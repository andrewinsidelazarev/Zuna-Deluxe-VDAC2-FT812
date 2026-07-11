#!/usr/bin/env python3
"""Прогнать VDC-состояние из 64K dump вперёд на текущем Z80-коде."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim
from vdc_cache_sync import sync_active_vdc_caches


STATE_ARRAYS = (
    "Core.VDC_Slots",
    "Core.VDC_Offsets",
    "Core.VDC_Shot2",
    "Core.VDC_ExplodeFrame",
    "Core.VDC_ExplodeMarker",
    "Core.VDC_RollbackCnt",
)

STATE_BYTES = (
    "Core.VDC_SlotsLen",
    "Core.VDC_HSA",
    "Core.VDC_HSub",
    "Core.VDC_ChainFreezeCnt",
    "Core.VDC_GapStepCnt",
    "Core.VDC_MatchScanIdx",
    "Core.VDC_GameState",
    "Core.VDC_DialogState",
    "Core.VDC_BallsSpawned",
)


def fmt_slots(values):
    out = []
    for v in values:
        if v == 0xFE:
            out.append("S")
        elif v == 0xFD:
            out.append("C")
        elif v == 0xFF:
            out.append(".")
        else:
            out.append(str(v))
    return "".join(out)


def signed(values):
    return [v - 256 if v >= 128 else v for v in values]


def load_dump_state(sim, dump):
    s = sim.sym
    for name in STATE_ARRAYS:
        if name not in s:
            continue
        base = s[name]
        for i in range(240):
            sim.set_byte(base + i, dump[base + i])
    for name in STATE_BYTES:
        if name in s:
            sim.set_byte(s[name], dump[s[name]])
    sync_active_vdc_caches(sim)


def snapshot(sim):
    s = sim.sym
    ln = sim.get_byte(s["Core.VDC_SlotsLen"])
    slots = list(sim.get_memory(s["Core.VDC_Slots"], ln))
    offsets = signed(sim.get_memory(s["Core.VDC_Offsets"], ln))
    shot2 = list(sim.get_memory(s["Core.VDC_Shot2"], ln))
    exp = list(sim.get_memory(s["Core.VDC_ExplodeFrame"], ln))
    mark = list(sim.get_memory(s["Core.VDC_ExplodeMarker"], ln))
    return ln, slots, offsets, shot2, exp, mark


def raw_runs(slots, offsets, shot2, exp):
    runs = []
    i = 0
    while i < len(slots):
        if slots[i] >= 5 or exp[i]:
            i += 1
            continue
        j = i + 1
        while j < len(slots) and slots[j] == slots[i] and not exp[j]:
            j += 1
        if j - i >= 3:
            runs.append((i, j - 1, slots[i], offsets[i:j], shot2[i:j]))
        i = j
    return runs


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: replay_dump_vdc_forward.py <dump> [frames]")
    dump_path = sys.argv[1]
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 160
    with open(dump_path, "rb") as f:
        dump = f.read()
    if len(dump) != 65536:
        raise SystemExit(f"bad dump size: {len(dump)}")

    sim = ZumaZ80Sim()
    s = sim.sym
    load_dump_state(sim, dump)
    sim.set_byte(s["Core.VDC_GameState"], 0)
    if "Core.VDC_DialogState" in s:
        sim.set_byte(s["Core.VDC_DialogState"], 0)

    prev_slots = None
    for frame in range(frames + 1):
        ln, slots, offsets, shot2, exp, mark = snapshot(sim)
        if frame == 0 or slots != prev_slots:
            print(
                f"frame={frame:03d} len={ln} hsa={sim.get_byte(s['Core.VDC_HSA'])} "
                f"hsub={sim.get_byte(s['Core.VDC_HSub'])} "
                f"freeze={sim.get_byte(s['Core.VDC_ChainFreezeCnt'])} "
                f"gapcnt={sim.get_byte(s['Core.VDC_GapStepCnt'])} "
                f"slots={fmt_slots(slots)}"
            )
            print(f"  offsets={offsets}")
            print(f"  shot2={[i for i, v in enumerate(shot2) if v]}")
            print(f"  explode={[i for i, v in enumerate(exp) if v or mark[i]]}")
            for run in raw_runs(slots, offsets, shot2, exp):
                print(f"  raw_run {run[0]}..{run[1]} color={run[2]} offs={run[3]} shot2={run[4]}")
            prev_slots = slots[:]
        if frame == frames:
            break
        sim.call(s["Core.VDC_AnimateChain"])


if __name__ == "__main__":
    main()
