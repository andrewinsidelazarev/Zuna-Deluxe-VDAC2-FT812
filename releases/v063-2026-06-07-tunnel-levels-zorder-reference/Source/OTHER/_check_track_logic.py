"""One-shot sanity check: rebuild track for level 01 (spiral) and 02 (claw)
from Graphics/levels/<NN-name>/<name>.dat using the same logic as
make_track_640.py, then byte-compare against the committed reference files
(track_640.bin / track_l02_640.bin)."""
import hashlib
import math
import os
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LEVELS_DIR = ROOT / 'Graphics' / 'levels'
CONVERTED = ROOT / 'Graphics' / 'Converted'

STEP = 1.0
WINDOW = 8
SMOOTH_WINDOW = 5


def parse_dat(path: Path):
    data = path.read_bytes()
    o = 0x10
    count1 = struct.unpack_from('<i', data, o)[0]
    o += 4 + count1 * 10
    curve_len = struct.unpack_from('<i', data, o)[0]
    o += 4
    x = struct.unpack_from('<f', data, o)[0]; o += 4
    y = struct.unpack_from('<f', data, o)[0]; o += 4
    pts = [(x, y)]
    for _ in range(curve_len):
        if o + 4 > len(data):
            break
        dx = struct.unpack_from('<b', data, o + 2)[0]
        dy = struct.unpack_from('<b', data, o + 3)[0]
        o += 4
        x += dx / 100.0
        y += dy / 100.0
        pts.append((x, y))
    return pts


def smooth_tangents_wrap(values, window=SMOOTH_WINDOW):
    if window <= 1 or not values:
        return values[:]
    half = window // 2
    unwrapped = [float(values[0])]
    for v in values[1:]:
        prev = unwrapped[-1]
        c = float(v)
        while c - prev > 128.0:
            c -= 256.0
        while c - prev < -128.0:
            c += 256.0
        unwrapped.append(c)
    out = []
    n = len(unwrapped)
    for i in range(n):
        lo = max(0, i - half)
        hi = min(n, i + half + 1)
        avg = sum(unwrapped[lo:hi]) / (hi - lo)
        out.append(int(round(avg)) & 0xFF)
    return out


def build_track(dat_path: Path) -> bytes:
    raw = parse_dat(dat_path)
    cum = [0.0]
    for i in range(1, len(raw)):
        dx = raw[i][0] - raw[i-1][0]
        dy = raw[i][1] - raw[i-1][1]
        cum.append(cum[-1] + math.hypot(dx, dy))
    total = cum[-1]
    n_out = int(total / STEP) + 1
    points = []
    src_i = 0
    for k in range(n_out):
        target = k * STEP
        while src_i < len(raw) - 2 and cum[src_i + 1] < target:
            src_i += 1
        seg = cum[src_i + 1] - cum[src_i]
        t = (target - cum[src_i]) / seg if seg > 0 else 0.0
        x = raw[src_i][0] + t * (raw[src_i + 1][0] - raw[src_i][0])
        y = raw[src_i][1] + t * (raw[src_i + 1][1] - raw[src_i][1])
        points.append((int(round(x)), int(round(y))))

    n = len(points)
    tans = []
    for i in range(n):
        j = max(0, i - WINDOW)
        k = min(n - 1, i + WINDOW)
        dx = points[k][0] - points[j][0]
        dy = points[k][1] - points[j][1]
        if dx == 0 and dy == 0:
            a8 = 0
        else:
            a = math.atan2(dy, dx)
            a8 = int(round((a / (2 * math.pi)) * 256)) & 0xFF
        tans.append(a8)
    tans = smooth_tangents_wrap(tans)

    out = bytearray()
    out += struct.pack('<H', n)
    for (x, y), tan in zip(points, tans):
        out += struct.pack('<hhB', x, y, tan)
    return bytes(out)


def check(label, dat_path: Path, ref_path: Path):
    new_bytes = build_track(dat_path)
    ref_bytes = ref_path.read_bytes()
    new_hash = hashlib.sha256(new_bytes).hexdigest()[:16]
    ref_hash = hashlib.sha256(ref_bytes).hexdigest()[:16]
    match = new_bytes == ref_bytes
    n_new = struct.unpack_from('<H', new_bytes, 0)[0]
    n_ref = struct.unpack_from('<H', ref_bytes, 0)[0]
    print(f"=== {label} ===")
    print(f"  dat:    {dat_path}")
    print(f"  ref:    {ref_path}")
    print(f"  new:    {len(new_bytes)} bytes, samples={n_new}, sha256[16]={new_hash}")
    print(f"  ref:    {len(ref_bytes)} bytes, samples={n_ref}, sha256[16]={ref_hash}")
    print(f"  match:  {'YES' if match else 'NO'}")
    if not match:
        # Show first diff
        m = min(len(new_bytes), len(ref_bytes))
        for i in range(m):
            if new_bytes[i] != ref_bytes[i]:
                print(f"  first diff at byte {i}: new={new_bytes[i]:#x} ref={ref_bytes[i]:#x}")
                break
        if len(new_bytes) != len(ref_bytes):
            print(f"  length differs: new={len(new_bytes)} ref={len(ref_bytes)}")
    print()
    return match


m1 = check("level 01 (spiral) vs track_640.bin",
           LEVELS_DIR / '01-spiral' / 'spiral.dat',
           CONVERTED / 'track_640.bin')
m2 = check("level 02 (claw) vs track_l02_640.bin",
           LEVELS_DIR / '02-claw' / 'claw.dat',
           CONVERTED / 'track_l02_640.bin')

sys.exit(0 if (m1 and m2) else 1)
