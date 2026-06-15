#!/usr/bin/env python3
"""РЕАЛЬНЫЙ старт уровня (не дамп) на полном стеке с УСКОРЕННЫМ шагом.
Узкое место было НЕ в подаче 2-го трека (харнесс кормит RawPak), а в скорости:
пер-шаговый хук (deque PC + трейс страниц) тормозит zx7-распаковку (Dzx7Turbo)
в ~100×. Ставим лёгкий шаг (хук только по pc-сету sd/Inflate/WriteMem, без
bookkeeping) → LoadGameplayAssets для L05 проходит за секунды. Затем кадры +
полный ZL_DrawFrame с подсчётом DL и разбивкой chain1/chain2."""
from __future__ import annotations
import os, sys, functools, time
from pathlib import Path
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
from full_stack_trace import FullStackTrace
from zx7_dec import dzx7_turbo
print=functools.partial(print, flush=True)
ROOT=Path(HERE).parent.parent
CMD=0x5E00
t0=time.time()
def tlog(m): print(f"[{time.time()-t0:6.1f}s] {m}")

fs=FullStackTrace(ROOT, shadow_ft812=True)
e=fs.emu; S=fs.sym
def gb(n): return e.get_byte(S[n])
def gw(n): return e.get_word(S[n])

# --- УСКОРЕННЫЙ шаг: только нужные хуки, без пер-шагового bookkeeping ---
HOOK_PCS=set(x for x in (S.get(n) for n in
    ("Core.sd_init","Core.sd_read_sector","FT.Coprocessor.Inflate","FT.WriteMem")) if x is not None)
DZX7=S.get("Dzx7Turbo")
# FT812 coprocessor wait/poll — эмулятор не продвигает FIFO, возвращаем сразу (CF=0)
RETNOW=set(x for x in (S.get(n) for n in
    ("FT.Coprocessor.WaitFlush","FT.Coprocessor.IsFault","FT.Coprocessor.Wait",
     "FT.Coprocessor.Write","FT.Coprocessor.Write32")) if x is not None)
bare=fs.orig_step; hook_pc=fs._hook_pc
zx7_calls=[0]
def ret_now(cf=0):
    sp=e.reg.SP; ret=e.mem.read(sp)|(e.mem.read((sp+1)&0xFFFF)<<8)
    e.reg.SP=(sp+2)&0xFFFF; e.reg.PC=ret
    if cf: e.reg.F|=0x01
    else:  e.reg.F&=~0x01
def fast():
    pc=e.reg.PC
    if pc in RETNOW:
        ret_now(0); return 0
    if pc==DZX7:
        # Python-распаковка zx7: HL=src(слот2), DE=dst(слот3)
        src=(e.reg.H<<8)|e.reg.L; dst=(e.reg.D<<8)|e.reg.E
        comp=bytes(e.mem.read((src+k)&0xFFFF) for k in range(min(0x10000-src,16384)))
        out,consumed=dzx7_turbo(comp)
        for k,b in enumerate(out): e.mem.write((dst+k)&0xFFFF,b)
        h=(src+consumed)&0xFFFF; e.reg.H=h>>8; e.reg.L=h&0xFF
        d=(dst+len(out))&0xFFFF; e.reg.D=d>>8; e.reg.E=d&0xFF
        sp=e.reg.SP; ret=e.mem.read(sp)|(e.mem.read((sp+1)&0xFFFF)<<8)
        e.reg.SP=(sp+2)&0xFFFF; e.reg.PC=ret
        zx7_calls[0]+=1
        return 0
    if pc in HOOK_PCS and hook_pc(pc):
        return 0
    return bare()
def use_fast(): e.step=fast

tlog("Init_Core...")
use_fast()
def call(n, ms=4_000_000):
    sp=(e.reg.SP-2)&0xFFFF; e.set_word(sp,0xFFFE); e.reg.SP=sp; e.reg.PC=S[n]
    steps=0
    while e.reg.PC!=0xFFFE:
        e.step(); steps+=1
        if steps>ms: raise TimeoutError(f"{n} timeout PC=#{e.reg.PC:04X}")
    return steps

call("Core.Init_Core")
e.set_byte(S["Core.CurrentLevel"], 4)        # L05 дубль
tlog("LoadGameplayAssets L05...")
n=call("Core.LoadGameplayAssets")
tlog(f"LoadGameplayAssets ОК за {n} шагов (zx7-распаковок: {zx7_calls[0]})")
print("HasSecondChain=",gb("Core.VDC_HasSecondChain"),
      " GameState=",gb("Core.VDC_GameState"),
      " chain1 TNS=",gw("Core.VDC_TrackNumSlots"),
      " chain2 TNS(stash#D899)=", e.get_byte(0xD899)|(e.get_byte(0xD89A)<<8),
      " chain1 len=",gb("Core.VDC_SlotsLen"))

# реальные кадры
N=40
for f in range(N):
    e.set_byte(S["Core.VDC_GameState"],0)
    call("Core.VDC_UpdateAllChains")
tlog(f"{N} кадров: chain1 len={gb('Core.VDC_SlotsLen')} chain2 len={gb('Core.VDC2_SlotsLen')} hsa={gb('Core.VDC_HSA')}")

# полный ZL_DrawFrame
def w32(p,v):
    for i in range(4): e.mem.write((p+i)&0xFFFF,(v>>(8*i))&0xFF)
    return (p+4)&0xFFFF
def full_frame():
    p=CMD
    p=w32(p,0xFFFFFF00); p=w32(p,(0x27<<24)|4); p=w32(p,(0x02<<24)|0x102030); p=w32(p,(0x26<<24)|0x07)
    e.set_word(S["FT.Coprocessor.BufferPtr"],p)
    try: call("Core.ZL_DrawFrame")
    except Exception as ex: print("  ZL_DrawFrame EXC:",ex,"PC=#%04X"%e.reg.PC)
    return ((e.get_word(S["FT.Coprocessor.BufferPtr"])-CMD)&0xFFFF)//4
tlog("(полный ZL_DrawFrame пропущен — HUD/курсор спинят на FT-опросе; меряем только цепочки)")

def meas(r):
    e.set_word(S["FT.Coprocessor.BufferPtr"],CMD)
    try: call(r)
    except Exception as ex: print(f"  {r} EXC {ex} PC=#{e.reg.PC:04X}")
    return ((e.get_word(S["FT.Coprocessor.BufferPtr"])-CMD)&0xFFFF)//4
call("Core.SetCurrentTrackPage")
d1=meas("Core.ZL_DrawActiveChain")
call("Core.VDC_SwapChains"); call("Core.SetSecondTrackPage")
c2=gb("Core.VDC_SlotsLen")
print(f"chain2 перед рендером: VDC_SlotsLen={c2} HSA={gb('Core.VDC_HSA')}")
d2=meas("Core.ZL_DrawActiveChainSimple")
call("Core.VDC_SwapChains")
print(f"\nchain1 рендер: {d1} команд | chain2 рендер: {d2} команд (chain2 len={c2})")
if d2 < c2: print("  !!! chain2 РИСУЕТ МЕНЬШЕ ДЛИНЫ — ОБРЕЗКА В РЕНДЕРЕ ВОСПРОИЗВЕДЕНА")
else: print("  chain2 рисуется полностью; обрезка в симуляции не воспроизводится")
