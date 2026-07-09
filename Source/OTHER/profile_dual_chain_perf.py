#!/usr/bin/env python3
"""Profile full-stack Z80 cost of single-chain vs dual-chain gameplay frames."""
from __future__ import annotations

import bisect
import argparse
import functools
import os
import sys
import time
from collections import Counter
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from full_stack_trace import FullStackTrace  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402
from zx7_dec import dzx7_turbo  # noqa: E402

print = functools.partial(print, flush=True)
ROOT = Path(HERE).parent.parent
CMD = 0x4CB0  # 1024-port: CMD_ADDRESS_PTR #4CB0 (was stale 0x5E00)


def build_symbol_index(sym: dict[str, int]):
    rows = sorted((addr, name) for name, addr in sym.items())
    addrs = [a for a, _ in rows]
    names = [n for _, n in rows]
    return addrs, names


def sym_name(addrs: list[int], names: list[str], pc: int) -> str:
    i = bisect.bisect_right(addrs, pc) - 1
    if i < 0:
        return f"#{pc:04X}"
    off = pc - addrs[i]
    return names[i] if off == 0 else f"{names[i]}+{off}"


def sym_base(addrs: list[int], names: list[str], pc: int) -> str:
    i = bisect.bisect_right(addrs, pc) - 1
    if i < 0:
        return f"#{pc:04X}"
    return names[i]


class Harness:
    def __init__(self, level: int):
        self.level = level
        self.fs = FullStackTrace(ROOT, shadow_ft812=True)
        self.e = self.fs.emu
        self.S = self.fs.sym
        if level == 4:
            track2 = ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l05_2_640.bin"
            data2 = track2.read_bytes()
            start2 = 0x0F * PAGE_SIZE
            self.e.mem.physical[start2 : start2 + PAGE_SIZE] = b"\x00" * PAGE_SIZE
            self.e.mem.physical[start2 : start2 + len(data2)] = data2
        self.addrs, self.names = build_symbol_index(self.S)
        self.zx7_calls = 0
        self.allow_zx7_hook = True
        self._install_fast_step()

    def gb(self, name: str) -> int:
        return self.e.get_byte(self.S[name])

    def gw(self, name: str) -> int:
        return self.e.get_word(self.S[name])

    def sw(self, name: str, value: int) -> None:
        self.e.set_word(self.S[name], value)

    def sb(self, name: str, value: int) -> None:
        self.e.set_byte(self.S[name], value)

    def _ret_now(self, cf: int = 0) -> None:
        e = self.e
        sp = e.reg.SP
        ret = e.mem.read(sp) | (e.mem.read((sp + 1) & 0xFFFF) << 8)
        e.reg.SP = (sp + 2) & 0xFFFF
        e.reg.PC = ret
        if cf:
            e.reg.F |= 0x01
        else:
            e.reg.F &= ~0x01

    def _install_fast_step(self) -> None:
        e = self.e
        S = self.S
        hook_names = (
            "Core.ZiFi_Init",
            "Core.ZiFi_Done",
            "Core.ZiFi_Enter",
            "Core.ZiFi_Leave",
            "Core.ZiFi_PakOpen",
            "Core.ZiFi_Seek0",
            "Core.ZiFi_SkipSectors16",
            "Core.ZiFi_PakReadToc",
            "Core.ZiFi_Load512",
            "Core.RawPak_ReadOneLogicalIX",
            "Core.sd_init",
            "Core.sd_read_sector",
            "FT.Coprocessor.Inflate",
            "FT.ReadMem",
            "FT.WriteMem",
        )
        hook_pcs = {S[n]: n for n in hook_names if n in S}
        loader_hook_prefixes = (
            "Core.ZiFi_",
            "Core.RawPak_",
            "Core.sd_",
            "FT.Coprocessor.Inflate",
            "FT.ReadMem",
            "FT.WriteMem",
        )
        dzx7 = S.get("Dzx7Turbo")
        ret_now = set(
            x
            for x in (
                S.get(n)
                for n in (
                    "FT.Coprocessor.WaitFlush",
                    "FT.Coprocessor.IsFault",
                    "FT.Coprocessor.Wait",
                    "FT.Coprocessor.Write",
                    "FT.Coprocessor.Write32",
                )
            )
            if x is not None
        )
        read8 = S.get("FT.Read8")
        bare = self.fs.orig_step
        hook_pc = self.fs._hook_pc

        def fast() -> int:
            pc = e.reg.PC
            if pc == read8:
                addr = ((e.reg.A & 0xFF) << 16) | ((e.reg.D & 0xFF) << 8) | (e.reg.E & 0xFF)
                if addr == 0x302054:       # FT_REG_DLSWAP: в harness swap считаем завершённым
                    e.reg.A = 0
                    self._ret_now(0)
                    return 0
                if addr == 0x3020A8:       # FT_REG_INT_FLAGS: дать пройти poll swap/int
                    e.reg.A = 1
                    self._ret_now(0)
                    return 0
            if pc in ret_now:
                self._ret_now(0)
                return 0
            if self.allow_zx7_hook and pc == dzx7:
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
                self._ret_now(0)
                self.zx7_calls += 1
                return 0
            hook_name = hook_pcs.get(pc)
            # Символы loader/rawpak живут на тех же виртуальных адресах, что и игровая страница #04.
            # После LoadGameplayAssets не даем старым loader-хукам съесть код VDC.
            if hook_name and not (
                pc >= 0xC000
                and e.mem.pages[3] == 0x04
                and hook_name.startswith(loader_hook_prefixes)
            ) and hook_pc(pc):
                return 0
            return bare()

        e.step = fast
        self.fast_step = fast

    def call(self, name: str, max_steps: int = 4_000_000) -> int:
        e = self.e
        sp = (e.reg.SP - 2) & 0xFFFF
        e.set_word(sp, 0xFFFE)
        e.reg.SP = sp
        e.reg.PC = self.S[name]
        steps = 0
        while e.reg.PC != 0xFFFE:
            e.step()
            steps += 1
            if steps > max_steps:
                raise TimeoutError(f"{name} timeout PC=#{e.reg.PC:04X}")
        return steps

    def prof_call(self, name: str, max_steps: int = 2_000_000) -> tuple[int, Counter[int], float]:
        e = self.e
        base_step = e.step
        pcs: Counter[int] = Counter()

        def profiled() -> int:
            pcs[e.reg.PC] += 1
            return base_step()

        e.step = profiled
        t0 = time.perf_counter()
        try:
            steps = self.call(name, max_steps)
        finally:
            e.step = base_step
        return steps, pcs, time.perf_counter() - t0

    def setup(self) -> None:
        self.call("Core.Init_Core")
        self.sb("Core.CurrentLevel", self.level)
        # Полная загрузка уровня сейчас проходит через PAK/SD staging и несколько
        # RAM_G upload-фаз. 8 млн шагов стало тесным тестовым лимитом: harness
        # обрывался уже на завершающем ZiFi_Init, до возврата из загрузчика.
        self.call("Core.LoadGameplayAssets", max_steps=12_000_000)
        self.e.mem.pages[3] = 0x04
        if "Core.CurrentCodePage" in self.S:
            self.sb("Core.CurrentCodePage", 0x04)
        if "CurrentCodePage" in self.S:
            self.sb("CurrentCodePage", 0x04)
        self.allow_zx7_hook = False

    def run_play_frames(self, frames: int) -> None:
        for _ in range(frames):
            self.sb("Core.VDC_GameState", 0)
            self.call("Core.VDC_UpdateAllChains")

    def cmd_words(self) -> int:
        return ((self.gw("FT.Coprocessor.BufferPtr") - CMD) & 0xFFFF) // 4

    def reset_cmd(self) -> None:
        self.sw("FT.Coprocessor.BufferPtr", CMD)

    def profile_draw_chains(self) -> list[tuple[str, int, int, float, int, Counter[int]]]:
        out = []
        self.call("Core.SetCurrentTrackPage")
        self.reset_cmd()
        steps, pcs, sec = self.prof_call("Core.ZL_DrawActiveChain")
        out.append(("draw_chain1", steps, self.cmd_words(), sec, self.gb("Core.VDC_SlotsLen"), pcs))
        if self.gb("Core.VDC_HasSecondChain"):
            self.call("Core.VDC_SwapChains")
            self.call("Core.SetSecondTrackPage")
            self.reset_cmd()
            steps, pcs, sec = self.prof_call("Core.ZL_DrawActiveChain")
            out.append(("draw_chain2_full", steps, self.cmd_words(), sec, self.gb("Core.VDC_SlotsLen"), pcs))
            self.call("Core.VDC_SwapChains")
            self.call("Core.SetCurrentTrackPage")
        return out

    def print_profile(self, title: str, pcs: Counter[int], limit: int = 12) -> None:
        grouped: Counter[str] = Counter()
        for pc, n in pcs.items():
            grouped[sym_base(self.addrs, self.names, pc)] += n
        print(f"  hot symbols for {title}:")
        for name, n in grouped.most_common(limit):
            print(f"    {n:7d}  {name}")
        print(f"  hot PC for {title}:")
        for pc, n in pcs.most_common(limit):
            print(f"    {n:7d}  #{pc:04X}  {sym_name(self.addrs, self.names, pc)}")

    def profile_full_draw_frame(self) -> tuple[int, int, float, Counter[int]]:
        self.reset_cmd()
        steps, pcs, sec = self.prof_call("Core.ZL_DrawFrame", max_steps=3_000_000)
        return steps, self.cmd_words(), sec, pcs


def run_case(label: str, level: int, warm_frames: int) -> None:
    t0 = time.time()
    h = Harness(level)
    print(f"\n== {label} CurrentLevel={level} ==")
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if "CurrentCodePage" in h.S:
        h.sb("CurrentCodePage", 0x04)
    print(
        f"loaded in {time.time()-t0:.1f}s zx7={h.zx7_calls} "
        f"has2={h.gb('Core.VDC_HasSecondChain')} state={h.gb('Core.VDC_GameState')}"
    )
    h.run_play_frames(warm_frames)
    print(
        f"after {warm_frames} play frames: "
        f"len1={h.gb('Core.VDC_SlotsLen')} len2={h.gb('Core.VDC2_SlotsLen')} "
        f"hsa={h.gb('Core.VDC_HSA')}"
    )

    steps, pcs, sec = h.prof_call("Core.VDC_UpdateAllChains")
    print(f"update_all: steps={steps} host={sec:.3f}s")
    h.print_profile("update_all", pcs)

    steps, pcs, sec = h.prof_call("Core.VDC_Update")
    print(f"update_chain1_only: steps={steps} host={sec:.3f}s")
    h.print_profile("update_chain1_only", pcs, limit=8)
    if h.gb("Core.VDC_HasSecondChain"):
        h.call("Core.VDC_SwapChains")
        h.call("Core.SetSecondTrackPage")
        steps, pcs, sec = h.prof_call("Core.VDC_UpdateActiveChainPlayOnly")
        print(f"update_chain2_only: steps={steps} host={sec:.3f}s")
        h.print_profile("update_chain2_only", pcs, limit=8)
        h.call("Core.VDC_SwapChains")
        h.call("Core.SetCurrentTrackPage")

    for name, steps, words, sec, slots_len, pcs in h.profile_draw_chains():
        print(f"{name}: len={slots_len} steps={steps} cmd_words={words} cmd_bytes={words*4} host={sec:.3f}s")
        h.print_profile(name, pcs)

    try:
        steps, words, sec, pcs = h.profile_full_draw_frame()
        print(f"draw_full_frame: steps={steps} cmd_words={words} cmd_bytes={words*4} host={sec:.3f}s")
        h.print_profile("draw_full_frame", pcs)
    except Exception as exc:
        print(f"draw_full_frame: skipped after harness exception: {exc}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warm-frames", type=int, default=40)
    args = ap.parse_args()
    # L01 — базовый уровень с одной цепочкой; L05 — первый уровень с двумя цепочками.
    run_case("single baseline", 0, args.warm_frames)
    run_case("dual chain", 4, args.warm_frames)


if __name__ == "__main__":
    main()
