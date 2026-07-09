#!/usr/bin/env python3
from __future__ import annotations

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from full_stack_trace import FullStackTrace  # noqa: E402
from test_gameplay_level_load_ramg import BG_PAL_RAMG, BG_PAL_SIZE, BG_RAMG, BG_SIZE, expected_bg, expected_pal  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402


TRACK_LOAD_PAGES = (0x06, 0x0F, 0x10, 0x12)
TRACK_V2_PAGE_SAMPLES = 2048
TRACK_V2_REC_SIZE = 8


def patch_ret(fs: FullStackTrace, page: int, sym_name: str) -> None:
    addr = fs.sym[sym_name]
    fs.emu.mem.physical[page * PAGE_SIZE + (addr & 0x3FFF)] = 0xC9


def gb(fs: FullStackTrace, name: str) -> int:
    return fs.emu.mem.read(fs.sym[name])


def gw(fs: FullStackTrace, name: str) -> int:
    addr = fs.sym[name]
    return fs.emu.mem.read(addr) | (fs.emu.mem.read(addr + 1) << 8)


def sb(fs: FullStackTrace, name: str, value: int) -> None:
    fs.emu.mem.write(fs.sym[name], value & 0xFF)


def sw(fs: FullStackTrace, name: str, value: int) -> None:
    addr = fs.sym[name]
    fs.emu.mem.write(addr, value & 0xFF)
    fs.emu.mem.write(addr + 1, (value >> 8) & 0xFF)


def toc_entry(level_index: int) -> tuple[int, ...]:
    pak = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()
    off = 512 + level_index * 20
    return struct.unpack_from("<HHHHHHHHHH", pak, off)


def track_blob(level_index: int) -> bytes:
    pak = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()
    fields = toc_entry(level_index)
    track_off, track_size = fields[4], fields[5]
    start = track_off * 512
    end = start + track_size * 512
    return pak[start:end]


def adventure_chain_entry(adventure_pos: int) -> tuple[int, int]:
    chain = (ROOT / "Build" / "level_chain_table.bin").read_bytes()
    off = adventure_pos * 2
    return chain[off], chain[off + 1]


def expected_track_meta(level_index: int) -> tuple[int, int, int, int]:
    blob = track_blob(level_index)
    assert blob[:4] == b"ZTV2", f"L{level_index + 1:02d}: missing Track V2 magic"
    c1 = struct.unpack_from("<H", blob, 4)[0]
    p1 = blob[6]
    c2 = struct.unpack_from("<H", blob, 7)[0]
    p2 = blob[9]
    rec_size = blob[10]
    page_samples = struct.unpack_from("<H", blob, 11)[0]
    assert rec_size == TRACK_V2_REC_SIZE
    assert page_samples == TRACK_V2_PAGE_SAMPLES
    return c1, p1, c2, p2


def assert_ramg_level(fs: FullStackTrace, level_index: int) -> None:
    actual_bg = bytes(fs.emu.ft.ram_g[BG_RAMG : BG_RAMG + BG_SIZE])
    actual_pal = bytes(fs.emu.ft.ram_g[BG_PAL_RAMG : BG_PAL_RAMG + BG_PAL_SIZE])
    assert actual_bg == expected_bg(level_index)[:BG_SIZE], f"L{level_index + 1:02d}: RAM_G background mismatch"
    assert actual_pal == expected_pal(level_index), f"L{level_index + 1:02d}: RAM_G palette mismatch"


def assert_track_pages(fs: FullStackTrace, level_index: int) -> None:
    c1, p1, c2, p2 = expected_track_meta(level_index)
    assert gw(fs, "Core.VDC_TrackSamples1") == c1
    assert gw(fs, "Core.VDC_TrackSamples2") == c2
    assert gb(fs, "Core.VDC_TrackPageCount1") == p1
    assert gb(fs, "Core.VDC_TrackPageCount2") == p2
    assert gw(fs, "Core.VDC_ActiveTrackSamples") == c1

    total_pages = p1 + p2
    assert 1 <= total_pages <= len(TRACK_LOAD_PAGES)
    blob = track_blob(level_index)
    payload = blob[512:]
    for index in range(total_pages):
        page = TRACK_LOAD_PAGES[index]
        got = bytes(fs.emu.mem.physical[page * PAGE_SIZE : (page + 1) * PAGE_SIZE])
        want = payload[index * PAGE_SIZE : (index + 1) * PAGE_SIZE].ljust(PAGE_SIZE, b"\0")
        if got != want:
            diff = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), 0)
            raise AssertionError(
                f"L{level_index + 1:02d}: Track V2 page #{page:02X} mismatch "
                f"at +#{diff:04X}: got #{got[diff]:02X}, want #{want[diff]:02X}"
            )

    first_page = bytes(fs.emu.mem.physical[TRACK_LOAD_PAGES[0] * PAGE_SIZE : TRACK_LOAD_PAGES[0] * PAGE_SIZE + 4])
    assert first_page != b"ZTV2", "Track metadata stayed mapped as the first sample page"


def assert_gameplay_reset(
    fs: FullStackTrace,
    level_index: int,
    expected_adventure_pos: int,
    expected_setting_index: int,
    expect_second: bool,
) -> None:
    assert gb(fs, "Core.CurrentLevel") == level_index, (
        f"CurrentLevel={gb(fs, 'Core.CurrentLevel')} expected={level_index}"
    )
    assert gb(fs, "Core.AdventurePos") == expected_adventure_pos, (
        f"AdventurePos={gb(fs, 'Core.AdventurePos')} expected={expected_adventure_pos}"
    )
    assert gb(fs, "Core.CurrentSettingIndex") == expected_setting_index, (
        f"CurrentSettingIndex={gb(fs, 'Core.CurrentSettingIndex')} expected={expected_setting_index}"
    )
    assert gb(fs, "Core.FadeAlpha") == 0, f"FadeAlpha={gb(fs, 'Core.FadeAlpha')}"
    assert gb(fs, "Core.VDC_DialogState") == 0, f"DialogState={gb(fs, 'Core.VDC_DialogState')}"
    assert gb(fs, "Core.VDC_GameState") == fs.sym["Core.VDC_STATE_INTRO"], (
        f"GameState={gb(fs, 'Core.VDC_GameState')} expected INTRO"
    )
    assert gb(fs, "Core.VDC_GaugeFull") == 0, f"GaugeFull={gb(fs, 'Core.VDC_GaugeFull')}"
    assert gw(fs, "Core.VDC_GaugeScore") == 0, f"GaugeScore={gw(fs, 'Core.VDC_GaugeScore')}"
    assert gb(fs, "Core.Bullet_Active") == 0, f"Bullet_Active={gb(fs, 'Core.Bullet_Active')}"
    assert gb(fs, "Core.Frog_IsFire") == 0, f"Frog_IsFire={gb(fs, 'Core.Frog_IsFire')}"
    assert gb(fs, "Core.VDC_HasSecondChain") == (1 if expect_second else 0), (
        f"HasSecondChain={gb(fs, 'Core.VDC_HasSecondChain')} expected={1 if expect_second else 0}"
    )
    assert gb(fs, "DialogFrameLoaded") == 0, f"DialogFrameLoaded={gb(fs, 'DialogFrameLoaded')}"
    if fs.emu.mem.pages[2] != TRACK_LOAD_PAGES[0]:
        p1 = [fs.emu.mem.read(fs.sym["Core.VDC_TrackPages1"] + i) for i in range(4)]
        p2 = [fs.emu.mem.read(fs.sym["Core.VDC_TrackPages2"] + i) for i in range(4)]
        raise AssertionError(
            f"slot2 should end on current track page, got #{fs.emu.mem.pages[2]:02X}; "
            f"TrackPages1={p1} TrackPages2={p2} "
            f"ActiveTrackPage1=#{gb(fs, 'Core.VDC_ActiveTrackPage1'):02X} "
            f"SecondActive={gb(fs, 'Core.VDC_SecondActive')}"
        )
    assert fs.emu.mem.pages[3] == 0x04, f"slot3 should end on gameplay page #04, got #{fs.emu.mem.pages[3]:02X}"


def run_case(start_level: int, start_adventure_pos: int, expected_level: int, expected_second: bool) -> None:
    fs = FullStackTrace(ROOT, shadow_ft812=True)
    fs.call("Core.Init_Core", 1_000_000)
    patch_ret(fs, 0x04, "Core.MainLoop")
    patch_ret(fs, 0x05, "Core.DrawBlackLoadingFrame")
    patch_ret(fs, 0x40, "Core.OVL_DrawNextLevelLoadingScreen")

    sb(fs, "Core.CurrentGameMode", 0)
    sb(fs, "Core.CurrentLevel", start_level)
    sb(fs, "Core.AdventurePos", start_adventure_pos)
    sb(fs, "Core.CurrentDifficulty", 0)
    sb(fs, "Core.CurrentSettingIndex", start_adventure_pos)

    # Poison the state like a finished WIN screen. The transition must clean all
    # gameplay-visible flags before the next level starts.
    sb(fs, "Core.VDC_DialogState", fs.sym["Core.DLG_WIN_FADE"])
    sb(fs, "Core.FadeAlpha", 255)
    sb(fs, "Core.VDC_GameState", fs.sym["Core.VDC_STATE_WIN"])
    sb(fs, "Core.VDC_GaugeFull", 1)
    sw(fs, "Core.VDC_GaugeScore", 0x7FFF)
    sb(fs, "Core.Bullet_Active", 1)
    sb(fs, "Core.Frog_IsFire", 1)
    sb(fs, "DialogFrameLoaded", 1)
    fs.emu.mem.pages[2] = 0x31
    fs.emu.mem.pages[3] = 0x04

    fs.call("UpdateDialog", 40_000_000)

    expected_adventure_pos = start_adventure_pos + 1
    chain_level, chain_setting = adventure_chain_entry(expected_adventure_pos)
    assert chain_level == expected_level, (
        f"test case expected L{expected_level + 1:02d}, "
        f"but adventure pos {expected_adventure_pos} maps to L{chain_level + 1:02d}"
    )
    assert_gameplay_reset(fs, expected_level, expected_adventure_pos, chain_setting, expected_second)
    assert_ramg_level(fs, expected_level)
    assert_track_pages(fs, expected_level)
    print(
        f"OK WIN fade transition L{start_level + 1:02d}->L{expected_level + 1:02d}: "
        f"track={gw(fs, 'Core.VDC_TrackSamples1')} samples has2={gb(fs, 'Core.VDC_HasSecondChain')}"
    )


def main() -> int:
    run_case(start_level=0, start_adventure_pos=0, expected_level=1, expected_second=False)
    run_case(start_level=3, start_adventure_pos=18, expected_level=4, expected_second=True)
    print("PASS: WIN fade -> next level full load resets gameplay state and loads Track V2/RAM_G")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
