#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import struct
from pathlib import Path


ATTR_READ_ONLY = 0x01
ATTR_DIRECTORY = 0x10
ATTR_ARCHIVE = 0x20
ATTR_LFN = 0x0F
EOC = 0x0FFFFFFF


def le16(buf: bytearray, off: int) -> int:
    return struct.unpack_from("<H", buf, off)[0]


def le32(buf: bytearray, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def put16(buf: bytearray, off: int, value: int) -> None:
    struct.pack_into("<H", buf, off, value & 0xFFFF)


def put32(buf: bytearray, off: int, value: int) -> None:
    struct.pack_into("<I", buf, off, value & 0xFFFFFFFF)


def short_checksum(short_name: bytes) -> int:
    chk = 0
    for b in short_name:
        chk = (((chk & 1) << 7) + (chk >> 1) + b) & 0xFF
    return chk


def sanitize_short(stem: str, ext: str = "") -> bytes:
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$~!#%&-{}()@'`"
    stem = "".join(ch for ch in stem.upper() if ch in allowed) or "FILE"
    ext = "".join(ch for ch in ext.upper() if ch in allowed)
    return stem[:8].ljust(8).encode("ascii") + ext[:3].ljust(3).encode("ascii")


def alias_from_long(name: str, is_dir: bool, used: set[bytes]) -> bytes:
    if not is_dir and "." in name:
        stem, ext = name.rsplit(".", 1)
    else:
        stem, ext = name, ""
    base = "".join(ch for ch in stem.upper() if ch.isalnum())
    ext_clean = "".join(ch for ch in ext.upper() if ch.isalnum())
    if not base:
        base = "ITEM"
    for n in range(1, 100):
        suffix = f"~{n}"
        candidate = (base[: 8 - len(suffix)] + suffix).ljust(8).encode("ascii")
        short = candidate + ext_clean[:3].ljust(3).encode("ascii")
        if short not in used:
            return short
    raise RuntimeError(f"no short alias for {name!r}")


def fits_83(name: str) -> bool:
    if name in (".", ".."):
        return True
    if name.count(".") > 1:
        return False
    if "." in name:
        stem, ext = name.rsplit(".", 1)
    else:
        stem, ext = name, ""
    return (
        1 <= len(stem) <= 8
        and len(ext) <= 3
        and sanitize_short(stem, ext).decode("ascii").rstrip()
        == (stem.upper().ljust(8) + ext.upper().ljust(3))
    )


def lfn_entries(name: str, short_name: bytes) -> list[bytes]:
    chars = [ord(c) for c in name]
    chars.append(0)
    while len(chars) % 13:
        chars.append(0xFFFF)
    chunks = [chars[i : i + 13] for i in range(0, len(chars), 13)]
    chk = short_checksum(short_name)
    entries: list[bytes] = []
    for i in range(len(chunks), 0, -1):
        chunk = chunks[i - 1]
        ent = bytearray(32)
        ent[0] = i | (0x40 if i == len(chunks) else 0)
        ent[11] = ATTR_LFN
        ent[13] = chk
        positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for pos, code in zip(positions, chunk):
            put16(ent, pos, code)
        entries.append(bytes(ent))
    return entries


class Fat32Image:
    def __init__(self, path: Path):
        self.path = path
        self.data = bytearray(path.read_bytes())
        self.bps = le16(self.data, 11)
        self.spc = self.data[13]
        self.reserved = le16(self.data, 14)
        self.fats = self.data[16]
        self.total_sectors = le32(self.data, 32)
        self.fat_size = le32(self.data, 36)
        self.root_cluster = le32(self.data, 44)
        self.first_data_sector = self.reserved + self.fats * self.fat_size
        self.cluster_size = self.bps * self.spc
        if self.bps != 512 or self.spc == 0 or self.fat_size == 0:
            raise RuntimeError("unsupported/non-FAT32 image")

    def cluster_offset(self, cluster: int) -> int:
        sector = self.first_data_sector + (cluster - 2) * self.spc
        return sector * self.bps

    def fat_offset(self, cluster: int, fat_index: int = 0) -> int:
        return (self.reserved + fat_index * self.fat_size) * self.bps + cluster * 4

    def get_fat(self, cluster: int) -> int:
        return le32(self.data, self.fat_offset(cluster)) & 0x0FFFFFFF

    def set_fat(self, cluster: int, value: int) -> None:
        for fat in range(self.fats):
            put32(self.data, self.fat_offset(cluster, fat), value)

    def cluster_chain(self, start: int) -> list[int]:
        chain = []
        cur = start
        while cur >= 2 and cur < 0x0FFFFFF8:
            chain.append(cur)
            nxt = self.get_fat(cur)
            if nxt >= 0x0FFFFFF8:
                break
            cur = nxt
        return chain

    def read_chain(self, start: int) -> bytes:
        return b"".join(
            bytes(self.data[self.cluster_offset(c) : self.cluster_offset(c) + self.cluster_size])
            for c in self.cluster_chain(start)
        )

    def allocate_clusters(self, count: int) -> list[int]:
        max_clusters = (self.total_sectors - self.first_data_sector) // self.spc + 2
        found: list[int] = []
        for c in range(2, max_clusters):
            if self.get_fat(c) == 0:
                found.append(c)
                if len(found) == count:
                    break
        if len(found) != count:
            raise RuntimeError("not enough free clusters")
        for idx, c in enumerate(found):
            self.set_fat(c, found[idx + 1] if idx + 1 < len(found) else EOC)
            off = self.cluster_offset(c)
            self.data[off : off + self.cluster_size] = b"\x00" * self.cluster_size
        return found

    def parse_dir(self, cluster: int) -> list[dict]:
        raw = self.read_chain(cluster)
        entries = []
        lfn_parts: list[bytes] = []
        lfn_start_index = 0
        for idx in range(0, len(raw), 32):
            ent = raw[idx : idx + 32]
            first = ent[0]
            if first == 0x00:
                break
            if first == 0xE5:
                lfn_parts = []
                continue
            attr = ent[11]
            if attr == ATTR_LFN:
                if not lfn_parts:
                    lfn_start_index = idx // 32
                lfn_parts.append(ent)
                continue
            short = ent[:11]
            long_name = None
            if lfn_parts:
                pieces = []
                for lp in reversed(lfn_parts):
                    for pos in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]:
                        code = struct.unpack_from("<H", lp, pos)[0]
                        if code == 0:
                            break
                        if code != 0xFFFF:
                            pieces.append(chr(code))
                long_name = "".join(pieces)
            entries.append(
                {
                    "index": idx // 32,
                    "lfn_start": lfn_start_index if lfn_parts else idx // 32,
                    "entries": (idx // 32) - (lfn_start_index if lfn_parts else idx // 32) + 1,
                    "short": short,
                    "name": long_name or self.short_to_name(short),
                    "attr": attr,
                    "cluster": (le16(bytearray(ent), 20) << 16) | le16(bytearray(ent), 26),
                    "size": le32(bytearray(ent), 28),
                }
            )
            lfn_parts = []
        return entries

    @staticmethod
    def short_to_name(short: bytes) -> str:
        stem = short[:8].decode("ascii", errors="ignore").rstrip()
        ext = short[8:11].decode("ascii", errors="ignore").rstrip()
        return f"{stem}.{ext}" if ext else stem

    def find_entry(self, dir_cluster: int, name: str) -> dict | None:
        target = name.upper()
        for ent in self.parse_dir(dir_cluster):
            if ent["name"].upper() == target or self.short_to_name(ent["short"]).upper() == target:
                return ent
        return None

    def mark_deleted(self, dir_cluster: int, entry: dict) -> None:
        for i in range(entry["entries"]):
            self.write_dir_byte(dir_cluster, (entry["lfn_start"] + i) * 32, 0xE5)

    def free_chain(self, start: int) -> None:
        if start < 2:
            return
        for cluster in self.cluster_chain(start):
            self.set_fat(cluster, 0)

    def write_dir_byte(self, dir_cluster: int, rel_off: int, value: int) -> None:
        chain = self.cluster_chain(dir_cluster)
        cluster_index = rel_off // self.cluster_size
        off_in_cluster = rel_off % self.cluster_size
        off = self.cluster_offset(chain[cluster_index]) + off_in_cluster
        self.data[off] = value

    def find_free_dir_slots(self, dir_cluster: int, needed: int) -> int:
        chain = self.cluster_chain(dir_cluster)
        while True:
            raw = self.read_chain(dir_cluster)
            run = 0
            start = 0
            for idx in range(0, len(raw), 32):
                first = raw[idx]
                if first in (0x00, 0xE5):
                    if run == 0:
                        start = idx // 32
                    run += 1
                    if run >= needed:
                        return start
                else:
                    run = 0
            new_cluster = self.allocate_clusters(1)[0]
            self.set_fat(chain[-1], new_cluster)
            self.set_fat(new_cluster, EOC)
            chain.append(new_cluster)

    def write_dir_entries(self, dir_cluster: int, slot: int, entries: list[bytes]) -> None:
        chain = self.cluster_chain(dir_cluster)
        rel = slot * 32
        for ent in entries:
            ci = rel // self.cluster_size
            co = rel % self.cluster_size
            off = self.cluster_offset(chain[ci]) + co
            self.data[off : off + 32] = ent
            rel += 32

    def used_short_names(self, dir_cluster: int) -> set[bytes]:
        return {ent["short"] for ent in self.parse_dir(dir_cluster)}

    def make_short_entry(self, short_name: bytes, attr: int, first_cluster: int, size: int) -> bytes:
        ent = bytearray(32)
        ent[:11] = short_name
        ent[11] = attr
        put16(ent, 20, (first_cluster >> 16) & 0xFFFF)
        put16(ent, 26, first_cluster & 0xFFFF)
        put32(ent, 28, size)
        return bytes(ent)

    def ensure_dir(self, parent_cluster: int, name: str) -> int:
        existing = self.find_entry(parent_cluster, name)
        if existing:
            if existing["attr"] & ATTR_DIRECTORY:
                return existing["cluster"]
            raise RuntimeError(f"{name} exists but is not a directory")
        cluster = self.allocate_clusters(1)[0]
        dot = self.make_short_entry(b".          ", ATTR_DIRECTORY, cluster, 0)
        dotdot = self.make_short_entry(b"..         ", ATTR_DIRECTORY, parent_cluster, 0)
        off = self.cluster_offset(cluster)
        self.data[off : off + 64] = dot + dotdot
        used = self.used_short_names(parent_cluster)
        short = sanitize_short(name) if fits_83(name) else alias_from_long(name, True, used)
        entries = ([] if fits_83(name) else lfn_entries(name, short)) + [
            self.make_short_entry(short, ATTR_DIRECTORY, cluster, 0)
        ]
        slot = self.find_free_dir_slots(parent_cluster, len(entries))
        self.write_dir_entries(parent_cluster, slot, entries)
        return cluster

    def write_file(self, dir_cluster: int, name: str, src: Path) -> None:
        existing = self.find_entry(dir_cluster, name)
        if existing:
            self.free_chain(existing["cluster"])
            self.mark_deleted(dir_cluster, existing)
        payload = src.read_bytes()
        clusters_needed = max(1, (len(payload) + self.cluster_size - 1) // self.cluster_size)
        clusters = self.allocate_clusters(clusters_needed)
        pos = 0
        for c in clusters:
            off = self.cluster_offset(c)
            chunk = payload[pos : pos + self.cluster_size]
            self.data[off : off + len(chunk)] = chunk
            pos += len(chunk)
        used = self.used_short_names(dir_cluster)
        if fits_83(name):
            if "." in name:
                stem, ext = name.rsplit(".", 1)
            else:
                stem, ext = name, ""
            short = sanitize_short(stem, ext)
        else:
            short = alias_from_long(name, False, used)
        entries = ([] if fits_83(name) else lfn_entries(name, short)) + [
            self.make_short_entry(short, ATTR_ARCHIVE, clusters[0], len(payload))
        ]
        slot = self.find_free_dir_slots(dir_cluster, len(entries))
        self.write_dir_entries(dir_cluster, slot, entries)

    def save(self) -> None:
        self.path.write_bytes(self.data)


def prepare_host_package(root: Path) -> list[Path]:
    package_dir = root / "Build" / "SD" / "Games" / "Zuma Deluxe VDAC2"
    package_dir.mkdir(parents=True, exist_ok=True)
    stale_nested_pak = package_dir / "ZUMALVL.PAK"
    if stale_nested_pak.exists():
        stale_nested_pak.unlink()
    files = [
        (root / "Build" / "zuma_vdac2.spg", package_dir / "ZUMA_VD2.SPG"),
        (root / "Build" / "ZUMAMAIN.PAK", package_dir / "ZUMAMAIN.PAK"),
        (root / "Build" / "ZUMALVL.PAK", package_dir / "ZUMALVL.PAK"),
        (root / "Build" / "ZUMAAUD.PAK", package_dir / "ZUMAAUD.PAK"),
        (root / "Build" / "ZUMASND.PAK", package_dir / "ZUMASND.PAK"),
        (root / "spgbld_boot.ini", package_dir / "SPGBLD.INI"),
        (root / "Build" / "zuma.sym", package_dir / "ZUMA.SYM"),
    ]
    for src, dst in files:
        if src.exists():
            shutil.copy2(src, dst)
    (package_dir / "README.TXT").write_text(
        "Zuma Deluxe VDAC2\n"
        "Folder for ZX Evolution / Wild Commander delivery.\n"
        "Run ZUMA_VD2.SPG. Main pack is ZUMAMAIN.PAK; level pack is ZUMALVL.PAK; GS packs are ZUMAAUD.PAK/ZUMASND.PAK.\n",
        encoding="ascii",
    )
    return sorted(dst for _, dst in files if dst.exists()) + [package_dir / "README.TXT"]


def main() -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Update Zuma files inside an existing FAT32 wc.img in-place. "
            "This tool must never copy or replace the whole disk image."
        )
    )
    ap.add_argument("--base-img", default=r"\\tsclient\D\Работа.Андрей\unreal_x64\wc.img")
    ap.add_argument("--out-img", default=None)
    args = ap.parse_args()

    root = Path.cwd()
    base_img = Path(args.base_img)
    out_arg = Path(args.out_img) if args.out_img else base_img
    out_img = out_arg if out_arg.is_absolute() else root / out_arg
    base_norm = os.path.normcase(os.path.abspath(str(base_img)))
    out_norm = os.path.normcase(os.path.abspath(str(out_img)))
    if base_norm != out_norm:
        raise SystemExit(
            "REFUSING full image replacement: --base-img and --out-img differ. "
            "Use the same path and update the existing wc.img in-place."
        )
    if not out_img.exists():
        raise SystemExit(f"REFUSING to create a new image: {out_img}")

    image = Fat32Image(out_img)
    package_files = prepare_host_package(root)
    games = image.ensure_dir(image.root_cluster, "Games")
    zuma = image.ensure_dir(games, "Zuma Deluxe VDAC2")
    for file in package_files:
        image.write_file(zuma, file.name, file)
    root_pak = root / "Build" / "ZUMALVL.PAK"
    old_root_pak = image.find_entry(image.root_cluster, "ZUMALVL.PAK")
    if old_root_pak:
        image.free_chain(old_root_pak["cluster"])
        image.mark_deleted(image.root_cluster, old_root_pak)
    image.save()

    print(f"image: {out_img} (in-place)")
    print("folder: /Games/Zuma Deluxe VDAC2/")
    for file in package_files:
        print(f"  {file.name} {file.stat().st_size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
