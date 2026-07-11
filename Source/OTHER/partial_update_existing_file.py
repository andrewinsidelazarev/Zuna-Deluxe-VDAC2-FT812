#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from inject_zuma_to_wc_img import ATTR_DIRECTORY, Fat32Image


DEFAULT_IMG = Path(r"\\tsclient\D\Работа.Андрей\unreal_x64\wc.img")
DEFAULT_TARGET = ("Games", "Zuma Deluxe VDAC2", "zuma_vdac2.spg")


def find_path(image: Fat32Image, parts: tuple[str, ...]) -> dict:
    cluster = image.root_cluster
    entry: dict | None = None
    for index, part in enumerate(parts):
        entry = image.find_entry(cluster, part)
        if entry is None:
            raise RuntimeError(f"not found: {'/'.join(parts[: index + 1])}")
        if index < len(parts) - 1:
            if not (entry["attr"] & ATTR_DIRECTORY):
                raise RuntimeError(f"not a directory: {'/'.join(parts[: index + 1])}")
            cluster = entry["cluster"]
    assert entry is not None
    return entry


def update_existing_file(img: Path, target: tuple[str, ...], src: Path) -> None:
    payload = src.read_bytes()
    image = Fat32Image(img)
    entry = find_path(image, target)
    old_size = entry["size"]
    if old_size != len(payload):
        raise RuntimeError(
            f"size mismatch for {'/'.join(target)}: image={old_size}, src={len(payload)}; "
            "directory/FAT update intentionally refused"
        )

    chain = image.cluster_chain(entry["cluster"])
    capacity = len(chain) * image.cluster_size
    if len(payload) > capacity:
        raise RuntimeError(f"cluster chain too small: capacity={capacity}, src={len(payload)}")

    with img.open("r+b") as f:
        pos = 0
        for cluster in chain:
            chunk = payload[pos : pos + image.cluster_size]
            if not chunk:
                break
            f.seek(image.cluster_offset(cluster))
            f.write(chunk)
            pos += len(chunk)

    print(f"updated: {img}")
    print(f"target: /{'/'.join(target)}")
    print(f"cluster: {entry['cluster']}")
    print(f"clusters: {len(chain)}")
    print(f"bytes: {len(payload)}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Overwrite data clusters of an existing FAT32 file without FAT/directory changes."
    )
    parser.add_argument("--img", type=Path, default=DEFAULT_IMG)
    parser.add_argument("--src", type=Path, default=Path("Build/zuma_vdac2.spg"))
    parser.add_argument("--target", nargs="*", default=list(DEFAULT_TARGET))
    args = parser.parse_args()
    update_existing_file(args.img, tuple(args.target), args.src)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
