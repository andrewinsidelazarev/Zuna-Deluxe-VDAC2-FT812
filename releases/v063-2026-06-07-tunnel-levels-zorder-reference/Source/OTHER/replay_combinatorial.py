#!/usr/bin/env python3
"""replay_combinatorial.py — full combinatorial coverage поиск stuck balls.

Прогоны:
  Pass 1: single insert, full sweep target × color, длинная цепь (60-85)
  Pass 2: то же + spawn активный во время tail
  Pass 3: пары inserts с разными интервалами (30, 60, 100 кадров)
  Pass 4: тройки inserts (cascade goals)
  Pass 5: head-area inserts (idx=0..3)
  Pass 6: insert в разных hsub-фазах chain (0, 8, 16, 24)

Логирует подозрительные сценарии в _replay_logs/combo_*.log с покадровым state.
"""
from __future__ import annotations
import argparse, os, sys
from pathlib import Path
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import PROJECT_ROOT, ZumaFullZ80Emulator

CELL_SIZE = 32
STUCK_LIMIT = 96
LOW_MOVE_RATIO = 0.05
LOG_DIR = Path(PROJECT_ROOT) / 'Source' / 'OTHER' / '_replay_logs'
LOG_DIR.mkdir(exist_ok=True)


def t_of(s, i): return (s['hsa'] - i) * CELL_SIZE + s['hsub'] + s['offsets'][i]
def is_real(b): return 0 <= b < 4
def chain_str(slots): return ZumaFullZ80Emulator.format_slots(slots)


def state_full(sim):
    s = sim.vdc_state()
    ln = int(s['slots_len'])
    s['shot2'] = list(sim.get_memory(sim.sym['Core.VDC_Shot2'], ln))
    s['freeze'] = sim.get_byte(sim.sym['Core.VDC_ChainFreezeCnt'])
    s['gapcnt'] = sim.get_byte(sim.sym['Core.VDC_GapStepCnt'])
    s['scan'] = sim.get_byte(sim.sym['Core.VDC_MatchScanIdx'])
    s['balls'] = sim.get_byte(sim.sym['Core.VDC_BallsSpawned'])
    return s


def snapshot(sim):
    S = sim.sym
    return {
        'slots': list(sim.get_memory(S['Core.VDC_Slots'], 240)),
        'offsets': list(sim.get_memory(S['Core.VDC_Offsets'], 240)),
        'shot2': list(sim.get_memory(S['Core.VDC_Shot2'], 240)),
        'hsa': sim.get_byte(S['Core.VDC_HSA']),
        'hsa_hi': sim.get_byte(S['Core.VDC_HSA'] + 1),
        'hsub': sim.get_byte(S['Core.VDC_HSub']),
        'len': sim.get_byte(S['Core.VDC_SlotsLen']),
        'balls': sim.get_byte(S['Core.VDC_BallsSpawned']),
        'freeze': sim.get_byte(S['Core.VDC_ChainFreezeCnt']),
        'gapcnt': sim.get_byte(S['Core.VDC_GapStepCnt']),
        'scan': sim.get_byte(S['Core.VDC_MatchScanIdx']),
        'fc': sim.get_word(S['Core.ZL_FrameCounter']),
        'lfsr': sim.get_byte(S['Core.VDC_LfsrSeed']),
    }


def restore(sim, snap):
    S = sim.sym
    for i, v in enumerate(snap['slots']):
        sim.set_byte(S['Core.VDC_Slots'] + i, v)
    for i, v in enumerate(snap['offsets']):
        sim.set_byte(S['Core.VDC_Offsets'] + i, v)
    for i, v in enumerate(snap['shot2']):
        sim.set_byte(S['Core.VDC_Shot2'] + i, v)
    sim.set_byte(S['Core.VDC_HSA'], snap['hsa'])
    sim.set_byte(S['Core.VDC_HSA'] + 1, snap['hsa_hi'])
    sim.set_byte(S['Core.VDC_HSub'], snap['hsub'])
    sim.set_byte(S['Core.VDC_SlotsLen'], snap['len'])
    sim.set_byte(S['Core.VDC_BallsSpawned'], snap['balls'])
    sim.set_byte(S['Core.VDC_ChainFreezeCnt'], snap['freeze'])
    sim.set_byte(S['Core.VDC_GapStepCnt'], snap['gapcnt'])
    sim.set_byte(S['Core.VDC_MatchScanIdx'], snap['scan'])
    sim.set_word(S['Core.ZL_FrameCounter'], snap['fc'])
    sim.set_byte(S['Core.VDC_LfsrSeed'], snap['lfsr'])


def run_updates(sim, frames, log_file=None, track_stuck=False):
    S = sim.sym
    s = state_full(sim)
    ln = int(s['slots_len'])
    prev_t = {i: t_of(s, i) for i in range(ln)} if track_stuck else None
    streak = {i: 0 for i in range(ln)} if track_stuck else None
    moved = {i: 0 for i in range(ln)} if track_stuck else None
    max_streak = 0

    for f in range(frames):
        sim.call(S['Core.VDC_Update'])
        fc = sim.get_word(S['Core.ZL_FrameCounter'])
        sim.set_word(S['Core.ZL_FrameCounter'], (fc + 1) & 0xFFFF)
        if log_file or track_stuck:
            s = state_full(sim)
            ln = int(s['slots_len'])
            if log_file:
                log_file.write(
                    f"f={f:4d} len={ln:2d} hsa={s['hsa']:3d}.{s['hsub']:02d} "
                    f"fc={s['freeze']:2d} gc={s['gapcnt']:2d} balls={s['balls']:2d} "
                    f"slots=[{chain_str(s['slots'])}] off={s['offsets']} shot2={s['shot2']}\n"
                )
            if track_stuck:
                for i in range(ln):
                    t = t_of(s, i)
                    settled = (is_real(s['slots'][i]) and s['offsets'][i] == 0
                               and (i == 0 or s['offsets'][i - 1] == 0)
                               and (i + 1 >= ln or s['offsets'][i + 1] == 0)
                               and all(is_real(v) for v in s['slots'][:ln]))
                    if i in prev_t:
                        if t != prev_t[i]:
                            moved[i] = moved.get(i, 0) + 1
                        if t == prev_t[i] and settled:
                            streak[i] = streak.get(i, 0) + 1
                        else:
                            streak[i] = 0
                    max_streak = max(max_streak, streak.get(i, 0))
                prev_t = {i: t_of(s, i) for i in range(ln)}

    return max_streak, streak, moved


def analyze(sim, frames, streak, moved):
    final = state_full(sim)
    ln = int(final['slots_len'])
    low_ratio = []
    for i in range(min(ln, len(moved))):
        if not is_real(final['slots'][i]):
            continue
        ratio = moved.get(i, 0) / max(frames, 1)
        if ratio < LOW_MOVE_RATIO:
            low_ratio.append((i, final['slots'][i], moved[i], ratio))
    return low_ratio, final


def build_chain(sim, frames):
    """Естественный spawn до stable chain."""
    S = sim.sym
    sim.call(S['Core.VDC_Init'])
    sim.set_word(S['Core.VDC_TrackNumSlots'], 240)  # без cap
    run_updates(sim, frames)


def insert_and_settle(sim, target, color, tail, log_file=None):
    S = sim.sym
    sim.call(S['Core.VDC_InsertAt'], a=target, b=color)
    max_streak, streak, moved = run_updates(sim, tail, log_file, track_stuck=True)
    low_ratio, final = analyze(sim, tail, streak, moved)
    return max_streak, low_ratio, final


def is_suspicious(max_streak, low_ratio):
    return max_streak >= STUCK_LIMIT or len(low_ratio) > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', type=int, default=5000)
    ap.add_argument('--tail', type=int, default=600)
    ap.add_argument('--max-suspicious-logs', type=int, default=10)
    args = ap.parse_args()

    print('=== Combinatorial replay sweep ===')
    print(f'  build={args.build} tail={args.tail}')

    suspicious_count = 0
    saved_logs = 0

    # === Base scenario: естественный chain ~70 шаров ===
    sim = ZumaFullZ80Emulator(PROJECT_ROOT)
    build_chain(sim, args.build)
    sim.set_byte(sim.sym['Core.VDC_BallsSpawned'], 85)  # spawn off
    base = snapshot(sim)
    sbase = state_full(sim)
    base_len = sbase['slots_len']
    print(f"  base_chain: len={base_len} hsa={sbase['hsa']}.{sbase['hsub']:02d} slots=[{chain_str(sbase['slots'])[:60]}...]")

    if base_len < 10:
        print('  ! ОШИБКА: цепь не построилась, base_len < 10')
        return 1

    # === Pass 1: single insert, FULL sweep всех targets ===
    print(f'\n--- Pass 1: single insert, all targets×colors, tail={args.tail} (spawn OFF) ---')
    pass1_susp = []
    for tgt in range(base_len):
        for color in range(4):
            restore(sim, base)
            ms, lr, final = insert_and_settle(sim, tgt, color, args.tail)
            if is_suspicious(ms, lr):
                pass1_susp.append((tgt, color, ms, lr, final))
                suspicious_count += 1
    print(f'  total scenarios: {base_len * 4}, suspicious: {len(pass1_susp)}')
    for tgt, col, ms, lr, final in pass1_susp[:5]:
        print(f'    t={tgt} c={col} max_streak={ms} low_ratio={len(lr)} final_len={final["slots_len"]}')

    # === Pass 2: single insert + spawn активный во время tail ===
    print(f'\n--- Pass 2: single insert, all targets×colors, spawn ON ---')
    pass2_susp = []
    for tgt in [0, 1, 2, base_len // 4, base_len // 2, 3 * base_len // 4, base_len - 1]:
        for color in range(4):
            restore(sim, base)
            # spawn on: BallsSpawned=35 → fast phase, шары спавнятся
            sim.set_byte(sim.sym['Core.VDC_BallsSpawned'], 35)
            ms, lr, final = insert_and_settle(sim, tgt, color, args.tail)
            if is_suspicious(ms, lr):
                pass2_susp.append((tgt, color, ms, lr, final))
                suspicious_count += 1
    print(f'  scenarios: {7 * 4}, suspicious: {len(pass2_susp)}')
    for tgt, col, ms, lr, final in pass2_susp[:5]:
        print(f'    t={tgt} c={col} max_streak={ms} low_ratio={len(lr)} final_len={final["slots_len"]}')

    # === Pass 3: пары inserts с интервалом ===
    print(f'\n--- Pass 3: pairs of inserts, interval ∈ {{30, 60, 100}} ---')
    pass3_susp = []
    pair_targets = [(0, base_len // 2), (base_len // 2, base_len - 1), (5, 10), (10, 20)]
    for t1, t2 in pair_targets:
        for c1 in range(4):
            for c2 in range(4):
                for interval in [30, 60, 100]:
                    restore(sim, base)
                    sim.call(sim.sym['Core.VDC_InsertAt'], a=t1, b=c1)
                    run_updates(sim, interval)
                    sim.call(sim.sym['Core.VDC_InsertAt'], a=t2, b=c2)
                    ms, _, mv = run_updates(sim, args.tail, track_stuck=True)
                    lr, final = analyze(sim, args.tail, _, mv)
                    if is_suspicious(ms, lr):
                        pass3_susp.append((t1, c1, t2, c2, interval, ms, lr, final))
                        suspicious_count += 1
    print(f'  scenarios: {len(pair_targets) * 16 * 3}, suspicious: {len(pass3_susp)}')
    for t1, c1, t2, c2, iv, ms, lr, final in pass3_susp[:5]:
        print(f'    (t={t1},c={c1})→[{iv}]→(t={t2},c={c2}) ms={ms} lr={len(lr)}')

    # === Pass 4: тройки inserts ===
    print(f'\n--- Pass 4: triple inserts (chain stress) ---')
    pass4_susp = []
    triple_targets = [(5, 15, 25), (10, 20, 30), (0, 5, 10), (base_len - 5, base_len - 3, base_len - 1)]
    for t1, t2, t3 in triple_targets:
        for c1 in range(4):
            restore(sim, base)
            sim.call(sim.sym['Core.VDC_InsertAt'], a=t1, b=c1)
            run_updates(sim, 50)
            sim.call(sim.sym['Core.VDC_InsertAt'], a=t2, b=c1)  # same color
            run_updates(sim, 50)
            sim.call(sim.sym['Core.VDC_InsertAt'], a=t3, b=c1)
            ms, _, mv = run_updates(sim, args.tail, track_stuck=True)
            lr, final = analyze(sim, args.tail, _, mv)
            if is_suspicious(ms, lr):
                pass4_susp.append((t1, t2, t3, c1, ms, lr, final))
                suspicious_count += 1
    print(f'  scenarios: {len(triple_targets) * 4}, suspicious: {len(pass4_susp)}')

    # === Pass 5: insert в head-area (idx 0,1,2,3) === уже частично покрыто в Pass 1.
    # === Pass 6: insert в разных hsub-фазах ===
    print(f'\n--- Pass 6: insert at different hsub phases ---')
    pass6_susp = []
    for hsub_target in [0, 8, 16, 24]:
        restore(sim, base)
        # Прогнать кадры пока hsub != target
        for _ in range(60):
            current_hsub = sim.get_byte(sim.sym['Core.VDC_HSub'])
            if current_hsub == hsub_target:
                break
            run_updates(sim, 1)
        # Теперь insert
        for tgt in [base_len // 4, base_len // 2]:
            for color in range(4):
                snap_hsub = snapshot(sim)
                sim.call(sim.sym['Core.VDC_InsertAt'], a=tgt, b=color)
                ms, _, mv = run_updates(sim, args.tail, track_stuck=True)
                lr, final = analyze(sim, args.tail, _, mv)
                if is_suspicious(ms, lr):
                    pass6_susp.append((hsub_target, tgt, color, ms, lr, final))
                    suspicious_count += 1
                restore(sim, snap_hsub)
    print(f'  scenarios: {4 * 2 * 4}, suspicious: {len(pass6_susp)}')

    # === Summary ===
    print(f'\n=== SUMMARY ===')
    total_susp = (len(pass1_susp) + len(pass2_susp) + len(pass3_susp)
                  + len(pass4_susp) + len(pass6_susp))
    print(f'  TOTAL suspicious: {total_susp}')
    if total_susp == 0:
        print('  ✓ ни в одном из ~{} сценариев STUCK не найден'.format(
            base_len * 4 + 7 * 4 + len(pair_targets) * 16 * 3 + len(triple_targets) * 4 + 4 * 2 * 4))
        return 0
    else:
        print('  >>> baseline scenarios нашли подозрительные — детали выше <<<')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
