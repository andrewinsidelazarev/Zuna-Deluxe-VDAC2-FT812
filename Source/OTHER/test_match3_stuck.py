#!/usr/bin/env python3
"""test_match3_stuck.py — воспроизведение «один шар стоит на месте после match-3».

Inject chain [0,1,2,2,2,1,0,3,3], trigger CheckMatch3(idx=3), отключаем spawn
(BallsSpawned == TARGET=85), прогон 400 кадров, отслеживаем t(i) для каждого
шара и ищем те, что не двигаются > 64 кадров (= 2 × GAP_STEP_FRAMES, заведомо
больше штатной CASCADE-паузы).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim

CELL_SIZE = 32
sim = ZumaZ80Sim()
S = sim.sym


def gap_diag():
    accum = sim.get_byte(S["Core.VDC_GapAccum"]) | (sim.get_byte(S["Core.VDC_GapAccum"] + 1) << 8)
    junction = sim.get_byte(S["Core.VDC_GapJunction"])
    pos_left = sim.get_byte(S["Core.VDC_GapPosLeft"])
    return f"ga={accum} gj={junction} gp={pos_left}"


sim.call(S['Core.VDC_Init'])
sim.set_byte(S['Core.VDC_TrackNumSlots'],     85)
sim.set_byte(S['Core.VDC_TrackNumSlots'] + 1, 0)

chain = [0, 1, 2, 2, 2, 1, 0, 3, 3]
HSA = 20
sim.set_byte(S['Core.VDC_HSA'], HSA)
sim.set_byte(S['Core.VDC_HSA'] + 1, 0)
sim.set_byte(S['Core.VDC_HSub'], 0)
sim.set_byte(S['Core.VDC_SlotsLen'], len(chain))
# Отключить spawn: BallsSpawned == TARGET → TrySpawn внутри VDC_Update сразу RET.
sim.set_byte(S['Core.VDC_BallsSpawned'], 85)
for i, c in enumerate(chain):
    sim.set_byte(S['Core.VDC_Slots'] + i, c)


def state():
    return sim.vdc_state()


def t_of(s, i):
    return (s['hsa'] - i) * CELL_SIZE + s['hsub'] + s['offsets'][i]


def is_real_ball(slot_byte):
    return slot_byte < 6  # VDC_NUM_COLORS


sim.set_byte(S['Core.VDC_TmpInsIdx'], 3)
print('=== BEFORE match-3 ===')
s0 = state()
print(f"  HSA={s0['hsa']:2d} len={s0['slots_len']} slots=[{sim.format_slots(s0['slots'])}]")

sim.call(S['Core.VDC_CheckMatch3'])
print('\n=== AFTER CheckMatch3 ===')
s1 = state()
print(f"  HSA={s1['hsa']:2d} HSub={s1['hsub']:2d} len={s1['slots_len']} "
      f"slots=[{sim.format_slots(s1['slots'])}] "
      f"fc={sim.get_byte(S['Core.VDC_ChainFreezeCnt'])} {gap_diag()}")
print(f"  offsets={s1['offsets']}")

N = 400
print(f'\n=== run {N} VDC_Update frames ===')

# t-history: t[frame][i] — но достаточно prev_t для streak подсчёта.
prev_t = {i: t_of(s1, i) for i in range(s1['slots_len'])}
prev_slots = list(s1['slots'])
stuck = {i: 0 for i in range(s1['slots_len'])}

# Печатаем компактно: только кадры где есть изменения slot map или каждый 50-й.
key_frames = []
last_slots_str = sim.format_slots(s1['slots'])

for f in range(N):
    sim.call(S['Core.VDC_Update'])
    s = state()
    cur_t = {i: t_of(s, i) for i in range(s['slots_len'])}
    cur_slots_str = sim.format_slots(s['slots'])

    # Apдейт stuck-счётчиков
    for i in range(s['slots_len']):
        if i in prev_t and cur_t[i] == prev_t[i]:
            stuck[i] = stuck.get(i, 0) + 1
        else:
            stuck[i] = 0

    if cur_slots_str != last_slots_str or f % 32 == 0:
        fc = sim.get_byte(S['Core.VDC_ChainFreezeCnt'])
        key_frames.append((f, s['hsa'], s['hsub'], s['slots_len'], cur_slots_str, fc,
                          dict(stuck)))
        last_slots_str = cur_slots_str

    prev_t = cur_t

# Печать key-frames.
for f, hsa, hsub, ln, ss, fc, st in key_frames[:30]:
    stuck_now = {i: v for i, v in st.items() if v > 32 and i < ln}
    extra = f"  stuck>{32}f: {stuck_now}" if stuck_now else ''
    print(f'  f={f:3d}: HSA={hsa:2d}.{hsub:02d} len={ln:2d} [{ss}] fc={fc}{extra}')

print('\n=== final state ===')
s = state()
print(f"  HSA={s['hsa']} HSub={s['hsub']} len={s['slots_len']} slots=[{sim.format_slots(s['slots'])}]")
print(f"  offsets={s['offsets']}")
print(f"  ChainFreezeCnt={sim.get_byte(S['Core.VDC_ChainFreezeCnt'])}")
print(f"  {gap_diag()}")
print(f"  MatchScanIdx={sim.get_byte(S['Core.VDC_MatchScanIdx'])}")

# Финальный список «застрявших».
stuck_balls = {i: v for i, v in stuck.items() if v > 64 and i < s['slots_len'] and is_real_ball(s['slots'][i])}
if stuck_balls:
    print(f"\n>>> STUCK REAL BALLS (>64 frames idle): {stuck_balls} <<<")
    for i in stuck_balls:
        print(f"    i={i} slot={s['slots'][i]} off={s['offsets'][i]} t={t_of(s, i)}")
else:
    print('\nno real-ball balls stuck > 64 frames')
