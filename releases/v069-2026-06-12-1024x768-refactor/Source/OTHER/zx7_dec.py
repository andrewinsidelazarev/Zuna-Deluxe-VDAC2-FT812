#!/usr/bin/env python3
"""Python-распаковка ZX7 (Dzx7Turbo) — точный порт асма main.asm:2489.
Валидация: dzx7(balls_native_p00_zx7.bin) == balls_native_p00.bin."""
from __future__ import annotations

def dzx7_turbo(data: bytes) -> bytearray:
    out = bytearray()
    i = 0
    out.append(data[i]); i += 1            # .zx7_copy_byte_loop первый литерал
    A = 0x80                               # битовый буфер (рег A)
    def getbit():
        nonlocal A, i
        # ADD A,A: CF=old bit7, A<<=1
        cf = (A >> 7) & 1
        A = (A << 1) & 0xFF
        if A == 0:                         # CALL Z .zx7_load_bits
            b = data[i]; i += 1            # LD A,(HL):INC HL
            # RLA: A=(b<<1)|old_CF, CF=b bit7
            A = ((b << 1) | cf) & 0xFF
            cf = (b >> 7) & 1
        return cf
    while True:
        if getbit() == 0:                  # JR NC .zx7_copy_byte_loop
            out.append(data[i]); i += 1
            continue
        # --- match: длина (Elias gamma) ---
        D = 0
        while True:                        # .zx7_len_size_loop: INC D; bit; JR NC loop
            D += 1
            if getbit() == 1:
                break
        BC = 1
        ended = False
        D -= 1                             # .zx7_len_value_start: DEC D
        while D != 0:                      # JR NZ .zx7_len_value_loop
            bit = getbit()
            # RL C, RL B : BC = (BC<<1)|bit, CF=old bit15
            BC = (BC << 1) | bit
            if BC & 0x10000:               # JR C .zx7_exit (overflow = конец потока)
                ended = True
                break
            BC &= 0xFFFF
            D -= 1
        if ended:
            break
        BC += 1                            # INC BC
        # --- offset ---
        E = data[i]; i += 1                # LD E,(HL):INC HL
        cf = (E >> 7) & 1                  # SLL E: CF=old bit7
        E = ((E << 1) | 1) & 0xFF          #         E=(E<<1)|1
        D = 0
        if cf == 1:                        # JR NC offset_end (пропуск если cf==0)
            D = (D << 1) | getbit()        # RL D
            D = (D << 1) | getbit()
            D = (D << 1) | getbit()
            b4 = getbit()
            ncf = 1 - b4                    # CCF
            if ncf == 0:                    # JR C offset_end → если ncf==1 прыжок, иначе INC D
                D += 1
            cf = ncf                        # CF на входе в offset_end (для RR E)
        else:
            cf = 0
        # offset_end: RR E : newE=(E>>1)|(cf<<7), newCF=old E bit0
        newcf = E & 1
        E = ((E >> 1) | (cf << 7)) & 0xFF
        # SBC HL,DE: src = dst - (D*256+E) - newCF
        offset = (D << 8) | E
        src = len(out) - offset - newcf
        # LDIR BC байт
        for _ in range(BC):
            out.append(out[src]); src += 1
    return out, i      # out=распакованное, i=потреблено сжатых байт


if __name__ == "__main__":
    import os
    ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    comp = open(os.path.join(ROOT,"Graphics","Converted","balls_native_p00_zx7.bin"),"rb").read()
    raw  = open(os.path.join(ROOT,"Graphics","Converted","balls_native_p00.bin"),"rb").read()
    got_ba, consumed = dzx7_turbo(comp); got = bytes(got_ba)
    print(f"сжатый={len(comp)} ожидаем raw={len(raw)} получили={len(got)} потреблено={consumed}")
    if got == raw:
        print("ВАЛИДАЦИЯ OK — zx7-декодер совпадает с эталоном")
    else:
        n = min(len(got), len(raw))
        d = next((k for k in range(n) if got[k]!=raw[k]), None)
        print(f"MISMATCH: первое расхождение @ {d}; got[{d}]={got[d] if d is not None else '-'} raw={raw[d] if d is not None else '-'}")
