#!/usr/bin/env python3
"""Audit FT812 scanline budget for L05 after fast-fill warm-up.

This produces a command-frame snapshot after CurrentLevel=4 has been loaded and
VDC_UpdateAllChains has run for a configurable number of frames.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import Harness  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402

# Runtime CMD_ADDRESS_PTR from Source/ASM/main.asm. The old diagnostic #5E00
# overlaps resident code in current builds and corrupts ZL_DrawFrame capture.
CMD = 0x4CB0
CAPTURE_CMD = 0x9000
WIDTH = 640
HEIGHT = 480
LINE_BUDGET = 832
FRAME_BUDGET = LINE_BUDGET * HEIGHT
PALETTED_FORMATS = {8, 14, 15, 16}
FMT_NAMES = {
    0: "ARGB1555", 1: "L1", 2: "L4", 3: "L8", 4: "RGB332", 5: "ARGB2",
    6: "ARGB4", 7: "RGB565", 8: "PALETTED", 9: "TEXT8X8",
    10: "TEXTVGA", 11: "BARGRAPH", 14: "PALETTED565",
    15: "PALETTED4444", 16: "PALETTED8", 17: "L2",
}


def sx(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b if a > 0 else 0


def write_u32(e, ptr: int, value: int) -> int:
    for i in range(4):
        e.mem.write(ptr + i, (value >> (8 * i)) & 0xFF)
    return (ptr + 4) & 0xFFFF


def dl_bitmap_layout(fmt: int, stride: int, height: int) -> int:
    return (0x07 << 24) | ((fmt & 0x1F) << 19) | ((stride & 0x3FF) << 9) | (height & 0x1FF)


def dl_bitmap_layout_h(stride: int, height: int) -> int:
    return (0x28 << 24) | (((stride >> 10) & 3) << 2) | ((height >> 9) & 3)


def dl_bitmap_size(filter_: int, width: int, height: int) -> int:
    return (0x08 << 24) | ((filter_ & 1) << 20) | ((width & 0x1FF) << 9) | (height & 0x1FF)


def dl_bitmap_size_h(width: int, height: int) -> int:
    return (0x29 << 24) | (((width >> 9) & 3) << 2) | ((height >> 9) & 3)


def dl_vertex2ii(x: int, y: int, handle: int, cell: int) -> int:
    return 0x80000000 | ((x & 0x1FF) << 21) | ((y & 0x1FF) << 12) | ((handle & 0x1F) << 7) | (cell & 0x7F)


def dl_vertex2f(x16: int, y16: int) -> int:
    return 0x40000000 | ((x16 & 0x7FFF) << 15) | (y16 & 0x7FFF)


def capture_call(h: Harness, name: str, max_steps: int = 4_000_000) -> bytes:
    h.sw("FT.Coprocessor.BufferPtr", CAPTURE_CMD)
    h.call(name, max_steps)
    end = h.gw("FT.Coprocessor.BufferPtr")
    size = (end - CAPTURE_CMD) & 0xFFFF
    return bytes(h.e.mem.read((CAPTURE_CMD + i) & 0xFFFF) for i in range(size))


def identity_matrix_words() -> bytes:
    words = [
        0x15000100, 0x16000000, 0x17000000,
        0x18000000, 0x19000100, 0x1A000000,
        0x04FFFFFF,
    ]
    return b"".join(w.to_bytes(4, "little") for w in words)


def cursor_words(h: Harness) -> bytes:
    x = h.gw("Core.ZL_SmoothX") if "Core.ZL_SmoothX" in h.S else 320
    y = h.gw("Core.ZL_SmoothY") if "Core.ZL_SmoothY" in h.S else 240
    words = [
        0x04FFFFFF,
        (0x05 << 24) | 7,
        (0x01 << 24) | 0x0D0000,
        dl_bitmap_layout(6, 48, 24),
        dl_bitmap_size(0, 24, 24),
        0x06000000,
        dl_vertex2f(x * 16, y * 16),
    ]
    return b"".join(w.to_bytes(4, "little") for w in words)


def cmd_frame(h: Harness) -> bytes:
    e = h.e
    ptr = CMD
    ptr = write_u32(e, ptr, 0xFFFFFF00)          # CMD_DLSTART
    ptr = write_u32(e, ptr, (0x27 << 24) | 4)    # VERTEX_FORMAT(4)
    ptr = write_u32(e, ptr, (0x02 << 24) | 0)    # CLEAR_COLOR_RGB
    ptr = write_u32(e, ptr, (0x26 << 24) | 0x07) # CLEAR(1,1,1)
    h.sw("FT.Coprocessor.BufferPtr", ptr)
    h.call("Core.ZL_DrawFrame", 10_000_000)
    ptr = h.gw("FT.Coprocessor.BufferPtr")
    ptr = write_u32(e, ptr, 0x00000000)          # DISPLAY
    used = (ptr - CMD) & 0xFFFF
    return bytes(e.mem.read((CMD + i) & 0xFFFF) for i in range(used))


def chain_budget_frame(h: Harness) -> bytes:
    """Frame model: real warmed L05 chain vertices plus explicit bitmap state."""
    e = h.e

    def read_cmd() -> bytes:
        end = h.gw("FT.Coprocessor.BufferPtr")
        size = (end - CAPTURE_CMD) & 0xFFFF
        return bytes(e.mem.read((CAPTURE_CMD + i) & 0xFFFF) for i in range(size))

    h.call("Core.SetCurrentTrackPage")
    killzone = capture_call(h, "DrawKillzoneDual")
    frog_chunks = b"".join(
        capture_call(h, name)
        for name in (
            "Core.Frog_DrawPlate",
            "Core.Frog_DrawBody",
            "Core.Frog_DrawTongue",
            "Core.Frog_DrawBallNow",
            "Core.Frog_DrawNextBall",
            "Core.Frog_DrawFaceOverlay",
            "Core.Bullet_Draw",
        )
        if name in h.S
    )

    h.sw("FT.Coprocessor.BufferPtr", CAPTURE_CMD)
    h.call("Core.ZL_DrawActiveChain", 10_000_000)
    chain1 = read_cmd()

    chain2 = b""
    if h.gb("Core.VDC_HasSecondChain"):
        h.call("Core.VDC_SwapChains")
        h.call("Core.SetSecondTrackPage")
        h.sw("FT.Coprocessor.BufferPtr", CAPTURE_CMD)
        h.call("Core.ZL_DrawActiveChain", 10_000_000)
        chain2 = read_cmd()
        h.call("Core.VDC_SwapChains")
        h.call("Core.SetCurrentTrackPage")

    overlay_names = [
        "DrawFrameStrips",
        "DrawLivesCounter",
        "DrawHudTopText",
        "DrawHudProgress",
        "DrawHudMenu",
        "DrawRetryDialog",
        "DrawFadeOverlay",
    ]
    overlay_chunks: dict[str, bytes] = {}
    for name in overlay_names:
        if name in h.S:
            overlay_chunks[name] = capture_call(h, name)

    scratch = 0x7000
    ptr = scratch
    ptr = write_u32(e, ptr, 0xFFFFFF00)                 # CMD_DLSTART
    ptr = write_u32(e, ptr, (0x27 << 24) | 4)           # VERTEX_FORMAT(4)
    ptr = write_u32(e, ptr, (0x02 << 24) | 0)           # CLEAR_COLOR_RGB
    ptr = write_u32(e, ptr, (0x26 << 24) | 0x07)        # CLEAR(1,1,1)

    # Background: 400x300 PALETTED4444 scaled by matrix, screen span 640x480.
    ptr = write_u32(e, ptr, (0x05 << 24) | 1)           # BITMAP_HANDLE(1)
    ptr = write_u32(e, ptr, (0x01 << 24) | 0x010000)    # BITMAP_SOURCE(BG_RAMG_ADDR)
    ptr = write_u32(e, ptr, dl_bitmap_layout(15, 400, 300))
    ptr = write_u32(e, ptr, dl_bitmap_size_h(640, 480))
    ptr = write_u32(e, ptr, dl_bitmap_size(0, 640, 480))
    ptr = write_u32(e, ptr, (0x1F << 24) | 1)           # BEGIN(BITMAPS)
    ptr = write_u32(e, ptr, dl_vertex2ii(0, 0, 1, 0))
    ptr = write_u32(e, ptr, (0x21 << 24))               # END

    # Ball atlas. Format depends on BALLS_ARGB4_ENABLED in Source/ASM/main.asm.
    ptr = write_u32(e, ptr, (0x1F << 24) | 1)           # BEGIN(BITMAPS)
    ptr = write_u32(e, ptr, (0x05 << 24) | 0)           # BITMAP_HANDLE(0)
    ptr = write_u32(e, ptr, (0x01 << 24) | 0x050000)    # BITMAP_SOURCE(BALLS_RAMG_ADDR)
    ptr = write_u32(e, ptr, dl_bitmap_layout(6, 64, 32))
    ptr = write_u32(e, ptr, dl_bitmap_size(0, 32, 32))

    ptr = write_u32(e, ptr, 0x00000000)                 # DISPLAY
    used = (ptr - scratch) & 0xFFFF
    header = bytes(e.mem.read((scratch + i) & 0xFFFF) for i in range(used))
    # Drop DISPLAY from header before appending real chain streams; keep one final DISPLAY.
    if header.endswith(b"\x00\x00\x00\x00"):
        header = header[:-4]
    playfield = header + killzone + frog_chunks + chain1 + chain2
    overlays = (
        identity_matrix_words()
        + overlay_chunks.get("DrawFrameStrips", b"")
        + overlay_chunks.get("DrawLivesCounter", b"")
        + overlay_chunks.get("DrawHudTopText", b"")
        + overlay_chunks.get("DrawHudProgress", b"")
        + overlay_chunks.get("DrawHudMenu", b"")
        + overlay_chunks.get("DrawRetryDialog", b"")
        + cursor_words(h)
        + overlay_chunks.get("DrawFadeOverlay", b"")
    )
    full = playfield + overlays + b"\x21\x00\x00\x00\x00\x00\x00\x00"
    return full


def rate_for(fmt: int, flt: int, pal_rate: int) -> int:
    if flt == 1:
        return 2
    if fmt in PALETTED_FORMATS:
        return pal_rate
    return 16


def parse_and_score(data: bytes, pal_rate: int) -> dict:
    handles: dict[int, dict] = {}
    cur_handle = 0
    in_begin = None
    scissor_xy = (0, 0)
    scissor_size = (WIDTH, HEIGHT)
    line = [0] * HEIGHT
    line_by_label = [Counter() for _ in range(HEIGHT)]
    cmd_count = 0
    clear_count = 0
    sprites = []
    op_counts = Counter()

    LABELS = {
        1: "bg",
        0: "balls",
        2: "frog_body",
        3: "killzone_or_destroy",
        4: "frog_plate",
        5: "frog_tongue",
        6: "frog_overlay",
        7: "cursor",
        14: "frame_top",
        15: "frame_bottom",
        16: "frame_left",
        17: "frame_right",
        19: "hud_progress",
        20: "hud_menu",
        21: "dialog_frame",
    }

    def label_for(handle: int, fmt: int, w: int, ht: int, x: int, y: int) -> str:
        if handle in LABELS:
            return LABELS[handle]
        if fmt == 15 and w == 88 and ht == 88:
            return "killzone"
        if fmt == 6 and w == 122 and ht == 122:
            return "frog"
        if fmt == 6 and w == 32 and ht == 32:
            return "balls_argb4"
        return f"handle_{handle}"

    def hdl() -> dict:
        return handles.setdefault(cur_handle, {})

    words = [struct.unpack_from("<I", data, off)[0] for off in range(0, len(data) - 3, 4)]

    for word in words:
        if word == 0xFFFFFF00:
            # CMD_DLSTART is a coprocessor FIFO command, not a RAM_DL display-list op.
            continue
        cmd_count += 1
        op = (word >> 24) & 0xFF
        op_counts[f"{op:02X}"] += 1

        if word == 0:
            break
        if (op & 0xC0) == 0x80 or (op & 0xC0) == 0xC0:
            if in_begin == 1:
                x = (word >> 21) & 0x1FF
                y = (word >> 12) & 0x1FF
                vh = (word >> 7) & 0x1F
                cell = word & 0x7F
                h = handles.get(vh, {})
                w = h.get("w", 0)
                ht = h.get("h", 0)
                fmt = h.get("fmt", 0)
                flt = h.get("filter", 0)
                x0 = max(x, scissor_xy[0])
                y0 = max(y, scissor_xy[1])
                x1 = min(x + w, scissor_xy[0] + scissor_size[0])
                y1 = min(y + ht, scissor_xy[1] + scissor_size[1])
                dw = max(0, x1 - x0)
                dh = max(0, y1 - y0)
                per = ceil_div(dw, rate_for(fmt, flt, pal_rate))
                label = label_for(vh, fmt, w, ht, x, y)
                for yy in range(max(0, y0), min(HEIGHT, y1)):
                    line[yy] += per
                    line_by_label[yy][label] += per
                sprites.append((vh, cell, x, y, w, ht, dw, dh, fmt, flt, per))
            continue
        if (op & 0xC0) == 0x40:
            if in_begin == 1:
                x_raw = sx((word >> 15) & 0x7FFF, 15)
                y_raw = sx(word & 0x7FFF, 15)
                x = x_raw // 16
                y = y_raw // 16
                h = handles.get(cur_handle, {})
                w = h.get("w", 0)
                ht = h.get("h", 0)
                fmt = h.get("fmt", 0)
                flt = h.get("filter", 0)
                x0 = max(x, scissor_xy[0])
                y0 = max(y, scissor_xy[1])
                x1 = min(x + w, scissor_xy[0] + scissor_size[0])
                y1 = min(y + ht, scissor_xy[1] + scissor_size[1])
                dw = max(0, x1 - x0)
                dh = max(0, y1 - y0)
                per = ceil_div(dw, rate_for(fmt, flt, pal_rate))
                label = label_for(cur_handle, fmt, w, ht, x, y)
                for yy in range(max(0, y0), min(HEIGHT, y1)):
                    line[yy] += per
                    line_by_label[yy][label] += per
                sprites.append((cur_handle, None, x, y, w, ht, dw, dh, fmt, flt, per))
            continue

        if op == 0x05:
            cur_handle = word & 0x1F
            handles.setdefault(cur_handle, {})
        elif op == 0x07:
            h = hdl()
            h["fmt"] = (word >> 19) & 0x1F
            h["stride"] = (h.get("stride", 0) & ~0x3FF) | ((word >> 9) & 0x3FF)
            h["layout_h"] = (h.get("layout_h", 0) & ~0x1FF) | (word & 0x1FF)
        elif op == 0x28:
            h = hdl()
            h["stride"] = (h.get("stride", 0) & 0x3FF) | (((word >> 2) & 3) << 10)
            h["layout_h"] = (h.get("layout_h", 0) & 0x1FF) | ((word & 3) << 9)
        elif op == 0x08:
            h = hdl()
            h["filter"] = (word >> 20) & 1
            h["w"] = (h.get("w_hi", 0) << 9) | ((word >> 9) & 0x1FF)
            h["h"] = (h.get("h_hi", 0) << 9) | (word & 0x1FF)
        elif op == 0x29:
            h = hdl()
            h["w_hi"] = (word >> 2) & 3
            h["h_hi"] = word & 3
        elif op == 0x1B:
            scissor_xy = ((word >> 11) & 0x7FF, word & 0x7FF)
        elif op == 0x1C:
            scissor_size = ((word >> 12) & 0xFFF, word & 0xFFF)
        elif op == 0x1F:
            in_begin = word & 0xF
        elif op == 0x21:
            in_begin = None
        elif op == 0x26 and (word & 0x4):
            clear_count += 1
            per = ceil_div(scissor_size[0], 16)
            for yy in range(max(0, scissor_xy[1]), min(HEIGHT, scissor_xy[1] + scissor_size[1])):
                line[yy] += per
                line_by_label[yy]["clear"] += per

    total_line = [v + cmd_count for v in line]
    worst_y = max(range(HEIGHT), key=lambda yy: total_line[yy])
    over = [yy for yy, v in enumerate(total_line) if v > LINE_BUDGET]
    frame_total = sum(total_line)
    sprite_total = sum(line)
    top_sprites = sorted(sprites, key=lambda s: s[10] * s[7], reverse=True)[:20]
    return {
        "pal_rate": pal_rate,
        "cmd_count": cmd_count,
        "clear_count": clear_count,
        "sprite_count": len(sprites),
        "walk_per_line": cmd_count,
        "worst_y": worst_y,
        "worst_line_clocks": total_line[worst_y],
        "worst_fill_only": line[worst_y],
        "over_lines": len(over),
        "frame_total": frame_total,
        "frame_budget": FRAME_BUDGET,
        "frame_pct": frame_total * 100.0 / FRAME_BUDGET,
        "sprite_fill_total": sprite_total,
        "line_samples": {str(y): total_line[y] for y in range(max(0, worst_y - 5), min(HEIGHT, worst_y + 6))},
        "worst_line_budget": {
            "y": worst_y,
            "total": total_line[worst_y],
            "limit": LINE_BUDGET,
            "slack": LINE_BUDGET - total_line[worst_y],
            "dl_walk": cmd_count,
            "fill_total": line[worst_y],
            "fill_by_label": dict(line_by_label[worst_y].most_common()),
        },
        "top_sprites": [
            {
                "handle": s[0], "cell": s[1], "x": s[2], "y": s[3],
                "size": [s[4], s[5]], "draw": [s[6], s[7]],
                "fmt": FMT_NAMES.get(s[8], str(s[8])), "filter": s[9],
                "clocks_per_line": s[10], "area_clocks": s[10] * s[7],
            }
            for s in top_sprites
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warm-frames", type=int, default=160)
    ap.add_argument("--out", default=str(ROOT / "Diagnostics" / "level5_ft812_budget"))
    ap.add_argument(
        "--pal-rates",
        default="16,8,4,2",
        help="comma-separated PALETTED* throughput values in px/clk",
    )
    args = ap.parse_args()

    h = Harness(4)
    track2 = ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l05_2_640.bin"
    data2 = track2.read_bytes()
    start2 = 0x0F * PAGE_SIZE
    h.e.mem.physical[start2 : start2 + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    h.e.mem.physical[start2 : start2 + len(data2)] = data2
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if "CurrentCodePage" in h.S:
        h.sb("CurrentCodePage", 0x04)
    h.run_play_frames(args.warm_frames)
    capture_mode = "chain_budget"
    data = chain_budget_frame(h)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "cmd_frame_l05_warm.bin").write_bytes(data)

    report = {
        "level_index": 4,
        "level": 5,
        "warm_frames": args.warm_frames,
        "slots_len_1": h.gb("Core.VDC_SlotsLen"),
        "slots_len_2": h.gb("Core.VDC2_SlotsLen"),
        "hsa_1": h.gb("Core.VDC_HSA"),
        "has_second_chain": h.gb("Core.VDC_HasSecondChain"),
        "cmd_bytes": len(data),
        "cmd_words_raw": len(data) // 4,
        "capture_mode": capture_mode,
        "models": [parse_and_score(data, int(pr.strip())) for pr in args.pal_rates.split(",") if pr.strip()],
    }
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"L05 after warm_frames={args.warm_frames}")
    print(f"slots: chain1={report['slots_len_1']} chain2={report['slots_len_2']} has2={report['has_second_chain']}")
    print(f"capture={capture_mode}")
    print(f"cmd: {report['cmd_bytes']} bytes, {report['cmd_words_raw']} raw words")
    for m in report["models"]:
        print(
            f"pal={m['pal_rate']:>2} px/clk: cmds={m['cmd_count']} sprites={m['sprite_count']} "
            f"walk={m['walk_per_line']} clk/line worst y={m['worst_y']} "
            f"{m['worst_line_clocks']}/{LINE_BUDGET} ({m['worst_line_clocks']*100/LINE_BUDGET:.1f}%) "
            f"over={m['over_lines']} frame={m['frame_total']}/{FRAME_BUDGET} ({m['frame_pct']:.1f}%)"
        )
    if len(report["models"]) >= 2:
        # Estimate the minimum paletted throughput needed for the observed worst
        # line using two model points. The model is line = fixed + pal_work/rate.
        a, b = report["models"][0], report["models"][1]
        r1, c1 = a["pal_rate"], a["worst_line_clocks"]
        r2, c2 = b["pal_rate"], b["worst_line_clocks"]
        denom = (1.0 / r1) - (1.0 / r2)
        if abs(denom) > 1e-9:
            pal_work = (c1 - c2) / denom
            fixed = c1 - pal_work / r1
            if LINE_BUDGET > fixed:
                need = pal_work / (LINE_BUDGET - fixed)
                print(f"required paletted throughput: >= {need:.2f} px/clk for {LINE_BUDGET} clk/line")
            else:
                print("required paletted throughput: impossible, fixed non-paletted/DL cost already exceeds budget")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
