#!/usr/bin/env python3
"""test_gauge_shown_anim.py — проверка animation VDC_GaugeShown → VDC_GaugeScore."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim

def main():
    sim = ZumaZ80Sim()
    S = sim.sym
    # Setup match-3 scenario
    for a in (S['Core.VDC_Slots'], S['Core.VDC_Offsets'],
              S['Core.VDC_ExplodeFrame'], S['Core.VDC_ExplodeMarker']):
        for i in range(240): sim.set_byte(a + i, 0)
    chain = [2,2,2,3,3]
    for i,c in enumerate(chain): sim.set_byte(S['Core.VDC_Slots']+i, c)
    sim.set_byte(S['Core.VDC_SlotsLen'], len(chain))
    for k in ('Core.VDC_StatCombos','Core.VDC_StatChainCount','Core.VDC_GaugeFull'):
        sim.set_byte(S[k], 0)
    sim.set_byte(S['Core.VDC_StatPrevMatchColor'], 0xFF)
    for w in ('Core.VDC_GaugeScore','Core.VDC_GaugeShown','Core.VDC_PlayerScore'):
        sim.set_byte(S[w], 0); sim.set_byte(S[w]+1, 0)
    # Fire match-3
    sim.set_byte(S['Core.VDC_TmpInsIdx'], 1)
    sim.call(S['VDC_CheckMatch3'] if 'VDC_CheckMatch3' in S else S['Core.VDC_CheckMatch3'])

    def get(name):
        addr = S[name]
        return sim.get_byte(addr) | (sim.get_byte(addr+1) << 8)

    print(f'After match: GaugeScore={get("Core.VDC_GaugeScore")} GaugeShown={get("Core.VDC_GaugeShown")} PlayerScore={get("Core.VDC_PlayerScore")}')

    # Tick animation 10 frames
    for frame in range(10):
        sim.call(S.get('VDC_TickGaugeShown', S.get('Core.VDC_TickGaugeShown')))
        print(f'  frame {frame+1}: Shown={get("Core.VDC_GaugeShown")}')

if __name__ == '__main__':
    main()
