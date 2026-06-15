"""Find exact center of golden sun on bg, compare with track end (211, 217)."""
from PIL import Image, ImageDraw
import os

PROJECT = os.path.dirname(os.path.abspath(__file__))
LEVELS = os.path.expanduser("~") + r"\Desktop\Zuma Deluxe\graphics\levels"

bg = Image.open(os.path.join(LEVELS, "level_src_01.png")).convert("RGB")
print(f"bg native: {bg.size}")

# Find golden pixels around (211, 217) — golden sun is yellow/golden, distinguish from purple track
# Scan 80x80 window
px = bg.load()
golds = []
W = 100
cx, cy = 211, 217
for y in range(cy-W, cy+W):
    for x in range(cx-W, cx+W):
        if 0 <= x < bg.width and 0 <= y < bg.height:
            r, g, b = px[x, y]
            # Golden yellow: R>180, G>120, B<100
            if r > 180 and g > 120 and b < 100:
                golds.append((x, y))

if golds:
    gx = sum(p[0] for p in golds) / len(golds)
    gy = sum(p[1] for p in golds) / len(golds)
    print(f"Golden sun pixels: count={len(golds)}, centroid=({gx:.1f}, {gy:.1f})")
    print(f"Track end:        (211, 217)")
    print(f"Offset:           dx={gx-211:.1f} dy={gy-217:.1f}")
    xs = [p[0] for p in golds]; ys = [p[1] for p in golds]
    print(f"Golden bbox:      X[{min(xs)}..{max(xs)}], Y[{min(ys)}..{max(ys)}]")
    print(f"Golden bbox center: ({(min(xs)+max(xs))/2:.1f}, {(min(ys)+max(ys))/2:.1f})")
else:
    print("No golden pixels found in window!")

# Crop region around suspected kill-zone for visual check
crop_box = (cx-80, cy-80, cx+80, cy+80)
crop = bg.crop(crop_box).resize((400, 400), Image.NEAREST)
draw = ImageDraw.Draw(crop)
# Coord transform: orig (x,y) → crop (x-cx+80, y-cy+80) → scaled *2.5
def to_crop(x, y):
    return ((x-cx+80)*2.5, (y-cy+80)*2.5)
# Mark track end (magenta)
mx, my = to_crop(211, 217)
draw.ellipse([mx-6, my-6, mx+6, my+6], outline="magenta", width=2)
# Draw 64x64 sprite box (in scaled crop, 64*2.5=160 px)
draw.rectangle([mx-80, my-80, mx+80, my+80], outline="magenta", width=1)
if golds:
    gxs, gys = to_crop(gx, gy)
    draw.ellipse([gxs-6, gys-6, gxs+6, gys+6], outline="lime", width=2)
crop.save(os.path.join(PROJECT, "_kz_zoom.png"))
print("saved _kz_zoom.png")
