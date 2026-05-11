#!/usr/bin/env python3
"""sim_tongue_rotation.py — визуальная симуляция: tongue rotates around
frog centre.  12 frames с cursor angle 0..330° (шаг 30°).  Tongue pivot =
base of stripe, anchor placed at frog centre (без orbit offset).
"""
import os, math
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')
sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')

W = 122
body = sheet.crop((0, 0, 162, 162)).resize((W, W), Image.LANCZOS)
plate = sheet.crop((162, 162, 324, 324)).resize((W, W), Image.LANCZOS)
overlay = sheet.crop((0, 162, 162, 324)).resize((W, W), Image.LANCZOS)

tongue_full = sheet.crop((162, 0, 324, 162))
alpha = tongue_full.split()[3]
bbox = alpha.getbbox()
PAD = 4
x0 = max(0, bbox[0] - PAD); y0 = max(0, bbox[1] - PAD)
x1 = min(162, bbox[2] + PAD); y1 = min(162, bbox[3] + PAD)
TW, TH = 32, 80
tongue_tight = tongue_full.crop((x0, y0, x1, y1)).resize((TW, TH), Image.LANCZOS)


def render_frame(canvas_w, frog_pos, cursor_angle, anchor_uv):
    """Render frog body+tongue+overlay при заданном cursor angle.
    Tongue rotates around frog centre (no orbit offset).
    Layer order: plate -> body -> tongue -> overlay (HD).
    """
    img = Image.new('RGBA', (canvas_w, canvas_w), (210, 210, 210, 255))
    fx, fy = frog_pos

    # plate
    plate_pos = (fx - W//2, fy - W//2)
    img.paste(plate, plate_pos, plate)

    # body — face cursor (eyes north native, rotate by angle+90 CCW so eyes point at cursor).
    body_rotated = body.rotate(-(math.degrees(cursor_angle) + 90),
                               resample=Image.BILINEAR, expand=False)
    img.paste(body_rotated, plate_pos, body_rotated)

    # tongue — anchor at base (16, 6 in tight), placed at frog centre, rotate same as body.
    tongue_rotated = tongue_tight.rotate(-(math.degrees(cursor_angle) + 90),
                                          resample=Image.BILINEAR,
                                          center=anchor_uv, expand=True)
    rw, rh = tongue_rotated.size
    # PIL expand=True centers original anchor at new bbox centre.
    tx = fx - rw // 2
    ty = fy - rh // 2
    img.paste(tongue_rotated, (int(tx), int(ty)), tongue_rotated)

    # face overlay (HD blink frame 0) — same rotation as body.
    overlay_rotated = overlay.rotate(-(math.degrees(cursor_angle) + 90),
                                      resample=Image.BILINEAR, expand=False)
    img.paste(overlay_rotated, plate_pos, overlay_rotated)

    # markers
    draw = ImageDraw.Draw(img)
    # frog centre + rotation centre (совпадают) — red ring
    draw.ellipse([(fx-8, fy-8), (fx+8, fy+8)], outline=(255, 0, 0, 255), width=2)
    # cursor direction line
    cx = fx + 90 * math.cos(cursor_angle)
    cy = fy + 90 * math.sin(cursor_angle)
    draw.line([(fx, fy), (cx, cy)], fill=(0, 200, 0, 255), width=2)
    # angle label
    try:
        font = ImageFont.truetype("arial.ttf", 12)
    except:
        font = ImageFont.load_default()
    draw.text((4, 4), f'{int(math.degrees(cursor_angle))} deg', fill=(0, 0, 0, 255), font=font)
    return img


CW = 280
N = 8
frames = []
for i in range(N):
    ang = i * 2 * math.pi / N
    f = render_frame(CW, (CW//2, CW//2), ang, anchor_uv=(16, 6))
    frames.append(f)

# Grid 4x2
cols, rows = 4, 2
grid = Image.new('RGBA', (CW * cols, CW * rows + 30), (255, 255, 255, 255))
draw = ImageDraw.Draw(grid)
try:
    font = ImageFont.truetype("arial.ttf", 14)
except:
    font = ImageFont.load_default()
draw.text((4, 6), "Tongue rotates around frog centre (red ring) — pivot=base, offset=0",
          fill=(0, 0, 0, 255), font=font)
for i, f in enumerate(frames):
    x = (i % cols) * CW
    y = 30 + (i // cols) * CW
    grid.paste(f, (x, y))
grid.save(os.path.join(HERE, '_tongue_rotation_sim.png'))
print('Saved _tongue_rotation_sim.png')

# Animated GIF for easier viewing
gif_frames = [f.convert('RGB') for f in frames]
gif_path = os.path.join(HERE, '_tongue_rotation_sim.gif')
gif_frames[0].save(gif_path, save_all=True, append_images=gif_frames[1:],
                   duration=200, loop=0)
print(f'Saved {gif_path}')
