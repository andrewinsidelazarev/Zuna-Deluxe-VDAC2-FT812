"""Crop and zoom into the suspicious top-left area to see what's drawn there."""
from PIL import Image
import os

PROJECT = os.path.dirname(os.path.abspath(__file__))
shot = Image.open(os.path.join(PROJECT, "Безымянный.png")).convert("RGB")
W, H = shot.size

# Top-left region of game viewport (top 1/3, left 1/3)
crop = shot.crop((0, 0, W//3, H//3))
crop = crop.resize((crop.width * 3, crop.height * 3), Image.LANCZOS)
crop.save(os.path.join(PROJECT, "_shot_topleft.png"))
print(f"saved _shot_topleft.png from {(0,0,W//3,H//3)}")

# Also crop center where bg sun should be
cx_s = int(208 / 640 * W)
cy_s = int(217 / 480 * H)
print(f"expected sun center in shot: ({cx_s}, {cy_s})")
crop2 = shot.crop((cx_s - 80, cy_s - 80, cx_s + 80, cy_s + 80))
crop2 = crop2.resize((crop2.width * 3, crop2.height * 3), Image.LANCZOS)
crop2.save(os.path.join(PROJECT, "_shot_center.png"))
print("saved _shot_center.png")
