#!/usr/bin/env python3
"""
Zuma Deluxe VDAC2 — визуальный эмулятор поверх VDC chain physics, 640×480.
Логика VDC (detect_match3, do_gap_step, scan_for_new_match, animate_chain,
move_chain, try_spawn, insert_at, slot_pos PRESERVE) сохранена один-в-один
с 360×288-версией. Изменены только геометрические параметры (×2 scale) и
рендер канвы — для отладки 640×480-варианта под VDAC2.

Управление: только мышь.
- Движение мыши → aim лягушки.
- ЛКМ → выстрел шара текущего цвета.

Не использует никаких внешних библиотек кроме tkinter (стандартная Python поставка).
"""
import struct
import tkinter as tk
import random
import os
from dataclasses import dataclass, field

# ---------- Константы (×2 scale от 360×288 версии) ----------
CELL_SIZE          = 64          # ×2 от 32. Семплов трека на slot. Track в 2× длиннее → плотность шаров та же.
NUM_BALL_COLORS    = 6           # = LevelNumColors в asm (red/green/yellow/blue/purple/white)
MAX_SLOTS          = 240         # без изменений
GAP_STEP_FRAMES    = CELL_SIZE   # = 64 (синхронно с CELL_SIZE)
GAP_STOP           = 0xFE
GAP_CASCADE        = 0xFD
SHOT_SPEED         = 12          # ×2 от 6 px/frame
DM3_OFFSET_GAP_MAX = 16          # ×2 от 8
ROLLBACK_PUSH      = 8           # ×2 от 4 — push px
BALL_DIAMETER      = 40          # ×2 от 20
BALL_RADIUS_VISUAL = 18          # ×2 от 9
COLLISION_BBOX_HALF = 28         # ×2 от 14

# Frog & screen (нативно 640×480 — VDAC2 / FT812 VGA)
SCR_W, SCR_H = 640, 480
RENDER_Y_OFFSET = 64             # ×2 от 32
FROG_X, FROG_Y = 200, 240        # top-left of 128×128 frog (центр ~ (264, 304))
FROG_CX, FROG_CY = FROG_X + 64, FROG_Y + 64
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

# ---------- TrackData loader (640×480 fit) ----------
# Берём 360×288 трек, uniform scale = min(640/orig_w, 480/orig_h) с маржином, центруем
# по X. Resample sample count = round(N * scale), линейная интерполяция между оригинальными
# семплами — держит плотность семплов на px такой же как в 360×288, поэтому CELL_SIZE=64
# покрывает ту же относительную долю трека что CELL=32 покрывал в оригинале (плотность
# шаров на цепи сохраняется).
def _here_or_zuma(name):
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    if os.path.exists(here):
        return here
    return f'c:/z80/zuma/{name}'

def load_track(path=None):
    if path is None:
        path = _here_or_zuma('level_01.bin')
    data = open(path, 'rb').read()
    raw = []
    n = (len(data) - 2) // 4
    for i in range(n):
        x, y = struct.unpack_from('<hh', data, i * 4)
        raw.append((x, y))
    if n < 2:
        return raw
    xs_r = [p[0] for p in raw]; ys_r = [p[1] for p in raw]
    orig_w = max(xs_r) - min(xs_r)
    orig_h = max(ys_r) - min(ys_r)
    margin = 16
    avail_w = SCR_W - 2 * margin
    avail_h = SCR_H - 2 * margin
    sx = avail_w / orig_w if orig_w > 0 else 1.0
    sy = avail_h / orig_h if orig_h > 0 else 1.0
    s = min(sx, sy)
    new_n = max(2, int(round(n * s)))
    scaled = []
    for j in range(new_n):
        t = j * (n - 1) / (new_n - 1)
        i0 = int(t); frac = t - i0
        i1 = min(i0 + 1, n - 1)
        x = raw[i0][0] * (1 - frac) + raw[i1][0] * frac
        y = raw[i0][1] * (1 - frac) + raw[i1][1] * frac
        scaled.append((x * s, y * s))
    xs = [p[0] for p in scaled]
    shift_x = margin - min(xs) + (avail_w - (max(xs) - min(xs))) / 2
    return [(int(round(x + shift_x)), int(round(y))) for x, y in scaled]

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
    rollback_counter: list = field(default_factory=lambda: [0] * MAX_SLOTS)
    # last_render_pos[i] = last (X, Y) where slot i was visibly drawn. Используется когда
    # t<0 (= шар «за стартом» во время cascade rollback) — рисуем на сохранённой позиции
    # вместо clamp в TrackData[0]. Эквивалент PRESERVE-логики в BcsPreClassify (asm).
    last_render_pos: list = field(default_factory=lambda: [None] * MAX_SLOTS)
    hsa: int = 0
    hsub: int = 0
    slots_len: int = 0
    chain_stalled: int = 0
    chain_freeze_counter: int = 0       # пауза chain motion (hsub++) на N кадров после insert/cascade-close
    gap_step_counter: int = 0
    match_scan_idx: int = 0xFF
    balls_spawned: int = 0
    last_match_scan_idx: int = 0
    frame: int = 0

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
        # Adjacent idx (lower=forward, higher=behind) → pixel_dist = 32 + offsets[fwd] - offsets[bhd].
        # Match-3 fires когда шары касаются ИЛИ overlap'ятся (pixel_dist в [0..32+GAP_MAX]).
        # Соответствует diff = offsets[fwd] - offsets[bhd] в [-32..GAP_MAX].
        # Левая граница (-32) допускает overlap при insert; правая (+8) блокирует cascade-gap.
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
        for k in range(lb, rb + 1):
            s.slots[k] = marker
            s.offsets[k] = 0
            s.shot2[k] = 0
        if lb > 0:
            s.shot2[lb-1] = 1
        if rb + 1 < s.slots_len:
            s.shot2[rb+1] = 1
        # Rollback push на match'е удалён — конфликтовал с cascade close offset+=CELL_SIZE
        # компенсацией (давал +30 px instant jump). Теперь rollback приходит ТОЛЬКО
        # от cascade close (HSA-- + offset compensation = smooth slide за CELL_SIZE кадров).
        s.chain_stalled = 1
        # Триггерим gap_step на ближайшем hsub=0 wrap'е — иначе случайная пауза
        # 0..32 кадров между match'ем и началом анимации схлопывания.
        s.gap_step_counter = GAP_STEP_FRAMES
        return True

    def do_gap_step(self):
        s = self.s
        # STOP from tail — HSA-- + head компенсация +CELL_SIZE. Tail НЕ компенсируем:
        # shift idx-=1 в сочетании с HSA-=1 автоматически сохраняет позицию tail-шаров.
        # Это даёт «как CASCADE»: chain shrinks by 1 cell, head smooth slides back 32 px,
        # tail балы остаются физически на месте → без jerk'ов.
        for k in range(s.slots_len - 1, -1, -1):
            if s.slots[k] == GAP_STOP:
                for j in range(k, s.slots_len - 1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                    s.last_render_pos[j] = s.last_render_pos[j+1]
                    s.rollback_counter[j] = s.rollback_counter[j+1]
                s.last_render_pos[s.slots_len - 1] = None
                s.rollback_counter[s.slots_len - 1] = 0
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # NO chain_freeze here — head компенсация +CELL_SIZE декаится за 32 кадра
                # параллельно с естественным chain motion (hsub++ wrap → HSA++). Net = head стоит.
                if k > 0 and k - 1 < s.slots_len and not is_gap(s.slots[k-1]):
                    s.shot2[k-1] = 1
                if k < s.slots_len and not is_gap(s.slots[k]):
                    s.shot2[k] = 1
                s.match_scan_idx = k
                return  # обрабатываем ОДИН маркер за вызов — иначе STOP+CASCADE в одном
                        # тике дают HSA-=2 без двойной компенсации → рывок head назад на 32 px.
        # CASCADE from head
        for k in range(s.slots_len):
            if s.slots[k] == GAP_CASCADE:
                for j in range(k, s.slots_len - 1):
                    s.slots[j] = s.slots[j+1]
                    s.offsets[j] = s.offsets[j+1]
                    s.shot2[j] = s.shot2[j+1]
                    s.last_render_pos[j] = s.last_render_pos[j+1]
                    s.rollback_counter[j] = s.rollback_counter[j+1]
                s.last_render_pos[s.slots_len - 1] = None
                s.rollback_counter[s.slots_len - 1] = 0
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                # Smooth rollback compensation, cap +CELL_SIZE — без cap'а несколько
                # cascade'ов подряд накапливают offset до 70+ → head «зависает» на
                # десятки кадров пока offset не decay'ится до 0.
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # chain_freeze: head декаится без параллельного chain motion →
                # head визуально откатывается на 32 px назад за 32 кадра (видимый rollback).
                s.chain_freeze_counter = CELL_SIZE
                if k > 0 and k - 1 < s.slots_len and not is_gap(s.slots[k-1]):
                    s.shot2[k-1] = 1
                if k < s.slots_len and not is_gap(s.slots[k]):
                    s.shot2[k] = 1
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
                # No match. Clear Shot2 only if offsets near k settled.
                settled = (s.offsets[k] == 0)
                if k > 0:
                    settled = settled and (s.offsets[k-1] == 0)
                if k + 1 < s.slots_len:
                    settled = settled and (s.offsets[k+1] == 0)
                if settled:
                    s.shot2[k] = 0
        return False

    def update_stall(self):
        s = self.s
        # Chain motion никогда не блокируется — gap_step и offset compensations
        # работают независимо. chain_stalled оставлен как флаг (для совместимости
        # с asm), но всегда 0 — move_chain больше не пропускается.
        s.chain_stalled = 0

    def animate_chain(self):
        s = self.s
        # Phase 1: gradient rollback (если rollback_counter > 0, offset -= 1).
        # Phase 2: standard decay toward 0 (если rollback завершился).
        for k in range(s.slots_len):
            if s.rollback_counter[k] > 0:
                s.offsets[k] = sat_signed(s.offsets[k] - 1)
                s.rollback_counter[k] -= 1
            else:
                o = s.offsets[k]
                if o > 0: s.offsets[k] = max(0, o - 1)
                elif o < 0: s.offsets[k] = min(0, o + 1)
        s.gap_step_counter += 1
        # Align gap_step по hsub=0 — после gap_step следующий tick будет с hsub=0,
        # spawn попадёт точно в track[0] без edge case'а t=hsub.
        if s.gap_step_counter >= GAP_STEP_FRAMES and s.hsub == 0:
            s.gap_step_counter = 0
            self.do_gap_step()
        s.match_scan_idx = 0
        self.scan_for_new_match()
        self.update_stall()

    def move_chain(self):
        s = self.s
        if s.chain_stalled: return
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
    def try_spawn(self):
        s = self.s
        if s.slots_len >= MAX_SLOTS: return False
        if s.hsa < s.slots_len: return False
        # Спавнить только когда chain выровнен по cell-границе (hsub=0).
        if s.hsub != 0: return False
        candidate = self.rng.randint(0, NUM_BALL_COLORS - 1)
        # anti-3-spawn-guard
        if s.slots_len >= 2 and s.slots[s.slots_len - 1] == s.slots[s.slots_len - 2] == candidate:
            candidate = (candidate + 1) % NUM_BALL_COLORS
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
        s.balls_spawned += 1
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
        # Tail-side (idx target_idx..end → target_idx+1..end+1): idx +1, HSA +1.
        # Эти эффекты на slot_t взаимно компенсируются → offsets без изменений.
        for j in range(s.slots_len, target_idx, -1):
            s.slots[j] = s.slots[j-1]
            s.offsets[j] = s.offsets[j-1]
            s.shot2[j] = s.shot2[j-1]
            s.last_render_pos[j] = s.last_render_pos[j-1]
            s.rollback_counter[j] = s.rollback_counter[j-1]
        # Новый шар: midpoint между head и tail соседями (учитывая decay-state).
        s.slots[target_idx] = color
        s.offsets[target_idx] = sat_signed(new_offset)
        s.shot2[target_idx] = 1
        s.last_render_pos[target_idx] = None
        s.rollback_counter[target_idx] = 0
        s.slots_len += 1
        # HSA+1 = chain продвинулся на 1 cell вперёд (к killzone). Cap по track-end.
        if s.hsa < len(self.track) // CELL_SIZE - 1:
            s.hsa += 1
        # Head-side (idx 0..target_idx-1): idx тот же, HSA+1 → +32 instant.
        # offsets -=CELL_SIZE компенсирует instant, декей возвращает к 0 за 32 кадра
        # → плавный slide HEAD на 32 px вперёд. Cap'ним на -CELL_SIZE чтобы при
        # многократных insert/match offsets не уходили в большие отрицательные значения.
        for i in range(target_idx):
            s.offsets[i] = max(s.offsets[i] - CELL_SIZE, -CELL_SIZE)
        # Freeze chain motion на CELL_SIZE кадров — head компенсация decay'ится без
        # параллельного chain-motion, иначе net advance = 2*CELL_SIZE вместо 1*CELL_SIZE.
        s.chain_freeze_counter = CELL_SIZE
        return self.check_match3(target_idx)

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
        log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vdc_emulator_log.txt')
        self.log = open(log_path, 'w', buffering=1)
        self.log.write('# frame slotsLen hsa hsub stalled scanIdx slots offsets shot2 rollback\n')
        self.cw = SCR_W * SCALE
        self.ch = (SCR_H + RENDER_Y_OFFSET) * SCALE
        self.canvas = tk.Canvas(root, width=self.cw, height=self.ch, bg='#202028')
        self.canvas.pack(side='left')
        self.info = tk.Label(root, font=('Consolas', 10), justify='left', anchor='nw', width=44, bg='#181818', fg='#cccccc')
        self.info.pack(side='right', fill='y')

        self.track = load_track()
        self.engine = VDCEngine(self.track, seed=42)
        self.flying = []
        self.next_color = self.rng_color()
        self.mouse_xy = (FROG_CX, FROG_CY - 50)
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
        """game coords → canvas coords (с шифтом по Y чтобы спавн-зона track[0..29] с y<0 была видна)"""
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
        dx = gx - FROG_CX
        dy = gy - FROG_CY
        mag = (dx*dx + dy*dy) ** 0.5
        if mag < 1e-3: return
        dx, dy = dx / mag * SHOT_SPEED, dy / mag * SHOT_SPEED
        self.log.write(f'# SHOT_FIRED frame={self.engine.s.frame} dir=({dx:.1f},{dy:.1f}) color={self.next_color}\n')
        # Spawn ball at frog center
        self.flying.append(FlyingBall(FROG_CX, FROG_CY, dx, dy, self.next_color))
        self.next_color = self.rng_color()
        self.shot_cooldown = 8

    def update_flying(self):
        e = self.engine
        new_list = []
        for b in self.flying:
            if not b.active: continue
            b.x += b.dx
            b.y += b.dy
            # Off-screen → drop
            if b.x < -32 or b.x > SCR_W + 32 or b.y < -32 or b.y > SCR_H + 32:
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
                new_list.append(b)
        self.flying = new_list

    def tick(self):
        e = self.engine
        # Spawn: try_spawn сам gate'ится по hsub==0 → одна попытка раз в 32 кадра
        # ровно в момент клеточного выравнивания. Шар появляется на track[0].
        if e.s.balls_spawned < 60:
            e.try_spawn()
        e.move_chain()
        e.animate_chain()
        self.update_flying()
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
        rb_str = ','.join(str(s.rollback_counter[i]) for i in range(s.slots_len))
        self.log.write(f'{s.frame} {s.slots_len} {s.hsa} {s.hsub} {s.chain_stalled} {s.match_scan_idx} '
                       f'[{slots_str}] [{offsets_str}] [{shot2_str}] [{rb_str}]\n')
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
            if pos is None: continue                      # pre-spawn (t<0) → не рисуем
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
        fx, fy = self.s2c(FROG_CX, FROG_CY)
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

        # Info panel
        s = e.s
        info = []
        info.append(f'Frame:        {s.frame}')
        info.append(f'SlotsLen:     {s.slots_len}/{MAX_SLOTS}')
        info.append(f'HSA:          {s.hsa}')
        info.append(f'HSub:         {s.hsub}/{CELL_SIZE}')
        info.append(f'Stalled:      {s.chain_stalled}')
        info.append(f'GapStepCnt:   {s.gap_step_counter}/{GAP_STEP_FRAMES}')
        info.append(f'BallsSpawned: {s.balls_spawned}')
        info.append(f'Flying balls: {len(self.flying)}')
        info.append(f'Next color:   {self.next_color}')
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
