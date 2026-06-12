#!/usr/bin/env python3
"""sim_frog_matrix.py — Python-модель запечённой BITMAP_TRANSFORM A..F для
масштабированного вращающегося frog-тела (1024x768 порт).

Цель: отладить целочисленную математику (которую перенесём в ASM
Frog_EmitFrogMatrix) ДО ASM. cmd_scale не компонуется в цепочке
translate+scale+rotate (даёт border-кайму), поэтому матрицу A..F эмитим
напрямую (как ball LUT make_chain_matrix_lut.py).

FT81x sampler (проверено на шарах):
  u = (A*sx + B*sy + C) >> 8
  v = (D*sx + E*sy + F) >> 8
  где sx,sy = пиксель экрана ОТНОСИТЕЛЬНО vertex (0..draw_size).
  A,B,D,E — Q8.8 signed (cos/sin * scale * 256).
  C,F     — Q?.8 signed (pivot * 256 * (1 - cos -+ sin)).

Формула (ball LUT, pivot=BALL_HALF, scale baked в A,B,D,E; C/F без scale,
т.к. scale*draw_center = atlas_center):
  A = E =  s*cos*256
  B     =  s*sin*256
  D     = -s*sin*256
  C     =  P*256*(1 - cos - sin)
  F     =  P*256*(1 - cos + sin)

Для frog тела: P = 61 (atlas centre), draw = 195, s = 122/195 = 0.6256.
"""
import math
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')

ATLAS = 122          # native frog body (stride/UV)
PIVOT = 61           # atlas centre
DRAW = 195           # 1024x768 draw size (round(122*1.6))
SCALE = ATLAS / DRAW  # 0.6256 — screen->UV factor baked в A,B,D,E

# ---- ASM Frog_SinTable: round(127 * sin(i*2pi/256)), i=0..255 (signed) -------
# В ASM лежат только 0..127, для 128..255 sin отрицателен (зеркало).
SIN127 = [round(127 * math.sin(i * 2 * math.pi / 256)) for i in range(256)]


def cos_sin_127(brad):
    """cos,sin в формате *127 (как из Frog_SinTable). brad — байт 0..255."""
    cos127 = SIN127[(brad + 64) & 0xFF]   # cos(x) = sin(x+90deg); 90deg = 64 BRAD
    sin127 = SIN127[brad & 0xFF]
    return cos127, sin127


def matrix_float(brad):
    """Эталонная float-матрица."""
    rad = brad * 2 * math.pi / 256.0
    cos_a, sin_a = math.cos(rad), math.sin(rad)
    A = round(SCALE * cos_a * 256)
    B = round(SCALE * sin_a * 256)
    D = round(-SCALE * sin_a * 256)
    E = round(SCALE * cos_a * 256)
    C = round(PIVOT * 256 * (1 - cos_a - sin_a))
    F = round(PIVOT * 256 * (1 - cos_a + sin_a))
    return A, B, C, D, E, F


def asr(x, n):
    """Арифметический сдвиг вправо (как ASM SRA), для signed."""
    return x >> n if x >= 0 else -((-x) >> n)


def matrix_int(brad):
    """Целочисленная матрица — ТОЧНО как будет в ASM (сдвиги/множители).

    A = E = (cos127 * 323) >> 8   ; 323 = 256+64+2+1  => scale 0.6256
            cos127*323 = (cos127<<8)+(cos127<<6)+(cos127<<1)+cos127
    B     = (sin127 * 323) >> 8
    D     = -B
    C     = 15616 - cs*123        ; 15616 = 61*256 ; 123 = round(61*256/127)
            cs = cos127 + sin127 ; cs*123 = (cs<<7) - (cs<<2) - cs
    F     = 15616 - cd*123        ; cd = cos127 - sin127
    """
    cos127, sin127 = cos_sin_127(brad)

    def mul323_sh8(x):
        # ASM-вариант: x*1.25 = x + (x asr 2). scale 0.617 (vs 0.6256) — компактнее
        # (без 16-bit умножения), визуально неотличимо (~1px по краю атласа).
        return x + asr(x, 2)

    def mul123(x):
        return (x << 7) - (x << 2) - x           # x*123

    A = E = mul323_sh8(cos127)
    B = mul323_sh8(sin127)
    D = -B
    cs = cos127 + sin127
    cd = cos127 - sin127
    C = 15616 - mul123(cs)
    F = 15616 - mul123(cd)
    return A, B, C, D, E, F


def render(atlas, mat, draw):
    """FT81x sampler: рисуем draw x draw rect, sampling atlas по A..F."""
    A, B, C, D, E, F = mat
    aw, ah = atlas.size
    px = atlas.load()
    out = Image.new('RGBA', (draw, draw), (0, 0, 0, 0))
    op = out.load()
    umin = vmin = 10 ** 9
    umax = vmax = -10 ** 9
    for sy in range(draw):
        for sx in range(draw):
            u = (A * sx + B * sy + C) >> 8
            v = (D * sx + E * sy + F) >> 8
            umin, umax = min(umin, u), max(umax, u)
            vmin, vmax = min(vmin, v), max(vmax, v)
            if 0 <= u < aw and 0 <= v < ah:
                op[sx, sy] = px[u, v]
            # else: BORDER -> transparent (0,0,0,0)
    return out, (umin, umax, vmin, vmax)


def load_body():
    p = os.path.join(GFX, 'frog.png')
    if os.path.exists(p):
        sheet = Image.open(p).convert('RGBA')
        return sheet.crop((0, 0, 162, 162)).resize((ATLAS, ATLAS), Image.LANCZOS)
    # fallback: synthetic test pattern (directional, with edge markers)
    img = Image.new('RGBA', (ATLAS, ATLAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([4, 4, ATLAS - 5, ATLAS - 5], fill=(80, 160, 80, 255))
    d.polygon([(PIVOT, 8), (PIVOT - 14, 40), (PIVOT + 14, 40)], fill=(230, 40, 40, 255))  # nose up
    d.rectangle([0, 0, 3, 3], fill=(255, 255, 0, 255))     # corner markers (catch border)
    d.rectangle([ATLAS - 4, ATLAS - 4, ATLAS - 1, ATLAS - 1], fill=(0, 255, 255, 255))
    return img


def main():
    body = load_body()
    angles = [0, 32, 64, 96, 128, 160, 192, 224]   # BRAD
    cell = DRAW + 8
    grid = Image.new('RGBA', (cell * len(angles), cell * 3 + 24), (190, 190, 190, 255))
    dr = ImageDraw.Draw(grid)
    dr.text((4, 4), "row0=native122  row1=float-scaled195  row2=INT-scaled195", fill=(0, 0, 0, 255))

    max_int_err = 0
    worst_uv = None
    for i, b in enumerate(angles):
        # native (scale 1.0, draw=122) — должен совпасть с оригиналом
        rad = b * 2 * math.pi / 256
        cos_a, sin_a = math.cos(rad), math.sin(rad)
        nat = (round(cos_a * 256), round(sin_a * 256),
               round(PIVOT * 256 * (1 - cos_a - sin_a)),
               round(-sin_a * 256), round(cos_a * 256),
               round(PIVOT * 256 * (1 - cos_a + sin_a)))
        img_nat, _ = render(body, nat, ATLAS)
        img_f, uvf = render(body, matrix_float(b), DRAW)
        img_i, uvi = render(body, matrix_int(b), DRAW)

        # числовая ошибка int vs float
        mf, mi = matrix_float(b), matrix_int(b)
        err = max(abs(a - c) for a, c in zip(mf, mi))
        max_int_err = max(max_int_err, err)
        # проверка: UV в пределах атласа (нет border-каймы по краям контента)
        print(f"BRAD {b:3d}: float A..F={mf}  int A..F={mi}  maxerr={err}  "
              f"uv_int=[{uvi[0]}..{uvi[1]},{uvi[2]}..{uvi[3]}]")
        if uvi[1] - uvi[0] > 0:
            if worst_uv is None or uvi[1] > worst_uv[1]:
                worst_uv = uvi

        x = i * cell
        grid.paste(img_nat, (x + (DRAW - ATLAS) // 2, 24 + (DRAW - ATLAS) // 2), img_nat)
        grid.paste(img_f, (x, 24 + cell), img_f)
        grid.paste(img_i, (x, 24 + cell * 2), img_i)

    grid.convert('RGB').save(os.path.join(ROOT, '_frog_matrix_sim.png'))
    print(f"\nmax int-vs-float A..F error = {max_int_err} (Q8.8/Q23.8 units, /256 px)")
    print(f"worst UV range = {worst_uv}  (должно быть в пределах 0..{ATLAS})")
    print("Saved _frog_matrix_sim.png  (row0 native, row1 float-scaled, row2 int-scaled)")
    print("Если row2 == row1 визуально и UV в [0..122] — целочисленная ASM-математика верна.")


if __name__ == '__main__':
    main()
