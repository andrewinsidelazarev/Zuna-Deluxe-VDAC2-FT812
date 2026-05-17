#!/usr/bin/env python3
"""
parse_log_dump.py — читает F12-dump Unreal (flat 64KB) и парсит circular RAM log.

Usage:
    python parse_log_dump.py <dump_file>

Dump формат:
    64 KB flat Z80 address space (после Init_Core: slot1=page5, поэтому Z80
    addr == offset в файле для зон #4000..#7FFF).

GameLog layout (см. MainLoop.asm EQU секцию):
    GAMELOG_ADDR     = 0x4800  (2048 bytes, 256 entries × 8 bytes)
    GAMELOG_IDX_ADDR = 0x5000  (1 byte, write index 0..255)

Entry формат (8 bytes):
    +0 type    (1 byte)  ; 0=empty, 1=SHOT_FIRED, 2=BBOX_HIT, 3=HEMI, 4=INSERT, 5=CASCADE
    +1 ctx     (1 byte)  ; color / hit_idx / target_idx / ins_idx
    +2 frame   (1 byte)  ; FrameCounter low byte
    +3 _       (1 byte)  ; reserved
    +4..7      (4 bytes) ; d1 (word LE), d2 (word LE)
"""
import sys
import struct

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

GAMELOG_ADDR     = 0x4800
GAMELOG_IDX_ADDR = 0x5000

EVT_NAMES = {
    1: "SHOT_FIRED",
    2: "BBOX_HIT",
    3: "HEMI",
    4: "INSERT",
    5: "CASCADE",
}


def parse_dump(dump_bytes):
    idx = dump_bytes[GAMELOG_IDX_ADDR]
    print(f"GameLogIdx = {idx} (next write slot, oldest entry)")
    print(f"GameLog @  = 0x{GAMELOG_ADDR:04X}")
    print()

    entries = []
    # Read in order: oldest → newest. Newest is at (idx-1) mod 256.
    # idx points to next-write = oldest entry currently in buffer.
    for i in range(256):
        real_idx = (idx + i) % 256
        base = GAMELOG_ADDR + real_idx * 8
        e = dump_bytes[base:base + 8]
        type_, ctx, frame, _ = e[0], e[1], e[2], e[3]
        d1 = e[4] | (e[5] << 8)
        d2 = e[6] | (e[7] << 8)
        if type_ == 0:
            continue
        entries.append({
            "idx": real_idx,
            "type": type_,
            "ctx": ctx,
            "frame": frame,
            "d1": d1,
            "d2": d2,
        })
    return entries


def fmt_signed_word(w):
    """Convert unsigned 16-bit to signed-display if MSB set."""
    if w & 0x8000:
        return f"{w - 0x10000} (0x{w:04X})"
    return f"{w}"


def print_entries(entries):
    if not entries:
        print("Buffer пуст (ни одного event'а).")
        return

    print(f"Всего event'ов в buffer'е: {len(entries)}")
    print()
    print(f"{'#':>3} {'idx':>3} {'frm':>3} {'type':<11} {'ctx':>4} {'d1':>20} {'d2':>20}")
    print("-" * 78)

    for n, e in enumerate(entries):
        ename = EVT_NAMES.get(e["type"], f"UNK({e['type']})")
        if e["type"] == 1:  # SHOT_FIRED — d1/d2 = SmoothX/SmoothY (где курсор)
            d1str = f"AimX={e['d1']}"
            d2str = f"AimY={e['d2']}"
        elif e["type"] == 2:  # BBOX_HIT
            d1str = f"BulletX={e['d1']}"
            d2str = f"BulletY={e['d2']}"
        elif e["type"] == 3:  # HEMI
            if e['d1'] == 0xFFFF and e['d2'] == 0xFFFF:
                d1str = "TargetX=<SKIP>"
                d2str = "TargetY=<SKIP>"
            else:
                d1str = f"TargetX={fmt_signed_word(e['d1'])}"
                d2str = f"TargetY={fmt_signed_word(e['d2'])}"
        elif e["type"] == 4:  # INSERT
            slots_len = e['d1'] & 0xFF
            hsa = (e['d1'] >> 8) & 0xFF
            color = e['d2'] & 0xFF
            hsub = (e['d2'] >> 8) & 0xFF
            d1str = f"len={slots_len} HSA={hsa}"
            d2str = f"col={color} HSub={hsub}"
        elif e["type"] == 5:  # CASCADE_TRIGGER
            slots_len = e['d1'] & 0xFF
            hsa = (e['d1'] >> 8) & 0xFF
            off = e['d2'] & 0xFF
            if off & 0x80:
                off -= 0x100
            hsub = (e['d2'] >> 8) & 0xFF
            d1str = f"len={slots_len} HSA={hsa}"
            d2str = f"off={off} HSub={hsub}"
        else:
            d1str = f"d1=0x{e['d1']:04X}"
            d2str = f"d2=0x{e['d2']:04X}"
        print(f"{n:>3} {e['idx']:>3} {e['frame']:>3} {ename:<11} {e['ctx']:>4} {d1str:>20} {d2str:>20}")


def find_wrong_target(entries):
    """
    Эвристика: для каждой пары (BBOX_HIT, HEMI) или (HEMI, INSERT)
    в одном frame-window — проверяем расхождения.
    Drift X/Y между BBOX_HIT bullet pos и HEMI target pos = индикатор
    "шар не там куда летел".
    """
    print()
    print("=" * 78)
    print("АНАЛИЗ: цепочки SHOT → BBOX_HIT → HEMI → INSERT")
    print("=" * 78)

    # Группируем events по shot-sequence (от SHOT_FIRED до INSERT).
    seq = []
    cur = []
    for e in entries:
        if e["type"] == 1:  # SHOT_FIRED — начало новой sequence
            if cur:
                seq.append(cur)
            cur = [e]
        else:
            cur.append(e)
    if cur:
        seq.append(cur)

    for s_no, s in enumerate(seq):
        types = [EVT_NAMES.get(e["type"], "?") for e in s]
        if "INSERT" not in types:
            continue  # bullet not yet hit / off-screen
        # Извлекаем
        shot = next((e for e in s if e["type"] == 1), None)
        bbox = next((e for e in s if e["type"] == 2), None)
        hemi = next((e for e in s if e["type"] == 3), None)
        ins  = next((e for e in s if e["type"] == 4), None)
        if not (shot and bbox and hemi and ins):
            continue

        # BulletX/Y vs Target pos
        bx, by = bbox["d1"], bbox["d2"]
        if hemi["d1"] == 0xFFFF:
            tx, ty = None, None
        else:
            tx, ty = hemi["d1"], hemi["d2"]
            # signed conversion
            if tx & 0x8000: tx -= 0x10000
            if ty & 0x8000: ty -= 0x10000

        hit_idx = bbox["ctx"]
        tgt_idx = hemi["ctx"]
        ins_idx = ins["ctx"]
        ins_len = ins["d1"] & 0xFF
        ins_hsa = (ins["d1"] >> 8) & 0xFF

        # Aim point at moment of shot (от Hyper-V/RDP jitter)
        aim_x, aim_y = shot["d1"], shot["d2"]

        # Frog_Angle = direction в которой полетел bullet (8-bit BRAD, 0..255)
        frog_angle = shot['ctx']
        import math
        dx_aim = aim_x - 327
        dy_aim = aim_y - 231
        expected_brad = None
        angle_diff_brad = None
        if not (dx_aim == 0 and dy_aim == 0):
            expected_angle_rad = math.atan2(dy_aim, dx_aim)
            expected_brad = int(((expected_angle_rad / (2 * math.pi)) * 256) % 256)
            diff = (int(frog_angle) - expected_brad) % 256
            if diff > 128: diff -= 256
            angle_diff_brad = diff

        warn = []
        if tx is not None:
            dx = bx - tx
            dy = by - ty
            dist = abs(dx) + abs(dy)
            if dist > 32:
                warn.append(f"BBOX↔HEMI drift={dist} px")
        if abs(int(tgt_idx) - int(hit_idx)) > 1:
            warn.append(f"hit={hit_idx} → target={tgt_idx} (Δ>{1})")
        if ins_idx > ins_len:
            warn.append(f"insert={ins_idx} > SlotsLen={ins_len} (clamped)")
        # Aim vs final bullet impact — wrong-target detection
        if tx is not None:
            aim_to_target = abs(aim_x - tx) + abs(aim_y - ty)
            if aim_to_target > 80:
                warn.append(f"⚡ AIM↔TARGET drift={aim_to_target} px (aim ({aim_x},{aim_y}), target ({tx},{ty}))")
        # Frog_Angle vs aim direction — grace stale detection
        if angle_diff_brad is not None and abs(angle_diff_brad) > 16:
            deg = angle_diff_brad * 360 / 256
            warn.append(f"🎯 ANGLE STALE: Frog_Angle off by {angle_diff_brad} BRAD ({deg:.1f}°) from aim direction")

        flag = "  ⚠️ " if warn else "     "
        warntext = " | ".join(warn) if warn else "OK"

        print(f"\nShot #{s_no+1} (frame ~{shot['frame']}):")
        if expected_brad is not None:
            print(f"  SHOT     Frog_Angle={frog_angle} (expected from aim={expected_brad}, Δ={angle_diff_brad}) AimXY=({aim_x},{aim_y})")
        else:
            print(f"  SHOT     Frog_Angle={frog_angle} AimXY=({aim_x},{aim_y})")
        print(f"  BBOX_HIT hit_idx={hit_idx} BulletXY=({bx},{by})")
        if tx is not None:
            print(f"  HEMI     target_idx={tgt_idx} TargetXY=({tx},{ty})")
        else:
            print(f"  HEMI     target_idx={tgt_idx} <SKIP slot>")
        print(f"  INSERT   ins_idx={ins_idx} SlotsLen={ins_len} HSA={ins_hsa}")
        print(f"{flag}{warntext}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python parse_log_dump.py <dump_file>")
        sys.exit(1)
    path = sys.argv[1]
    with open(path, 'rb') as f:
        dump = f.read()
    print(f"Dump file: {path} ({len(dump)} bytes)")
    if len(dump) < 0x5010:
        print(f"WARN: dump too small (expected ≥ 64 KB)")
    print()
    entries = parse_dump(dump)
    print_entries(entries)
    find_wrong_target(entries)


if __name__ == "__main__":
    main()
