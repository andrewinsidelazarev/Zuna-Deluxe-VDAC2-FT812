#!/usr/bin/env python3
"""Regression: prepared chain-2 PLAY renderer stays cache-only when stateless."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import pack_vertex2f  # noqa: E402
from test_dual_chain_win_outro_z80 import load_track_v2_pair  # noqa: E402
from zuma_full_z80_emulator import RETURN_MARKER, ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CMD = 0x4CB0
CACHE_FILL = 0xCC
WIN_SENTINEL_1 = 0xA55A
WIN_SENTINEL_2 = 0x5AA5


def call_with_hits(
    emu: ZumaFullZ80Emulator, addr: int, hit_addr: int, max_steps: int = 2_000_000
) -> tuple[int, int]:
    for reg in ("A", "B", "C", "D", "E", "H", "L"):
        setattr(emu.reg, reg, 0)
    sp = (emu.reg.SP - 2) & 0xFFFF
    emu.set_word(sp, RETURN_MARKER)
    emu.reg.SP = sp
    emu.reg.PC = addr
    hits = 0
    steps = 0
    start_t = emu.tstates
    while emu.reg.PC != RETURN_MARKER:
        if emu.reg.PC == hit_addr:
            hits += 1
        emu.step()
        steps += 1
        if steps > max_steps:
            raise TimeoutError(f"timeout at PC={emu.reg.PC:#06x}")
    return hits, emu.tstates - start_t


def chain2_explode_addr(emu: ZumaFullZ80Emulator) -> int:
    s = emu.sym
    return s["Core.VDC2_ChainLocal"] + (
        s["Core.VDC_ExplodeActive"] - s["Core.VDC_ChainLocalStart"]
    )


def fill_secondary_cache(emu: ZumaFullZ80Emulator, count: int = 12) -> None:
    base = emu.sym["Core.ZL_BALL_CACHE2_ADDR"]
    flags = (0, 1, 2, 3)
    for index in range(count):
        record = bytes((index & 0xF8, (index * 5) % 72))
        record += pack_vertex2f(
            16 * (80 + index * 7), 16 * (120 + index * 3)
        ).to_bytes(4, "little")
        record += bytes((flags[index & 3],))
        for offset, value in enumerate(record):
            emu.set_byte(base + index * 7 + offset, value)


def setup(explode1: int, explode2: int, game_state: int, draw_pass: int) -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    emu.set_word(s["FT.Coprocessor.BufferPtr"], CMD)
    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(s["Core.VDC_SecondActive"], 0)
    emu.set_byte(s["Core.VDC_GameState"], game_state)
    emu.set_byte(s["Core.VDC_ExplodeActive"], explode1)
    emu.set_byte(chain2_explode_addr(emu), explode2)
    emu.set_byte(s["Core.ZL_ChainDrawPass"], draw_pass)
    emu.set_byte(s["Core.ZL_Chain2BallCount"], 12)
    emu.set_byte(s["Core.ZL_BallRotationDisabled"], 0)
    emu.set_byte(s["Core.CurrentLevel"], 18)
    emu.set_byte(s["Core.VDC_RenderTrackPageIdx"], 0xFF)
    emu.set_byte(s["Core.VDC_TrackPages1"], 0x06)
    emu.set_byte(s["Core.VDC_TrackPages2"], 0x0F)
    emu.set_byte(s["Core.VDC_ActiveTrackPage1"], 0x06)
    emu.set_word(s["Core.VDC_pTrackPages"], s["Core.VDC_TrackPages1"])
    emu.set_word(s["Core.VDC_ActiveTrackSamples"], 4096)
    emu.call(s["Core.VDC_SelectChain1"])
    fill_secondary_cache(emu)
    return emu


def state_snapshot(emu: ZumaFullZ80Emulator) -> tuple[bytes, ...]:
    s = emu.sym
    local_len = s["Core.VDC_ChainLocalEnd"] - s["Core.VDC_ChainLocalStart"]
    pointer_start = s["Core.VDC_pSlots"]
    return (
        emu.get_memory(s["Core.VDC_ChainLocalStart"], local_len),
        emu.get_memory(s["Core.VDC2_ChainLocal"], local_len),
        emu.get_memory(pointer_start, 10),
        bytes((emu.get_byte(s["Core.VDC_SecondActive"]),)),
        bytes(emu.mem.pages),
        emu.get_memory(s["Core.VDC_pTrackPages"], 2),
        emu.get_memory(s["Core.VDC_ActiveTrackSamples"], 2),
        bytes(
            (
                emu.get_byte(s["Core.VDC_ActiveTrackPage1"]),
                emu.get_byte(s["Core.VDC_RenderTrackPageIdx"]),
            )
        ),
    )


def command_stream(emu: ZumaFullZ80Emulator) -> bytes:
    end = emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"])
    if not CMD <= end < 0x5C00:
        raise AssertionError(f"invalid command pointer {end:#06x}")
    return bytes(emu.get_memory(CMD, end - CMD))


def full_chain_state_snapshot(emu: ZumaFullZ80Emulator) -> tuple[bytes, ...]:
    """Всё физическое состояние обеих цепочек, которое render-view обязан вернуть."""
    s = emu.sym
    local_len = s["Core.VDC_ChainLocalEnd"] - s["Core.VDC_ChainLocalStart"]
    second_end = s["Core.VDC2_ChainLocal"] + local_len
    resident_scalars = bytes(
        emu.get_byte(s[name])
        for name in (
            "Core.VDC_HSub",
            "Core.VDC2_HSub",
            "Core.VDC_SlotsLen",
            "Core.VDC2_SlotsLen",
            "Core.VDC_KzFrame",
            "Core.VDC2_KzFrame",
            "Core.VDC_SecondActive",
        )
    )
    return (
        bytes(
            emu.get_memory(
                s["Core.VDC_TopologyState1"],
                s["Core.VDC_ChainLocalEnd"] - s["Core.VDC_TopologyState1"],
            )
        ),
        bytes(
            emu.get_memory(
                s["Core.VDC_TopologyState2"],
                second_end - s["Core.VDC_TopologyState2"],
            )
        ),
        resident_scalars,
        bytes(emu.get_memory(s["Core.VDC_pSlots"], 10)),
        bytes(emu.mem.pages),
        bytes(emu.get_memory(s["Core.VDC_pTrackPages"], 2)),
        bytes(emu.get_memory(s["Core.VDC_ActiveTrackSamples"], 2)),
        bytes((emu.get_byte(s["Core.VDC_ActiveTrackPage1"]),)),
    )


def expected_win_head(
    slots: list[int], offsets: list[int], hsa: int, hsub: int, samples: int
) -> int:
    found: list[int] = []
    base = hsa * 32 + hsub
    for index, (slot, raw_offset) in enumerate(zip(slots, offsets, strict=True)):
        if slot >= 6:
            continue
        base_t = base - index * 32
        if base_t < 0:
            continue
        offset = raw_offset if raw_offset < 0x80 else raw_offset - 0x100
        track_t = base_t + offset
        if track_t >= 0:
            found.append(min(track_t, samples - 1))
    if not found:
        raise AssertionError("synthetic top-mask chain has no WIN-head sample")
    return max(found)


def setup_topmask_cache_state() -> tuple[ZumaFullZ80Emulator, tuple[int, int]]:
    """L19 с намеренно разными backing-store, скалярами и пятью наборами массивов."""
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    load_track_v2_pair(
        emu,
        PACK / "track_l19_640.bin",
        PACK / "track_l19_2_640.bin",
    )
    emu.set_byte(s["Core.CurrentLevel"], 18)
    emu.set_byte(s["Core.CurrentDifficulty"], 0)
    emu.call(s["Core.VDC_Init"], max_steps=5_000_000)
    emu.set_byte(s["Core.VDC_GameState"], 0)
    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(s["Core.VDC_SecondActive"], 0)
    emu.set_byte(s["Core.ZL_BallsPalettedActive"], 1)
    emu.set_byte(s["Core.ZL_BallRotationDisabled"], 0)

    local_len = s["Core.VDC_ChainLocalEnd"] - s["Core.VDC_ChainLocalStart"]
    for index in range(local_len):
        emu.set_byte(s["Core.VDC_ChainLocalStart"] + index, (0x21 + index * 7) & 0xFF)
        emu.set_byte(s["Core.VDC2_ChainLocal"] + index, (0x92 + index * 11) & 0xFF)

    primary_slots = [0, 1, 2, 0xFF, 4, 5]
    primary_offsets = [0, 1, 0xFE, 3, 0, 2]
    secondary_slots = [5, 4, 3, 2, 1]
    secondary_offsets = [4, 0xFD, 2, 0, 1]
    max_slots = s["Core.VDC_MAX_SLOTS"]
    primary_arrays = (
        s["Core.VDC_Slots"],
        s["Core.VDC_Offsets"],
        s["Core.VDC_Shot2"],
        s["Core.VDC_ExplodeFrame"],
        s["Core.VDC_ExplodeMarker"],
    )
    secondary_arrays = (
        s["Core.VDC2_Slots"],
        s["Core.VDC2_Offsets"],
        s["Core.VDC2_Shot2"],
        s["Core.VDC2_ExplodeFrame"],
        s["Core.VDC2_ExplodeMarker"],
    )
    for array_index, (first, second) in enumerate(
        zip(primary_arrays, secondary_arrays, strict=True)
    ):
        for index in range(max_slots):
            emu.set_byte(first + index, (0x10 + array_index * 23 + index * 3) & 0xFF)
            emu.set_byte(second + index, (0x80 + array_index * 29 + index * 5) & 0xFF)
    for index, value in enumerate(primary_slots):
        emu.set_byte(s["Core.VDC_Slots"] + index, value)
        emu.set_byte(s["Core.VDC_Offsets"] + index, primary_offsets[index])
    for index, value in enumerate(secondary_slots):
        emu.set_byte(s["Core.VDC2_Slots"] + index, value)
        emu.set_byte(s["Core.VDC2_Offsets"] + index, secondary_offsets[index])

    hsa_offset = s["Core.VDC_HSA"] - s["Core.VDC_ChainLocalStart"]
    emu.set_byte(s["Core.VDC_HSA"], 8)
    emu.set_byte(s["Core.VDC2_ChainLocal"] + hsa_offset, 15)
    emu.set_byte(s["Core.VDC_HSub"], 3)
    emu.set_byte(s["Core.VDC2_HSub"], 19)
    emu.set_byte(s["Core.VDC_SlotsLen"], len(primary_slots))
    emu.set_byte(s["Core.VDC2_SlotsLen"], len(secondary_slots))
    emu.set_byte(s["Core.VDC_KzFrame"], 2)
    emu.set_byte(s["Core.VDC2_KzFrame"], 9)
    emu.set_byte(s["Core.VDC_TopologyState1"], 0x31)
    emu.set_byte(s["Core.VDC_TopologyState2"], 0xC7)
    emu.set_word(s["Core.VDC_WinHeadS1"], WIN_SENTINEL_1)
    emu.set_word(s["Core.VDC_WinHeadS2"], WIN_SENTINEL_2)
    for address in (s["Core.ZL_BALL_CACHE_ADDR"], s["Core.ZL_BALL_CACHE2_ADDR"]):
        for index in range(s["Core.ZL_BALL_CACHE_BYTES"]):
            emu.set_byte(address + index, CACHE_FILL)
    emu.call(s["Core.VDC_SelectChain1"], max_steps=200_000)
    emu.call(s["Core.SetCurrentTrackPage"], max_steps=200_000)

    expected = (
        expected_win_head(
            primary_slots,
            primary_offsets,
            8,
            3,
            emu.get_word(s["Core.VDC_TrackSamples1"]),
        ),
        expected_win_head(
            secondary_slots,
            secondary_offsets,
            15,
            19,
            emu.get_word(s["Core.VDC_TrackSamples2"]),
        ),
    )
    return emu, expected


def run_full_topmask_cache_reference(emu: ZumaFullZ80Emulator) -> None:
    """Прежняя полная swap-пара вокруг построения cache2."""
    s = emu.sym
    emu.call(s["Core.ZL_RestoreActiveTrackPage"], max_steps=200_000)
    emu.call(s["Core.ZL_SelectPrimaryBallCache"], max_steps=200_000)
    emu.call(s["Core.ZL_BuildActiveChainCache"], max_steps=5_000_000)
    emu.set_byte(s["Core.ZL_Chain1BallCount"], emu.get_byte(s["Core.ZL_BallCount"]))
    emu.set_byte(s["Core.ZL_Chain2BallCount"], 0)
    emu.call(s["Core.VDC_SwapChains"], max_steps=500_000)
    emu.call(s["Core.SetSecondTrackPage"], max_steps=200_000)
    emu.call(s["Core.ZL_SelectSecondaryBallCache"], max_steps=200_000)
    emu.call(s["Core.ZL_BuildActiveChainCache"], max_steps=5_000_000)
    emu.set_byte(s["Core.ZL_Chain2BallCount"], emu.get_byte(s["Core.ZL_BallCount"]))
    emu.call(s["Core.VDC_SwapChains"], max_steps=500_000)
    emu.call(s["Core.SetCurrentTrackPage"], max_steps=200_000)


def topmask_cache_output(emu: ZumaFullZ80Emulator) -> tuple[bytes, ...]:
    s = emu.sym
    size = s["Core.ZL_BALL_CACHE_BYTES"]
    return (
        bytes(emu.get_memory(s["Core.ZL_BALL_CACHE_ADDR"], size)),
        bytes(emu.get_memory(s["Core.ZL_BALL_CACHE2_ADDR"], size)),
        bytes(
            (
                emu.get_byte(s["Core.ZL_Chain1BallCount"]),
                emu.get_byte(s["Core.ZL_Chain2BallCount"]),
            )
        ),
        bytes(emu.get_memory(s["Core.VDC_WinHeadS1"], 4)),
    )


def prepared_topmask_commands(emu: ZumaFullZ80Emulator) -> tuple[bytes, ...]:
    s = emu.sym
    explode2 = s["Core.VDC2_ChainLocal"] + (
        s["Core.VDC_ExplodeActive"] - s["Core.VDC_ChainLocalStart"]
    )
    emu.set_byte(s["Core.VDC_GameState"], 0)
    emu.set_byte(s["Core.VDC_ExplodeActive"], 0)
    emu.set_byte(explode2, 0)
    result: list[bytes] = []
    for draw_pass in (1, 2):
        emu.set_byte(s["Core.ZL_ChainDrawPass"], draw_pass)
        for routine in (
            "Core.ZL_DrawPreparedChain1",
            "Core.ZL_DrawPreparedChain2Maybe",
        ):
            emu.set_word(s["FT.Coprocessor.BufferPtr"], CMD)
            for index in range(0x800):
                emu.set_byte(CMD + index, 0)
            emu.call(s[routine], max_steps=5_000_000)
            result.append(command_stream(emu))
    return tuple(result)


def check_light_render_swap_and_topmask_cache() -> None:
    light, expected_heads = setup_topmask_cache_state()
    reference, reference_heads = setup_topmask_cache_state()
    if reference_heads != expected_heads:
        raise AssertionError("L19 setup produced inconsistent WIN oracles")

    s = light.sym
    before = full_chain_state_snapshot(light)
    start = light.tstates
    light.call(s["Core.VDC_SwapRenderChains"], max_steps=500_000)
    to_second = light.tstates - start
    if light.get_byte(s["Core.VDC_SecondActive"]) != 1:
        raise AssertionError("light render swap did not select chain2")
    for pointer, target in (
        ("Core.VDC_pSlots", "Core.VDC2_Slots"),
        ("Core.VDC_pOffsets", "Core.VDC2_Offsets"),
        ("Core.VDC_pShot2", "Core.VDC2_Shot2"),
        ("Core.VDC_pExplodeFrame", "Core.VDC2_ExplodeFrame"),
        ("Core.VDC_pExplodeMarker", "Core.VDC2_ExplodeMarker"),
    ):
        if light.get_word(s[pointer]) != s[target]:
            raise AssertionError(f"light render swap left {pointer} on the wrong chain")
    if (
        light.get_byte(s["Core.VDC_HSA"]),
        light.get_byte(s["Core.VDC_HSub"]),
        light.get_byte(s["Core.VDC_SlotsLen"]),
        light.get_byte(s["Core.VDC_KzFrame"]),
    ) != (15, 19, 5, 2):
        raise AssertionError("light chain2 view exposed wrong render scalars")
    start = light.tstates
    light.call(s["Core.VDC_SwapRenderChains"], max_steps=500_000)
    to_first = light.tstates - start
    if full_chain_state_snapshot(light) != before:
        raise AssertionError("light render swap pair changed chain state")

    full_before = full_chain_state_snapshot(reference)
    start = reference.tstates
    reference.call(reference.sym["Core.VDC_SwapChains"], max_steps=500_000)
    reference.call(reference.sym["Core.VDC_SwapChains"], max_steps=500_000)
    full_pair = reference.tstates - start
    if full_chain_state_snapshot(reference) != full_before:
        raise AssertionError("full swap timing probe changed chain state")
    light_pair = to_second + to_first
    # Полный игровой swap теперь переносит также alpha головы обеих цепочек;
    # лёгкий swap рендера его намеренно не трогает.
    if full_pair - light_pair != 4814:
        raise AssertionError(
            f"render swap delta changed: full={full_pair} light={light_pair}"
        )

    optimized, expected_heads = setup_topmask_cache_state()
    reference, _ = setup_topmask_cache_state()
    optimized_before = full_chain_state_snapshot(optimized)
    reference_before = full_chain_state_snapshot(reference)
    hits, ticks = call_with_hits(
        optimized,
        optimized.sym["Core.ZL_BuildTopMaskChainCaches"],
        optimized.sym["Core.VDC_SwapBlock"],
        max_steps=5_000_000,
    )
    run_full_topmask_cache_reference(reference)
    if hits:
        raise AssertionError(f"top-mask cache builder still used SwapBlock {hits} times")
    if full_chain_state_snapshot(optimized) != optimized_before:
        raise AssertionError("light top-mask cache build changed optimized chain state")
    if full_chain_state_snapshot(reference) != reference_before:
        raise AssertionError("full top-mask reference changed chain state")
    if topmask_cache_output(optimized) != topmask_cache_output(reference):
        raise AssertionError("light top-mask build changed cache/count/WIN output")
    actual_heads = (
        optimized.get_word(optimized.sym["Core.VDC_WinHeadS1"]),
        optimized.get_word(optimized.sym["Core.VDC_WinHeadS2"]),
    )
    if actual_heads != expected_heads:
        raise AssertionError(
            f"light top-mask WIN heads {actual_heads} != oracle {expected_heads}"
        )
    if prepared_topmask_commands(optimized) != prepared_topmask_commands(reference):
        raise AssertionError("light top-mask caches changed prepared-renderer CMD stream")
    print(
        "PASS L19 light render swap: "
        f"full={full_pair}t light={light_pair}t gain={full_pair-light_pair}t "
        f"builder={ticks}t, state/cache/WIN/CMD exact"
    )


def run_old_prepared_reference(emu: ZumaFullZ80Emulator) -> None:
    """Execute the pre-optimization prepared-chain2 sequence by named calls."""
    s = emu.sym
    emu.call(s["Core.ZL_FlushCommandBufferMidFrame"])
    emu.call(s["Core.VDC_SwapChains"])
    emu.call(s["Core.SetSecondTrackPage"])
    emu.call(s["FT.Coprocessor.ColorRGB"], c=255, d=255, e=255)
    emu.call(s["Core.ZL_SetupBallBitmapState"])
    emu.call(s["Core.ZL_SelectSecondaryBallCache"])
    emu.set_byte(s["Core.ZL_BallCount"], emu.get_byte(s["Core.ZL_Chain2BallCount"]))
    emu.call(s["Core.ZL_DrawCachedActiveChainWithShadowMaybe"])
    emu.call(s["Core.VDC_SwapChains"])
    emu.call(s["Core.SetCurrentTrackPage"])


def check_case(explode1: int, explode2: int, game_state: int, draw_pass: int) -> None:
    fast = setup(explode1, explode2, game_state, draw_pass)
    reference = setup(explode1, explode2, game_state, draw_pass)
    before = state_snapshot(fast)
    hits, ticks = call_with_hits(
        fast,
        fast.sym["Core.ZL_DrawPreparedChain2Maybe"],
        fast.sym["Core.VDC_SwapBlock"],
    )
    after = state_snapshot(fast)
    run_old_prepared_reference(reference)

    expected_hits = 0 if game_state == 0 and explode1 == 0 and explode2 == 0 else 2
    if hits != expected_hits:
        raise AssertionError(
            f"state={game_state} explode={explode1}/{explode2}: swaps={hits}, "
            f"expected {expected_hits}"
        )
    if after != before:
        raise AssertionError("prepared draw changed chain/page/pointer state")
    if command_stream(fast) != command_stream(reference):
        raise AssertionError("optimized prepared draw changed the FT812 command stream")
    print(
        f"PASS state={game_state} explode={explode1}/{explode2} pass={draw_pass}: "
        f"swaps={hits} tstates={ticks} cmd={len(command_stream(fast))}"
    )


def main() -> int:
    check_light_render_swap_and_topmask_cache()

    for draw_pass in (1, 2):
        check_case(0, 0, 0, draw_pass)
    check_case(1, 0, 0, 1)
    check_case(0, 1, 0, 2)
    check_case(0, 0, 1, 1)

    emu = setup(0, 0, 0, 1)
    emu.set_byte(emu.sym["Core.VDC_HasSecondChain"], 0)
    before = state_snapshot(emu)
    hits, _ = call_with_hits(
        emu,
        emu.sym["Core.ZL_DrawPreparedChain2Maybe"],
        emu.sym["Core.VDC_SwapBlock"],
    )
    if hits or state_snapshot(emu) != before or command_stream(emu):
        raise AssertionError("HasSecondChain=0 path is not an exact no-op")
    print("PASS: prepared chain-2 guarded no-swap path is byte-exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
