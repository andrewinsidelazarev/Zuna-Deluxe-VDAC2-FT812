# Zuma Deluxe VDAC2 — Debug Bundle для Gemini Pro

Проект: порт игры Zuma Deluxe под ZX-Evo + VDAC2 (FT812 GPU) в нативном 640×480.

Архитектура:
- **VDC** = 1D дискретный калькулятор цепочки шаров (Slots/Offsets/HSA/HSub).
- **2D холст** = проекция `TrackData[slot_t] → (X,Y)` через готовый track 640×480.
- **FT812** = GPU над SPI, рендер через DL команды (`cmd_translate`/`cmd_rotate`/`Vertex2f`).

Разделение 1D physics + 2D render → отладка локализуется в одной размерности.

---

## 1. Python VDC Emulator (визуальный, tkinter)

Файл `vdc_visual_emulator.py` — содержит VDC engine (class `VDCEngine`) + tkinter render (class `App`). Используется как reference для asm-порта.

```python
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

# ---------- Константы (синхронно с текущим asm: VDC.asm + MainLoop.asm) ----------
CELL_SIZE          = 32          # = VDC_CELL_SIZE в asm. 1 sample ≈ 1.08 px → ≈ 34.6 px между centers.
DECAY_NEG_PER_FRAME = 2          # negative offsets (insert head slide) → 0 быстро.
DECAY_POS_PER_FRAME = 1          # positive offsets (cascade rollback) → 0 плавно (= коллега).
NUM_BALL_COLORS    = 6           # = VDC_NUM_COLORS
MAX_SLOTS          = 240         # = VDC_MAX_SLOTS
GAP_STEP_FRAMES    = CELL_SIZE
GAP_STOP           = 0xFE
GAP_CASCADE        = 0xFD
SHOT_SPEED         = 6           # px/frame (= MainLoop bullet step, 360×288 baseline)
DM3_OFFSET_GAP_MAX = 10          # = VDC_DM3_OFFSET_GAP_MAX
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
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'track_640.bin')
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
        # Триггерим первый gap_step немедленно — иначе chain motion в течение
        # waiting period (0..CS frames до hsub=0) двигает head вперёд, а должна
        # стоять и ждать хвост. С первым instant gap_step head получает +CS
        # offset compensation сразу → stationary до конца decay phase.
        # Оставшиеся markers ждут hsub=0 (= 1 marker per gap_step call).
        self.do_gap_step()
        s.gap_step_counter = 0
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
                s.last_render_pos[s.slots_len - 1] = None
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # NO chain_freeze here — head компенсация +CELL_SIZE декаится за CELL_SIZE кадров
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
                s.last_render_pos[s.slots_len - 1] = None
                s.slots_len -= 1
                if s.hsa > 0:
                    s.hsa -= 1
                # Smooth rollback compensation, cap +CELL_SIZE — без cap'а несколько
                # cascade'ов подряд накапливают offset до 70+ → head «зависает» на
                # десятки кадров пока offset не decay'ится до 0.
                for j in range(k):
                    s.offsets[j] = min(s.offsets[j] + CELL_SIZE, CELL_SIZE)
                # chain_freeze: head декаится без параллельного chain motion →
                # head визуально откатывается на CELL_SIZE px назад за N кадров (видимый rollback).
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
        # Без hsub=0 constraint, иначе зазор между decay-end и next gap_step → head moves forward.
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
        # Новый шар: midpoint между head и tail соседями (учитывая decay-state).
        s.slots[target_idx] = color
        s.offsets[target_idx] = sat_signed(new_offset)
        s.shot2[target_idx] = 1
        s.last_render_pos[target_idx] = None
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
        # NO freeze (= синхронно с asm `VDC_InsertAt`): head компенсация (-CS) decay'ится
        # параллельно с natural chain motion → head «ускоренно уезжает вперёд на 2 cells
        # за CELL_SIZE кадров», без stutter'а паузы. См. коммент в VDC.asm после InsertAt.
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

```

---

## 2. ASM реализация (Z80 / sjasmplus syntax-ab)

Layout: TSLib в page 0 на #1000, Core (game logic) в page 5 на #6000. Slot 2 (#8000) маппится на page 6 (TrackData).

### 2.main.asm

Точка сборки + include всех модулей + Init_Core (DMA загрузка bg/atlas в RAM_G FT812)

```asm
; ============================================================================
; Zuma Deluxe VDAC2 — main.asm
; ----------------------------------------------------------------------------
; Точка сборки. Использует TSLib из Docs/TSLib/.
; Layout:
;   Page 0 (#0000..#3FFF mapped at slot 0): TSLib code, ORG #1000
;   Page 5 (#4000..#7FFF mapped at slot 1): Core code, ORG #6000
; После Init_Core slot/page mapping: page1=5, page2=2, page3=8.
; Стек в slot 1 (#40F2) — между Resolution* указателями и началом кода.
; ============================================================================

                DEVICE ZXSPECTRUM4096
                define MAPPING_REGISTERS              ; реестры через FMADDR_REGS

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #6000                        ; slot 1 (page 5)
StackTop             EQU #40F2
ResolutionWidthPtr   EQU #40F3                        ; куда FT_RESOLUTION пишет ширину (W word)
ResolutionHeightPtr  EQU #40F5                        ; высоту (H word)
MemoryPages          EQU #40F7                        ; page-numbers cache (для не-MAPPING_REGISTERS)
InterruptVA          EQU #4000                        ; IM2 vector area (page-aligned)

TSLib                EQU #1000                        ; адрес где живёт TSLib
TSLibPage            EQU #00                          ; страница TSLib

; --- TSLib block (page 0) ------------------------------------------------
                ORG TSLib
TSLIB_Start:
                include "Docs/TSLib/Include/TSConf.inc"
                include "Docs/TSLib/Include/Memory/Include.inc"
                include "Docs/TSLib/Include/Cache/Macro.inc"
                include "Docs/TSLib/Include/Video/Macro.inc"
                include "Docs/TSLib/Include/System/Macro.inc"
                include "Docs/TSLib/Include/INT/Macro.inc"
                include "Docs/TSLib/Include/FT/81x Const.inc"
                include "Docs/TSLib/Include/FT/DL  Macro.inc"
                include "Docs/TSLib/Include/FT/812 Macro.inc"
                module FT
                include "Docs/TSLib/Include/FT/812 Func.asm"
                include "Docs/TSLib/Include/FT/Coprocessor/Include.inc"
                endmodule
                include "Docs/TSLib/Include/Input/Include.inc"
TSLIB_End:
TSLIB_Size       EQU TSLIB_End - TSLIB_Start
                display "TSLib:    \t", /A, TSLIB_Start, " size=", /D, TSLIB_Size, " bytes"
                SAVEBIN "TSLib.bin", TSLIB_Start, TSLIB_Size

; --- Core block (page 5) -------------------------------------------------
                ORG EntryPoint
                module Core
Start:
                ; ----- EntryPoint -----
                LD   SP, StackTop
                CALL Initialize
                JP   MainLoop

                ; ----- Initialize -----
Initialize:     CALL Init_Core
                CALL Init_Int                         ; EI/HALT — ждём первого FRAME INT (HW stab)
                CALL Init_Video                       ; FT_BOOT_UP + 640×480 + FT_INT_SWAP enable
                CALL Input.Mouse.Initialize           ; курсор в центр (W/2, H/2)
                ; Init завершён — отключаем TS-Conf frame INT 50 Hz, чтобы он не бился
                ; с FT812 vsync 57.25 Hz. Синхронизация в MainLoop через FT_INT_SWAP.
                DI
                INT_Setting 0

                ; Залить bg_level01 (640x480 RGB565, 38 страниц 7..44) в RAM_G
                ; начиная с #010000. Каждая страница = 16384 байт по адресу #8000
                ; в slot 2.
                ; ВАЖНО: bg грузится ПЕРВЫМ. 38×16384=622592 байт реально пишется в
                ; #010000..#0A8000, тогда как реальный bg — 614400 байт (#010000..#0A0000),
                ; последние 8192 байт = padding zeros последней spgbld page. Если atlas
                ; (#0A6000..) залить до bg — bg-padding затрёт первые 8 КБ atlas
                ; = Cell 0 + начало Cell 1 → невидимый шар. Поэтому: bg первым,
                ; atlas вторым (atlas-padding потом уходит в свободную область после #0F2000).
                LD   A, BG_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BG_PAGE_COUNT
.UploadBg:      PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000                          ; источник в slot 2
                LD   BC, 16384
                LD   A,  (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                ; advance RAM_G addr += #4000
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarry
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarry:       LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBg

                ; Залить balls_atlas (6 colors × 8 frames × 56×56 ARGB4 = 301 056 байт)
                ; в RAM_G #0A6000. Atlas грузится ПОСЛЕ bg чтобы перезаписать
                ; bg-padding в #0A6000..#0A8000 реальными sprite-данными. Handle 0 в DL.
                LD   A, BALLS_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BALLS_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BALLS_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BALLS_PAGE_COUNT
.UploadBalls:   PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryB
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryB:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBalls

                ; Залить frog body / plate / tongue / face-overlay в RAM_G.
                ; Layout (FROG_TOTAL_PAGES=7 pages подряд от FROG_PAGE):
                ;   pages 0x52..0x53 — body    (2 pages, 122×122 ARGB4)
                ;   pages 0x54..0x55 — plate   (2 pages)
                ;   page  0x56       — tongue  (1 page tight 32×80, padding 11 КБ
                ;                                перезаписывается next overlay
                ;                                upload, но overlay начинается at
                ;                                OVERLAY_RAMG_ADDR = #0F8000 — gap
                ;                                #0F5000..#0F8000 остаётся zeros)
                ;   pages 0x57..0x58 — overlay (2 pages, HD blink frame 0)
                ; Loop пишет 16 КБ на page и advance RAM_G на #4000 — для tongue
                ; padding zeros (11 КБ) ложится в gap до overlay (no harm).
                LD   A, FROG_PAGE
                LD   (BgPg), A
                LD   HL, FROG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FROG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, FROG_TOTAL_PAGES
.UploadFrog:    PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryF
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryF:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadFrog

                ; Залить killzone 64×64 ARGB4 (8192 байт) в RAM_G KZ_RAMG_ADDR
                ; (#04C000 = bg padding zone). Page 0x16 в spgbld.
                LD   A, KZ_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 8192
                LD   A, (KZ_RAMG_ADDR >> 16) & 0xFF
                LD   DE, KZ_RAMG_ADDR & 0xFFFF
                CALL FT.WriteMem

                ; Залить cursor 48×48 ARGB4 (4608 байт) в RAM_G CURSOR_RAMG_ADDR.
                ; Single page 0x5A. Padding в page безопасен (RAM_G #0BC000+4608..
                ; #0C0000 = пустая зона, никто не читает).
                LD   A, CURSOR_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, CURSOR_W * CURSOR_H * 2
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                LD   DE, CURSOR_RAMG_ADDR & 0xFFFF
                CALL FT.WriteMem

                ; Восстановить slot 2 на TrackData (page 6)
                SetPage2 6

                ; --- VDC physics init (TrackData уже доступен в slot 2) ---
                CALL VDC_Init
                CALL Frog_Init
                CALL Bullet_Init
                RET

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 15                                ; 400×300 RGB565 = 240000 bytes (~60% economy)
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BALLS_FIRST_PAGE   EQU #2D                             ; balls_atlas pages 0x2D..0x38 (12 pages)
BALLS_PAGE_COUNT   EQU 12                                ; 6 colors × 16 phases × 32×32 ARGB4 = 192 KB
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000)
FROG_PAGE          EQU #52                             ; spgbld first page (frog body)
FROG_PAGE_COUNT    EQU 2                                ; 122×122 ARGB4 = 2 pages each
FROG_TOTAL_PAGES   EQU FROG_PAGE_COUNT * 4              ; body+plate+tongue+overlay = 8 pages
FROG_RAMG_ADDR     EQU #09C000                         ; после balls (19 pages = 0x4C000 от #050000)
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #4000 * FROG_PAGE_COUNT     ; #0A4000
TONGUE_RAMG_ADDR   EQU PLATE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT    ; #0AC000
OVERLAY_RAMG_ADDR  EQU TONGUE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT   ; #0B4000
KZ_PAGE            EQU #16                             ; killzone в bg padding zone
KZ_RAMG_ADDR       EQU #04C000                         ; bg padding (после реальных bg pages)

; --- Cursor 48×48 ARGB4 (1 page) ---
CURSOR_PAGE        EQU #5A
CURSOR_RAMG_ADDR   EQU #0BC000                         ; сразу после overlay area
CURSOR_W           EQU 24
CURSOR_H           EQU 24
CURSOR_TIP_X       EQU 0                               ; острие sprite-coords (см. make_cursor.py)
CURSOR_TIP_Y       EQU 0

BgPg:           DEFB 0
BgRamL:         DEFW 0
BgRamH:         DEFB 0

Init_Core:      FMapAddrInit                          ; FT_EN, MEM_WO, page0=TSLibPage
                System_Setting SYS_ZCLK14 | SYS_CACHEEN
                Cache_Setting  EN_0000 | EN_4000 | EN_8000
                SetPage1 5                            ; #4000 → Core code page
                SetPage2 6                            ; #8000 → TrackData (track_640.bin)
                SetPage3 8
                RET

TrackData       EQU #8000                             ; в slot 2 (page 6)

Init_Int:       ; Стандартная IM2 + frame INT инициализация (как в TSLib HelloWorld).
                ; HALT перед RET КРИТИЧЕН: ждём первый FRAME interrupt — это даёт
                ; TS-Conf время стабилизировать timing, иначе FT_BOOT_UP стартует
                ; до того как HW готова → видеорежим выходит неправильный.
                LD   HL, INT_Handler
                LD   (InterruptVA + INT_VEC_FRAME), HL
                LD   A,  HIGH InterruptVA
                LD   I,  A
                IM   2
                INT_Setting INT_MSK_FRAME
                EI
                HALT
                RET

INT_Handler:    EI
                RET

                ; ----- Init_Video, VDC и MainLoop из отдельных файлов -----
                include "Init_Video.asm"
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"

End:
                endmodule

Core_Size        EQU Core.End - Core.Start
                display "Core:     \t", /A, Core.Start, " size=", /D, Core_Size, " bytes"
                SAVEBIN "Core.bin", Core.Start, Core_Size

                END EntryPoint

```

### 2.Init_Video.asm

FT_BOOT_UP, FT_RESOLUTION VM_640_480_57Hz, разрешение IRQ_SWAP

```asm

                ifndef _ZUMA_INIT_VIDEO_
                define _ZUMA_INIT_VIDEO_

; ============================================================================
; Init_Video — инициализация видеорежима 640×480 через VDAC2 / FT812
; ----------------------------------------------------------------------------
; Использует TSLib (DeadlyKom). Зависимости подключи в основном файле проекта:
;
;   include "Docs/TSLib/Include/TSConf.inc"            ; STATUS, VCONFIG, VID_*
;   include "Docs/TSLib/Include/Video/Macro.inc"       ; Video_Setting
;   include "Docs/TSLib/Include/FT/81x Const.inc"      ; FT_REG_*, VM_*, FT_INT_*
;   include "Docs/TSLib/Include/FT/812 Macro.inc"      ; FT_BOOT_UP, FT_RESOLUTION, FT_WR_REG8, FT_CMD_RESET
;   include "Docs/TSLib/Include/FT/812 Func.asm"       ; FT.WriteMem, FT.WriteDL, FT.SendCommand.Param
;   include "Docs/TSLib/Include/FT/DL  Macro.inc"      ; FT_CLEAR_COLOR_RGB, FT_CLEAR, FT_DISPLAY (DEFD-форма)
;
; Пользовательские константы (определи в Configuration.inc или Include.inc):
;   ResolutionWidthPtr   EQU <addr_word_in_RAM>   ; куда FT_RESOLUTION пишет ширину
;   ResolutionHeightPtr  EQU ResolutionWidthPtr+2 ; высоту
;
; Out:
;   A=0, Z=1   — успех (640×480 включён через FT812)
;   A=1, Z=0   — VDAC2 на этой плате не обнаружен (вызывающий выбирает fallback)
; Corrupts: AF, BC, DE, HL
; ============================================================================

Init_Video:     ; --- 1. Sanity-check: VDAC2 присутствует на плате? --------
                ; TS-Conf STATUS [2:0] = 111 ⇒ FT812-VDAC2. Иначе плата с
                ; обычным VDAC (5/4/3/2-bit) — на ней этот код работать не
                ; будет, надо отдать управление обратно в TS-Config рендер.
                IN   A, (STATUS)
                AND  %00000111
                CP   %00000111
                JP   NZ, .no_vdac2                    ; JP, не JR — FT_BOOT_UP большой

                ; --- 2. Полная boot-up последовательность FT812 ----------
                ; FT_BOOT_UP (TSLib 812 Macro.inc:104):
                ;   PWRDOWN_ → CLKEXT → CLKSEL #C0 → ACTIVE
                ;   ждать REG_ID == 0x7C
                ;   ждать REG_CPURESET == 0
                ;   записать default тайминги, SWIZZLE/PCLK_POL/CSPREAD/DITHER/OUTBITS
                ;   GPIOX_DIR=0xFFFF, GPIOX=0xFFFF (включить DISP)
                ;   REG_PCLK = 2 (включает развёртку 60/2 = 30 МГц)
                FT_BOOT_UP

                ; --- 3. Сброс co-processor буфера ------------------------
                ; FT_CMD_RESET = REG_CPURESET=1, DELAY 5, REG_CMD_READ/WRITE=0,
                ; REG_CPURESET=0. Гарантирует что после старта co-processor
                ; не имеет «висящих» команд из предыдущих сессий.
                FT_CMD_RESET

                ; --- 4. Переключить таймминги на 640×480 @ 57 Hz ---------
                ; VM_640_480_57Hz: PCLK 24 МГц (F_MUL=3), H 16/96/48/640,
                ;                  V 11/2/31/480 → HCYCLE 800, VCYCLE 524.
                ; Макрос пишет HCYCLE, HOFFSET, HSYNC0/1, HSIZE, VCYCLE,
                ; VOFFSET, VSYNC0/1, VSIZE и REG_PCLK = F_MUL.
                FT_RESOLUTION VM_640_480_57Hz, ResolutionWidthPtr

                ; --- 5. Залить минимальный пустой DL: чёрный экран -------
                ; До первого FT_CMD_Write из MainLoop'а на экране может быть
                ; garbage (RAM_DL после reset не определена). Заливаем 12 байт:
                ; CLEAR_COLOR_RGB(0,0,0); CLEAR(1,1,1); DISPLAY().
                LD   HL, .EmptyDL
                LD   BC, .EmptyDL_Size
                LD   DE, 0                             ; offset 0 от FT_RAM_DL
                CALL FT.WriteDL                        ; HL→RAM_DL+DE, OTIR блок
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME

                ; --- 6. Разрешить SWAP-interrupt -------------------------
                ; MainLoop ждёт этот INT_FLAG чтобы синхронизироваться
                ; с vsync (см. Examples\2.HelloWorld\Core\MainLoop.asm).
                FT_WR_REG8 FT_REG_INT_MASK, FT_INT_SWAP
                FT_WR_REG8 FT_REG_INT_EN,   1

                ; --- 7. Переключить видеовыход TS-Conf → FT812 -----------
                ; VID_FT812 (#04) = bit 2 FT_EN — выход через VDAC2.
                ; VID_NOGFX (#20) = bit 5 NO_GFX — отключить TS-Conf gfx
                ; (освобождает 448 DMA-циклов/строку для FT-передач).
                Video_Setting VID_FT812 | VID_NOGFX

                ; Успех
                XOR  A                                ; A=0, Z=1
                RET

.no_vdac2:      ; VDAC2 не обнаружен. Возвращаем NZ — пусть caller решает
                ; (fallback на оригинальный TS-Conf рендер 360×288 или Halt).
                LD   A, 1
                OR   A                                ; Z=0
                RET

; ----------------------------------------------------------------------------
; Минимальный пустой Display List — три 32-битные команды, всего 12 байт.
; Хранится в коде, заливается один раз при init для гарантии чистого экрана
; до первого живого DL из MainLoop'а.
; ----------------------------------------------------------------------------
.EmptyDL:       FT_CLEAR_COLOR_RGB 0, 0, 0            ; opcode 0x02 — фон чёрный
                FT_CLEAR 1, 1, 1                       ; opcode 0x26 — color+stencil+tag
                FT_DISPLAY                             ; opcode 0x00 — конец DL
.EmptyDL_End:
.EmptyDL_Size   EQU .EmptyDL_End - .EmptyDL

                endif ; ~_ZUMA_INIT_VIDEO_

```

### 2.MainLoop.asm

Главный цикл: Build DL → Wait FT INT → Burst write CMD FIFO → Frame. Содержит bucket-rotation chain render (group-by-tangent) + spin physics + helpers ZL_Mul16x8, ZL_EmitTranslate/Rotate/SetMatrix

```asm

                ifndef _ZUMA_MAIN_LOOP_
                define _ZUMA_MAIN_LOOP_

; ============================================================================
; MainLoop — главный игровой цикл Zuma VDAC2 (640×480 через FT812)
; ----------------------------------------------------------------------------
; Каркас: на этом этапе DL содержит только тёмный фон + анимированную точку
; (proof-of-life). По мере добавления game-state'а сюда подключатся:
;   • VDC engine update (move_chain, animate_chain, try_spawn, scan_match…)
;   • Background bitmap из RAM_G
;   • Цикл по slots[] → BITMAP cells шаров (FT_Vertex2ii)
;   • Frog с rotation matrix к курсору
;   • Cursor + score
;
; Зависимости подключаются ровно те же что для Init_Video.asm
; (TSConf + Video + FT/81x Const + DL + 812 Macro + module FT 812 Func + Coprocessor).
;
; Контракт: MainLoop вызывается из EntryPoint после Init_Video и не возвращается.
; ============================================================================

; --- Константы кадра (всё в subpixel'ах: VertexFormat=4 → 1/16 px) ----------
ZL_SCR_W        EQU 640
ZL_SCR_H        EQU 480
ZL_SUB          EQU 16                                ; subpixel множитель

ZL_PT_RADIUS_PX EQU 16                                ; визуальный радиус точки
ZL_PT_SIZE_FT   EQU ZL_PT_RADIUS_PX * ZL_SUB          ; PointSize в 1/16 px

ZL_PT_INIT_X    EQU (ZL_SCR_W / 2) * ZL_SUB
ZL_PT_INIT_Y    EQU (ZL_SCR_H / 2) * ZL_SUB
ZL_PT_VEL_X     EQU 3 * ZL_SUB                        ; 3 px/frame
ZL_PT_VEL_Y     EQU 2 * ZL_SUB                        ; 2 px/frame

ZL_PT_MIN_X     EQU ZL_PT_SIZE_FT
ZL_PT_MAX_X     EQU ZL_SCR_W * ZL_SUB - ZL_PT_SIZE_FT
ZL_PT_MIN_Y     EQU ZL_PT_SIZE_FT
ZL_PT_MAX_Y     EQU ZL_SCR_H * ZL_SUB - ZL_PT_SIZE_FT

; ----------------------------------------------------------------------------
; MainLoop — точка входа. Никогда не возвращается.
; ----------------------------------------------------------------------------
MainLoop:       ; --- Init game state (одноразово при первом входе) ---
                LD   HL, 0
                LD   (ZL_FrameCounter), HL
                ; Spin K — runtime (per-level калибровка). Default = level 1.
                LD   A, ZL_SPIN_K_DEFAULT
                LD   (ZL_SpinK), A

.Loop           ; --- 1. Update input + game state (Z80-only, параллельно с FT812 render) ---
                CALL Input.Mouse.UpdateMouseState
                CALL ZL_AimUpdate
                CALL ZL_SmoothMouse
                CALL Frog_Update
                CALL VDC_Update
                CALL Bullet_Update
                CALL Bullet_CheckCollision

                ; --- 2. Build DL в Z80 buffer (тоже параллельно с render). Тяжёлый
                ; build (mouse motion → ComputeFrogAngle/atan2) не съедает FT812
                ; vblank window — write всегда попадает строго в vblank.
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x102030
                FT_ClearAll
                FT_Begin FT_BITMAPS
                CALL ZL_DrawFrame
                FT_Display

                ; --- 3. Sync с FT812 vsync (HighLander pattern). Wait ПОСЛЕ build,
                ; ПЕРЕД write — FT812 закончил рендер prev frame, освободил RAM_DL.
.WaitIntSync    FT_RD_REG8 FT_REG_INT_FLAGS
                AND  FT_INT_SWAP
                JR   Z, .WaitIntSync
.WaitDLSwap     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .WaitDLSwap

                ; --- 4. Burst write Z80 buffer → FT812 RAM_CMD (in vblank window) ---
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME

                ; --- 5. Frame counter ---
                LD   HL, (ZL_FrameCounter)
                INC  HL
                LD   (ZL_FrameCounter), HL

                JP   .Loop

; ----------------------------------------------------------------------------
; ZL_DrawFrame — собрать DL-команды текущего кадра
; ----------------------------------------------------------------------------
ZL_BALL_DIAM_PX  EQU 32                               ; atlas cell size (BitmapLayout/Size)
ZL_BALL_VISIBLE  EQU ZL_BALL_DIAM_PX                  ; visible diameter = atlas cell (без alpha-padding)
ZL_BALL_W        EQU ZL_BALL_DIAM_PX                  ; native classic ball cell
ZL_BALL_H        EQU ZL_BALL_DIAM_PX
ZL_BALL_HALF     EQU ZL_BALL_DIAM_PX / 2              ; центр rect'а (= pivot для cmd_rotate)
; --- Spin physics: rolling-without-slip связь между движением t и phase atlas ---
; t — позиция шара на треке в track samples. Phase меняется ТОЛЬКО когда t движется
; → автоматически пропорционально скорости шаров (быстрее цепь → быстрее phase).
;
; Формула: spin_frame = ((t * K) >> 8) & (ATLAS_PHASES-1), где
;   K = 256 * ATLAS_PHASES * px_per_sample / (π * D_visible)
; π ≈ 355/113, px_per_sample ≈ 108/100 (замер level 1 spiral), всё compile-time integer.
; Для D_visible=32, phases=16 → K = 256*16*113*108/(355*32*100) ≈ 44.05 → 44.
;
; K держится в RAM (ZL_SpinK) — runtime, можно менять per-level. Default = compile-time.
ZL_ATLAS_PHASES            EQU 16
ZL_TRACK_PX_PER_SAMPLE_NUM EQU 108                    ; level 1 spiral замер
ZL_TRACK_PX_PER_SAMPLE_DEN EQU 100
ZL_SPIN_K_NUM              EQU 256 * ZL_ATLAS_PHASES * 113 * ZL_TRACK_PX_PER_SAMPLE_NUM
ZL_SPIN_K_DEN              EQU 355 * ZL_BALL_VISIBLE * ZL_TRACK_PX_PER_SAMPLE_DEN
ZL_SPIN_K_DEFAULT          EQU (ZL_SPIN_K_NUM + ZL_SPIN_K_DEN / 2) / ZL_SPIN_K_DEN
ZL_SPIN_MASK               EQU ZL_ATLAS_PHASES - 1

; --- Bucket-based tangent rotation: цепь группирована по buckets, 1 cmd_rotate per bucket.
; ZL_BUCKETS = 8/16/32/64. Чем больше — тем плавнее rotation, но больше cmd_rotate/frame.
; bucket = (tangent + step/2) / step mod N. step = 256/N BRAD.
ZL_BUCKETS      EQU 32                                ; 32 buckets = 11.25° точность (max ±5.6° error)

ZL_BG_W         EQU 400                               ; native bg storage (рендер upscaled до 640×480 через scale 1.6x)
ZL_BG_H         EQU 300
ZL_BG_RAMG_ADDR EQU #010000                           ; адрес bg в RAM_G (см. main.asm BG_RAMG_ADDR)
ZL_BALL_COLORS  EQU 6

ZL_DrawFrame:
                ; --- Tint: белый (без модуляции цвета bitmap) ---
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; bg 400×300 RGB565 + scale 1.6 matrix → hardware upscale до 640×480.
                ; 1.6 в f16.16 = 1.6 × 65536 = 0x1999A.
                CALL ZL_EmitLoadId
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF #0001999A                  ; sx = 1.6
                FT_CMD_BUF #0001999A                  ; sy = 1.6
                CALL ZL_EmitSetMatrix
                FT_BitmapHandle 1
                FT_BitmapSource ZL_BG_RAMG_ADDR
                FT_BitmapLayout FT_RGB565, ZL_BG_W * 2, ZL_BG_H
                ; NEAREST вместо BILINEAR: фон 400×300 + cmd_scale(1.6) с BILINEAR
                ; жрёт 2 пикс/clk вместо 16 — главный bandwidth-обжора (~20 тактов/пикс).
                ; См. Чат.txt 2026-05-11 (Сергей Слободчиков).
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, 640, 480
                FT_Vertex2ii 0, 0, 1, 0

                ; ============================================================
                ; Killzone POINT-marker (на последнем track-sample, под chain).
                ; ============================================================
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                FT_BitmapHandle 3
                FT_BitmapSource KZ_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, 64 * 2, 64
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, 64, 64
                LD   HL, (TrackData)
                DEC  HL
                LD   D, H : LD E, L
                ADD  HL, HL : ADD HL, HL
                ADD  HL, DE
                LD   DE, TrackData + 2
                ADD  HL, DE
                LD   E, (HL) : INC HL : LD D, (HL)
                INC  HL
                LD   C, (HL) : INC HL : LD B, (HL)
                EX   DE, HL
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   DE, 32 * 16
                AND  A
                SBC  HL, DE
                PUSH HL
                LD   H, B : LD L, C
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   DE, 32 * 16
                AND  A
                SBC  HL, DE
                EX   DE, HL
                POP  HL : LD B, H : LD C, L
                CALL FT.Coprocessor.Vertex2f

                ; ============================================================
                ; Frog composition (HD Frog_Draw порядок):
                ;   plate (под body, no rotation)
                ;   body (rotation matrix к курсору, atan2)
                ;   tongue (та же rotation matrix, offset = tongueExpand·dir)
                ; tongueExpand втягивается в рот при выстреле (ЛКМ); recoil
                ; pos.x/y вычисляется в Frog_TickRecoil из Frog_Update.
                ; ============================================================
                CALL Frog_DrawPlate
                CALL Frog_DrawBody
                CALL Frog_DrawTongue
                CALL Frog_DrawBallNow                  ; в рот, на pos+ballExpand·dir
                CALL Frog_DrawNextBall                 ; на спине, pos-28·dir
                CALL Frog_DrawFaceOverlay              ; face overlay поверх всего

                CALL Bullet_Draw                       ; летящий шар (если активен)

                ; ============================================================
                ; Цепь шаров — handle 0, atlas 6×(40×40) ARGB4 в RAM_G #0000
                ; (вертикальный layout: stride 80, height 40, 6 cells подряд).
                ; Default BlendFunc = SRC_ALPHA / ONE_MINUS_SRC_ALPHA — корректно
                ; смешивает шары с фоном уровня по альфа-каналу спрайта.
                ; ============================================================
                FT_BitmapHandle 0
                FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_W, ZL_BALL_H

                ; --- VDC chain rendering: group-by-tangent (8 buckets × 45°).
                ; Algorithm:
                ;   Pre-pass: для каждого шара кэшируем (bucket, cell, Vx, Vy) — 6 байт.
                ;   Outer (8 buckets): emit cmd_rotate(bucket*32+16) + setmatrix.
                ;   Inner: scan кэш, emit Cell + Vertex2f для шаров текущего бакета.
                ; Снижение cmd_rotate с N (per ball) до 8 (per frame) → 11× меньше SPI.
                ; Точность rotation 45° (BRAD/32) для 32×32 ball — на глаз не отличить.
                LD   A, (VDC_SlotsLen)
                LD   (ZL_BallCount), A
                OR   A
                JP   Z, .ChainEnd
                LD   B, A                             ; B = loop count
                LD   C, 0                             ; C = i
                LD   HL, ZL_BALL_CACHE_ADDR                 ; cache write ptr
                LD   (ZL_CacheWPtr), HL
.PrePassLoop:   PUSH BC                               ; save count+i
                LD   HL, (ZL_CacheWPtr)
                ; --- gap-проверка ---
                LD   A, C
                LD   D, 0 : LD E, A
                PUSH HL                               ; save cache ptr (DE = i)
                LD   HL, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)                          ; Slots[i]
                POP  HL                               ; restore cache ptr
                CP   VDC_NUM_COLORS                   ; ≥ 6 → gap
                JR   NC, .PrePassMark
                LD   (ZL_TmpFrame), A                 ; color
                LD   A, C
                PUSH HL                               ; save cache ptr
                CALL VDC_SlotPos                      ; BC=X, DE=Y, CF=1=skip
                POP  HL                               ; restore cache ptr
                JR   C, .PrePassMark
                LD   (ZL_TmpBallX), BC
                LD   (ZL_TmpBallY), DE
                ; --- spin ---
                PUSH HL                               ; save cache ptr
                LD   HL, (VDC_LastT)
                LD   A, (ZL_SpinK)
                CALL ZL_Mul16x8                       ; HL = t × K
                LD   A, H
                AND  ZL_SPIN_MASK                      ; spin 0..15
                LD   D, A
                LD   A, (ZL_TmpFrame)                 ; color
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A    ; ×16
                ADD  A, D                             ; cell = color*16 + spin
                LD   (ZL_TmpFrame), A
                ; --- bucket = (tangent + 4) >> 3 mod 32 → round-nearest 8 BRAD (11.25°).
                ; 32 buckets = 32 cmd_rotate/frame (vs 85 per-ball).
                LD   A, (VDC_LastTangent)
                ADD  A, 4                              ; round-nearest 8 BRAD
                RRCA : RRCA : RRCA                    ; >>3 mod 32 (wraps via rotate)
                AND  31
                POP  HL                               ; restore cache ptr
                LD   (HL), A : INC HL                 ; +0 bucket
                LD   A, (ZL_TmpFrame)
                LD   (HL), A : INC HL                 ; +1 cell
                ; Vx = (BallX - HALF) × SUB
                PUSH HL
                LD   HL, (ZL_TmpBallX)
                LD   DE, ZL_BALL_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL              ; ×16
                EX   DE, HL                            ; DE = Vx
                POP  HL                               ; cache ptr
                LD   (HL), E : INC HL                 ; +2 Vx lo
                LD   (HL), D : INC HL                 ; +3 Vx hi
                ; Vy = (BallY - HALF) × SUB
                PUSH HL
                LD   HL, (ZL_TmpBallY)
                LD   DE, ZL_BALL_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL              ; ×16
                EX   DE, HL                            ; DE = Vy
                POP  HL
                LD   (HL), E : INC HL                 ; +4 Vy lo
                LD   (HL), D : INC HL                 ; +5 Vy hi
                LD   (ZL_CacheWPtr), HL
                POP  BC
                INC  C
                DEC  B
                JP   NZ, .PrePassLoop
                JP   .BucketStart

.PrePassMark:   ; gap / off-track: bucket = 0xFF, advance HL by 6
                LD   (HL), #FF
                LD   BC, 6
                ADD  HL, BC
                LD   (ZL_CacheWPtr), HL
                POP  BC
                INC  C
                DEC  B
                JP   NZ, .PrePassLoop

.BucketStart:   XOR  A
                LD   (ZL_TmpBucket), A
.BucketLoop:    ; emit matrix для текущего bucket
                CALL ZL_EmitLoadId
                LD   HL, ZL_BALL_HALF
                LD   DE, ZL_BALL_HALF
                CALL ZL_EmitTranslate
                LD   A, (ZL_TmpBucket)
                ADD  A, A : ADD A, A : ADD A, A      ; ×8 → tangent представитель bucket
                CALL ZL_EmitRotate                    ; +192 face direction внутри
                LD   HL, -ZL_BALL_HALF
                LD   DE, -ZL_BALL_HALF
                CALL ZL_EmitTranslate
                CALL ZL_EmitSetMatrix
                ; --- scan кэш, emit для current bucket ---
                LD   A, (ZL_BallCount)
                LD   B, A
                LD   IX, ZL_BALL_CACHE_ADDR
.BInner:        LD   A, (ZL_TmpBucket)
                CP   (IX+0)
                JR   NZ, .BSkip
                LD   A, (IX+1)                         ; cell
                PUSH BC
                CALL FT.Coprocessor.Cell
                LD   C, (IX+2) : LD B, (IX+3)         ; BC = Vx
                LD   E, (IX+4) : LD D, (IX+5)         ; DE = Vy
                CALL FT.Coprocessor.Vertex2f
                POP  BC
.BSkip:         LD   DE, 6
                ADD  IX, DE                            ; next record
                DEC  B
                JP   NZ, .BInner
                ; next bucket
                LD   A, (ZL_TmpBucket)
                INC  A
                LD   (ZL_TmpBucket), A
                CP   32
                JP   NZ, .BucketLoop
.ChainEnd:
                ; --- Reset BITMAP_TRANSFORM к identity для cursor + следующих кадров ---
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix

                ; ============================================================
                ; Cursor — деревянная стрелка 48×48 ARGB4 (handle 7).
                ; Острие sprite в (CURSOR_TIP_X, CURSOR_TIP_Y) — рисуем sprite
                ; со смещением, чтобы острие попадало точно в (SmoothX, SmoothY) =
                ; точка срабатывания (= куда летит шар при выстреле).
                ; ============================================================
                LD   C, 255 : LD D, 255 : LD E, 255   ; tint = white (без модуляции)
                CALL FT.Coprocessor.ColorRGB
                FT_BitmapHandle 7
                FT_BitmapSource CURSOR_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, CURSOR_W * 2, CURSOR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, CURSOR_W, CURSOR_H
                XOR  A                                ; Cell(0) — chain оставил Cell ≠ 0
                CALL FT.Coprocessor.Cell
                ; Cursor рисуем по RAW мыши, не smoothed: low-pass фильтр (~3-4
                ; кадра tau) виден как «лаг» острия за мышью при большом 36×36
                ; sprite. Frog aim по-прежнему использует ZL_SmoothX/Y — там
                ; фильтр нужен для подавления Hyper-V Kempston jitter.
                ; Vertex2f((RawX - CURSOR_TIP_X)*16, (RawY - CURSOR_TIP_Y)*16)
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, CURSOR_TIP_X
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, CURSOR_TIP_Y
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f

                ; ============================================================
                ; SPI/GPU load indicator (temporary):
                ;   bar в (0,0), длина = ZL_SpiCounter >> 5 px.
                ;   Длинный = FT812 ещё рендерит когда Z80 готов = FT812 загружен.
                ;   Короткий = FT812 быстро отрендерил, есть headroom.
                ; ============================================================
                RET

; ----------------------------------------------------------------------------
; ZL_EmitLoadId — append cmd_loadidentity (4 байт opcode) в CMD буфер.
; ----------------------------------------------------------------------------
ZL_EmitLoadId:  LD   DE, FT_CMD_LOADIDENTITY & #FFFF
                LD   BC, FT_CMD_LOADIDENTITY >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitTranslate — append cmd_translate(tx, ty) в CMD буфер.
;   In:  HL = tx_int_px (signed 16), DE = ty_int_px (signed 16)
;   Параметры передаются в FT812 как fixed-point 1/65536 px:
;   tx_subpx = tx_px * 65536 → low_word = 0, high_word = tx_px.
; ----------------------------------------------------------------------------
ZL_EmitTranslate:
                LD   (ZL_TmpTx), HL
                LD   (ZL_TmpTy), DE
                LD   DE, FT_CMD_TRANSLATE & #FFFF
                LD   BC, FT_CMD_TRANSLATE >> 16
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTx)
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTy)
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitRotate — append cmd_rotate(angle) в CMD буфер.
;   In:  A = tangent byte 0..255 (256 = full circle)
;   Native sprite face direction в spritesheet — DOWN (0° = низ экрана).
;   tangent байт = atan2(dy, dx): 0=right, 64=down, 128=left, 192=up.
;   Чтобы face шёл по track-направлению, поворачиваем на (tangent - 64),
;   то есть для tangent=64 (= down) поворот=0 (face остаётся внизу = вдоль
;   движения). Эквивалент `ADD A, 192` (= -64 mod 256).
; ----------------------------------------------------------------------------
ZL_EmitRotate:  ADD  A, 192                          ; offset native face direction
                LD   D, A : LD E, 0
                LD   (ZL_TmpAngle), DE
                LD   DE, FT_CMD_ROTATE & #FFFF
                LD   BC, FT_CMD_ROTATE >> 16
                CALL FT.Coprocessor.Command_BCDE
                LD   BC, 0
                LD   DE, (ZL_TmpAngle)
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitSetMatrix — append cmd_setmatrix (4 байт opcode).
; Применяет текущую coprocessor матрицу как BITMAP_TRANSFORM_A..F (6 DL cmds).
; ----------------------------------------------------------------------------
ZL_EmitSetMatrix:
                LD   DE, FT_CMD_SETMATRIX & #FFFF
                LD   BC, FT_CMD_SETMATRIX >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_AimUpdate — detect mouse motion (с threshold для подавления Hyper-V Kempston
; jitter) + keyboard arrows меняют Frog_Angle напрямую.
;
; Архитектура (1:1 с VDC коллеги): Frog_Angle = primary state (8-bit BRAD wraps
; → 360° автоматом). Если мышь двинулась — set ZL_MouseMoved=1, иначе =0.
; Frog_Update вызывает ComputeFrogAngle ТОЛЬКО при ZL_MouseMoved=1 — иначе
; угол от клавиш сохраняется. Combine, не mode-toggle: клавиши применяются
; КАЖДЫЙ кадр (до atan2-проверки), мышь wins при движении.
;
; Threshold ZL_MOTION_THR = 3 px подавляет Hyper-V jitter ±1-2 px (без
; threshold курсор постоянно «дрожит» → MouseMoved всегда=1 → клавиши никогда
; не работают).
; ----------------------------------------------------------------------------
ZL_KBD_STEP     EQU 4                                 ; BRAD/frame, ≈1.4°/frame ≈ 80°/sec @57Hz
ZL_MOTION_THR   EQU 3                                 ; px threshold для motion detection

ZL_AimUpdate:
                ; FM_EN постоянно ON в нашей сборке (нужен для page mapping
                ; через FMADDR_REGS). Это ломает port reads на #FE (TS-Conf
                ; перенаправляет некоторые keyboard rows на регистры). Временно
                ; выключаем FM_EN на время keyboard reads, потом включаем обратно.
                LD   BC, FMADDR
                XOR  A
                OUT  (C), A
                ; --- 1. Apply keyboard к Frog_Angle (LEFT = ←/O, RIGHT = →/P) ---
                ; Spectrum keyboard читаем напрямую port'ом #DFFE (row Y..P).
                ; bit 0 = P, bit 1 = O. Active LOW (pressed = bit clear).
                ; (TSLib Spectrum.KeyState ожидает INDEX в таблицу, а SVK_X
                ; константы = bit mask — не годится для прямого вызова.)
                LD   A, Input.VK_KEMPSTON_LEFT
                CALL Input.Kempston.KeyState
                JR   NZ, .do_left
                LD   BC, #DFFE
                IN   A, (C)
                BIT  1, A                             ; O (bit 1)
                JR   NZ, .check_right                 ; bit set → released → skip
.do_left:       LD   A, (Frog_Angle)
                SUB  ZL_KBD_STEP                      ; 8-bit wraps
                LD   (Frog_Angle), A

.check_right:   LD   A, Input.VK_KEMPSTON_RIGHT
                CALL Input.Kempston.KeyState
                JR   NZ, .do_right
                LD   BC, #DFFE
                IN   A, (C)
                BIT  0, A                             ; P (bit 0)
                JR   NZ, .check_fire                  ; не нажата → не пропускаем fire-check
.do_right:      LD   A, (Frog_Angle)
                ADD  A, ZL_KBD_STEP
                LD   (Frog_Angle), A

.check_fire:    ; FIRE = SPACE (port #7FFE bit 0) ИЛИ Kempston FIRE (port #1F bit 4).
                LD   BC, #7FFE
                IN   A, (C)
                BIT  0, A                             ; SPACE (bit 0, active LOW)
                JR   Z, .fire_pressed
                LD   A, Input.VK_KEMPSTON_B          ; bit 4 = Kempston FIRE
                CALL Input.Kempston.KeyState
                JR   NZ, .fire_pressed                ; Kempston active HIGH (NZ = pressed)
                XOR  A
                LD   (Frog_KeySpacePrev), A
                JR   .check_motion
.fire_pressed:  CALL Frog_FireKeyboard                ; внутри debounce KeySpacePrev

                ; --- 2. Detect mouse motion (|raw - prev| ≥ ZL_MOTION_THR) ---
.check_motion:  XOR  A
                LD   (ZL_MouseMoved), A               ; default = 0
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, (ZL_PrevRawX)
                AND  A
                SBC  HL, DE                           ; HL = raw_X - prev_X (signed)
                CALL ZL_AbsHL
                LD   DE, ZL_MOTION_THR
                AND  A
                SBC  HL, DE
                JR   NC, .motion                      ; |dx| ≥ threshold
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, (ZL_PrevRawY)
                AND  A
                SBC  HL, DE
                CALL ZL_AbsHL
                LD   DE, ZL_MOTION_THR
                AND  A
                SBC  HL, DE
                JR   C, ZL_FmEnRestore                ; |dy| < threshold → no motion

.motion:        ; Mouse moved → set flag + save prev_raw.
                LD   A, 1
                LD   (ZL_MouseMoved), A
                LD   HL, (Input.Mouse.PositionX)
                LD   (ZL_PrevRawX), HL
                LD   HL, (Input.Mouse.PositionY)
                LD   (ZL_PrevRawY), HL
                JR   ZL_FmEnRestore

; Все RET в ZL_AimUpdate выше → ZL_FmEnRestore (включить FM_EN обратно).
ZL_FmEnRestore: LD   BC, FMADDR
                LD   A, FM_EN
                OUT  (C), A
                RET

; ----------------------------------------------------------------------------
; ZL_Mul16x8 — unsigned 16x8 multiply, low 16 bits of result.
;   In:  HL = multiplicand (unsigned 16-bit), A = multiplier (unsigned 8-bit)
;   Out: HL = (HL_in * A_in) & #FFFF
;   Scratch: BC, A, F. ~14 байт, ~155 t-states avg.
;   Используется для runtime K в spin formula (по 1 вызову на шар цепи).
; ----------------------------------------------------------------------------
ZL_Mul16x8:     LD   C, L : LD B, H                   ; BC = multiplicand
                LD   HL, 0                             ; HL = accumulator
                LD   D, 8                             ; bit counter
.lp:            ADD  HL, HL                            ; HL <<= 1
                ADD  A, A                             ; CF = top bit of multiplier
                JR   NC, .skip
                ADD  HL, BC                            ; if bit set → +BC
.skip:          DEC  D
                JR   NZ, .lp
                RET

; ----------------------------------------------------------------------------
; ZL_AbsHL — HL = |HL| (16-bit signed → unsigned magnitude).
; ----------------------------------------------------------------------------
ZL_AbsHL:       BIT  7, H
                RET  Z
                LD   A, H : CPL : LD H, A
                LD   A, L : CPL : LD L, A
                INC  HL
                RET


; ----------------------------------------------------------------------------
; ZL_SmoothMouse — exponential low-pass filter (alpha = 1/4):
;   smooth = (smooth*3 + raw) / 4
; Убирает jitter от Kempston-эмулятора через Hyper-V. Latency ~3-4 кадра.
; ----------------------------------------------------------------------------
ZL_SmoothMouse: LD   HL, (ZL_SmoothX)
                LD   D, H : LD E, L                   ; DE = old
                ADD  HL, DE
                ADD  HL, DE                           ; HL = old*3
                LD   DE, (Input.Mouse.PositionX)
                ADD  HL, DE                           ; HL = old*3 + raw
                SRL  H : RR L
                SRL  H : RR L                         ; HL /= 4
                LD   (ZL_SmoothX), HL

                LD   HL, (ZL_SmoothY)
                LD   D, H : LD E, L
                ADD  HL, DE
                ADD  HL, DE
                LD   DE, (Input.Mouse.PositionY)
                ADD  HL, DE
                SRL  H : RR L
                SRL  H : RR L
                LD   (ZL_SmoothY), HL
                RET

; ----------------------------------------------------------------------------
; ZL_UpdateGame — переместить точку, отскок от краёв
; ----------------------------------------------------------------------------
ZL_UpdateGame:
                ; --- X axis ---
                LD   HL, (ZL_PointX)
                LD   DE, (ZL_VelX)
                ADD  HL, DE
                LD   (ZL_PointX), HL

                ; if X >= MAX → clamp + invert VelX
                LD   DE, ZL_PT_MAX_X
                AND  A
                SBC  HL, DE                           ; HL = X - MAX
                JR   C, .X_under_max                  ; X < MAX → дальше проверим MIN
                LD   HL, ZL_PT_MAX_X
                LD   (ZL_PointX), HL
                LD   HL, ZL_VelX
                CALL ZL_NegateW
                JR   .Y_axis

.X_under_max    ; X < MAX. Если X < MIN — clamp + invert.
                LD   HL, (ZL_PointX)
                LD   DE, ZL_PT_MIN_X
                AND  A
                SBC  HL, DE
                JR   NC, .Y_axis                      ; X >= MIN → ОК
                LD   HL, ZL_PT_MIN_X
                LD   (ZL_PointX), HL
                LD   HL, ZL_VelX
                CALL ZL_NegateW

.Y_axis         ; --- Y axis (зеркальная логика) ---
                LD   HL, (ZL_PointY)
                LD   DE, (ZL_VelY)
                ADD  HL, DE
                LD   (ZL_PointY), HL

                LD   DE, ZL_PT_MAX_Y
                AND  A
                SBC  HL, DE
                JR   C, .Y_under_max
                LD   HL, ZL_PT_MAX_Y
                LD   (ZL_PointY), HL
                LD   HL, ZL_VelY
                CALL ZL_NegateW
                RET

.Y_under_max    LD   HL, (ZL_PointY)
                LD   DE, ZL_PT_MIN_Y
                AND  A
                SBC  HL, DE
                RET  NC                                ; Y >= MIN → done
                LD   HL, ZL_PT_MIN_Y
                LD   (ZL_PointY), HL
                LD   HL, ZL_VelY
                CALL ZL_NegateW
                RET

; ----------------------------------------------------------------------------
; ZL_NegateW — двухбайтовая negation: (HL) = -(HL) (как 16-bit signed word)
; ----------------------------------------------------------------------------
ZL_NegateW:     LD   A, (HL)
                CPL
                ADD  A, 1
                LD   (HL), A
                INC  HL
                LD   A, (HL)
                CPL
                ADC  A, 0
                LD   (HL), A
                RET

; ----------------------------------------------------------------------------
; Game state в коде (data section). DEFW = 2 байта LE.
; При SAVEBIN эти ячейки попадают в .bin — на старте у них валидные значения,
; MainLoop их сразу переписывает (см. начало MainLoop).
; ----------------------------------------------------------------------------
ZL_PointX:      DEFW 0
ZL_PointY:      DEFW 0
ZL_VelX:        DEFW 0
ZL_VelY:        DEFW 0
ZL_FrameCounter:DEFW 0
ZL_SmoothX:     DEFW 320                              ; центр 640×480
ZL_SmoothY:     DEFW 240
ZL_PrevRawX:    DEFW 320                              ; raw mouse prev — для motion detection
ZL_PrevRawY:    DEFW 240
ZL_MouseMoved:  DEFB 0                                ; 0=stationary, 1=moved (≥THR per axis)
ZL_ChainHSA:    DEFW 0                                ; head sample на треке
ZL_ChainTick:   DEFB 0                                ; subdivider 4 для медленного движения
ZL_ColorIdx:    DEFB 0                                ; текущий cell для CELL()-эмита в цепи
ZL_TmpFrame:    DEFB 0                                ; spin frame idx 0..7 (chain rendering)
ZL_TmpTx:       DEFW 0                                ; ZL_EmitTranslate scratch X
ZL_TmpTy:       DEFW 0                                ; ZL_EmitTranslate scratch Y
ZL_TmpAngle:    DEFW 0                                ; ZL_EmitRotate scratch angle
ZL_TmpBallX:    DEFW 0                                ; chain render: текущий шар X (px)
ZL_TmpBallY:    DEFW 0                                ; chain render: текущий шар Y (px)
ZL_TmpAngleByte:DEFB 0                                ; chain render: combined rotation byte
ZL_SpinK:       DEFB ZL_SPIN_K_DEFAULT                ; runtime spin multiplier (per-level)
ZL_BallCount:   DEFB 0                                ; cached VDC_SlotsLen для bucket prepass
ZL_TmpBucket:   DEFB 0                                ; current bucket в outer loop
ZL_CacheWPtr:   DEFW 0                                ; write ptr в prepass
                ; Per-ball cache: bucket, cell, Vx_lo, Vx_hi, Vy_lo, Vy_hi = 6 байт.
                ; bucket = #FF → skip (gap/off-track).
                ; Размещён в свободной зоне slot 1 ниже Core (page 5 #4000-#5FFF),
                ; чтобы 1440 байт cache не раздували Core за границу 8 КБ (#7FFF).
ZL_BALL_CACHE_ADDR EQU #4200                          ; (max 240 × 6 = 1440 = #5A0; до #47A0)

                endif ; ~_ZUMA_MAIN_LOOP_

```

### 2.VDC.asm

VDC chain physics: MoveChain, AnimateChain (decay), CheckMatch3/DetectMatch3, DoGapStep, InsertAt, RemoveSlotAt, SpawnChainBall, ShiftRight_*, SlotPos/SlotT, GameOver absorption (state machine)

```asm

                ifndef _ZUMA_VDC_
                define _ZUMA_VDC_

; ============================================================================
; VDC — Virtual Discrete Chain physics для Zuma VDAC2 (640x480).
; ----------------------------------------------------------------------------
; Порт vdc_visual_emulator.py 1:1. Отличия от 360x288 asm-версии:
;   - CELL_SIZE = 64 (вместо 32), все производные пересчитаны.
;   - HSA word (вместо byte) — track 640x480 длиннее (~2762 sample / 64 = ~43 slot,
;     помещается в byte, но держим word для запаса под длинные уровни).
;   - LastRenderPos НЕ хранится: при t<0 рендер skip. Trade-off: при cascade
;     rollback шары на спавне на 1-2 кадра становятся невидимыми. Можно добавить
;     потом как опциональный массив.
;   - Без EXPLOSION_FRAMES анимации (Slots[lb..rb] сразу = GAP). Explosion
;     отдельным TSU-слоем, как в v6/v7 360x288, добавится позже.
;
; API:
;   VDC_Init       — обнулить все массивы, Slots[] = GAP_STOP, RNG seed.
;   VDC_Update     — TrySpawn + MoveChain + AnimateChain. Один вызов = один кадр.
;   VDC_SlotPos    — для слота A считает (X,Y) центра шара.
;                    Out: BC=X, DE=Y, CF=1 если skip (gap или t<0).
;   VDC_InsertAt   — A=target_idx, B=color. Вставить шар, проверить match.
;
; Все функции корраптят AF/BC/DE/HL.
; TrackData layout (page 6 в slot 2 #8000):
;   word LE NumSamples, затем NumSamples * (sword X, sword Y).
; ============================================================================

VDC_LEVEL_START_BALLS  EQU 35                            ; быстрая фаза: 35 шаров «поездом»
VDC_FAST_ADVANCE       EQU 12                            ; MoveChain ×12 за tick в fast-фазе
VDC_CELL_SIZE          EQU 32                            ; sample-units на slot.
VDC_DECAY_NEG          EQU 2                             ; insert head slide (neg→0) быстро.
VDC_DECAY_POS          EQU 1                             ; cascade rollback (pos→0) плавно.
                                                          ; track chord 1.0815 px/sample: 32×1.08 ≈ 34.6 px
                                                          ; centers, ball 32 px → gap ~2.6 px на прямой.
                                                          ; Используется в VDC_SlotT через ZL_Mul16x8.
                                                         ; track 1.067 px/sample → 42*1.067 ≈ 45 px
                                                         ; между центрами при ball=40 → 5 px gap
                                                         ; (= touching, как в оригинале Zuma).
VDC_MAX_SLOTS          EQU 240
VDC_GAP_STOP           EQU #FE
VDC_GAP_CASCADE        EQU #FD
VDC_NUM_COLORS         EQU 4                             ; classic Zuma level 1: colors="4"
VDC_GAP_STEP_FRAMES    EQU VDC_CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX EQU 10                            ; ~CELL_SIZE/4
VDC_BALLS_TARGET       EQU 85                            ; classic level 1: start 35 + repeat 50 = 85

; ============================================================================
; VDC_Init — обнулить state, Slots[] = GAP_STOP. Должен быть вызван 1 раз
; до любого VDC_Update / VDC_SlotPos / VDC_InsertAt.
; ============================================================================
VDC_Init:
                ; Слоты: 240 байт = GAP_STOP
                LD   HL, VDC_Slots
                LD   DE, VDC_Slots + 1
                LD   BC, VDC_MAX_SLOTS - 1
                LD   (HL), VDC_GAP_STOP
                LDIR

                ; Offsets, Shot2 — все 0
                LD   HL, VDC_Offsets
                LD   DE, VDC_Offsets + 1
                LD   BC, (VDC_MAX_SLOTS * 2) - 1
                LD   (HL), 0
                LDIR

                ; Скаляры — нулим простым LD
                XOR  A
                LD   (VDC_HSA),                A
                LD   (VDC_HSub),               A
                LD   (VDC_SlotsLen),           A
                LD   (VDC_ChainFreezeCnt),     A
                LD   (VDC_GapStepCnt),         A
                LD   (VDC_BallsSpawned),       A
                LD   (VDC_MatchScanIdx),       A

                ; Запомнить TRACK_NUM_SLOTS (= NumSamples / CELL_SIZE - 1) —
                ; используется как cap для HSA. NumSamples лежит в TrackData word.
                LD   HL, (TrackData)                  ; HL = NumSamples
                LD   A, VDC_CELL_SIZE
                CALL VDC_DivHLbyA                     ; HL = NumSamples / CELL_SIZE
                DEC  HL
                LD   (VDC_TrackNumSlots), HL

                ; LFSR seed: базовый #ACE1, scramble через RTC секунды (low_byte ×
                ; RTC_sec) — каждый запуск получает разную starting sequence, как
                ; у коллеги в TS-Conf версии (RandomChainColor scramble).
                LD   HL, #ACE1
                LD   (VDC_LfsrSeed), HL
                CALL ReadRTCSeconds                    ; A = 0..59
                OR   A
                JR   NZ, .seed_have_sec
                LD   A, 17                             ; защита если RTC = 0
.seed_have_sec:
                LD   D, A : LD E, A                    ; DE = RTC sec (multiplier)
                LD   HL, (VDC_LfsrSeed)
                LD   A, L                              ; A = low seed byte
                LD   HL, 0
                LD   B, 8
.seed_mul:
                ADD  HL, HL
                SLA  A
                JR   NC, .seed_no_add
                ADD  HL, DE
.seed_no_add:
                DJNZ .seed_mul
                ; HL = low_seed * RTC_sec. Гарантируем non-zero.
                LD   A, H : OR L
                JR   NZ, .seed_ok
                LD   HL, #1234
.seed_ok:
                LD   (VDC_LfsrSeed), HL
                RET


; ============================================================================
; ReadRTCSeconds — TS-Conf GLUK CMOS RTC, регистр 0 (секунды BCD).
; Порты #DFF7 (адрес) / #BFF7 (данные). Out: A = 0..59 binary.
; ============================================================================
ReadRTCSeconds:
                LD   BC, #DFF7
                XOR  A
                OUT  (C), A                            ; reg 0 = seconds
                LD   BC, #BFF7
                IN   A, (C)                            ; A = BCD seconds
                LD   B, A
                AND  $0F                               ; low nibble
                LD   C, A
                LD   A, B
                AND  $F0
                SRL  A : SRL A : SRL A : SRL A         ; high nibble (0..5)
                LD   B, A
                ; A = high*10 + low
                ADD  A, A : ADD A, A : ADD A, B        ; *5
                ADD  A, A                              ; *10
                ADD  A, C
                RET

; ============================================================================
; VDC_Update — один шаг физики (вызывать раз в кадр).
; Phase 1 (BallsSpawned < LEVEL_START_BALLS): 12× MoveChain + 1× AnimateChain +
;   1× TrySpawn (TrySpawn внутри loop'ит). Это «поезд» влёта 35 шаров за ~90 тиков.
; Phase 2 (BallsSpawned ≥ LEVEL_START_BALLS): 1× MoveChain каждый кадр (norm-speed
;   подобран под VDAC2 CELL_SIZE=42 — без subdivider /2 как у коллеги).
; ============================================================================
VDC_Update:
                LD   A, (VDC_BallsSpawned)
                CP   VDC_LEVEL_START_BALLS
                JR   NC, .upd_normal
                ; Fast phase: ×12 MoveChain (35 шаров «поездом»)
                LD   B, VDC_FAST_ADVANCE
.upd_fast:      PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd_fast
                CALL VDC_AnimateChain
                JP   VDC_TrySpawn
.upd_normal:    ; Normal phase (Python 1:1):
                ;   move+animate каждый 2-й кадр (subdivider /2 = classic speed=.5)
                ;   spawn ТОЛЬКО когда (frame & 63) == 0 (= раз в 64 кадра)
                LD   A, (ZL_FrameCounter)
                AND  1
                RET  NZ                                ; odd frame → skip всё
                CALL VDC_MoveChain
                CALL VDC_AnimateChain
                ; spawn timing
                LD   A, (VDC_BallsSpawned)
                CP   VDC_BALLS_TARGET
                RET  NC
                LD   A, (ZL_FrameCounter)
                AND  63
                RET  NZ
                JP   VDC_TrySpawn

; ============================================================================
; VDC_SlotT — для A=i считает t = (HSA-i)*64 + HSub + sext(offsets[i]).
; Out: HL = signed 16-bit t.  AF/DE clobber.
; ============================================================================
VDC_SlotT:
                LD   C, A                             ; C = i
                LD   A, (VDC_HSA)
                SUB  C
                JR   NC, .delta_ok
                XOR  A                                ; clamp 0 (i > HSA)
.delta_ok:
                ; HL = (HSA - i) × VDC_CELL_SIZE через generic mul (sub from MainLoop).
                ; A still holds delta (HSA - i); save i (=C from caller) first.
                LD   H, 0 : LD L, A                    ; HL = delta
                PUSH BC                                 ; save i
                LD   A, VDC_CELL_SIZE
                CALL ZL_Mul16x8                        ; HL = delta × CELL_SIZE
                POP  BC                                 ; restore i

                ; + HSub (0..63 unsigned)
                LD   A, (VDC_HSub)
                LD   E, A
                LD   D, 0
                ADD  HL, DE

                ; + sext(offsets[i])
                LD   A, C
                PUSH HL
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .off_pos
                DEC  D                                ; sign-extend
.off_pos:
                POP  HL
                ADD  HL, DE
                RET

; ============================================================================
; VDC_SlotPos — для A=i возвращает центр шара (X,Y) из TrackData[t].
;   Out: BC = X (signed word), DE = Y (signed word), CF = 0 если рисуем,
;        CF = 1 если skip (gap или t<0).
;   AF, HL clobber.
; ============================================================================
VDC_SlotPos:
                ; --- skip if gap ---
                LD   C, A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .not_gap
                SCF                                    ; CF=1, skip
                RET
.not_gap:
                LD   A, C
                CALL VDC_SlotT                         ; HL = t
                ; t < 0 → skip
                BIT  7, H
                JR   Z, .t_nonneg
                SCF
                RET
.t_nonneg:
                ; t >= NumSamples → clamp to NumSamples-1
                PUSH HL
                LD   DE, (TrackData)                   ; NumSamples
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .t_in
                LD   HL, (TrackData)
                DEC  HL
.t_in:
                ; expose t для caller (используется для spin frame по track-advance)
                LD   (VDC_LastT), HL
                ; HL_addr = TrackData + 2 + t*5  (stride 5 = X word + Y word + tangent byte)
                LD   D, H : LD E, L                    ; DE = t
                ADD  HL, HL : ADD HL, HL               ; *4
                ADD  HL, DE                            ; *5
                LD   DE, TrackData + 2
                ADD  HL, DE
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   C, (HL) : INC HL
                LD   B, (HL) : INC HL                  ; BC = Y
                LD   A, (HL)                           ; A = tangent byte 0..255
                LD   (VDC_LastTangent), A              ; expose для caller
                EX   DE, HL                            ; HL = X (free up DE)
                LD   D, B : LD E, C                    ; DE = Y
                LD   B, H : LD C, L                    ; BC = X
                AND  A                                 ; CF = 0
                RET

; ============================================================================
; VDC_TrySpawn — спавн нового шара в хвост (если разрешено).
;   Условия: SlotsLen<MAX, BallsSpawned<TARGET, HSA>=SlotsLen, HSub==0.
; ============================================================================
VDC_TrySpawn:
                LD   A, (VDC_BallsSpawned)
                CP   VDC_BALLS_TARGET
                RET  NC
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; HSA < SlotsLen → не спавним (хвост не достиг старта)
                LD   B, A                              ; B = SlotsLen
                LD   A, (VDC_HSA)
                CP   B
                RET  C

                ; SlotsLen > 0 AND offsets[tail-1] != 0 → не спавним (хвост ещё двигается).
                ; Python 1:1. HSub==0 gate УБРАН — Python `try_spawn` без него (см. чат
                ; коллеги). Без этого fix fast-phase spawn'ит 0 шаров если HSub != 0
                ; в момент tick'а.
                LD   A, B
                OR   A
                JR   Z, .spawn_no_tail_check
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ
.spawn_no_tail_check:
                ; --- color = RandomColor() ---
                CALL VDC_RandomColor                   ; A = 0..NUM_COLORS-1

                ; --- anti-3-spawn-guard ---
                ; Если SlotsLen>=2 и Slots[len-1]==Slots[len-2]==candidate → +1 mod NUM
                LD   B, A                              ; B = candidate
                LD   A, (VDC_SlotsLen)
                CP   2
                JR   C, .spawn_no_guard
                DEC  A                                 ; len-1
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)                           ; Slots[len-1]
                CP   B
                JR   NZ, .spawn_no_guard
                DEC  HL
                LD   A, (HL)                           ; Slots[len-2]
                CP   B
                JR   NZ, .spawn_no_guard
                ; collision: candidate++ mod NUM_COLORS
                LD   A, B
                INC  A
                CP   VDC_NUM_COLORS
                JR   C, .guard_ok
                XOR  A
.guard_ok:
                LD   B, A
.spawn_no_guard:
                ; --- Slots[SlotsLen] = candidate ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   (HL), B

                ; --- offsets[SlotsLen] = (SlotsLen>0) ? offsets[SlotsLen-1] : 0 ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .spawn_off_zero
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   B, (HL)                           ; B = offsets[len-1]
                JR   .spawn_off_set
.spawn_off_zero:
                LD   B, 0
.spawn_off_set:
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   (HL), B

                ; --- Shot2[SlotsLen] = 0 ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 0

                ; --- SlotsLen++, BallsSpawned++ ---
                LD   HL, VDC_SlotsLen
                INC  (HL)
                LD   HL, VDC_BallsSpawned
                INC  (HL)
                RET                                    ; single-shot per tick (= Python коллеги).
                                                       ; Множественный spawn даёт instant chain growth = дёрганость.

; ============================================================================
; VDC_MoveChain — HSub++ если chain не frozen; wrap → HSA++.
; ============================================================================
VDC_MoveChain:
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                JR   Z, .mc_no_freeze
                DEC  A
                LD   (VDC_ChainFreezeCnt), A
                RET
.mc_no_freeze:
                LD   A, (VDC_HSub)
                INC  A
                CP   VDC_CELL_SIZE
                JR   C, .mc_save_sub
                XOR  A
                LD   (VDC_HSub), A
                ; HSA++ с cap по TrackNumSlots-1
                LD   HL, (VDC_TrackNumSlots)           ; max
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   Z, .mc_at_max                     ; HSA == max → stop
                JR   C, .mc_at_max
                LD   HL, VDC_HSA
                INC  (HL)
.mc_at_max:
                RET
.mc_save_sub:
                LD   (VDC_HSub), A
                RET

; ============================================================================
; VDC_AnimateChain — decay offsets к 0 ±1, gap_step_counter, при wrap → DoGapStep.
; После — ScanForNewMatch + UpdateStall.
; ============================================================================
VDC_AnimateChain:
                ; --- 1. decay offsets (rollback_counter не реализован — нет
                ; кода который бы его выставлял; декай идёт сразу к 0).
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ac_after_decay
                LD   B, A
                LD   HL, VDC_Offsets
.ac_decay:
                LD   A, (HL)
                OR   A
                JR   Z, .ac_decay_skip
                BIT  7, A
                JR   NZ, .ac_decay_neg
                SUB  VDC_DECAY_POS                     ; pos (cascade rollback) → 0 плавно
                JR   NC, .ac_decay_store
                XOR  A                                 ; clamp 0
                JR   .ac_decay_store
.ac_decay_neg:  ADD  A, VDC_DECAY_NEG                  ; neg (insert head slide) → 0 быстро
                JR   Z, .ac_decay_store
                BIT  7, A
                JR   NZ, .ac_decay_store               ; ещё отрицательный
                XOR  A                                 ; overshoot → 0
.ac_decay_store:
                LD   (HL), A
.ac_decay_skip:
                INC  HL
                DJNZ .ac_decay
.ac_after_decay:
                ; --- 2. GapStepCnt++; при cnt>=GAP_STEP_FRAMES → DoGapStep (без
                ; hsub==0 constraint, иначе зазор между decay-end и next gap_step
                ; → head moves forward; см. Python emulator + чат 2026-05-12).
                LD   A, (VDC_GapStepCnt)
                INC  A
                LD   (VDC_GapStepCnt), A
                CP   VDC_GAP_STEP_FRAMES
                JR   C, .ac_no_gap_step
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
.ac_no_gap_step:
                ; --- 3. Persistent scan. ---
                CALL VDC_ScanForNewMatch
                RET

; ============================================================================
; VDC_DetectMatch3 — для idx в (TmpInsIdx) ищет run >= 3 одинаковых цветов
; вокруг idx с offset gap check'ом. Out: A=1 если матч (TmpML/TmpMR/TmpMC заполнены),
; A=0 иначе.
; ============================================================================
VDC_DetectMatch3:
                LD   A, (VDC_SlotsLen)
                OR   A
                JP   Z, .dm3_no
                LD   A, (VDC_TmpInsIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JP   NC, .dm3_no                       ; idx>=len

                ; color = Slots[idx]
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JP   NC, .dm3_no                       ; gap → не центр
                LD   (VDC_TmpMC_Color), A

                ; --- left scan ---
                LD   A, (VDC_TmpInsIdx)
                LD   B, A                              ; B = idx
.dm3_l:
                LD   A, B
                OR   A
                JR   Z, .dm3_l_done
                DEC  A                                 ; A = B-1
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_l_done

                ; offset gap: -CS <= (off[B-1]-off[B]) < GAP_MAX (= [-CS..GAP_MAX-1])
                LD   A, B
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   C, A                              ; C = off[B-1]
                LD   A, B
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                SUB  C                                 ; off[B] - off[B-1]
                NEG                                    ; -> off[B-1] - off[B]
                ADD  A, VDC_CELL_SIZE                  ; +CS (shift to unsigned [0..2*CS])
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_l_done

                DEC  B
                JR   .dm3_l
.dm3_l_done:
                LD   A, B
                LD   (VDC_TmpML), A

                ; --- right scan ---
                LD   A, (VDC_TmpInsIdx)
                LD   C, A                              ; C = idx
.dm3_r:
                LD   A, C
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .dm3_r_done
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_r_done

                ; offset gap для right
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A                              ; B = off[C]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                SUB  B                                 ; off[C+1] - off[C]
                NEG                                    ; -> off[C] - off[C+1]
                ADD  A, VDC_CELL_SIZE
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_r_done

                INC  C
                JR   .dm3_r
.dm3_r_done:
                LD   A, C
                LD   (VDC_TmpMR), A

                ; count = right - left + 1
                LD   A, (VDC_TmpML)
                LD   B, A
                LD   A, C
                SUB  B
                INC  A
                CP   3
                JR   C, .dm3_no
                LD   (VDC_TmpMCount), A
                LD   A, 1
                RET
.dm3_no:
                XOR  A
                RET

; ============================================================================
; VDC_CheckMatch3 — DetectMatch3 + если матч: GAP_STOP/GAP_CASCADE marker, Slots/Offsets,
; Shot2 на соседях, ChainStalled, GapStepCnt=GAP_STEP_FRAMES, ChainFreezeCnt=CELL_SIZE.
; A=1 если был матч, A=0 иначе.
; ============================================================================
VDC_CheckMatch3:
                CALL VDC_DetectMatch3
                OR   A
                JP   Z, .m3_no

                ; default marker GAP_STOP
                LD   B, VDC_GAP_STOP

                ; CASCADE check: lb>0 & rb+1<len & Slots[lb-1] и Slots[rb+1] обe non-gap
                ; и одного цвета.
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_have_marker                ; lb=0 → STOP
                LD   HL, VDC_SlotsLen
                LD   A, (VDC_TmpMR)
                INC  A
                CP   (HL)
                JR   NC, .m3_have_marker               ; rb+1>=len → STOP

                LD   A, (VDC_TmpML)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   C, (HL)                           ; C = Slots[lb-1]
                LD   A, C
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP

                LD   A, (VDC_TmpMR)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP
                CP   C
                JR   NZ, .m3_have_marker
                LD   B, VDC_GAP_CASCADE
.m3_have_marker:
                ; Slots[lb..rb] = B, Offsets[lb..rb] = 0, Shot2[lb..rb] = 0
                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_slots:
                LD   (HL), B
                INC  HL
                DEC  C
                JR   NZ, .m3_set_slots

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_offs:
                LD   (HL), 0
                INC  HL
                DEC  C
                JR   NZ, .m3_set_offs

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_shot2_clr:
                LD   (HL), 0
                INC  HL
                DEC  C
                JR   NZ, .m3_set_shot2_clr

                ; Shot2[lb-1]=1 если lb>0
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_no_left_shot2
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.m3_no_left_shot2:
                ; Shot2[rb+1]=1 если rb+1<len
                LD   A, (VDC_TmpMR)
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .m3_no_right_shot2
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.m3_no_right_shot2:
                ; Instant gap_step — иначе chain motion в waiting period (до hsub=0)
                ; двигает head вперёд, а должен стоять и ждать хвост. С первым
                ; instant gap_step head получает +CS offset compensation сразу
                ; → stationary до конца decay phase. Остальные markers ждут
                ; следующего GAP_STEP_FRAMES (без hsub=0 constraint).
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
                LD   A, 1
                RET
.m3_no:
                XOR  A
                RET

; ============================================================================
; VDC_DoGapStep — обрабатывает ОДИН маркер за вызов. Pass 1: STOP from tail
; (right→left), удаляет slot, HSA--, head compensation. Pass 2 (если STOP не было):
; CASCADE from head (left→right), то же + ChainFreezeCnt = CELL_SIZE.
; ============================================================================
VDC_DoGapStep:
                ; --- Pass 1: ищем последний GAP_STOP справа налево ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JP   Z, .dgs_cascade_init
                DEC  A
                LD   C, A                              ; C = idx (от len-1)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE                            ; HL = &Slots[len-1]
.dgs_stop_scan:
                LD   A, (HL)
                CP   VDC_GAP_STOP
                JR   Z, .dgs_stop_found
                LD   A, C
                OR   A
                JP   Z, .dgs_cascade_init
                DEC  C
                DEC  HL
                JR   .dgs_stop_scan

.dgs_stop_found:
                LD   A, C
                LD   (VDC_TmpGapIdx), A
                CALL VDC_RemoveSlotAt                  ; удаляет slot C, len-=1
                CALL VDC_HsaDec                        ; HSA-- если >0

                ; offsets[0..K-1] = min(off[j]+CS, CS) — head compensation
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_stop_no_off
                LD   B, A                              ; B = K
                LD   HL, VDC_Offsets
.dgs_stop_off:
                ; Python: s.offsets[k] = min(s.offsets[k] + CELL_SIZE, CELL_SIZE)
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE + 1
                JR   C, .dgs_stop_off_save             ; A ≤ CELL_SIZE → save
                LD   A, VDC_CELL_SIZE                  ; cap
.dgs_stop_off_save:
                LD   (HL), A
                INC  HL
                DJNZ .dgs_stop_off
.dgs_stop_no_off:
                ; MatchScanIdx = K (для информативности; persistent scan по Shot2 всё равно ловит)
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                ; Shot2 на соседях K-1 и K (после shift), если они non-gap.
                CALL VDC_SetShot2OnNeighbors
                RET

.dgs_cascade_init:
                ; --- Pass 2: ищем первый GAP_CASCADE слева ---
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = len
                LD   C, 0                              ; C = idx
                LD   HL, VDC_Slots
.dgs_casc_scan:
                LD   A, (HL)
                CP   VDC_GAP_CASCADE
                JR   Z, .dgs_casc_found
                INC  HL
                INC  C
                DEC  B
                JR   NZ, .dgs_casc_scan
                RET

.dgs_casc_found:
                LD   A, C
                LD   (VDC_TmpGapIdx), A
                CALL VDC_RemoveSlotAt
                CALL VDC_HsaDec

                ; head comp
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_casc_no_off
                LD   B, A
                LD   HL, VDC_Offsets
.dgs_casc_off:
                ; Python: s.offsets[k] = min(CELL_SIZE, s.offsets[k] + CELL_SIZE)
                ; Old asm: cap'ил positive offsets к CELL_SIZE INSTEAD ADD — это
                ; давало instant jump на +(CELL_SIZE-offset) при positive mid-decay.
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE + 1
                JR   C, .dgs_casc_off_save             ; A ≤ CELL_SIZE → save
                LD   A, VDC_CELL_SIZE                  ; cap
.dgs_casc_off_save:
                LD   (HL), A
                INC  HL
                DJNZ .dgs_casc_off
.dgs_casc_no_off:
                LD   A, VDC_CELL_SIZE
                LD   (VDC_ChainFreezeCnt), A
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                CALL VDC_SetShot2OnNeighbors
                RET

; ----------------------------------------------------------------------------
; VDC_RemoveSlotAt — удаляет slot (VDC_TmpGapIdx). Shift_left +
; SlotsLen-=1. Затрагивает Slots, Offsets, Shot2, RollbackCnt.
; ----------------------------------------------------------------------------
VDC_RemoveSlotAt:
                LD   A, (VDC_SlotsLen)
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpGapIdx)
                LD   C, A                              ; C = idx
                LD   A, B
                SUB  C
                DEC  A                                 ; count = len - idx - 1
                JR   Z, .rsa_no_shift                  ; idx == len-1 → ничего не двигать
                LD   E, A                              ; E = count

                ; Shift Slots[idx+1..len-1] → Slots[idx..len-2]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE                            ; HL = src = &Slots[idx+1]
                PUSH HL
                LD   D, H : LD E, L
                DEC  DE                                ; DE = dst = &Slots[idx]
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0                    ; BC = count
                LDIR
                POP  HL                                ; (восстановили src=&Slots[idx+1])

                ; Аналогично для Offsets, Shot2, RollbackCnt
                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

.rsa_no_shift:
                LD   HL, VDC_SlotsLen
                DEC  (HL)
                RET

; ----------------------------------------------------------------------------
; VDC_HsaDec — HSA-- если HSA>0, иначе nop.
; ----------------------------------------------------------------------------
VDC_HsaDec:
                LD   A, (VDC_HSA)
                OR   A
                RET  Z
                DEC  A
                LD   (VDC_HSA), A
                RET

; ----------------------------------------------------------------------------
; VDC_SetShot2OnNeighbors — после удаления slot K (TmpGapIdx) поставить Shot2
; на K-1 и K (если non-gap, в bounds).
; ----------------------------------------------------------------------------
VDC_SetShot2OnNeighbors:
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .ssn_skip_left
                ; K-1: проверить < SlotsLen и not gap
                DEC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .ssn_skip_left
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .ssn_skip_left
                LD   A, (VDC_TmpGapIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.ssn_skip_left:
                ; K: проверить < SlotsLen и not gap
                LD   A, (VDC_TmpGapIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .ssn_skip_right
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .ssn_skip_right
                LD   A, (VDC_TmpGapIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.ssn_skip_right:
                RET

; ============================================================================
; VDC_ScanForNewMatch — проходит Shot2[0..len-1], при is_gap чистит, иначе
; CheckMatch3, иначе если settled (все offsets вокруг 0) — чистит Shot2.
; ============================================================================
VDC_ScanForNewMatch:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = iter
                LD   HL, VDC_Shot2
                LD   C, 0                              ; C = idx
.snm_loop:
                LD   A, (HL)
                OR   A
                JP   Z, .snm_next

                ; Slots[C] is gap? → clear Shot2
                PUSH BC
                PUSH HL
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                POP  HL
                POP  BC
                CP   VDC_NUM_COLORS
                JR   C, .snm_check
                LD   (HL), 0
                JP   .snm_next

.snm_check:
                PUSH BC
                PUSH HL
                LD   A, C
                LD   (VDC_TmpInsIdx), A
                CALL VDC_CheckMatch3
                POP  HL
                POP  BC
                OR   A
                RET  NZ                                ; match → выходим

                ; settled check: offset[C], [C-1], [C+1] all 0 → clear Shot2
                PUSH BC
                PUSH HL
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
                LD   A, C
                OR   A
                JR   Z, .snm_check_right
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
.snm_check_right:
                LD   A, C
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .snm_settled
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
.snm_settled:
                POP  HL
                POP  BC
                LD   (HL), 0
                JR   .snm_next
.snm_unsettled:
                POP  HL
                POP  BC
.snm_next:
                INC  HL
                INC  C
                DJNZ .snm_loop
                RET

; ============================================================================
; VDC_InsertAt — вставить шар цвета B в позицию A (=target_idx).
; Shift right Slots/Offsets/Shot2/RollbackCnt[A..len-1] → A+1..len.
; new_off = -CS/2 + (head_off + tail_off)/2.
; HSA++ с cap, offsets[0..A-1] -= CS с cap -CS, ChainFreezeCnt = CS,
; ставит Shot2 на A, CheckMatch3.
; ============================================================================
VDC_InsertAt:
                LD   (VDC_TmpInsIdx), A
                LD   A, B
                LD   (VDC_TmpInsColor), A

                ; clamp target_idx <= SlotsLen
                LD   A, (VDC_TmpInsIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   C, .ia_idx_ok
                LD   A, (HL)
                LD   (VDC_TmpInsIdx), A
.ia_idx_ok:
                ; SlotsLen >= MAX → fail (silent)
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; --- compute new_offset ---
                ; head_off, tail_off:
                ;   slots_len==0           → head=tail=0
                ;   target_idx==0          → head=tail=offsets[0]
                ;   target_idx==slots_len  → head=tail=offsets[len-1]
                ;   else                   → head=offsets[idx-1], tail=offsets[idx]
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   NZ, .ia_off_nonempty
                LD   B, 0 : LD C, 0                    ; head=0, tail=0
                JR   .ia_off_compute
.ia_off_nonempty:
                LD   A, (VDC_TmpInsIdx)
                OR   A
                JR   NZ, .ia_off_not_zero
                ; idx==0
                LD   H, 0 : LD L, 0
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A : LD C, A
                JR   .ia_off_compute
.ia_off_not_zero:
                LD   HL, VDC_SlotsLen
                LD   A, (VDC_TmpInsIdx)
                CP   (HL)
                JR   NZ, .ia_off_middle
                ; idx == slots_len
                LD   A, (HL)                           ; A = len
                DEC  A                                 ; A = len-1
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A : LD C, A
                JR   .ia_off_compute
.ia_off_middle:
                ; head = offsets[idx-1], tail = offsets[idx]
                LD   A, (VDC_TmpInsIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   B, (HL)                           ; B = head_off
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   C, (HL)                           ; C = tail_off
.ia_off_compute:
                ; new_off = -CS/2 + (head + tail) / 2 — все signed бытовое сложение.
                ; Считаем как 16-bit signed для безопасности от переполнения.
                ; head_ext, tail_ext:
                LD   A, B
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .ia_head_ext_pos
                DEC  D
.ia_head_ext_pos:
                PUSH DE                                ; head_ext on stack
                LD   A, C
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .ia_tail_ext_pos
                DEC  D
.ia_tail_ext_pos:
                POP  HL                                ; HL = head_ext
                ADD  HL, DE                            ; HL = head + tail (signed 16)
                ; /2 (signed): SRA H, RR L
                SRA  H : RR L
                LD   DE, -(VDC_CELL_SIZE/2)
                ADD  HL, DE                            ; HL = -CS/2 + (h+t)/2
                ; saturate to signed byte [-128..127]
                LD   A, L
                BIT  7, H
                JR   Z, .ia_off_sat_pos
                ; negative: clamp to -128 if H < #FF
                LD   A, H
                CP   #FF
                JR   Z, .ia_off_neg_byte
                LD   A, #80                            ; -128
                JR   .ia_off_save
.ia_off_neg_byte:
                LD   A, L
                CP   #80
                JR   NC, .ia_off_save                  ; A in [#80..#FF] OK
                LD   A, #80
                JR   .ia_off_save
.ia_off_sat_pos:
                ; positive: H must be 0
                OR   H
                LD   A, L
                JR   Z, .ia_off_save
                LD   A, #7F                            ; +127
.ia_off_save:
                LD   (VDC_TmpInsNewOff), A

                ; --- shift right: Slots[idx..len-1] → idx+1..len ---
                ; Используем LDDR (от хвоста), чтобы не затирать.
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ia_no_shift                   ; len==0 → нечего сдвигать
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpInsIdx)
                CP   B
                JR   NC, .ia_no_shift                  ; idx>=len → нечего сдвигать
                ; count = len - idx
                SUB  B
                NEG                                    ; A = len - idx
                LD   E, A                              ; E = count

                ; Slots: src = &Slots[len-1], dst = &Slots[len], count
                CALL VDC_ShiftRight_Slots

                ; Offsets
                CALL VDC_ShiftRight_Offsets

                ; Shot2
                CALL VDC_ShiftRight_Shot2
.ia_no_shift:
                ; --- Slots[idx] = color, Offsets[idx] = new_off, Shot2[idx]=1 ---
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (VDC_TmpInsColor)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (VDC_TmpInsNewOff)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1

                ; SlotsLen++
                LD   HL, VDC_SlotsLen
                INC  (HL)

                ; HSA++ с cap по TrackNumSlots-1
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   C, .ia_no_hsa_inc
                JR   Z, .ia_no_hsa_inc
                LD   HL, VDC_HSA
                INC  (HL)
.ia_no_hsa_inc:
                ; offsets[0..idx-1] -= CS, cap to -CS (= -64)
                LD   A, (VDC_TmpInsIdx)
                OR   A
                JR   Z, .ia_no_head_comp
                LD   B, A
                LD   HL, VDC_Offsets
.ia_head_comp:
                LD   A, (HL)
                SUB  VDC_CELL_SIZE                     ; off -= CS
                ; cap к -CS (signed): если A < -CELL (signed) → A = -CELL.
                ; Biased compare: (A XOR #80) < (#80 - CELL_SIZE) → clamp.
                PUSH AF
                XOR  #80
                CP   #80 - VDC_CELL_SIZE
                POP  AF
                JR   NC, .ia_head_comp_save            ; A >= -CELL → ОК
                LD   A, 256 - VDC_CELL_SIZE            ; -CELL
.ia_head_comp_save:
                LD   (HL), A
                INC  HL
                DJNZ .ia_head_comp
.ia_no_head_comp:
                ; ChainFreezeCnt НЕ ставим (VDC сосед нашёл: с freeze хвост стоит
                ; CELL_SIZE кадров — некрасиво. Без freeze head_offsets декаят
                ; параллельно с natural hsub advance → head ускоренно уезжает
                ; вперёд на 2 cells за CELL_SIZE кадров, освобождая место.
                ; Tail формально на месте (math: t=(HSA+1−(idx+1))*CS+sub = old t),
                ; spawn-таймер не сбивается. Cascade-close по-прежнему ставит
                ; freeze в DoGapStep. См. Чат.txt 2026-05-09 18:10.)

                ; CheckMatch3 на target_idx (TmpInsIdx уже стоит)
                CALL VDC_CheckMatch3
                RET

; ----------------------------------------------------------------------------
; VDC_ShiftRight_* — сдвиг массива Array[idx..len-1] → Array[idx+1..len].
; Идём через LDDR (HL = src=last, DE = dst=last+1, BC = count).
; Использует VDC_TmpInsIdx, VDC_SlotsLen.
; ----------------------------------------------------------------------------
VDC_ShiftRight_Slots:
                LD   IX, VDC_Slots
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Offsets:
                LD   IX, VDC_Offsets
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Shot2:
                LD   IX, VDC_Shot2
                ; fallthrough
VDC_ShiftRight_Common:
                ; src = Array + (len-1), dst = src+1, count = len - idx
                LD   A, (VDC_SlotsLen)
                DEC  A
                LD   H, 0 : LD L, A
                PUSH IX
                POP  DE                                ; DE = Array
                ADD  HL, DE
                ; HL = src
                LD   D, H : LD E, L
                INC  DE                                ; DE = dst = src+1

                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpInsIdx)
                LD   C, A
                LD   A, B
                SUB  C
                LD   C, A : LD B, 0                    ; BC = count
                LDDR
                RET

; ============================================================================
; VDC_DivHLbyA — целочисленное деление 16-bit на 8-bit.
;   In:  HL = dividend (unsigned), A = divisor (unsigned, > 0)
;   Out: HL = quotient, A = remainder
;   Clobbers BC.
; Bit-by-bit алгоритм. ~80 t-states, ~16 байт кода.
; ============================================================================
VDC_DivHLbyA:
                LD   C, A
                XOR  A
                LD   B, 16
.dv_loop:
                ADD  HL, HL
                RLA
                CP   C
                JR   C, .dv_skip
                SUB  C
                INC  L                                 ; HL[0] был 0 после ADD, теперь 1
.dv_skip:
                DJNZ .dv_loop
                RET

; ============================================================================
; VDC_RandomColor — LFSR Galois 16-bit (poly 0xB400). Out: A = 0..NUM_COLORS-1.
; Распределение: используем (rand8 * NUM_COLORS) >> 8 вместо AND 7 + clamp,
; иначе в 6-цветовом случае colors 0/1 встречаются 2× чаще остальных
; (8 mod 6 = 2 → дубли 6→0 и 7→1). Mul/shift даёт ≤1.4% bias.
; ============================================================================
VDC_RandomColor:
                LD   HL, (VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   Z, .rc_no_xor
                LD   D, #B4 : LD E, 0
                LD   A, H : XOR D : LD H, A
                LD   A, L : XOR E : LD L, A
.rc_no_xor:
                LD   (VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; 8-bit random
                AND  VDC_NUM_COLORS - 1                ; 0..NUM_COLORS-1 (NUM=4 степень 2 → AND 3)
                RET

; ============================================================================
; STATE — массивы и скаляры. SAVEBIN их сохранит как нули; VDC_Init
; явно инициализирует на старте (см. feedback_zuma_init_explicit.md).
; ============================================================================
VDC_Slots:        DS VDC_MAX_SLOTS
VDC_Offsets:      DS VDC_MAX_SLOTS
VDC_Shot2:        DS VDC_MAX_SLOTS

VDC_HSA:           DEFB 0
VDC_HSub:          DEFB 0
VDC_SlotsLen:      DEFB 0
VDC_ChainFreezeCnt:DEFB 0
VDC_GapStepCnt:    DEFB 0
VDC_BallsSpawned:  DEFB 0
VDC_MatchScanIdx:  DEFB 0
VDC_TrackNumSlots: DEFW 0

VDC_TmpInsIdx:    DEFB 0
VDC_TmpInsColor:  DEFB 0
VDC_TmpInsNewOff: DEFB 0
VDC_TmpGapIdx:    DEFB 0
VDC_TmpML:        DEFB 0
VDC_TmpMR:        DEFB 0
VDC_TmpMCount:    DEFB 0
VDC_TmpMC_Color:  DEFB 0

VDC_LfsrSeed:     DEFW 0
VDC_LastTangent:  DEFB 0                                ; tangent байт последнего VDC_SlotPos
VDC_LastT:        DEFW 0                                ; t (16-bit signed) последнего VDC_SlotPos — для spin frame по track-advance

                endif ; ~_ZUMA_VDC_

```

### 2.Frog.asm

Frog: render plate/body/tongue/overlay/ball-in-mouth/next-ball, rotation matrix, recoil animation, fire trigger (mouse/keyboard)

```asm
; ============================================================================
; Frog.asm — рендер лягушки 1:1 с Zuma-Deluxe-HD/src/zuma/Frog.c.
;
; Композиция (Frog_Draw):
;   • plate (no rotation) под body
;   • body с rotation matrix вокруг центра, angle = atan2(mouse - frog).
;     Native sprite face = south (BRAD 64), поэтому ZL_EmitRotate уже делает
;     ADD A,192 (= -64) — передаём raw FrogAngle.
;   • tongue с offset (tongueExpand · dir) и той же rotation matrix вокруг
;     центра sprite. dir = (cos(angle), sin(angle)) (см. SinTable ниже).
;
; Recoil/fire (Frog_Update):
;   ЛКМ rise edge → fireRecoilTick=0, isFire=1, ballExpand=0.
;   Каждый кадр: tick += 10 BRAD (≈0.245 rad ≈ HD 0.25 rad/frame).
;   recoil = sin(tick); пока recoil ≥ 0:
;     tongueExpand = 24 - (recoil * 24) >> 7         ; язык втянут в рот
;     ballExpand   = min(32, ballExpand + 2)         ; вылет шара
;     pos.x = posStart.x - (cos(angle) * recoil) / 2048    ; ≈ -dir*recoil*8/128
;     pos.y = posStart.y - (sin(angle) * recoil) / 2048
;   recoil < 0 → end: tongueExpand=24, ballExpand=32, pos=posStart, isFire=0.
;
; FT812 BITMAP_HANDLE: 2=body, 4=plate, 5=tongue.
; ============================================================================

FROG_SPR_W        EQU 122
FROG_SPR_HALF     EQU 61
FROG_SPR_HALF_NEG EQU -FROG_SPR_HALF & 0xFFFF          ; -61 в 16-bit two's-comp

; Tongue full 122×122 ARGB4 — точный 1:1 перенос из Python visual_emulator.py.
; Pivot UV (61, 61) = sprite centre = HD anchor (native sprite centre 81, 81 в
; 162×162, после resize 162→122).  Screen rect совпадает со sprite size, sprite
; circular fits в square rect при любом угле rotation, без clipping.
FROG_TONGUE_W     EQU 122                               ; sprite W в RAM_G
FROG_TONGUE_H     EQU 122                               ; sprite H в RAM_G
FROG_TONGUE_UV_HW EQU 61                                ; UV pivot = sprite centre
FROG_TONGUE_UV_HH EQU 61
FROG_TONGUE_SCR_W EQU 122
FROG_TONGUE_SCR_H EQU 122
FROG_TONGUE_SCR_HALF EQU 61
FROG_TONGUE_SCR_HALF_NEG EQU -FROG_TONGUE_SCR_HALF & 0xFFFF

; Overlay 122×122 (= same size как body — features alignment ✓).

FROG_RECOIL_STEP  EQU 10                                ; BRAD/frame; π/0.25 ≈ 12.6 кадров полу-периода
FROG_DEFAULT_X    EQU 327
FROG_DEFAULT_Y    EQU 231

FROG_BALL_IDLE    EQU 24                                ; HD: ballExpand idle 24 (= точное Python значение)
FROG_NEXT_OFFSET  EQU 28                                ; HD next-ball orbit (= точное Python значение)
FROG_BALL_W       EQU 32                                ; ball atlas cell native classic 32×32
FROG_BALL_DST_W   EQU 32                                ; screen size = native
FROG_BALL_DST_HALF EQU 16


; ----------------------------------------------------------------------------
; Frog_Init — обнулить state.  F12-reset не reload'ит RAM, поэтому всё
; инициализируется явно.
; ----------------------------------------------------------------------------
Frog_Init:        XOR  A
                  LD   (Frog_Angle), A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_IsFire), A
                  LD   A, 1                            ; pre-init = pressed → no spurious
                  LD   (Frog_PrevMouseLeft), A         ; edge-rise на первом кадре
                  LD   (Frog_KeySpacePrev), A
                  XOR  A
                  LD   A, 24
                  LD   (Frog_TongueExpand), A
                  LD   A, FROG_BALL_IDLE
                  LD   (Frog_BallExpand), A
                  LD   HL, FROG_DEFAULT_X
                  LD   (Frog_PosX), HL
                  LD   (Frog_PosStartX), HL
                  LD   HL, FROG_DEFAULT_Y
                  LD   (Frog_PosY), HL
                  LD   (Frog_PosStartY), HL
                  ; Initial ball colors via VDC RNG (already seeded by VDC_Init).
                  CALL VDC_RandomColor
                  LD   (Frog_BallColor), A
                  CALL VDC_RandomColor
                  AND  3                                ; 0..3 (HD: nextBallColor 4 colors)
                  LD   (Frog_NextBallColor), A
                  RET


; ----------------------------------------------------------------------------
; Frog_Update — angle от atan2(mouse) ТОЛЬКО при ZL_MouseMoved=1 (combine logic
; коллеги): keyboard arrows ←/→ меняют Frog_Angle напрямую в ZL_AimUpdate
; (= перед нами), и без mouse motion atan2 не перезатирает их работу.
; Если mouse двинулась с порогом — atan2 wins (естественный blend, mouse
; takes over).
; ----------------------------------------------------------------------------
Frog_Update:      LD   A, (ZL_MouseMoved)
                  OR   A
                  CALL NZ, Frog_ComputeAngle           ; mouse активна → пересчитать
                  CALL Frog_HandleMouse
                  JP   Frog_TickRecoil


; ----------------------------------------------------------------------------
; Frog_ComputeAngle — Frog_Angle = atan2(SmoothY-PosStartY, SmoothX-PosStartX).
; 8-октантная схема + AtanTable[129] + hybrid slow/fast follow.
; ----------------------------------------------------------------------------
Frog_ComputeAngle:
                  ; dx = SmoothX - PosStartX
                  LD   HL, (ZL_SmoothX)
                  LD   DE, (Frog_PosStartX)
                  AND  A
                  SBC  HL, DE
                  LD   B, 0                            ; flags: b0=dx<0, b1=dy<0, b2=swap
                  BIT  7, H
                  JR   Z, .dx_pos
                  SET  0, B
                  LD   A, H : CPL : LD H, A
                  LD   A, L : CPL : LD L, A
                  INC  HL
.dx_pos:          ; Clamp |dx| до 255 (если H≠0 значит |dx|>255 → насыщать).  Без clamp
                  ; truncate (LD C, L) даёт 0x39=57 для dx=313=0x139, swap-логика
                  ; сходит с ума → frog дёргается у краёв экрана.  (Кредит: Gemini.)
                  LD   A, H
                  OR   A
                  JR   Z, .dx_clamped
                  LD   L, 255
.dx_clamped:      LD   C, L                            ; C = |dx| (true 8-bit clamp)
                  ; dy = SmoothY - PosStartY
                  LD   HL, (ZL_SmoothY)
                  LD   DE, (Frog_PosStartY)
                  AND  A
                  SBC  HL, DE
                  BIT  7, H
                  JR   Z, .dy_pos
                  SET  1, B
                  LD   A, H : CPL : LD H, A
                  LD   A, L : CPL : LD L, A
                  INC  HL
.dy_pos:          LD   A, H
                  OR   A
                  JR   Z, .dy_clamped
                  LD   L, 255
.dy_clamped:      LD   E, L                            ; E = |dy| (true 8-bit clamp)
                  ; swap = (|dy| > |dx|)
                  LD   A, E
                  CP   C
                  JR   C, .no_swap
                  SET  2, B
                  LD   A, C : LD C, E : LD E, A
.no_swap:         ; C = max, E = min
                  LD   A, C
                  OR   A
                  JR   Z, .cfa_done                    ; курсор в frog center → не менять угол
                  ; t = E*128 / C
                  LD   H, 0
                  LD   L, E
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                  CALL Frog_Div16by8                   ; A = HL / C
                  CP   129
                  JR   C, .lookup
                  LD   A, 128
.lookup:          LD   HL, Frog_AtanTable
                  LD   D, 0 : LD E, A
                  ADD  HL, DE
                  LD   A, (HL)                         ; A = угол 0..32 (1-й октант)
                  ; mirror at 90° если был swap
                  BIT  2, B
                  JR   Z, .no_mirror
                  LD   E, A : LD A, 64 : SUB E
.no_mirror:       ; A в 0..64. Применяем знаки dx/dy.
                  BIT  0, B
                  JR   Z, .dx_pos2
                  BIT  1, B
                  JR   Z, .q2
                  ; Q3: dx<0, dy<0 → 128 + A
                  LD   E, A : LD A, 128 : ADD A, E
                  JR   .store
.q2:              ; Q2: dx<0, dy≥0 → 128 - A
                  LD   E, A : LD A, 128 : SUB E
                  JR   .store
.dx_pos2:         BIT  1, B
                  JR   Z, .store                       ; Q1: A
                  NEG                                  ; Q4: 256 - A
.store:           ; A = new angle. Hybrid follow: |diff|≥4 → snap, иначе ±1.
                  LD   B, A                            ; B = new
                  LD   A, C
                  CP   5
                  JR   C, .cfa_done                    ; deadzone
                  LD   A, B
                  LD   HL, Frog_Angle
                  SUB  (HL)                            ; A = signed diff (8-bit wrap)
                  JR   Z, .cfa_done
                  LD   D, A
                  BIT  7, A
                  JR   Z, .gp_pos
                  NEG
.gp_pos:          CP   4
                  JR   NC, .gp_full
                  LD   A, (HL)
                  BIT  7, D
                  JR   NZ, .gp_dec
                  INC  A
                  JR   .gp_save
.gp_dec:          DEC  A
.gp_save:         LD   (HL), A
                  RET
.gp_full:         LD   (HL), B
.cfa_done:        RET


; ----------------------------------------------------------------------------
; Frog_Div16by8 — HL / C → A (assumed quotient ≤ 129).
; ----------------------------------------------------------------------------
Frog_Div16by8:    XOR  A
                  LD   D, 0
.d8_loop:         LD   E, C
                  AND  A
                  SBC  HL, DE
                  JR   C, .d8_restore
                  INC  A
                  CP   130
                  JR   C, .d8_loop
                  RET
.d8_restore:      ADD  HL, DE
                  RET


; ----------------------------------------------------------------------------
; Frog_FireKeyboard — start fire от SPACE (вызывается ZL_AimUpdate при port
; #7FFE bit 0 pressed). Свой debounce через Frog_KeySpacePrev — независимо от
; LMB edge-rise в Frog_HandleMouse, чтобы зажатый SPACE не повторял огонь.
; ----------------------------------------------------------------------------
Frog_FireKeyboard:
                  LD   A, (Frog_KeySpacePrev)
                  OR   A
                  RET  NZ                              ; уже fired в прошлом кадре
                  LD   A, 1
                  LD   (Frog_KeySpacePrev), A
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                              ; уже стреляем (recoil идёт)
                  ; Start fire (= копия Frog_HandleMouse start-fire блока):
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= что вылетает изо рта)
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now (новый шар во рту)
                  CALL VDC_RandomColor
                  AND  3
                  LD   (Frog_NextBallColor), A
                  LD   A, 1
                  LD   (Frog_IsFire), A
                  XOR  A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_BallExpand), A
                  RET


; ----------------------------------------------------------------------------
; Frog_HandleMouse — edge-rise по SVK_LBUTTON, при необходимости стартует fire.
; HD: при первом нажатии (was=0, now=1) и !isFire — start fire.
; ----------------------------------------------------------------------------
Frog_HandleMouse:
                  ; Fire = только LMB (стабильно работает). RMB/SPACE/Kempston —
                  ; видимо в этом Unreal phantom-pressed (port reads bit clear
                  ; постоянно) → блокировали edge-rise.
                  LD   A, Input.Mouse.SVK_LBUTTON
                  CALL Input.Mouse.KeyState            ; Z=released, NZ=pressed
                  LD   A, 0
                  JR   Z, .save
                  LD   A, 1
.save:            LD   HL, Frog_PrevMouseLeft
                  LD   B, (HL)                         ; B = prev
                  LD   (HL), A                         ; save curr
                  OR   A
                  RET  Z                                ; curr=0 → не rise
                  LD   A, B
                  OR   A
                  RET  NZ                               ; prev=1 → не rise
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                               ; уже стреляем
                  ; --- Start fire (HD): promote nextBall → ballColor, new next 0..3,
                  ; ballExpand=0, recoilTick=0, isFire=1.
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= что вылетает изо рта)
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now (новый шар во рту)
                  CALL VDC_RandomColor
                  AND  3
                  LD   (Frog_NextBallColor), A
                  LD   A, 1
                  LD   (Frog_IsFire), A
                  XOR  A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_BallExpand), A
                  RET


; ----------------------------------------------------------------------------
; Frog_TickRecoil — если isFire: tick++, обновить tongueExpand, ballExpand, pos.
; recoil < 0 → выйти из fire-state, восстановить idle-значения.
; ----------------------------------------------------------------------------
Frog_TickRecoil:
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  Z

                  ; tick += FROG_RECOIL_STEP
                  LD   HL, Frog_RecoilTick
                  LD   A, (HL)
                  ADD  A, FROG_RECOIL_STEP
                  LD   (HL), A

                  ; recoil = SinTable[tick]
                  CALL Frog_LookupSin                   ; A = signed sin (-127..127)
                  BIT  7, A
                  JP   NZ, .end_fire                    ; sin < 0 → recoil закончился

                  LD   (Frog_TmpRecoil), A              ; recoil unsigned 0..127

                  ; tongueExpand = 24 - (recoil * 24) >> 7
                  LD   D, A
                  LD   E, 24
                  CALL Frog_Mul8x8u                     ; HL = recoil*24, ≤ 3048
                  SLA  L : RL  H                        ; HL <<= 1; H = HL>>7 (= 0..23)
                  LD   A, 24
                  SUB  H
                  LD   (Frog_TongueExpand), A

                  ; ballExpand: if < FROG_BALL_IDLE → += 2 (HD = 2.5/frame, floor to 2).
                  LD   A, (Frog_BallExpand)
                  CP   FROG_BALL_IDLE
                  JR   NC, .be_done
                  ADD  A, 2
                  CP   FROG_BALL_IDLE + 1
                  JR   C, .be_save
                  LD   A, FROG_BALL_IDLE
.be_save:         LD   (Frog_BallExpand), A
.be_done:

                  ; pos.x = posStart.x - (cos(angle) * recoil) / 2048
                  LD   A, (Frog_Angle)
                  ADD  A, 64                            ; cos = sin(angle + 64)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TmpRecoil)
                  LD   C, A
                  CALL Frog_SignedScale_div2048         ; A = signed (cos*recoil)/2048
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosStartX)
                  ADD  HL, DE
                  LD   (Frog_PosX), HL

                  ; pos.y = posStart.y - (sin(angle) * recoil) / 2048
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TmpRecoil)
                  LD   C, A
                  CALL Frog_SignedScale_div2048
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosStartY)
                  ADD  HL, DE
                  LD   (Frog_PosY), HL
                  RET

.end_fire:        XOR  A
                  LD   (Frog_IsFire), A
                  LD   (Frog_RecoilTick), A
                  LD   A, 24
                  LD   (Frog_TongueExpand), A
                  LD   A, FROG_BALL_IDLE
                  LD   (Frog_BallExpand), A
                  LD   HL, (Frog_PosStartX)
                  LD   (Frog_PosX), HL
                  LD   HL, (Frog_PosStartY)
                  LD   (Frog_PosY), HL
                  RET


; ----------------------------------------------------------------------------
; Frog_LookupSin — A = SinTable[A].  Corrupts D, E, HL.
; ----------------------------------------------------------------------------
Frog_LookupSin:   LD   HL, Frog_SinTable
                  LD   D, 0 : LD E, A
                  ADD  HL, DE
                  LD   A, (HL)
                  RET


; ----------------------------------------------------------------------------
; Frog_SignExtendA_HL — HL = sign-extended A.
; ----------------------------------------------------------------------------
Frog_SignExtendA_HL:
                  LD   H, 0
                  BIT  7, A
                  JR   Z, .pp
                  DEC  H                                ; H=0xFF (negative)
.pp:              LD   L, A
                  RET


; ----------------------------------------------------------------------------
; Frog_SignedScale_div128 — signed (B*C) / 128, range ±127.
;   In:  B = signed multiplier, C = unsigned (0..127, обычно 0..24)
;   Out: A = signed result
; ----------------------------------------------------------------------------
Frog_SignedScale_div128:
                  LD   A, B
                  LD   E, 0                             ; sign flag
                  BIT  7, A
                  JR   Z, .pos
                  INC  E
                  NEG
.pos:             LD   D, A                             ; D = |B|
                  PUSH DE
                  LD   E, C
                  CALL Frog_Mul8x8u                     ; HL = |B|*C
                  POP  DE
                  SLA  L : RL  H                        ; HL <<= 1; H = HL/128
                  LD   A, H
                  BIT  0, E
                  RET  Z
                  NEG
                  RET


; ----------------------------------------------------------------------------
; Frog_SignedScale_div2048 — signed (B*C) / 2048, range ±8.
;   In:  B = signed multiplier (cos/sin), C = unsigned (0..127, recoil)
;   Out: A = signed result (-8..+8 px)
; ----------------------------------------------------------------------------
Frog_SignedScale_div2048:
                  LD   A, B
                  LD   E, 0
                  BIT  7, A
                  JR   Z, .pos
                  INC  E
                  NEG
.pos:             LD   D, A
                  PUSH DE
                  LD   E, C
                  CALL Frog_Mul8x8u
                  POP  DE
                  LD   A, H                             ; A = HL/256, range 0..63
                  SRL  A : SRL A : SRL A                ; A /= 8 → /2048 total
                  BIT  0, E
                  RET  Z
                  NEG
                  RET


; ----------------------------------------------------------------------------
; Frog_Mul8x8u — D × E → HL (unsigned 16-bit).  Corrupts A, B, DE.
; ----------------------------------------------------------------------------
Frog_Mul8x8u:     LD   A, D
                  LD   HL, 0
                  LD   D, 0                             ; DE = E (extended unsigned)
                  LD   B, 8
.loop:            SRL  A
                  JR   NC, .skip
                  ADD  HL, DE
.skip:            SLA  E : RL D
                  DJNZ .loop
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawPlate — handle 4, no rotation, на текущем pos (с recoil offset).
; Перед вызовом ожидается matrix = identity.  Plate matrix не трогает.
; ----------------------------------------------------------------------------
Frog_DrawPlate:   FT_BitmapHandle 4
                  FT_BitmapSource PLATE_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawBody — handle 2, rotation matrix вокруг центра sprite.
;   matrix = T(61,61) · R(angle - 64) · T(-61,-61)
; Body native face = SOUTH (BRAD 64) → нужен offset -64 (= +192 mod 256).
; ----------------------------------------------------------------------------
Frog_DrawBody:    LD   A, (Frog_Angle)
                  ADD  A, 192                          ; body: -64 BRAD (south native)
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 2
                  FT_BitmapSource FROG_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawTongue — handle 5, tight-crop sprite 32×80, на pos + tongueExpand·dir,
; rotation вокруг tongue centre.
;   tongueX = pos.x + (cos(angle) * tongueExpand) / 128
;   tongueY = pos.y + (sin(angle) * tongueExpand) / 128
;   matrix  = T(16, 40) · R(angle + 192) · T(-16, -40)
; Tongue native = south (tip внизу 32×80 кадра); rotation как у body.
; ----------------------------------------------------------------------------
Frog_DrawTongue:
                  ; HD-style: tongue centre = pos + tongueExpand·dir (orbit).
                  ; tongueExpand=24 idle, втягивается до 0 при выстреле.
                  ;   offsetX = (cos(angle) · tongueExpand) / 128
                  ;   offsetY = (sin(angle) · tongueExpand) / 128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TongueExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL

                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TongueExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Matrix: T(uv_pivot) · R(angle + 192) · T(-screen_pivot)
                  ; UV centra sprite (16, 40) фиксируется в screen centra (48, 48)
                  ; rect'a 96×96 — sprite 32×80 рисуется внутри расширенного
                  ; screen rect'а и не клипается при любом угле rotation.
                  CALL ZL_EmitLoadId
                  LD   HL, FROG_TONGUE_UV_HW
                  LD   DE, FROG_TONGUE_UV_HH
                  CALL ZL_EmitTranslate
                  LD   A, (Frog_Angle)
                  ADD  A, 192
                  CALL Frog_EmitRotateRaw
                  LD   HL, FROG_TONGUE_SCR_HALF_NEG
                  LD   DE, FROG_TONGUE_SCR_HALF_NEG
                  CALL ZL_EmitTranslate
                  CALL ZL_EmitSetMatrix

                  FT_BitmapHandle 5
                  FT_BitmapSource TONGUE_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_TONGUE_W * 2, FROG_TONGUE_H
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_TONGUE_SCR_W, FROG_TONGUE_SCR_H

                  ; Vertex2f((TmpX - 48) * 16, (TmpY - 48) * 16)
                  LD   HL, (Frog_TmpX)
                  LD   DE, FROG_TONGUE_SCR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_TmpY)
                  LD   DE, FROG_TONGUE_SCR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  CALL FT.Coprocessor.Vertex2f

                  ; Reset matrix → identity для последующих ops.
                  CALL ZL_EmitLoadId
                  CALL ZL_EmitSetMatrix
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawFaceOverlay — handle 6, frog без лап (HD blink frame 0), та же
; rotation matrix что body.  Рисуется ПОСЛЕ tongue (и ball, когда будет) —
; перекрывает корень tongue, виден только tip торчащий за face area.
; ----------------------------------------------------------------------------
Frog_DrawFaceOverlay:
                  ; Overlay 122×122 = same size as body → identical rotation matrix.
                  LD   A, (Frog_Angle)
                  ADD  A, 192                            ; body native = south
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 6
                  FT_BitmapSource OVERLAY_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  ; Сбросить cell в 0: предыдущий next-ball оставил Cell=NextBallColor*8.
                  ; Cell — persistent DL state; без сброса Vertex2f читает overlay с
                  ; offset cell*29768 байт от OVERLAY_RAMG_ADDR — попадает за пределы
                  ; sprite в zero-padding RAM_G → alpha=0 → overlay invisible.
                  ; Проявлялось как «крышка иногда пропадает после выстрела» (75%
                  ; выстрелов: NextBallColor ∈ {1,2,3} ≠ 0).
                  XOR  A
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_PosCentered
                  CALL ZL_EmitLoadId
                  CALL ZL_EmitSetMatrix
                  RET


; ----------------------------------------------------------------------------
; Frog_EmitFrogMatrix — emit T(61) · R(A) · T(-61) → setmatrix.
;   In: A = raw rotation byte (caller добавил offset под native face direction)
; Body native = SOUTH (вызывает с Frog_Angle + 192).
; Tongue native = NORTH (вызывает с Frog_Angle + 64).
; ----------------------------------------------------------------------------
Frog_EmitFrogMatrix:
                  LD   (Frog_TmpRotByte), A
                  CALL ZL_EmitLoadId
                  LD   HL, FROG_SPR_HALF
                  LD   DE, FROG_SPR_HALF
                  CALL ZL_EmitTranslate
                  LD   A, (Frog_TmpRotByte)
                  CALL Frog_EmitRotateRaw
                  LD   HL, FROG_SPR_HALF_NEG
                  LD   DE, FROG_SPR_HALF_NEG
                  CALL ZL_EmitTranslate
                  JP   ZL_EmitSetMatrix


; ----------------------------------------------------------------------------
; Frog_EmitRotateRaw — append cmd_rotate(A) without face-direction offset.
; (ZL_EmitRotate в MainLoop делает +192 для chain — нам нужно raw.)
; ----------------------------------------------------------------------------
Frog_EmitRotateRaw:
                  LD   D, A : LD E, 0
                  LD   (ZL_TmpAngle), DE
                  LD   DE, FT_CMD_ROTATE & #FFFF
                  LD   BC, FT_CMD_ROTATE >> 16
                  CALL FT.Coprocessor.Command_BCDE
                  LD   BC, 0
                  LD   DE, (ZL_TmpAngle)
                  JP   FT.Coprocessor.Command_BCDE


; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_PosCentered — Vertex2f((PosX-61)*16, (PosY-61)*16).
; Общая часть DrawPlate / DrawBody (рисуем в текущем pos).
; ----------------------------------------------------------------------------
Frog_EmitVertex2f_PosCentered:
                  LD   HL, (Frog_PosX)
                  LD   DE, FROG_SPR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_PosY)
                  LD   DE, FROG_SPR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  JP   FT.Coprocessor.Vertex2f


; ----------------------------------------------------------------------------
; Frog_DrawBallNow — handle 0 (chain atlas), при pos + ballExpand·dir.
; ballExpand = 24 idle, при выстреле 0 → восстанавливается.  Cell = ballColor*16.
; ----------------------------------------------------------------------------
Frog_DrawBallNow:
                  ; offsetX = (cos · ballExpand) / 128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_BallExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL
                  ; offsetY = (sin · ballExpand) / 128
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_BallExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Native size 56×56 — оригинальный chain-ball размер.
                  FT_BitmapHandle 0
                  FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_BallColor)
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A    ; *16 (cell = color*16)
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawNextBall — handle 0, на спине frog: pos - 39·dir.
; Dark-spot в native body на (61, 22) = 39 px над centre, после rotation
; ends up в -dir (back of frog) на screen.
; ----------------------------------------------------------------------------
Frog_DrawNextBall:
                  ; offsetX = -(cos · 39) / 128 → pos - cos·39/128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, FROG_NEXT_OFFSET
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, FROG_NEXT_OFFSET
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Native size 56×56 — оригинальный chain-ball размер.
                  FT_BitmapHandle 0
                  FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_NextBallColor)
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A    ; *16 (cell = color*16)
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  RET


; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_Tmp_BallCentred — Vertex2f((TmpX-16)*16, (TmpY-16)*16) для
; ball screen rect 32×32 (centra TmpX, TmpY).
; ----------------------------------------------------------------------------
Frog_EmitVertex2f_Tmp_BallCentred:
                  LD   HL, (Frog_TmpX)
                  LD   DE, FROG_BALL_DST_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_TmpY)
                  LD   DE, FROG_BALL_DST_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  JP   FT.Coprocessor.Vertex2f


; ----------------------------------------------------------------------------
; Frog_AtanTable — atan(i/128) * 256/(2π) для i=0..128.  129 entries.
; ----------------------------------------------------------------------------
Frog_AtanTable:
                  DB  0,  0,  1,  1,  1,  2,  2,  2
                  DB  3,  3,  3,  3,  4,  4,  4,  5
                  DB  5,  5,  6,  6,  6,  7,  7,  7
                  DB  8,  8,  8,  8,  9,  9,  9, 10
                  DB 10, 10, 11, 11, 11, 11, 12, 12
                  DB 12, 13, 13, 13, 13, 14, 14, 14
                  DB 15, 15, 15, 15, 16, 16, 16, 17
                  DB 17, 17, 17, 18, 18, 18, 18, 19
                  DB 19, 19, 19, 20, 20, 20, 20, 21
                  DB 21, 21, 21, 22, 22, 22, 22, 23
                  DB 23, 23, 23, 23, 24, 24, 24, 24
                  DB 25, 25, 25, 25, 25, 26, 26, 26
                  DB 26, 26, 27, 27, 27, 27, 27, 28
                  DB 28, 28, 28, 28, 29, 29, 29, 29
                  DB 29, 29, 30, 30, 30, 30, 30, 31
                  DB 31, 31, 31, 31, 31, 32, 32, 32
                  DB 32


; ----------------------------------------------------------------------------
; Frog_SinTable — sin(i * 2π / 256) * 127, signed byte, для i=0..255.
; Сгенерировано: round(127 * math.sin(i * 2*pi / 256)).  Отрицательные
; значения — two's-complement (DB 253 = -3).
; Использование: cos(angle) = SinTable[(angle + 64) & 0xFF].
; ----------------------------------------------------------------------------
Frog_SinTable:
                  DB   0,   3,   6,   9,  12,  16,  19,  22,  25,  28,  31,  34,  37,  40,  43,  46
                  DB  49,  51,  54,  57,  60,  63,  65,  68,  71,  73,  76,  78,  81,  83,  85,  88
                  DB  90,  92,  94,  96,  98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116
                  DB 117, 118, 120, 121, 122, 122, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127
                  DB 127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 122, 122, 121, 120, 118
                  DB 117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100,  98,  96,  94,  92
                  DB  90,  88,  85,  83,  81,  78,  76,  73,  71,  68,  65,  63,  60,  57,  54,  51
                  DB  49,  46,  43,  40,  37,  34,  31,  28,  25,  22,  19,  16,  12,   9,   6,   3
                  DB   0, 253, 250, 247, 244, 240, 237, 234, 231, 228, 225, 222, 219, 216, 213, 210
                  DB 207, 205, 202, 199, 196, 193, 191, 188, 185, 183, 180, 178, 175, 173, 171, 168
                  DB 166, 164, 162, 160, 158, 156, 154, 152, 150, 149, 147, 145, 144, 143, 141, 140
                  DB 139, 138, 136, 135, 134, 134, 133, 132, 131, 131, 130, 130, 130, 129, 129, 129
                  DB 129, 129, 129, 129, 130, 130, 130, 131, 131, 132, 133, 134, 134, 135, 136, 138
                  DB 139, 140, 141, 143, 144, 145, 147, 149, 150, 152, 154, 156, 158, 160, 162, 164
                  DB 166, 168, 171, 173, 175, 178, 180, 183, 185, 188, 191, 193, 196, 199, 202, 205
                  DB 207, 210, 213, 216, 219, 222, 225, 228, 231, 234, 237, 240, 244, 247, 250, 253


; ----------------------------------------------------------------------------
; Frog state (data section).
; ----------------------------------------------------------------------------
Frog_Angle:        DEFB 0
Frog_RecoilTick:   DEFB 0
Frog_IsFire:       DEFB 0
Frog_PrevMouseLeft:DEFB 0
Frog_KeySpacePrev: DEFB 0                              ; SPACE debounce (0=ready, 1=fired)
Frog_TongueExpand: DEFB 24
Frog_BallExpand:   DEFB 32
Frog_TmpRecoil:    DEFB 0
Frog_TmpRotByte:   DEFB 0
Frog_BallColor:    DEFB 0
Frog_NextBallColor:DEFB 0
Frog_PosX:         DEFW FROG_DEFAULT_X
Frog_PosY:         DEFW FROG_DEFAULT_Y
Frog_PosStartX:    DEFW FROG_DEFAULT_X
Frog_PosStartY:    DEFW FROG_DEFAULT_Y
Frog_TmpX:         DEFW 0
Frog_TmpY:         DEFW 0

```

### 2.Bullet.asm

Flying ball: spawn по fire, motion по cos/sin, collision check vs chain (Manhattan), call VDC_InsertAt

```asm
; ============================================================================
; Bullet.asm — летящий шар (одиночный выстрел из лягушки).
;
; State: Active flag + позиция (X,Y signed 16-bit) + velocity (VX,VY signed 8-bit)
; + color (0..5).  Spawn в start-fire (Frog_HandleMouse / Frog_FireKeyboard).
; Update каждый кадр (X += VX, Y += VY).  Out-of-screen → deactivate.
; Render — handle 0 chain atlas, тот же что ball-now/next-ball/chain.
;
; Этап 1 (текущий): только полёт + render. Без collision/insert в chain.
; ============================================================================

BULLET_SPEED        EQU 12                            ; px/frame, ~684 px/sec @57Hz
BULLET_SPRITE_HALF  EQU 16                            ; chain atlas 32×32 native classic
BULLET_HIT_THR      EQU 16                            ; bbox half-side: |dx|<THR && |dy|<THR


; ----------------------------------------------------------------------------
; Bullet_Init — обнулить state.
; ----------------------------------------------------------------------------
Bullet_Init:        XOR  A
                    LD   (Bullet_Active), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Spawn — вызывается из Frog start-fire (LMB или SPACE).
; Berёт цвет из Frog_BallColor (= уже промотировано из NextBallColor),
; angle из Frog_Angle, spawn position из Frog_PosStartX/Y (центр лягушки).
; Velocity = BULLET_SPEED * (cos(angle), sin(angle)) / 128.
; ----------------------------------------------------------------------------
Bullet_Spawn:       LD   A, (Bullet_Active)
                    OR   A
                    RET  NZ                           ; уже в полёте — single bullet MVP
                    LD   A, 1
                    LD   (Bullet_Active), A
                    LD   A, (Frog_BallColor)
                    LD   (Bullet_Color), A

                    LD   HL, (Frog_PosStartX)
                    LD   (Bullet_X), HL
                    LD   HL, (Frog_PosStartY)
                    LD   (Bullet_Y), HL

                    ; VX = (cos(angle) * BULLET_SPEED) / 128 (signed)
                    LD   A, (Frog_Angle)
                    ADD  A, 64                        ; cos = sin(angle + 64)
                    CALL Frog_LookupSin
                    LD   B, A
                    LD   A, BULLET_SPEED
                    LD   C, A
                    CALL Frog_SignedScale_div128
                    LD   (Bullet_VX), A

                    ; VY = (sin(angle) * BULLET_SPEED) / 128 (signed)
                    LD   A, (Frog_Angle)
                    CALL Frog_LookupSin
                    LD   B, A
                    LD   A, BULLET_SPEED
                    LD   C, A
                    CALL Frog_SignedScale_div128
                    LD   (Bullet_VY), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Update — X += VX, Y += VY каждый кадр. Deactivate если за экран.
; ----------------------------------------------------------------------------
Bullet_Update:      LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    LD   A, (Bullet_VX)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_X)
                    ADD  HL, DE
                    LD   (Bullet_X), HL
                    ; out-of-screen X check (signed)
                    BIT  7, H
                    JR   NZ, .deactivate              ; X < 0
                    LD   DE, 640
                    AND  A
                    SBC  HL, DE
                    JR   NC, .deactivate              ; X ≥ 640

                    LD   A, (Bullet_VY)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_Y)
                    ADD  HL, DE
                    LD   (Bullet_Y), HL
                    BIT  7, H
                    JR   NZ, .deactivate
                    LD   DE, 480
                    AND  A
                    SBC  HL, DE
                    RET  C                            ; Y < 480 → ОК
.deactivate:        XOR  A
                    LD   (Bullet_Active), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_CheckCollision — итерация по chain slots.  При Manhattan(bullet, slot)
; < BULLET_HIT_THR → VDC_InsertAt(slot_idx, color), Active=0.
; ----------------------------------------------------------------------------
Bullet_CheckCollision:
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z
                    LD   A, (VDC_SlotsLen)
                    OR   A
                    RET  Z
                    LD   B, A                          ; B = loop count
                    LD   C, 0                          ; C = i
.bcc_loop:          PUSH BC
                    LD   A, C
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=skip
                    JR   C, .bcc_skip
                    ; bbox check: |Bullet_X - X| < THR
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   NZ, .bcc_skip                 ; |dx| > 255 → too far
                    LD   A, L
                    CP   BULLET_HIT_THR
                    JR   NC, .bcc_skip                 ; |dx| ≥ thr → too far
                    ; bbox check: |Bullet_Y - Y| < THR
                    LD   HL, (Bullet_Y)
                    AND  A
                    SBC  HL, DE
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   NZ, .bcc_skip
                    LD   A, L
                    CP   BULLET_HIT_THR
                    JR   NC, .bcc_skip
                    ; HIT — hemisphere insert: target = i или i+1 по ближайшему neighbour.
                    POP  BC                            ; B=count, C=hit_idx
                    LD   A, C
                    CALL Bullet_HemisphereTarget       ; A = target_idx (i или i+1)
                    LD   C, A                          ; save target
                    LD   A, (Bullet_Color)
                    LD   B, A
                    LD   A, C
                    CALL VDC_InsertAt
                    XOR  A
                    LD   (Bullet_Active), A
                    RET
.bcc_skip:          POP  BC
                    INC  C
                    DEC  B
                    JP   NZ, .bcc_loop
                    RET


; ----------------------------------------------------------------------------
; Bullet_HemisphereTarget — A = hit_idx (slot куда попал bullet).
; Возвращает A = target_idx (i или i+1) — куда вставить.
; Логика: считаем Manhattan dist до prev (i-1) и next (i+1) non-gap соседей,
; вставляем со стороны более близкого соседа.
; Out: A = i или i+1.  Corrupts BC, DE, HL.
; ----------------------------------------------------------------------------
Bullet_HemisphereTarget:
                    LD   (Bullet_TmpHit), A
                    ; default target = hit
                    ; --- find prev non-gap (k < hit) ---
                    LD   (Bullet_TmpDistP+1), A        ; init prev_dist = 255 (= нет prev)
                    LD   A, 255
                    LD   (Bullet_TmpDistP), A
                    LD   (Bullet_TmpDistN), A          ; default next_dist = 255
                    LD   A, (Bullet_TmpHit)
                    OR   A
                    JR   Z, .ht_skip_prev              ; hit=0 → нет prev
                    DEC  A
.ht_prev_loop:      LD   (Bullet_TmpScan), A
                    LD   H, 0 : LD L, A
                    LD   DE, VDC_Slots
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_prev_found             ; non-gap
                    LD   A, (Bullet_TmpScan)
                    OR   A
                    JR   Z, .ht_skip_prev
                    DEC  A
                    JR   .ht_prev_loop
.ht_prev_found:     LD   A, (Bullet_TmpScan)
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=skip
                    JR   C, .ht_skip_prev
                    CALL Bullet_ManhattanToBC_DE       ; A = |bx-X|+|by-Y| (clamped 255)
                    LD   (Bullet_TmpDistP), A
.ht_skip_prev:
                    ; --- find next non-gap (k > hit) ---
                    LD   A, (Bullet_TmpHit)
                    INC  A
                    LD   (Bullet_TmpScan), A
                    LD   B, A
                    LD   A, (VDC_SlotsLen)
                    CP   B
                    JR   C, .ht_decide                 ; scan >= len → нет next
                    JR   Z, .ht_decide
.ht_next_loop:      LD   A, (Bullet_TmpScan)
                    LD   H, 0 : LD L, A
                    LD   DE, VDC_Slots
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_next_found
                    LD   A, (Bullet_TmpScan)
                    INC  A
                    LD   (Bullet_TmpScan), A
                    LD   B, A
                    LD   A, (VDC_SlotsLen)
                    CP   B
                    JR   Z, .ht_decide
                    JR   C, .ht_decide
                    JR   .ht_next_loop
.ht_next_found:     LD   A, (Bullet_TmpScan)
                    CALL VDC_SlotPos
                    JR   C, .ht_decide
                    CALL Bullet_ManhattanToBC_DE
                    LD   (Bullet_TmpDistN), A
.ht_decide:
                    ; if dist_next < dist_prev → target = hit + 1, else hit
                    LD   A, (Bullet_TmpDistN)
                    LD   B, A
                    LD   A, (Bullet_TmpDistP)
                    CP   B
                    LD   A, (Bullet_TmpHit)
                    RET  C                             ; prev < next → target=hit
                    INC  A                             ; next ≤ prev → target=hit+1
                    RET


; ----------------------------------------------------------------------------
; Bullet_ManhattanToBC_DE — A = |Bullet_X - BC| + |Bullet_Y - DE| clamped 255.
; ----------------------------------------------------------------------------
Bullet_ManhattanToBC_DE:
                    PUSH DE                            ; save Y
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   Z, .mh_dx_ok
                    LD   L, 255
.mh_dx_ok:          LD   B, L                          ; B = |dx| clamped
                    POP  DE                            ; restore Y
                    LD   HL, (Bullet_Y)
                    AND  A
                    SBC  HL, DE
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   Z, .mh_dy_ok
                    LD   L, 255
.mh_dy_ok:          LD   A, L
                    ADD  A, B                          ; |dy| + |dx|
                    RET  NC
                    LD   A, 255                        ; sat
                    RET


; ----------------------------------------------------------------------------
; Bullet_AbsHL — HL = |HL| (signed → unsigned magnitude).
; ----------------------------------------------------------------------------
Bullet_AbsHL:       BIT  7, H
                    RET  Z
                    LD   A, H : CPL : LD H, A
                    LD   A, L : CPL : LD L, A
                    INC  HL
                    RET


; ----------------------------------------------------------------------------
; Bullet_SignExtendA_HL — HL = sign-extended A.
; ----------------------------------------------------------------------------
Bullet_SignExtendA_HL:
                    LD   H, 0
                    BIT  7, A
                    JR   Z, .pp
                    DEC  H
.pp:                LD   L, A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Draw — render bullet sprite в DL.  handle 0 chain atlas.
; Cell = Bullet_Color * 16 (без spin — один кадр).  Matrix должна быть identity.
; ----------------------------------------------------------------------------
Bullet_Draw:        LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    FT_BitmapHandle 0
                    FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                    FT_BitmapLayout FT_ARGB4, 32 * 2, 32
                    FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, 32, 32
                    LD   A, (Bullet_Color)
                    ADD  A, A : ADD A, A : ADD A, A : ADD A, A   ; * 16 (cell = color*16)
                    CALL FT.Coprocessor.Cell
                    ; Vertex2f((X - 28) * 16, (Y - 28) * 16)
                    LD   HL, (Bullet_X)
                    LD   DE, BULLET_SPRITE_HALF
                    AND  A
                    SBC  HL, DE
                    ADD  HL, HL : ADD HL, HL
                    ADD  HL, HL : ADD HL, HL
                    LD   B, H : LD C, L
                    LD   HL, (Bullet_Y)
                    LD   DE, BULLET_SPRITE_HALF
                    AND  A
                    SBC  HL, DE
                    ADD  HL, HL : ADD HL, HL
                    ADD  HL, HL : ADD HL, HL
                    EX   DE, HL
                    CALL FT.Coprocessor.Vertex2f
                    RET


; ----------------------------------------------------------------------------
Bullet_Active:      DEFB 0
Bullet_X:           DEFW 0
Bullet_Y:           DEFW 0
Bullet_VX:          DEFB 0
Bullet_VY:          DEFB 0
Bullet_Color:       DEFB 0
Bullet_TmpHit:      DEFB 0                            ; hemisphere scratch
Bullet_TmpScan:     DEFB 0
Bullet_TmpDistP:    DEFB 0
Bullet_TmpDistN:    DEFB 0

```

---

## 3. Контекст для review

- VDC дискретная модель сознательно выбрана вместо continuous 2D physics — для изоляции отладки.
- Sync с Python emulator: одни константы (CELL_SIZE=32, DECAY_POS=1, DECAY_NEG=2, GAP_STEP_FRAMES=32), одна логика InsertAt/DoGapStep/CheckMatch3/AnimateChain.
- Match-3 STOP: instant gap_step в CheckMatch3 → head получает +CS offset → stationary визуально. Остальные markers разбираются по 1 каждые GAP_STEP_FRAMES (без `HSub==0` constraint).
- Insert: head_side offsets -= CS, decay neg = 2/frame → head «уезжает» 2 cells за CELL_SIZE кадров без freeze.
- Chain rendering: bucket-grouping (32 buckets = 11.25° step) уменьшает SPI cmd_rotate с per-ball на 32/frame.

Что просим у Gemini Pro: найти inconsistencies между Python и asm, logical ошибки в chain physics (особенно cascade match-3 + rollback), и suggest improvements.
