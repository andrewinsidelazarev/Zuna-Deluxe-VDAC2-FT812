#!/usr/bin/env python3
"""Dual-chain WIN outro regression test.

Each WIN emitter must leave a final explosion exactly at its own kill-zone
sample. The old path marked the emitter done after overshooting the end of the
track, so the last visible explosion could stop several samples before KZ.
"""
from __future__ import annotations

import struct
from pathlib import Path

from make_level_pack import encode_track_v2_pages, scale_track_samples
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CASES = (5, 12, 19)
MODES = ("both", "chain1_early", "chain2_early")
MAX_FRAMES = 260
TRACK_RUNTIME_PAGES = (0x06, 0x0F, 0x10, 0x12)


def load_page_bytes(emu: ZumaFullZ80Emulator, page: int, data: bytes) -> None:
    start = page * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    emu.mem.physical[start : start + len(data)] = data


def track_kz_scaled(path: Path) -> tuple[int, int, int]:
    data = scale_track_samples(path.read_bytes())
    assert data is not None
    samples = struct.unpack_from("<H", data, 0)[0]
    x, y, _tan, _flags = struct.unpack_from("<hhBB", data, 2 + (samples - 1) * 6)
    return samples, x, y


def write_page_table(emu: ZumaFullZ80Emulator, addr: int, pages: list[int]) -> None:
    for idx in range(4):
        emu.set_byte(addr + idx, pages[idx] if idx < len(pages) else 0)


def load_track_v2_pair(emu: ZumaFullZ80Emulator, track1: Path, track2: Path) -> tuple[int, int]:
    first = scale_track_samples(track1.read_bytes())
    second = scale_track_samples(track2.read_bytes())
    assert first is not None and second is not None
    count1, pages1 = encode_track_v2_pages(first)
    count2, pages2 = encode_track_v2_pages(second)
    all_pages = pages1 + pages2
    if len(all_pages) > len(TRACK_RUNTIME_PAGES):
        raise AssertionError(f"test runtime page overflow: {len(all_pages)} pages")

    for page_id, data in zip(TRACK_RUNTIME_PAGES, all_pages):
        load_page_bytes(emu, page_id, data)

    sym = emu.sym
    write_page_table(emu, sym["Core.VDC_TrackPages1"], list(TRACK_RUNTIME_PAGES[: len(pages1)]))
    write_page_table(
        emu,
        sym["Core.VDC_TrackPages2"],
        list(TRACK_RUNTIME_PAGES[len(pages1) : len(pages1) + len(pages2)]),
    )
    emu.set_word(sym["Core.VDC_TrackSamples1"], count1)
    emu.set_word(sym["Core.VDC_TrackSamples2"], count2)
    emu.set_byte(sym["Core.VDC_TrackPageCount1"], len(pages1))
    emu.set_byte(sym["Core.VDC_TrackPageCount2"], len(pages2))
    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=200_000)
    return count1, count2


def gb(emu: ZumaFullZ80Emulator, name: str) -> int:
    return emu.get_byte(emu.sym[name])


def gw(emu: ZumaFullZ80Emulator, name: str) -> int:
    return emu.get_word(emu.sym[name])


def sb(emu: ZumaFullZ80Emulator, name: str, value: int) -> None:
    emu.set_byte(emu.sym[name], value)


def set_chain(emu: ZumaFullZ80Emulator, chain: int, length: int, hsa: int) -> None:
    sym = emu.sym
    if chain == 1:
        sb(emu, "Core.VDC_SlotsLen", length)
        emu.set_word(sym["Core.VDC_HSA"], hsa)
        sb(emu, "Core.VDC_HSub", 0)
        slots = sym["Core.VDC_Slots"]
        offsets = sym["Core.VDC_Offsets"]
        shot2 = sym["Core.VDC_Shot2"]
        exp = sym["Core.VDC_ExplodeFrame"]
        marker = sym["Core.VDC_ExplodeMarker"]
    else:
        sb(emu, "Core.VDC2_SlotsLen", length)
        sb(emu, "Core.VDC2_HSub", 0)
        cl_start = sym["Core.VDC_ChainLocalStart"]
        hsa_off = sym["Core.VDC_HSA"] - cl_start
        emu.set_word(sym["Core.VDC2_ChainLocal"] + hsa_off, hsa)
        slots = sym["Core.VDC2_Slots"]
        offsets = sym["Core.VDC2_Offsets"]
        shot2 = sym["Core.VDC2_Shot2"]
        exp = sym["Core.VDC2_ExplodeFrame"]
        marker = sym["Core.VDC2_ExplodeMarker"]

    for idx in range(length):
        emu.set_byte(slots + idx, idx % 6)
        emu.set_byte(offsets + idx, 0)
        emu.set_byte(shot2 + idx, 0)
        emu.set_byte(exp + idx, 0)
        emu.set_byte(marker + idx, 0)


def has_particle_at(emu: ZumaFullZ80Emulator, x: int, y: int) -> bool:
    base = emu.sym["Core.VDC_WinPrtcl"]
    for idx in range(32):
        if emu.get_byte(base + idx * 5 + 4) == 255:
            continue
        if emu.get_word(base + idx * 5) == x and emu.get_word(base + idx * 5 + 2) == y:
            return True
    return False


def run_case(level: int, mode: str) -> tuple[bool, str]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    track1 = PACK / f"track_l{level:02d}_640.bin"
    track2 = PACK / f"track_l{level:02d}_2_640.bin"
    samples1, kz1_x, kz1_y = track_kz_scaled(track1)
    samples2, kz2_x, kz2_y = track_kz_scaled(track2)

    loaded1, loaded2 = load_track_v2_pair(emu, track1, track2)
    assert loaded1 == samples1 and loaded2 == samples2

    # WIN atlas upload is unrelated to the state logic and would slow this test
    # through zx7/FT812 paths. Keep VDC_WinOutroInit focused.
    emu.set_byte(sym["UnpackAndUploadPage"], 0xC9)  # RET

    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)
    sb(emu, "Core.VDC_GameState", 0)
    sb(emu, "Core.VDC_GaugeFull", 1)
    sb(emu, "Core.VDC_HasSecondChain", 1)
    sb(emu, "Core.VDC_SecondActive", 0)

    cl_start = sym["Core.VDC_ChainLocalStart"]
    tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
    tns1 = gw(emu, "Core.VDC_TrackNumSlots")
    tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off)
    set_chain(emu, 1, 4, max(0, tns1 - 5))
    set_chain(emu, 2, 4, max(0, tns2 - 5))
    emu.call(sym["Core.VDC_WinSnapAllChains"], max_steps=5_000_000)

    if mode == "both":
        sb(emu, "Core.VDC_SlotsLen", 0)
        sb(emu, "Core.VDC2_SlotsLen", 0)
    elif mode == "chain1_early":
        sb(emu, "Core.VDC_SlotsLen", 0)
        emu.call(sym["Core.VDC_WinSnapAllChains"], max_steps=5_000_000)
        sb(emu, "Core.VDC2_SlotsLen", 0)
    elif mode == "chain2_early":
        sb(emu, "Core.VDC2_SlotsLen", 0)
        emu.call(sym["Core.VDC_WinSnapAllChains"], max_steps=5_000_000)
        sb(emu, "Core.VDC_SlotsLen", 0)
    else:
        raise AssertionError(mode)

    emu.call(sym["Core.VDC_CheckWinMaybe"], max_steps=5_000_000)
    if gb(emu, "Core.VDC_GameState") != 6:
        return False, f"L{level:02d} {mode}: WIN did not arm"

    saw_kz1 = False
    saw_kz2 = False
    for frame in range(MAX_FRAMES):
        before1 = gw(emu, "Core.VDC_WinEmitPos1")
        before2 = gw(emu, "Core.VDC_WinEmitPos2")
        emu.call(sym["Core.VDC_UpdateWin"], max_steps=5_000_000)
        after1 = gw(emu, "Core.VDC_WinEmitPos1")
        after2 = gw(emu, "Core.VDC_WinEmitPos2")

        if before1 != 0xFFFF and after1 == 0xFFFF:
            saw_kz1 = has_particle_at(emu, kz1_x, kz1_y)
            if not saw_kz1:
                return False, (
                    f"L{level:02d} {mode}: chain1 emitter finished without KZ particle "
                    f"at ({kz1_x},{kz1_y}), samples={samples1}, frame={frame}"
                )
        if before2 != 0xFFFF and after2 == 0xFFFF:
            saw_kz2 = has_particle_at(emu, kz2_x, kz2_y)
            if not saw_kz2:
                return False, (
                    f"L{level:02d} {mode}: chain2 emitter finished without KZ particle "
                    f"at ({kz2_x},{kz2_y}), samples={samples2}, frame={frame}"
                )

        if saw_kz1 and saw_kz2:
            return True, (
                f"L{level:02d} {mode}: final KZ particles ok "
                f"chain1=({kz1_x},{kz1_y}) chain2=({kz2_x},{kz2_y})"
            )

    return False, (
        f"L{level:02d} {mode}: emitters did not finish, "
        f"pos=({gw(emu, 'Core.VDC_WinEmitPos1')},{gw(emu, 'Core.VDC_WinEmitPos2')})"
    )


def main() -> int:
    failures: list[str] = []
    for level in CASES:
        for mode in MODES:
            ok, msg = run_case(level, mode)
            print(("PASS: " if ok else "FAIL: ") + msg)
            if not ok:
                failures.append(msg)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
