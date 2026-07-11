#!/usr/bin/env python3
"""Проверка выбора RTC/PS2-регистра Mr.Gluk в полном Z80 harness."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def check_register_selection() -> None:
    emu = ZumaFullZ80Emulator(ROOT)
    emu.out_port(0xEFF7, 0x80)

    emu.out_port(0xDFF7, 0x00)
    if emu.in_port(0xBFF7) != emu.input.rtc_seconds_bcd:
        raise AssertionError("регистр RTC seconds не вернул BCD-секунды")

    emu.out_port(0xDFF7, 0x02)
    if emu.in_port(0xBFF7) != 0:
        raise AssertionError("BCD-секунды протекли в другой регистр Mr.Gluk")

    emu.input.ps2_fifo.extend((0xE0, 0x75))
    emu.out_port(0xDFF7, 0xF0)
    values = [emu.in_port(0xBFF7) for _ in range(3)]
    if values != [0xE0, 0x75, 0x00]:
        raise AssertionError(f"неверный дренаж PS/2 FIFO: {values}")


def check_idle_input_scan() -> None:
    emu = ZumaFullZ80Emulator(ROOT)
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    set_key_pc = emu.sym["Core.Input_SetKey"]
    set_key_visits = 0
    base_step = emu.step

    def traced_step() -> int:
        nonlocal set_key_visits
        if emu.reg.PC == set_key_pc:
            set_key_visits += 1
        return base_step()

    emu.step = traced_step
    emu.call(emu.sym["Core.Input_Scan"])
    fifo_reads = sum(1 for port, _ in emu.ports_in if port == 0xBFF7)
    if set_key_visits != 0:
        raise AssertionError(f"idle Input_Scan вызвал Input_SetKey {set_key_visits} раз")
    if fifo_reads != 1:
        raise AssertionError(f"idle Input_Scan прочитал PS/2 FIFO {fifo_reads} раз")


def main() -> int:
    check_register_selection()
    check_idle_input_scan()
    print("PASS: Mr.Gluk registers разделены; idle PS/2 FIFO не вызывает Input_SetKey")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
