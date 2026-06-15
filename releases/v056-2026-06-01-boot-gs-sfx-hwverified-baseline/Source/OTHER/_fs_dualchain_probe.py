#!/usr/bin/env python3
"""Fullstack-проба двойной цепочки на РЕАЛЬНОМ Z80-коде, состояние из дампа 111.

Дамп 111 уже содержит загруженный L05 (обе цепочки, TNS=79). Грузим его 4 слота
в физические страницы по page-map [#00,#05,#06,#04], держим PLAY и гоняем
настоящий VDC_UpdateAllChains N кадров, снимая длины/HSA обеих цепочек. Это
детерминированно показывает, наполняются ли обе симметрично или одна застывает.
"""
from __future__ import annotations
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT, PAGE_SIZE

DUMP = os.path.join(PROJECT_ROOT, "111")
dump = open(DUMP, "rb").read()
assert len(dump) == 65536

emu = ZumaFullZ80Emulator(PROJECT_ROOT)
S = emu.sym
# page-map на момент дампа: slot0=#00 slot1=#05(Core) slot2=#06 slot3=#04
emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
# загрузить логический образ дампа через текущую раскладку
for addr in range(65536):
    emu.mem.write(addr, dump[addr])

def gb(n): return emu.get_byte(S[n])
def sb(n, v): emu.set_byte(S[n], v)
def gw(n): return emu.get_word(S[n])
def call(n, **kw): emu.call(S[n], **kw)

emu.reg.SP = 0x40F2     # штатный игровой стек

print("HasSecondChain =", gb("Core.VDC_HasSecondChain"),
      " GameState =", gb("Core.VDC_GameState"),
      " GaugeFull =", gb("Core.VDC_GaugeFull"),
      " SecondActive =", gb("Core.VDC_SecondActive"))
print("старт: chain1 len=", gb("Core.VDC_SlotsLen"), "hsa=", gb("Core.VDC_HSA"),
      "| chain2 len=", gb("Core.VDC2_SlotsLen"), "hsa=", emu.get_byte(S["Core.VDC2_ChainLocal"]),
      " TNS=", gw("Core.VDC_TrackNumSlots"))

def lens():
    c1 = gb("Core.VDC_SlotsLen"); c1h = gb("Core.VDC_HSA")
    c2 = gb("Core.VDC2_SlotsLen"); c2h = emu.get_byte(S["Core.VDC2_ChainLocal"])
    bs1 = gb("Core.VDC_BallsSpawned")
    return c1, c1h, c2, c2h, bs1

N = 1500
print(f"\n=== {N} кадров VDC_UpdateAllChains (реальный Z80) ===")
print("frame  c1_len c1_hsa c1_spawn | c2_len c2_hsa")
for f in range(N):
    sb("Core.VDC_GameState", 0)        # держим PLAY
    sb("Core.VDC_GaugeFull", 0)        # держим спавн включённым (чистая проверка наполнения)
    try:
        call("Core.VDC_UpdateAllChains")
    except Exception as e:
        print(f"  кадр {f}: исключение {e} PC=#{emu.reg.PC:04X}")
        break
    if f % 100 == 0 or f == N-1:
        c1, c1h, c2, c2h, bs1 = lens()
        print(f"{f:5d}   {c1:4d}  {c1h:4d}  {bs1:5d}   |  {c2:4d}  {c2h:4d}")

c1, c1h, c2, c2h, bs1 = lens()
print(f"\nИТОГ: chain1 len={c1} hsa={c1h} | chain2 len={c2} hsa={c2h}  TNS={gw('Core.VDC_TrackNumSlots')}")
if abs(c1 - c2) > 3:
    print(f"  !!! АСИММЕТРИЯ: разница длин {abs(c1-c2)} — одна цепочка отстаёт/обрезана")
else:
    print("  цепочки наполняются симметрично")
