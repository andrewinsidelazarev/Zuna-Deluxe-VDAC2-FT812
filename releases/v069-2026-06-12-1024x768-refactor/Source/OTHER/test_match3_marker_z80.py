#!/usr/bin/env python3
"""test_match3_marker_z80.py — Z80-уровень проверка bug-fix'а на match-3 marker.

Bug 2026-05-20: в VDC_CheckMatch3 регистр B (= marker GAP_STOP/CASCADE)
клобался stats-блоком (`LD B, A` в gauge-loop'е) → после анимации в Slots
писалось 0 = color blue (3 синих шара на месте gap'а).

Тест:
  1. Манипулируем VDC state directly без VDC_Init (VDC_Init виснет в Z80 sim
     из-за I/O-stub'ов на ReadRTCSeconds + отсутствующего TrackData).
  2. Заполняем Slots = [0,0,0,0,0,1,1,1,0,0,0,0,0]  (3 шара цвета 1 в idx 5..7).
  3. TmpInsIdx = 6 (центр группы).
  4. Вызываем VDC_CheckMatch3.
  5. Читаем ExplodeMarker[5..7] — должны быть #FE (GAP_STOP), а не 0/мусор.

Ожидаемый PASS: marker = #FE для всех 3 ячеек.
До фикса: marker = 0 (или мусор после клобка B).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def reset_vdc_state(sim, chain):
    S = sim.sym
    for addr in (S['Core.VDC_Slots'], S['Core.VDC_Offsets'],
                 S['Core.VDC_Shot2'], S['Core.VDC_ExplodeFrame'],
                 S['Core.VDC_ExplodeMarker']):
        for i in range(240):
            sim.set_byte(addr + i, 0)
    for i, c in enumerate(chain):
        sim.set_byte(S['Core.VDC_Slots'] + i, c)
    sim.set_byte(S['Core.VDC_SlotsLen'], len(chain))
    for k in ('Core.VDC_StatCombos', 'Core.VDC_StatMaxCombo',
              'Core.VDC_StatMaxChain', 'Core.VDC_StatPrevMatchColor',
              'Core.VDC_GaugeFull'):
        if k in S:
            sim.set_byte(S[k], 0)
    for w in ('Core.VDC_StatTimeFrames', 'Core.VDC_GaugeScore',
              'Core.VDC_PlayerScore'):
        if w in S:
            sim.set_byte(S[w], 0)
            sim.set_byte(S[w] + 1, 0)


def run_case(sim, name, chain, tmp_ins_idx, group_range, expected_marker):
    S = sim.sym
    reset_vdc_state(sim, chain)
    sim.set_byte(S['Core.VDC_TmpInsIdx'], tmp_ins_idx)
    sim.call(S.get('VDC_CheckMatch3', S.get('Core.VDC_CheckMatch3')))

    marker_addr = S['Core.VDC_ExplodeMarker']
    frame_addr  = S['Core.VDC_ExplodeFrame']
    lb, rb = group_range
    markers = [sim.get_byte(marker_addr + i) for i in range(lb, rb + 1)]
    frames  = [sim.get_byte(frame_addr + i) for i in range(lb, rb + 1)]
    print(f'\n=== {name} ===')
    print(f'  chain={chain} TmpInsIdx={tmp_ins_idx}')
    print(f'  ExplodeFrame [{lb}..{rb}] = {[hex(x) for x in frames]}  (expected #01 each)')
    print(f'  ExplodeMarker[{lb}..{rb}] = {[hex(x) for x in markers]}  (expected #{expected_marker:02X} each)')

    fail = False
    for i, m in enumerate(markers):
        if m != expected_marker:
            print(f'  FAIL marker[{lb+i}]=0x{m:02X}, expected 0x{expected_marker:02X}')
            fail = True
    for i, f in enumerate(frames):
        if f != 1:
            print(f'  FAIL frame[{lb+i}]=0x{f:02X}, expected 1')
            fail = True
    return fail


def main():
    sim = ZumaZ80Sim()

    # Case 1: STOP — соседи разных цветов вокруг match-3.
    # chain = [2,2,2,2,3,1,1,1,4,2,2,2,2], match idx 5..7 (color 1)
    # Slots[4]=3 (left neighbour), Slots[8]=4 (right) → разные → STOP (#FE)
    f1 = run_case(sim, 'STOP marker',
                  chain=[2,2,2,2,3,1,1,1,4,2,2,2,2],
                  tmp_ins_idx=6,
                  group_range=(5, 7),
                  expected_marker=0xFE)

    # Case 2: CASCADE — соседи одного цвета.
    # chain = [0,0,0,0,0,1,1,1,0,0,0,0,0], match idx 5..7 (color 1)
    # Slots[4]=0, Slots[8]=0 → одного цвета → CASCADE (#FD)
    f2 = run_case(sim, 'CASCADE marker',
                  chain=[0,0,0,0,0,1,1,1,0,0,0,0,0],
                  tmp_ins_idx=6,
                  group_range=(5, 7),
                  expected_marker=0xFD)

    if f1 or f2:
        print('\n>>> FAIL: match-3 marker bug NOT fixed (B-clobber regression) <<<')
        sys.exit(1)
    print('\nALL PASS — marker сохраняется корректно через stats-блок.')


if __name__ == '__main__':
    main()
