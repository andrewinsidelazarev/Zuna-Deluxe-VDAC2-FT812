#!/usr/bin/env python3
"""analyze_dl_pixelclock.py — парсит FT812 cmd_frame_*.bin и оценивает
pixel-clock budget по каждому BITMAPS draw.

Бюджет FT812 (per BRT_AN_033 + experimental):
- NEAREST: ~16 px/clock
- BILINEAR: ~2 px/clock
- BORDER mode: stride/bbox scan
Один scanline 640×480 @ 60Hz: line_clocks ≈ 800 (PCLK budget).

Каждый bitmap draw на FT812:
- effective_pixels_per_line ≈ width × height_visible_on_line
- pixel_clocks ≈ effective_pixels / (16 or 2)

Не учитывает: scissor clipping (FT812 пропускает off-clip pixels быстрее),
overlap pixel coverage (если 2 спрайта overlap, оба cost'ятся), кэш.
"""
import sys, struct, os
from pathlib import Path

# Opcode names (FT81X)
OPCODES = {
    0x00: 'DISPLAY',
    0x01: 'BITMAP_SOURCE',
    0x02: 'CLEAR_COLOR_RGB',
    0x03: 'TAG',
    0x04: 'COLOR_RGB',
    0x05: 'BITMAP_HANDLE',
    0x06: 'CELL',
    0x07: 'BITMAP_LAYOUT',
    0x08: 'BITMAP_SIZE',
    0x09: 'ALPHA_FUNC',
    0x0A: 'STENCIL_FUNC',
    0x0B: 'BLEND_FUNC',
    0x0C: 'STENCIL_OP',
    0x0D: 'POINT_SIZE',
    0x0E: 'LINE_WIDTH',
    0x0F: 'CLEAR_COLOR_A',
    0x10: 'COLOR_A',
    0x11: 'CLEAR_STENCIL',
    0x12: 'CLEAR_TAG',
    0x13: 'STENCIL_MASK',
    0x14: 'TAG_MASK',
    0x15: 'BITMAP_TRANSFORM_A',
    0x16: 'BITMAP_TRANSFORM_B',
    0x17: 'BITMAP_TRANSFORM_C',
    0x18: 'BITMAP_TRANSFORM_D',
    0x19: 'BITMAP_TRANSFORM_E',
    0x1A: 'BITMAP_TRANSFORM_F',
    0x1B: 'SCISSOR_XY',
    0x1C: 'SCISSOR_SIZE',
    0x1D: 'CALL',
    0x1E: 'JUMP',
    0x1F: 'BEGIN',
    0x20: 'COLOR_MASK',
    0x21: 'END',
    0x22: 'SAVE_CONTEXT',
    0x23: 'RESTORE_CONTEXT',
    0x24: 'RETURN',
    0x25: 'MACRO',
    0x26: 'CLEAR',
    0x27: 'VERTEX_FORMAT',
    0x28: 'BITMAP_LAYOUT_H',
    0x29: 'BITMAP_SIZE_H',
    0x2A: 'PALETTE_SOURCE',
    0x2B: 'VERTEX_TRANSLATE_X',
    0x2C: 'VERTEX_TRANSLATE_Y',
    0x2D: 'NOP',
}

# --- Render-rate model (clocks) ----------------------------------------------
# Lina TSL (2026-05-23, hw-verified on 1024x768): FT812 fills 16 px/clock for
# primitives and NON-paletted bitmaps (NEAREST); every command that draws
# nothing / only changes state costs 1 clock; CLEAR paints full width at
# 16 px/clk. CRITICALLY: the engine re-walks the WHOLE display list for EVERY
# scanline, so each command costs its 1-clock overhead on every line.
# Paletted formats render SLOWER than 16 px/clk (exact rate not yet measured on
# our clock-config) and BILINEAR roughly halves throughput — both parameterized.
PAL_RATE = 8        # px/clk for PALETTED* formats (UNVERIFIED default; swept below)
BILINEAR_RATE = 2   # px/clk for BILINEAR filter (legacy assumption)
PALETTED_FORMATS = (8, 14, 15, 16)  # PALETTED, PALETTED565, PALETTED4444, PALETTED8


def rate_for(fmt, flt, pal_rate=None):
    """px/clk for a bitmap of given format/filter under the corrected model."""
    pr = PAL_RATE if pal_rate is None else pal_rate
    if flt == 1:                 # BILINEAR
        return BILINEAR_RATE
    if fmt in PALETTED_FORMATS:  # paletted lookup is slower than 16 px/clk
        return pr
    return 16                    # non-paletted NEAREST primitive


def ceil_div(a, b):
    return (a + b - 1) // b if a > 0 else 0


FILTER_NAMES = {0: 'NEAREST', 1: 'BILINEAR'}
FORMAT_NAMES = {
    0: 'ARGB1555', 1: 'L1', 2: 'L4', 3: 'L8', 4: 'RGB332', 5: 'ARGB2',
    6: 'ARGB4', 7: 'RGB565', 8: 'PALETTED', 9: 'TEXT8X8', 10: 'TEXTVGA',
    11: 'BARGRAPH', 14: 'PALETTED565', 15: 'PALETTED4444', 16: 'PALETTED8',
    17: 'L2',
}


def parse_dl(data):
    """Yield (offset, opcode_byte, raw_word, decoded_dict) for each 4-byte command."""
    for i in range(0, len(data) - 3, 4):
        word = struct.unpack('<I', data[i:i+4])[0]
        op = (word >> 24) & 0xFF
        yield i, op, word


def analyze(bundle_dir):
    bundle = Path(bundle_dir)
    frames = sorted(bundle.glob('cmd_frame_*.bin'))
    if not frames:
        print(f'No cmd_frame_*.bin in {bundle}')
        return
    for fpath in frames:
        data = fpath.read_bytes()
        analyze_frame(fpath.name, data)


def analyze_frame(fname, data):
    print(f'\n{"="*70}\nFrame: {fname} ({len(data)} bytes, {len(data)//4} commands)\n{"="*70}')

    # State trackers
    cur_handle = 0
    handles = {}     # handle → {source, layout, size, format, w, h, stride, filter}
    scissor_xy = (0, 0)
    scissor_size = (640, 480)
    palette_source = 0
    in_begin = None
    pixel_clock_total = 0
    sprite_stats = []  # list of (handle, w_drawn, h_drawn, format, filter, pix_clk)
    clears = []        # list of (scissor_xy, scissor_size) for each color-CLEAR

    for off, op, word in parse_dl(data):
        if op == 0x05:  # BITMAP_HANDLE
            cur_handle = word & 0x1F
            if cur_handle not in handles:
                handles[cur_handle] = {}
        elif op == 0x01:  # BITMAP_SOURCE
            src = word & 0xFFFFFF
            handles.setdefault(cur_handle, {})['source'] = src
        elif op == 0x07:  # BITMAP_LAYOUT
            fmt = (word >> 19) & 0x1F
            stride = (word >> 9) & 0x3FF
            height = word & 0x1FF
            handles.setdefault(cur_handle, {}).update({
                'format': fmt, 'stride': stride, 'h_layout': height
            })
        elif op == 0x28:  # BITMAP_LAYOUT_H (high bits for stride/height)
            stride_h = (word >> 2) & 3
            height_h = word & 3
            h = handles.setdefault(cur_handle, {})
            h['stride'] = (h.get('stride', 0) | (stride_h << 10))
            h['h_layout'] = (h.get('h_layout', 0) | (height_h << 9))
        elif op == 0x08:  # BITMAP_SIZE
            f = (word >> 20) & 1
            wrap_x = (word >> 19) & 1
            wrap_y = (word >> 18) & 1
            w_lo = (word >> 9) & 0x1FF
            h_lo = word & 0x1FF
            hdl = handles.setdefault(cur_handle, {})
            # Preserve high bits set by BITMAP_SIZE_H earlier (FT_BitmapSize emits
            # SIZE_H then SIZE).
            w_hi = hdl.get('w_hi', 0)
            h_hi = hdl.get('h_hi', 0)
            hdl.update({
                'filter': f, 'w': (w_hi << 9) | w_lo, 'h': (h_hi << 9) | h_lo
            })
        elif op == 0x29:  # BITMAP_SIZE_H — set BEFORE BITMAP_SIZE per FT_BitmapSize macro
            w_h = (word >> 2) & 3
            h_h = word & 3
            hdl = handles.setdefault(cur_handle, {})
            hdl['w_hi'] = w_h
            hdl['h_hi'] = h_h
        elif op == 0x1B:  # SCISSOR_XY
            scissor_xy = ((word >> 11) & 0x7FF, word & 0x7FF)
        elif op == 0x1C:  # SCISSOR_SIZE
            scissor_size = ((word >> 12) & 0x7FF, word & 0x7FF)
        elif op == 0x1F:  # BEGIN
            in_begin = word & 0xF  # 1=BITMAPS, 2=POINTS, 3=LINES, ...
        elif op == 0x21:  # END
            in_begin = None
        elif op == 0x2A:  # PALETTE_SOURCE
            palette_source = word & 0xFFFFFF
        elif op == 0x26:  # CLEAR — bit2 = clear color buffer (paints scissor rect)
            if word & 0x4:
                clears.append((scissor_xy, scissor_size))
        elif (op & 0xC0) == 0x80:  # VERTEX2II (bit 7=1, bit 6=0)
            if in_begin == 1:
                # VERTEX2II: bits 30..21 = x (10bit), 20..11 = y, 10..7 = handle, 6..0 = cell
                vx = (word >> 21) & 0x1FF
                vy = (word >> 11) & 0x1FF
                hdl = (word >> 7) & 0xF
                cell = word & 0x7F
                h = handles.get(hdl, {})
                w = h.get('w', 0)
                hh = h.get('h', 0)
                fmt = h.get('format', 0)
                flt = h.get('filter', 0)
                pixels = w * hh
                rate = rate_for(fmt, flt)
                pclk = (pixels + rate - 1) // rate if pixels else 0
                pixel_clock_total += pclk
                sprite_stats.append({
                    'handle': hdl, 'pos': (vx, vy), 'size': (w, hh),
                    'draw': (w, hh), 'fmt': fmt, 'filter': flt,
                    'pclk': pclk, 'src': h.get('source', 0), 'kind': 'V2II'
                })
        elif (op & 0xC0) == 0x40:  # VERTEX2F (bit 7=0, bit 6=1)
            if in_begin == 1:  # BITMAPS
                h = handles.get(cur_handle, {})
                w = h.get('w', 0)
                hh = h.get('h', 0)
                fmt = h.get('format', 0)
                flt = h.get('filter', 0)
                # Effective bbox (intersect with scissor)
                sx0, sy0 = scissor_xy
                sx1 = sx0 + scissor_size[0]
                sy1 = sy0 + scissor_size[1]
                # Vertex2F: bits 30..15 = x (signed 16, /16), bits 14..0 = y (signed)
                x_raw = (word >> 15) & 0x7FFF
                if x_raw & 0x4000: x_raw -= 0x8000
                y_raw = word & 0x7FFF
                if y_raw & 0x4000: y_raw -= 0x8000
                vx, vy = x_raw // 16, y_raw // 16
                bbox_x0 = max(vx, sx0)
                bbox_y0 = max(vy, sy0)
                bbox_x1 = min(vx + w, sx1)
                bbox_y1 = min(vy + hh, sy1)
                draw_w = max(0, bbox_x1 - bbox_x0)
                draw_h = max(0, bbox_y1 - bbox_y0)
                pixels = draw_w * draw_h
                rate = rate_for(fmt, flt)
                pclk = (pixels + rate - 1) // rate if pixels else 0
                pixel_clock_total += pclk
                sprite_stats.append({
                    'handle': cur_handle, 'pos': (vx, vy), 'size': (w, hh),
                    'draw': (draw_w, draw_h), 'fmt': fmt, 'filter': flt,
                    'pclk': pclk, 'src': h.get('source', 0), 'kind': 'V2F'
                })

    # PER-LINE accumulator: для каждой Y-линии (0..479) суммируем pclk всех
    # sprites которые её перекрывают (vy..vy+draw_h). FT812 has ~800 PCLK/line
    # budget @ 57Hz (832 @74Hz). Превышение на каком-то line → tearing.
    line_pclk = [0] * 480
    for s in sprite_stats:
        draw_w, draw_h = s['draw']
        if draw_w <= 0 or draw_h <= 0: continue
        # Each line of this sprite costs draw_w/rate clocks
        rate = 2 if s['filter'] == 1 else 16
        per_line_clk = (draw_w + rate - 1) // rate
        y0 = s.get('pos', (0, 0))[1] if s.get('kind') == 'V2F' else 0
        # Intersection with scissor was already applied in draw bounds
        # We approximate y range = [vy, vy+draw_h)
        vy = max(0, y0)
        y_end = min(480, vy + draw_h)
        for y in range(vy, y_end):
            line_pclk[y] += per_line_clk

    max_line = max(range(480), key=lambda y: line_pclk[y])
    LINE_BUDGET_74HZ = 832
    over_lines = [y for y in range(480) if line_pclk[y] > LINE_BUDGET_74HZ]
    print(f'\nPer-line pixel-clock (budget 832 @74Hz):')
    print(f'  Worst line y={max_line}: {line_pclk[max_line]} clocks ({line_pclk[max_line]*100//LINE_BUDGET_74HZ}%)')
    if over_lines:
        print(f'  ⚠️ {len(over_lines)} lines OVER budget (>{LINE_BUDGET_74HZ}):')
        # Compress consecutive
        groups = []
        for y in over_lines:
            if groups and groups[-1][1] == y - 1:
                groups[-1] = (groups[-1][0], y)
            else:
                groups.append((y, y))
        for y0, y1 in groups[:10]:
            mid = (y0 + y1) // 2
            print(f'    y={y0}..{y1}: peak {max(line_pclk[y0:y1+1])} clocks')
    else:
        print(f'  ✓ All lines within budget')

    # === CORRECTED per-line model (Lina TSL, hw-verified 2026-05-23) =========
    # The FT812 re-walks the ENTIRE display list for EVERY scanline, so every
    # command costs 1 clock per line (NOP/state/vertex alike). On top of that:
    #   - CLEAR paints the scissor width at 16 px/clk, every line it covers
    #   - each bitmap vertex adds ceil(span_w / rate) on the lines it touches
    # rate: 16 for non-paletted NEAREST, BILINEAR_RATE for bilinear, pal_rate
    # for PALETTED* (slower — exact value not yet measured, hence the sweep).
    N_CMDS = len(data) // 4
    LINE_BUDGET = 832  # HCYCLE of VM_640_480_74Hz (Init_Video.asm)
    print(f'\n[CORRECTED] DL-walk overhead = {N_CMDS} clk/line '
          f'({N_CMDS*100//LINE_BUDGET}% of {LINE_BUDGET}) — paid on EVERY line, '
          f'before any fill. Old model scored this as 0.')

    def corrected_worst(pal_rate):
        line = [N_CMDS] * 480  # walk overhead, every line
        for (sxy, ssz) in clears:
            cw = ceil_div(ssz[0], 16)
            for y in range(max(0, sxy[1]), min(480, sxy[1] + ssz[1])):
                line[y] += cw
        for s in sprite_stats:
            dw, dh = s['draw']
            if dw <= 0 or dh <= 0:
                continue
            r = rate_for(s['fmt'], s['filter'], pal_rate)
            per = ceil_div(dw, r)
            y0 = s['pos'][1] if s.get('kind') == 'V2F' else 0
            vy = max(0, y0)
            ye = min(480, vy + dh)
            for y in range(vy, ye):
                line[y] += per
        wl = max(range(480), key=lambda y: line[y])
        over = sum(1 for y in range(480) if line[y] > LINE_BUDGET)
        return wl, line[wl], over, line[0]  # line[0] ~ "empty" line floor

    print(f'  Worst scanline under corrected model (budget {LINE_BUDGET}):')
    print(f'    {"pal px/clk":>11} | {"floor(empty)":>12} | {"worst line":>10} | {"clk":>5} | {"%budget":>7} | over-lines')
    for pr in (16, 8, 4):
        wl, clk, over, floor = corrected_worst(pr)
        flag = '  ⚠️ TEARS' if clk > LINE_BUDGET else '  ✓'
        print(f'    {pr:>11} | {floor:>12} | y={wl:<8} | {clk:>5} | {clk*100//LINE_BUDGET:>6}% | {over:>4} lines{flag}')

    # Sort by pixel-clock cost
    sprite_stats.sort(key=lambda s: -s['pclk'])
    print(f'\nTotal pixel-clock estimate: {pixel_clock_total:6d}')
    print(f'  640×480@60Hz line budget ≈ 800/line × 480 = 384000')
    print(f'  Budget used: {pixel_clock_total * 100 // 384000}%')
    print(f'\nTop sprites by cost:')
    print(f'{"handle":>6} {"pos":>12} {"size":>10} {"draw":>10} {"fmt":>14} {"filter":>9} {"src":>8} {"clocks":>7}')
    for s in sprite_stats[:25]:
        fmt = FORMAT_NAMES.get(s['fmt'], f'fmt{s["fmt"]}')
        flt = FILTER_NAMES.get(s['filter'], '?')
        print(f"{s['handle']:>6} {str(s['pos']):>12} {str(s['size']):>10} {str(s['draw']):>10} {fmt:>14} {flt:>9} 0x{s['src']:06X} {s['pclk']:>7}")


if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('bundle', nargs='?', default='_ft812_bundle_analysis')
    a = p.parse_args()
    analyze(a.bundle)
