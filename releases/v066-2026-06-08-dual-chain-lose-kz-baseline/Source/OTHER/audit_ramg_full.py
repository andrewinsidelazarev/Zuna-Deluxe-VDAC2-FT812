#!/usr/bin/env python3
"""Полный аудит RAM_G (FT812, ровно 1 МБ = 0x100000).

Берёт ground-truth адреса из Build/zuma.sym, считает КОНЦЫ регионов по реальным
размерам (страницы / W*H*bpp), группирует по сценам-профилям и флагует:
  * любой регион с концом > 0x100000  (на железе аливасится в низ RAM_G → мусор);
  * перекрытия внутри ОДНОГО профиля (живут одновременно → порча).
Перекрытия МЕЖДУ профилями — это норма (сцены перезаливают RAM_G), печатаются
информационно.

Запуск: python Source/OTHER/audit_ramg_full.py
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
RAM_G = 0x100000
PAGE = 0x4000


def load_sym() -> dict[str, int]:
    sym = {}
    path = ROOT / "Build" / "zuma.sym"
    rx = re.compile(r"^([A-Za-z0-9_.]+):\s+EQU\s+0x([0-9A-Fa-f]+)")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = rx.match(line)
        if m:
            sym[m.group(1)] = int(m.group(2), 16)
    return sym


def hx(v: int) -> str:
    return f"#{v:06X}"


def range_contains(rows: list[tuple[str, int, int, str]], value: int) -> bool:
    return any(start <= value < start + size for _, start, size, _ in rows)


def is_ramg_symbol(name: str) -> bool:
    base = name.split(".")[-1]
    if "RAMG" not in base and "RAM_G" not in base:
        return False
    if base in {"FT_RAM_G", "FT_RAM_G_SIZE"}:
        return False
    if base.endswith(("_END", "_SIZE", "_COUNT", "_W", "_H")):
        return False
    return True


def scan_stale_ramg_comments() -> list[str]:
    """Find source comments that can reintroduce the old 4 MB RAM_G mistake."""
    hits: list[str] = []
    needles = ("4 МБ RAM_G", "4 MB RAM_G", "4МБ RAM_G", "4MB RAM_G")
    for root in (ROOT / "Source" / "ASM", ROOT / "Source" / "OTHER"):
        for path in root.rglob("*"):
            if path.resolve() == Path(__file__).resolve():
                continue
            if path.suffix.lower() not in {".asm", ".inc", ".py", ".md", ".txt"}:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                if any(n in line for n in needles):
                    hits.append(f"{path.relative_to(ROOT)}:{lineno}: {line.strip()}")
    return hits


def main() -> int:
    S = load_sym()

    def a(name: str) -> int:
        # адрес: пробуем с префиксом Core. и без
        for k in (name, "Core." + name):
            if k in S:
                return S[k]
        raise KeyError(name)

    # (имя, старт, размер_байт, заметка). Размер = ВЫДЕЛЕННЫЙ экстент (для overlap).
    profiles: dict[str, list[tuple[str, int, int, str]]] = {}

    # ---- BOOT loading screen (показывается на буте, пока грузится ZUMAMAIN.PAK) ----
    profiles["boot_loading"] = [
        ("BOOT_LOADING_BG_DXT_L4", a("BOOT_LOADING_BG_RAMG"), a("BOOT_LOADING_BG_PAGES") * PAGE, "640x480 pseudo-DXT L4 raw, 15 стр"),
        ("BOOT_LOADING_BAR", a("BOOT_LOADING_BAR_RAMG"), 2 * PAGE, "395x37 ARGB4, 2 стр"),
        ("BOOT_TS_ANIM", a("BOOT_TS_ANIM_RAMG"), 10 * PAGE, "188x407 atlas ARGB4, 10 стр"),
        ("BOOT_SFX_AUTHORS", a("BOOT_SFX_AUTHORS_RAMG"), a("BOOT_SFX_AUTHORS_PAGES") * PAGE, "Claude/Codex 48x48x2 ARGB4 atlas"),
    ]

    # ---- GAMEPLAY (нормальная игра) ----
    profiles["gameplay"] = [
        ("TEXT_GAMEOVER", a("TEXT_GAMEOVER_RAMG"), PAGE, "169x46 ARGB4 (1 стр)"),
        ("FONT_LEVEL48", a("FONT_LEVEL48_RAMG"), 2 * PAGE, "LEVEL N-M шрифт"),
        ("SPARKLE", a("SPARKLE_RAMG"), PAGE, "24x24 ARGB4"),
        ("BG_BITMAP", a("BG_RAMG_ADDR"), 0x1D4C0, "400x300 PALETTED4444"),
        ("BG_PALETTE", a("BG_PALETTE_RAMG"), 0x200, ""),
        ("DIALOG_OK", a("DIALOG_OK_RAMG"), 0x2800, "300x34"),
        ("FROG_ARGB4", a("FROG_RAMG_ADDR"), 0x20000, "frog/plate/tongue/overlay 4x32K"),
        ("BALLS_ARGB4", a("BALLS_RAMG_ADDR"), 0x30000, "192K, 16 фаз"),
        ("BALLS_PALETTE", a("BALLS_PALETTE_RAMG"), 0x200, ""),
        ("FRAME_PALETTE", a("FRAME_PAL_RAMG"), 0x200, ""),
        ("TOP_MASK_A", a("TOP_MASK_RAMG_A"), a("TOP_MASK_RAMG_A_END") - a("TOP_MASK_RAMG_A"), "active tunnel ARGB4 top-cover tiles"),
        ("FRAME_TOP", a("FRAME_TOP_RAMG"), 2 * PAGE, "640x44"),
        ("FRAME_BOT", a("FRAME_BOT_RAMG"), PAGE, "640x24"),
        ("FRAME_LEFT", a("FRAME_LEFT_RAMG"), PAGE, "24x412"),
        ("FRAME_RIGHT", a("FRAME_RIGHT_RAMG"), PAGE, "24x412"),
        ("FONT_NATIVE", a("FONT_NATIVE_RAMG"), 2 * PAGE, ""),
        ("FONT_CANCUN10", a("FONT_CANCUN10_STATS_RAMG"), PAGE, ""),
        ("FONT_CANCUN8", a("FONT_CANCUN8_RAMG"), 2 * PAGE, ""),
        ("TOP_MASK_SWAP", a("TOP_MASK_RAMG_SWAP"), a("TOP_MASK_RAMG_SWAP_END") - a("TOP_MASK_RAMG_SWAP"), "active tunnel ARGB4 top-cover tiles; swaps with DIALOG_FRAME"),
        ("HUD_LIFE_FROG", a("LIFE_FROG_RAMG"), 0x200, ""),
        ("HUD_PALETTE", a("HUD_PALETTE_RAMG"), 0x200, ""),
        ("DIALOG_PALETTE", a("DIALOG_PALETTE_RAMG"), 0x200, ""),
        ("HUD_MENU", a("HUD_MENU_RAMG"), 0x1C00, "79x26x3"),
        ("HUD_PROGRESS", a("HUD_PROGRESS_RAMG"), 0x0960, "63x19x2"),
        ("CURSOR", a("CURSOR_RAMG_ADDR"), PAGE, "24x24 ARGB4"),
        ("KZ+DESTROY", a("KZ_RAMG_ADDR"), a("KZ_PAGE_COUNT") * PAGE, "killzone 6 + destroy 4 стр"),
        ("TOP_MASK_B", a("TOP_MASK_RAMG_B"), a("TOP_MASK_RAMG_B_END") - a("TOP_MASK_RAMG_B"), "active tunnel ARGB4 top-cover tiles"),
    ]

    # ---- DIALOG/PAUSE-state: то же поле, но #0AC000..#0CC000 занято окном диалога.
    dialog = [r for r in profiles["gameplay"] if r[0] != "TOP_MASK_SWAP"]
    dialog.append(("DIALOG_FRAME", a("DIALOG_FRAME_RAMG"), 8 * PAGE, "400x327 PALETTED4444, lazy reload over TOP_MASK_SWAP"))
    profiles["dialog_state"] = dialog

    # ---- WIN-state: то же, что gameplay, НО WINEXP-атлас дозаливается поверх BALLS ----
    win = [r for r in profiles["gameplay"]]
    win.append(("WINEXP_ATLAS(over BALLS)", a("WINEXP_RAMG_ADDR"),
                a("WINEXP_PAGE_COUNT") * PAGE, "оранжевый взрыв, 5 стр — поверх BALLS на входе в WIN"))
    profiles["win_state"] = win

    # ---- MAIN MENU ----
    # Вся графика меню — 8bpp PALETTED (1 байт/пиксель); подтверждено разницей
    # последовательных адресов в zuma.sym (FG=640x480=#4B000 и т.д.).
    def menu_btn(stem, w, h):
        return [(f"{stem}_{v}", a(f"MENU_{stem}_{v}_RAMG"), w * h, "")
                for v in ("N", "H", "P")]
    profiles["main_menu"] = [
        ("MENU_FG", a("MENU_FG_RAMG"), 640 * 480, "640x480 PALETTED 8bpp"),
        ("MENU_SKY", a("MENU_SKY_RAMG"), 640 * 167, "8bpp"),
        ("MENU_SUN", a("MENU_SUN_RAMG"), 87 * 92, "8bpp"),
        ("MENU_GLOW", a("MENU_GLOW_RAMG"), 210 * 210, "8bpp"),
        *menu_btn("ADV", 163, 92),
        *menu_btn("GAUNT", 180, 83),
        *menu_btn("OPT", 199, 86),
        *menu_btn("MORE", 118, 127),
        *menu_btn("QUIT", 120, 141),
        ("MENU_SKY_PAL", a("MENU_SKY_PAL_RAMG"), 0x200, ""),
        ("MENU_UI_PAL", a("MENU_UI_PAL_RAMG"), 0x200, ""),
        ("MENU_CURSOR", a("MENU_CURSOR_RAMG"), 24 * 24 * 2, ""),
    ]

    # ---- LEVEL SELECT ----
    profiles["level_select"] = [
        ("LS_BG", a("LS_BG_RAMG"), a("LS_SKY_RAMG") - a("LS_BG_RAMG"), ""),
        ("LS_SKY..LS_UI", a("LS_SKY_RAMG"), a("LS_RAMG_END") - a("LS_SKY_RAMG"), "sky+sun+кнопки+бейджи"),
        ("LS_SKY_PAL", a("LS_SKY_PAL_RAMG"), 0x200, ""),
        ("LS_UI_PAL", a("LS_UI_PAL_RAMG"), 0x200, ""),
        ("LS_CURSOR", a("LS_CURSOR_RAMG"), 24 * 24 * 2, ""),
        ("LS_PREVIEW_MARK/FROG/KZ", a("LS_PREVIEW_MARKER_RAMG"),
         a("LS_PREVIEW_KZ_RAMG") + a("LS_PREVIEW_KZ_BYTES") - a("LS_PREVIEW_MARKER_RAMG"), "превью-маркеры"),
        ("LS_PREVIEW_BG", a("LS_PREVIEW_BG_RAMG"), 0x20000, "превью фона уровня"),
        ("LOADING_TEXT", a("LOADING_TEXT_RAMG"), 2 * PAGE, "баннер LOADING LEVEL"),
    ]

    # ---- MORE GAMES ----
    profiles["more_games"] = [
        ("MORE_GAMES_BG", a("MORE_GAMES_RAMG"), 5 * 0xF000, ""),
        ("MORE_GAMES_PAL", a("MORE_GAMES_PAL_RAMG"), 0x200, ""),
    ]

    # ---- Runtime upload extents (что реально пишется в RAM_G) ----
    # Здесь размеры намеренно берутся как upload-window: UnpackAndUploadPage
    # всегда пишет 16K и авто-двигает BgRam, даже если полезная картинка меньше.
    uploads: list[tuple[str, int, int, str]] = [
        ("boot:loading_bg_dxt_raw_pages", a("BOOT_LOADING_BG_RAMG"), a("BOOT_LOADING_BG_PAGES") * PAGE, "raw FT.WriteMem x15"),
        ("boot:loading_bar_pages", a("BOOT_LOADING_BAR_RAMG"), 2 * PAGE, "UnpackAndUploadPage x2"),
        ("boot:ts_anim_pages", a("BOOT_TS_ANIM_RAMG"), 10 * PAGE, "UnpackAndUploadPage x10"),
        ("boot:sfx_authors_pages", a("BOOT_SFX_AUTHORS_RAMG"), a("BOOT_SFX_AUTHORS_PAGES") * PAGE, "UnpackAndUploadPage x1"),
        ("game:level_bg_stream", a("BG_RAMG_ADDR"), a("BG_PAGE_COUNT") * PAGE, "level pak bg stream / fallback pages"),
        ("game:bg_palette_raw", a("BG_PALETTE_RAMG"), 0x200, "raw palette"),
        ("game:balls_pages", a("BALLS_RAMG_ADDR"), a("BALLS_PAGE_COUNT") * PAGE, "UnpackAndUploadPage x12"),
        ("game:frog_pages", a("FROG_RAMG_ADDR"), a("FROG_TOTAL_PAGES") * PAGE, "UnpackAndUploadPage"),
        ("game:kz_destroy_pages", a("KZ_RAMG_ADDR"), a("KZ_PAGE_COUNT") * PAGE, "killzone + destroy"),
        ("game:cursor_page", a("CURSOR_RAMG_ADDR"), PAGE, "cursor upload pads to 16K"),
        ("game:text_gameover_page", a("TEXT_GAMEOVER_RAMG"), PAGE, ""),
        ("game:font_level48_pages", a("FONT_LEVEL48_RAMG"), 2 * PAGE, ""),
        ("game:sparkle_page", a("SPARKLE_RAMG"), PAGE, ""),
        ("game:frame_strip_pages", a("FRAME_TOP_RAMG"), 5 * PAGE, "top2 + bot + left + right"),
        ("game:top_mask_a_raw", a("TOP_MASK_RAMG_A"), a("TOP_MASK_RAMG_A_END") - a("TOP_MASK_RAMG_A"), "active tunnel ARGB4 top-cover tiles"),
        ("game:top_mask_b_raw", a("TOP_MASK_RAMG_B"), a("TOP_MASK_RAMG_B_END") - a("TOP_MASK_RAMG_B"), "active tunnel ARGB4 top-cover tiles"),
        ("game:top_mask_swap_raw", a("TOP_MASK_RAMG_SWAP"), a("TOP_MASK_RAMG_SWAP_END") - a("TOP_MASK_RAMG_SWAP"), "active tunnel ARGB4 top-cover tiles over dialog frame window"),
        ("game:dialog_frame_pages", a("DIALOG_FRAME_RAMG"), 8 * PAGE, ""),
        ("game:font_native_pages", a("FONT_NATIVE_RAMG"), 2 * PAGE, ""),
        ("game:font_cancun10_page", a("FONT_CANCUN10_STATS_RAMG"), PAGE, ""),
        ("game:font_cancun8_pages", a("FONT_CANCUN8_RAMG"), 2 * PAGE, ""),
        ("win:winexp_pages_over_balls", a("WINEXP_RAMG_ADDR"), a("WINEXP_PAGE_COUNT") * PAGE, "WIN-only overlay over BALLS"),
        ("level_select:preview_bg_stream", a("LS_PREVIEW_BG_RAMG"), 0x20000, "8 pages from ZUMALVL preview bg"),
        ("level_select:loading_text_pages", a("LOADING_TEXT_RAMG"), 2 * PAGE, ""),
    ]

    problems: list[str] = []
    for prof in ("boot_loading", "main_menu", "level_select", "more_games", "gameplay", "dialog_state", "win_state"):
        rows = sorted(profiles[prof], key=lambda r: r[1])
        print(f"\n=== {prof} ===")
        max_end = 0
        for name, start, size, note in rows:
            end = start + size
            max_end = max(max_end, end)
            flag = "  <<< ЗА 1МБ!" if end > RAM_G else ""
            print(f"  {hx(start)}..{hx(end)}  {name:<26} {note}{flag}")
            if end > RAM_G:
                problems.append(f"{prof}:{name} конец {hx(end)} > 1МБ")
        print(f"  -> max end {hx(max_end)}  (свободно до 1МБ: {RAM_G - max_end} байт)")
        # overlaps внутри профиля (намеренное переиспользование — в allow-list)
        allowed = {("BALLS_ARGB4", "WINEXP_ATLAS(over BALLS)")}  # шаров в WIN нет
        for i, (n1, s1, z1, _) in enumerate(rows):
            e1 = s1 + z1
            for n2, s2, z2, _ in rows[i + 1:]:
                if s2 >= e1:
                    break
                if (n1, n2) in allowed or (n2, n1) in allowed:
                    continue
                ov = min(e1, s2 + z2) - max(s1, s2)
                problems.append(f"{prof}: ПЕРЕКРЫТИЕ {n1}({hx(s1)}..{hx(e1)}) ↔ {n2}({hx(s2)}..{hx(s2+z2)}) = {ov} байт")

    print("\n=== runtime_uploads ===")
    for name, start, size, note in sorted(uploads, key=lambda r: r[1]):
        end = start + size
        flag = "  <<< ЗА 1МБ!" if end > RAM_G else ""
        print(f"  {hx(start)}..{hx(end)}  {name:<30} {note}{flag}")
        if end > RAM_G:
            problems.append(f"upload:{name} конец {hx(end)} > 1МБ")

    all_profile_rows = [row for rows in profiles.values() for row in rows]
    print("\n=== ramg_symbols_coverage ===")
    uncovered: list[str] = []
    ramg_symbols = sorted((k, v) for k, v in S.items() if is_ramg_symbol(k))
    for name, value in ramg_symbols:
        if not 0 <= value < RAM_G:
            problems.append(f"symbol:{name} = {hx(value)} вне RAM_G 0..#0FFFFF")
            continue
        if not range_contains(all_profile_rows, value):
            uncovered.append(f"{name}={hx(value)}")
    print(f"  checked symbols: {len(ramg_symbols)}")
    if uncovered:
        for item in uncovered:
            print(f"  UNCOVERED {item}")
            problems.append(f"RAM_G symbol not covered by any profile: {item}")
    else:
        print("  OK: все RAMG/RAM_G asset-символы попадают в хотя бы один профиль")

    print("\n=== stale_ramg_comments ===")
    stale = scan_stale_ramg_comments()
    if stale:
        for hit in stale:
            print(f"  STALE {hit}")
            problems.append(f"устаревший комментарий про 4 МБ RAM_G: {hit}")
    else:
        print("  OK: в Source нет старых комментариев про 4 МБ RAM_G")

    print("\n" + "=" * 60)
    if problems:
        print("НАЙДЕНЫ ПРОБЛЕМЫ:")
        for p in problems:
            print(" -", p)
        return 1
    print("OK: все профили влезают в 1МБ, живых перекрытий нет.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
