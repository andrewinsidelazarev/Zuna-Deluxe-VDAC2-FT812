#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from inject_zuma_to_wc_img import ATTR_DIRECTORY, Fat32Image


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_IMG = Path(r"\\tsclient\D\Работа.Андрей\unreal_x64\wc.img")
HOST_DIR = ["Games", "Zuma Deluxe VDAC2"]
FILES = {
    ("Games", "Zuma Deluxe VDAC2", "zuma_vdac2.spg"): ROOT / "Build" / "zuma_vdac2.spg",
    ("Games", "Zuma Deluxe VDAC2", "ZUMAMAIN.PAK"): ROOT / "Build" / "SD" / "Games" / "Zuma Deluxe VDAC2" / "ZUMAMAIN.PAK",
    ("Games", "Zuma Deluxe VDAC2", "ZUMALVL.PAK"): ROOT / "Build" / "SD" / "Games" / "Zuma Deluxe VDAC2" / "ZUMALVL.PAK",
    ("Games", "Zuma Deluxe VDAC2", "ZUMAAUD.PAK"): ROOT / "Build" / "SD" / "Games" / "Zuma Deluxe VDAC2" / "ZUMAAUD.PAK",
    ("Games", "Zuma Deluxe VDAC2", "ZUMASND.PAK"): ROOT / "Build" / "SD" / "Games" / "Zuma Deluxe VDAC2" / "ZUMASND.PAK",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def walk_dir(img: Fat32Image, parts: list[str]) -> dict:
    cluster = img.root_cluster
    entry: dict | None = None
    for part in parts:
        entry = img.find_entry(cluster, part)
        if entry is None:
            raise RuntimeError(f"directory not found: {'/'.join(parts)} at {part!r}")
        if not (entry["attr"] & ATTR_DIRECTORY):
            raise RuntimeError(f"not a directory: {part!r}")
        cluster = entry["cluster"]
    return {"cluster": cluster, "entry": entry}


def chain_report(img: Fat32Image, entry: dict) -> tuple[list[int], str]:
    chain = img.cluster_chain(entry["cluster"])
    expected = (entry["size"] + img.cluster_size - 1) // img.cluster_size
    status = "OK" if len(chain) >= expected else f"SHORT expected>={expected}"
    return chain, status


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Zuma files inside the host FAT32 wc.img.")
    parser.add_argument("--img", type=Path, default=DEFAULT_IMG)
    args = parser.parse_args()

    img = Fat32Image(args.img)
    target = walk_dir(img, HOST_DIR)
    entries = img.parse_dir(target["cluster"])

    print(f"image={args.img}")
    print(f"cluster_size={img.cluster_size} root_cluster={img.root_cluster}")
    print(f"dir=/{'/'.join(HOST_DIR)} cluster={target['cluster']}")
    print("directory_entries:")
    for ent in entries:
        chain, status = chain_report(img, ent)
        kind = "dir" if ent["attr"] & ATTR_DIRECTORY else "file"
        print(
            f"  {ent['name']} type={kind} size={ent['size']} cluster={ent['cluster']} "
            f"chain_len={len(chain)} chain_status={status}"
        )

    ok = True
    for parts, local_path in FILES.items():
        name = "/".join(parts)
        dir_cluster = img.root_cluster
        missing_dir = False
        for part in parts[:-1]:
            parent = img.find_entry(dir_cluster, part)
            if parent is None or not (parent["attr"] & ATTR_DIRECTORY):
                print(f"compare {name}: DIR_MISSING {part}")
                ok = False
                missing_dir = True
                break
            dir_cluster = parent["cluster"]
        if missing_dir:
            continue
        ent = img.find_entry(dir_cluster, parts[-1])
        if ent is None:
            print(f"compare {name}: MISSING_IN_IMAGE")
            ok = False
            continue
        if not local_path.exists():
            print(f"compare {name}: LOCAL_MISSING {local_path}")
            ok = False
            continue

        host_data = img.read_chain(ent["cluster"])[: ent["size"]]
        local_data = local_path.read_bytes()
        same_size = len(host_data) == len(local_data)
        same_hash = sha256(host_data) == sha256(local_data)
        print(
            f"compare {name}: host_size={len(host_data)} local_size={len(local_data)} "
            f"size_match={same_size} hash_match={same_hash}"
        )
        print(f"  host_sha256={sha256(host_data)}")
        print(f"  local_sha256={sha256(local_data)}")
        if not same_size or not same_hash:
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
