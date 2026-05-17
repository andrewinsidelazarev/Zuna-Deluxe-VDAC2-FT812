#!/usr/bin/env python3
"""fire_into_dump111.py — заинжектить реальный game-state из dump 111
(момент cascade decay) и сверху fire bullets с разных позиций.

dump 111 содержит:
  chain len=31, HSA=52, HSub=23, BallsSpawned=35
  slots=[120210211021202310012C231302310]  ← C = GAP_CASCADE marker @ idx 20
  offsets[0..20]=+19 (head_comp decay), [21..30]=0
  shot2[20]=1, ChainFreezeCnt=19

Это РЕАЛЬНОЕ состояние из игры в момент когда юзер видел wrong-target.
"""
from __future__ import annotations
import os, sys
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT

CELL_SIZE = 32
DELTA_THR = 4

# Load dump 111 — 64KB Z80 memory snapshot.
DUMP_PATH = Path(PROJECT_ROOT) / '111'
with open(DUMP_PATH, 'rb') as f:
    dump = f.read()
print(f'dump 111: {len(dump)} bytes')


def call_routine(sim, addr, a=0, b=0, c=0):
    sim.reg.A = a
    sim.reg.B = b
    sim.reg.C = c
    sp = (sim.reg.SP - 2) & 0xFFFF
    sim.set_word(sp, 0xFFFE)
    sim.reg.SP = sp
    sim.reg.PC = addr
    return sim.run_until_pc(0xFFFE, max_steps=500000)


def call_slot_pos(sim, i):
    sim.reg.A = i
    sp = (sim.reg.SP - 2) & 0xFFFF
    sim.set_word(sp, 0xFFFE)
    sim.reg.SP = sp
    sim.reg.PC = sim.sym['Core.VDC_SlotPos']
    sim.run_until_pc(0xFFFE, max_steps=50000)
    cf = sim.reg.F & 1
    bc = (sim.reg.B << 8) | sim.reg.C
    de = (sim.reg.D << 8) | sim.reg.E
    x = bc if bc < 0x8000 else bc - 0x10000
    y = de if de < 0x8000 else de - 0x10000
    return cf, x, y


def inject_dump_state(sim):
    """Восстановить VDC + Bullet + Frog state из dump 111."""
    S = sim.sym
    # Copy critical RAM regions from dump (z80 addresses match between dump and sim).
    # VDC state region #6C56..#6C9F (Tmp* etc).
    vdc_region_start = S['Core.VDC_Slots']  # #697F
    vdc_region_end = S['Core.VDC_LastT'] + 2  # ~#6C93
    for addr in range(vdc_region_start, vdc_region_end):
        sim.mem.write(addr, dump[addr])

    # Bullet vars
    for addr in range(S['Core.Bullet_Active'], S['Core.Bullet_Active'] + 16):
        if addr < len(dump):
            sim.mem.write(addr, dump[addr])


def fire_bullet(sim, x, y, color):
    S = sim.sym
    sim.mem.write(S['Core.Bullet_Active'], 1)
    sim.mem.write(S['Core.Bullet_Color'], color)
    sim.mem.write(S['Core.Bullet_X'], x & 0xFF)
    sim.mem.write(S['Core.Bullet_X'] + 1, (x >> 8) & 0xFF)
    sim.mem.write(S['Core.Bullet_Y'], y & 0xFF)
    sim.mem.write(S['Core.Bullet_Y'] + 1, (y >> 8) & 0xFF)


def snapshot(sim):
    S = sim.sym
    return {
        'slots': list(sim.get_memory(S['Core.VDC_Slots'], 240)),
        'offsets': list(sim.get_memory(S['Core.VDC_Offsets'], 240)),
        'shot2': list(sim.get_memory(S['Core.VDC_Shot2'], 240)),
        'hsa': sim.get_byte(S['Core.VDC_HSA']),
        'hsub': sim.get_byte(S['Core.VDC_HSub']),
        'len': sim.get_byte(S['Core.VDC_SlotsLen']),
        'balls': sim.get_byte(S['Core.VDC_BallsSpawned']),
        'freeze': sim.get_byte(S['Core.VDC_ChainFreezeCnt']),
        'gapcnt': sim.get_byte(S['Core.VDC_GapStepCnt']),
        'scan': sim.get_byte(S['Core.VDC_MatchScanIdx']),
    }


def restore(sim, snap):
    S = sim.sym
    for i, v in enumerate(snap['slots']):
        sim.mem.write(S['Core.VDC_Slots'] + i, v)
    for i, v in enumerate(snap['offsets']):
        sim.mem.write(S['Core.VDC_Offsets'] + i, v)
    for i, v in enumerate(snap['shot2']):
        sim.mem.write(S['Core.VDC_Shot2'] + i, v)
    sim.mem.write(S['Core.VDC_HSA'], snap['hsa'])
    sim.mem.write(S['Core.VDC_HSub'], snap['hsub'])
    sim.mem.write(S['Core.VDC_SlotsLen'], snap['len'])
    sim.mem.write(S['Core.VDC_BallsSpawned'], snap['balls'])
    sim.mem.write(S['Core.VDC_ChainFreezeCnt'], snap['freeze'])
    sim.mem.write(S['Core.VDC_GapStepCnt'], snap['gapcnt'])
    sim.mem.write(S['Core.VDC_MatchScanIdx'], snap['scan'])


# === Main ===
sim = ZumaFullZ80Emulator(PROJECT_ROOT)
sim.game_init()  # set up FT812 / Frog / Bullet stubs

inject_dump_state(sim)
base = snapshot(sim)
print(f'\n=== injected state ===')
print(f'  len={base["len"]} HSA={base["hsa"]}.{base["hsub"]:02d} freeze={base["freeze"]}')
slots_str = ''.join(['S' if s == 0xFE else 'C' if s == 0xFD else '.' if s == 0xFF else str(s)
                     for s in base['slots'][:base['len']]])
print(f'  slots: [{slots_str}]')
print(f'  offsets[0..20]: {base["offsets"][:21]}')

# Cache slot positions
positions = []
for i in range(base['len']):
    cf, x, y = call_slot_pos(sim, i)
    positions.append((i, cf, x, y))
real = [(i, x, y) for i, cf, x, y in positions if not cf]
print(f'\n  valid (rendered) positions: {len(real)}')
for i, x, y in real[:5]:
    print(f'    i={i} ({x},{y})')
print(f'    ... last: i={real[-1][0]} ({real[-1][1]},{real[-1][2]})')

# Fire bullets из множества точек.
print('\n=== fire bullets sweep ===')
wrong_events = []
for ball_idx, ball_x, ball_y in real:
    for dx in (-10, -5, 0, 5, 10):
        for dy in (-10, -5, 0, 5, 10):
            bx, by = ball_x + dx, ball_y + dy
            restore(sim, base)
            fire_bullet(sim, bx, by, 2)
            call_routine(sim, sim.sym['Core.Bullet_CheckCollision'])
            new_len = sim.get_byte(sim.sym['Core.VDC_SlotsLen'])
            if new_len == base['len']:
                continue
            target = sim.get_byte(sim.sym['Core.VDC_TmpInsIdx'])
            dists = [(i, abs(bx - x) + abs(by - y)) for i, x, y in real]
            nearest_i, nd = min(dists, key=lambda t: t[1])
            delta = abs(target - nearest_i)
            if delta > DELTA_THR:
                wrong_events.append({
                    'bullet': (bx, by),
                    'aimed_at_ball': ball_idx,
                    'target': target,
                    'nearest': nearest_i,
                    'nearest_d': nd,
                    'delta': delta,
                })

print(f'\nfires tested: {len(real) * 25}')
print(f'wrong-target (delta > {DELTA_THR}): {len(wrong_events)}')
for w in wrong_events[:15]:
    print(f'  bullet@({w["bullet"][0]:3d},{w["bullet"][1]:3d})  aimed_at_ball={w["aimed_at_ball"]:2d}  '
          f'target={w["target"]:3d}  nearest={w["nearest"]:2d}  d={w["nearest_d"]:3d}  delta={w["delta"]}')
