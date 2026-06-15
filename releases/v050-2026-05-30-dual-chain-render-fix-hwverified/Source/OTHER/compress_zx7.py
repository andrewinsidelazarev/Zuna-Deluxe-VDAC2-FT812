#!/usr/bin/env python3
"""
Small ZX7-compatible packer for local PoC work.

It is intentionally simple, not optimal like Einar Saukas' original compressor.
It emits valid ZX7 streams using literals and matches with distance <= 128,
which keeps the offset encoder small and is enough to validate the Z80 depacker.
"""
from __future__ import annotations

import argparse
from pathlib import Path


def gamma_bits(value: int) -> list[int]:
    if value <= 0:
        raise ValueError("gamma value must be positive")
    bits = [int(ch) for ch in bin(value)[2:]]
    return [0] * (len(bits) - 1) + [1] + bits[1:]


class BitWriter:
    def __init__(self, out: bytearray) -> None:
        self.out = out
        self.ctrl_pos: int | None = None
        self.mask = 0

    def _reserve(self) -> None:
        self.ctrl_pos = len(self.out)
        self.out.append(0)
        self.mask = 0x80

    def bit(self, value: int) -> None:
        if self.ctrl_pos is None or self.mask == 0:
            self._reserve()
        if value:
            self.out[self.ctrl_pos] |= self.mask
        self.mask >>= 1

    def bits(self, values: list[int]) -> None:
        for value in values:
            self.bit(value)


def find_match(data: bytes, pos: int) -> tuple[int, int]:
    best_len = 0
    best_dist = 0
    max_dist = min(128, pos)
    max_len = min(255, len(data) - pos)
    for dist in range(1, max_dist + 1):
        start = pos - dist
        ln = 0
        while ln < max_len and data[start + ln] == data[pos + ln]:
            ln += 1
            # ZX7 can copy overlapping matches, so source may run into output.
            if start + ln >= pos and dist == 0:
                break
        if ln > best_len:
            best_len = ln
            best_dist = dist
    if best_len < 3:
        return 0, 0
    return best_len, best_dist


def compress(data: bytes) -> bytes:
    if not data:
        raise ValueError("ZX7 stream cannot be empty")

    out = bytearray()
    out.append(data[0])
    bits = BitWriter(out)
    pos = 1

    while pos < len(data):
        ln, dist = find_match(data, pos)
        if ln:
            bits.bit(1)
            bits.bits(gamma_bits(ln - 1))
            out.append(dist - 1)
            pos += ln
        else:
            bits.bit(0)
            out.append(data[pos])
            pos += 1

    # End marker: force 16-bit gamma length overflow in the standard ZX7 decoder.
    bits.bit(1)
    bits.bits([0] * 16 + [1] + [0] * 16)
    return bytes(out)


def decompress_zx7(data: bytes) -> bytes:
    src = 0
    dst = bytearray()
    bit_acc = 0x80

    def read_bit() -> int:
        nonlocal src, bit_acc
        carry_in = 1 if bit_acc & 0x80 else 0
        bit_acc = (bit_acc << 1) & 0xFF
        if bit_acc == 0:
            value = data[src]
            src += 1
            carry_out = 1 if value & 0x80 else 0
            bit_acc = ((value << 1) & 0xFF) | carry_in
            return carry_out
        return carry_in

    dst.append(data[src])
    src += 1

    while True:
        if read_bit() == 0:
            dst.append(data[src])
            src += 1
            continue

        zeros = 0
        while read_bit() == 0:
            zeros += 1

        value = 1
        for _ in range(zeros):
            value = (value << 1) | read_bit()
            if value > 0xFFFF:
                return bytes(dst)
        length = value + 1

        offset = data[src]
        src += 1
        if offset & 0x80:
            raise ValueError("lite decoder only expects <=128 byte offsets")
        distance = offset + 1
        for _ in range(length):
            dst.append(dst[-distance])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()

    raw = args.input.read_bytes()
    packed = compress(raw)
    if decompress_zx7(packed) != raw:
        raise SystemExit("internal round-trip failed")
    args.output.write_bytes(packed)
    print(f"{args.input.name}: {len(raw)} -> {len(packed)} bytes ({len(packed) * 100 / len(raw):.1f}%)")


if __name__ == "__main__":
    main()
