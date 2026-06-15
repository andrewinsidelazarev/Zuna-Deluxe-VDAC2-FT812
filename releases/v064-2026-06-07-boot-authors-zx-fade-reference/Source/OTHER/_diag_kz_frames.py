"""Analyze each kill-zone frame in the HD atlas — show bbox, centroid, asymmetry."""
from PIL import Image, ImageDraw, ImageFont
import os, struct

PROJECT = os.path.dirname(os.path.abspath(__file__))
HD = os.path.join(PROJECT, "Graphics", "Original", "gameobjects.png")
if not os.path.exists(HD):
    HD = r"C:\z80\zuma\_gameobjects_hd.png"

KZ_SRC_X, KZ_SRC_Y = 629, 132
KZ_SRC_W = KZ_SRC_H = 132
KZ_FRAMES = 12
KW = KH = 64
KZ_TARGET_MAX = 60

def clear_red_guides_load(im):
    out = im.copy()
    px = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a and r > 35 and g < 30 and b < 30:
                px[x, y] = (0, 0, 0, 0)
    return out

objects = clear_red_guides_load(Image.open(HD).convert("RGBA"))
src_frames = [
    objects.crop((KZ_SRC_X, KZ_SRC_Y + i * KZ_SRC_H,
                  KZ_SRC_X + KZ_SRC_W, KZ_SRC_Y + (i + 1) * KZ_SRC_H))
    for i in range(KZ_FRAMES)
]
bboxes = [frame.split()[3].getbbox() for frame in src_frames]

print("FRAME   bbox(L,T,R,B)        bbox-center  bbox-WxH  cell-center-after-resize")
print("-" * 85)
max_dim = max(max(box[2] - box[0], box[3] - box[1]) for box in bboxes if box)
print(f"max_dim={max_dim}")
print()

for i, (frame, box) in enumerate(zip(src_frames, bboxes)):
    if box is None:
        print(f"  {i:2d}: empty")
        continue
    l, t, r, b = box
    bw, bh = r - l, b - t
    bcx, bcy = (l + r) / 2, (t + b) / 2
    src_cx, src_cy = KZ_SRC_W / 2, KZ_SRC_H / 2
    # In 132x132 source frame, native center is (66,66). bbox-center may differ.
    dx = bcx - src_cx
    dy = bcy - src_cy
    scale = KZ_TARGET_MAX / max_dim
    tw = max(2, int(round(bw * scale)))
    th = max(2, int(round(bh * scale)))
    # Centered in 64x64 cell: top-left = ((KW-tw)//2, (KH-th)//2). cell-center = (KW/2, KH/2) = (32,32) always.
    # But the bbox is CROPPED then placed centered, so original asymmetry (dx,dy) is LOST.
    print(f"  {i:2d}: ({l:3},{t:3},{r:3},{b:3})  ({bcx:5.1f},{bcy:5.1f})  {bw:3}x{bh:3}  scaled {tw:2}x{th:2}  bbox-off-from-src-center: dx={dx:+5.1f} dy={dy:+5.1f}")

# Create a per-frame composite preview showing original frame, bbox, and re-centered result side-by-side
preview = Image.new("RGB", (KZ_FRAMES * 132, 132 + 64 + 20), (40, 40, 40))
draw = ImageDraw.Draw(preview)
for i, (frame, box) in enumerate(zip(src_frames, bboxes)):
    rgb = Image.new("RGB", frame.size, (60, 60, 60))
    rgb.paste(frame, (0, 0), frame.split()[3] if frame.mode == "RGBA" else None)
    preview.paste(rgb, (i*132, 0))
    if box:
        ImageDraw.Draw(preview).rectangle([i*132+box[0], box[1], i*132+box[2], box[3]], outline="yellow", width=1)
        # Mark source center (66,66) cyan, bbox center magenta
        scx = i*132 + 66; scy = 66
        bcx = i*132 + (box[0]+box[2])//2; bcy = (box[1]+box[3])//2
        draw.ellipse([scx-2, scy-2, scx+2, scy+2], fill="cyan")
        draw.ellipse([bcx-2, bcy-2, bcx+2, bcy+2], fill="magenta")
    draw.text((i*132+4, 0), str(i), fill="white")
preview.save(os.path.join(PROJECT, "_kz_per_frame.png"))
print("\nsaved _kz_per_frame.png (yellow=bbox, cyan=src-center, magenta=bbox-center)")
