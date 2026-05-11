#!/usr/bin/env python3
"""sim_tongue_pivot.py — Python-симуляция rotation tongue для разных anchor.

Проблема: tongue визуально крутится не вокруг центра frog body, а вокруг
точки слева от tongue.  Нужно подобрать anchor (UV pivot) в sprite frame
+ offset в формуле `pos + tongueExpand·dir` так, чтобы:
  • Rotation centre на screen = центр frog body.
  • Tongue base "у рта" frog (близко к телу), tip торчит наружу.

Скрипт прогоняет 8 кадров с cursor вращающимся вокруг frog и показывает
4 варианта anchor placement.
"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')

# Подгружаю native sprites (122x122 после resize HD 162→122).
sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')

W = 122
body = sheet.crop((0, 0, 162, 162)).resize((W, W), Image.LANCZOS)
plate = sheet.crop((162, 162, 324, 324)).resize((W, W), Image.LANCZOS)

# Tongue tight crop как в make_misc_sprites.py (bbox + 4 px pad → 32x80).
tongue_full = sheet.crop((162, 0, 324, 162))
alpha = tongue_full.split()[3]
bbox = alpha.getbbox()
PAD = 4
x0 = max(0, bbox[0] - PAD)
y0 = max(0, bbox[1] - PAD)
x1 = min(162, bbox[2] + PAD)
y1 = min(162, bbox[3] + PAD)
TW, TH = 32, 80
tongue_tight = tongue_full.crop((x0, y0, x1, y1)).resize((TW, TH), Image.LANCZOS)

# Native sprite centre HD (81, 81) в bbox-rel + tight координатах:
hd_anchor_bbox = (81 - x0, 81 - y0)
sx, sy = TW / (x1 - x0), TH / (y1 - y0)
hd_anchor_tight = (hd_anchor_bbox[0] * sx, hd_anchor_bbox[1] * sy)
print(f'HD anchor in native: (81, 81)')
print(f'HD anchor in tight {TW}x{TH}: ({hd_anchor_tight[0]:.1f}, {hd_anchor_tight[1]:.1f})')
# Stripe boundaries in tight frame
base_y_native = bbox[1]      # top of opaque (tongue base, attaches к рту)
tip_y_native = bbox[3]       # bottom of opaque (tip)
print(f'Native opaque bbox: x[{bbox[0]}..{bbox[2]}], y[{base_y_native}..{tip_y_native}]')
base_tight_y = (base_y_native - y0) * sy
tip_tight_y = (tip_y_native - y0) * sy
print(f'In tight: base y={base_tight_y:.1f}, tip y={tip_tight_y:.1f}')


def draw_frog_with_tongue(canvas_size, frog_pos, cursor_angle, anchor_uv, anchor_offset_screen):
    """Render frog + tongue для одного угла.
    anchor_uv: (x, y) в sprite frame, точка вращения.
    anchor_offset_screen: (dx, dy) где dx, dy = смещение anchor от frog_pos в screen.
                          (e.g., (24*cos, 24*sin) для HD-style orbit, или (0, 0) для rotation вокруг frog).
    """
    img = Image.new('RGBA', canvas_size, (200, 200, 200, 255))
    fx, fy = frog_pos

    # plate
    plate_pos = (fx - W // 2, fy - W // 2)
    img.paste(plate, plate_pos, plate)

    # body — rotate by (angle - 90°) so eyes face cursor.
    # native eyes at top of sprite (y=20-50), face direction = north visually.
    # To face cursor at angle (atan2 with screen Y-down), rotate by ?
    body_rot_deg = math.degrees(cursor_angle) + 90  # empirical: for cursor east (0), need 90° to put eyes east
    body_rotated = body.rotate(-body_rot_deg, resample=Image.BILINEAR, expand=False)
    img.paste(body_rotated, plate_pos, body_rotated)

    # tongue — rotate same as body but native = south.
    tongue_rot_deg = math.degrees(cursor_angle) + 90
    tongue_rotated = tongue_tight.rotate(-tongue_rot_deg, resample=Image.BILINEAR,
                                          center=anchor_uv, expand=True)
    # After rotate-expand, anchor moves to centre of rotated bbox? PIL rotate with expand=True
    # places original anchor at centre of new bbox.
    rw, rh = tongue_rotated.size
    # Anchor on rotated sprite is at its centre (expand=True).
    anchor_in_rotated = (rw // 2, rh // 2)
    # Place rotated tongue so anchor lands at (fx + dx, fy + dy).
    ax = fx + anchor_offset_screen[0] - anchor_in_rotated[0]
    ay = fy + anchor_offset_screen[1] - anchor_in_rotated[1]
    img.paste(tongue_rotated, (int(ax), int(ay)), tongue_rotated)

    # Draw markers
    draw = ImageDraw.Draw(img)
    # frog centre — red cross
    draw.line([(fx-8, fy), (fx+8, fy)], fill=(255, 0, 0, 255), width=2)
    draw.line([(fx, fy-8), (fx, fy+8)], fill=(255, 0, 0, 255), width=2)
    # rotation centre / anchor on screen — yellow cross
    rax = fx + anchor_offset_screen[0]
    ray = fy + anchor_offset_screen[1]
    draw.line([(rax-6, ray), (rax+6, ray)], fill=(255, 220, 0, 255), width=2)
    draw.line([(rax, ray-6), (rax, ray+6)], fill=(255, 220, 0, 255), width=2)
    # cursor direction — line from frog to angle
    cx = fx + 80 * math.cos(cursor_angle)
    cy = fy + 80 * math.sin(cursor_angle)
    draw.line([(fx, fy), (cx, cy)], fill=(0, 100, 0, 200), width=1)

    return img


def make_grid(label, anchor_uv, offset_fn):
    """Сгенерить 8-frame grid для one configuration.
    offset_fn: cursor_angle → (dx, dy) screen offset of anchor from frog centre.
    """
    angles = [i * math.pi / 4 for i in range(8)]   # E, SE, S, SW, W, NW, N, NE
    cells = []
    for ang in angles:
        cells.append(draw_frog_with_tongue((180, 180), (90, 90), ang, anchor_uv, offset_fn(ang)))
    cols = 4
    rows = 2
    grid = Image.new('RGBA', (180 * cols, 180 * rows + 30), (255, 255, 255, 255))
    draw = ImageDraw.Draw(grid)
    draw.text((4, 4), label, fill=(0, 0, 0, 255))
    for i, c in enumerate(cells):
        x = (i % cols) * 180
        y = 30 + (i // cols) * 180
        grid.paste(c, (x, y))
    return grid


# Configuration 1 (CURRENT after my last fix):
# UV pivot = (16, 6) (base of stripe in tight). Anchor placed at frog + 24·dir.
cfg1 = make_grid(
    "1: pivot=(16,6) base, offset=24*dir (HD orbit)",
    (16, 6),
    lambda ang: (24 * math.cos(ang), 24 * math.sin(ang)),
)

# Configuration 2: pivot=(16, 29) HD sprite centre, offset=24*dir (HD-EXACT).
cfg2 = make_grid(
    "2: pivot=(16,29) HD centre, offset=24*dir",
    (16, 29),
    lambda ang: (24 * math.cos(ang), 24 * math.sin(ang)),
)

# Configuration 3: pivot=(16, 40) bbox centre, offset=24*dir (my old version).
cfg3 = make_grid(
    "3: pivot=(16,40) bbox centre, offset=24*dir",
    (16, 40),
    lambda ang: (24 * math.cos(ang), 24 * math.sin(ang)),
)

# Configuration 4: pivot=(16, 6) base, offset=0 (rotation вокруг frog centre).
cfg4 = make_grid(
    "4: pivot=(16,6) base, offset=0 (вокруг frog centre)",
    (16, 6),
    lambda ang: (0, 0),
)

# Stack all configs vertically.
out = Image.new('RGBA', (180 * 4, (180 * 2 + 30) * 4 + 20), (240, 240, 240, 255))
out.paste(cfg1, (0, 0))
out.paste(cfg2, (0, 180 * 2 + 30))
out.paste(cfg3, (0, (180 * 2 + 30) * 2))
out.paste(cfg4, (0, (180 * 2 + 30) * 3))
out_path = os.path.join(HERE, '_tongue_sim.png')
out.save(out_path)
print(f'\nSaved: {out_path}')
