#!/usr/bin/env python3
"""test_tail_fix_verify.py — verify ASM cap-branch (.ia_cap_branch) state matches
expected "normal HSA=86 flow" semantically.

ASM сейчас выполняет cap-fix внутри VDC_InsertAt (.ia_cap_branch):
  1. offsets[idx] ← +CELL_SIZE/2 (instead of -CS/2 normal)
  2. offsets[idx+1..len-1] += CELL_SIZE (clamp to +CS)
  3. offsets[0..idx-1] unchanged (нет head_comp at cap)

Test просто проверяет actual ASM state после InsertAt совпадает с тем что
было бы при normal HSA=86 flow с head_comp -CS. Раньше тест делал manual
override + duplicate +CS (что давало +32 mismatch).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim

CELL_SIZE = 32
sim = ZumaZ80Sim()
S = sim.sym

# Setup cap-state: HSA=85=cap, SlotsLen=85.
sim.call(S['Core.VDC_Init'])
sim.set_byte(S['Core.VDC_TrackNumSlots'], 85)
sim.set_byte(S['Core.VDC_TrackNumSlots'] + 1, 0)
HSA, SLOTS_LEN = 85, 85
sim.set_byte(S['Core.VDC_HSA'], HSA)
sim.set_byte(S['Core.VDC_HSub'], 0)
sim.set_byte(S['Core.VDC_SlotsLen'], SLOTS_LEN)
sim.set_byte(S['Core.VDC_BallsSpawned'], 85)
for i in range(SLOTS_LEN):
    sim.set_byte(S['Core.VDC_Slots'] + i, [0, 1, 2][i % 3])

TARGET, COLOR = 42, 1
sim.call(S['Core.VDC_InsertAt'], a=TARGET, b=COLOR)
state = sim.vdc_state()

print(f'=== ASM cap-branch state after InsertAt(target={TARGET}, color={COLOR}) ===')
print(f'  HSA={state["hsa"]} HSub={state["hsub"]} SlotsLen={state["slots_len"]}')


def signed_byte(b):
    return b - 0x100 if b & 0x80 else b


def actual_t(i):
    off = signed_byte(sim.get_byte(S['Core.VDC_Offsets'] + i))
    return (state['hsa'] - i) * CELL_SIZE + state['hsub'] + off


def expected_t(i, total_len):
    """Semantic equivalent при HSA=86 normal flow + head_comp -CS."""
    HSA_normal = 86
    if i < TARGET:
        off = -CELL_SIZE
    elif i == TARGET:
        off = -CELL_SIZE // 2
    else:
        off = 0
    return (HSA_normal - i) * CELL_SIZE + 0 + off


print('\n=== compare ASM cap-branch actual t(i) vs expected (HSA=86 normal) ===')
mismatches = 0
for i in range(state['slots_len']):
    et = expected_t(i, state['slots_len'])
    at = actual_t(i)
    off = signed_byte(sim.get_byte(S['Core.VDC_Offsets'] + i))
    if at != et:
        mismatches += 1
        if mismatches <= 5:
            print(f'  i={i:3d}  asm_off={off:+4d}  asm_t={at:+5d}  expected={et:+5d}  diff={at - et:+4d}  ✗')

print(f'\nmismatches: {mismatches} / {state["slots_len"]}')
monotone = all(actual_t(i) > actual_t(i + 1) for i in range(state['slots_len'] - 1))
print(f'  → монотонность t(i): {monotone}')
print(f'  → t(head=0)   = {actual_t(0)}  (expected {expected_t(0, state["slots_len"])})')
print(f'  → t(tail={state["slots_len"] - 1}) = {actual_t(state["slots_len"] - 1)}  '
      f'(expected {expected_t(state["slots_len"] - 1, state["slots_len"])})')
print(f'  → t(new={TARGET})  = {actual_t(TARGET)}')

if mismatches == 0 and monotone:
    print('\nPASS')
else:
    print('\nFAIL')
    sys.exit(1)
