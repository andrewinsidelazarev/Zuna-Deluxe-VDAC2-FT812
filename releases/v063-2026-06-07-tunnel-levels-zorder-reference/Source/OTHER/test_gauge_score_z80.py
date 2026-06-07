#!/usr/bin/env python3
"""test_gauge_score_z80.py — Z80-уровень проверка точности points/gauge formula.

Эмулирует серию match-3 событий и читает VDC_GaugeScore после каждого CheckMatch3.
Покрывает: base count*10, combo*100, chain bonus.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def setup_chain(sim, chain):
    S = sim.sym
    # Clear arrays
    for addr in (S['Core.VDC_Slots'], S['Core.VDC_Offsets'],
                 S['Core.VDC_Shot2'], S['Core.VDC_ExplodeFrame'],
                 S['Core.VDC_ExplodeMarker']):
        for i in range(240):
            sim.set_byte(addr + i, 0)
    for i, c in enumerate(chain):
        sim.set_byte(S['Core.VDC_Slots'] + i, c)
    sim.set_byte(S['Core.VDC_SlotsLen'], len(chain))


def reset_stats(sim):
    S = sim.sym
    for k in ('Core.VDC_StatCombos', 'Core.VDC_StatMaxCombo',
              'Core.VDC_StatMaxChain', 'Core.VDC_StatChainCount',
              'Core.VDC_GaugeFull'):
        if k in S: sim.set_byte(S[k], 0)
    sim.set_byte(S['Core.VDC_StatPrevMatchColor'], 0xFF)
    for w in ('Core.VDC_GaugeScore', 'Core.VDC_PlayerScore'):
        if w in S:
            sim.set_byte(S[w], 0); sim.set_byte(S[w] + 1, 0)


def get_score(sim):
    S = sim.sym
    addr = S['Core.VDC_GaugeScore']
    return sim.get_byte(addr) | (sim.get_byte(addr+1) << 8)


def get_state(sim):
    S = sim.sym
    return {
        'gauge': get_score(sim),
        'chain': sim.get_byte(S['Core.VDC_StatChainCount']),
        'combo': sim.get_byte(S['Core.VDC_StatCombos']),
        'full':  sim.get_byte(S['Core.VDC_GaugeFull']),
    }


def fire_match(sim, chain, idx, label):
    S = sim.sym
    setup_chain(sim, chain)
    sim.set_byte(S['Core.VDC_TmpInsIdx'], idx)
    pre = get_state(sim)
    sim.call(S.get('VDC_CheckMatch3', S.get('Core.VDC_CheckMatch3')))
    post = get_state(sim)
    delta = post['gauge'] - pre['gauge']
    print(f'  {label}: +{delta:4d}  gauge={post["gauge"]:4d}  chain={post["chain"]}  combo={post["combo"]}  full={post["full"]}')
    return post


def main():
    sim = ZumaZ80Sim()

    print('\n=== Case 1: 3 одинаковых шара (TmpMCount=3), первый match ===')
    print('Ожидание: 30 (base) + 0 (combo) + 0 (chain<5) = 30')
    reset_stats(sim)
    fire_match(sim, [2,2,2,3,3,4,4,5,5,1], 1, 'first M3 col=2 cnt=3')

    print('\n=== Case 2: серия match-3 БЕЗ combo (разный цвет каждый раз) ===')
    print('Каждый match-3 cnt=3 разного цвета → +30 каждый, chain++. После 5 матчей chain>=5 без combo → chain bonus.')
    reset_stats(sim)
    fire_match(sim, [2,2,2,3,3], 1, 'M1 col=2')
    fire_match(sim, [3,3,3,2,2], 1, 'M2 col=3')
    fire_match(sim, [4,4,4,2,2], 1, 'M3 col=4')
    fire_match(sim, [5,5,5,2,2], 1, 'M4 col=5')
    fire_match(sim, [1,1,1,2,2], 1, 'M5 col=1 (chain=5, combo=0 → +100 bonus)')
    fire_match(sim, [0,0,0,2,2], 1, 'M6 col=0 (chain=6 → +100+10*1=110 bonus)')

    print('\n=== Case 3: серия match-3 ОДНОГО цвета (combo) ===')
    print('Каждый match-3 одного цвета → combo++. Chain тоже растёт но combo>0 значит chain bonus disabled.')
    reset_stats(sim)
    fire_match(sim, [2,2,2,3,3], 1, 'M1 col=2 (combo=0)')
    fire_match(sim, [2,2,2,3,3], 1, 'M2 col=2 (combo=1, +100)')
    fire_match(sim, [2,2,2,3,3], 1, 'M3 col=2 (combo=2, +200)')

    print('\n=== Case 4: длинный match-3 cnt=5 ===')
    reset_stats(sim)
    fire_match(sim, [2,2,2,2,2,3,3], 2, '5-ball match col=2')

    print('\n=== Case 5: бар лезет за target=1000? ===')
    print('Если score >= 1000 → VDC_GaugeFull=1.')
    reset_stats(sim)
    for i in range(35):
        chain = [2,2,2,3,3] if i%2==0 else [3,3,3,2,2]
        st = fire_match(sim, chain, 1, f'iter {i+1}')
        if st['full']:
            print(f'  → GaugeFull triggered at iter {i+1}, gauge={st["gauge"]}')
            break


if __name__ == '__main__':
    main()
