#!/usr/bin/env python3
"""Воспроизводим РЕАЛЬНУЮ последовательность рендера MainLoop и ловим, как рендер
chain1 ломает рендер chain2. Реальный Z80, дамп 111."""
from __future__ import annotations
import os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT
CMD=0x5E00
dump=open(os.path.join(PROJECT_ROOT,"111"),"rb").read()
e=ZumaFullZ80Emulator(PROJECT_ROOT); e.mem.pages=[0x00,0x05,0x06,0x04]
for a in range(65536): e.mem.write(a,dump[a])
e.reg.SP=0x40F2; S=e.sym
def gb(n): return e.get_byte(S[n])
def pages(): return list(e.mem.pages)
for _ in range(1400):
    e.set_byte(S["Core.VDC_GameState"],0); e.set_byte(S["Core.VDC_GaugeFull"],0)
    try: e.call(S["Core.VDC_UpdateAllChains"])
    except Exception: break

def classify(tag):
    hsa=gb("Core.VDC_HSA"); slen=gb("Core.VDC_SlotsLen"); ps=e.get_word(S["Core.VDC_pSlots"])
    NUM=3
    drawn=gap=tneg=0
    for i in range(slen):
        si=e.get_byte((ps+i)&0xFFFF)
        e.call(S["Core.VDC_SlotPos"], a=i); cf=e.reg.F&1
        if cf:
            if si>=NUM: gap+=1
            else: tneg+=1
        else: drawn+=1
    print(f"[{tag}] HSA={hsa} SlotsLen={slen} pSlots=#{ps:04X} pages={pages()} -> draw={drawn} gap={gap} t<0={tneg}")

print("pages после роста:", pages(), " (slot3 должен быть #04 = backing цепочек)")
# === РЕАЛЬНАЯ последовательность MainLoop ===
e.set_word(S["FT.Coprocessor.BufferPtr"], CMD)
try: e.call(S["Core.ZL_DrawActiveChain"])   # chain1
except Exception as ex: print("DrawActiveChain exc",ex,"PC=#%04X"%e.reg.PC)
print("pages ПОСЛЕ ZL_DrawActiveChain(chain1):", pages())
e.call(S["Core.VDC_SwapChains"])
if "Core.SetSecondTrackPage" in S: e.call(S["Core.SetSecondTrackPage"])
print("pages ПОСЛЕ SwapChains+SetSecondTrackPage:", pages())
classify("chain2 в реальной последовательности")
