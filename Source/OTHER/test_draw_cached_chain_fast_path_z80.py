#!/usr/bin/env python3
"""Compare slow and fast cached-chain draw paths on a synthetic Z80 cache."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import pack_vertex2f  # noqa: E402
from zuma_full_z80_emulator import RETURN_MARKER, ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
CMD = 0x4CB0
CACHE = 0x4100
PRESSURE_PTR = 0x5800


def call(emu: ZumaFullZ80Emulator, addr: int, max_steps: int = 1_000_000) -> tuple[int, int]:
    start_t = emu.tstates
    steps = emu.call(addr, max_steps=max_steps)
    return steps, emu.tstates - start_t


def sw(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.set_word(addr, value & 0xFFFF)


def sb(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.set_byte(addr, value & 0xFF)


def setup_state(
    emu: ZumaFullZ80Emulator,
    ball_count: int,
    pass_id: int,
    *,
    explode: int = 0,
    rotation_disabled: int = 0,
    game_state: int = 0,
) -> None:
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    sw(emu, s["FT.Coprocessor.BufferPtr"], CMD)
    sw(emu, s["Core.ZL_CacheBasePtr"], CACHE)
    sb(emu, s["Core.ZL_BallCount"], ball_count)
    sb(emu, s["Core.ZL_ChainDrawPass"], pass_id)
    sb(emu, s["Core.VDC_ExplodeActive"], explode)
    sb(emu, s["Core.ZL_BallRotationDisabled"], rotation_disabled)
    sb(emu, s["Core.VDC_GameState"], game_state)
    for i in range(0x800):
        emu.mem.write(CMD + i, 0)


def fill_cache(emu: ZumaFullZ80Emulator, ball_count: int) -> None:
    flags = (0, 1, 2, 3, 0x80, 0x81, 0x82, 0x83)
    for i in range(ball_count):
        tangent = ((i // 3) * 8) & 0xF8
        cell = (i * 5) % 72
        x = 16 * (70 + (i % 16) * 8)
        y = 16 * (90 + (i // 16) * 10)
        off = CACHE + i * 7
        emu.mem.write(off + 0, tangent)
        emu.mem.write(off + 1, cell)
        vertex = pack_vertex2f(x, y).to_bytes(4, "little")
        for byte_index, value in enumerate(vertex):
            emu.mem.write(off + 2 + byte_index, value)
        emu.mem.write(off + 6, flags[i % len(flags)])

    # Mark a few gaps; both paths must skip them identically.
    for i in (5, 17, 43):
        if i < ball_count:
            emu.mem.write(CACHE + i * 7 + 1, 0xFF)


def run_path(
    label: str,
    sym_name: str,
    ball_count: int,
    pass_id: int,
    *,
    explode: int = 0,
    rotation_disabled: int = 0,
    game_state: int = 0,
) -> tuple[bytes, int, int, int, int, int]:
    emu = ZumaFullZ80Emulator(ROOT)
    setup_state(
        emu,
        ball_count,
        pass_id,
        explode=explode,
        rotation_disabled=rotation_disabled,
        game_state=game_state,
    )
    fill_cache(emu, ball_count)
    steps, tstates = call(emu, emu.sym[sym_name])
    if emu.reg.PC != RETURN_MARKER:
        raise AssertionError(f"{label}: bad return PC=#{emu.reg.PC:04X}")
    ptr = emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"])
    size = (ptr - CMD) & 0xFFFF
    data = bytes(emu.get_memory(CMD, size))
    last_tangent = emu.get_byte(emu.sym["Core.ZL_TmpLastTangent"])
    carry = emu.reg.F & 1
    return data, size, steps, tstates, last_tangent, carry


def compare_pass(ball_count: int, pass_id: int) -> tuple[int, int]:
    slow = run_path(
        "slow", "Core.ZL_DrawCachedActiveChainSlow", ball_count, pass_id
    )
    fast = run_path(
        "fast", "Core.ZL_DrawCachedActiveChainFastMaybe", ball_count, pass_id
    )
    slow_data, slow_size, slow_steps, slow_t, slow_tangent, _ = slow
    fast_data, fast_size, fast_steps, fast_t, fast_tangent, fast_carry = fast
    if slow_data != fast_data:
        limit = min(len(slow_data), len(fast_data))
        diff = next(
            (i for i in range(limit) if slow_data[i] != fast_data[i]), limit
        )
        raise AssertionError(
            f"count={ball_count} pass={pass_id}: CMD differs at {diff}: "
            f"slow={slow_data[diff:diff+16].hex(' ')} "
            f"fast={fast_data[diff:diff+16].hex(' ')}"
        )
    if slow_size != fast_size:
        raise AssertionError(
            f"count={ball_count} pass={pass_id}: size {slow_size} != {fast_size}"
        )
    if slow_tangent != fast_tangent:
        raise AssertionError(
            f"count={ball_count} pass={pass_id}: final tangent "
            f"{slow_tangent:#04x} != {fast_tangent:#04x}"
        )
    if not fast_carry:
        raise AssertionError(f"count={ball_count} pass={pass_id}: fast path rejected")
    return slow_t, fast_t


def run_pressure_filter_case(
    pass_id: int, *, with_draw: bool
) -> tuple[list[int], int]:
    emu = ZumaFullZ80Emulator(ROOT)
    setup_state(emu, 3, pass_id)
    fill_cache(emu, 3)
    sw(emu, emu.sym["FT.Coprocessor.BufferPtr"], PRESSURE_PTR)

    emu.mem.write(CACHE + 1, 0xFF)
    filtered_flags = 2 if pass_id == 1 else 0
    eligible_flags = 0 if pass_id == 1 else 2
    emu.mem.write(CACHE + 7 + 6, filtered_flags)
    emu.mem.write(CACHE + 14 + 6, eligible_flags if with_draw else filtered_flags)

    flush_pc = emu.sym["Core.ZL_FlushCommandBufferMidFrame"]
    flush_ix: list[int] = []
    base_step = emu.step

    def traced_step() -> int:
        if emu.reg.PC == flush_pc:
            flush_ix.append(emu.reg.IX)
        return base_step()

    emu.step = traced_step
    target = (
        "Core.ZL_DrawCachedActiveChainTopMaskFastUnder"
        if pass_id == 1
        else "Core.ZL_DrawCachedActiveChainTopMaskFastOver"
    )
    call(emu, emu.sym[target])
    if emu.reg.PC != RETURN_MARKER:
        raise AssertionError(f"pressure pass={pass_id}: bad return PC=#{emu.reg.PC:04X}")
    return flush_ix, emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"])


def check_pressure_after_filter() -> None:
    for pass_id in (1, 2):
        flush_ix, ptr = run_pressure_filter_case(pass_id, with_draw=True)
        expected_ix = CACHE + 14
        if flush_ix != [expected_ix]:
            raise AssertionError(
                f"pressure pass={pass_id}: flush IX={flush_ix}, expected [{expected_ix}]"
            )
        if ptr == PRESSURE_PTR:
            raise AssertionError(f"pressure pass={pass_id}: eligible ball was not emitted")

        flush_ix, ptr = run_pressure_filter_case(pass_id, with_draw=False)
        if flush_ix:
            raise AssertionError(
                f"all-filtered pass={pass_id}: unexpected flush IX={flush_ix}"
            )
        if ptr != PRESSURE_PTR:
            raise AssertionError(
                f"all-filtered pass={pass_id}: BufferPtr={ptr:#06x}, "
                f"expected {PRESSURE_PTR:#06x}"
            )


def check_reject(
    label: str,
    *,
    pass_id: int = 0,
    explode: int = 0,
    rotation_disabled: int = 0,
    game_state: int = 0,
) -> None:
    data, size, _, _, _, carry = run_path(
        label,
        "Core.ZL_DrawCachedActiveChainFastMaybe",
        24,
        pass_id,
        explode=explode,
        rotation_disabled=rotation_disabled,
        game_state=game_state,
    )
    if carry or size or data:
        raise AssertionError(
            f"{label}: rejected path changed CMD or returned carry "
            f"(carry={carry}, size={size})"
        )


def main() -> int:
    rows: list[tuple[int, int, int, int]] = []
    for pass_id in (0, 1, 2):
        for ball_count in (1, 40, 73, 80, 96):
            slow_t, fast_t = compare_pass(ball_count, pass_id)
            rows.append((pass_id, ball_count, slow_t, fast_t))

    check_reject("dialog pass", pass_id=3)
    check_reject("explosion", explode=1)
    check_reject("rotation disabled", rotation_disabled=1)
    check_reject("non-PLAY", game_state=1)
    check_pressure_after_filter()

    for pass_id in (0, 1, 2):
        _, count, slow_t, fast_t = next(
            row for row in rows if row[0] == pass_id and row[1] == 96
        )
        gain = slow_t - fast_t
        pct = gain * 100.0 / slow_t
        print(
            f"pass={pass_id} count={count}: slow={slow_t}t fast={fast_t}t "
            f"gain={gain}t ({pct:.1f}%)"
        )
    print("PASS: fast cached-chain CMD is byte-identical for passes 0/1/2; fallbacks are clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
