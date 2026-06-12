#!/usr/bin/env python3
"""replay_insert_sequence.py — построить chain через естественный spawn, потом
имитировать серию выстрелов через VDC_InsertAt и наблюдать stuck balls.

Сценарий ближе к реальному gameplay чем прямой CheckMatch3 inject:
  1. spawn build: VDC_Update N1 кадров с активным spawn (chain набирается).
  2. snapshot base state.
  3. для каждого варианта (target, color):
     - restore state
     - call VDC_InsertAt(target, color)
     - run N2 кадров VDC_Update
     - лог каждого кадра + finder stuck balls

Цель — поймать сценарий «settled real ball не двигается > STUCK_LIMIT кадров»
который описывает user.

Запуск:
  py -3.12 Source/OTHER/replay_insert_sequence.py --build 5000 --tail 1500
"""
from __future__ import annotations
import argparse, os, sys
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import PROJECT_ROOT, ZumaFullZ80Emulator

CELL_SIZE = 32
STUCK_LIMIT = 96
LOG_DIR = Path(PROJECT_ROOT) / 'Source' / 'OTHER' / '_replay_logs'
LOG_DIR.mkdir(exist_ok=True)


def signed(b): return b - 256 if b & 0x80 else b


def t_of(s, i):
    return (s['hsa'] - i) * CELL_SIZE + s['hsub'] + s['offsets'][i]


def is_real(b): return 0 <= b < 4


def state_full(sim):
    s = sim.vdc_state()
    ln = int(s['slots_len'])
    s['shot2'] = list(sim.get_memory(sim.sym['Core.VDC_Shot2'], ln))
    s['freeze'] = sim.get_byte(sim.sym['Core.VDC_ChainFreezeCnt'])
    s['gapcnt'] = sim.get_byte(sim.sym['Core.VDC_GapStepCnt'])
    s['scan'] = sim.get_byte(sim.sym['Core.VDC_MatchScanIdx'])
    s['balls'] = sim.get_byte(sim.sym['Core.VDC_BallsSpawned'])
    return s


def chain_str(slots): return ZumaFullZ80Emulator.format_slots(slots)


def run_update(sim, frames, log_file=None):
    """Прогнать N кадров VDC_Update с инкрементом ZL_FrameCounter."""
    S = sim.sym
    for f in range(frames):
        sim.call(S['Core.VDC_Update'])
        fc = sim.get_word(S['Core.ZL_FrameCounter'])
        sim.set_word(S['Core.ZL_FrameCounter'], (fc + 1) & 0xFFFF)
        if log_file is not None:
            s = state_full(sim)
            log_file.write(
                f"f={f:4d} len={s['slots_len']:2d} hsa={s['hsa']:3d}.{s['hsub']:02d} "
                f"freeze={s['freeze']:2d} gc={s['gapcnt']:2d} balls={s['balls']:2d} "
                f"slots=[{chain_str(s['slots'])}] off={s['offsets']} shot2={s['shot2']}\n"
            )


def snapshot(sim):
    """Snapshot всех VDC state байтов для восстановления."""
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


def find_stuck(sim, frames, log_file=None):
    """Прогнать frames кадров. Метрики на каждый i:
       - max streak подряд без движения (settled real ball)
       - movement_ratio = moved_frames / total_frames
       Если max_streak >= STUCK_LIMIT ИЛИ movement_ratio < 0.05 → suspicious."""
    S = sim.sym
    s = state_full(sim)
    ln = int(s['slots_len'])
    prev_t = {i: t_of(s, i) for i in range(ln)}
    streak = {i: 0 for i in range(ln)}
    moved = {i: 0 for i in range(ln)}
    max_streak = 0
    stuck_found = []

    for f in range(frames):
        sim.call(S['Core.VDC_Update'])
        fc = sim.get_word(S['Core.ZL_FrameCounter'])
        sim.set_word(S['Core.ZL_FrameCounter'], (fc + 1) & 0xFFFF)
        s = state_full(sim)
        ln = int(s['slots_len'])

        if log_file is not None:
            log_file.write(
                f"f={f:4d} len={ln:2d} hsa={s['hsa']:3d}.{s['hsub']:02d} "
                f"fc={s['freeze']:2d} gc={s['gapcnt']:2d} balls={s['balls']:2d} "
                f"slots=[{chain_str(s['slots'])}] off={s['offsets']} shot2={s['shot2']}\n"
            )

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
            if streak[i] > max_streak:
                max_streak = streak[i]
            if streak[i] == STUCK_LIMIT:
                stuck_found.append(('streak', f, i, s['slots'][i], t,
                                    chain_str(s['slots']), list(s['offsets'])))
        prev_t = {i: t_of(s, i) for i in range(ln)}

    # Финальный анализ movement_ratio
    final = state_full(sim)
    final_ln = int(final['slots_len'])
    low_ratio = []
    for i in range(min(final_ln, len(moved))):
        ratio = moved.get(i, 0) / frames
        if ratio < 0.05 and is_real(final['slots'][i]):
            low_ratio.append((i, final['slots'][i], moved[i], ratio))

    return max_streak, stuck_found, low_ratio, final


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', type=int, default=3000, help='кадров для естественного spawn')
    ap.add_argument('--tail', type=int, default=1000, help='кадров после insert')
    ap.add_argument('--log', action='store_true', help='лог каждого кадра в _replay_logs/')
    args = ap.parse_args()

    sim = ZumaFullZ80Emulator(PROJECT_ROOT)
    S = sim.sym

    # Init и build chain через естественный spawn.
    sim.call(S['Core.VDC_Init'])
    sim.set_word(S['Core.VDC_TrackNumSlots'], 240)  # никаких cap-edge

    print(f'=== Build chain: {args.build} VDC_Update frames ===')
    run_update(sim, args.build)

    # Pause spawn (BallsSpawned >= TARGET).
    sim.set_byte(S['Core.VDC_BallsSpawned'], 85)
    base = snapshot(sim)
    s_base = state_full(sim)
    print(f"  base len={s_base['slots_len']} hsa={s_base['hsa']}.{s_base['hsub']:02d} "
          f"slots=[{chain_str(s_base['slots'])}]")

    # Scripted inserts. Варьируем target и color.
    ln = s_base['slots_len']
    scenarios = []
    for tgt in [ln // 4, ln // 2, ln // 2 + 1, 3 * ln // 4, ln - 2]:
        for color in [0, 1, 2, 3]:
            scenarios.append((tgt, color))

    print(f'\n=== {len(scenarios)} insert scenarios × {args.tail} frames each ===')

    any_stuck = False
    for tgt, col in scenarios:
        restore(sim, base)
        # Inject TmpInsIdx + TmpInsColor через прямой call VDC_InsertAt(a=tgt, b=col).
        sim.call(S['Core.VDC_InsertAt'], a=tgt, b=col)
        log_file = None
        if args.log:
            log_path = LOG_DIR / f'insert_t{tgt}_c{col}.log'
            log_file = open(log_path, 'w', encoding='utf-8')
        max_streak, stuck, low_ratio, final = find_stuck(sim, args.tail, log_file)
        if log_file:
            log_file.close()
        mark = ''
        if stuck or low_ratio:
            mark = '  <<< SUSPICIOUS >>>'
            any_stuck = True
        print(f'  target={tgt:3d} color={col}  max_streak={max_streak:4d}  '
              f'final_len={final["slots_len"]:3d}  low_move_ratio={len(low_ratio)}{mark}')
        if stuck:
            for tag, f, i, slot, t, slots_str, offsets in stuck[:3]:
                print(f'      STREAK f={f} i={i} slot={slot} t={t} slots=[{slots_str[:60]}...]')
        if low_ratio:
            for i, slot, moved_n, ratio in low_ratio[:3]:
                print(f'      LOW-RATIO i={i} slot={slot} moved={moved_n}/{args.tail} ratio={ratio:.1%}')

    print('\n=== summary ===')
    if any_stuck:
        print('  >>> найдены stuck-сценарии — см. выше <<<')
    else:
        print(f'  ни один из {len(scenarios)} сценариев не показал stuck >= {STUCK_LIMIT} кадров')

    return 2 if any_stuck else 0


if __name__ == '__main__':
    raise SystemExit(main())
