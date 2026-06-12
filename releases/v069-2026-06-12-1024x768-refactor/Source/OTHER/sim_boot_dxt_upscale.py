#!/usr/bin/env python3
"""sim_boot_dxt_upscale.py — модель FT812-вывода boot pseudo-DXT фона на 1024×768.

Вопрос: «что-попало» на boot-экране после ×1.6 — это баг кода или дизеринг
L4-маски, который NEAREST-апскейл превращает в кашу?

Рендерит три PNG:
  boot_bg_640.png           — нативный декод (эталон, как было на 640×480)
  boot_bg_1024_nearest.png  — точная модель текущего DL: маска NEAREST ×1.6,
                              цвета NEAREST ×6.4 (floor-сэмплинг как FT812)
  boot_bg_1024_bilinear.png — модель фикса: маска и цвета BILINEAR
"""
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
RAW = ROOT / "Graphics" / "Converted" / "BootLoading" / "boot_loading_bg_dxt_l4.raw"
OUT = ROOT / "Diagnostics"

C_W, C_H = 160, 120            # endpoint-плоскости RGB565
M_W, M_H = 640, 480            # L4 маска
C0_OFF, C1_OFF, MASK_OFF = 0x000000, 0x009600, 0x012C00
SCR_W, SCR_H = 1024, 768


def rgb565_plane(buf, off):
    a = np.frombuffer(buf, dtype="<u2", count=C_W * C_H, offset=off)
    a = a.reshape(C_H, C_W).astype(np.uint32)
    r = ((a >> 11) & 31) * 255 // 31
    g = ((a >> 5) & 63) * 255 // 63
    b = (a & 31) * 255 // 31
    return np.stack([r, g, b], axis=-1).astype(np.float64)


def l4_mask(buf, off):
    raw = np.frombuffer(buf, dtype=np.uint8, count=M_W * M_H // 2, offset=off)
    raw = raw.reshape(M_H, M_W // 2)
    hi = raw >> 4            # левый пиксель — старший ниббл
    lo = raw & 0x0F
    m = np.empty((M_H, M_W), dtype=np.uint8)
    m[:, 0::2] = hi
    m[:, 1::2] = lo
    return (m.astype(np.float64) * 17.0) / 255.0   # 0..15 → альфа 0..1


def sample_nearest(img, u, v):
    ui = np.clip(np.floor(u).astype(int), 0, img.shape[1] - 1)
    vi = np.clip(np.floor(v).astype(int), 0, img.shape[0] - 1)
    return img[vi, ui]


def sample_bilinear(img, u, v):
    # FT812 BILINEAR: центр текселя в (i+0.5)
    u = u - 0.5
    v = v - 0.5
    u0 = np.floor(u).astype(int)
    v0 = np.floor(v).astype(int)
    fu = (u - u0)[..., None] if img.ndim == 3 else (u - u0)
    fv = (v - v0)[..., None] if img.ndim == 3 else (v - v0)
    u0c = np.clip(u0, 0, img.shape[1] - 1)
    u1c = np.clip(u0 + 1, 0, img.shape[1] - 1)
    v0c = np.clip(v0, 0, img.shape[0] - 1)
    v1c = np.clip(v0 + 1, 0, img.shape[0] - 1)
    p00 = img[v0c, u0c]
    p10 = img[v0c, u1c]
    p01 = img[v1c, u0c]
    p11 = img[v1c, u1c]
    return (p00 * (1 - fu) * (1 - fv) + p10 * fu * (1 - fv)
            + p01 * (1 - fu) * fv + p11 * fu * fv)


def compose(c0, c1, alpha):
    out = c0 * (1.0 - alpha[..., None]) + c1 * alpha[..., None]
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


def main():
    buf = RAW.read_bytes()
    c0 = rgb565_plane(buf, C0_OFF)
    c1 = rgb565_plane(buf, C1_OFF)
    mask = l4_mask(buf, MASK_OFF)
    OUT.mkdir(exist_ok=True)

    # --- эталон 640 (как было): маска per-pixel, цвета NEAREST ×4 ---
    ys, xs = np.mgrid[0:480, 0:640]
    a640 = mask[ys, xs]
    c0n = sample_nearest(c0, xs / 4.0, ys / 4.0)
    c1n = sample_nearest(c1, xs / 4.0, ys / 4.0)
    Image.fromarray(compose(c0n, c1n, a640)).save(OUT / "boot_bg_640.png")

    # --- текущий DL: NEAREST, маска ×1.6 (A=160/256), цвета ×6.4 (A=40/256) ---
    ys, xs = np.mgrid[0:SCR_H, 0:SCR_W]
    u_m = xs * (160.0 / 256.0)
    v_m = ys * (160.0 / 256.0)
    u_c = xs * (40.0 / 256.0)
    v_c = ys * (40.0 / 256.0)
    a = sample_nearest(mask, u_m, v_m)
    c0s = sample_nearest(c0, u_c, v_c)
    c1s = sample_nearest(c1, u_c, v_c)
    Image.fromarray(compose(c0s, c1s, a)).save(OUT / "boot_bg_1024_nearest.png")

    # --- фикс-кандидат: BILINEAR маска и цвета ---
    a_b = sample_bilinear(mask, u_m, v_m)
    c0b = sample_bilinear(c0, u_c, v_c)
    c1b = sample_bilinear(c1, u_c, v_c)
    Image.fromarray(compose(c0b, c1b, a_b)).save(OUT / "boot_bg_1024_bilinear.png")

    # --- гипотеза бага: CMD_SCALE(0x1999A) инвертируется копроцессором с
    # усечением → маска A=159/256, а цвета (CMD_SCALE 6.4) A=40/256 ровно.
    # Пары «пиксель маски ↔ блок цветов» расходятся с ростом x/y → шум.
    u_t = xs * (159.0 / 256.0)
    v_t = ys * (159.0 / 256.0)
    a_t = sample_nearest(mask, u_t, v_t)
    Image.fromarray(compose(c0s, c1s, a_t)).save(OUT / "boot_bg_1024_trunc159.png")

    # --- гибрид (идея Gemini, но на ТОЧНЫХ матрицах): маска BILINEAR,
    # цвета NEAREST — мягкие переходы блендинга без смаза блоков c0/c1.
    a_h = sample_bilinear(mask, u_m, v_m)
    Image.fromarray(compose(c0s, c1s, a_h)).save(OUT / "boot_bg_1024_hybrid.png")

    print("saved Diagnostics/boot_bg_{640,1024_nearest,1024_bilinear,1024_trunc159,1024_hybrid}.png")


if __name__ == "__main__":
    main()
