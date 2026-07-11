#!/usr/bin/env python3
"""Z80 regression for Track V4 compatibility decode and direct cache emit."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import encode_track_v4_record  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
TRACK_PAGE = 0x06
CACHE = 0x4100
CMD = 0x4CB0
CACHE_FILL = 0xCC
WIN_SENTINEL = 0xBEEF


def signed_word(value: int) -> int:
    return value & 0xFFFF


def setup_track_records(emu: ZumaFullZ80Emulator, records: dict[int, bytes]) -> None:
    sym = emu.sym
    start = TRACK_PAGE * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = bytes(PAGE_SIZE)
    for sample, record in records.items():
        if not 0 <= sample < PAGE_SIZE // 8:
            raise AssertionError(f"sample {sample} is outside the synthetic track page")
        offset = start + sample * 8
        emu.mem.physical[offset : offset + 8] = record
    emu.mem.pages = [0x00, 0x05, TRACK_PAGE, 0x04]
    emu.set_byte(sym["Core.VDC_TrackPages1"], TRACK_PAGE)
    emu.set_word(sym["Core.VDC_pTrackPages"], sym["Core.VDC_TrackPages1"])
    emu.set_byte(sym["Core.VDC_RenderTrackPageIdx"], 0xFF)


def setup_track_record(emu: ZumaFullZ80Emulator, record: bytes) -> None:
    setup_track_records(emu, {0: record})


def check_compatibility_reader(vx: int, vy: int) -> None:
    emu = ZumaFullZ80Emulator(ROOT)
    record = encode_track_v4_record(vx, vy, 0xA5, 0x83, 7)
    setup_track_record(emu, record)
    emu.call(emu.sym["Core.VDC_ReadRenderSampleAtHL_Slot0"], h=0, l=0, max_steps=100_000)
    got_x = (emu.reg.B << 8) | emu.reg.C
    got_y = (emu.reg.D << 8) | emu.reg.E
    if got_x != signed_word(vx) or got_y != signed_word(vy):
        raise AssertionError(
            f"reader ({vx},{vy}) -> ({got_x:#06x},{got_y:#06x})"
        )
    if emu.get_byte(emu.sym["Core.VDC_LastTrackFlags"]) != 0x83:
        raise AssertionError("reader lost flags")


def check_cached_emit_and_decode(vx: int, vy: int) -> None:
    emu = ZumaFullZ80Emulator(ROOT)
    record = encode_track_v4_record(vx, vy, 0, 0, 0)
    for index, value in enumerate(record[:4]):
        emu.mem.write(CACHE + 2 + index, value)
    emu.reg.IX = CACHE
    emu.set_word(emu.sym["FT.Coprocessor.BufferPtr"], CMD)
    emu.call(emu.sym["Core.ZL_EmitCachedVertex2f"], max_steps=100_000)
    got = bytes(emu.get_memory(CMD, 4))
    if got != record[:4]:
        raise AssertionError(f"cached emit ({vx},{vy}): {got.hex()} != {record[:4].hex()}")
    if emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"]) != CMD + 4:
        raise AssertionError("cached emit advanced BufferPtr incorrectly")

    emu.mem.write(CACHE + 1, 0xFE)
    emu.reg.IX = CACHE
    emu.set_word(emu.sym["FT.Coprocessor.BufferPtr"], CMD)
    emu.call(emu.sym["Core.ZL_EmitCachedCellVertex"], max_steps=100_000)
    expected = bytes((0x7E, 0x00, 0x00, 0x06)) + record[:4]
    got = bytes(emu.get_memory(CMD, 8))
    if got != expected:
        raise AssertionError(
            f"cached CELL+VERTEX2F ({vx},{vy}): {got.hex()} != {expected.hex()}"
        )
    if emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"]) != CMD + 8:
        raise AssertionError("cached CELL+VERTEX2F advanced BufferPtr incorrectly")

    emu.reg.IX = CACHE
    emu.call(emu.sym["Core.ZL_DecodeCachedVertex2f"], max_steps=100_000)
    got_x = (emu.reg.B << 8) | emu.reg.C
    got_y = (emu.reg.D << 8) | emu.reg.E
    if got_x != signed_word(vx) or got_y != signed_word(vy):
        raise AssertionError(
            f"cache decode ({vx},{vy}) -> ({got_x:#06x},{got_y:#06x})"
        )


def win_oracle(emu: ZumaFullZ80Emulator) -> int | None:
    sym = emu.sym
    slots_len = emu.get_byte(sym["Core.VDC_SlotsLen"])
    slots = emu.get_word(sym["Core.VDC_pSlots"])
    samples = emu.get_word(sym["Core.VDC_ActiveTrackSamples"])
    found: list[int] = []
    for index in range(slots_len):
        if emu.get_byte(slots + index) >= 6:
            continue
        emu.call(sym["Core.VDC_SlotT"], a=index, max_steps=100_000)
        track_t = (emu.reg.H << 8) | emu.reg.L
        if track_t & 0x8000:
            continue
        found.append(min(track_t, samples - 1))
    return max(found) if found else None


def live_cache_entry(color: int, record: bytes) -> bytes:
    tangent = (record[4] + 0x08) & 0xF0
    cell = color * 12 + record[6]
    return bytes((tangent, cell)) + record[:4] + bytes((record[5],))


def marked_cache_entry() -> bytes:
    return bytes((0, 0xFF)) + bytes((CACHE_FILL,)) * 5


def check_builder_case(
    name: str,
    *,
    slots: list[int],
    offsets: list[int],
    hsa: int,
    hsub: int,
    records: dict[int, bytes],
    expected_cache: bytes,
) -> None:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    setup_track_records(emu, records)

    emu.set_word(sym["Core.VDC_pSlots"], sym["Core.VDC_Slots"])
    emu.set_word(sym["Core.VDC_pOffsets"], sym["Core.VDC_Offsets"])
    emu.set_byte(sym["Core.VDC_SlotsLen"], len(slots))
    for index, (slot, offset) in enumerate(zip(slots, offsets, strict=True)):
        emu.set_byte(sym["Core.VDC_Slots"] + index, slot)
        emu.set_byte(sym["Core.VDC_Offsets"] + index, offset & 0xFF)
    emu.set_byte(sym["Core.VDC_HSA"], hsa)
    emu.set_byte(sym["Core.VDC_HSub"], hsub)
    emu.set_word(sym["Core.VDC_ActiveTrackSamples"], max(records, default=0) + 1)
    emu.set_byte(sym["Core.VDC_HasSecondChain"], 0)
    emu.set_byte(sym["Core.VDC_GameState"], 0)
    emu.set_byte(sym["Core.VDC_SecondActive"], 0)
    emu.set_byte(sym["Core.CurrentLevel"], 0)
    emu.set_word(sym["Core.ZL_CacheBasePtr"], CACHE)
    emu.set_word(sym["Core.VDC_WinHeadS1"], WIN_SENTINEL)
    for index in range(len(expected_cache)):
        emu.mem.write(CACHE + index, CACHE_FILL)

    expected_win = win_oracle(emu)

    sp_before = emu.reg.SP
    tstates_before = emu.tstates
    emu.call(sym["Core.ZL_BuildActiveChainCache"], max_steps=500_000)
    if emu.reg.SP != sp_before:
        raise AssertionError(
            f"{name}: cache builder unbalanced SP: {emu.reg.SP:#06x} != {sp_before:#06x}"
        )

    got = bytes(emu.get_memory(CACHE, len(expected_cache)))
    if got != expected_cache:
        raise AssertionError(f"{name}: cache {got.hex()} != {expected_cache.hex()}")
    actual_win = emu.get_word(sym["Core.VDC_WinHeadS1"])
    wanted_win = WIN_SENTINEL if expected_win is None else expected_win
    if actual_win != wanted_win:
        raise AssertionError(
            f"{name}: WIN head {actual_win:#06x} != oracle {wanted_win:#06x}"
        )
    print(f"PASS: builder {name}: {emu.tstates - tstates_before} T, cache/SP/WIN exact")


def check_builder_cache_records() -> None:
    visible = encode_track_v4_record(320, 464, 0x35, 0xA6, 7)
    invisible = encode_track_v4_record(20000, 464, 0x6B, 0x5D, 9)
    borrow = encode_track_v4_record(640, 704, 0x92, 0x3C, 11)

    check_builder_case(
        "visible flags/spin",
        slots=[4],
        offsets=[0],
        hsa=0,
        hsub=0,
        records={0: visible},
        expected_cache=live_cache_entry(4, visible),
    )
    check_builder_case(
        "gap without saved stack state",
        slots=[0xFF],
        offsets=[0],
        hsa=0,
        hsub=0,
        records={0: visible},
        expected_cache=marked_cache_entry(),
    )
    check_builder_case(
        "negative t",
        slots=[2],
        offsets=[-1],
        hsa=0,
        hsub=0,
        records={0: visible},
        expected_cache=marked_cache_entry(),
    )
    check_builder_case(
        "Track V4 metadata cull",
        slots=[3],
        offsets=[0],
        hsa=0,
        hsub=0,
        records={0: invisible},
        expected_cache=marked_cache_entry(),
    )
    check_builder_case(
        "BaseT low-byte borrow",
        slots=[4, 5],
        offsets=[0, 0],
        hsa=0,
        hsub=1,
        records={1: borrow},
        expected_cache=live_cache_entry(4, borrow) + marked_cache_entry(),
    )


def main() -> int:
    compatibility_cases = (
        (-0x8000, -0x8000),
        (-2496, -1616),
        (-832, -832),
        (-1, -1),
        (0, 0),
        (12287, 12288),
        (16383, 16384),
        (17424, 12512),
        (0x7FFF, 0x7FFF),
    )
    for vx, vy in compatibility_cases:
        check_compatibility_reader(vx, vy)

    visible_cases = ((-832, -832), (-1, -1), (0, 0), (12287, 12287), (16383, 0))
    for vx, vy in visible_cases:
        check_cached_emit_and_decode(vx, vy)

    check_builder_cache_records()

    print("PASS: Track V4 reader, cache builder, direct emit, and visible decode are exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
