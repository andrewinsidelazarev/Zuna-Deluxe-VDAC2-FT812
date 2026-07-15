#!/usr/bin/env python3
"""Regression for RawPak_StoreLfn bounds in the real Z80 overlay.

RawPak_EntName is 64 bytes.  A FAT LFN fragment contributes 13 characters at
``(sequence - 1) * 13``.  Sequence 5 already reaches byte 64 and sequence 6
starts beyond the buffer.  Those names are not representable by this loader:
the fragment must leave adjacent state untouched and invalidate HaveLfn so the
following short entry falls back to its bounded 8.3 name.

The test also verifies the positive boundary: sequences 1..4 retain their
original placement and uppercase conversion.
"""

from __future__ import annotations

import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


LOADER_PAGE = 0x40
LFN_ENTRY = 0x8000
LFN_CHAR_OFFSETS = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
CANARY = 0xA5
NAME_FILL = 0xCC
WIDE_GUARD_SIZE = 4096


def set_ix(emu: ZumaFullZ80Emulator, value: int) -> None:
    if hasattr(emu.reg, "IX"):
        emu.reg.IX = value & 0xFFFF
    else:
        emu.reg.IXH = (value >> 8) & 0xFF
        emu.reg.IXL = value & 0xFF


def exercise_invalid(sequence: int) -> tuple[bool, bool, bool, int]:
    emu = ZumaFullZ80Emulator()
    emu.mem.pages[3] = LOADER_PAGE
    sym = emu.sym
    ent_name = sym["Core.RawPak_EntName"]
    have_lfn = sym["Core.RawPak_HaveLfn"]
    adjacent = ent_name + 64

    # Guard a deliberately wide part of loader state after EntName.  The first
    # bytes catch seq=5/6 overwriting CheckSize/FoundSize; the wider tail also
    # catches the old seq=0 underflow, where DEC #00 became #FF and moved HL
    # 255*13 bytes before storing the fragment.
    for offset in range(WIDE_GUARD_SIZE):
        emu.set_byte(adjacent + offset, CANARY)
    for offset in range(64):
        emu.set_byte(ent_name + offset, NAME_FILL)
    emu.set_byte(have_lfn, 1)  # invalid fragment must actively poison the chain

    emu.set_byte(LFN_ENTRY, sequence & 0x1F)
    for index, offset in enumerate(LFN_CHAR_OFFSETS):
        emu.set_byte(LFN_ENTRY + offset, ord("a") + index)

    set_ix(emu, LFN_ENTRY)
    emu.call(sym["Core.RawPak_StoreLfn"], max_steps=100_000)

    expected = bytearray([CANARY]) * WIDE_GUARD_SIZE
    expected[have_lfn - adjacent] = 0xFF
    actual = emu.get_memory(adjacent, WIDE_GUARD_SIZE)
    guard_clean = actual == expected
    name_untouched = emu.get_memory(ent_name, 64) == bytes([NAME_FILL]) * 64
    invalidated = emu.get_byte(have_lfn) == 0xFF
    changed = sum(
        actual_byte != expected_byte
        for actual_byte, expected_byte in zip(actual, expected)
    )
    return guard_clean, name_untouched, invalidated, changed


def exercise_poisoned_chain() -> tuple[bool, bool, bool]:
    """An overlong first fragment poisons all following valid-looking pieces.

    FAT stores a long name in descending on-disk order.  Therefore an
    overlong name normally appears as seq=5|LAST, then seq=4,3,2,1.  Merely
    rejecting seq=5 is insufficient: seq=4 must not restore HaveLfn=1 and turn
    the incomplete tail into an apparently valid name.
    """

    emu = ZumaFullZ80Emulator()
    emu.mem.pages[3] = LOADER_PAGE
    sym = emu.sym
    ent_name = sym["Core.RawPak_EntName"]
    have_lfn = sym["Core.RawPak_HaveLfn"]
    adjacent = ent_name + 64

    for offset in range(64):
        emu.set_byte(ent_name + offset, NAME_FILL)
        emu.set_byte(adjacent + offset, CANARY)
    emu.set_byte(have_lfn, 0)

    for sequence_byte in (0x45, 4, 3, 2, 1):
        emu.set_byte(LFN_ENTRY, sequence_byte)
        for index, offset in enumerate(LFN_CHAR_OFFSETS):
            emu.set_byte(LFN_ENTRY + offset, ord("a") + index)
        set_ix(emu, LFN_ENTRY)
        emu.call(sym["Core.RawPak_StoreLfn"], max_steps=100_000)

    expected_guard = bytearray([CANARY]) * 64
    expected_guard[have_lfn - adjacent] = 0xFF
    name_untouched = emu.get_memory(ent_name, 64) == bytes([NAME_FILL]) * 64
    guard_clean = emu.get_memory(adjacent, 64) == expected_guard
    remains_poisoned = emu.get_byte(have_lfn) == 0xFF
    return name_untouched, guard_clean, remains_poisoned


def exercise_valid(sequence: int) -> tuple[bool, bool, bool]:
    """Run one representable fragment and verify its exact 13-byte window."""

    emu = ZumaFullZ80Emulator()
    emu.mem.pages[3] = LOADER_PAGE
    sym = emu.sym
    ent_name = sym["Core.RawPak_EntName"]
    have_lfn = sym["Core.RawPak_HaveLfn"]
    adjacent = ent_name + 64

    for offset in range(64):
        emu.set_byte(ent_name + offset, NAME_FILL)
        emu.set_byte(adjacent + offset, CANARY)
    emu.set_byte(have_lfn, 0)

    # LAST_LONG_ENTRY (#40) shares the sequence byte.  Add it to the highest
    # valid sequence to prove the mask still preserves normal FAT encoding.
    sequence_byte = sequence | (0x40 if sequence == 4 else 0)
    emu.set_byte(LFN_ENTRY, sequence_byte)
    for index, offset in enumerate(LFN_CHAR_OFFSETS):
        emu.set_byte(LFN_ENTRY + offset, ord("a") + index)

    set_ix(emu, LFN_ENTRY)
    emu.call(sym["Core.RawPak_StoreLfn"], max_steps=100_000)

    expected_name = bytearray([NAME_FILL]) * 64
    start = (sequence - 1) * 13
    expected_name[start : start + 13] = b"ABCDEFGHIJKLM"
    name_ok = emu.get_memory(ent_name, 64) == expected_name

    expected_guard = bytearray([CANARY]) * 64
    expected_guard[have_lfn - adjacent] = 1
    guard_clean = emu.get_memory(adjacent, 64) == expected_guard
    marked_valid = emu.get_byte(have_lfn) == 1
    return name_ok, guard_clean, marked_valid


def main() -> int:
    failed = False
    for sequence in (0, 5, 6, 31):
        guard_clean, name_untouched, invalidated, changed = exercise_invalid(sequence)
        ok = guard_clean and name_untouched and invalidated
        failed |= not ok
        print(
            f"{'PASS' if ok else 'FAIL'}: LFN seq={sequence} rejected "
            f"without EntName overflow: adjacent_changed={changed} "
            f"EntName_untouched={name_untouched} HaveLfn_invalidated={invalidated}",
            flush=True,
        )

    for sequence in (1, 2, 3, 4):
        name_ok, guard_clean, marked_valid = exercise_valid(sequence)
        ok = name_ok and guard_clean and marked_valid
        failed |= not ok
        print(
            f"{'PASS' if ok else 'FAIL'}: LFN seq={sequence} stored in bounded window: "
            f"name_ok={name_ok} adjacent_clean={guard_clean} "
            f"HaveLfn_set={marked_valid}",
            flush=True,
        )

    name_untouched, guard_clean, remains_poisoned = exercise_poisoned_chain()
    ok = name_untouched and guard_clean and remains_poisoned
    failed |= not ok
    print(
        f"{'PASS' if ok else 'FAIL'}: LFN seq=5->4->3->2->1 remains rejected: "
        f"EntName_untouched={name_untouched} adjacent_clean={guard_clean} "
        f"HaveLfn_poisoned={remains_poisoned}",
        flush=True,
    )

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
