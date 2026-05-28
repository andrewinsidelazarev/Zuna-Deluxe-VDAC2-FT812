#!/usr/bin/env python3
"""Static memory-map checks for Zuma Deluxe VDAC2.

This is intentionally conservative: it fails on duplicate SPG pages, mismatched
preview page tables, and overlaps inside one FT812 RAM_G profile. Cross-room
RAM_G reuse is reported as informational because menu/level-select/gameplay
profiles are reloaded on room transitions.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


@dataclass(frozen=True)
class Range:
    profile: str
    name: str
    start: int
    end: int  # exclusive
    note: str = ""

    @property
    def size(self) -> int:
        return self.end - self.start


@dataclass(frozen=True)
class SpgBlock:
    line: int
    offset: int
    page: int
    path: Path
    text: str

    @property
    def size(self) -> int:
        return self.path.stat().st_size if self.path.exists() else 0

    @property
    def page_start(self) -> int:
        return self.page

    @property
    def page_end(self) -> int:
        offset_in_page = self.offset & 0x3FFF
        return self.page + (offset_in_page + self.size + 0x3FFF) // 0x4000


def hx(value: int, width: int = 6) -> str:
    return f"#{value:0{width}X}"


def parse_spg_blocks() -> list[SpgBlock]:
    path = ROOT / "spgbld_vdac2.ini"
    blocks: list[SpgBlock] = []
    rx = re.compile(r"Block\s*=\s*#([0-9A-Fa-f]+)\s*,\s*#([0-9A-Fa-f]{2})\s*,\s*(.+)")
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        m = rx.search(line)
        if not m:
            continue
        offset = int(m.group(1), 16)
        page = int(m.group(2), 16)
        rel = m.group(3).strip()
        blocks.append(SpgBlock(lineno, offset, page, ROOT / rel, line.strip()))
    return blocks


def parse_preview_inc() -> tuple[int, int, dict[int, tuple[int, int]]]:
    path = ROOT / "Source" / "ASM" / "level_select_preview_spg.inc"
    rows: dict[int, tuple[int, int]] = {}
    offset = 0
    count = 22
    rx = re.compile(r"DEFB\s+#([0-9A-Fa-f]{2})\s*:\s*DEFW\s+(\d+)\s*;\s*L(\d{2})")
    for line in path.read_text(encoding="utf-8").splitlines():
        m_offset = re.search(r"LEVEL_SELECT_PREVIEW_ZLIB_OFFSET\s+EQU\s+#([0-9A-Fa-f]+)", line)
        if m_offset:
            offset = int(m_offset.group(1), 16)
        m_count = re.search(r"LEVEL_SELECT_PREVIEW_ZLIB_COUNT\s+EQU\s+(\d+)", line)
        if m_count:
            count = int(m_count.group(1))
        m = rx.search(line)
        if m:
            rows[int(m.group(3))] = (int(m.group(1), 16), int(m.group(2)))
    return offset, count, rows


def check_spg_pages(errors: list[str]) -> None:
    blocks = parse_spg_blocks()
    for block in blocks:
        if not block.path.exists():
            errors.append(f"SPG block file is missing at line {block.line}: {block.path}")
    existing = [b for b in blocks if b.path.exists()]
    by_start: dict[int, list[SpgBlock]] = {}
    for block in existing:
        by_start.setdefault(block.page, []).append(block)
    for page, rows in sorted(by_start.items()):
        if len(rows) > 1:
            detail = "\n".join(f"    line {b.line}: {b.text}" for b in rows)
            errors.append(f"SPG page {hx(page, 2)} has multiple Block starts:\n{detail}")
    for idx, a in enumerate(existing):
        for b in existing[idx + 1 :]:
            if max(a.page_start, b.page_start) < min(a.page_end, b.page_end):
                errors.append(
                    f"SPG page range overlap: line {a.line} {hx(a.page_start, 2)}..{hx(a.page_end - 1, 2)} "
                    f"vs line {b.line} {hx(b.page_start, 2)}..{hx(b.page_end - 1, 2)}"
                )
    print(f"[spg] {len(existing)} Block ranges checked")


def check_preview_pages(errors: list[str]) -> None:
    blocks = parse_spg_blocks()
    block_ranges = [(b.page_start, b.page_end) for b in blocks if b.path.exists()]
    offset, count, inc = parse_preview_inc()
    if count == 0:
        if inc:
            errors.append(f"preview table must be empty when LEVEL_SELECT_PREVIEW_ZLIB_COUNT=0: {sorted(inc)}")
            return
        print("[preview] SPG preview table is empty; thumbnails are expected in ZUMALVL.PAK")
        return
    if sorted(inc) != list(range(1, count + 1)):
        errors.append(f"preview table levels are wrong: {sorted(inc)}")
        return
    expected_page = 0xCC
    for level, (page, size) in sorted(inc.items()):
        if page != expected_page:
            errors.append(f"L{level:02d} preview page is {hx(page, 2)}, expected contiguous high preview page {hx(expected_page, 2)}")
        zpath = ROOT / "Graphics" / "levels" / "Converted" / "pack" / f"level_select_preview_l{level:02d}.zlib"
        if zpath.exists() and zpath.stat().st_size != size:
            errors.append(f"L{level:02d} preview size table={size}, file={zpath.stat().st_size}")
        page_count = (offset + size + 0x3FFF) // 0x4000
        for pg in range(page, page + page_count):
            if not any(start <= pg < end for start, end in block_ranges):
                errors.append(f"L{level:02d} preview references SPG page {hx(pg, 2)} but spgbld has no Block for it")
        expected_page += page_count
    if expected_page > 0x100:
        errors.append(f"preview page range ends beyond SPG page #FF: next={hx(expected_page, 2)}")
    print("[preview] table, zlib sizes, and contiguous high-page ownership are consistent")


def ramg_ranges() -> list[Range]:
    return [
        # Gameplay profile.
        Range("gameplay", "TEXT_GAMEOVER", 0x000000, 0x004000),
        Range("gameplay", "TEXT_LEVEL11", 0x004000, 0x008000),
        Range("gameplay", "TEXT_TITLE", 0x008000, 0x00C000),
        Range("gameplay", "SPARKLE", 0x00C000, 0x010000),
        Range("gameplay", "BG_BITMAP", 0x010000, 0x02D500),
        Range("gameplay", "BG_PALETTE", 0x02D500, 0x02D700),
        Range("gameplay", "DIALOG_OK", 0x02D800, 0x030000),
        Range("gameplay", "FROG_ARGB4", 0x030000, 0x050000),
        Range("gameplay", "BALLS_ARGB4", 0x050000, 0x080000),
        Range("gameplay", "BALLS_PALETTE_SLOT", 0x080000, 0x080200),
        Range("gameplay", "FRAME_PALETTE", 0x080200, 0x080400),
        Range("gameplay", "FRAME_STRIPS", 0x084000, 0x098000),
        Range("gameplay", "FONT_NATIVE", 0x098000, 0x0A0000),
        Range("gameplay", "FONT_CANCUN10_STATS", 0x0A0000, 0x0A4000),
        Range("gameplay", "FONT_CANCUN8", 0x0A4000, 0x0AC000),
        Range("gameplay", "DIALOG_FRAME", 0x0AC000, 0x0CC000),
        Range("gameplay", "HUD_LIFE_FROG", 0x0CC000, 0x0CC200),
        Range("gameplay", "HUD_PALETTE", 0x0CC200, 0x0CC400),
        Range("gameplay", "DIALOG_PALETTE", 0x0CC400, 0x0CC600),
        Range("gameplay", "HUD_MENU", 0x0CC800, 0x0CE400),
        Range("gameplay", "HUD_PROGRESS", 0x0CE400, 0x0CFD5E),
        Range("gameplay", "CURSOR_UPLOAD_BLOCK", 0x0D0000, 0x0D4000),
        Range("gameplay", "KILLZONE_DESTROY_UPLOAD", 0x0D4000, 0x0FC000, "combined KZ + destroy upload"),
        Range("gameplay", "DESTROY_HANDLE_SOURCE", 0x0EC000, 0x0FA000, "inside combined upload"),
        # Main menu profile.
        Range("main_menu", "MENU_FG", 0x000000, 0x04B000),
        Range("main_menu", "MENU_SKY", 0x04B000, 0x065180),
        Range("main_menu", "MENU_SPRITES", 0x065180, 0x0ABA60),
        Range("main_menu", "MENU_SKY_PAL", 0x0ABA60, 0x0ABC60),
        Range("main_menu", "MENU_UI_PAL", 0x0ABC60, 0x0ABE60),
        Range("main_menu", "MENU_CURSOR", 0x0AC000, 0x0AD200),
        # Level select profile.
        Range("level_select", "LS_BG", 0x000000, 0x04B000),
        Range("level_select", "LS_SKY", 0x04B000, 0x065180),
        Range("level_select", "LS_UI", 0x065180, 0x082658),
        Range("level_select", "LS_SKY_PAL", 0x0ABA60, 0x0ABC60),
        Range("level_select", "LS_UI_PAL", 0x0ABC60, 0x0ABE60),
        Range("level_select", "LS_CURSOR_REUSE", 0x0AC000, 0x0AD200),
        Range("level_select", "LS_MARKERS", 0x0B0000, 0x0B20B2),
        Range("level_select", "LS_PREVIEW_BG", 0x0D4000, 0x0EA580),
        # More Games profile.
        Range("more_games", "MORE_GAMES_BG", 0x000000, 0x04B000),
        Range("more_games", "MORE_GAMES_PAL", 0x0ABC60, 0x0ABE60),
    ]


def allowed_same_profile_overlap(a: Range, b: Range) -> bool:
    if a.profile == "gameplay":
        names = {a.name, b.name}
        return names == {"KILLZONE_DESTROY_UPLOAD", "DESTROY_HANDLE_SOURCE"}
    return False


def check_ramg(errors: list[str]) -> None:
    ranges = ramg_ranges()
    for item in ranges:
        if item.start < 0 or item.end > 0x100000 or item.start >= item.end:
            errors.append(f"{item.profile}:{item.name} invalid range {hx(item.start)}..{hx(item.end)}")
    for profile in sorted({r.profile for r in ranges}):
        rows = sorted((r for r in ranges if r.profile == profile), key=lambda r: r.start)
        for idx, a in enumerate(rows):
            for b in rows[idx + 1 :]:
                if b.start >= a.end:
                    break
                if not allowed_same_profile_overlap(a, b):
                    errors.append(
                        f"RAM_G overlap inside {profile}: {a.name} {hx(a.start)}..{hx(a.end)} "
                        f"vs {b.name} {hx(b.start)}..{hx(b.end)}"
                    )
        max_end = max(r.end for r in rows)
        print(f"[ramg] {profile}: {len(rows)} ranges, max end {hx(max_end)}")

    cross_notes = [
        ("level_select", "LS_PREVIEW_BG", "gameplay", "KILLZONE_DESTROY_UPLOAD"),
        ("main_menu", "MENU_CURSOR", "gameplay", "DIALOG_FRAME"),
        ("level_select", "LS_CURSOR_REUSE", "gameplay", "DIALOG_FRAME"),
    ]
    lookup = {(r.profile, r.name): r for r in ranges}
    for left_p, left_n, right_p, right_n in cross_notes:
        a = lookup[(left_p, left_n)]
        b = lookup[(right_p, right_n)]
        if max(a.start, b.start) < min(a.end, b.end):
            print(f"[ramg] cross-profile reuse: {left_p}:{left_n} overlaps {right_p}:{right_n}")


def check_build_sizes(errors: list[str]) -> None:
    sym_path = ROOT / "Build" / "zuma.sym"
    if not sym_path.exists():
        print("[build] Build/zuma.sym missing; skipping size check")
        return
    text = sym_path.read_text(encoding="utf-8", errors="replace")
    values: dict[str, int] = {}
    for name in ("Main0_Size", "Main1_Size", "UiOvl_Size", "LoaderOvl_Size"):
        m = re.search(rf"^{re.escape(name)}:\s+EQU\s+0x([0-9A-Fa-f]+)", text, re.MULTILINE)
        if m:
            values[name] = int(m.group(1), 16)
    main0 = values.get("Main0_Size")
    main1 = values.get("Main1_Size")
    if main0 is not None and main0 > 0x2400:
        errors.append(f"Main0_Size is {main0} bytes; review Core page headroom")
    if main1 is not None and main1 > 0x4000:
        errors.append(f"Main1_Size is {main1} bytes; page #04 overflows by {main1 - 0x4000} bytes")
    if main0 is not None:
        print(f"[build] Main0_Size={main0} bytes")
    if main1 is not None:
        print(f"[build] Main1_Size={main1} bytes, free={0x4000 - main1} bytes (gameplay overlay page #04)")
        if main1 > 0x3F00:
            print("[build] warning: gameplay overlay (page #04) has less than 256 bytes free")
    # Each slot-3 overlay assembles at #C000 and must fit one 16K page. They share
    # the logical window but live on distinct physical pages (#04 gameplay, #41 ui,
    # #40 loader); SAVEBIN remaps the slot before each dump (see main.asm).
    for name, page, label in (("UiOvl_Size", "#41", "ui overlay"),
                              ("LoaderOvl_Size", "#40", "loader overlay")):
        sz = values.get(name)
        if sz is None:
            continue
        if sz > 0x4000:
            errors.append(f"{name} is {sz} bytes; {label} page {page} overflows by {sz - 0x4000} bytes")
        else:
            print(f"[build] {name}={sz} bytes, free={0x4000 - sz} bytes ({label} page {page})")


def main() -> int:
    errors: list[str] = []
    check_spg_pages(errors)
    check_preview_pages(errors)
    check_ramg(errors)
    check_build_sizes(errors)
    if errors:
        print()
        print("FAIL: memory-map check found problems:")
        for err in errors:
            print(f"- {err}")
        return 1
    print("PASS: memory-map checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
