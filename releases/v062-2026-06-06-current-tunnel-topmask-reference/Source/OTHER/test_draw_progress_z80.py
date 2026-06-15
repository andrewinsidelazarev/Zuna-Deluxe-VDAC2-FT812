#!/usr/bin/env python3
"""test_draw_progress_z80.py — реальный binary Z80 вызов DrawHudProgress,
читаем emitted SCISSOR_SIZE и проверяем что для GaugeShown=30 width=1 px.
"""
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim

def main():
    sim = ZumaZ80Sim()
    S = sim.sym
    # Initialize FT BufferPtr to a known location (use unused area, e.g. 0x9000 in slot 2)
    # FT.Coprocessor.BufferPtr is a word
    buf_ptr_addr = S.get('FT.Coprocessor.BufferPtr', None)
    if buf_ptr_addr is None:
        # find it
        for k in sim.sym:
            if 'BufferPtr' in k:
                buf_ptr_addr = sim.sym[k]
                print(f'BufferPtr at {hex(buf_ptr_addr)} (sym {k})')
                break
    print('BufferPtr loc:', hex(buf_ptr_addr))
    BUF_START = 0x9000
    sim.set_byte(buf_ptr_addr, BUF_START & 0xFF)
    sim.set_byte(buf_ptr_addr + 1, (BUF_START >> 8) & 0xFF)
    # zero out buf area
    for i in range(256):
        sim.set_byte(BUF_START + i, 0)

    # Set GaugeShown=30, GaugeFull=0
    sim.set_byte(S['Core.VDC_GaugeShown'], 30)
    sim.set_byte(S['Core.VDC_GaugeShown'] + 1, 0)
    sim.set_byte(S['Core.VDC_GaugeFull'], 0)

    # Find DrawHudProgress
    draw_addr = S.get('DrawHudProgress', None)
    if draw_addr is None:
        for k in sim.sym:
            if 'DrawHudProgress' in k and not k.endswith('.End') and '.' not in k.replace('DrawHudProgress', ''):
                draw_addr = sim.sym[k]
                break
    print('DrawHudProgress at:', hex(draw_addr))

    # Call it
    try:
        sim.call(draw_addr, max_steps=200_000)
    except Exception as e:
        print(f'Exception during call: {e}')

    # Read buffer — find SCISSOR_SIZE opcode (0x1C in top byte LE position)
    print('\nBuffer bytes after DrawHudProgress (GaugeShown=30):')
    for i in range(0, 128, 4):
        b = [sim.get_byte(BUF_START + i + j) for j in range(4)]
        word = (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0]
        opcode = (word >> 24) & 0xFF
        comment = ''
        if opcode == 0x1B:
            x = (word >> 11) & 0x7FF
            y = word & 0x7FF
            comment = f'SCISSOR_XY({x},{y})'
        elif opcode == 0x1C:
            w = (word >> 12) & 0x7FF
            h = word & 0x7FF
            comment = f'SCISSOR_SIZE({w},{h})  ← бар width'
        elif opcode == 0x1F:
            comment = f'BEGIN'
        elif opcode == 0x1:
            comment = 'BITMAP_SOURCE'
        elif opcode == 0x6:
            comment = 'CELL'
        elif opcode == 0x40 or opcode == 0x42:
            x = ((word >> 15) & 0x7FFF) - (0x4000 if word & 0x40000000 else 0)
            y = ((word >> 0) & 0x7FFF)
            comment = f'VERTEX2F'
        print(f'  +{i:02X}: {b[0]:02X} {b[1]:02X} {b[2]:02X} {b[3]:02X}  ({word:08X})  {comment}')
        if all(x == 0 for x in b):
            break

if __name__ == '__main__':
    main()
