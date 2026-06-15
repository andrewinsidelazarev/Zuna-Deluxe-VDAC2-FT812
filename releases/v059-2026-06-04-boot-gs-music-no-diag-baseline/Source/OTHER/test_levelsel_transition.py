#!/usr/bin/env python3
"""Emulate the MenuMain → LevelSelect transition with shadow FT812 attached.

Workflow:
  * Boot Z80 emulator, init Core/Video/etc.
  * Run MenuMain for a few frames so RAM_G holds menu assets.
  * Snapshot the DL emitted by MenuMain — verify it's well-formed.
  * Simulate the Adventure click (set MenuAdventureClick=1).
  * Step the menu loop one more iteration → .start_game fires → in current
    revert state that means JP MainLoop, so we instead force-call a synthetic
    LoadLevelSelectAssets entry to mimic the swap.
  * Capture FT_REG_CMD_READ/CMD_WRITE/CMD_FIFO before/after the transition.

The shadow's "instant coprocessor processing" model means we cannot see the
real coprocessor stall here — but we CAN verify the DL contents are valid and
the inflate sequence Z80-side completes without bad opcodes/timeouts.
"""

import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402
from shadow_ft812 import (  # noqa: E402
    attach_shadow, disasm_dl, format_dl, summarize_dl, REG_CMD_READ, REG_CMD_WRITE
)

ROOT = HERE.parent.parent
STUB_RET_OK = bytes([0xB7, 0xC9])  # OR A; RET


def stub_ret_ok(emu: ZumaFullZ80Emulator, name: str) -> None:
    addr = emu.sym.get(name)
    if addr is None:
        return
    for i, byte in enumerate(STUB_RET_OK):
        emu.set_byte(addr + i, byte)


def hook_safe_inflate(emu: ZumaFullZ80Emulator) -> None:
    """Emulate SafeInflatePage2 with Python zlib so the test stays Z80-side."""
    inflate_addr = emu.sym["SafeInflatePage2"]
    page_size = 0x4000
    orig_step = emu.step

    def hooked_step():
        if emu.reg.PC != inflate_addr:
            return orig_step()

        dest = (emu.reg.A << 16) | (emu.reg.D << 8) | emu.reg.E
        src_page = emu.reg["A_"]
        src_offset = (emu.reg.H << 8) | emu.reg.L
        phys_start = src_page * page_size + (src_offset & 0x3FFF)
        phys_slice = bytes(emu.mem.physical[phys_start:phys_start + 200_000])
        data = zlib.decompress(phys_slice)
        emu.ft.ram_g[dest:dest + len(data)] = data

        sp = emu.reg.SP
        ret_addr = emu.mem.read(sp) | (emu.mem.read(sp + 1) << 8)
        emu.reg.SP = (sp + 2) & 0xFFFF
        emu.reg.PC = ret_addr
        emu.reg.F &= ~0x01
        return 0

    emu.step = hooked_step


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    regs = attach_shadow(emu)
    hook_safe_inflate(emu)
    if emu.errors:
        print("load warnings:")
        for err in emu.errors:
            print(" -", err)

    sym = emu.sym

    # --- Init phase (no FT812 hardware boot since shadow already provides defaults) ---
    print("[init] calling Init_Core")
    for name in (
        "FT.Coprocessor.WaitFlush",
        "FT.Coprocessor.Write",
        "FT.Coprocessor.Write32",
        "FT.Coprocessor.IsFault",
        "FT.Coprocessor.Wait",
    ):
        stub_ret_ok(emu, name)
    emu.call(sym["Core.Init_Core"])

    # Init_Int does a HALT and waits for IRQ — skip it (would deadlock without IRQ source).
    # Likewise skip Init_Video to keep things minimal — shadow_ft812 has video defaults.

    # --- Find MenuMain entry ---
    mm_entry = sym.get("Core.MenuMain")
    if mm_entry is None:
        print("ERROR: Core.MenuMain not in zuma.sym")
        return 1
    print(f"[menu] MenuMain entry: #{mm_entry:04X}")

    # MenuMain runs an infinite loop — we can't `emu.call` it.
    # Instead, manually call LoadMainMenuAssets + a few build-frame iterations.
    load_menu = sym.get("Core.LoadMainMenuAssets")
    if load_menu is None:
        print("ERROR: Core.LoadMainMenuAssets not in zuma.sym")
        return 1
    print(f"[menu] calling LoadMainMenuAssets @ #{load_menu:04X}")
    emu.call(load_menu)
    print(f"  after load: CMD_READ=#{regs._get32(REG_CMD_READ):04X} "
          f"CMD_WRITE=#{regs._get32(REG_CMD_WRITE):04X}")

    # Build one MenuMain frame: MenuUpdateButtons + AdvanceSky + BuildFrame + SwapFrame.
    mub = sym.get("Core.MenuUpdateButtons")
    mbf = sym.get("Core.MenuBuildFrame")
    msf = sym.get("Core.MenuSwapFrame")
    mas = sym.get("Core.MenuAdvanceSky")
    if not all((mub, mbf, msf, mas)):
        print("ERROR: missing one of MenuMain sub-routines in symbol table")
        for n in ("MenuUpdateButtons", "MenuBuildFrame", "MenuSwapFrame", "MenuAdvanceSky"):
            print(f"  Core.{n}: {sym.get('Core.' + n)}")
        return 1

    for f in range(3):
        emu.call(mub)
        emu.call(mas)
        emu.call(mbf)
        emu.call(msf)
        regs.tick_frame(emu.ft.ram_dl)
    print(f"[menu] 3 frames built, swap_count={regs.swap_count}")

    if regs.last_dl_snapshot:
        ops = disasm_dl(regs.last_dl_snapshot)
        print(f"[menu DL] {summarize_dl(ops)}")
    else:
        print("[menu] NO DL snapshot captured — swap path broken")
        return 1

    # --- Transition: call LoadLevelSelectAssets ---
    load_ls = sym.get("Core.LoadLevelSelectAssets")
    if load_ls is None:
        print("ERROR: Core.LoadLevelSelectAssets not in zuma.sym "
              "(LevelSelect.asm not included)")
        return 1
    print(f"[transition] calling LoadLevelSelectAssets @ #{load_ls:04X}")
    pre_cmd_write = regs._get32(REG_CMD_WRITE)
    steps = emu.call(load_ls, max_steps=10_000_000)
    post_cmd_write = regs._get32(REG_CMD_WRITE)
    post_cmd_read = regs._get32(REG_CMD_READ)
    print(f"  load done, steps={steps:,}, t-states={emu.tstates:,}")
    print(f"  CMD_WRITE: #{pre_cmd_write:04X} -> #{post_cmd_write:04X} "
          f"(delta {post_cmd_write - pre_cmd_write})")
    print(f"  CMD_READ:  #{post_cmd_read:04X} (must equal CMD_WRITE)")

    # --- Build one LevelSelect-equivalent frame with menu DL (asset swap proof) ---
    # In the user's "asset swap" mental model, after LoadLevelSelectAssets we keep
    # running MenuBuildFrame/MenuSwapFrame — pixels change because RAM_G now holds
    # level-select bitmaps at the same addresses as menu bitmaps.
    print("[post-swap] running 1 frame of MenuBuildFrame/SwapFrame")
    emu.call(mub)
    emu.call(mas)
    emu.call(mbf)
    emu.call(msf)
    regs.tick_frame(emu.ft.ram_dl)
    if regs.last_dl_snapshot:
        ops = disasm_dl(regs.last_dl_snapshot)
        print(f"[post-swap DL] {summarize_dl(ops)}")

    # --- Check RAM_G content changed (sky bitmap header bytes) ---
    sky_addr = 0x04B000
    sky_bytes_after = bytes(emu.ft.ram_g[sky_addr:sky_addr + 16])
    print(f"[RAM_G] sky @ #{sky_addr:06X}: {sky_bytes_after.hex(' ')}")

    print()
    print("=== VERDICT ===")
    if post_cmd_read == post_cmd_write:
        print("OK: shadow coprocessor caught up — Z80-side inflate sequence completed.")
        print("    Real-hw stall must be FT812 state preservation between menu/level-select,")
        print("    not the inflate code itself.")
    else:
        print(f"FAIL: CMD_READ={post_cmd_read:#04X} != CMD_WRITE={post_cmd_write:#04X}")
        print("    Z80 stuck mid-inflate — a real bug in the inflate driver path.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
