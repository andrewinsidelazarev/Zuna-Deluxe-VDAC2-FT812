#!/usr/bin/env python3
"""Audit FT812 display-list state/order around WIN explosions and HUD clock.

This is a targeted host-side diagnostic. It uses the existing full-stack
harness to load gameplay assets, create live WIN explosion particles, build one
Win renderer into the Z80 FT command buffer, then decodes the emitted DL words.
It also statically checks the frame draw order: WIN explosions must be emitted
before frame strips/HUD so they cannot overdraw the clock socket.
"""
from __future__ import annotations

import functools
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from full_stack_trace import FullStackTrace  # noqa: E402
from shadow_ft812 import DLOp, disasm_dl, format_dl, summarize_dl  # noqa: E402
from zx7_dec import dzx7_turbo  # noqa: E402

print = functools.partial(print, flush=True)
ROOT = HERE.parent.parent
CMD_BUF = 0x5E00

WINEXP_HANDLE = 26


def ret_now(e) -> None:
    sp = e.reg.SP
    ret = e.mem.read(sp) | (e.mem.read((sp + 1) & 0xFFFF) << 8)
    e.reg.SP = (sp + 2) & 0xFFFF
    e.reg.PC = ret
    e.reg.F &= ~0x01


def install_fast_hooks(fs: FullStackTrace) -> None:
    e = fs.emu
    sym = fs.sym
    hook_pcs = {
        x
        for x in (
            sym.get("Core.sd_init"),
            sym.get("Core.sd_read_sector"),
            sym.get("FT.Coprocessor.Inflate"),
            sym.get("FT.WriteMem"),
        )
        if x is not None
    }
    dzx7 = sym.get("Dzx7Turbo")
    ret_pcs = {
        x
        for x in (
            sym.get("FT.Coprocessor.WaitFlush"),
            sym.get("FT.Coprocessor.IsFault"),
            sym.get("FT.Coprocessor.Wait"),
            sym.get("FT.Coprocessor.Write"),
            sym.get("FT.Coprocessor.Write32"),
        )
        if x is not None
    }
    bare = fs.orig_step
    hook_pc = fs._hook_pc

    def fast_step() -> int:
        pc = e.reg.PC
        if pc in ret_pcs:
            ret_now(e)
            return 0
        if pc == dzx7:
            src = (e.reg.H << 8) | e.reg.L
            dst = (e.reg.D << 8) | e.reg.E
            comp = bytes(e.mem.read((src + k) & 0xFFFF) for k in range(min(0x10000 - src, 16384)))
            out, consumed = dzx7_turbo(comp)
            for k, b in enumerate(out):
                e.mem.write((dst + k) & 0xFFFF, b)
            h = (src + consumed) & 0xFFFF
            e.reg.H = h >> 8
            e.reg.L = h & 0xFF
            d = (dst + len(out)) & 0xFFFF
            e.reg.D = d >> 8
            e.reg.E = d & 0xFF
            ret_now(e)
            return 0
        if pc in hook_pcs and hook_pc(pc):
            return 0
        return bare()

    e.step = fast_step


def call(fs: FullStackTrace, name: str, max_steps: int = 4_000_000) -> int:
    e = fs.emu
    addr = fs.sym[name]
    sp = (e.reg.SP - 2) & 0xFFFF
    e.set_word(sp, 0xFFFE)
    e.reg.SP = sp
    e.reg.PC = addr
    steps = 0
    while e.reg.PC != 0xFFFE:
        e.step()
        steps += 1
        if steps > max_steps:
            raise TimeoutError(f"{name} timeout PC=#{e.reg.PC:04X}")
    return steps


def get_byte(e, sym: dict[str, int], name: str) -> int:
    return e.get_byte(sym[name])


def get_word(e, sym: dict[str, int], name: str) -> int:
    return e.get_word(sym[name])


def emitted_ops(fs: FullStackTrace, name: str, max_steps: int = 4_000_000) -> list[DLOp]:
    e = fs.emu
    start = CMD_BUF
    e.set_word(fs.sym["FT.Coprocessor.BufferPtr"], start)
    call(fs, name, max_steps=max_steps)
    end = e.get_word(fs.sym["FT.Coprocessor.BufferPtr"])
    size = (end - start) & 0xFFFF
    data = bytes(e.mem.read((start + i) & 0xFFFF) for i in range(size))
    return disasm_dl(data, max_ops=max(1, size // 4), stop_at_display=False)


def field_int(op: DLOp, key: str) -> int | None:
    value = op.fields.get(key)
    if value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.startswith("#"):
        return int(value[1:], 16)
    return None


def audit_win_visual_ops(label: str, ops: list[DLOp]) -> bool:
    ok = True
    print(f"\n=== {label} ===")
    print(summarize_dl(ops))

    win_indices = [
        i for i, op in enumerate(ops)
        if op.name == "BITMAP_HANDLE" and field_int(op, "handle") == WINEXP_HANDLE
    ]
    print(f"WINEXP handle indices: {win_indices[:8]}")

    if not win_indices:
        print("FAIL: no WINEXP BITMAP_HANDLE(26) found")
        ok = False

    for wi in win_indices[:1]:
        print("\n-- context around WINEXP handle --")
        print(format_dl(ops[max(0, wi - 4): wi + 14]))

    after = ops[win_indices[0]:] if win_indices else []
    has_source = any(op.name == "BITMAP_SOURCE" and field_int(op, "addr") == 0x050000 for op in after[:8])
    has_layout = any(
        op.name == "BITMAP_LAYOUT"
        and op.fields.get("fmt") == "ARGB4"
        and field_int(op, "stride") == 96
        and field_int(op, "height") == 48
        for op in after[:8]
    )
    has_size = any(
        op.name == "BITMAP_SIZE"
        and field_int(op, "w") == 80
        and field_int(op, "h") == 80
        for op in after[:8]
    )
    vertices = [op for op in after if op.name == "VERTEX2F"]
    if not (has_source and has_layout and has_size and vertices):
        print(
            "FAIL: WINEXP draw lacks full state "
            f"(source={has_source}, layout={has_layout}, size={has_size}, vertices={len(vertices)})"
        )
        ok = False
    else:
        print(f"OK: WINEXP re-emits handle/source/layout/size and {len(vertices)} vertices")

    return ok


def audit_source_order() -> bool:
    src = (ROOT / "Source" / "ASM" / "MainLoop.asm").read_text(encoding="utf-8")
    start = src.index("ZL_AfterChains:")
    end = src.index("; --- LEVEL DONE fade-out overlay", start)
    body = src[start:end]
    win = body.find("CALL Z, DrawWinStateVisual")
    hud = body.find("CALL DrawHudTopText")
    cursor = body.find("FT_BitmapHandle 7")
    print("\n=== ZL_AfterChains source order ===")
    print(f"DrawWinStateVisual offset={win}, DrawHudTopText offset={hud}, cursor offset={cursor}")
    if win < 0:
        print("FAIL: DrawWinStateVisual is not called in ZL_AfterChains")
        return False
    if hud < 0:
        print("FAIL: DrawHudTopText not found in ZL_AfterChains")
        return False
    if not win < hud:
        print("FAIL: WIN explosions are drawn after HUD and can overdraw the clock")
        return False
    if cursor >= 0 and win > cursor:
        print("FAIL: WIN explosions are still drawn after cursor/HUD tail")
        return False
    print("OK: WIN explosions are emitted before frame/HUD/cursor overlays")
    return True


def main() -> int:
    fs = FullStackTrace(ROOT, shadow_ft812=True)
    install_fast_hooks(fs)
    e = fs.emu
    sym = fs.sym

    call(fs, "Core.Init_Core")
    e.set_byte(sym["Core.CurrentLevel"], 4)  # L05 has two chains; good WIN stress case.
    call(fs, "Core.LoadGameplayAssets")
    e.set_byte(sym["CurrentCodePage"], 0x04)

    for _ in range(40):
        e.set_byte(sym["Core.VDC_GameState"], 0)
        call(fs, "Core.VDC_UpdateAllChains")

    head = get_word(e, sym, "Core.VDC_WinHeadS1")
    print(f"PLAY warmup: head_sample={head} slots=({get_byte(e, sym, 'Core.VDC_SlotsLen')},"
          f"{get_byte(e, sym, 'Core.VDC2_SlotsLen')})")

    e.set_byte(sym["Core.VDC_SlotsLen"], 0)
    e.set_byte(sym["Core.VDC2_SlotsLen"], 0)
    e.set_byte(sym["Core.VDC_GameState"], 6)  # VDC_STATE_WIN
    e.set_byte(sym["Core.VDC_WinTick"], 250)
    call(fs, "Core.VDC_WinOutroInit")
    for _ in range(20):
        call(fs, "Core.VDC_UpdateWin")

    base = sym["Core.VDC_WinPrtcl"]
    alive = sum(1 for i in range(32) if e.get_byte(base + i * 5 + 4) != 255)
    print(f"WIN particles alive={alive}, active={get_byte(e, sym, 'Core.VDC_WinOutroActive')}")
    if alive == 0:
        print("FAIL: no live WIN particles; cannot audit WINEXP -> HUD state")
        return 1

    ok = True
    ok &= audit_win_visual_ops("DrawWinStateVisual only", emitted_ops(fs, "Core.DrawWinStateVisual"))
    ok &= audit_source_order()
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
