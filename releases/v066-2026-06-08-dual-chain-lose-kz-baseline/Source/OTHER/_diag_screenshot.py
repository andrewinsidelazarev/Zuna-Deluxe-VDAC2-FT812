"""Find inner game viewport in screenshot and map to 640x480 game coords precisely."""
from PIL import Image, ImageDraw
import os

PROJECT = os.path.dirname(os.path.abspath(__file__))
shot = Image.open(os.path.join(PROJECT, "Безымянный.png")).convert("RGB")
W, H = shot.size
print(f"screenshot: {W}x{H}")
px = shot.load()

# Find non-white inner viewport — find topmost and leftmost row/col with significant non-white pixels
def is_nonwhite(r, g, b):
    return not (r > 230 and g > 230 and b > 230)

# Top edge: scan from top, find first row with >100 non-white pixels (skip title bar)
top = 0
for y in range(H):
    cnt = sum(1 for x in range(W) if is_nonwhite(*px[x, y]))
    if cnt > W * 0.3:
        top = y
        break
print(f"top edge of game viewport: y={top}")

# Bottom: scan from bottom
bot = H - 1
for y in range(H-1, -1, -1):
    cnt = sum(1 for x in range(W) if is_nonwhite(*px[x, y]))
    if cnt > W * 0.3:
        bot = y
        break
print(f"bottom edge: y={bot}")

# Left: scan within [top..bot]
left = 0
for x in range(W):
    cnt = sum(1 for y in range(top, bot+1) if is_nonwhite(*px[x, y]))
    if cnt > (bot-top) * 0.5:
        left = x
        break
print(f"left edge: x={left}")

# Right
right = W - 1
for x in range(W-1, -1, -1):
    cnt = sum(1 for y in range(top, bot+1) if is_nonwhite(*px[x, y]))
    if cnt > (bot-top) * 0.5:
        right = x
        break
print(f"right edge: x={right}")

print(f"\nInner game viewport: ({left},{top}) — ({right},{bot}) size {right-left+1}x{bot-top+1}")
print(f"Expected aspect 640/480={640/480:.3f}, actual: {(right-left+1)/(bot-top+1):.3f}")

def game_to_shot(gx, gy):
    sx = left + gx * (right - left) / 640
    sy = top + gy * (bot - top) / 480
    return sx, sy

# Mark expected kill-zone (208, 217) in screenshot
big = shot.copy()
draw = ImageDraw.Draw(big)
ex, ey = game_to_shot(208, 217)
draw.ellipse([ex-3, ey-3, ex+3, ey+3], fill="red")
# 64x64 box
hw = 32 * (right - left) / 640
draw.rectangle([ex-hw, ey-hw, ex+hw, ey+hw], outline="red", width=2)

# Mark frog (327, 231)
fx, fy = game_to_shot(327, 231)
draw.ellipse([fx-3, fy-3, fx+3, fy+3], fill="yellow")

# Mark track endpoint (211, 217)
tx, ty = game_to_shot(211, 217)
draw.ellipse([tx-3, ty-3, tx+3, ty+3], fill="cyan")

# Find golden pixels inside viewport
golds_in = []
for y in range(top, bot+1):
    for x in range(left, right+1):
        r, g, b = px[x, y]
        if r > 200 and g > 140 and b < 100:
            golds_in.append((x, y))
if golds_in:
    xs = [p[0] for p in golds_in]; ys = [p[1] for p in golds_in]
    print(f"Golden pixels in viewport: count={len(golds_in)}")
    print(f"  shot bbox: X[{min(xs)}..{max(xs)}] Y[{min(ys)}..{max(ys)}]")
    cx_s = (min(xs) + max(xs)) / 2
    cy_s = (min(ys) + max(ys)) / 2
    cx_g = (cx_s - left) * 640 / (right - left)
    cy_g = (cy_s - top) * 480 / (bot - top)
    print(f"  game-coord bbox center: ({cx_g:.1f}, {cy_g:.1f})")
    print(f"  expected (KZ_DEFAULT): (208, 217) — diff dx={cx_g-208:.1f} dy={cy_g-217:.1f}")
big.save(os.path.join(PROJECT, "_shot_annotated.png"))
print("saved _shot_annotated.png")
