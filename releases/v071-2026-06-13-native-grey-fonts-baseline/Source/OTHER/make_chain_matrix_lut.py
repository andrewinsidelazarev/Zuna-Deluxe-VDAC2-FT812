#!/usr/bin/env python3
"""make_chain_matrix_lut.py — пред-вычисление BITMAP_TRANSFORM матриц для 32
quantized углов вращения шара цепи.

Mirror текущего asm CMD-цикла:
  CMD_LOADIDENTITY → CMD_TRANSLATE(+16, +16) → CMD_ROTATE(a)
  → CMD_TRANSLATE(-16, -16) → CMD_SETMATRIX

ZL_EmitRotate в asm:
  effective_BRAD = (input_BRAD + 192) & 0xFF
  ft_angle = effective_BRAD × 256 (16-bit, 65536 = full rotation)

LUT format: 32 buckets × 6 BITMAP_TRANSFORM opcodes × 4 bytes = 768 bytes.
Каждый bucket = 24 bytes (один LDIR блок).

Opcodes:
  0x15 BITMAP_TRANSFORM_A (cos, Q8.8 signed 17-bit)
  0x16 BITMAP_TRANSFORM_B (-sin, Q8.8 17-bit)
  0x17 BITMAP_TRANSFORM_C (translation X, Q23.8 24-bit)
  0x18 BITMAP_TRANSFORM_D (sin, Q8.8 17-bit)
  0x19 BITMAP_TRANSFORM_E (cos, Q8.8 17-bit)
  0x1A BITMAP_TRANSFORM_F (translation Y, Q23.8 24-bit)

LE 32-bit words; FT_CMD_BUF писет E, D, C, B → LE.
"""
import math
import struct
from pathlib import Path

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
OUT = ROOT / 'Graphics' / 'Converted' / 'chain_matrix_lut.bin'

BALL_HALF = 16     # atlas cell half (32×32 atlas) — UV pivot
BALL_DRAW = 51     # 1024×768 port: on-screen draw size = round(32 × 8/5)
UV_SCALE  = (BALL_HALF * 2) / BALL_DRAW   # 32/51: screen→UV scale baked into A,B,D,E
                                          # so a BALL_DRAW-px rect samples the full 32px atlas.
                                          # C/F (translation) stay UNCHANGED because
                                          # UV_SCALE × (BALL_DRAW/2) = atlas/2 = BALL_HALF.
NUM_BUCKETS = 32   # 8 BRAD quantization (256 / 8)
ANGLE_OFFSET = 192 # ZL_EmitRotate +192 offset


def opcode_word(opcode, value, mask):
    return (opcode << 24) | (value & mask)


def encode_q88(x):
    """Q8.8 signed 17-bit (low 17 bits used). Range ~[-128, 128]."""
    v = int(round(x * 256))
    return v & 0x1FFFF


def encode_translation(x):
    """Q23.8 (or however FT812 expects translation) 24-bit signed."""
    v = int(round(x * 256))
    return v & 0xFFFFFF


def matrix_for_bucket(b):
    """Return 6-tuple (A, B, C, D, E, F) fixed-point matrix for bucket b."""
    raw_brad = b * 8                              # bucket centre BRAD (LOWER bound)
    eff_brad = (raw_brad + ANGLE_OFFSET) & 0xFF
    rad = eff_brad * 2.0 * math.pi / 256.0
    cos_a = math.cos(rad)
    sin_a = math.sin(rad)
    # FT812 BITMAP_TRANSFORM maps screen (x,y) → texture (u,v).
    # Visual CCW rotation by θ требует U = R(-θ)·X. Знаки sin'а ниже подобраны
    # эмпирически чтобы матчить CMD_ROTATE coprocessor output (compare-проверка
    # с не-LUT версией кадра 1500, см. учебник).
    A = encode_q88(cos_a * UV_SCALE)
    B = encode_q88(sin_a * UV_SCALE)
    D = encode_q88(-sin_a * UV_SCALE)
    E = encode_q88(cos_a * UV_SCALE)
    # Translation: U-vector centered at (BALL_HALF, BALL_HALF) → screen.
    # C/F derived from M·(0,0) = (cx(1-cos)-cy·sin, cx·sin+cy(1-cos))
    C = encode_translation(BALL_HALF * (1 - cos_a) - BALL_HALF * sin_a)
    F = encode_translation(BALL_HALF * sin_a + BALL_HALF * (1 - cos_a))
    return A, B, C, D, E, F


def build_lut(path, atlas_half, draw_px, buckets=NUM_BUCKETS):
    """Запечь BITMAP_TRANSFORM LUT (buckets записей): rotate вокруг центра атласа
    + scale atlas→draw (A,B,D,E × atlas/draw; C/F от atlas_half — инвариантны).
    ANGLE_OFFSET (+192, native face DOWN) ВШИТ — caller передаёт сырой угол!"""
    uv_scale = (atlas_half * 2) / draw_px
    out = bytearray()
    for b in range(buckets):
        raw_brad = b * (256 // buckets)
        eff_brad = (raw_brad + ANGLE_OFFSET) & 0xFF
        rad = eff_brad * 2.0 * math.pi / 256.0
        cos_a = math.cos(rad)
        sin_a = math.sin(rad)
        A = encode_q88(cos_a * uv_scale)
        B = encode_q88(sin_a * uv_scale)
        D = encode_q88(-sin_a * uv_scale)
        E = encode_q88(cos_a * uv_scale)
        C = encode_translation(atlas_half * (1 - cos_a) - atlas_half * sin_a)
        F = encode_translation(atlas_half * sin_a + atlas_half * (1 - cos_a))
        out += struct.pack('<I', opcode_word(0x15, A, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x16, B, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x17, C, 0xFFFFFF))
        out += struct.pack('<I', opcode_word(0x18, D, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x19, E, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x1A, F, 0xFFFFFF))
    path.write_bytes(out)
    print(f'  saved {path.name}: {len(out)} bytes ({buckets}x24, '
          f'atlas_half={atlas_half}, draw={draw_px})')


def main():
    out = bytearray()
    for b in range(NUM_BUCKETS):
        A, B, C, D, E, F = matrix_for_bucket(b)
        # 6 opcodes, LE 32-bit each
        out += struct.pack('<I', opcode_word(0x15, A, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x16, B, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x17, C, 0xFFFFFF))
        out += struct.pack('<I', opcode_word(0x18, D, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x19, E, 0x1FFFF))
        out += struct.pack('<I', opcode_word(0x1A, F, 0xFFFFFF))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(out)
    print(f'  saved {OUT.name}: {len(out)} bytes ({NUM_BUCKETS}×24)')

    # 1024×768: frog-маркер превью level-select — атлас 58×58, draw 58*8//5=92.
    # 256 бакетов = ПОЛНАЯ точность BRAD (1 запись на каждый угол, без квантования).
    build_lut(OUT.parent / 'preview_frog_matrix_lut.bin', 29, 58 * 8 // 5, buckets=256)

    # Sanity print: bucket 0 (BRAD 192 effective = 270° = facing down)
    print('\nDecoded sanity check (bucket 0, effective BRAD 192 = 270°):')
    A, B, C, D, E, F = matrix_for_bucket(0)
    print(f'  A=cos={A:5X} ({A if A < 0x10000 else A-0x20000:6d}/256)')
    print(f'  B=-sin={B:5X}')
    print(f'  C=tx={C:6X}')
    print(f'  D=sin={D:5X}')
    print(f'  E=cos={E:5X}')
    print(f'  F=ty={F:6X}')


if __name__ == '__main__':
    main()
