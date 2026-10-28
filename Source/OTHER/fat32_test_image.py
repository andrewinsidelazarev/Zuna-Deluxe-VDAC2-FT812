#!/usr/bin/env python3
"""Клод: образ SD-карты в памяти для проверок FAT32-драйвера игры.

MBR с разделом FAT32 LBA (#0C), две копии FAT, FSInfo, длинные имена (LFN),
файлы можно класть заданными цепочками кластеров (фрагментация). Образ —
bytearray; сектор читается card.sector(lba).
"""
from __future__ import annotations

import struct

SECTOR = 512
EOC = 0x0FFFFFFF


def _lfn_checksum(short: bytes) -> int:
    s = 0
    for b in short:
        s = (((s & 1) << 7) + (s >> 1) + b) & 0xFF
    return s


def _fits_83(name: str) -> bool:
    stem, _, ext = name.partition(".")
    ok = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$~!#%&-{}()@'`")
    return (1 <= len(stem) <= 8 and len(ext) <= 3 and "." not in ext
            and all(c in ok for c in stem.upper() + ext.upper()))


class Card:
    def __init__(self, spc: int = 8, clusters: int = 5000, part: int = 2048) -> None:
        self.spc, self.clusters, self.part = spc, clusters, part
        self.reserved, self.fats = 32, 2
        self.fat_sectors = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        self.total = self.reserved + self.fats * self.fat_sectors + clusters * spc
        self.data_start = part + self.reserved + self.fats * self.fat_sectors
        self.image = bytearray((part + self.total) * SECTOR)
        self.fat = [0] * (clusters + 2)
        self.fat[0], self.fat[1] = 0x0FFFFFF8, EOC
        self.next_free = 2
        self.root = self.alloc_chain(1)
        self.dirs: dict[int, list[bytes]] = {self.root: []}
        self.parent: dict[int, int] = {self.root: 0}

    def sector(self, lba: int) -> bytes:
        return bytes(self.image[lba * SECTOR:(lba + 1) * SECTOR])

    def alloc(self) -> int:
        c = self.next_free
        assert c < self.clusters + 2, "том полон"
        self.next_free += 1
        return c

    def alloc_chain(self, n: int) -> int:
        chain = [self.alloc() for _ in range(n)]
        self._link(chain)
        return chain[0]

    def _link(self, chain: list[int]) -> None:
        for a, b in zip(chain, chain[1:]):
            self.fat[a] = b
        self.fat[chain[-1]] = EOC

    def _write_cluster(self, cluster: int, data: bytes) -> None:
        size = self.spc * SECTOR
        off = (self.data_start + (cluster - 2) * self.spc) * SECTOR
        self.image[off:off + size] = data.ljust(size, b"\0")

    def _short(self, name: str, used: set[bytes]) -> bytes:
        if _fits_83(name):
            stem, _, ext = name.upper().partition(".")
            s = stem.ljust(8).encode() + ext.ljust(3).encode()
            if s not in used:
                return s
        stem, _, ext = name.rpartition(".") if "." in name else (name, "", "")
        base = "".join(c for c in stem.upper() if c.isalnum()) or "ITEM"
        ext = "".join(c for c in ext.upper() if c.isalnum())[:3]
        for n in range(1, 100):
            s = (base[:8 - len(f"~{n}")] + f"~{n}").ljust(8).encode() + ext.ljust(3).encode()
            if s not in used:
                return s
        raise RuntimeError(name)

    def _add(self, parent: int, name: str, attr: int, cluster: int, size: int) -> None:
        used = {e[0:11] for e in self.dirs[parent] if e[11] != 0x0F}
        short = self._short(name, used)
        out = []
        if name.upper() != name or not _fits_83(name):
            units = [ord(ch) for ch in name] + [0]
            while len(units) % 13:
                units.append(0xFFFF)
            parts = [units[i:i + 13] for i in range(0, len(units), 13)]
            chk = _lfn_checksum(short)
            for seq in range(len(parts), 0, -1):
                e = bytearray(32)
                e[0] = seq | (0x40 if seq == len(parts) else 0)
                for i, pos in enumerate((1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)):
                    struct.pack_into("<H", e, pos, parts[seq - 1][i])
                e[11], e[13] = 0x0F, chk
                out.append(bytes(e))
        e = bytearray(32)
        e[0:11] = short
        e[11] = attr
        struct.pack_into("<HHHHHHHI", e, 14, 0x6000, 0x5B5B, 0x5B5B, cluster >> 16,
                         0x6000, 0x5B5B, cluster & 0xFFFF, size)
        out.append(bytes(e))
        self.dirs[parent].extend(out)

    def mkdir(self, parent: int, name: str) -> int:
        c = self.alloc_chain(1)
        self.dirs[c] = []
        self.parent[c] = parent
        self._add(parent, name, 0x10, c, 0)
        return c

    def add_file(self, parent: int, name: str, data: bytes, chain: list[int] | None = None) -> None:
        size = self.spc * SECTOR
        n = max(1, (len(data) + size - 1) // size)
        chain = chain or [self.alloc() for _ in range(n)]
        assert len(chain) == n
        self._link(chain)
        for i, c in enumerate(chain):
            self._write_cluster(c, data[i * size:(i + 1) * size])
        self._add(parent, name, 0x20, chain[0], len(data))

    def finish(self) -> "Card":
        size = self.spc * SECTOR
        for d, entries in self.dirs.items():
            body = b""
            if d != self.root:
                p = self.parent[d]
                p = 0 if p == self.root else p
                for name, cl in ((b".          ", d), (b"..         ", p)):
                    e = bytearray(32)
                    e[0:11], e[11] = name, 0x10
                    struct.pack_into("<H", e, 20, cl >> 16)
                    struct.pack_into("<H", e, 26, cl & 0xFFFF)
                    body += bytes(e)
            body += b"".join(entries)
            assert len(body) < size, "каталог длиннее кластера"
            self._write_cluster(d, body)
        fat = b"".join(struct.pack("<I", v) for v in self.fat).ljust(self.fat_sectors * SECTOR, b"\0")
        for copy in range(self.fats):
            off = (self.part + self.reserved + copy * self.fat_sectors) * SECTOR
            self.image[off:off + len(fat)] = fat
        bpb = bytearray(512)
        bpb[:11] = b"\xEB\x58\x90MSDOS5.0"
        struct.pack_into("<HBHBHHBHHHII", bpb, 11, 512, self.spc, self.reserved, self.fats,
                         0, 0, 0xF8, 0, 63, 255, self.part, self.total)
        struct.pack_into("<IHHIHH", bpb, 36, self.fat_sectors, 0, 0, self.root, 1, 6)
        bpb[64], bpb[66] = 0x80, 0x29
        bpb[71:82], bpb[82:90], bpb[510:512] = b"ZUMA TEST  ", b"FAT32   ", b"\x55\xAA"
        info = bytearray(512)
        struct.pack_into("<I", info, 0, 0x41615252)
        struct.pack_into("<III", info, 484, 0x61417272, self.clusters + 2 - self.next_free, self.next_free)
        info[510:512] = b"\x55\xAA"
        for lba, sec in ((0, bpb), (1, info), (6, bpb), (7, info)):
            off = (self.part + lba) * SECTOR
            self.image[off:off + SECTOR] = sec
        mbr = bytearray(512)
        mbr[446 + 4] = 0x0C
        struct.pack_into("<II", mbr, 446 + 8, self.part, self.total)
        mbr[510:512] = b"\x55\xAA"
        self.image[0:SECTOR] = mbr
        return self
