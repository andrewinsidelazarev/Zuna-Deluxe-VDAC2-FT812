#!/usr/bin/env python3
"""
Zuma Deluxe VDAC2 — визуальный эмулятор поверх VDC chain physics, 640×480.
Логика VDC (detect_match3, do_gap_step, scan_for_new_match, animate_chain,
move_chain, try_spawn, insert_at, slot_pos PRESERVE) сохранена один-в-один
с 360×288-версией. Изменены только геометрические параметры (×2 scale) и
рендер канвы — для отладки 640×480-варианта под VDAC2.

Управление: только мышь.
- Движение мыши -> aim лягушки.
- ЛКМ -> выстрел шара текущего цвета.

Не использует никаких внешних библиотек кроме tkinter (стандартная Python поставка).
"""
import struct
import tkinter as tk
import random
import os
from dataclasses import dataclass, field

# ---------- Константы (синхронно с текущим asm: VDC.asm + MainLoop.asm) ----------
CELL_SIZE          = 32          # = VDC_CELL_SIZE в asm. 1 sample ≈ 1.08 px -> ≈ 34.6 px между centers.
DECAY_NEG_PER_FRAME = 2          # negative offsets (insert head slide) -> 0 быстро.
DECAY_POS_PER_FRAME = 1          # positive offsets (cascade rollback) -> 0 плавно (= коллега).
NUM_BALL_COLORS    = 6           # = VDC_NUM_COLORS
MAX_SLOTS          = 240         # = VDC_MAX_SLOTS
LEVEL_START_BALLS  = 35          # = VDC_LEVEL_START_BALLS
FAST_ADVANCE       = 12          # = VDC_FAST_ADVANCE
SPAWN_FRAME_MASK   = 63          # normal phase: VDC_TrySpawn only when frame&63 == 0
GAP_STEP_FRAMES    = CELL_SIZE
GAP_STOP           = 0xFE
GAP_CASCADE        = 0xFD
SHOT_SPEED         = 6           # px/frame (= MainLoop bullet step, 360×288 baseline)
DM3_OFFSET_GAP_MAX = CELL_SIZE // 2 + 2  # = VDC_DM3_OFFSET_GAP_MAX
BALL_DIAMETER      = 32          # = ZL_BALL_DIAM_PX (atlas cell 32×32)
BALL_RADIUS_VISUAL = 16          # = ZL_BALL_HALF
COLLISION_BBOX_HALF = 16         # = ZL_BALL_HALF

# Frog & screen (нативно 640×480 — VDAC2 / FT812 VGA)
SCR_W, SCR_H = 640, 480
RENDER_Y_OFFSET = 64             # ×2 от 32
# FROG позиция вычисляется динамически = killzone (track[-1]) при init.
# Размер sprite 128×128, центр в (cx, cy) = track[-1].
FROG_HALF = 64
SCALE = 1                         # окно нативно 640×480, без software scale

# Цвета шаров (R, G, B) — 6 цветов как в asm spritesheet (порядок: convert_balls24.py)
BALL_COLORS = {
    0: '#4080ff',                # blue
    1: '#40c040',                # green
    2: '#ffd040',                # yellow
    3: '#e04040',                # red
    4: '#c060c0',                # purple
    5: '#d0d0d0',                # white/grey
}

# ---------- TrackData loader ----------
# track_640.bin: word NumSamples + N × (X word, Y word, tangent byte) = stride 5.
# Уже native 640×480 после make_track_640.py — никакого scaling.
def load_track(path=None):
    if path is None:
        _here = os.path.dirname(os.path.abspath(__file__))
        _converted = os.path.join(os.path.abspath(os.path.join(_here, '..', '..')), 'Graphics', 'Converted')
        path = os.path.join(_converted, 'track_640.bin')
    data = open(path, 'rb').read()
    n = struct.unpack_from('<H', data, 0)[0]
    pts = []
    for i in range(n):
        x, y = struct.unpack_from('<hh', data, 2 + i * 5)
        pts.append((x, y))
    return pts

# ---------- VDC state ----------
def is_gap(v):
    return v >= NUM_BALL_COLORS

def sat_signed(v):
    if v < -128: return -128
    if v > 127:  return 127
    return v

@dataclass
class VDCState:
    slots: list = field(default_factory=lambda: [GAP_STOP] * MAX_SLOTS)
    offsets: list = field(default_factory=lambda: [0] * MAX_SLOTS)
    shot2: list = field(default_factory=lambda: [0] * MAX_SLOTS)
    # last_render_pos[i] = last (X, Y) where slot i was visibly drawn. Используется когда
    # t<0 (= шар «за стартом» во время cascade rollback) — рисуем на сохранённой позиции
    # вместо clamp в TrackData[0]. Эквивалент PRESERVE-логики в BcsPreClassify (asm).
    last_render_pos: list = field(default_factory=lambda: [None] * MAX_SLOTS)
    hsa: int = 0
    hsub: int = 0
    slots_len: int = 0
    chain_freeze_counter: int = 0       # пауза chain motion (hsub++) на N кадров после insert/cascade-close
    gap_step_counter: int = 0
    match_scan_idx: int = 0xFF
    balls_spawned: int = 0
    spawn_cluster_color: int = 0xFF
    spawn_cluster_rem: int = 0
    last_match_scan_idx: int = 0
    frame: int = 0
    # --- Scoring / Zuma bar (mirror of VDC.asm m3_have_marker + VDC_TickGaugeShown) ---
    gauge_score: int = 0            # true cumulative score for this level
    gauge_shown: int = 0            # displayed animated score (LERP to gauge_score @ STEP/frame)
    gauge_full: int = 0             # 1 when gauge_score >= GAUGE_TARGET
    stat_combos: int = 0
    stat_max_combo: int = 0
    stat_chain_count: int = 0       # consecutive explosions без miss-shot
    stat_max_chain: int = 0
    stat_prev_match_color: int = 0xFF
    player_score: int = 0           # cumulative for HUD
    # Gap-bonus tracking — обновляется когда летящий шар near GAP-слотов и не задел chain
    bullet_gap_min_dist: int = 255  # init=255, ползёт вниз во время полёта
    bullet_gap_count: int = 0       # consecutive gap-shots для ×2 multiplier


# --- Scoring constants (mirror VDC.asm + main.asm) ---
GAUGE_TARGET           = 1000       # HUD_GAUGE_TARGET (юзер 2026-05-20: lvl1 оригинал = 3000, but keep 1000 for now)
GAUGE_SHOWN_STEP       = 8          # очков/кадр в анимации бара
GAUGE_SPRITE_W         = 63         # HUD_PROGRESS_W
CHAIN_BONUS_THRESHOLD  = 5          # chain >= 5 + combo == 0 -> bonus
GAP_HIT_THR            = 24         # VDC_GAP_HIT_THR (Manhattan dist)
GAP_MAX                = 32         # VDC_GAP_MAX

class VDCEngine:
    def __init__(self, track, seed=0):
        self.track = track
        self.rng = random.Random(seed)
        self.s = VDCState()

    # --------- match detection с offset gap check ----------
    def detect_match3(self, idx):
        s = self.s
        if idx >= s.slots_len: return None
        c = s.slots[idx]
        if is_gap(c): return None
        # Adjacent idx (lower=forward, higher=behind) -> pixel_dist = 32 + offsets[fwd] - offsets[bhd].
        # Match-3 fires когда шары касаются ИЛИ overlap'ятся (pixel_dist в [0..32+GAP_MAX]).
        # Соответствует diff = offsets[fwd] - offsets[bhd] в [-32..GAP_MAX].
        # Левая граница (-32) допускает overlap при insert; правая (+18) допускает
        # свежую вставку на half-cell, но блокирует full cascade-gap (+32).
        lb = idx
        while lb > 0 and s.slots[lb-1] == c:
            d = s.offsets[lb-1] - s.offsets[lb]
            if d < -CELL_SIZE or d >= DM3_OFFSET_GAP_MAX: break
            lb -= 1
        rb = idx
        while rb < s.slots_len - 1 and s.slots[rb+1] == c:
            d = s.offsets[rb] - s.offsets[rb+1]
            if d < -CELL_SIZE or d >= DM3_OFFSET_GAP_MAX: break
            rb += 1
        if rb - lb + 1 < 3: return None
        return (lb, rb, rb - lb + 1, c)

    def check_match3(self, idx):
        m = self.detect_match3(idx)
        if not m: return False
        lb, rb, count, color = m
        s = self.s
        marker = GAP_STOP
        # CASCADE только если обе стороны — реальные шары одного цвета.
        # Если хотя бы одна сторона gap — это STOP (иначе два gap'а сравниваются как
        # равные и тригерят ложный cascade close с HSA-- и head rollback).
        if (lb > 0 and rb + 1 < s.slots_len
                and not is_gap(s.slots[lb-1])
                and not is_gap(s.slots[rb+1])
                and s.slots[lb-1] == s.slots[rb+1]):
            marker = GAP_CASCADE
        # --- Scoring (mirror VDC.asm m3_have_marker) ---
        s.stat_chain_count += 1
        if count > s.stat_max_chain:
            s.stat_max_chain = count
        # Combo: same-color streak
        if color == s.stat_prev_match_color:
            s.stat_combos += 1
            if s.stat_combos > s.stat_max_combo:
                s.stat_max_combo = s.stat_combos
        else:
            s.stat_combos = 0
            s.stat_prev_match_color = color
        # Points: base + (combo OR chain bonus, mutually exclusive)
        points = count * 10
        if s.stat_combos > 0:
            points += s.stat_combos * 100
        elif s.stat_chain_count >= CHAIN_BONUS_THRESHOLD:
            points += 100 + 10 * (s.stat_chain_count - CHAIN_BONUS_THRESHOLD)
        s.player_score += points
        s.gauge_score += points
        if s.gauge_score >= GAUGE_TARGET:
            s.gauge_full = 1
        # Hook for app-level logging (App sets this callback if needed)
        if getattr(self, 'on_match_log', None):
            self.on_match_log(count, color, points, marker)
        for k in range(lb, rb + 1):
            s.slots[k] = marker
            s.offsets[k] = 0
            s.shot2[k] = 0
        # NOTE 2026-05-20: преждевременная Shot2 propagation на lb-1/rb+1 убрана
        # (с repeatChance RNG соседи часто 3+ same color → ложный «двойной match-3
        # разных цветов» без gap closure). Cascade теперь через DoGapStep после
        # физического закрытия gap.
        # OLD: s.shot2[lb-1] = 1; s.shot2[rb+1] = 1
        # Триггерим первый gap_step немедленно — иначе chain motion в течение
        # waiting period (0..CS frames до hsub=0) двигает head вперёд, а должна
        # стоять и ждать хвост. С первым instant gap_step head получает +CS
        # offset compensation сразу -> stationary до конца decay phase.
        # Оставшиеся markers ждут hsub=0 (= 1 marker per gap_step call).
        self.do_gap_step()
        s.gap_step_counter = 0
        return True

    def do_gap_step(self):
        s = self.s
        def set_shot2_on_real_closure(k):
            # Trigger delayed match only when removing the gap joins two same-color balls.
            # Otherwise a pre-existing same-color run on one side can false-trigger.
            if k <= 0 or k >= s.slots_len:
                return
            left = s.slots[k - 1]
            right = s.slots[k]
            if is_gap(left) or is_gap(right) or left != right:
                return
            s.shot2[k - 1] = 1
            s.shot2[k] = 1

        # STOP from tail — HSA-- + head компенсация +CELL_SIZE. Tail НЕ компенсируем:
        # shift idx-=1 в сочетании с HSA-=1 автоматически сохраняет позицию tail-шаров.
        # Это даёт «как CASCADE»: chain shrinks by 1 cell, head smooth slides back 32 px,
        # tail балы остаются физически на месте -> без jerk'ов.
        for k in range(s.slots_len - 1, -1, -1):
            if s.slots[k] == GAP_STOP:
                for j in range(k, s.slots_len - 1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                    s.last_render_pos[j] = s.last_render_pos[j+1]
                s.last_render_pos[s.slots_len - 1] = None
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # NO chain_freeze here — head компенсация +CELL_SIZE декаится за CELL_SIZE кадров
                # параллельно с естественным chain motion (hsub++ wrap -> HSA++). Net = head стоит.
                set_shot2_on_real_closure(k)
                s.match_scan_idx = k
                return  # обрабатываем ОДИН маркер за вызов — иначе STOP+CASCADE в одном
                        # тике дают HSA-=2 без двойной компенсации -> рывок head назад на 32 px.
        # CASCADE from head
        for k in range(s.slots_len):
            if s.slots[k] == GAP_CASCADE:
                for j in range(k, s.slots_len - 1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                    s.last_render_pos[j] = s.last_render_pos[j+1]
                s.last_render_pos[s.slots_len - 1] = None
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                # Smooth rollback compensation, cap +CELL_SIZE — без cap'а несколько
                # cascade'ов подряд накапливают offset до 70+ -> head «зависает» на
                # десятки кадров пока offset не decay'ится до 0.
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # chain_freeze: head декаится без параллельного chain motion ->
                # head визуально откатывается на CELL_SIZE px назад за N кадров (видимый rollback).
                s.chain_freeze_counter = CELL_SIZE
                set_shot2_on_real_closure(k)
                s.match_scan_idx = k
                break

    def scan_for_new_match(self):
        s = self.s
        s.last_match_scan_idx = s.match_scan_idx
        for k in range(s.slots_len):
            if s.shot2[k] == 1:
                if is_gap(s.slots[k]):
                    s.shot2[k] = 0
                    continue
                if self.check_match3(k):
                    return True
                # No match. Keep pending until offsets near k settle; fresh insert
                # can become a valid match after half-cell slide decays.
                settled = (s.offsets[k] == 0)
                if k > 0:
                    settled = settled and (s.offsets[k-1] == 0)
                if k + 1 < s.slots_len:
                    settled = settled and (s.offsets[k+1] == 0)
                if settled:
                    s.shot2[k] = 0
        return False

    def clamp_offset_order(self):
        """Prevent a positive tail offset from visually moving in front of its head-side neighbor."""
        s = self.s
        for i in range(1, s.slots_len):
            if s.offsets[i] > 0 and s.offsets[i] > s.offsets[i - 1]:
                s.offsets[i] = s.offsets[i - 1]

    def animate_chain(self):
        s = self.s
        # Decay offsets toward 0 — asymmetric: insert head slide быстро, cascade rollback плавно.
        for k in range(s.slots_len):
            o = s.offsets[k]
            if o > 0:
                s.offsets[k] = max(0, o - DECAY_POS_PER_FRAME)
            elif o < 0:
                s.offsets[k] = min(0, o + DECAY_NEG_PER_FRAME)
        s.gap_step_counter += 1
        # Каждые GAP_STEP_FRAMES кадров (= CELL_SIZE) запускаем gap_step — синхронно
        # с decay (offsets +CS decay'ятся за CELL_SIZE/decay_pos = 32 кадров).
        # Без hsub=0 constraint, иначе зазор между decay-end и next gap_step -> head moves forward.
        if s.gap_step_counter >= GAP_STEP_FRAMES:
            s.gap_step_counter = 0
            self.do_gap_step()
        s.match_scan_idx = 0
        self.scan_for_new_match()

    def move_chain(self):
        s = self.s
        # chain_freeze: пауза hsub-увеличения на N кадров. Используется чтобы insert/cascade-close
        # head компенсация (offsets +/-CELL_SIZE) decay'илась без параллельного chain-motion'а,
        # иначе head съезжает на 2 cell вперёд за один insert вместо 1.
        if s.chain_freeze_counter > 0:
            s.chain_freeze_counter -= 1
            return
        s.hsub += 1
        if s.hsub >= CELL_SIZE:
            s.hsub = 0
            if s.hsa < len(self.track) // CELL_SIZE - 1:
                s.hsa += 1

    # --------- Spawn / Insert ----------
    def try_spawn(self, no_hsub_gate=False):
        s = self.s
        if s.gauge_full: return False               # Zuma bar full -> spawn gate OFF
        if s.slots_len >= MAX_SLOTS: return False
        if s.hsa < s.slots_len: return False
        # Спавнить только когда chain выровнен по cell-границе (hsub=0).
        # Fast phase mirrors asm VDC_TrySpawn_NoHsubGate.
        if not no_hsub_gate and s.hsub != 0: return False
        if s.spawn_cluster_rem > 0:
            s.spawn_cluster_rem -= 1
            candidate = s.spawn_cluster_color
        elif self.rng.randrange(2) == 0:
            candidate = self.rng.randint(0, NUM_BALL_COLORS - 1)
            s.spawn_cluster_rem = 0
        else:
            candidate = self.rng.randint(0, NUM_BALL_COLORS - 1)
            s.spawn_cluster_color = candidate
            total_len = self.rng.randint(1, NUM_BALL_COLORS - 1)
            s.spawn_cluster_rem = total_len - 1
        s.spawn_cluster_color = candidate
        s.slots[s.slots_len] = candidate
        # Offset нового шара = offset хвоста (или -delta*CELL_SIZE если цепь пуста).
        # Это даёт ровную cell-aligned дистанцию между новым шаром и хвостом
        # синхронно в их фазе decay'я. Никаких «дырок» между ними.
        if s.slots_len > 0:
            new_offset = s.offsets[s.slots_len - 1]
        else:
            delta = s.hsa - s.slots_len
            new_offset = sat_signed(-delta * CELL_SIZE) if delta > 0 else 0
        s.offsets[s.slots_len] = sat_signed(new_offset)
        s.shot2[s.slots_len] = 0
        s.last_render_pos[s.slots_len] = None
        s.slots_len += 1
        s.balls_spawned = min(255, s.balls_spawned + 1)  # mirror asm debug counter saturation
        return True

    def insert_at(self, target_idx, color):
        s = self.s
        if s.slots_len >= MAX_SLOTS: return False
        if target_idx > s.slots_len: target_idx = s.slots_len
        # Считаем offset нового шара ДО шифта: midpoint между head_neighbor и tail_neighbor
        # с учётом decay-state. Чистая midpoint формула (см. вывод в комментарии ниже).
        if s.slots_len == 0:
            head_off = 0; tail_off = 0
        elif target_idx == 0:
            head_off = s.offsets[0]; tail_off = s.offsets[0]
        elif target_idx == s.slots_len:
            head_off = s.offsets[target_idx - 1]; tail_off = s.offsets[target_idx - 1]
        else:
            head_off = s.offsets[target_idx - 1]; tail_off = s.offsets[target_idx]
        new_offset = -CELL_SIZE // 2 + (head_off + tail_off) // 2
        # Tail-side (idx target_idx..end -> target_idx+1..end+1): idx +1, HSA +1.
        # Эти эффекты на slot_t взаимно компенсируются -> offsets без изменений.
        for j in range(s.slots_len, target_idx, -1):
            s.slots[j] = s.slots[j-1]
            s.offsets[j] = s.offsets[j-1]
            s.shot2[j] = s.shot2[j-1]
            s.last_render_pos[j] = s.last_render_pos[j-1]
        # Новый шар: midpoint между head и tail соседями (учитывая decay-state).
        s.slots[target_idx] = color
        s.offsets[target_idx] = sat_signed(new_offset)
        s.shot2[target_idx] = 1
        s.last_render_pos[target_idx] = None
        s.slots_len += 1
        # HSA+1 = chain продвинулся на 1 cell вперёд (к killzone). Cap по track-end.
        if s.hsa < len(self.track) // CELL_SIZE - 1:
            s.hsa += 1
        # Head-side (idx 0..target_idx-1): idx тот же, HSA+1 -> +32 instant.
        # offsets -=CELL_SIZE компенсирует instant, декей возвращает к 0 за 32 кадра
        # -> плавный slide HEAD на 32 px вперёд. Cap'ним на -CELL_SIZE чтобы при
        # многократных insert/match offsets не уходили в большие отрицательные значения.
        for i in range(target_idx):
            s.offsets[i] = max(s.offsets[i] - CELL_SIZE, -CELL_SIZE)
        # NO freeze (= синхронно с asm `VDC_InsertAt`): head компенсация (-CS) decay'ится
        # параллельно с natural chain motion -> head «ускоренно уезжает вперёд на 2 cells
        # за CELL_SIZE кадров», без stutter'а паузы. См. коммент в VDC.asm после InsertAt.
        matched = self.check_match3(target_idx)
        if not matched:
            # Shot без match -> BreakChain (Statistics_BreakChain)
            s.stat_chain_count = 0
        self.clamp_offset_order()
        return matched

    # --------- Gauge bar animation ----------
    def tick_gauge_shown(self):
        s = self.s
        if s.gauge_shown < s.gauge_score:
            s.gauge_shown = min(s.gauge_shown + GAUGE_SHOWN_STEP, s.gauge_score)
        elif s.gauge_shown > s.gauge_score:
            s.gauge_shown = s.gauge_score  # быстрый откат (restart, etc)

    # --------- Gap-bonus detection ----------
    def update_bullet_gap_tracking(self, bx, by):
        """Per-frame во время полёта (когда BBOX не попал в chain): обновить min-dist
        от bullet до ближайшего GAP-слота."""
        s = self.s
        for i in range(s.slots_len):
            if not is_gap(s.slots[i]): continue
            pos = self.slot_pos(i)
            if pos is None: continue
            cx, cy = pos
            d = int(abs(bx - cx) + abs(by - cy))
            if d < s.bullet_gap_min_dist:
                s.bullet_gap_min_dist = d

    def reset_bullet_gap_tracking(self):
        self.s.bullet_gap_min_dist = 255

    def award_gap_bonus(self):
        """Bullet expired off-screen без hit'а. Если был gap-pass — начислить очки."""
        s = self.s
        if s.bullet_gap_min_dist <= GAP_HIT_THR:
            s.bullet_gap_count += 1
            bonus = max(10, GAP_MAX - s.bullet_gap_min_dist)
            if s.bullet_gap_count > 1:
                bonus *= 2
            s.player_score += bonus
            s.gauge_score += bonus
            if s.gauge_score >= GAUGE_TARGET:
                s.gauge_full = 1
        else:
            s.bullet_gap_count = 0
        # Shot exit ломает chain
        s.stat_chain_count = 0

    # --------- fill_px для прогресс-бара (mirror DrawHudProgress) ----------
    def fill_px(self):
        s = self.s
        if s.gauge_full:
            return GAUGE_SPRITE_W
        if s.gauge_shown == 0:
            return 0
        q = (s.gauge_shown * GAUGE_SPRITE_W) // GAUGE_TARGET
        if q == 0:
            q = 1
        return min(q, GAUGE_SPRITE_W)

    # --------- Compute slot's track-position ----------
    def slot_t(self, i):
        s = self.s
        return (s.hsa - i) * CELL_SIZE + s.hsub + s.offsets[i]

    def slot_pos(self, i):
        """Возвращает (X, Y) для рендера. PRESERVE-логика BcsPreClassify (VDC):
        при t<0 (шар «вылетел» за старт трека во время каскадного pullback) шар не
        исчезает, а остаётся на своей последней валидной позиции, пока offsets/HSA
        не вернут t в положительную зону. None только если шара ещё ни разу не
        рисовали (только что заспавнили, last_render_pos[i] == None)."""
        s = self.s
        t = self.slot_t(i)
        if t < 0:
            return s.last_render_pos[i]
        if t >= len(self.track):
            t = len(self.track) - 1
        pos = self.track[t]
        s.last_render_pos[i] = pos
        return pos

# ---------- Flying ball ----------
@dataclass
class FlyingBall:
    x: float
    y: float
    dx: float
    dy: float
    color: int
    active: bool = True

# ---------- App ----------
class App:
    def __init__(self, root):
        self.root = root
        self.root.title('VDC Visual Emulator — Zuma 640×480 (VDAC2)')
        # State log — append every frame for offline analysis
        _here = os.path.dirname(os.path.abspath(__file__))
        _root = os.path.abspath(os.path.join(_here, '..', '..'))
        log_path = os.path.join(_root, 'vdc_emulator_log.txt')
        self.log = open(log_path, 'w', buffering=1, encoding='utf-8')
        self.log.write('# frame slotsLen hsa hsub freeze scanIdx slots offsets shot2\n')
        self.cw = SCR_W * SCALE
        self.ch = (SCR_H + RENDER_Y_OFFSET) * SCALE
        self.canvas = tk.Canvas(root, width=self.cw, height=self.ch, bg='#202028')
        self.canvas.pack(side='left')
        self.info = tk.Label(root, font=('Consolas', 10), justify='left', anchor='nw', width=44, bg='#181818', fg='#cccccc')
        self.info.pack(side='right', fill='y')

        self.track = load_track()
        # FROG center = FROG_DEFAULT_X/Y из Frog.asm (hardcoded для level 1).
        self.frog_cx, self.frog_cy = 327, 231
        self.engine = VDCEngine(self.track, seed=42)
        # Attach scoring logger hook
        def _on_match(count, color, points, marker):
            mname = 'STOP' if marker == GAP_STOP else 'CASCADE'
            self.log.write(f'# MATCH frame={self.engine.s.frame} count={count} color={color} '
                           f'marker={mname} chain={self.engine.s.stat_chain_count} '
                           f'combo={self.engine.s.stat_combos} +{points} pts -> '
                           f'gauge={self.engine.s.gauge_score}\n')
        self.engine.on_match_log = _on_match
        self.flying = []
        self.next_color = self.rng_color()
        self.mouse_xy = (self.frog_cx, self.frog_cy - 50)
        self.spawn_timer = 0
        self.shot_cooldown = 0
        self.canvas.bind('<Motion>', self.on_motion)
        self.canvas.bind('<Button-1>', self.on_click)
        self.root.protocol('WM_DELETE_WINDOW', self.on_closing)
        # Pre-draw faint track outline
        self._track_drawn = False
        self.tick()

    def on_closing(self):
        try:
            self.log.close()
        except Exception:
            pass
        self.root.destroy()

    def rng_color(self):
        # Выбираем только из цветов, ещё представленных в цепочке — иначе игроку
        # выпадает «бесполезный» цвет которого нет где разрядить.
        s = self.engine.s
        colors = set()
        for i in range(s.slots_len):
            c = s.slots[i]
            if not is_gap(c):
                colors.add(c)
        if not colors:
            return random.randint(0, NUM_BALL_COLORS - 1)
        return random.choice(list(colors))

    def s2c(self, x, y):
        """game coords -> canvas coords (с шифтом по Y чтобы спавн-зона track[0..29] с y<0 была видна)"""
        return x * SCALE, (y + RENDER_Y_OFFSET) * SCALE

    def on_motion(self, e):
        # Convert canvas pixel back to game coords (с учётом RENDER_Y_OFFSET).
        gx = e.x / SCALE
        gy = e.y / SCALE - RENDER_Y_OFFSET
        self.mouse_xy = (gx, gy)

    def on_click(self, e):
        # Лог КАЖДОГО клика (включая cooldown'ы) — для отладки «само стреляет».
        gx, gy = e.x / SCALE, e.y / SCALE - RENDER_Y_OFFSET
        self.log.write(f'# CLICK frame={self.engine.s.frame} canvas=({e.x},{e.y}) game=({gx:.1f},{gy:.1f}) cooldown={self.shot_cooldown} color={self.next_color}\n')
        if self.shot_cooldown > 0: return
        # Direction from frog center to click
        dx = gx - self.frog_cx
        dy = gy - self.frog_cy
        mag = (dx*dx + dy*dy) ** 0.5
        if mag < 1e-3: return
        dx, dy = dx / mag * SHOT_SPEED, dy / mag * SHOT_SPEED
        self.log.write(f'# SHOT_FIRED frame={self.engine.s.frame} dir=({dx:.1f},{dy:.1f}) color={self.next_color}\n')
        # Spawn ball at frog center
        self.flying.append(FlyingBall(self.frog_cx, self.frog_cy, dx, dy, self.next_color))
        self.next_color = self.rng_color()
        self.shot_cooldown = 8
        self.engine.reset_bullet_gap_tracking()

    def update_flying(self):
        e = self.engine
        new_list = []
        for b in self.flying:
            if not b.active: continue
            b.x += b.dx
            b.y += b.dy
            # Off-screen -> drop (expire без hit -> gap-bonus award)
            if b.x < -32 or b.x > SCR_W + 32 or b.y < -32 or b.y > SCR_H + 32:
                pre_gauge = e.s.gauge_score
                e.award_gap_bonus()
                if e.s.gauge_score != pre_gauge:
                    self.log.write(f'# GAP_BONUS frame={e.s.frame} min_dist={e.s.bullet_gap_min_dist} '
                                   f'count={e.s.bullet_gap_count} +{e.s.gauge_score - pre_gauge} pts -> '
                                   f'gauge={e.s.gauge_score}\n')
                else:
                    self.log.write(f'# MISS frame={e.s.frame} (no gap, chain reset)\n')
                continue
            # Check collision with chain
            inserted = False
            for i in range(e.s.slots_len):
                if is_gap(e.s.slots[i]): continue
                pos = e.slot_pos(i)
                if pos is None: continue                  # pre-spawn (t<0) — нет коллизии
                cx, cy = pos
                ddx = b.x - cx
                ddy = b.y - cy
                # asm-style bbox: |dx|<14 && |dy|<14 (CheckBallChainCollisions, asm:2203/2215)
                if abs(ddx) < COLLISION_BBOX_HALF and abs(ddy) < COLLISION_BBOX_HALF:
                    # Hemisphere check: куда вставить — idx=i (новый шар вперёд idx i,
                    # head-side) или idx=i+1 (новый шар позади idx i, tail-side).
                    # Решаем по тому, к какому соседу bumped'а ближе летящий шар.
                    target_idx = i
                    prev_p = next_p = None
                    for k in range(i-1, -1, -1):
                        if not is_gap(e.s.slots[k]):
                            prev_p = e.slot_pos(k); break
                    for k in range(i+1, e.s.slots_len):
                        if not is_gap(e.s.slots[k]):
                            next_p = e.slot_pos(k); break
                    dist_prev = float('inf'); dist_next = float('inf')
                    if prev_p is not None:
                        dx_p = b.x - prev_p[0]; dy_p = b.y - prev_p[1]
                        dist_prev = dx_p*dx_p + dy_p*dy_p
                    if next_p is not None:
                        dx_n = b.x - next_p[0]; dy_n = b.y - next_p[1]
                        dist_next = dx_n*dx_n + dy_n*dy_n
                    if dist_next < dist_prev:
                        target_idx = i + 1
                    self.log.write(f'# COLLISION frame={e.s.frame} ball=({b.x:.1f},{b.y:.1f}) hit_idx={i} target_idx={target_idx} color={b.color}\n')
                    e.insert_at(target_idx, b.color)
                    inserted = True
                    break
            if not inserted:
                # Не попал в этом кадре — update gap-tracking (min Manhattan dist
                # до ближайшего GAP-слота в цепи)
                e.update_bullet_gap_tracking(b.x, b.y)
                new_list.append(b)
        self.flying = new_list

    def tick(self):
        import time as _t
        _t0 = _t.time()
        def _check(stage):
            el = _t.time() - _t0
            if el > 0.5:
                print(f'[SLOW TICK] frame={self.engine.s.frame} stage={stage} elapsed={el:.2f}s')
                self.log.write(f'# SLOW_TICK frame={self.engine.s.frame} stage={stage} elapsed={el:.2f}s\n')
        e = self.engine
        # Mirror asm VDC_Update:
        # fast phase: 12x MoveChain, then AnimateChain, then TrySpawn_NoHsubGate.
        # normal phase: MoveChain, AnimateChain, then TrySpawn every 64 frames.
        if e.s.balls_spawned < LEVEL_START_BALLS:
            for _ in range(FAST_ADVANCE):
                e.move_chain()
            _check('move_chain_fast')
            e.animate_chain()
            _check('animate_chain')
            e.try_spawn(no_hsub_gate=True)
            _check('try_spawn_fast')
        else:
            e.move_chain()
            _check('move_chain')
            e.animate_chain()
            _check('animate_chain')
            if (e.s.frame & SPAWN_FRAME_MASK) == 0:
                e.try_spawn()
            _check('try_spawn')
        e.tick_gauge_shown()                       # animate Zuma bar
        _check('tick_gauge_shown')
        self.update_flying()
        _check('update_flying')
        if self.shot_cooldown > 0:
            self.shot_cooldown -= 1
        e.s.frame += 1
        self.render()
        # Log state for offline analysis
        s = e.s
        slots_str = ''.join(
            ('S' if v == GAP_STOP else 'C' if v == GAP_CASCADE else '.' if v == 0xFF else str(v))
            for v in s.slots[:s.slots_len])
        offsets_str = ','.join(str(s.offsets[i]) for i in range(s.slots_len))
        shot2_str = ''.join(str(s.shot2[i]) for i in range(s.slots_len))
        self.log.write(f'{s.frame} {s.slots_len} {s.hsa} {s.hsub} {s.chain_freeze_counter} {s.match_scan_idx} '
                       f'[{slots_str}] [{offsets_str}] [{shot2_str}]\n')
        self.root.after(20, self.tick)

    def render(self):
        c = self.canvas
        c.delete('dyn')
        # Track outline (draw once, sparse points)
        if not self._track_drawn:
            # Линия на game y=0 — обозначает «настоящий» край экрана; всё выше = спавн-зона
            edge_y = self.s2c(0, 0)[1]
            c.create_line(0, edge_y, self.cw, edge_y, fill='#604030', width=1, dash=(4, 6), tags='track')
            for i in range(0, len(self.track), 8):
                x, y = self.track[i]
                cx, cy = self.s2c(x, y)
                c.create_oval(cx-1, cy-1, cx+1, cy+1, fill='#404048', outline='', tags='track')
            # killzone (×2)
            kx, ky = self.track[-1]
            cx, cy = self.s2c(kx, ky)
            c.create_oval(cx-24, cy-24, cx+24, cy+24, fill='#000000', outline='#ffaa00', width=2, tags='track')
            self._track_drawn = True

        # Chain balls
        e = self.engine
        for i in range(e.s.slots_len):
            slot = e.s.slots[i]
            if is_gap(slot): continue
            pos = e.slot_pos(i)
            if pos is None: continue                      # pre-spawn (t<0) -> не рисуем
            x, y = pos
            color = BALL_COLORS.get(slot, '#888')
            cx, cy = self.s2c(x, y)
            r = BALL_RADIUS_VISUAL * SCALE
            c.create_oval(cx-r, cy-r, cx+r, cy+r, fill=color, outline='#000', width=1, tags='dyn')

        # Flying balls
        for b in self.flying:
            color = BALL_COLORS.get(b.color, '#888')
            cx, cy = self.s2c(b.x, b.y)
            r = BALL_RADIUS_VISUAL * SCALE
            c.create_oval(cx-r, cy-r, cx+r, cy+r, fill=color, outline='#fff', width=1, tags='dyn')

        # Frog (128×128, ×2 от 64×64)
        fx, fy = self.s2c(self.frog_cx, self.frog_cy)
        c.create_oval(fx-32*SCALE, fy-32*SCALE, fx+32*SCALE, fy+32*SCALE,
                      fill='#406030', outline='#80c060', width=2, tags='dyn')
        c.create_text(fx, fy, text='🐸', font=('Segoe UI Emoji', 36*SCALE), tags='dyn')

        # Aim line
        mx, my = self.mouse_xy
        mx2, my2 = self.s2c(mx, my)
        c.create_line(fx, fy, mx2, my2, fill='#ffffff', width=1, dash=(2, 4), tags='dyn')

        # Preview ball at frog mouth (×2)
        prev_color = BALL_COLORS.get(self.next_color, '#888')
        c.create_oval(fx-12*SCALE, fy-12*SCALE, fx+12*SCALE, fy+12*SCALE,
                      fill=prev_color, outline='#fff', tags='dyn')

        # --- Zuma progress bar (top-right) ---
        bar_x, bar_y, bar_w, bar_h = 540, 40, 63, 19
        bx0, by0 = self.s2c(bar_x, bar_y)
        bx1, by1 = self.s2c(bar_x + bar_w, bar_y + bar_h)
        # Red socket background
        c.create_rectangle(bx0, by0, bx1, by1, fill='#601015', outline='#a06030', width=1, tags='dyn')
        fill = e.fill_px()
        if fill > 0:
            fx1, fy1 = self.s2c(bar_x + fill, bar_y + bar_h)
            colr = '#40e040' if e.s.gauge_full else '#ffd040'
            c.create_rectangle(bx0, by0, fx1, fy1, fill=colr, outline='', tags='dyn')
        # bar label
        lx, ly = self.s2c(bar_x + bar_w // 2, bar_y - 8)
        c.create_text(lx, ly, text=f'{e.s.gauge_shown}/{GAUGE_TARGET}', font=('Consolas', 8), fill='#ffd080', tags='dyn')

        # Info panel
        s = e.s
        info = []
        info.append(f'Frame:        {s.frame}')
        info.append(f'SlotsLen:     {s.slots_len}/{MAX_SLOTS}')
        info.append(f'HSA:          {s.hsa}')
        info.append(f'HSub:         {s.hsub}/{CELL_SIZE}')
        info.append(f'FreezeCnt:    {s.chain_freeze_counter}')
        info.append(f'GapStepCnt:   {s.gap_step_counter}/{GAP_STEP_FRAMES}')
        info.append(f'BallsSpawned: {s.balls_spawned}')
        info.append(f'Flying balls: {len(self.flying)}')
        info.append(f'Next color:   {self.next_color}')
        info.append('')
        info.append('--- Scoring ---')
        info.append(f'PlayerScore:  {s.player_score}')
        info.append(f'GaugeScore:   {s.gauge_score}')
        info.append(f'GaugeShown:   {s.gauge_shown}  fill={e.fill_px()}/{GAUGE_SPRITE_W} px')
        info.append(f'GaugeFull:    {s.gauge_full}')
        info.append(f'Chain:        {s.stat_chain_count} (max {s.stat_max_chain})')
        info.append(f'Combo:        {s.stat_combos} (max {s.stat_max_combo})')
        info.append(f'GapMinDist:   {s.bullet_gap_min_dist}')
        info.append(f'GapCount:     {s.bullet_gap_count}')
        info.append('')
        info.append('--- Slot states ---')
        info.append('idx slot off shot2')
        for i in range(min(s.slots_len + 2, 30)):
            slot = s.slots[i]
            if slot == GAP_STOP: ss = 'STOP'
            elif slot == GAP_CASCADE: ss = 'CASC'
            elif slot == 0xFF: ss = '.'
            else: ss = str(slot)
            mark = ''
            if i == s.slots_len - 1: mark = ' tail'
            elif i >= s.slots_len: mark = ' >>'
            info.append(f'{i:3d} {ss:>4} {s.offsets[i]:4d} {s.shot2[i]}{mark}')
        self.info.config(text='\n'.join(info))

if __name__ == '__main__':
    root = tk.Tk()
    app = App(root)
    root.mainloop()
