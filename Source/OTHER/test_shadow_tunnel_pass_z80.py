#!/usr/bin/env python3
"""Regression for hardware ball shadows around tunnel/dual-chain/heavy levels."""
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

CMD_MEMWRITE = 0xFFFFFF1A
CMD_APPEND = 0xFFFFFF1E
VERTEX_TRANSLATE_X = 0x2B
VERTEX_TRANSLATE_Y = 0x2C
SHADOW_DX = 4 * 16
SHADOW_DY = 5 * 16
TUNNEL = 0x01
DRAW_ABOVE = 0x02


def sw(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.set_word(addr, value & 0xFFFF)


def sb(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.set_byte(addr, value & 0xFF)


def setup_state(
    emu: ZumaFullZ80Emulator,
    pass_id: int,
    explode: int = 0,
    topmask: int = 0,
    second_chain: int = 0,
    current_level: int = 0,
) -> None:
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    sw(emu, s["FT.Coprocessor.BufferPtr"], CMD)
    sw(emu, s["Core.ZL_CacheBasePtr"], CACHE)
    sb(emu, s["Core.ZL_BallCount"], 4)
    sb(emu, s["Core.ZL_ChainDrawPass"], pass_id)
    sb(emu, s["Core.VDC_ExplodeActive"], explode)
    sb(emu, s["Core.ZL_BallRotationDisabled"], 0)
    sb(emu, s["Core.ZL_HasTopMaskLevel"], topmask)
    sb(emu, s["Core.VDC_HasSecondChain"], second_chain)
    sb(emu, s["Core.CurrentLevel"], current_level)
    sb(emu, s["Core.VDC_GameState"], 0)
    for i in range(0x1000):
        emu.mem.write(CMD + i, 0)


def fill_cache(emu: ZumaFullZ80Emulator) -> None:
    flags = [0, TUNNEL, DRAW_ABOVE, TUNNEL | DRAW_ABOVE]
    for i, flag in enumerate(flags):
        x = 16 * (100 + i * 20)
        y = 16 * 120
        off = CACHE + i * 7
        emu.mem.write(off + 0, 0x00)
        emu.mem.write(off + 1, 10 + i)
        vertex = pack_vertex2f(x, y).to_bytes(4, "little")
        for byte_index, value in enumerate(vertex):
            emu.mem.write(off + 2 + byte_index, value)
        emu.mem.write(off + 6, flag)


def words(data: bytes) -> list[int]:
    return [int.from_bytes(data[i : i + 4], "little") for i in range(0, len(data), 4)]


def vertex2f_count(data: bytes) -> int:
    return sum(1 for w in words(data) if (w >> 30) == 0x01)


def run_pass(
    pass_id: int,
    explode: int = 0,
    topmask: int = 0,
    second_chain: int = 0,
    current_level: int = 0,
) -> tuple[list[int], bytes]:
    emu = ZumaFullZ80Emulator(ROOT)
    setup_state(emu, pass_id, explode, topmask, second_chain, current_level)
    fill_cache(emu)
    emu.call(emu.sym["Core.ZL_DrawCachedActiveChainWithShadowMaybe"], max_steps=1_000_000)
    if emu.reg.PC != RETURN_MARKER:
        raise AssertionError(f"pass {pass_id}: bad return PC=#{emu.reg.PC:04X}")
    ptr = emu.get_word(emu.sym["FT.Coprocessor.BufferPtr"])
    size = (ptr - CMD) & 0xFFFF
    data = bytes(emu.get_memory(CMD, size))
    return words(data), data


def check_shadow_pass(pass_id: int, expected_vertices: int, explode: int = 0) -> None:
    ws, data = run_pass(pass_id, explode)
    if ws.count(CMD_MEMWRITE) != 1:
        raise AssertionError(f"pass {pass_id}: expected one CMD_MEMWRITE, got {ws.count(CMD_MEMWRITE)}")
    expected_appends = 1 if explode else 2
    if ws.count(CMD_APPEND) != expected_appends:
        raise AssertionError(
            f"pass {pass_id}: expected {expected_appends} CMD_APPEND, got {ws.count(CMD_APPEND)}"
        )
    if ((VERTEX_TRANSLATE_X << 24) | SHADOW_DX) not in ws:
        raise AssertionError(f"pass {pass_id}: missing shadow X translate")
    if ((VERTEX_TRANSLATE_Y << 24) | SHADOW_DY) not in ws:
        raise AssertionError(f"pass {pass_id}: missing shadow Y translate")
    payload_len = ws[2]
    payload = data[12 : 12 + payload_len]
    got_vertices = vertex2f_count(payload)
    if got_vertices != expected_vertices:
        raise AssertionError(
            f"pass {pass_id}: expected {expected_vertices} shadow vertices, got {got_vertices}"
        )


def check_topmask_pass_has_no_shadow(pass_id: int, explode: int = 0) -> None:
    ws, _ = run_pass(pass_id, explode, topmask=1)
    if CMD_MEMWRITE in ws or CMD_APPEND in ws:
        raise AssertionError(f"top-mask pass {pass_id}: shadow payload must be disabled")
    if ((VERTEX_TRANSLATE_X << 24) | SHADOW_DX) in ws:
        raise AssertionError(f"top-mask pass {pass_id}: unexpected shadow X translate")
    if ((VERTEX_TRANSLATE_Y << 24) | SHADOW_DY) in ws:
        raise AssertionError(f"top-mask pass {pass_id}: unexpected shadow Y translate")


def check_dual_chain_has_no_shadow(pass_id: int, explode: int = 0) -> None:
    ws, _ = run_pass(pass_id, explode, second_chain=1)
    if CMD_MEMWRITE in ws or CMD_APPEND in ws:
        raise AssertionError(f"dual-chain pass {pass_id}: shadow payload must be disabled")
    if ((VERTEX_TRANSLATE_X << 24) | SHADOW_DX) in ws:
        raise AssertionError(f"dual-chain pass {pass_id}: unexpected shadow X translate")
    if ((VERTEX_TRANSLATE_Y << 24) | SHADOW_DY) in ws:
        raise AssertionError(f"dual-chain pass {pass_id}: unexpected shadow Y translate")


def check_level_has_no_shadow(level_index: int, explode: int = 0) -> None:
    ws, _ = run_pass(0, explode, current_level=level_index)
    if CMD_MEMWRITE in ws or CMD_APPEND in ws:
        raise AssertionError(f"CurrentLevel {level_index}: shadow payload must be disabled")
    if ((VERTEX_TRANSLATE_X << 24) | SHADOW_DX) in ws:
        raise AssertionError(f"CurrentLevel {level_index}: unexpected shadow X translate")
    if ((VERTEX_TRANSLATE_Y << 24) | SHADOW_DY) in ws:
        raise AssertionError(f"CurrentLevel {level_index}: unexpected shadow Y translate")


def main() -> int:
    # Non-top-mask passes still use the hardware shadow path and pass filters.
    check_shadow_pass(1, 3)
    check_shadow_pass(2, 1)
    check_shadow_pass(1, 3, explode=1)
    check_shadow_pass(2, 1, explode=1)

    # Tunnel/top-mask levels render normal balls only: no shadow payload.
    check_topmask_pass_has_no_shadow(1)
    check_topmask_pass_has_no_shadow(2)
    check_topmask_pass_has_no_shadow(1, explode=1)
    check_topmask_pass_has_no_shadow(2, explode=1)

    # Dual-chain levels also render normal balls only: no shadow payload.
    check_dual_chain_has_no_shadow(0)
    check_dual_chain_has_no_shadow(0, explode=1)

    # Heavy single-chain levels also render normal balls only.
    check_level_has_no_shadow(16)  # L17
    check_level_has_no_shadow(21)  # L22
    check_level_has_no_shadow(16, explode=1)
    check_level_has_no_shadow(21, explode=1)

    ws, _ = run_pass(3)
    if CMD_MEMWRITE in ws or CMD_APPEND in ws:
        raise AssertionError("pass 3 must stay normal-only without shadow CMD_APPEND")

    print(
        "PASS: hardware shadows stay enabled on single-chain/plain levels "
        "and are disabled on tunnel/top-mask, dual-chain, L17, or L22 levels"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
