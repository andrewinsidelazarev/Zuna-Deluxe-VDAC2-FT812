#!/usr/bin/env python3
"""HUD sprites → PALETTED4444.

Two palette groups (одни sprites не могут шарить с другими из-за разной палитры):
  • hud_palette  — life_frog (зелёные оттенки) → `hud_palette_argb4.bin`
  • dialog_palette — MAIN MENU + PLAY buttons (жёлто-коричневые) → `dialog_palette_argb4.bin`

Outputs (Graphics/Converted/):
  life_frog.bin                       — 20×20 = 400 bytes
  hud_menu_atlas.bin                  — 3×79×26 = 6162 bytes
  hud_progress_atlas.bin              — 2×63×19 = 2394 bytes
  hud_palette_argb4.bin               — 512 bytes ARGB4 LE
  dialog_main_menu_{state}.bin × 3    — 211×84 = 17724 bytes каждый
  dialog_play_{state}.bin × 3         — 157×49 = 7693 bytes каждый
  dialog_palette_argb4.bin            — 512 bytes ARGB4 LE
  + ZX7-compressed variants `*_zx7.bin` для больших sprite'ов

Palette layout (одинаковый для обоих):
  index 0      = fully transparent (alpha=0)
  indices 1..N = opaque RGBA centroids (alpha=0xF)
"""
import os
import subprocess
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = ROOT / 'Graphics' / 'Original' / 'sprites'
OUT = ROOT / 'Graphics' / 'Converted'
OUT.mkdir(parents=True, exist_ok=True)

LIFE_FROG_SIZE = 20


def quantize_rgba(pool: np.ndarray, K: int = 255, seed: int = 42) -> np.ndarray:
    """K-means на RGBA pool → (K, 4) uint8 centroids."""
    rng = np.random.default_rng(seed)
    X = pool.astype(np.float32)
    if len(X) > 30000:
        idx = rng.choice(len(X), 30000, replace=False)
        X = X[idx]
    init_idx = rng.choice(len(X), min(K, len(X)), replace=False)
    centers = X[init_idx].copy()
    if len(centers) < K:
        centers = np.vstack([centers, np.tile(centers[0], (K - len(centers), 1))])
    for it in range(25):
        labels = np.empty(len(X), dtype=np.int32)
        for i in range(0, len(X), 5000):
            batch = X[i:i+5000]
            d = ((batch[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
            labels[i:i+5000] = np.argmin(d, axis=1)
        new_centers = centers.copy()
        for k in range(K):
            mem = X[labels == k]
            if len(mem) > 0:
                new_centers[k] = mem.mean(axis=0)
        shift = np.linalg.norm(new_centers - centers)
        centers = new_centers
        if shift < 1.0:
            break
    return np.clip(centers, 0, 255).astype(np.uint8)


def map_to_palette(im_rgba: np.ndarray, palette: np.ndarray) -> np.ndarray:
    H, W = im_rgba.shape[:2]
    flat = im_rgba.reshape(-1, 4).astype(np.float32)
    indices = np.zeros(len(flat), dtype=np.uint8)
    transparent = flat[..., 3] < 8
    opaque = flat[~transparent]
    if len(opaque) > 0:
        candidates = palette[1:].astype(np.float32)
        dists = np.empty((len(opaque), len(candidates)), dtype=np.float32)
        for i in range(0, len(opaque), 5000):
            batch = opaque[i:i+5000]
            d = np.linalg.norm(batch[:, None, :] - candidates[None, :, :], axis=2)
            dists[i:i+5000] = d
        nearest = np.argmin(dists, axis=1).astype(np.uint8) + 1
        indices[~transparent] = nearest
    return indices.reshape(H, W)


def rgba_to_argb4_le_bytes(palette: np.ndarray) -> bytes:
    out = bytearray()
    for i in range(256):
        if i < len(palette):
            r, g, b, a = (int(palette[i][k]) for k in range(4))
        else:
            r = g = b = a = 0
        a4 = (a >> 4) & 0xF
        r4 = (r >> 4) & 0xF
        g4 = (g >> 4) & 0xF
        b4 = (b >> 4) & 0xF
        word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
        out += word.to_bytes(2, 'little')
    assert len(out) == 512
    return bytes(out)


def build_palette_for(pixels_pool: np.ndarray, K: int) -> np.ndarray:
    """Return (256, 4) full palette: idx 0 = transparent, idx 1..K = quantized centroids."""
    centers = quantize_rgba(pixels_pool, K=K)
    full = np.zeros((256, 4), dtype=np.uint8)
    full[1:1+K] = centers
    full[1:1+K, 3] = 0xFF  # force opaque alpha
    return full


def zx7_compress(src: Path, dst: Path):
    """Wrap compress_zx7.py CLI."""
    subprocess.check_call(['python', str(HERE / 'compress_zx7.py'), str(src), str(dst)])


def process_life_frog():
    src = Image.open(SRC / 'life_frog.png').convert('RGBA')
    life = src.resize((LIFE_FROG_SIZE, LIFE_FROG_SIZE), Image.LANCZOS)
    life_rgba = np.array(life)
    pool = life_rgba[life_rgba[..., 3] > 8]
    palette = build_palette_for(pool, K=64)
    indices = map_to_palette(life_rgba, palette)
    (OUT / 'life_frog.bin').write_bytes(indices.tobytes())
    (OUT / 'hud_palette_argb4.bin').write_bytes(rgba_to_argb4_le_bytes(palette))
    # Preview
    recon = palette[indices]
    Image.fromarray(recon, 'RGBA').save(ROOT / '_life_frog_paletted_preview.png')
    print(f'life_frog.bin: {indices.size} bytes, hud_palette: 512')


# Source sprites are from 720p HD-ref. VDAC2 frame is 480p, so scale is 2/3.
HUD_MENU_W = 79
HUD_MENU_H = 26
HUD_MENU_STATES = [
    ('menu_inactive.png', 0),
    ('menu_pressed.png', 1),  # filenames are swapped in the extracted set
    ('menu_active.png', 2),
]
HUD_PROGRESS_W = 63
HUD_PROGRESS_H = 19
HUD_PROGRESS_STATES = [
    ('progress_green.png', 0),
    ('progress_yellow.png', 1),
]


def process_hud_sprites():
    life_src = Image.open(SRC / 'life_frog.png').convert('RGBA')
    life = life_src.resize((LIFE_FROG_SIZE, LIFE_FROG_SIZE), Image.LANCZOS)
    life_rgba = np.array(life)

    menu_frames = []
    for fname, _cell in HUD_MENU_STATES:
        img = Image.open(SRC / fname).convert('RGBA')
        img = img.resize((HUD_MENU_W, HUD_MENU_H), Image.LANCZOS)
        menu_frames.append(np.array(img))

    progress_frames = []
    for fname, _cell in HUD_PROGRESS_STATES:
        img = Image.open(SRC / fname).convert('RGBA')
        img = img.resize((HUD_PROGRESS_W, HUD_PROGRESS_H), Image.LANCZOS)
        progress_frames.append(np.array(img))

    pool = [life_rgba[life_rgba[..., 3] > 8]]
    pool.extend(arr[arr[..., 3] > 8] for arr in menu_frames)
    pool.extend(arr[arr[..., 3] > 8] for arr in progress_frames)
    palette = build_palette_for(np.concatenate(pool), K=220)

    life_idx = map_to_palette(life_rgba, palette)
    (OUT / 'life_frog.bin').write_bytes(life_idx.tobytes())

    atlas = np.zeros((HUD_MENU_H * 3, HUD_MENU_W), dtype=np.uint8)
    for arr, (_fname, cell) in zip(menu_frames, HUD_MENU_STATES):
        atlas[cell * HUD_MENU_H:(cell + 1) * HUD_MENU_H, :] = map_to_palette(arr, palette)
    (OUT / 'hud_menu_atlas.bin').write_bytes(atlas.tobytes())

    progress = np.zeros((HUD_PROGRESS_H * 2, HUD_PROGRESS_W), dtype=np.uint8)
    for arr, (_fname, cell) in zip(progress_frames, HUD_PROGRESS_STATES):
        progress[cell * HUD_PROGRESS_H:(cell + 1) * HUD_PROGRESS_H, :] = map_to_palette(arr, palette)
    (OUT / 'hud_progress_atlas.bin').write_bytes(progress.tobytes())
    (OUT / 'hud_palette_argb4.bin').write_bytes(rgba_to_argb4_le_bytes(palette))

    Image.fromarray(palette[life_idx], 'RGBA').save(ROOT / '_life_frog_paletted_preview.png')
    Image.fromarray(palette[atlas], 'RGBA').save(ROOT / '_hud_menu_atlas_preview.png')
    Image.fromarray(palette[progress], 'RGBA').save(ROOT / '_hud_progress_atlas_preview.png')
    print(f'life_frog.bin: {life_idx.size} bytes')
    print(f'hud_menu_atlas.bin: {atlas.size} bytes, hud_palette: 512')
    print(f'hud_progress_atlas.bin: {progress.size} bytes')


DIALOG_SPRITES = [
    # name, source_filename, target_w, target_h.
    # target_w*target_h MUST be <= 16384 (один SPG page после UnpackAndUploadPage),
    # ИЛИ кратно 16384 (дробится на чанки в process loop).
    ('dialog_frame',             'dialog_frame.png',             400, 327),  # 130800 = 8 chunks (last has 272 wasted)
    ('dialog_main_menu_normal',  'dialog_main_menu_normal.png',  200, 80),   # 16000, scaled from 211×84
    ('dialog_main_menu_hover',   'dialog_main_menu_hover.png',   200, 80),
    ('dialog_main_menu_pressed', 'dialog_main_menu_pressed.png', 200, 80),
    ('dialog_play_normal',       'dialog_play_normal.png',       157, 49),   # 7693 fits 1 chunk natively
    ('dialog_play_hover',        'dialog_play_hover.png',        157, 49),
    ('dialog_play_pressed',      'dialog_play_pressed.png',      157, 49),
    ('dialog_ok_normal',         '__ok_wide_green__',             300, 34),
]


def make_ok_button_wide_green(w: int, h: int) -> Image.Image:
    """Wide green OK button matching the original final Game Over menu."""
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Stone outer rim + dark inner line + bright green capsule.
    draw.rounded_rectangle((0, 0, w - 1, h - 1), radius=8,
                           fill=(166, 170, 139, 255), outline=(67, 68, 54, 255), width=2)
    draw.rounded_rectangle((5, 5, w - 6, h - 6), radius=7,
                           fill=(30, 70, 25, 255), outline=(227, 230, 205, 255), width=1)
    for y in range(7, h - 7):
        t = (y - 7) / max(1, (h - 14))
        r = int(28 + 18 * (1 - t))
        g = int(205 - 70 * t)
        b = int(45 + 5 * (1 - t))
        draw.line((9, y, w - 10, y), fill=(r, g, b, 255))
    draw.rounded_rectangle((9, 7, w - 10, h - 8), radius=6,
                           outline=(78, 235, 82, 220), width=1)
    draw.line((18, 9, w - 20, 9), fill=(125, 255, 112, 150), width=1)

    font_path = Path(r'C:\Windows\Fonts\impact.ttf')
    font = ImageFont.truetype(str(font_path), 16) if font_path.exists() else ImageFont.load_default()
    text = 'OK'
    box = draw.textbbox((0, 0), text, font=font, stroke_width=2)
    tw = box[2] - box[0]
    th = box[3] - box[1]
    x = (w - tw) // 2
    y = (h - th) // 2 - 1
    draw.text((x, y), text, font=font, fill=(255, 221, 75, 255),
              stroke_width=2, stroke_fill=(128, 45, 10, 255))
    return img


def process_dialog_sprites():
    # Загружаем все sprites, скейлим под target_w×target_h (Lanczos),
    # собираем общий пул пикселей для одной palette
    sprites_rgba = []
    pool_all = []
    for name, fname, w, h in DIALOG_SPRITES:
        if fname == '__ok_wide_green__':
            img = make_ok_button_wide_green(w, h)
        else:
            img = Image.open(SRC / fname).convert('RGBA')
        if img.size != (w, h):
            print(f'  resize {fname}: {img.size} → ({w}, {h})')
            img = img.resize((w, h), Image.LANCZOS)
        arr = np.array(img)
        sprites_rgba.append((name, arr))
        opaque = arr[arr[..., 3] > 8]
        pool_all.append(opaque)
    pool = np.concatenate(pool_all)
    print(f'Dialog pool: {len(pool)} opaque pixels из 6 sprites')

    palette = build_palette_for(pool, K=200)  # больше колоров для HD-ярких кнопок
    (OUT / 'dialog_palette_argb4.bin').write_bytes(rgba_to_argb4_le_bytes(palette))
    print('dialog_palette_argb4.bin: 512 bytes')

    # Map каждый sprite + ZX7 compress.
    # Большие sprite'ы (>16K raw) дополнительно режутся на 16K-чанки и каждый
    # чанк сжимается отдельно — потому что UnpackAndUploadPage заливает ровно
    # один SPG page (декомпрессированный 16K блок) за вызов.
    PAGE_BYTES = 16384
    for name, arr in sprites_rgba:
        idx = map_to_palette(arr, palette)
        raw = idx.tobytes()
        raw_path = OUT / f'{name}.bin'
        raw_path.write_bytes(raw)
        recon = palette[idx]
        Image.fromarray(recon, 'RGBA').save(ROOT / f'_{name}_paletted_preview.png')
        if len(raw) > PAGE_BYTES:
            # Split into 16K chunks, last padded with zeros.
            num_chunks = (len(raw) + PAGE_BYTES - 1) // PAGE_BYTES
            total_zx7 = 0
            for i in range(num_chunks):
                chunk = raw[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
                if len(chunk) < PAGE_BYTES:
                    chunk = chunk + b'\x00' * (PAGE_BYTES - len(chunk))
                chunk_raw_path = OUT / f'{name}_p{i:02d}.bin'
                chunk_raw_path.write_bytes(chunk)
                chunk_zx7_path = OUT / f'{name}_p{i:02d}_zx7.bin'
                zx7_compress(chunk_raw_path, chunk_zx7_path)
                total_zx7 += chunk_zx7_path.stat().st_size
            print(f'{name}: raw {len(raw)} → {num_chunks} chunks, zx7 total {total_zx7}')
        else:
            zx7_path = OUT / f'{name}_zx7.bin'
            zx7_compress(raw_path, zx7_path)
            print(f'{name}: raw {len(raw)} → zx7 {zx7_path.stat().st_size}')


def main():
    process_hud_sprites()
    print()
    process_dialog_sprites()


if __name__ == '__main__':
    main()
