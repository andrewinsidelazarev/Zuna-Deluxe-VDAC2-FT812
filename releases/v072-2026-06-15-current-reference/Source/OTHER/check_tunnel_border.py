import struct
from pathlib import Path

data = Path("Graphics/levels/Converted/pack/track_l11_640.bin").read_bytes()
count = struct.unpack_from("<H", data, 0)[0]
BASE = 2
SAMPLE = 6
OX0, OY0, OX1, OY1 = 259, 252, 419, 429

def inside(x, y):
    return OX0 <= x < OX1 and OY0 <= y < OY1

print("--- 20 до TUNNEL (idx 2267..2286) ---")
for i in range(2267, 2287):
    x, y, tang, flags = struct.unpack_from("<hhBB", data, BASE + i * SAMPLE)
    label = "IN " if inside(x, y) else "out"
    print(f"  [{i}] x={x:4d} y={y:4d} f=0x{flags:02x}  {label}")

print("--- 20 после TUNNEL (idx 2471..2490) ---")
for i in range(2471, 2491):
    x, y, tang, flags = struct.unpack_from("<hhBB", data, BASE + i * SAMPLE)
    label = "IN " if inside(x, y) else "out"
    print(f"  [{i}] x={x:4d} y={y:4d} f=0x{flags:02x}  {label}")

# NEITHER samples: where do they sit?
neither = []
for i in range(count):
    x, y, tang, flags = struct.unpack_from("<hhBB", data, BASE + i * SAMPLE)
    if flags == 0:
        neither.append((i, x, y))
print(f"\nNEITHER total={len(neither)}")
print(f"NEITHER range: idx [{neither[0][0]}..{neither[-1][0]}]")
in_overlay = [(i, x, y) for i, x, y in neither if inside(x, y)]
print(f"NEITHER inside overlay: {len(in_overlay)}")
if in_overlay:
    print(f"  first 5: {in_overlay[:5]}")
    print(f"  last 5:  {in_overlay[-5:]}")
