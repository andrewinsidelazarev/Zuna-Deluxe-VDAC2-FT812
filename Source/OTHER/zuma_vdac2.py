#!/usr/bin/env python3
"""Unified VDAC2 harness CLI (по образцу TS-Conf zuma_ts_emulator.py).

Объединяет ~20 разрозненных скриптов в Source/OTHER/ под один entry-point.
Распределение по backend'ам фиксированно по тесту:
    lite (kosarev/z80, ZumaZ80Sim)  : wrong-target, tail-glitch
    full (cburbridge, ZumaFullZ80Emulator) : match3-stuck, stack, call/game-frames

Usage:
    py -3.12 zuma_vdac2.py --call Core.VDC_Init
    py -3.12 zuma_vdac2.py --test wrong-target --scenario S1
    py -3.12 zuma_vdac2.py --test wrong-target --scenario all
    py -3.12 zuma_vdac2.py --test tail-glitch
    py -3.12 zuma_vdac2.py --test match3-stuck --frames 3000
    py -3.12 zuma_vdac2.py --test stack --symbol Core.VDC_Init
    py -3.12 zuma_vdac2.py --game-frames 5 --vdc-state

Старые скрипты (test_wrong_target_v2.py, stress_*, test_tail_glitch.py,
replay_match3_stuck_full.py) остаются как есть для совместимости.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

# Lite backend (kosarev/z80 pip) — eager import. Used by wrong-target, tail-glitch.
from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

CELL_SIZE = 32
TRACK_BIN = PROJECT_ROOT / "Graphics" / "Converted" / "track_640.bin"


def _import_full() -> Any:
    """Lazy import cburbridge full backend. Purges kosarev z80 from sys.modules
    first so the cburbridge `_z80_lib_cburbridge/src/z80` package wins.

    After calling this, ZumaZ80Sim must NOT be used in the same process — its
    `z80` reference is stale. Tests are dispatched one-per-process, so OK.
    """
    for k in list(sys.modules):
        if k == "z80" or k.startswith("z80."):
            del sys.modules[k]
    if "zuma_full_z80_emulator" in sys.modules:
        del sys.modules["zuma_full_z80_emulator"]
    from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402
    return ZumaFullZ80Emulator


def _format_slots(slots) -> str:
    out = []
    for v in slots:
        if v == 0xFE:
            out.append("S")
        elif v == 0xFD:
            out.append("C")
        elif v == 0xFF:
            out.append(".")
        else:
            out.append(str(v))
    return "".join(out)


# =============================================================================
# Common helpers (lite backend / ZumaZ80Sim)
# =============================================================================
def lite_fresh() -> ZumaZ80Sim:
    """Create lite sim, load track to #8000, call VDC_Init, force TrackNumSlots=85."""
    sim = ZumaZ80Sim()
    track = TRACK_BIN.read_bytes()
    for i, b in enumerate(track):
        sim.set_byte(0x8000 + i, b)
    sim.call(sim.sym["Core.VDC_Init"])
    sim.set_byte(sim.sym["Core.VDC_TrackNumSlots"], 85)
    sim.set_byte(sim.sym["Core.VDC_TrackNumSlots"] + 1, 0)
    return sim


def lite_setup_chain(sim: ZumaZ80Sim, hsa: int, hsub: int, chain: List[int],
                     offsets: Optional[List[int]] = None,
                     balls_spawned: int = 85) -> None:
    """Inject chain state directly into VDC vars."""
    S = sim.sym
    sim.set_byte(S["Core.VDC_HSA"], hsa & 0xFF)
    sim.set_byte(S["Core.VDC_HSA"] + 1, (hsa >> 8) & 0xFF)
    sim.set_byte(S["Core.VDC_HSub"], hsub & 0xFF)
    sim.set_byte(S["Core.VDC_SlotsLen"], len(chain))
    sim.set_byte(S["Core.VDC_BallsSpawned"], balls_spawned)
    for i, c in enumerate(chain):
        sim.set_byte(S["Core.VDC_Slots"] + i, c & 0xFF)
        off = (offsets[i] if offsets else 0) & 0xFF
        sim.set_byte(S["Core.VDC_Offsets"] + i, off)


def lite_slot_pos(sim: ZumaZ80Sim, i: int) -> Tuple[int, int, int]:
    """Call VDC_SlotPos(A=i), return (cf, x_signed, y_signed)."""
    sim.call(sim.sym["Core.VDC_SlotPos"], a=i)
    cf = sim.cpu.f & 1
    bc = sim.cpu.bc
    de = sim.cpu.de
    x = bc - 0x10000 if bc >= 0x8000 else bc
    y = de - 0x10000 if de >= 0x8000 else de
    return cf, x, y


def lite_fire_bullet(sim: ZumaZ80Sim, x: int, y: int, color: int) -> None:
    S = sim.sym
    sim.set_byte(S["Core.Bullet_Active"], 1)
    sim.set_byte(S["Core.Bullet_Color"], color & 0xFF)
    sim.set_byte(S["Core.Bullet_X"],     x & 0xFF)
    sim.set_byte(S["Core.Bullet_X"] + 1, (x >> 8) & 0xFF)
    sim.set_byte(S["Core.Bullet_Y"],     y & 0xFF)
    sim.set_byte(S["Core.Bullet_Y"] + 1, (y >> 8) & 0xFF)


def lite_run_collision(sim: ZumaZ80Sim) -> int:
    return sim.call(sim.sym["Core.Bullet_CheckCollision"])


def lite_snapshot(sim: ZumaZ80Sim, span: int = 240) -> Dict:
    S = sim.sym
    return {
        "slots":   [sim.get_byte(S["Core.VDC_Slots"]   + i) for i in range(span)],
        "offsets": [sim.get_byte(S["Core.VDC_Offsets"] + i) for i in range(span)],
        "shot2":   [sim.get_byte(S["Core.VDC_Shot2"]   + i) for i in range(span)],
        "hsa":     sim.get_byte(S["Core.VDC_HSA"]),
        "hsa_hi":  sim.get_byte(S["Core.VDC_HSA"] + 1),
        "hsub":    sim.get_byte(S["Core.VDC_HSub"]),
        "len":     sim.get_byte(S["Core.VDC_SlotsLen"]),
        "balls":   sim.get_byte(S["Core.VDC_BallsSpawned"]),
    }


def lite_restore(sim: ZumaZ80Sim, snap: Dict) -> None:
    S = sim.sym
    for i, v in enumerate(snap["slots"]):
        sim.set_byte(S["Core.VDC_Slots"] + i, v)
    for i, v in enumerate(snap["offsets"]):
        sim.set_byte(S["Core.VDC_Offsets"] + i, v)
    for i, v in enumerate(snap["shot2"]):
        sim.set_byte(S["Core.VDC_Shot2"] + i, v)
    sim.set_byte(S["Core.VDC_HSA"],     snap["hsa"])
    sim.set_byte(S["Core.VDC_HSA"] + 1, snap["hsa_hi"])
    sim.set_byte(S["Core.VDC_HSub"],    snap["hsub"])
    sim.set_byte(S["Core.VDC_SlotsLen"], snap["len"])
    sim.set_byte(S["Core.VDC_BallsSpawned"], snap["balls"])


def find_insert_idx(chain_before: List[int], chain_after: List[int]) -> Optional[int]:
    """Locate where a new ball was inserted (chain grew by 1)."""
    if len(chain_after) != len(chain_before) + 1:
        return None
    for i in range(len(chain_before) + 1):
        if i == len(chain_before):
            return i
        if chain_after[i] != chain_before[i]:
            return i
    return None


def nearest_manhattan(positions: List[Tuple[int, int, int]],
                      bullet_x: int, bullet_y: int) -> Tuple[int, int]:
    """positions = list of (idx, x, y). Return (idx_of_nearest, distance)."""
    dists = [(idx, abs(bullet_x - x) + abs(bullet_y - y)) for idx, x, y in positions]
    return min(dists, key=lambda t: t[1])


# =============================================================================
# Test: wrong-target — 6 scenarios (S1, S2, S3, natural, post-match3, spiral)
# =============================================================================
def test_wrong_target_S1() -> int:
    """bbox overlap при сжатой цепи (offsets ≠ 0 после match-3 / insert)."""
    print("=== S1: bbox overlap (compressed chain, offsets≠0) ===")
    sim = lite_fresh()
    chain = [0, 1, 2, 3, 0, 1]
    offsets = [0, -8, 0, -8, 0, 0]
    lite_setup_chain(sim, 20, 0, chain, offsets)
    positions = [lite_slot_pos(sim, i) for i in range(6)]
    real = [(i, x, y) for i, (cf, x, y) in enumerate(positions) if not cf]
    print(f"  valid positions: {len(real)}")
    p1, p2 = positions[1], positions[2]
    bullet_x = (p1[1] + p2[1]) // 2
    bullet_y = (p1[2] + p2[2]) // 2
    lite_fire_bullet(sim, bullet_x, bullet_y, 2)
    print(f"  bullet @ ({bullet_x}, {bullet_y})")
    lite_run_collision(sim)
    ln_after = sim.get_byte(sim.sym["Core.VDC_SlotsLen"])
    chain_after = [sim.get_byte(sim.sym["Core.VDC_Slots"] + i) for i in range(ln_after)]
    inserted = find_insert_idx(chain, chain_after)
    nearest_i, nearest_d = nearest_manhattan(real, bullet_x, bullet_y)
    print(f"  chain after: {chain_after} (inserted at idx={inserted})")
    print(f"  nearest by Manhattan: i={nearest_i} (d={nearest_d})")
    if inserted is not None and nearest_d < 20 and inserted != nearest_i:
        print(f"  >>> S1: insert at {inserted} ≠ nearest {nearest_i} <<<")
        return 2
    return 0


def test_wrong_target_S2() -> int:
    """bullet рядом с GAP marker (CASCADE в середине)."""
    print("=== S2: gap-adjacent (CASCADE in middle) ===")
    sim = lite_fresh()
    GAP_CASCADE = 0xFD
    chain = [0, 1, GAP_CASCADE, 3, 0, 1]
    lite_setup_chain(sim, 20, 0, chain)
    positions = [lite_slot_pos(sim, i) for i in range(6)]
    gap_pos = positions[2]
    bullet_x, bullet_y = gap_pos[1], gap_pos[2]
    lite_fire_bullet(sim, bullet_x, bullet_y, 1)
    print(f"  bullet @ gap position ({bullet_x}, {bullet_y})")
    lite_run_collision(sim)
    ln_after = sim.get_byte(sim.sym["Core.VDC_SlotsLen"])
    chain_after = [sim.get_byte(sim.sym["Core.VDC_Slots"] + i) for i in range(ln_after)]
    inserted = find_insert_idx(chain, chain_after)
    print(f"  chain after: {chain_after} (inserted at idx={inserted})")
    return 0


def test_wrong_target_S3() -> int:
    """cascade state — offsets ≠ 0 (decay phase)."""
    print("=== S3: decay phase (head_comp +CS) ===")
    sim = lite_fresh()
    chain = [0, 1, 2, 3, 0, 1]
    offsets = [32, 32, 32, 32, 0, 0]
    lite_setup_chain(sim, 19, 0, chain, offsets)
    positions = [lite_slot_pos(sim, i) for i in range(6)]
    real = [(i, x, y) for i, (cf, x, y) in enumerate(positions) if not cf and chain[i] < 4]
    p2, p3 = positions[2], positions[3]
    bullet_x = (p2[1] + p3[1]) // 2
    bullet_y = (p2[2] + p3[2]) // 2
    lite_fire_bullet(sim, bullet_x, bullet_y, 1)
    print(f"  bullet @ ({bullet_x}, {bullet_y})")
    lite_run_collision(sim)
    ln_after = sim.get_byte(sim.sym["Core.VDC_SlotsLen"])
    chain_after = [sim.get_byte(sim.sym["Core.VDC_Slots"] + i) for i in range(ln_after)]
    inserted = find_insert_idx(chain, chain_after)
    nearest_i, _ = nearest_manhattan(real, bullet_x, bullet_y) if real else (None, None)
    print(f"  chain after: {chain_after} (inserted at idx={inserted})")
    print(f"  nearest by Manhattan: i={nearest_i}")
    if inserted is not None and nearest_i is not None and abs(inserted - nearest_i) > 1:
        print(f"  >>> S3 SUSPICIOUS: insert={inserted} ≠ nearest={nearest_i} <<<")
        return 2
    return 0


def test_wrong_target_natural(chain_len: int = 35, delta_threshold: int = 3) -> int:
    """Natural chain, грид выстрелов вокруг каждого реального слота."""
    print(f"=== natural: chain_len={chain_len}, grid bullets per slot ===")
    sim = lite_fresh()
    chain = [(i % 4) for i in range(chain_len)]
    lite_setup_chain(sim, 50, 0, chain)
    positions = [lite_slot_pos(sim, i) for i in range(chain_len)]
    real = [(i, x, y) for i, (cf, x, y) in enumerate(positions) if not cf]
    print(f"  valid positions: {len(real)}")
    if not real:
        print("  NO valid positions — abort")
        return 1
    snap = lite_snapshot(sim)
    bad = []
    for i, x, y in real:
        for dx in (-12, -6, 0, 6, 12):
            for dy in (-12, -6, 0, 6, 12):
                lite_restore(sim, snap)
                lite_fire_bullet(sim, x + dx, y + dy, 2)
                lite_run_collision(sim)
                new_len = sim.get_byte(sim.sym["Core.VDC_SlotsLen"])
                if new_len == chain_len:
                    continue
                chain_after = [sim.get_byte(sim.sym["Core.VDC_Slots"] + k)
                               for k in range(new_len)]
                inserted = None
                for k in range(new_len):
                    if chain_after[k] != (k % 4):
                        inserted = k
                        break
                if inserted is None:
                    continue
                nearest, nd = nearest_manhattan(real, x + dx, y + dy)
                delta = abs(inserted - nearest)
                if delta > delta_threshold:
                    bad.append({"bullet": (x + dx, y + dy), "aimed": i,
                                "inserted": inserted, "nearest": nearest,
                                "delta": delta, "d": nd})
    print(f"  tested bullets: {len(real) * 25}")
    print(f"  wrong-target events (|insert - nearest| > {delta_threshold}): {len(bad)}")
    for b in bad[:10]:
        print(f"    bullet@{b['bullet']} aimed={b['aimed']:2d} "
              f"inserted={b['inserted']:3d} nearest={b['nearest']:2d} "
              f"(d={b['d']}) delta={b['delta']}")
    return 2 if bad else 0


def test_wrong_target_spiral(chain_len: int = 80) -> int:
    """Spiral wraparound — pairs with bbox overlap on different turns."""
    print(f"=== spiral: chain_len={chain_len}, overlap pairs ===")
    sim = lite_fresh()
    chain = [(i % 4) for i in range(chain_len)]
    lite_setup_chain(sim, chain_len, 0, chain)
    positions = [lite_slot_pos(sim, i) for i in range(chain_len)]
    real = [(i, x, y) for i, (cf, x, y) in enumerate(positions) if not cf]
    print(f"  valid positions: {len(real)}")
    THR = 16
    overlap = [(i, j, xi, yi, xj, yj)
               for (i, xi, yi) in real
               for (j, xj, yj) in real
               if j > i + 3 and abs(xi - xj) < THR * 2 and abs(yi - yj) < THR * 2]
    print(f"  overlap pairs (j > i+3): {len(overlap)}")
    if not overlap:
        return 0
    snap = lite_snapshot(sim)
    wrong = []
    for (i, j, xi, yi, xj, yj) in overlap:
        bx = (xi + xj) // 2
        by = (yi + yj) // 2
        if abs(bx - xi) >= THR or abs(by - yi) >= THR:
            continue
        if abs(bx - xj) >= THR or abs(by - yj) >= THR:
            continue
        lite_restore(sim, snap)
        lite_fire_bullet(sim, bx, by, 2)
        lite_run_collision(sim)
        new_len = sim.get_byte(sim.sym["Core.VDC_SlotsLen"])
        if new_len == chain_len:
            continue
        chain_after = [sim.get_byte(sim.sym["Core.VDC_Slots"] + k)
                       for k in range(new_len)]
        inserted = None
        for k in range(new_len):
            if chain_after[k] != (k % 4):
                inserted = k
                break
        if inserted is None:
            continue
        nearest, nd = nearest_manhattan(real, bx, by)
        delta = abs(inserted - nearest)
        if delta > 3:
            wrong.append({"bullet": (bx, by), "pair": (i, j),
                          "inserted": inserted, "nearest": nearest,
                          "delta": delta, "d": nd})
    print(f"  wrong-target events: {len(wrong)}")
    for w in wrong[:10]:
        print(f"    bullet@{w['bullet']} pair={w['pair']} "
              f"inserted={w['inserted']:3d} nearest={w['nearest']:2d} "
              f"(d={w['d']}) delta={w['delta']}")
    return 2 if wrong else 0


def test_wrong_target_post_match3(chain_len: int = 25,
                                  skip_step: int = 8, max_skip: int = 32) -> int:
    """Wrong-target ПОСЛЕ match-3 cascade (transient decay state)."""
    print(f"=== post-match3: chain_len={chain_len}, skip_step={skip_step} ===")
    chain_template = [(i % 4) for i in range(chain_len)]
    chain_template[10] = chain_template[11] = chain_template[12] = 1
    bad = []
    for skip in range(0, max_skip + 1, skip_step):
        sim = lite_fresh()
        S = sim.sym
        lite_setup_chain(sim, 40, 0, chain_template)
        sim.set_byte(S["Core.VDC_TmpInsIdx"], 11)
        sim.call(S["Core.VDC_CheckMatch3"])
        for _ in range(skip):
            sim.call(S["Core.VDC_Update"])
            fc = sim.get_word(S["Core.ZL_FrameCounter"])
            sim.set_byte(S["Core.ZL_FrameCounter"],     (fc + 1) & 0xFF)
            sim.set_byte(S["Core.ZL_FrameCounter"] + 1, ((fc + 1) >> 8) & 0xFF)
        cur_len = sim.get_byte(S["Core.VDC_SlotsLen"])
        positions = [lite_slot_pos(sim, i) for i in range(cur_len)]
        real = [(i, x, y) for i, (cf, x, y) in enumerate(positions) if not cf]
        if not real:
            continue
        snap_after = lite_snapshot(sim)
        for ball_idx, bx, by in real:
            for dx in (-8, 0, 8):
                for dy in (-8, 0, 8):
                    lite_restore(sim, snap_after)
                    lite_fire_bullet(sim, bx + dx, by + dy, 2)
                    lite_run_collision(sim)
                    new_len = sim.get_byte(S["Core.VDC_SlotsLen"])
                    if new_len == cur_len:
                        continue
                    chain_after = [sim.get_byte(S["Core.VDC_Slots"] + k)
                                   for k in range(new_len)]
                    inserted = None
                    for k in range(new_len):
                        if k >= cur_len or chain_after[k] != snap_after["slots"][k]:
                            inserted = k
                            break
                    if inserted is None:
                        continue
                    nearest, nd = nearest_manhattan(real, bx + dx, by + dy)
                    delta = abs(inserted - nearest)
                    if delta > 3:
                        bad.append({"skip": skip, "bullet": (bx + dx, by + dy),
                                    "inserted": inserted, "nearest": nearest,
                                    "delta": delta, "d": nd, "len": cur_len})
    print(f"  wrong-target events: {len(bad)}")
    for b in bad[:10]:
        print(f"    skip={b['skip']:2d} bullet@{b['bullet']} len={b['len']} "
              f"inserted={b['inserted']:3d} nearest={b['nearest']:2d} "
              f"(d={b['d']}) delta={b['delta']}")
    return 2 if bad else 0


WRONG_TARGET_SCENARIOS = {
    "S1": test_wrong_target_S1,
    "S2": test_wrong_target_S2,
    "S3": test_wrong_target_S3,
    "natural": test_wrong_target_natural,
    "spiral": test_wrong_target_spiral,
    "post-match3": test_wrong_target_post_match3,
}


def test_wrong_target(scenario: str) -> int:
    if scenario == "all":
        rc = 0
        for name in ("S1", "S2", "S3", "natural", "spiral", "post-match3"):
            rc |= WRONG_TARGET_SCENARIOS[name]()
            print()
        return rc
    fn = WRONG_TARGET_SCENARIOS.get(scenario)
    if fn is None:
        print(f"unknown scenario: {scenario}. valid: {list(WRONG_TARGET_SCENARIOS)} + 'all'")
        return 1
    return fn()


# =============================================================================
# Test: tail-glitch — cap-state insert
# =============================================================================
def test_tail_glitch(target: int = 42, color: int = 1) -> int:
    print(f"=== tail-glitch: cap state, InsertAt(target={target}, color={color}) ===")
    sim = ZumaZ80Sim()
    S = sim.sym
    sim.call(S["Core.VDC_Init"])
    sim.set_byte(S["Core.VDC_TrackNumSlots"],     85)
    sim.set_byte(S["Core.VDC_TrackNumSlots"] + 1, 0)
    HSA = 85
    SLOTS_LEN = 85
    sim.set_byte(S["Core.VDC_HSA"], HSA)
    sim.set_byte(S["Core.VDC_HSA"] + 1, 0)
    sim.set_byte(S["Core.VDC_HSub"], 0)
    sim.set_byte(S["Core.VDC_SlotsLen"], SLOTS_LEN)
    sim.set_byte(S["Core.VDC_BallsSpawned"], 85)
    for i in range(SLOTS_LEN):
        sim.set_byte(S["Core.VDC_Slots"] + i, [0, 1, 2][i % 3])

    def t_of(state, i):
        return (state["hsa"] - i) * CELL_SIZE + state["hsub"] + state["offsets"][i]

    before = sim.vdc_state()
    print(f"  BEFORE: HSA={before['hsa']} HSub={before['hsub']} len={before['slots_len']}")
    print(f"          t(tail=84)={t_of(before, 84)}  t(mid=42)={t_of(before, 42)}")

    sim.call(S["Core.VDC_InsertAt"], a=target, b=color)

    after = sim.vdc_state()
    new_tail = after["slots_len"] - 1
    print(f"  AFTER : HSA={after['hsa']} HSub={after['hsub']} len={after['slots_len']}")
    print(f"          slots[40..45]={after['slots'][40:45]}  slots[80..86]={after['slots'][-6:]}")
    print(f"          t(new_tail={new_tail})={t_of(after, new_tail)}")
    tail_shift = t_of(after, new_tail) - t_of(before, SLOTS_LEN - 1)
    print(f"  TAIL-SHIFT: {tail_shift} samples ({tail_shift * 1.08:+.1f} px)")
    if tail_shift < 0:
        print(f"  >>> BUG REPRODUCED: tail shifted -{-tail_shift} samples toward spawn <<<")
        return 2
    print("  no negative tail-shift")
    return 0


# =============================================================================
# Test: match3-stuck — full backend, frame-streak detection
# =============================================================================
STUCK_LIMIT = 96


def _is_real_ball(v: int) -> bool:
    return 0 <= v < 4


def _is_settled(state: Dict, i: int) -> bool:
    slots = state["slots"]
    offsets = state["offsets"]
    if not _is_real_ball(slots[i]) or offsets[i] != 0:
        return False
    if any(not _is_real_ball(v) for v in slots):
        return False
    if i > 0 and offsets[i - 1] != 0:
        return False
    if i + 1 < len(offsets) and offsets[i + 1] != 0:
        return False
    return True


def _t_full(state: Dict, i: int) -> int:
    return (int(state["hsa"]) - i) * CELL_SIZE + int(state["hsub"]) + int(state["offsets"][i])


def _write_array(emu, sym: str, values: List[int]) -> None:
    base = emu.sym[sym]
    for i, v in enumerate(values):
        emu.set_byte(base + i, v & 0xFF)


def _get_state_full(emu) -> Dict:
    s = emu.vdc_state()
    ln = int(s["slots_len"])
    s["shot2"] = list(emu.get_memory(emu.sym["Core.VDC_Shot2"], ln))
    s["freeze"] = emu.get_byte(emu.sym["Core.VDC_ChainFreezeCnt"])
    s["gapcnt"] = emu.get_byte(emu.sym["Core.VDC_GapStepCnt"])
    s["scan"] = emu.get_byte(emu.sym["Core.VDC_MatchScanIdx"])
    return s


def _setup_match3_scenario(emu, chain: List[int], match_idx: int,
                           hsa_margin: int = 20) -> None:
    S = emu.sym
    emu.call(S["Core.VDC_Init"])
    target = S.get("Core.VDC_BALLS_TARGET", 85)
    emu.set_byte(S["Core.VDC_BallsSpawned"], target)
    emu.set_word(S["Core.VDC_TrackNumSlots"], 240)
    emu.set_byte(S["Core.VDC_HSA"], len(chain) + hsa_margin)
    emu.set_byte(S["Core.VDC_HSub"], 0)
    emu.set_byte(S["Core.VDC_SlotsLen"], len(chain))
    emu.set_byte(S["Core.VDC_ChainFreezeCnt"], 0)
    emu.set_byte(S["Core.VDC_GapStepCnt"], 0)
    emu.set_byte(S["Core.VDC_MatchScanIdx"], 0)
    emu.set_word(S["Core.ZL_FrameCounter"], 0)
    _write_array(emu, "Core.VDC_Slots", chain)
    _write_array(emu, "Core.VDC_Offsets", [0] * len(chain))
    _write_array(emu, "Core.VDC_Shot2",   [0] * len(chain))
    emu.set_byte(S["Core.VDC_TmpInsIdx"], match_idx)
    emu.call(S["Core.VDC_CheckMatch3"])


def test_match3_stuck(frames: int = 3000) -> int:
    scenarios = [
        ("short STOP",      [0, 1, 2, 2, 2, 3, 0, 3, 3], 3,   20),
        ("short CASCADE",   [0, 1, 1, 2, 2, 2, 1, 0, 0, 3, 3], 4, 20),
        ("long middle STOP",
         ([0, 1, 2, 3] * 12)[:22] + [2, 2, 2] + ([3, 1, 0, 2] * 12)[:23],
         23, 40),
        ("long same-neighbor CASCADE",
         ([0, 1, 2, 3] * 12)[:20] + [1, 2, 2, 2, 1] + ([3, 0, 1, 2] * 12)[:25],
         22, 40),
    ]
    ZumaFullZ80Emulator = _import_full()
    any_suspicious = False
    for name, chain, match_idx, hsa_margin in scenarios:
        emu = ZumaFullZ80Emulator(PROJECT_ROOT)
        _setup_match3_scenario(emu, chain, match_idx, hsa_margin=hsa_margin)
        initial = _get_state_full(emu)
        prev_t = {i: _t_full(initial, i) for i in range(int(initial["slots_len"]))}
        streak = {i: 0 for i in range(int(initial["slots_len"]))}
        suspicious: Dict[int, Tuple[int, int, int, int]] = {}
        max_streak = 0
        for frame in range(1, frames + 1):
            emu.call(emu.sym["Core.VDC_Update"])
            fc = emu.get_word(emu.sym["Core.ZL_FrameCounter"])
            emu.set_word(emu.sym["Core.ZL_FrameCounter"], (fc + 1) & 0xFFFF)
            s = _get_state_full(emu)
            ln = int(s["slots_len"])
            for i in range(ln):
                cur_t = _t_full(s, i)
                if i in prev_t and cur_t == prev_t[i] and _is_settled(s, i):
                    streak[i] = streak.get(i, 0) + 1
                else:
                    streak[i] = 0
                max_streak = max(max_streak, streak[i])
                if streak[i] == STUCK_LIMIT:
                    suspicious[i] = (frame, int(s["slots"][i]),
                                     int(s["offsets"][i]), cur_t)
            prev_t = {i: _t_full(s, i) for i in range(ln)}
        final = _get_state_full(emu)
        print(f"\n=== {name} ({frames} frames) ===")
        print(f"  final len={final['slots_len']} "
              f"hsa={final['hsa']}.{final['hsub']:02d} "
              f"slots={_format_slots(final['slots'])} "
              f"max_streak={max_streak}")
        if suspicious:
            any_suspicious = True
            print(f"  SUSPICIOUS stuck >= {STUCK_LIMIT}: {suspicious}")
        else:
            print(f"  no stuck streak >= {STUCK_LIMIT}")
    return 2 if any_suspicious else 0


# =============================================================================
# Test: stack — sentinel + min-SP for arbitrary symbol (full backend)
# =============================================================================
def test_stack(symbol: str = "Core.VDC_Init") -> int:
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    if symbol not in emu.sym:
        print(f"unknown symbol: {symbol}")
        return 1

    SENTINEL_LO = 0x4000
    SENTINEL = bytes([0xDE, 0xAD, 0xBE, 0xEF])
    for i, b in enumerate(SENTINEL):
        emu.set_byte(SENTINEL_LO + i, b)

    sp_before = emu.reg.SP
    min_sp = sp_before

    orig_step = emu.step

    def tracking_step():
        nonlocal min_sp
        rc = orig_step()
        if emu.reg.SP < min_sp:
            min_sp = emu.reg.SP
        return rc

    emu.step = tracking_step

    print(f"[{symbol}] SP before = #{sp_before:04X}, "
          f"sentinel #{SENTINEL_LO:04X}..#{SENTINEL_LO+3:04X} = {SENTINEL.hex()}")

    emu.call(emu.sym[symbol], max_steps=2_000_000)

    sp_after = emu.reg.SP
    sentinel_after = bytes(emu.get_byte(SENTINEL_LO + i) for i in range(4))
    used = sp_before - min_sp
    print(f"[{symbol}] SP after  = #{sp_after:04X} "
          f"(delta from before: {sp_before - sp_after:+d})")
    print(f"[{symbol}] min SP    = #{min_sp:04X}  (max stack used: {used} bytes)")
    intact = sentinel_after == SENTINEL
    print(f"[{symbol}] sentinel after = {sentinel_after.hex()} "
          f"({'intact' if intact else 'OVERWRITTEN'})")

    failures = []
    if sp_before != sp_after:
        failures.append(f"stack leak ({sp_before - sp_after:+d} bytes)")
    if not intact:
        failures.append("sentinel overwritten")
    if min_sp < SENTINEL_LO + 4:
        failures.append(f"min SP #{min_sp:04X} crossed sentinel boundary #{SENTINEL_LO:04X}")
    if failures:
        print(f"FAIL: {'; '.join(failures)}")
        return 1
    print("PASS: stack balanced, sentinel intact, depth within budget")
    return 0


# =============================================================================
# Test: mouse-aim-pipeline — track Frog_Angle / velocity lag vs mouse cursor.
# Full pipeline через ZL_AimUpdate + ZL_SmoothMouse + Frog_Update, потом
# Bullet_Spawn напрямую (обходим broken mouse-button emulation в port handler).
# =============================================================================
import math


def _signed8(v: int) -> int:
    return v - 256 if v & 0x80 else v


def _get_word_signed(emu, addr: int) -> int:
    v = emu.get_word(addr)
    return v - 0x10000 if v & 0x8000 else v


def _angle_brad_to_deg(brad: int) -> float:
    """BRAD 256 = 360°. Returns deg in [0, 360)."""
    return brad * 360.0 / 256.0


def _vec_angle_deg(dx: float, dy: float) -> float:
    """atan2(dy, dx) in degrees [0, 360). Screen coords: +Y is down."""
    a = math.degrees(math.atan2(dy, dx))
    return a + 360.0 if a < 0 else a


def _angle_diff_deg(a: float, b: float) -> float:
    """Shortest angular distance in degrees, [0..180]."""
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def _run_mouse_scenario(emu, target_x: int, target_y: int,
                       settle_frames: int) -> dict:
    """Initial state: settled at frog. Jump mouse → run N frames → Bullet_Spawn."""
    S = emu.sym
    frog_x = _get_word_signed(emu, S["Core.Frog_PosStartX"])
    frog_y = _get_word_signed(emu, S["Core.Frog_PosStartY"])

    # Reset: smoothed mouse, prev-raw, angle, mouse-moved flag all at frog idle.
    emu.set_word(S["Core.ZL_SmoothX"],  frog_x & 0xFFFF)
    emu.set_word(S["Core.ZL_SmoothY"],  frog_y & 0xFFFF)
    emu.set_word(S["Core.ZL_PrevRawX"], frog_x & 0xFFFF)
    emu.set_word(S["Core.ZL_PrevRawY"], frog_y & 0xFFFF)
    emu.set_byte(S["Core.Frog_Angle"], 0)
    emu.set_byte(S["Core.ZL_MouseMoved"], 0)
    # Set raw mouse to frog position too (idle).
    emu.set_word(S["Input.Mouse.PositionX"], frog_x & 0xFFFF)
    emu.set_word(S["Input.Mouse.PositionY"], frog_y & 0xFFFF)
    # Bullet inactive so Bullet_Spawn proceeds.
    emu.set_byte(S["Core.Bullet_Active"], 0)

    # Jump mouse to target — this is the "user moved cursor" moment.
    emu.set_word(S["Input.Mouse.PositionX"], target_x & 0xFFFF)
    emu.set_word(S["Input.Mouse.PositionY"], target_y & 0xFFFF)

    # Run settle_frames where ZL_AimUpdate sees motion, ZL_SmoothMouse advances
    # the EMA, and Frog_Update (if mouse-moved=1) calls Frog_ComputeAngle.
    for _ in range(settle_frames):
        emu.call(S["Core.ZL_AimUpdate"])
        emu.call(S["Core.ZL_SmoothMouse"])
        emu.call(S["Core.Frog_Update"])

    smooth_x = _get_word_signed(emu, S["Core.ZL_SmoothX"])
    smooth_y = _get_word_signed(emu, S["Core.ZL_SmoothY"])
    angle = emu.get_byte(S["Core.Frog_Angle"])
    moved = emu.get_byte(S["Core.ZL_MouseMoved"])

    # Now fire: Bullet_Spawn (uses Frog_Angle → Bullet_VX,VY via sin LUT).
    emu.call(S["Core.Bullet_Spawn"])
    bx = _get_word_signed(emu, S["Core.Bullet_X"])
    by = _get_word_signed(emu, S["Core.Bullet_Y"])
    vx = _signed8(emu.get_byte(S["Core.Bullet_VX"]))
    vy = _signed8(emu.get_byte(S["Core.Bullet_VY"]))

    aim_deg = _vec_angle_deg(target_x - frog_x, target_y - frog_y)
    smooth_deg = _vec_angle_deg(smooth_x - frog_x, smooth_y - frog_y) \
        if (smooth_x != frog_x or smooth_y != frog_y) else None
    bullet_deg = _vec_angle_deg(vx, vy) if (vx or vy) else None
    frog_deg = _angle_brad_to_deg(angle)

    aim_vs_bullet = _angle_diff_deg(aim_deg, bullet_deg) if bullet_deg is not None else None
    aim_vs_frog = _angle_diff_deg(aim_deg, frog_deg)
    aim_vs_smooth = _angle_diff_deg(aim_deg, smooth_deg) if smooth_deg is not None else None

    return {
        "frog": (frog_x, frog_y),
        "target": (target_x, target_y),
        "settle": settle_frames,
        "smooth": (smooth_x, smooth_y),
        "moved": moved,
        "angle_brad": angle,
        "frog_deg": frog_deg,
        "smooth_deg": smooth_deg,
        "aim_deg": aim_deg,
        "bullet": (bx, by),
        "velocity": (vx, vy),
        "bullet_deg": bullet_deg,
        "err_smooth_vs_aim": aim_vs_smooth,
        "err_frog_vs_aim": aim_vs_frog,
        "err_bullet_vs_aim": aim_vs_bullet,
    }


def test_mouse_aim_pipeline() -> int:
    print("=== mouse-aim-pipeline: lag of velocity vs cursor across settle frames ===")
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    emu.game_init()

    S = emu.sym
    frog_x = _get_word_signed(emu, S["Core.Frog_PosStartX"])
    frog_y = _get_word_signed(emu, S["Core.Frog_PosStartY"])
    print(f"frog @ ({frog_x},{frog_y})")

    targets = [
        ("E",   frog_x + 200, frog_y),
        ("S",   frog_x,       frog_y + 150),
        ("W",   frog_x - 200, frog_y),
        ("N",   frog_x,       max(10, frog_y - 150)),
        ("SE",  frog_x + 150, frog_y + 150),
        ("SW",  frog_x - 150, frog_y + 150),
        ("NE",  frog_x + 150, max(10, frog_y - 150)),
        ("NW",  frog_x - 150, max(10, frog_y - 150)),
    ]
    settle_options = [0, 1, 2, 4, 8, 15, 30, 60]

    bad = []
    print()
    print(f"{'dir':4s} {'settle':>6s} {'aim°':>6s} {'frog°':>6s} {'bul°':>6s} "
          f"{'err_b':>6s} {'err_f':>6s} {'V':>10s} moved")
    for name, tx, ty in targets:
        for sf in settle_options:
            r = _run_mouse_scenario(emu, tx, ty, sf)
            bul = f"{r['bullet_deg']:.1f}" if r['bullet_deg'] is not None else "—"
            err_b = (f"{r['err_bullet_vs_aim']:.1f}"
                     if r['err_bullet_vs_aim'] is not None else "—")
            err_f = f"{r['err_frog_vs_aim']:.1f}"
            print(f"{name:4s} {sf:>6d} {r['aim_deg']:>6.1f} {r['frog_deg']:>6.1f} "
                  f"{bul:>6s} {err_b:>6s} {err_f:>6s} {str(r['velocity']):>10s} "
                  f"{r['moved']}")
            if r["err_bullet_vs_aim"] is not None and r["err_bullet_vs_aim"] > 30:
                bad.append((name, sf, r))
    print()
    print(f"scenarios with bullet-angle error > 30°: {len(bad)}")
    if bad:
        print("  examples:")
        for name, sf, r in bad[:5]:
            print(f"    {name} settle={sf}: aim={r['aim_deg']:.1f}° "
                  f"→ bullet={r['bullet_deg']:.1f}° "
                  f"(err {r['err_bullet_vs_aim']:.1f}°)")
    return 2 if bad else 0


# =============================================================================
# Test: catch-wrong-target — instrument the real game loop via existing
# catch_wrong_target_live.Catcher. Wrapper, no code duplication.
# =============================================================================
def test_catch_wrong_target(build_frames: int = 2600,
                            max_frames: int = 80,
                            area_only: bool = False,
                            phases=None) -> int:
    print(f"=== catch-wrong-target: build_frames={build_frames}, "
          f"max_frames={max_frames}, area_only={area_only} ===")
    _import_full()
    from catch_wrong_target_live import Catcher
    catcher = Catcher()
    catcher.init(build_frames)
    if phases is None:
        phases = [0, 4, 8, 12, 16, 24, 32, 40, 48, 56]
    events = catcher.run(phases=phases, max_frames=max_frames, area_only=area_only)
    for ev in events[:20]:
        print(f"  {ev.kind} phase={ev.phase} frame={ev.frame} aim={ev.aim_idx} "
              f"bullet=({ev.bullet[0]},{ev.bullet[1]}) v={ev.velocity} "
              f"nearest={ev.nearest_idx}(d={ev.nearest_dist}) "
              f"insert={ev.insert_idx} insert_delta={ev.insert_delta} "
              f"aim_delta={ev.aim_delta} remote={ev.remote_changes}")
        print(f"    bbox={ev.bbox}  slots={ev.slots[:80]}")
    if len(events) > 20:
        print(f"  ... {len(events) - 20} more events")
    print(f"found {len(events)} event(s)")
    return 2 if events else 0


# =============================================================================
# Run real MainLoop for N frames and capture the game DL via shadow
# =============================================================================
def cmd_mainloop_frames(n_frames: int, shadow_dl: bool, shadow_regs: bool,
                        max_steps: int = 50_000_000) -> int:
    """game_init → Init_Video → MainLoop forward until N DLSWAPs captured.
    Same HALT-skip + tick_frame as cmd_call, exit when shadow.swap_count >= N."""
    print(f"=== mainloop: {n_frames} frame(s) through shadow ===")
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    from shadow_ft812 import attach_shadow, disasm_dl, format_dl, summarize_dl
    regs = attach_shadow(emu)

    print("[1] game_init (Init_Core + VDC_Init + Frog_Init + Bullet_Init)")
    emu.game_init()
    print(f"    OK. Init_Video pre-state: PC=#{emu.reg.PC:04X}, SP=#{emu.reg.SP:04X}")

    print("[2] Init_Video (with HALT-skip)")
    from shadow_ft812 import REG_FRAMES as _SHADOW_REG_FRAMES
    _run_with_halt_skip(emu, regs, emu.sym["Core.Init_Video"],
                        stop_on_swaps=None, max_steps=max_steps,
                        return_marker=0xFFFE)
    print(f"    OK. After Init_Video: swap_writes={regs.dlswap_writes}, "
          f"frames={regs._get32(_SHADOW_REG_FRAMES)}")

    print(f"[3] MainLoop forward until {n_frames} swap(s)")
    swaps_before = regs.swap_count
    steps, halts = _run_with_halt_skip(
        emu, regs, emu.sym["Core.MainLoop"],
        stop_on_swaps=swaps_before + n_frames,
        max_steps=max_steps,
        return_marker=None,  # MainLoop never returns
    )
    print(f"    done. steps={steps}, halts={halts}, "
          f"swaps_captured={regs.swap_count - swaps_before}")

    if shadow_regs:
        from shadow_ft812 import (REG_FRAMES, REG_CLOCK, REG_DLSWAP,
                                  REG_INT_FLAGS, REG_CMD_READ, REG_CMD_WRITE,
                                  REG_PCLK, REG_HSIZE, REG_VSIZE)
        print(f"shadow regs: frames={regs._get32(REG_FRAMES)} "
              f"clock={regs._get32(REG_CLOCK)} "
              f"dlswap={regs._get32(REG_DLSWAP)} "
              f"int_flags={regs._get32(REG_INT_FLAGS):02X} "
              f"cmd_r={regs._get32(REG_CMD_READ)} cmd_w={regs._get32(REG_CMD_WRITE)} "
              f"hsize={regs._get32(REG_HSIZE)} vsize={regs._get32(REG_VSIZE)} "
              f"pclk={regs._get32(REG_PCLK)}")
        print(f"shadow stats: swap_writes={regs.dlswap_writes} "
              f"swaps_done={regs.swap_count} "
              f"int_flags_reads={regs.int_flags_reads}")
    if shadow_dl:
        snap = regs.last_dl_snapshot
        if snap is None:
            print("(no DL snapshot captured — dumping current RAM_DL)")
            snap = bytes(emu.ft.ram_dl[:0x2000])
        ops = disasm_dl(snap, max_ops=4096)
        print(format_dl(ops))
        print()
        print(summarize_dl(ops))
    return 0


def _run_with_halt_skip(emu, regs, start_pc: int, *, stop_on_swaps,
                        max_steps: int, return_marker):
    """Manual loop: HALT→ PC+1 + tick_frame. Exit when:
    - PC == return_marker (if set), or
    - regs.swap_count >= stop_on_swaps (if set), or
    - steps >= max_steps.
    For function calls (Init_Video): set return_marker=0xFFFE, push it on stack.
    For MainLoop: return_marker=None, stop_on_swaps required."""
    if return_marker is not None:
        sp = (emu.reg.SP - 2) & 0xFFFF
        emu.set_word(sp, return_marker)
        emu.reg.SP = sp
    emu.reg.PC = start_pc
    steps = halts = 0
    while steps < max_steps:
        if return_marker is not None and emu.reg.PC == return_marker:
            break
        if stop_on_swaps is not None and regs.swap_count >= stop_on_swaps:
            break
        pc = emu.reg.PC
        op = emu.mem.read(pc)
        if op == 0x76:
            emu.reg.PC = (pc + 1) & 0xFFFF
            halts += 1
            regs.tick_frame(emu.ft.ram_dl)
        else:
            emu.step()
        steps += 1
    return steps, halts


# =============================================================================
# Test: shadow-dl — synthetic DL through full backend + shadow FT812
# =============================================================================
def test_shadow_dl() -> int:
    """Inject a small DL via emu._write_ft_addr, trigger DLSWAP, verify snapshot
    captured and disassembled correctly. Doesn't run game logic — pure smoke
    test for the L2+L3 shadow wiring."""
    print("=== shadow-dl: synthetic DL through full backend ===")
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    from shadow_ft812 import (attach_shadow, disasm_dl, format_dl, summarize_dl,
                              REG_DLSWAP, DLSWAP_FRAME, RAM_DL_BASE)
    regs = attach_shadow(emu)
    dl_words = [
        0x02000080,   # CLEAR_COLOR_RGB(0, 0, 128)
        0x26000007,   # CLEAR(c=1, s=1, t=1)
        0x05000003,   # BITMAP_HANDLE(3)
        0x1F000001,   # BEGIN(BITMAPS)
        0x80000000 | (320 << 21) | (240 << 12) | (3 << 7) | 7,  # VERTEX2II(320,240,h=3,c=7)
        0x21000000,   # END
        0x00000000,   # DISPLAY
    ]
    for i, w in enumerate(dl_words):
        for j in range(4):
            emu._write_ft_addr(RAM_DL_BASE + i * 4 + j, (w >> (j * 8)) & 0xFF)
    emu._write_ft_addr(REG_DLSWAP, DLSWAP_FRAME)

    if regs.last_dl_snapshot is None:
        print("FAIL: no DL snapshot captured after DLSWAP write")
        return 1
    ops = disasm_dl(regs.last_dl_snapshot)
    print(format_dl(ops))
    print()
    print(summarize_dl(ops))
    print(f"shadow stats: swap_writes={regs.dlswap_writes} "
          f"swaps_done={regs.swap_count}")
    expected_names = ["CLEAR_COLOR_RGB", "CLEAR", "BITMAP_HANDLE", "BEGIN",
                      "VERTEX2II", "END", "DISPLAY"]
    got = [op.name for op in ops]
    if got != expected_names:
        print(f"FAIL: expected {expected_names}, got {got}")
        return 1
    print("PASS: shadow DL pipeline OK (write → DLSWAP → snapshot → disasm)")
    return 0


# =============================================================================
# CLI
# =============================================================================
def cmd_call(symbol: str, trace: bool,
             shadow_dl: bool = False, shadow_regs: bool = False,
             max_steps: int = 20_000_000) -> int:
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT, trace=trace)
    regs = None
    if shadow_dl or shadow_regs:
        from shadow_ft812 import attach_shadow
        regs = attach_shadow(emu)
    if symbol in emu.sym:
        addr = emu.sym[symbol]
    elif symbol.startswith("#"):
        addr = int(symbol[1:], 16)
    elif symbol.lower().startswith("0x"):
        addr = int(symbol[2:], 16)
    else:
        print(f"unknown symbol or addr: {symbol}")
        return 1
    # Manual call loop so we can capture shadow stats on timeout. HALT (0x76)
    # — игра ждёт IRQ от 50Hz vsync; cburbridge не моделирует прерывания,
    # поэтому fake-IRQ: после HALT просто двигаем PC на 1 (как будто ISR
    # отработал и вернулся). Это L6 hack, без него Init_Video не проходит.
    RETURN_MARKER = 0xFFFE
    sp = (emu.reg.SP - 2) & 0xFFFF
    emu.set_word(sp, RETURN_MARKER)
    emu.reg.SP = sp
    emu.reg.PC = addr
    steps = 0
    halt_count = 0
    while emu.reg.PC != RETURN_MARKER and steps < max_steps:
        pc_before = emu.reg.PC
        op = emu.mem.read(pc_before)
        if op == 0x76:           # HALT
            emu.reg.PC = (pc_before + 1) & 0xFFFF
            halt_count += 1
            if regs is not None:
                regs.tick_frame(emu.ft.ram_dl)
        else:
            emu.step()
        steps += 1
    status = "ok" if emu.reg.PC == RETURN_MARKER else f"TIMEOUT @ #{emu.reg.PC:04X}"
    print(f"called {symbol} (#{addr:04X}): {status}, steps={steps}, "
          f"halts={halt_count}, pc=#{emu.reg.PC:04X}")
    if regs is not None and shadow_regs:
        from shadow_ft812 import (REG_FRAMES, REG_CLOCK, REG_DLSWAP,
                                  REG_INT_FLAGS, REG_CMD_READ, REG_CMD_WRITE,
                                  REG_HSIZE, REG_VSIZE, REG_PCLK)
        print(f"shadow regs: frames={regs._get32(REG_FRAMES)} "
              f"clock={regs._get32(REG_CLOCK)} "
              f"dlswap={regs._get32(REG_DLSWAP)} "
              f"int_flags={regs._get32(REG_INT_FLAGS):02X} "
              f"cmd_r={regs._get32(REG_CMD_READ)} cmd_w={regs._get32(REG_CMD_WRITE)} "
              f"hsize={regs._get32(REG_HSIZE)} vsize={regs._get32(REG_VSIZE)} "
              f"pclk={regs._get32(REG_PCLK)}")
        print(f"shadow stats: swap_writes={regs.dlswap_writes} "
              f"swaps_done={regs.swap_count} "
              f"int_flags_reads={regs.int_flags_reads}")
    if regs is not None and shadow_dl:
        from shadow_ft812 import disasm_dl, format_dl, summarize_dl
        snap = regs.last_dl_snapshot
        if snap is None:
            print("(no DL swap captured — dumping current RAM_DL)")
            snap = bytes(emu.ft.ram_dl[:0x2000])
        ops = disasm_dl(snap)
        print(format_dl(ops))
        print()
        print(summarize_dl(ops))
    return 0


def cmd_game_frames(n: int, show_state: bool,
                    shadow_dl: bool = False, shadow_regs: bool = False,
                    dl_summary: bool = False) -> int:
    ZumaFullZ80Emulator = _import_full()
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    regs = None
    if shadow_dl or shadow_regs:
        from shadow_ft812 import attach_shadow, disasm_dl, format_dl, summarize_dl
        regs = attach_shadow(emu)
    emu.game_init()
    for _ in range(n):
        emu.game_frame()
        if regs is not None:
            regs.tick_frame(emu.ft.ram_dl)
    if show_state:
        s = emu.vdc_state()
        print(f"hsa={s['hsa']} hsub={s['hsub']} len={s['slots_len']} "
              f"balls={s['balls_spawned']} tstates={s['tstates']}")
        print("slots=" + _format_slots(s["slots"])[:120])
        print("pages=" + ",".join(f"{p:02X}" for p in s["page_map"]))
    if regs is not None and shadow_regs:
        from shadow_ft812 import (REG_FRAMES, REG_CLOCK, REG_DLSWAP,
                                  REG_INT_FLAGS, REG_CMD_READ, REG_CMD_WRITE)
        print(f"shadow regs: frames={regs._get32(REG_FRAMES)} "
              f"clock={regs._get32(REG_CLOCK)} "
              f"dlswap={regs._get32(REG_DLSWAP)} "
              f"int_flags={regs._get32(REG_INT_FLAGS):02X} "
              f"cmd_r={regs._get32(REG_CMD_READ)} cmd_w={regs._get32(REG_CMD_WRITE)}")
        print(f"shadow stats: swap_writes={regs.dlswap_writes} "
              f"swaps_done={regs.swap_count} "
              f"int_flags_reads={regs.int_flags_reads}")
    if regs is not None and shadow_dl:
        from shadow_ft812 import disasm_dl, format_dl, summarize_dl
        snap = regs.last_dl_snapshot
        if snap is None:
            # Fallback: dump current RAM_DL even if no DLSWAP was issued
            print("(no DL swap captured — dumping current RAM_DL)")
            snap = bytes(emu.ft.ram_dl[:0x2000])
        ops = disasm_dl(snap)
        print(format_dl(ops))
        print()
        print(summarize_dl(ops))
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="zuma_vdac2",
                                 description="Unified VDAC2 harness CLI")
    ap.add_argument("--call", help="call a symbol/addr through full backend")
    ap.add_argument("--trace", action="store_true",
                    help="trace each instruction (works with --call)")
    ap.add_argument("--test", choices=("wrong-target", "tail-glitch",
                                       "match3-stuck", "stack", "shadow-dl",
                                       "catch-wrong-target",
                                       "mouse-aim-pipeline"),
                    help="run named test")
    ap.add_argument("--build-frames", type=int, default=2600,
                    help="for --test catch-wrong-target: frames to build chain")
    ap.add_argument("--max-frames", type=int, default=80,
                    help="for --test catch-wrong-target: per-bullet flight cap")
    ap.add_argument("--area-only", action="store_true",
                    help="for --test catch-wrong-target: bottom-screen probes")
    ap.add_argument("--scenario",
                    help="for --test wrong-target: S1, S2, S3, natural, "
                         "spiral, post-match3, all (default S1)")
    ap.add_argument("--symbol", help="for --test stack: symbol name "
                                     "(default Core.VDC_Init)")
    ap.add_argument("--frames", type=int, default=3000,
                    help="for --test match3-stuck (default 3000)")
    ap.add_argument("--game-frames", type=int, default=0,
                    help="run game_init + N game_frame() iterations")
    ap.add_argument("--mainloop-frames", type=int, default=0,
                    help="game_init + Init_Video + MainLoop forward until N DLSWAPs "
                         "(use with --shadow-dl / --shadow-regs)")
    ap.add_argument("--vdc-state", action="store_true",
                    help="print VDC state after --game-frames")
    ap.add_argument("--shadow-dl", action="store_true",
                    help="attach shadow FT812, dump last DL snapshot")
    ap.add_argument("--shadow-regs", action="store_true",
                    help="attach shadow FT812, dump key register values")
    args = ap.parse_args(argv)

    if args.call:
        return cmd_call(args.call, args.trace,
                        shadow_dl=args.shadow_dl,
                        shadow_regs=args.shadow_regs)

    if args.test == "wrong-target":
        return test_wrong_target(args.scenario or "S1")
    if args.test == "tail-glitch":
        return test_tail_glitch()
    if args.test == "match3-stuck":
        return test_match3_stuck(args.frames)
    if args.test == "stack":
        return test_stack(args.symbol or "Core.VDC_Init")
    if args.test == "shadow-dl":
        return test_shadow_dl()
    if args.test == "catch-wrong-target":
        return test_catch_wrong_target(
            build_frames=args.build_frames,
            max_frames=args.max_frames,
            area_only=args.area_only,
        )
    if args.test == "mouse-aim-pipeline":
        return test_mouse_aim_pipeline()

    if args.mainloop_frames:
        return cmd_mainloop_frames(args.mainloop_frames,
                                   shadow_dl=args.shadow_dl,
                                   shadow_regs=args.shadow_regs)

    if args.game_frames or args.vdc_state or args.shadow_dl or args.shadow_regs:
        return cmd_game_frames(args.game_frames, args.vdc_state,
                               shadow_dl=args.shadow_dl,
                               shadow_regs=args.shadow_regs)

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
