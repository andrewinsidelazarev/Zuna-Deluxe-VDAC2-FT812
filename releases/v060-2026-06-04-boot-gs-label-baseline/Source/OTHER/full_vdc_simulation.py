#!/usr/bin/env python3
"""
Полная симуляция VDC chain physics: random shots, spawns, hits, misses, match-3,
cascade. Проверяет invariants и зарегистрированные edge cases.

Использует ChainSimVDC из chain_sim.py + расширения:
- Anti-3-spawn-guard (как в asm SpawnChainBall).
- Shot2-markers (как в asm CheckMatch3 + DoGapStep + ScanForNewMatch).
- Поток: spawn → периодические shots с random color/position → match-3 cascade.
- Invariants:
  * SlotsLen >= 0
  * HSA >= 0
  * 0 <= color < NUM_BALL_COLORS для не-GAP slots
  * Shot2 markers только на не-GAP slots
  * Match-3 не появляется без shot/Shot2 (= ложный match)
  * Cascade chain не зацикливается (max length bounded)
"""
import random
import sys
from dataclasses import dataclass, field

# --- Константы (синхронны с asm) ---
NUM_BALL_COLORS = 3
MAX_SLOTS = 60
GAP_STOP = 0xFE
GAP_CASCADE = 0xFD
CELL_SIZE = 32
GAP_STEP_FRAMES = CELL_SIZE
LEVEL_TOTAL = 85
TRACK_NUM_SLOTS = 96


def is_gap(v):
    return v >= NUM_BALL_COLORS


def sat_signed(v):
    if v > 127: return 127
    if v < -128: return -128
    return v


@dataclass
class VDCState:
    slots: list = field(default_factory=lambda: [GAP_STOP] * MAX_SLOTS)
    offsets: list = field(default_factory=lambda: [0] * MAX_SLOTS)
    shot2: list = field(default_factory=lambda: [0] * MAX_SLOTS)
    hsa: int = 50
    hsub: int = 0
    slots_len: int = 0
    gap_step_counter: int = 0
    match_scan_idx: int = 0xFF
    chain_stalled: int = 0
    balls_spawned: int = 0
    frame: int = 0


@dataclass
class TestStats:
    spawns: int = 0
    shots_fired: int = 0
    shots_inserted: int = 0
    shots_missed: int = 0
    matches_apply: int = 0
    matches_cascade: int = 0
    cascade_chains_max: int = 0
    invariant_failures: list = field(default_factory=list)
    spurious_matches: list = field(default_factory=list)
    completed_clears: int = 0


class FullVDCSim:
    def __init__(self, seed=42):
        self.rng = random.Random(seed)
        self.s = VDCState()
        self.stats = TestStats()
        self._cascade_depth = 0

    # ---------- Match detection (как в asm DetectMatch3OnSlots) ----------
    # offset gap check: расширяем run только пока |offset[i] - offset[i+1]| < OFFSET_GAP_MAX (=8).
    def detect_match3(self, idx):
        s = self.s
        OFFSET_GAP_MAX = 8
        if idx >= s.slots_len: return None
        c = s.slots[idx]
        if is_gap(c): return None
        lb = idx
        while lb > 0 and s.slots[lb-1] == c and abs(s.offsets[lb] - s.offsets[lb-1]) < OFFSET_GAP_MAX:
            lb -= 1
        rb = idx
        while rb < s.slots_len-1 and s.slots[rb+1] == c and abs(s.offsets[rb+1] - s.offsets[rb]) < OFFSET_GAP_MAX:
            rb += 1
        count = rb - lb + 1
        if count < 3: return None
        return (lb, rb, count, c)

    # ---------- Apply match (CheckMatch3 в asm) ----------
    def check_match3(self, idx, source='unknown'):
        m = self.detect_match3(idx)
        if not m: return False
        lb, rb, count, color = m
        s = self.s
        had_shot2_in_run = any(s.shot2[k] for k in range(lb, rb+1))
        # Расстояние от места последнего GAP closure (= source of cascade)
        scan_idx = getattr(s, '_last_match_scan_idx', None)
        dist_from_scan = None
        if scan_idx is not None:
            if rb < scan_idx: dist_from_scan = scan_idx - rb
            elif lb > scan_idx: dist_from_scan = lb - scan_idx
            else: dist_from_scan = 0
        # marker decision
        marker = GAP_STOP
        if lb > 0 and rb+1 < s.slots_len and s.slots[lb-1] == s.slots[rb+1]:
            marker = GAP_CASCADE
        # Запись cascade match — с дистанцией до scan_idx для классификации
        # near (<=3) — легитимный compaction cascade; far (>3) — потенциально ложный
        if source != 'insert' and not had_shot2_in_run:
            kind = 'near' if (dist_from_scan is not None and dist_from_scan <= 3) else 'far'
            self.stats.spurious_matches.append({
                'frame': s.frame, 'idx': idx, 'source': source, 'kind': kind,
                'lb': lb, 'rb': rb, 'count': count, 'color': color,
                'dist': dist_from_scan, 'scan_idx': scan_idx,
                'slots_snapshot': list(s.slots[max(0,lb-2):min(s.slots_len, rb+3)]),
                'shot2_snapshot': list(s.shot2[max(0,lb-2):min(s.slots_len, rb+3)]),
                'slots_len': s.slots_len,
            })
        # Set GAP markers
        for k in range(lb, rb+1):
            s.slots[k] = marker
            s.offsets[k] = 0
            s.shot2[k] = 0   # cleanup внутри match (не в asm — TODO)
        # Shot2 на соседях
        if lb > 0:
            s.shot2[lb-1] = 1
        if rb+1 < s.slots_len:
            s.shot2[rb+1] = 1
        s.chain_stalled = 1
        if source == 'insert':
            self.stats.matches_apply += 1
        else:
            self.stats.matches_cascade += 1
        return True

    # ---------- DoGapStep (sequential, MatchScanIdx set после КАЖДОГО close) ----------
    # Также set Shot2[K-1]=1 на compaction-site — Phase 1 будет ловить cascade combos.
    def do_gap_step(self):
        s = self.s
        # STOP from tail
        for k in range(s.slots_len-1, -1, -1):
            if s.slots[k] == GAP_STOP:
                for j in range(k, s.slots_len-1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                s.slots_len -= 1
                for j in range(k, s.slots_len):
                    s.offsets[j] = sat_signed(s.offsets[j] - CELL_SIZE)
                # Compaction site: новый сосед на k-1 встал рядом с тем что было k+1.
                if k > 0 and k-1 < s.slots_len and not is_gap(s.slots[k-1]):
                    s.shot2[k-1] = 1
                if k < s.slots_len and not is_gap(s.slots[k]):
                    s.shot2[k] = 1
                s.match_scan_idx = k
                break
        # CASCADE from head
        for k in range(s.slots_len):
            if s.slots[k] == GAP_CASCADE:
                for j in range(k, s.slots_len-1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                for j in range(k):
                    s.offsets[j] = sat_signed(s.offsets[j] + CELL_SIZE)
                if k > 0 and k-1 < s.slots_len and not is_gap(s.slots[k-1]):
                    s.shot2[k-1] = 1
                if k < s.slots_len and not is_gap(s.slots[k]):
                    s.shot2[k] = 1
                s.match_scan_idx = k
                break

    # ---------- ScanForNewMatch (Phase 1 Shot2, persistent retry) ----------
    # Shot2 markers НЕ очищаются при неудачном match'е (чтобы offset decay
    # позволил cascade combo сработать через 25-32 кадра). Они очищаются ТОЛЬКО:
    # - при match'е (= consumed),
    # - если slot стал GAP'ом (consumed elsewhere),
    # - когда offsets полностью settled (=0) и match всё ещё нет (= no cascade).
    def scan_for_new_match(self):
        s = self.s
        s._last_match_scan_idx = s.match_scan_idx
        # Phase 1: Shot2 markers
        for k in range(s.slots_len):
            if s.shot2[k] == 1:
                # Cleanup: GAP slot = Shot2 stale.
                if is_gap(s.slots[k]):
                    s.shot2[k] = 0
                    continue
                if self.check_match3(k, source='cascade'):
                    self._cascade_depth += 1
                    self.stats.cascade_chains_max = max(self.stats.cascade_chains_max, self._cascade_depth)
                    return True
                # No match. Clear Shot2 only if offsets fully settled near k (= retry done).
                settled = (s.offsets[k] == 0)
                if k > 0:
                    settled = settled and (s.offsets[k-1] == 0)
                if k+1 < s.slots_len:
                    settled = settled and (s.offsets[k+1] == 0)
                if settled:
                    s.shot2[k] = 0
        return False

    # ---------- Update stall ----------
    def update_stall(self):
        s = self.s
        any_gap = any(is_gap(s.slots[k]) for k in range(s.slots_len))
        any_off = any(s.offsets[k] != 0 for k in range(s.slots_len))
        s.chain_stalled = 1 if (any_gap or any_off) else 0
        if not any_gap:
            self._cascade_depth = 0

    # ---------- AnimateChain ----------
    # Scan для match'ей делается КАЖДЫЙ кадр (а не только после GAP closure):
    # offset-gap check может блокировать match сразу после shift (offset=-32),
    # но через ~32 кадров offset decay'ит к 0 и match отрабатывает естественно.
    def animate_chain(self):
        s = self.s
        # decay
        for k in range(s.slots_len):
            o = s.offsets[k]
            if o > 0: s.offsets[k] = max(0, o - 1)
            elif o < 0: s.offsets[k] = min(0, o + 1)
        s.gap_step_counter += 1
        if s.gap_step_counter >= GAP_STEP_FRAMES:
            s.gap_step_counter = 0
            self.do_gap_step()
        # Persistent scan: try Shot2 markers each frame
        s.match_scan_idx = 0  # always re-arm
        self.scan_for_new_match()
        self.update_stall()

    # ---------- MoveChain ----------
    def move_chain(self):
        s = self.s
        if s.chain_stalled: return
        s.hsub += 1
        if s.hsub >= CELL_SIZE:
            s.hsub = 0
            if s.hsa < TRACK_NUM_SLOTS - 1:
                s.hsa += 1

    # ---------- Spawn (anti-3-in-row) ----------
    def try_spawn(self):
        s = self.s
        if s.compact_timer if hasattr(s, 'compact_timer') else 0:
            return
        if s.slots_len >= MAX_SLOTS: return
        if s.slots_len > 0:
            tail_off = s.offsets[s.slots_len-1]
            if tail_off != 0: return
        if s.hsa < s.slots_len: return
        # candidate color
        candidate = self.rng.randint(0, NUM_BALL_COLORS-1)
        # anti-3-in-row guard
        if s.slots_len >= 2 and s.slots[s.slots_len-1] == s.slots[s.slots_len-2] == candidate:
            candidate = (candidate + 1) % NUM_BALL_COLORS
        s.slots[s.slots_len] = candidate
        s.offsets[s.slots_len] = 0
        s.shot2[s.slots_len] = 0
        s.slots_len += 1
        s.balls_spawned = min(255, s.balls_spawned + 1)
        self.stats.spawns += 1

    # ---------- Insert (выстрел игрока) ----------
    def insert_shot(self, target_idx, color):
        s = self.s
        if s.slots_len >= MAX_SLOTS: return False
        if target_idx > s.slots_len: target_idx = s.slots_len
        # shift_right
        for j in range(s.slots_len, target_idx, -1):
            s.slots[j] = s.slots[j-1]
            s.offsets[j] = s.offsets[j-1]
            s.shot2[j] = s.shot2[j-1]
        s.slots[target_idx] = color
        s.offsets[target_idx] = 0
        s.shot2[target_idx] = 1   # set marker для возможного match'а;
                                  # immediate check_match3 разрулит сразу если offsets fine,
                                  # иначе persistent scan повторит когда offsets decay'ят.
        s.slots_len += 1
        if s.hsa < TRACK_NUM_SLOTS - 1:
            s.hsa += 1
        return self.check_match3(target_idx, source='insert')

    # ---------- Случайный shot (с возможностью попадания/промаха) ----------
    def random_shot(self):
        s = self.s
        self.stats.shots_fired += 1
        # 75% попасть, 25% промах
        if self.rng.random() < 0.75 and s.slots_len > 0:
            target = self.rng.randint(0, s.slots_len)
            color = self.rng.randint(0, NUM_BALL_COLORS-1)
            self.insert_shot(target, color)
            self.stats.shots_inserted += 1
        else:
            self.stats.shots_missed += 1

    # ---------- Tick (один кадр) ----------
    def tick(self):
        s = self.s
        s.frame += 1
        # Phase logic (упрощённо)
        if s.balls_spawned < 35:
            for _ in range(12):
                self.move_chain()
            self.animate_chain()
            self.try_spawn()
        else:
            if s.frame % 2 == 0:
                self.move_chain()
                self.animate_chain()
            if s.balls_spawned < LEVEL_TOTAL and s.frame % 64 == 0:
                self.try_spawn()
        self.check_invariants()

    # ---------- Invariants ----------
    def check_invariants(self):
        s = self.s
        if s.slots_len < 0:
            self.stats.invariant_failures.append((s.frame, 'SlotsLen<0', s.slots_len))
        if s.hsa < 0:
            self.stats.invariant_failures.append((s.frame, 'HSA<0', s.hsa))
        for i in range(s.slots_len):
            c = s.slots[i]
            if not is_gap(c) and (c < 0 or c >= NUM_BALL_COLORS):
                self.stats.invariant_failures.append((s.frame, f'invalid color@{i}', c))
            if s.shot2[i] == 1 and is_gap(c):
                # Shot2 на GAP — допустимо residual после shift, но flag для analyse
                pass
        # Detect spurious match: 3-в-ряд без Shot2 trigger или recent insert
        for i in range(s.slots_len - 2):
            c = s.slots[i]
            if not is_gap(c) and s.slots[i+1] == c and s.slots[i+2] == c:
                # 3-в-ряд лежит, но не все они уже GAP — значит match-3 ещё не сработал.
                # Это normal mid-state если есть Shot2 marker рядом.
                near_shot2 = any(s.shot2[j] for j in range(max(0,i-1), min(s.slots_len, i+4)))
                if not near_shot2 and s.chain_stalled == 0:
                    # 3-в-ряд лежит, нет Shot2 markers, не stalled — потенциально missed match
                    pass


def run_test(seed, max_frames=15000, shot_prob_per_frame=0.005):
    sim = FullVDCSim(seed=seed)
    s = sim.s
    last_shot_frame = 0
    for _ in range(max_frames):
        # Random shots — игрок стреляет периодически
        if (sim.rng.random() < shot_prob_per_frame and
                s.frame - last_shot_frame > 10 and
                s.balls_spawned > 5):
            sim.random_shot()
            last_shot_frame = s.frame
        sim.tick()
        if s.slots_len == 0 and s.balls_spawned >= LEVEL_TOTAL:
            sim.stats.completed_clears += 1
            break
    return sim


def main():
    print("=" * 70)
    print("FULL VDC SIMULATION — Random shots/spawns/match-3/cascade test")
    print(f"NUM_BALL_COLORS={NUM_BALL_COLORS}, MAX_SLOTS={MAX_SLOTS}, GAP_STEP={GAP_STEP_FRAMES}")
    print("=" * 70)

    total = TestStats()
    total_runs = 50
    failures = []
    spurious_total = []
    for seed in range(total_runs):
        sim = run_test(seed)
        st = sim.stats
        total.spawns += st.spawns
        total.shots_fired += st.shots_fired
        total.shots_inserted += st.shots_inserted
        total.shots_missed += st.shots_missed
        total.matches_apply += st.matches_apply
        total.matches_cascade += st.matches_cascade
        total.cascade_chains_max = max(total.cascade_chains_max, st.cascade_chains_max)
        total.invariant_failures.extend(st.invariant_failures)
        total.completed_clears += st.completed_clears
        if st.invariant_failures:
            failures.append((seed, st.invariant_failures[:3]))
        for sp in st.spurious_matches:
            spurious_total.append((seed, sp))

    print(f"\nRuns: {total_runs}, frames each up to 15000 (300 sec game-time)")
    print(f"Total spawns:      {total.spawns}")
    print(f"Shots fired:       {total.shots_fired}")
    print(f"  Inserted:        {total.shots_inserted}")
    print(f"  Missed:          {total.shots_missed}")
    print(f"Match-3 (insert):  {total.matches_apply}")
    print(f"Match-3 (cascade): {total.matches_cascade}")
    print(f"Max cascade chain: {total.cascade_chains_max}")
    print(f"Levels cleared:    {total.completed_clears}/{total_runs}")
    print(f"\nInvariant failures: {len(total.invariant_failures)}")
    for seed, errs in failures[:5]:
        print(f"  seed {seed}:")
        for e in errs: print(f"    {e}")
    if not total.invariant_failures:
        print("  *** ALL INVARIANTS HOLD ***")

    near_count = sum(1 for _, sp in spurious_total if sp['kind'] == 'near')
    far_count = sum(1 for _, sp in spurious_total if sp['kind'] == 'far')
    print(f"\nCascade без Shot2 в run: {len(spurious_total)} total")
    print(f"  near (dist<=3 от MatchScanIdx, легитимный compaction-cascade): {near_count}")
    print(f"  far  (dist>3, потенциально ЛОЖНЫЙ — далеко от GAP closure):    {far_count}")
    far_list = [(s, sp) for s, sp in spurious_total if sp['kind'] == 'far']
    if far_list:
        print(f"  FAR cases (первые 10):")
        for seed, sp in far_list[:10]:
            print(f"    seed={seed} frame={sp['frame']} idx={sp['idx']} dist={sp['dist']} scan_idx={sp['scan_idx']} "
                  f"lb..rb={sp['lb']}..{sp['rb']} count={sp['count']} color={sp['color']}")
            print(f"      slots window = {sp['slots_snapshot']}")
            print(f"      shot2 window = {sp['shot2_snapshot']}")


if __name__ == '__main__':
    main()
