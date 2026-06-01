#!/usr/bin/env python3
"""Проверка WIN «бегущей дорожки» на реально загруженном дубль-уровне L05.
(1) VDC_WinSnapAllChains в PLAY снимает head-сэмпл (фронт цепи); (2) при очистке
цепочки head НЕ сбрасывается (keep-last); (3) ZL_DrawWinSweep эмитит команды
(дорожка взрывов от головы до килл-зоны)."""
from __future__ import annotations
import os, sys, functools
from pathlib import Path
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
from full_stack_trace import FullStackTrace
from zx7_dec import dzx7_turbo
print=functools.partial(print, flush=True)
ROOT=Path(HERE).parent.parent

fs=FullStackTrace(ROOT, shadow_ft812=True)
e=fs.emu; S=fs.sym
def gb(n): return e.get_byte(S[n])
def gw(n): return e.get_word(S[n])

HOOK_PCS=set(x for x in (S.get(n) for n in
    ("Core.sd_init","Core.sd_read_sector","FT.Coprocessor.Inflate","FT.WriteMem")) if x is not None)
DZX7=S.get("Dzx7Turbo")
RETNOW=set(x for x in (S.get(n) for n in
    ("FT.Coprocessor.WaitFlush","FT.Coprocessor.IsFault","FT.Coprocessor.Wait",
     "FT.Coprocessor.Write","FT.Coprocessor.Write32")) if x is not None)
bare=fs.orig_step; hook_pc=fs._hook_pc
def ret_now():
    sp=e.reg.SP; ret=e.mem.read(sp)|(e.mem.read((sp+1)&0xFFFF)<<8)
    e.reg.SP=(sp+2)&0xFFFF; e.reg.PC=ret; e.reg.F&=~0x01
def fast():
    pc=e.reg.PC
    if pc in RETNOW: ret_now(); return 0
    if pc==DZX7:
        src=(e.reg.H<<8)|e.reg.L; dst=(e.reg.D<<8)|e.reg.E
        comp=bytes(e.mem.read((src+k)&0xFFFF) for k in range(min(0x10000-src,16384)))
        out,consumed=dzx7_turbo(comp)
        for k,b in enumerate(out): e.mem.write((dst+k)&0xFFFF,b)
        h=(src+consumed)&0xFFFF; e.reg.H=h>>8; e.reg.L=h&0xFF
        d=(dst+len(out))&0xFFFF; e.reg.D=d>>8; e.reg.E=d&0xFF
        sp=e.reg.SP; ret=e.mem.read(sp)|(e.mem.read((sp+1)&0xFFFF)<<8)
        e.reg.SP=(sp+2)&0xFFFF; e.reg.PC=ret; return 0
    if pc in HOOK_PCS and hook_pc(pc): return 0
    return bare()
e.step=fast

def call(n, ms=4_000_000):
    sp=(e.reg.SP-2)&0xFFFF; e.set_word(sp,0xFFFE); e.reg.SP=sp; e.reg.PC=S[n]
    steps=0
    while e.reg.PC!=0xFFFE:
        e.step(); steps+=1
        if steps>ms: raise TimeoutError(f"{n} timeout PC=#{e.reg.PC:04X}")
    return steps

call("Core.Init_Core")
e.set_byte(S["Core.CurrentLevel"], 4)        # L05 дубль
call("Core.LoadGameplayAssets")
for f in range(40):
    e.set_byte(S["Core.VDC_GameState"],0)
    call("Core.VDC_UpdateAllChains")

h1=gw("Core.VDC_WinHeadS1")
l1=gb("Core.VDC_SlotsLen"); l2=gb("Core.VDC2_SlotsLen")
print(f"после 40 кадров PLAY: chain1={l1} chain2={l2}  VDC_WinHeadS1={h1} (head sample)")
ok=True
if h1 in (0xFFFF, 0):
    print("FAIL: head-сэмпл не снят — дорожки не будет"); ok=False

prev=h1
e.set_byte(S["Core.VDC_SlotsLen"],0)
e.set_byte(S["Core.VDC2_SlotsLen"],0)
e.set_byte(S["Core.VDC_GameState"],0)
call("Core.VDC_UpdateAllChains")
h1b=gw("Core.VDC_WinHeadS1")
print(f"после кадра с пустыми цепочками: VDC_WinHeadS1={h1b} (было {prev})")
if h1b!=prev:
    print("FAIL: head сброшен на пустом кадре — к WIN данных не будет"); ok=False

# аутро: init эмиттеров + прогон VDC_UpdateWin → частицы должны заспавниться,
# затем DrawWinStateVisual эмитит команды на живые частицы.
CMD=0x5E00
def meas(r):
    e.set_word(S["FT.Coprocessor.BufferPtr"],CMD)
    try: call(r)
    except Exception as ex: print(f"  {r} EXC {ex} PC=#{e.reg.PC:04X}")
    return ((e.get_word(S["FT.Coprocessor.BufferPtr"])-CMD)&0xFFFF)//4
e.set_byte(S["Core.VDC_GameState"],6)            # VDC_STATE_WIN
e.set_byte(S["Core.VDC_WinTick"],250)
call("Core.VDC_WinOutroInit")
act=gb("Core.VDC_WinOutroActive")
print(f"VDC_WinOutroActive после init = {act}")
if act!=1:
    print("FAIL: аутро не активировалось"); ok=False
for _ in range(20):
    call("Core.VDC_UpdateWin")
# посчитать живые частицы
base=S["Core.VDC_WinPrtcl"]; alive=sum(1 for i in range(32) if e.get_byte(base+i*5+4)!=255)
print(f"живых частиц после 20 кадров аутро = {alive}")
if alive==0:
    print("FAIL: эмиттер не родил ни одной частицы"); ok=False
cmds=meas("Core.DrawWinStateVisual")
print(f"DrawWinStateVisual эмитнул {cmds} команд ({alive} частиц)")
if cmds < 4:
    print("FAIL: частицы не рисуются"); ok=False

print("PASS: head-сэмпл снят, переживает очистку, дорожка рисуется" if ok else "PROBE FAILED")
sys.exit(0 if ok else 1)
