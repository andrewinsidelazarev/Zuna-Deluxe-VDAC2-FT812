#!/usr/bin/env python3
"""Compress all shared assets (balls/frog/kz/destroy/cursor) with ZX7.

1:1 mapping: каждый исходный *.bin → *_zx7.bin в той же папке.
SPG layout остаётся прежним (один compressed файл = одна SPG page).
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Load compress() from compress_zx7
import importlib.util
spec = importlib.util.spec_from_file_location("zx7", os.path.join(os.path.dirname(__file__), "compress_zx7.py"))
zx7 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zx7)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
GFX = os.path.join(ROOT, 'Graphics', 'Converted')

TARGETS = (
    # (count, prefix-format) — список логически сгруппированных файлов
    *(f'balls_atlas_p{i:02d}.bin' for i in range(24)),
    *(f'frog_p{i:02d}.bin' for i in range(2)),
    *(f'frog_plate_p{i:02d}.bin' for i in range(2)),
    *(f'frog_tongue_p{i:02d}.bin' for i in range(2)),
    *(f'frog_overlay_p{i:02d}.bin' for i in range(2)),
    *(f'killzone_p{i:02d}.bin' for i in range(6)),
    *(f'destroy_atlas_p{i:02d}.bin' for i in range(4)),
    'cursor_p00.bin',
)

def main():
    total_orig = 0
    total_zx7 = 0
    for fname in TARGETS:
        src = os.path.join(GFX, fname)
        dst = src.replace('.bin', '_zx7.bin')
        with open(src, 'rb') as f: data = f.read()
        c = zx7.compress(data)
        with open(dst, 'wb') as f: f.write(c)
        total_orig += len(data)
        total_zx7 += len(c)
        print(f'  {fname:30s} {len(data):6d} -> {len(c):6d}  ({100*len(c)/len(data):5.1f}%)')
    print()
    print(f'TOTAL: {total_orig} -> {total_zx7} ({100*total_zx7/total_orig:.1f}%)')
    pg_o = (total_orig + 16383) // 16384
    pg_c = (total_zx7 + 16383) // 16384
    print(f'Logical pages: {pg_o} -> {pg_c} (potential save if packed: {pg_o - pg_c})')
    print(f'1:1 mapping (current PoC): {pg_o} SPG pages (no save).')

if __name__ == '__main__':
    main()
