"""Visualize track endpoint vs bg crater + show where DrawKillzoneDual draws skull."""
from PIL import Image, ImageDraw
import struct, os

PROJECT = os.path.dirname(os.path.abspath(__file__))
LEVELS = os.path.expanduser("~") + r"\Desktop\Zuma Deluxe\graphics\levels"

with open(os.path.join(PROJECT, "Graphics", "Converted", "track_640.bin"), "rb") as f:
    data = f.read()
n = struct.unpack_from("<H", data, 0)[0]
pts = []
for i in range(n):
    x, y, t = struct.unpack_from("<hhB", data, 2 + i * 5)
    pts.append((x, y, t))

xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
print(f"N={n}")
print(f"X range [{min(xs)}..{max(xs)}], Y range [{min(ys)}..{max(ys)}]")
print(f"first 3: {pts[:3]}")
print(f"last 3:  {pts[-3:]}")
print(f"kill-zone (last sample): X={pts[-1][0]} Y={pts[-1][1]}")

# Frog default from Frog.asm
FROG_X, FROG_Y = 327, 231
print(f"FROG_DEFAULT (Frog.asm): X={FROG_X} Y={FROG_Y}")

# Show 5 last samples to see if it's really the spiral inner end
print("Last 10 samples:")
for p in pts[-10:]:
    print(f"  X={p[0]} Y={p[1]} tan={p[2]}")

bg = Image.open(os.path.join(LEVELS, "level_src_01.png")).convert("RGB")
print(f"bg size: {bg.size}")
draw = ImageDraw.Draw(bg)

# Draw whole track in red (every sample)
for x, y, t in pts:
    if 0 <= x < bg.width and 0 <= y < bg.height:
        draw.point((x, y), fill="red")

# Mark first (green) and last (magenta with 64x64 box = killzone overlay area)
fx, fy = pts[0][:2]
draw.ellipse([fx-6, fy-6, fx+6, fy+6], outline="lime", width=2)
lx, ly = pts[-1][:2]
draw.ellipse([lx-4, ly-4, lx+4, ly+4], fill="magenta")
draw.rectangle([lx-32, ly-32, lx+32, ly+32], outline="magenta", width=2)

# Mark frog position (yellow)
draw.ellipse([FROG_X-4, FROG_Y-4, FROG_X+4, FROG_Y+4], fill="yellow")
draw.rectangle([FROG_X-61, FROG_Y-61, FROG_X+61, FROG_Y+61], outline="yellow", width=1)

bg.save(os.path.join(PROJECT, "_track_overlay.png"))
print("saved _track_overlay.png")
print()
print(f"distance frog->kz: dx={lx-FROG_X} dy={ly-FROG_Y}")
