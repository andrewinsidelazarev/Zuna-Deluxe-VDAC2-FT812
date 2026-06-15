"""Generate <NN-name>-4-3.dat in every Graphics/levels/<NN-name>/ folder.

For each <NN-name> folder, finds <name>*.dat track source and produces
4:3 (640x480) native resampled track using the same logic as
make_track_640.py:
  - parse CURV format (count1 + N×(t1,t2,dX,dY) with dX/100, dY/100)
  - resample arc-length at STEP=1.0 px (linear interp between HD samples)
  - tangent precompute with window=±8, smoothed by wrap-aware moving avg
    width=5
  - output: word LE N + N×(X word, Y word, tangent byte)

Multi-curve boards (blackswirley, serpents, snakepit) have <name>-1.dat /
<name>-2.dat and produce <NN-name>-1-4-3.dat / <NN-name>-2-4-3.dat.

Verified byte-for-byte against committed Graphics/Converted/track_640.bin
(spiral) and track_l02_640.bin (claw) by _check_track_logic.py.
"""
import math
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
LEVELS_DIR = ROOT / 'Graphics' / 'levels'

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


def build_track(dat_path: Path) -> tuple[bytes, int, int, int, int, int]:
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
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return bytes(out), n, min(xs), max(xs), min(ys), max(ys)


def board_name_from_dir(name: str) -> str:
    """'05-blackswirley' -> 'blackswirley'."""
    return name.split('-', 1)[1] if '-' in name else name


def out_name(folder_name: str, dat_filename: str) -> str:
    """Build output filename.
    folder='05-blackswirley', dat='blackswirley-1.dat' ->
        '05-blackswirley-1-4-3.dat'
    folder='02-claw', dat='claw.dat' -> '02-claw-4-3.dat'
    """
    board = board_name_from_dir(folder_name)
    stem = dat_filename[:-4]  # strip .dat
    if stem == board:
        suffix = ''
    elif stem.startswith(board + '-'):
        suffix = stem[len(board):]  # e.g. '-1', '-2'
    else:
        suffix = '-' + stem
    return f"{folder_name}{suffix}-4-3.dat"


def main() -> int:
    folders = sorted(p for p in LEVELS_DIR.iterdir() if p.is_dir())
    total_in = 0
    total_out = 0
    failed = []
    print(f"folders: {len(folders)}")
    for folder in folders:
        dats = sorted(folder.glob('*.dat'))
        # Skip already-generated -4-3 outputs on re-run
        dats = [d for d in dats if not d.stem.endswith('-4-3')]
        if not dats:
            print(f"  {folder.name}: no source .dat")
            continue
        for dat in dats:
            total_in += 1
            try:
                payload, n, xmin, xmax, ymin, ymax = build_track(dat)
            except Exception as exc:
                failed.append((dat, str(exc)))
                print(f"  {folder.name}/{dat.name}: FAILED — {exc}")
                continue
            out_path = folder / out_name(folder.name, dat.name)
            out_path.write_bytes(payload)
            total_out += 1
            print(f"  {folder.name}/{dat.name} -> {out_path.name}  "
                  f"samples={n}, bytes={len(payload)}, "
                  f"X=[{xmin}..{xmax}] Y=[{ymin}..{ymax}]")
    print()
    print(f"in={total_in}, out={total_out}, failed={len(failed)}")
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
