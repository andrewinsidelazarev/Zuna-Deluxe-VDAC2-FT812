#!/usr/bin/env python3
"""
VDC test runner — programmatic scenarios для VDC engine из vdc_visual_emulator.py.
Не открывает GUI — прогоняет тесты, печатает state evolution и pass/fail.
"""
import sys
sys.path.insert(0, 'c:/z80/zuma')
from vdc_visual_emulator import VDCEngine, GAP_STOP, GAP_CASCADE, NUM_BALL_COLORS, MAX_SLOTS, CELL_SIZE, GAP_STEP_FRAMES, is_gap, load_track

def fmt_slot(v):
    if v == GAP_STOP: return 'S'
    if v == GAP_CASCADE: return 'C'
    if v == 0xFF: return '.'
    return str(v)

def chain_str(s):
    return ''.join(fmt_slot(s.slots[i]) for i in range(s.slots_len))

def offsets_str(s):
    return ' '.join(f'{s.offsets[i]:+3d}' for i in range(s.slots_len))

def run_scenario(name, setup, expectations, max_frames=200):
    print(f'\n=== {name} ===')
    track = load_track()
    e = VDCEngine(track, seed=0)
    setup(e)
    print(f'  init: chain={chain_str(e.s)} hsa={e.s.hsa} stalled={e.s.chain_stalled}')

    history = []
    for f in range(max_frames):
        e.s.frame = f
        e.move_chain()
        e.animate_chain()
        history.append({
            'frame': f, 'slots_len': e.s.slots_len, 'chain': chain_str(e.s),
            'offsets': list(e.s.offsets[:e.s.slots_len]),
            'stalled': e.s.chain_stalled, 'hsa': e.s.hsa,
        })

    # Run expectations against history
    all_passed = True
    for desc, fn in expectations:
        try:
            ok, info = fn(history, e)
        except Exception as ex:
            ok, info = False, f'EXCEPTION: {ex}'
        status = 'OK ' if ok else 'FAIL'
        all_passed = all_passed and ok
        print(f'  {status}  {desc}: {info}')
    return all_passed


def setup_match3_stop(e):
    """Place 3 same-color balls at slots [5,6,7], surrounded by different colors."""
    e.s.slots_len = 10
    e.s.slots[:10] = [0, 1, 0, 1, 0, 2, 2, 2, 0, 1]
    e.s.offsets[:10] = [0]*10
    e.s.hsa = 20
    e.s.hsub = 0
    # Mark insert spot for match scan
    e.s.shot2[6] = 1
    e.s.match_scan_idx = 6


def setup_match3_cascade(e):
    """Match-3 with same-color neighbors → CASCADE marker."""
    e.s.slots_len = 11
    # slots[3..7] = X, X, [color, color, color], X = X — neighbors of match (slot 4 and 8) same color
    # Actually CASCADE fires when slots[lb-1] == slots[rb+1]
    e.s.slots[:11] = [0, 1, 1, 2, 2, 2, 1, 0, 0, 0, 1]   # match 2,2,2 at [3,4,5]; neighbors lb-1=2 (color 1), rb+1=6 (color 1) — same!
    e.s.offsets[:11] = [0]*11
    e.s.hsa = 20
    e.s.hsub = 0
    e.s.shot2[4] = 1
    e.s.match_scan_idx = 4


def expect_match_fires(history, e):
    """Within history, does match-3 successfully fire (= chain shrinks)?"""
    initial_len = history[0]['slots_len']
    for h in history:
        if h['slots_len'] < initial_len:
            return True, f'chain shrank to {h["slots_len"]} at frame {h["frame"]}'
    return False, f'chain never shrank (still {initial_len})'


def expect_smooth_rollback(history, e):
    """Head-side balls offset progression should be gradual (not instant 0→-12 or -12→0)."""
    # Look at slot 0 offset over time. Should change gradually.
    if history[0]['slots_len'] == 0: return True, 'no chain'
    offsets_t = [h['offsets'][0] if len(h['offsets']) > 0 else 0 for h in history]
    # Find max absolute change between consecutive frames
    max_jump = 0
    for i in range(1, len(offsets_t)):
        d = abs(offsets_t[i] - offsets_t[i-1])
        if d > max_jump: max_jump = d
    # Expect max_jump <= 1 (= smooth)
    return max_jump <= 1, f'max single-frame offset jump = {max_jump} px (slot 0)'


def expect_settles_to_zero(history, e):
    """All offsets should decay to 0 within max_frames."""
    last = history[-1]
    if last['slots_len'] == 0: return True, 'chain empty'
    nonzero = [(i, o) for i, o in enumerate(last['offsets']) if o != 0]
    return len(nonzero) == 0, f'{len(nonzero)} offsets non-zero: {nonzero[:5]}'


def expect_no_stall_after_settle(history, e):
    """After all offsets settle, chain_stalled should be 0."""
    return e.s.chain_stalled == 0, f'final chain_stalled={e.s.chain_stalled}'


def run_all():
    results = []
    results.append(run_scenario(
        'Match-3 STOP (no same-color neighbors)',
        setup_match3_stop,
        [('match fires', expect_match_fires),
         ('rollback offset jump <=1 px/frame', expect_smooth_rollback),
         ('offsets settle to 0', expect_settles_to_zero),
         ('chain unstalled at end', expect_no_stall_after_settle)],
    ))
    results.append(run_scenario(
        'Match-3 CASCADE (same-color neighbors)',
        setup_match3_cascade,
        [('match fires', expect_match_fires),
         ('rollback offset jump <=1 px/frame', expect_smooth_rollback),
         ('offsets settle to 0', expect_settles_to_zero),
         ('chain unstalled at end', expect_no_stall_after_settle)],
    ))

    print('\n' + '='*60)
    if all(results):
        print('ALL TESTS PASSED')
    else:
        print(f'SOME TESTS FAILED ({sum(1 for r in results if not r)}/{len(results)})')

if __name__ == '__main__':
    run_all()
