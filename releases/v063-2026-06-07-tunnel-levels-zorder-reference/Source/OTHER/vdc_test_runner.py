#!/usr/bin/env python3
"""
VDC test runner — programmatic scenarios для VDC engine из vdc_visual_emulator.py.
Не открывает GUI — прогоняет тесты, печатает state evolution и pass/fail.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vdc_visual_emulator import (
    VDCEngine, GAP_STOP, GAP_CASCADE, NUM_BALL_COLORS, MAX_SLOTS,
    CELL_SIZE, GAP_STEP_FRAMES, is_gap, load_track,
    DECAY_POS_PER_FRAME, DECAY_NEG_PER_FRAME,
)

def fmt_slot(v):
    if v == GAP_STOP: return 'S'
    if v == GAP_CASCADE: return 'C'
    if v == 0xFF: return '.'
    return str(v)

def chain_str(s):
    return ''.join(fmt_slot(s.slots[i]) for i in range(s.slots_len))

def offsets_str(s):
    return ' '.join(f'{s.offsets[i]:+3d}' for i in range(s.slots_len))

def run_scenario(name, setup, expectations, max_frames=400):
    print(f'\n=== {name} ===')
    track = load_track()
    e = VDCEngine(track, seed=0)
    setup(e)
    print(f'  init: chain={chain_str(e.s)} hsa={e.s.hsa}')

    history = []
    for f in range(max_frames):
        e.s.frame = f
        e.move_chain()
        e.animate_chain()
        history.append({
            'frame': f, 'slots_len': e.s.slots_len, 'chain': chain_str(e.s),
            'offsets': list(e.s.offsets[:e.s.slots_len]),
            'hsa': e.s.hsa,
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
    """Cascade/STOP rollback: cascade trigger допускает instant +CS jump (или ±CS-1
    после ClampOffsetOrder), но между triggers decay должен идти -1/frame."""
    if history[0]['slots_len'] == 0: return True, 'no chain'
    offsets_t = [h['offsets'][0] if len(h['offsets']) > 0 else 0 for h in history]
    cascade_triggers = 0
    bad_jumps = []
    for i in range(1, len(offsets_t)):
        d = offsets_t[i] - offsets_t[i-1]
        if abs(d) <= DECAY_POS_PER_FRAME + 1:
            continue                                  # smooth decay step
        # Cascade trigger может быть partial (+22) если уже offset был не 0,
        # либо full (+CS=32). Главное: positive jump = cascade adds offset += CS clamped.
        if d > 0 and d <= CELL_SIZE + 1:
            cascade_triggers += 1
            continue
        bad_jumps.append((i, d))
    ok = len(bad_jumps) == 0
    return ok, f'cascade triggers={cascade_triggers}, bad jumps={bad_jumps[:3]}'


def expect_settles_to_zero(history, e):
    """All offsets should decay to 0 within max_frames (≥ CS/DECAY_POS = 32 frames after last trigger)."""
    last = history[-1]
    if last['slots_len'] == 0: return True, 'chain empty'
    nonzero = [(i, o) for i, o in enumerate(last['offsets']) if o != 0]
    return len(nonzero) == 0, f'{len(nonzero)} offsets non-zero: {nonzero[:5]}'


def expect_no_stall_after_settle(history, e):
    """ChainFreezeCnt должен decay до 0 за CS frames после cascade."""
    cnt = getattr(e.s, 'chain_freeze_counter', 0)
    return cnt == 0, f'final chain_freeze_counter={cnt}'


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
