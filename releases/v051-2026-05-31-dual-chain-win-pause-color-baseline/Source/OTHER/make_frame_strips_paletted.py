#!/usr/bin/env python3
"""Frame strips → PALETTED4444 (shared 256-color palette).

Input: 4 PNG strips from Graphics/Original/frame_strips/
  frame_top.png    640×44
  frame_bot.png    640×24
  frame_left.png   24×412
  frame_right.png  24×412

Output (in Graphics/Converted/):
  frame_top.bin / frame_bot.bin / frame_left.bin / frame_right.bin   — 8bpp index data
  frame_palette_argb4.bin                                            — 512 bytes ARGB4 LE

Palette index 0 = fully transparent.
Indices 1..255 = quantized RGBA cluster centroids (alpha preserved per-cluster).
"""
import os
from pathlib import Path
import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = ROOT / 'Graphics' / 'Original' / 'frame_strips'
OUT = ROOT / 'Graphics' / 'Converted'
OUT.mkdir(parents=True, exist_ok=True)

STRIPS = ['frame_top', 'frame_bot', 'frame_left', 'frame_right']

def main():
    images = {}
    all_rgba = []
    for name in STRIPS:
        im = np.array(Image.open(SRC / f'{name}.png').convert('RGBA'))
        images[name] = im
        print(f'{name}: {im.shape[1]}×{im.shape[0]} = {im.shape[0]*im.shape[1]} px')
        # Only sample opaque pixels for palette (transparent ones use index 0)
        opaque_mask = im[..., 3] > 0
        all_rgba.append(im[opaque_mask])
    pool = np.concatenate(all_rgba, axis=0)
    print(f'Total opaque pixels for quantization: {len(pool)}')

    # PIL quantize on RGBA: PIL median-cut works on RGB only, so we treat alpha
    # as part of color space by quantizing RGBA together via simple KMeans (numpy-only).
    # 255 clusters (index 0 reserved for transparent).
    K = 255
    # Subsample if huge (median cut on 50k pixels is plenty representative)
    if len(pool) > 50000:
        rng = np.random.default_rng(42)
        idx = rng.choice(len(pool), 50000, replace=False)
        sample = pool[idx]
    else:
        sample = pool

    # Simple numpy K-means (no sklearn dependency).
    rng = np.random.default_rng(42)
    X = sample.astype(np.float32)
    # Init centers by random sampling from data
    init_idx = rng.choice(len(X), K, replace=False)
    centers_f = X[init_idx].copy()
    for it in range(30):
        # Assign step: batched distance compute
        labels = np.empty(len(X), dtype=np.int32)
        for i in range(0, len(X), 5000):
            batch = X[i:i+5000]
            d = ((batch[:, None, :] - centers_f[None, :, :]) ** 2).sum(axis=2)
            labels[i:i+5000] = np.argmin(d, axis=1)
        # Update step
        new_centers = centers_f.copy()
        for k in range(K):
            mem = X[labels == k]
            if len(mem) > 0:
                new_centers[k] = mem.mean(axis=0)
        shift = np.linalg.norm(new_centers - centers_f)
        centers_f = new_centers
        if shift < 1.0:
            print(f'  iter {it}: converged (shift={shift:.2f})')
            break
    centers = np.clip(centers_f, 0, 255).astype(np.uint8)
    print(f'Quantized to {K} centroids')

    # Build full palette: idx 0 = transparent, idx 1..K = centroids
    palette = np.zeros((256, 4), dtype=np.uint8)
    palette[1:1+K] = centers

    # Save palette as 512 bytes ARGB4 LE (256 × 2 bytes)
    pal_out = bytearray()
    for i in range(256):
        r, g, b, a = (int(palette[i][k]) for k in range(4))
        a4 = (a >> 4) & 0xF
        r4 = (r >> 4) & 0xF
        g4 = (g >> 4) & 0xF
        b4 = (b >> 4) & 0xF
        word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
        pal_out += word.to_bytes(2, 'little')
    assert len(pal_out) == 512
    with open(OUT / 'frame_palette_argb4.bin', 'wb') as f:
        f.write(pal_out)
    print(f'Wrote frame_palette_argb4.bin (512 bytes)')

    # For each strip: map every pixel to nearest palette index
    # Use nearest-neighbor in RGBA space (Euclidean)
    pal_f = palette.astype(np.float32)
    for name in STRIPS:
        im = images[name]
        H, W = im.shape[:2]
        flat = im.reshape(-1, 4).astype(np.float32)
        # For each pixel, find nearest palette entry
        # Transparent pixels (alpha=0) → index 0
        indices = np.zeros(len(flat), dtype=np.uint8)
        transparent = flat[..., 3] == 0
        # For opaque pixels, find nearest in centers (idx 1..K)
        opaque_pix = flat[~transparent]
        if len(opaque_pix) > 0:
            # Compute distances to all 255 centers (batched)
            dists = np.zeros((len(opaque_pix), K), dtype=np.float32)
            for i in range(0, len(opaque_pix), 5000):
                batch = opaque_pix[i:i+5000]
                d = np.linalg.norm(batch[:, None, :] - centers[None, :, :], axis=2)
                dists[i:i+5000] = d
            nearest = np.argmin(dists, axis=1).astype(np.uint8) + 1
            indices[~transparent] = nearest
        # Save raw indices (W*H bytes)
        with open(OUT / f'{name}.bin', 'wb') as f:
            f.write(indices.tobytes())
        print(f'{name}.bin: {len(indices)} bytes ({W}×{H})')

        # Preview: reconstruct from palette
        recon = palette[indices].reshape(H, W, 4)
        Image.fromarray(recon, 'RGBA').save(ROOT / f'_{name}_paletted_preview.png')

if __name__ == '__main__':
    main()
