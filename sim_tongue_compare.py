#!/usr/bin/env python3
"""sim_tongue_compare.py — single-frame side-by-side 4-конфигурации tongue.
Показывает rotation centre (yellow cross) vs frog centre (red cross).
"""
import os, math
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')
sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')

W = 122
body = sheet.crop((0, 0, 162, 162)).resize((W, W), Image.LANCZOS)
plate = sheet.crop((162, 162, 324, 324)).resize((W, W), Image.LANCZOS)

tongue_full = sheet.crop((162, 0, 324, 162))
alpha = tongue_full.split()[3]
bbox = alpha.getbbox()
PAD = 4
x0 = max(0, bbox[0] - PAD); y0 = max(0, bbox[1] - PAD)
x1 = min(162, bbox[2] + PAD); y1 = min(162, bbox[3] + PAD)
TW, TH = 32, 80
tongue_tight = tongue_full.crop((x0, y0, x1, y1)).resize((TW, TH), Image.LANCZOS)


def render(canvas_w, frog_pos, cursor_angle, anchor_uv, anchor_offset):
    img = Image.new('RGBA', (canvas_w, canvas_w), (210, 210, 210, 255))
    fx, fy = frog_pos
    plate_pos = (fx - W//2, fy - W//2)
    img.paste(plate, plate_pos, plate)
    body_rotated = body.rotate(-(math.degrees(cursor_angle) + 90),
                               resample=Image.BILINEAR, expand=False)
    img.paste(body_rotated, plate_pos, body_rotated)

    tongue_rotated = tongue_tight.rotate(-(math.degrees(cursor_angle) + 90),
                                          resample=Image.BILINEAR,
                                          center=anchor_uv, expand=True)
    rw, rh = tongue_rotated.size
    ax = fx + anchor_offset[0] - rw // 2
    ay = fy + anchor_offset[1] - rh // 2
    img.paste(tongue_rotated, (int(ax), int(ay)), tongue_rotated)

    draw = ImageDraw.Draw(img)
    draw.line([(fx-10, fy), (fx+10, fy)], fill=(255, 0, 0, 255), width=3)
    draw.line([(fx, fy-10), (fx, fy+10)], fill=(255, 0, 0, 255), width=3)
    rax = fx + anchor_offset[0]; ray = fy + anchor_offset[1]
    draw.ellipse([(rax-7, ray-7), (rax+7, ray+7)], outline=(255, 220, 0, 255), width=2)
    cx = fx + 90 * math.cos(cursor_angle); cy = fy + 90 * math.sin(cursor_angle)
    draw.line([(fx, fy), (cx, cy)], fill=(0, 100, 0, 255), width=1)
    return img


def labeled(img, label):
    out = Image.new('RGBA', (img.width, img.height + 38), (255, 255, 255, 255))
    out.paste(img, (0, 38))
    d = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype("arial.ttf", 14)
    except:
        font = ImageFont.load_default()
    for i, line in enumerate(label.split('\n')):
        d.text((4, 4 + i*16), line, fill=(0, 0, 0, 255), font=font)
    return out


CW = 200
ang = 0.0  # cursor east

cfg1 = labeled(render(CW, (CW//2, CW//2), ang, (16, 6),  (24*math.cos(ang), 24*math.sin(ang))),
               "1: pivot=(16,6) base\noffset=24*dir (CURRENT)")
cfg2 = labeled(render(CW, (CW//2, CW//2), ang, (16, 29), (24*math.cos(ang), 24*math.sin(ang))),
               "2: pivot=(16,29) HD\noffset=24*dir")
cfg3 = labeled(render(CW, (CW//2, CW//2), ang, (16, 6),  (0, 0)),
               "4: pivot=(16,6) base\noffset=0 (around frog)")
cfg4 = labeled(render(CW, (CW//2, CW//2), ang, (16, 6),  (0, 12)),
               "5: pivot=(16,6) base\noffset=(0,+12) below")

out = Image.new('RGBA', (CW * 4, CW + 38), (255, 255, 255, 255))
out.paste(cfg1, (CW * 0, 0))
out.paste(cfg2, (CW * 1, 0))
out.paste(cfg3, (CW * 2, 0))
out.paste(cfg4, (CW * 3, 0))
out.save(os.path.join(HERE, '_tongue_sim_compare.png'))
print('Saved _tongue_sim_compare.png')
