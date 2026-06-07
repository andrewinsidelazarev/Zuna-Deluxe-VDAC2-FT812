"""Рисует отладочное изображение: оверлей loopy.png + позиции шаров по флагам."""
import struct
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent.parent
SRC = Path.home() / "Desktop" / "Zuma-Deluxe-HD-release-v010-ref" / "content" / "levels" / "loopy" / "loopy.png"
TRACK = ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l11_640.bin"
OUT = ROOT / "Source" / "OTHER" / "debug_l11_overlay_check.png"

NATIVE = (640, 480)

# Загружаем и масштабируем оверлей
overlay = Image.open(SRC).convert("RGBA").resize(NATIVE, Image.Resampling.LANCZOS)

# Трек
data = TRACK.read_bytes()
count = struct.unpack_from("<H", data, 0)[0]
BASE = 2; S = 6
tunnel, above_, neither_, both_ = [], [], [], []
for i in range(count):
    x, y, t, flags = struct.unpack_from("<hhBB", data, BASE + i * S)
    if flags == 0x00:
        neither_.append((x, y))
    elif flags == 0x01:
        tunnel.append((x, y))
    elif flags == 0x02:
        above_.append((x, y))
    else:
        both_.append((x, y))

# Композит: серый фон + оверлей с 50% прозрачностью + точки по флагам
bg = Image.new("RGBA", NATIVE, (80, 80, 80, 255))
# Оверлей поверх серого
overlay_half = overlay.copy()
overlay_arr = np.array(overlay_half)
overlay_arr[:, :, 3] = (overlay_arr[:, :, 3].astype(np.uint16) * 180 // 255).astype(np.uint8)
overlay_half = Image.fromarray(overlay_arr)
bg.alpha_composite(overlay_half)
draw = ImageDraw.Draw(bg)

def clamp(x, y):
    return max(0, min(639, x)), max(0, min(479, y))

R = 2
# NEITHER = желтые
for x, y in neither_:
    cx, cy = clamp(x, y)
    draw.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(255, 255, 0, 220))
# TUNNEL = красные
for x, y in tunnel:
    cx, cy = clamp(x, y)
    draw.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(255, 0, 0, 220))
# Первые 30 ABOVE_ (начало цепи, хвост) = синие
for x, y in above_[:30]:
    cx, cy = clamp(x, y)
    draw.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(0, 120, 255, 220))
# Последние 30 ABOVE_ (около KZ) = зеленые
for x, y in above_[-30:]:
    cx, cy = clamp(x, y)
    draw.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(0, 255, 80, 220))

# Текущая bbox overlay из метаданных
OX, OY, OW, OH = 259, 252, 160, 177
draw.rectangle([OX, OY, OX+OW, OY+OH], outline=(255, 255, 255, 200), width=2)

# Конвертируем в RGB для сохранения
bg_rgb = bg.convert("RGB")
bg_rgb.save(OUT)
print(f"Saved: {OUT}")
print(f"Tunnel={len(tunnel)} Neither={len(neither_)} Above={len(above_)}")
print(f"Current overlay bbox: X={OX}..{OX+OW} Y={OY}..{OY+OH}")
