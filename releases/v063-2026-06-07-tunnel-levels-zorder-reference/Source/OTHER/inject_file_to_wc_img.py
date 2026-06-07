#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from inject_zuma_to_wc_img import Fat32Image


DEFAULT_IMG = Path(r"\\tsclient\D\Работа.Андрей\unreal_x64\wc.img")


def main() -> int:
    parser = argparse.ArgumentParser(description="Add or replace one file inside an existing FAT32 wc.img.")
    parser.add_argument("--img", type=Path, default=DEFAULT_IMG)
    parser.add_argument("--src", type=Path, required=True)
    parser.add_argument("--dir", nargs="+", required=True)
    parser.add_argument("--name", default=None)
    args = parser.parse_args()

    if not args.img.exists():
        raise SystemExit(f"image not found: {args.img}")
    if not args.src.exists():
        raise SystemExit(f"source not found: {args.src}")

    image = Fat32Image(args.img)
    cluster = image.root_cluster
    for part in args.dir:
        cluster = image.ensure_dir(cluster, part)

    target_name = args.name or args.src.name
    image.write_file(cluster, target_name, args.src)
    image.save()

    print(f"image: {args.img} (in-place)")
    print(f"folder: /{'/'.join(args.dir)}/")
    print(f"file: {target_name} {args.src.stat().st_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
