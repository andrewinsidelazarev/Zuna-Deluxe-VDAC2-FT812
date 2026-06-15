#!/usr/bin/env python3
"""Verify generated top-mask pages are actually present in ZUMAMAIN.PAK."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "Source" / "ASM" / "main_pak_table.inc"
PAK = ROOT / "Build" / "ZUMAMAIN.PAK"
PAGE_SIZE = 0x4000


def main() -> int:
    text = TABLE.read_text(encoding="utf-8", errors="replace").splitlines()
    entries: list[tuple[int, str]] = []
    page = None
    for line in text:
        m = re.search(r"DEFB #([0-9A-F]{2})", line)
        if m:
            page = int(m.group(1), 16)
            continue
        if page is not None and "Graphics/levels/Converted/top_masks/" in line:
            rel = line.split(";", 1)[1].strip()
            entries.append((page, rel))
            page = None
    failures: list[str] = []
    if len(entries) != 17:
        failures.append(f"expected 17 top-mask entries in main_pak_table, got {len(entries)}")
    pak = PAK.read_bytes()
    for index, (page_num, rel) in enumerate(entries):
        src = (ROOT / rel).read_bytes().ljust(PAGE_SIZE, b"\x00")
        start = index * PAGE_SIZE
        # ZUMAMAIN.PAK order is MainPakPageTable order, not page-number order.
        # Find the actual table row index by recounting top-mask entries in full table.
        row = None
        current_page = None
        full_index = -1
        for line in text:
            m = re.search(r"DEFB #([0-9A-F]{2})", line)
            if m:
                current_page = int(m.group(1), 16)
                full_index += 1
                continue
            if current_page == page_num and rel in line:
                row = full_index
                break
        if row is None:
            failures.append(f"page #{page_num:02X}: cannot locate row for {rel}")
            continue
        got = pak[row * PAGE_SIZE : (row + 1) * PAGE_SIZE]
        if got != src:
            failures.append(f"page #{page_num:02X}: ZUMAMAIN.PAK payload mismatch for {rel}")
    pages = [page for page, _rel in entries]
    if pages != list(range(0xCC, 0xDD)):
        failures.append(f"top-mask pages are {pages}, expected #CC..#DC")
    if failures:
        print("FAIL: top-mask ZUMAMAIN.PAK delivery")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: top-mask pages #CC..#DC are delivered byte-for-byte in ZUMAMAIN.PAK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
