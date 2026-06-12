#!/usr/bin/env python3
"""dump_track_start.py — первые/последние сэмплы трека уровня (640-исходник).
Диагностика «шары выезжают не из-за края экрана»: точка спавна = сэмпл 0.
"""
import glob
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"


def dump(path: Path) -> None:
    b = path.read_bytes()
    n = struct.unpack_from("<H", b, 0)[0]
    print(f"{path.name}: samples={n}")
    idxs = [0, 1, 2, 5, 10, 30, 80]
    for i in idxs:
        if i < n:
            x, y, t, f = struct.unpack_from("<hhBB", b, 2 + i * 6)
            sx, sy = round(x * 8 / 5), round(y * 8 / 5)
            print(f"  s{i:4d}: 640=({x:5d},{y:5d}) -> 1024=({sx:5d},{sy:5d}) tan={t:3d} fl={f:02X}")


def main() -> None:
    levels = sys.argv[1:] or ["11"]
    for lv in levels:
        for p in sorted(PACK.glob(f"track_l{int(lv):02d}*.bin")):
            dump(p)


if __name__ == "__main__":
    main()
