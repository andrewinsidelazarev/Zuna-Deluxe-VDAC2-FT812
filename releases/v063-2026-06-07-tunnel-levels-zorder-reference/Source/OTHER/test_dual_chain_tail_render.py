#!/usr/bin/env python3
"""Проверка хвоста цепочки 2: при полностью заполненной и продвинутой (HSA=max)
второй цепочке рендер-путь (тот же своп + SetSecondTrackPage, что в
ZL_DrawActiveChainSimple) должен дать ВАЛИДНУЮ позицию (CF=0) для КАЖДОГО
заполненного слота, включая хвостовые индексы. Любой ложный CF на хвосте = баг
«обрезан хвост цепочки 2»."""
from __future__ import annotations

from pathlib import Path

from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CASES = (5, 12, 19)


def install_ret_a(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.mem.write(addr, 0x3E)
    emu.mem.write(addr + 1, value & 0xFF)
    emu.mem.write(addr + 2, 0xC9)


def load_track_page(emu: ZumaFullZ80Emulator, page: int, path: Path) -> None:
    data = path.read_bytes()
    start = page * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    emu.mem.physical[start : start + len(data)] = data


def main() -> int:
    failures: list[str] = []
    for level in CASES:
        emu = ZumaFullZ80Emulator(ROOT)
        sym = emu.sym
        install_ret_a(emu, sym["Core.ReadRTCSeconds"], 17)
        load_track_page(emu, 0x06, PACK / f"track_l{level:02d}_640.bin")
        load_track_page(emu, 0x0F, PACK / f"track_l{level:02d}_2_640.bin")
        emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
        emu.set_byte(sym["Core.CurrentLevel"], level - 1)
        emu.set_byte(sym["Core.CurrentDifficulty"], 0)
        emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)

        cl_start = sym["Core.VDC_ChainLocalStart"]
        hsa_off = sym["Core.VDC_HSA"] - cl_start
        tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
        tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off)
        if tns2 == 0 or tns2 > 240:
            failures.append(f"L{level:02d}: tns2 невменяем = {tns2}")
            continue

        # Полностью заполнить backing store цепочки 2 цветом 0 и продвинуть HSA в max.
        for i in range(tns2):
            emu.set_byte(sym["Core.VDC2_Slots"] + i, 0)
            emu.set_byte(sym["Core.VDC2_Offsets"] + i, 0)
        emu.set_byte(sym["Core.VDC2_SlotsLen"], tns2 & 0xFF)
        emu.set_byte(sym["Core.VDC2_HSub"], 0)
        emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, tns2 & 0xFF)

        # Тот же путь, что рендерер chain2: своп цепочек + страница её трека.
        emu.call(sym["Core.VDC_SwapChains"])
        emu.call(sym["Core.SetSecondTrackPage"])

        active_len = emu.get_byte(sym["Core.VDC_SlotsLen"])
        cf_tail = []
        for i in range(active_len):
            emu.call(sym["Core.VDC_SlotPos"], a=i, max_steps=500_000)
            if emu.reg.F & 0x01:  # CF=1 → слот пропущен рендером
                cf_tail.append(i)

        # вернуть состояние
        emu.call(sym["Core.VDC_SwapChains"])
        emu.call(sym["Core.SetCurrentTrackPage"])

        print(f"L{level:02d}: tns2={tns2} active_len={active_len} CF_slots={cf_tail}")
        if active_len != (tns2 & 0xFF):
            failures.append(f"L{level:02d}: своп дал active_len {active_len} != tns2 {tns2}")
        if cf_tail:
            failures.append(
                f"L{level:02d}: {len(cf_tail)} слотов с ложным CF (обрезка хвоста): {cf_tail[:8]}..."
            )

    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print("PASS: хвост цепочки 2 рендерится полностью (CF=0 для всех заполненных слотов)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
