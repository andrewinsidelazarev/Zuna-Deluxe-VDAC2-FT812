#!/usr/bin/env python3
"""sim_tongue_only.py — animated GIF: только tongue sprite, rotates вокруг
центра canvas.  Проверяем какая формула rotation корректна — tongue tip
должен указывать в направлении cursor (зелёная линия).
"""
import os, math
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')

sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')
tongue_full = sheet.crop((162, 0, 324, 162))
alpha = tongue_full.split()[3]
bbox = alpha.getbbox()
PAD = 4
x0 = max(0, bbox[0] - PAD); y0 = max(0, bbox[1] - PAD)
x1 = min(162, bbox[2] + PAD); y1 = min(162, bbox[3] + PAD)
TW, TH = 32, 80
tongue = tongue_full.crop((x0, y0, x1, y1)).resize((TW, TH), Image.LANCZOS)

CW = 360
CENTRE = CW // 2

# Pivot at sprite centre (16, 40) = bbox centre.
PIVOT = (16, 40)

# Test 4 formulas; whichever has tip ALWAYS along green line is correct.
FORMULAS = [
    ('A: rot = deg - 90',        lambda d: d - 90),
    ('B: rot = -(deg + 90)',     lambda d: -(d + 90)),
    ('C: rot = 90 - deg',        lambda d: 90 - d),
    ('D: rot = -(deg - 90)',     lambda d: -(d - 90)),
]

try:
    font = ImageFont.truetype("arial.ttf", 14)
except:
    font = ImageFont.load_default()


def render_frame(angle_deg, formula_label, formula_fn):
    img = Image.new('RGBA', (CW, CW), (40, 40, 50, 255))
    draw = ImageDraw.Draw(img)
    # Cardinal lines
    draw.line([(0, CENTRE), (CW, CENTRE)], fill=(70, 70, 80, 255), width=1)
    draw.line([(CENTRE, 0), (CENTRE, CW)], fill=(70, 70, 80, 255), width=1)
    # Cardinals labels
    draw.text((CW-30, CENTRE-15), 'E', fill=(150, 150, 160, 255), font=font)
    draw.text((10, CENTRE-15),    'W', fill=(150, 150, 160, 255), font=font)
    draw.text((CENTRE+5, 10),     'N (Y-)', fill=(150, 150, 160, 255), font=font)
    draw.text((CENTRE+5, CW-25),  'S (Y+)', fill=(150, 150, 160, 255), font=font)

    # Cursor direction (green)
    angle_rad = math.radians(angle_deg)
    cx = CENTRE + 140 * math.cos(angle_rad)
    cy = CENTRE + 140 * math.sin(angle_rad)
    draw.line([(CENTRE, CENTRE), (cx, cy)], fill=(0, 255, 100, 255), width=3)
    draw.ellipse([cx-6, cy-6, cx+6, cy+6], fill=(0, 255, 100, 255))

    rot_deg = formula_fn(angle_deg)
    tongue_rot = tongue.rotate(rot_deg, resample=Image.BILINEAR,
                                center=PIVOT, expand=True)
    rw, rh = tongue_rot.size
    img.alpha_composite(tongue_rot, (CENTRE - rw // 2, CENTRE - rh // 2))

    # Pivot mark (red)
    draw.ellipse([CENTRE-6, CENTRE-6, CENTRE+6, CENTRE+6],
                 outline=(255, 0, 0, 255), width=2)
    draw.line([(CENTRE-9, CENTRE), (CENTRE+9, CENTRE)], fill=(255, 0, 0, 255), width=1)
    draw.line([(CENTRE, CENTRE-9), (CENTRE, CENTRE+9)], fill=(255, 0, 0, 255), width=1)

    # Title bar
    draw.rectangle([(0, 0), (CW, 25)], fill=(20, 20, 30, 255))
    draw.text((6, 4), formula_label, fill=(255, 255, 255, 255), font=font)
    draw.text((CW - 70, 4), f'{angle_deg}°', fill=(0, 255, 100, 255), font=font)
    return img


# 4 формулы × 8 углов: grid + animated GIF
N_ANGLES = 8
angles = [i * 360 // N_ANGLES for i in range(N_ANGLES)]

# Сохраню grid (4 строк формул × 8 столбцов углов).
cell = CW // 2  # downscale half for grid
grid = Image.new('RGBA', (cell * N_ANGLES, cell * len(FORMULAS)), (255,)*4)
for fi, (lbl, fn) in enumerate(FORMULAS):
    for ai, ang in enumerate(angles):
        f = render_frame(ang, lbl, fn).resize((cell, cell), Image.LANCZOS)
        grid.paste(f, (ai * cell, fi * cell))
grid_path = os.path.join(HERE, '_tongue_only_grid.png')
grid.save(grid_path)
print(f'Saved {grid_path}')

# Animated GIF for first formula (A) — пользователь меняет в коде если хочет.
gif_frames = []
for ang in range(0, 360, 15):
    for fi, (lbl, fn) in enumerate(FORMULAS):
        # actually, do a 4-formula side-by-side per angle
        pass
    # actually simpler: just A formula, smooth rotation
    f = render_frame(ang, FORMULAS[0][0], FORMULAS[0][1])
    gif_frames.append(f.convert('RGB'))
gif_path = os.path.join(HERE, '_tongue_only_anim.gif')
gif_frames[0].save(gif_path, save_all=True, append_images=gif_frames[1:],
                   duration=80, loop=0)
print(f'Saved {gif_path}')
