#!/usr/bin/env python3
import argparse
from pathlib import Path


GAMELOG_ADDR = 0x4B80
GAMELOG_IDX_ADDR = 0x4C80
ENTRY_SIZE = 8
ENTRY_COUNT = (GAMELOG_IDX_ADDR - GAMELOG_ADDR) // ENTRY_SIZE

EVENTS = {
    1: "SHOT_FIRED",
    2: "BBOX_HIT",
    3: "HEMI",
    4: "INSERT",
    5: "CASCADE_TRIGGER",
    6: "MATCH3",
}


def u16le(data: bytes, off: int) -> int:
    return data[off] | (data[off + 1] << 8)


def decode_entry(data: bytes, n: int) -> str:
    off = GAMELOG_ADDR + n * ENTRY_SIZE
    typ = data[off]
    ctx = data[off + 1]
    frame = data[off + 2]
    d0 = data[off + 4]
    d1 = data[off + 5]
    d2 = data[off + 6]
    d3 = data[off + 7]
    name = EVENTS.get(typ, f"EVT_{typ:02X}")

    if typ == 1:
        sx = u16le(data, off + 4)
        sy = u16le(data, off + 6)
        detail = f"angle={ctx} smooth=({sx},{sy})"
    elif typ == 2:
        bx = u16le(data, off + 4)
        by = u16le(data, off + 6)
        detail = f"hit_idx={ctx} bullet=({bx},{by})"
    elif typ == 3:
        x = u16le(data, off + 4)
        y = u16le(data, off + 6)
        detail = f"target_idx={ctx} target_pos=({x},{y})"
    elif typ == 4:
        detail = f"idx={ctx} len={d0} hsa={d1} color={d2} hsub={d3}"
    elif typ == 5:
        detail = f"gap_idx={ctx} len={d0} hsa={d1} offset=0x{d2:02X} hsub={d3}"
    elif typ == 6:
        detail = f"color={ctx} lb={d0} rb={d1} count={d2} trigger_idx={d3}"
    else:
        detail = f"ctx={ctx} data={d0:02X} {d1:02X} {d2:02X} {d3:02X}"

    return f"{n:03d} frame_lo={frame:03d} {name}: {detail}"


def main() -> None:
    ap = argparse.ArgumentParser(description="Decode Zuma GAMELOG ring from a raw memory dump.")
    ap.add_argument("dump", type=Path, help="raw memory dump, for example 111")
    ap.add_argument("--all", action="store_true", help="print empty/unknown entries too")
    ap.add_argument("--tail", type=int, default=80, help="number of recent non-empty entries to print")
    args = ap.parse_args()

    data = args.dump.read_bytes()
    if len(data) <= GAMELOG_IDX_ADDR:
        raise SystemExit(f"dump too small: size={len(data)}")

    idx = data[GAMELOG_IDX_ADDR]
    if idx >= ENTRY_COUNT:
        idx = 0
    entries: list[tuple[int, int]] = []
    for i in range(ENTRY_COUNT):
        n = (idx + i) % ENTRY_COUNT
        off = GAMELOG_ADDR + n * ENTRY_SIZE
        typ = data[off]
        if args.all or typ in EVENTS:
            entries.append((n, typ))

    if not args.all:
        entries = entries[-args.tail :]

    print(f"write_idx={idx} entries={len(entries)} capacity={ENTRY_COUNT}")
    for n, _ in entries:
        print(decode_entry(data, n))


if __name__ == "__main__":
    main()
