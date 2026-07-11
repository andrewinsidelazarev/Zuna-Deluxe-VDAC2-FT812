#!/usr/bin/env python3
"""Снять headless Z80-профиль L19 и отсортировать символы по tstates."""
from __future__ import annotations

import argparse
import bisect
import csv
import datetime as dt
import hashlib
import pickle
import sys
import time
import zlib
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import CMD, Harness  # noqa: E402
from test_dual_chain_fastfill import load_track_v2_pair  # noqa: E402

ROOT = HERE.parent.parent
DIAG = ROOT / "Diagnostics"
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CHECKPOINT_VERSION = 1


@dataclass
class FrameResult:
    tstates: int
    steps: int
    cmd_bytes: int


def install_extra_ft_hooks(h: Harness) -> None:
    # Headless-модель только для ожиданий FT812: не даём загрузчику/кадру
    # висеть на SPI-read, но не подменяем игровую логику.
    e = h.e
    S = h.S
    base_step = e.step
    read8 = S.get("FT.Read8")
    read16 = S.get("FT.Read16")
    write_regs = {
        pc
        for pc in (S.get("FT.WriteReg8"), S.get("FT.WriteReg16"), S.get("FT.WriteReg32"), S.get("FT.SendCommand"))
        if pc is not None
    }
    reg_id = S.get("FT_REG_ID", 0x302000) & 0xFFFF
    reg_cpureset = S.get("FT_REG_CPURESET", 0x302020) & 0xFFFF
    reg_dlswap = S.get("FT_REG_DLSWAP", 0x302054) & 0xFFFF
    reg_int_flags = S.get("FT_REG_INT_FLAGS", 0x3020A8) & 0xFFFF
    reg_cmd_read = S.get("FT_REG_CMD_READ", 0x3020F8) & 0xFFFF
    reg_cmd_write = S.get("FT_REG_CMD_WRITE", 0x3020FC) & 0xFFFF
    reg_cmdb_space = S.get("FT_REG_CMDB_SPACE", 0x302574) & 0xFFFF

    def ret_ok() -> None:
        h._ret_now(0)

    def hooked() -> int:
        pc = e.reg.PC
        de = ((e.reg.D << 8) | e.reg.E) & 0xFFFF
        if pc == read8:
            if de == reg_id:
                e.reg.A = 0x7C
            elif de == reg_int_flags:
                e.reg.A = 0x01
            elif de in (reg_cpureset, reg_dlswap):
                e.reg.A = 0x00
            else:
                e.reg.A = 0x00
            ret_ok()
            return 0
        if pc == read16:
            if de in (reg_cmd_read, reg_cmd_write):
                e.reg.B = 0x00
                e.reg.C = 0x00
            elif de == reg_cmdb_space:
                e.reg.B = 0x0F
                e.reg.C = 0xFC
            else:
                e.reg.B = 0x00
                e.reg.C = 0x00
            ret_ok()
            return 0
        if pc in write_regs:
            ret_ok()
            return 0
        return base_step()

    e.step = hooked
    h.fast_step = hooked


def install_ret_a(h: Harness, name: str, value: int) -> None:
    addr = h.S.get(name)
    if addr is None:
        return
    h.e.mem.write(addr, 0x3E)      # LD A,n
    h.e.mem.write(addr + 1, value & 0xFF)
    h.e.mem.write(addr + 2, 0xC9)  # RET


def setup_l19_gameplay(h: Harness, max_steps: int) -> None:
    install_ret_a(h, "Core.ReadRTCSeconds", 17)
    load_track_v2_pair(h.e, PACK / "track_l19_640.bin", PACK / "track_l19_2_640.bin")
    h.sb("Core.CurrentLevel", 18)
    h.sb("Core.CurrentDifficulty", 0)
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if "CurrentCodePage" in h.S:
        h.sb("CurrentCodePage", 0x04)
    h.e.mem.pages[3] = 0x04
    h.sb("Core.ZL_SpinK", h.S.get("Core.ZL_SPIN_K_DEFAULT", 81) & 0xFF)
    h.call("Core.VDC_Init", max_steps=max_steps)
    h.call("Core.Frog_Init", max_steps=max_steps)
    h.call("Core.Bullet_Init", max_steps=max_steps)
    h.sb("Core.VDC_GameState", 0)
    h.call("Core.SetCurrentTrackPage", max_steps=max_steps)


def build_signature() -> str:
    return hashlib.sha256((ROOT / "Build" / "zuma.sym").read_bytes()).hexdigest()


def save_warm_checkpoint(h: Harness, path: Path, warm_count: int) -> None:
    state = {
        "version": CHECKPOINT_VERSION,
        "build_signature": build_signature(),
        "warm_count": warm_count,
        "physical": zlib.compress(bytes(h.e.mem.physical), level=1),
        "pages": list(h.e.mem.pages),
        "registers": {
            name: value
            for name, value in h.e.reg.items()
            if name != "condition"
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(pickle.dumps(state, protocol=pickle.HIGHEST_PROTOCOL))


def load_warm_checkpoint(h: Harness, path: Path) -> int:
    state = pickle.loads(path.read_bytes())
    if state.get("version") != CHECKPOINT_VERSION:
        raise RuntimeError(f"unsupported checkpoint version: {state.get('version')}")
    if state.get("build_signature") != build_signature():
        raise RuntimeError("warm checkpoint belongs to a different Build/zuma.sym")
    physical = zlib.decompress(state["physical"])
    if len(physical) != len(h.e.mem.physical):
        raise RuntimeError(f"checkpoint physical RAM size mismatch: {len(physical)}")
    h.e.mem.physical[:] = physical
    h.e.mem.pages[:] = state["pages"]
    for name, value in state["registers"].items():
        h.e.reg[name] = value
    h.fs.last_pages = tuple(h.e.mem.pages)
    return int(state["warm_count"])


def is_gameplay_slot3_symbol(name: str) -> bool:
    blocked = (
        "Core.sd_",
        "Core.qsd_",
        "Core.ZiFi_",
        "Core.RawPak_",
        "Core.Menu",
        "Core.LoadMainMenu",
        "Core.LoadLevelSelect",
        "Core.MoreGames",
        "Core.UploadBoot",
    )
    return not name.startswith(blocked)


def build_symbol_index(sym: dict[str, int], *, gameplay_slot3: bool = False) -> tuple[list[int], list[str]]:
    rows_by_addr: dict[int, list[str]] = defaultdict(list)
    for name, addr in sym.items():
        if not (0 <= addr <= 0xFFFF):
            continue
        if gameplay_slot3 and not is_gameplay_slot3_symbol(name):
            continue
        rows_by_addr[addr].append(name)
    rows = sorted((addr, choose_symbol(names)) for addr, names in rows_by_addr.items())
    return [addr for addr, _ in rows], [name for _, name in rows]


def choose_symbol(names: list[str]) -> str:
    priority_prefixes = (
        "Core.VDC_",
        "Core.ZL_",
        "Core.Frog_",
        "Core.Bullet_",
        "Core.Input_",
        "Core.Update",
        "Core.Draw",
        "Core.Esc",
        "Core.GS_",
        "FT.",
    )

    def key(name: str) -> tuple[int, int, str]:
        prefix_score = 0
        for idx, prefix in enumerate(priority_prefixes):
            if name.startswith(prefix):
                prefix_score = len(priority_prefixes) - idx
                break
        local_penalty = name.count(".")
        return (prefix_score, -local_penalty, name)

    return max(names, key=key)


def nearest_symbol(addrs: list[int], names: list[str], pc: int) -> str:
    i = bisect.bisect_right(addrs, pc) - 1
    if i < 0:
        return f"#{pc:04X}"
    return names[i]


def fold_symbol(name: str) -> str:
    if name.startswith("Core."):
        body = name[5:]
        if "." in body:
            return "Core." + body.split(".", 1)[0]
    return name.split(".", 1)[0] if "." in name and not name.startswith("Core.") else name


def make_profiler(h: Harness) -> tuple[Counter[str], Counter[str], Counter[tuple[int, int]], callable, callable, callable]:
    addrs, names = build_symbol_index(h.S)
    game_addrs, game_names = build_symbol_index(h.S, gameplay_slot3=True)
    by_symbol: Counter[str] = Counter()
    by_folded: Counter[str] = Counter()
    by_pc: Counter[tuple[int, int]] = Counter()
    base_step = h.e.step

    def symbol_for(pc: int, page: int) -> str:
        if 0xC000 <= pc <= 0xFFFF and page == 0x04:
            return nearest_symbol(game_addrs, game_names, pc)
        return nearest_symbol(addrs, names, pc)

    def profiled_step() -> int:
        pc = h.e.reg.PC
        page = h.e.mem.pages[(pc >> 14) & 3]
        ts = base_step()
        sym = symbol_for(pc, page)
        by_symbol[sym] += ts
        by_folded[fold_symbol(sym)] += ts
        by_pc[(page, pc)] += ts
        return ts

    def install() -> None:
        h.e.step = profiled_step

    def restore() -> None:
        h.e.step = base_step

    return by_symbol, by_folded, by_pc, install, restore, symbol_for


def run_mainloop_frame(h: Harness, loop_pc: int, max_steps: int) -> FrameResult:
    e = h.e
    e.reg.PC = loop_pc
    start_t = e.tstates
    steps = 0
    while True:
        e.step()
        steps += 1
        if steps > max_steps:
            raise TimeoutError(f"MainLoop frame timeout PC=#{e.reg.PC:04X}")
        if steps > 1 and e.reg.PC == loop_pc:
            break
    cmd_bytes = ((h.gw("FT.Coprocessor.BufferPtr") - CMD) & 0xFFFF)
    return FrameResult(e.tstates - start_t, steps, cmd_bytes)


def write_counter_csv(path: Path, counter: Counter, frames: int) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["name", "avg_tstates_per_frame", "total_tstates", "percent"])
        total = sum(counter.values()) or 1
        for name, value in counter.most_common():
            w.writerow([name, value // frames, value, f"{value * 100.0 / total:.2f}"])


def write_pc_csv(path: Path, counter: Counter[tuple[int, int]], symbol_for: callable, frames: int) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["page", "pc", "symbol", "avg_tstates_per_frame", "total_tstates", "percent"])
        total = sum(counter.values()) or 1
        for (page, pc), value in counter.most_common():
            w.writerow([f"#{page:02X}", f"#{pc:04X}", symbol_for(pc, page), value // frames, value, f"{value * 100.0 / total:.2f}"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=120)
    ap.add_argument("--warm-frames", type=int, default=120)
    ap.add_argument("--warm-max-frames", type=int, default=2000)
    ap.add_argument("--prewarm-mainloop-frames", type=int, default=3)
    ap.add_argument("--min-slots", type=int, default=90)
    ap.add_argument("--max-steps", type=int, default=5_000_000)
    ap.add_argument("--checkpoint-in", type=Path)
    ap.add_argument("--checkpoint-out", type=Path)
    ap.add_argument(
        "--warm-chunk-frames",
        type=int,
        default=0,
        help="run at most this many warm frames, save checkpoint, and exit",
    )
    ns = ap.parse_args()

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = DIAG / f"L19_headless_z80_tstates_{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    h = Harness(18)
    # Собственный profiler ниже считает PC/t-states только на измеряемых кадрах.
    # Общий FullStackTrace ring на каждом warmup-шаге дублирует эту работу и
    # делает прогрев 70+70 неоправданно долгим.
    h.fs.capture_step_trace = False
    install_extra_ft_hooks(h)
    setup_l19_gameplay(h, ns.max_steps)
    warm_count = 0
    if ns.checkpoint_in is not None:
        warm_count = load_warm_checkpoint(h, ns.checkpoint_in)
    print(
        f"setup L19: has2={h.gb('Core.VDC_HasSecondChain')} "
        f"tns1={h.gw('Core.VDC_TrackNumSlots')} "
        f"len={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')} warm={warm_count}",
        flush=True,
    )

    warm_stop = ns.warm_max_frames
    if ns.warm_chunk_frames > 0:
        warm_stop = min(warm_stop, warm_count + ns.warm_chunk_frames)
    while warm_count < warm_stop:
        if warm_count >= ns.warm_frames and min(
            h.gb("Core.VDC_SlotsLen"), h.gb("Core.VDC2_SlotsLen")
        ) >= ns.min_slots:
            break
        h.sb("Core.VDC_GameState", 0)
        h.call("Core.VDC_UpdateAllChains", max_steps=ns.max_steps)
        warm_count += 1
        if warm_count % 40 == 0:
            print(
                f"warm {warm_count}: len={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')} "
                f"hsa={h.gb('Core.VDC_HSA')}",
                flush=True,
            )
        if warm_count >= ns.warm_frames and min(h.gb("Core.VDC_SlotsLen"), h.gb("Core.VDC2_SlotsLen")) >= ns.min_slots:
            break
    if ns.warm_chunk_frames > 0:
        if ns.checkpoint_out is None:
            raise RuntimeError("--warm-chunk-frames requires --checkpoint-out")
        save_warm_checkpoint(h, ns.checkpoint_out, warm_count)
        print(
            f"checkpoint {ns.checkpoint_out}: warm={warm_count} "
            f"len={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')}",
            flush=True,
        )
        return 0
    if min(h.gb("Core.VDC_SlotsLen"), h.gb("Core.VDC2_SlotsLen")) < ns.min_slots:
        print(
            f"warning: min_slots={ns.min_slots} not reached, "
            f"len={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')} after warm={warm_count}",
            flush=True,
        )

    loop_pc = h.S["Core.MainLoop.Loop"]
    for j in range(ns.prewarm_mainloop_frames):
        h.sb("Core.VDC_GameState", 0)
        fr = run_mainloop_frame(h, loop_pc, ns.max_steps)
        print(
            f"prewarm mainloop {j + 1}/{ns.prewarm_mainloop_frames}: "
            f"tstates={fr.tstates} len={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')}",
            flush=True,
        )

    by_symbol, by_folded, by_pc, install, restore, symbol_for = make_profiler(h)
    frames: list[FrameResult] = []
    host_t0 = time.perf_counter()
    install()
    try:
        for i in range(ns.frames):
            h.sb("Core.VDC_GameState", 0)
            frames.append(run_mainloop_frame(h, loop_pc, ns.max_steps))
            if (i + 1) % 20 == 0:
                print(f"measure {i + 1}/{ns.frames}", flush=True)
    finally:
        restore()
    host_sec = time.perf_counter() - host_t0

    total_t = sum(fr.tstates for fr in frames)
    avg_t = total_t // len(frames)
    max_t = max(fr.tstates for fr in frames)
    avg_steps = sum(fr.steps for fr in frames) // len(frames)
    max_cmd = max(fr.cmd_bytes for fr in frames)

    write_counter_csv(out_dir / "symbols_folded_sorted.csv", by_folded, len(frames))
    write_counter_csv(out_dir / "symbols_raw_sorted.csv", by_symbol, len(frames))
    write_pc_csv(out_dir / "pc_sorted.csv", by_pc, symbol_for, len(frames))

    top = by_folded.most_common(30)
    report = out_dir / "z80_tstates_sorted.txt"
    with report.open("w", encoding="utf-8") as f:
        f.write("Zuma VDAC2 L19 headless Z80 tstates profile\n")
        f.write(
            f"frames={len(frames)} warm_frames={warm_count} "
            f"prewarm_mainloop_frames={ns.prewarm_mainloop_frames} "
            f"min_slots={ns.min_slots} host_seconds={host_sec:.3f}\n"
        )
        f.write(
            f"CurrentLevel={h.gb('Core.CurrentLevel')} loop_pc=#{loop_pc:04X} "
            f"slots={h.gb('Core.VDC_SlotsLen')}+{h.gb('Core.VDC2_SlotsLen')} "
            f"has2={h.gb('Core.VDC_HasSecondChain')} hsa={h.gb('Core.VDC_HSA')}\n"
        )
        f.write(f"total_avg_tstates_per_frame={avg_t} total_max_frame_tstates={max_t} avg_steps={avg_steps} max_cmd_bytes={max_cmd}\n\n")
        f.write(f"{'symbol':45} {'avg/frame':>12} {'total':>12} {'percent':>8}\n")
        total_grouped = sum(by_folded.values()) or 1
        for name, value in top:
            f.write(f"{name[:45]:45} {value // len(frames):12d} {value:12d} {value * 100.0 / total_grouped:7.2f}%\n")

    print(report)
    print(f"frames={len(frames)} avg_tstates={avg_t} max_tstates={max_t} avg_steps={avg_steps} max_cmd_bytes={max_cmd}")
    print("top:")
    for name, value in top[:15]:
        print(f"{value // len(frames):8d}  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
