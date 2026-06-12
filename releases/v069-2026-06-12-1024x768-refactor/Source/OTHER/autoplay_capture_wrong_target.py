#!/usr/bin/env python3
"""autoplay_capture_wrong_target.py — реальная gameplay-эмуляция через Codex'овский
full harness. Bot fires в random visible chain slots, ловит момент wrong-target.

Для каждого insert event замеряем:
  - bullet_pos в момент collision
  - inserted_idx (где встал шар)
  - nearest_visible_slot (по Manhattan)
  - delta = |inserted - nearest|

Где delta > 5 — bug.
"""
from __future__ import annotations
import os, sys, random
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT

CELL_SIZE = 32
WRONG_TARGET_DELTA = 5
FROG_X = 320
FROG_Y = 240


def signed(b): return b - 256 if b & 0x80 else b


def call_slot_pos(sim, i):
    """Direct call VDC_SlotPos(A=i). Returns (cf, x, y)."""
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


def slots_state(sim):
    S = sim.sym
    ln = sim.get_byte(S['Core.VDC_SlotsLen'])
    slots = list(sim.get_memory(S['Core.VDC_Slots'], ln))
    return ln, slots


def set_mouse_aim(sim, target_x, target_y):
    """Установить mouse в (target_x, target_y) так чтобы frog aim угол показывал туда."""
    sim.input.mouse_x = target_x
    sim.input.mouse_y = target_y


def fire(sim, on):
    """Зажать/отпустить LMB (bit 0 mouse_buttons)."""
    if on:
        sim.input.mouse_buttons = 0x02  # LMB pressed (active low: 0)
    else:
        sim.input.mouse_buttons = 0x03  # nothing pressed


def find_inserted_idx(slots_before, slots_after):
    """Найти где в chain появился новый шар."""
    if len(slots_after) != len(slots_before) + 1:
        return None
    for i in range(len(slots_after)):
        if i >= len(slots_before):
            return i
        if slots_after[i] != slots_before[i]:
            return i
    return None


# === Main loop ===
sim = ZumaFullZ80Emulator(PROJECT_ROOT)
sim.game_init()

# Warmup: spawn 35-50 шаров без стрельбы.
print('=== warmup: spawn chain ===')
for f in range(2000):
    sim.game_frame()
ln, slots = slots_state(sim)
print(f'  after warmup: len={ln} slots={slots[:20]}...')

# Pre-cache valid slot positions для nearest lookup.
def cache_positions(sim):
    ln, _ = slots_state(sim)
    pos = []
    for i in range(ln):
        cf, x, y = call_slot_pos(sim, i)
        if not cf:
            pos.append((i, x, y))
    return pos

# === Gameplay autopilot: aim+fire ===
print('\n=== autoplay 8000 frames, fire каждые 30 ===')
log_events = []
prev_len = ln

random.seed(42)

for f in range(8000):
    # Каждые 30 кадров выбираем random target slot и стреляем.
    if f % 30 == 0:
        positions = cache_positions(sim)
        if positions:
            target = random.choice(positions)
            tx, ty = target[1], target[2]
            set_mouse_aim(sim, tx, ty)
            fire(sim, True)
    elif f % 30 == 5:
        fire(sim, False)

    sim.game_frame()

    # Detect insert event by SlotsLen change.
    new_len, new_slots = slots_state(sim)
    if new_len > prev_len:
        # Insert произошёл. Замерим где встал и куда летел bullet.
        S = sim.sym
        bx = sim.get_byte(S['Core.Bullet_X']) | (sim.get_byte(S['Core.Bullet_X'] + 1) << 8)
        by = sim.get_byte(S['Core.Bullet_Y']) | (sim.get_byte(S['Core.Bullet_Y'] + 1) << 8)
        bx = bx if bx < 0x8000 else bx - 0x10000
        by = by if by < 0x8000 else by - 0x10000

        # Slots before insert restored из prev_slots — нет, мы потеряли. Use snapshot.
        # Hack: compare current slots с prev_slots (cached at start of frame).
        prev_slots_local = prev_slots if 'prev_slots' in dir() else []
        # Actually we need snapshot taken BEFORE game_frame. Skip and reconstruct from new_slots.
        # Find inserted idx as first non-(i%4) position — но patterns spawn random colors, this won't work.
        # Approximation: use VDC_TmpInsIdx if available
        ti = S.get('Core.VDC_TmpInsIdx')
        target_idx = sim.get_byte(ti) if ti else None
        positions = cache_positions(sim)
        if positions and target_idx is not None:
            dists = [(i, abs(bx - x) + abs(by - y)) for i, x, y in positions]
            nearest_i, nearest_d = min(dists, key=lambda t: t[1])
            delta = abs(target_idx - nearest_i)
            event = {
                'frame': f,
                'bullet_pos': (bx, by),
                'inserted_at': target_idx,
                'nearest': nearest_i,
                'nearest_d': nearest_d,
                'delta': delta,
                'slots_len': new_len,
            }
            log_events.append(event)
            if delta > WRONG_TARGET_DELTA:
                print(f'  ⚠ frame {f}: bullet@({bx},{by}) inserted_at={target_idx} '
                      f'nearest={nearest_i} (d={nearest_d}) DELTA={delta}')
    prev_len = new_len
    prev_slots = new_slots

print(f'\n=== {len(log_events)} insert events captured ===')
wrong = [e for e in log_events if e['delta'] > WRONG_TARGET_DELTA]
print(f'wrong-target events (delta > {WRONG_TARGET_DELTA}): {len(wrong)}')
for w in wrong[:20]:
    print(f'  frame {w["frame"]:5d} bullet@({w["bullet_pos"][0]:3d},{w["bullet_pos"][1]:3d}) '
          f'inserted={w["inserted_at"]:3d} nearest={w["nearest"]:3d} delta={w["delta"]}')
