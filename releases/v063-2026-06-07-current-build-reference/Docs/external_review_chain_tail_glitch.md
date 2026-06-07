# External Review Request — Zuma VDAC2 chain «лишний шар в хвосте»

**Контекст:** проект Zuma Deluxe для платформы ZX Evolution + VDAC2 (FT812 SPI graphics, нативное 640×480). На Z80 написан порт chain physics из Python-эмулятора (VDC = Virtual Discrete Chain). Python работает корректно, asm-порт имеет визуальный баг.

## Симптом

User стреляет лягушкой по шарам в **середину цепи**. Видит, что **в самом хвосте** цепи (далеко от килзоны, ближе к точке спавна) **появляется лишний шар**. То есть после insert-а в середину tail-end цепи визуально удлиняется на один шар.

В Python-эмуляторе (`vdc_visual_emulator.py`) — **тот же сценарий не воспроизводится**. User проверил, выстрел в середину не добавляет шар к хвосту.

## Условия воспроизведения

- `BallsSpawned == VDC_BALLS_TARGET (=85)` — спавн новых шаров уже закрыт.
- Цепь уже подошла к концу трека (голова близко к killzone), но не полностью её прошла.
- User стреляет в **середину** цепи (не в хвост, не в голову).
- Bullet collide в middle (Manhattan bbox < BULLET_HIT_THR=16) → `VDC_InsertAt(target_idx, color)`.

## Геометрия и константы

```
VDC_CELL_SIZE          = 32     ; sample-units на slot.
VDC_NUM_COLORS         = 4
VDC_MAX_SLOTS          = 240
VDC_GAP_STEP_FRAMES    = 32     ; = CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX = 10
VDC_BALLS_TARGET       = 85
VDC_LEVEL_START_BALLS  = 35     ; fast phase
VDC_FAST_ADVANCE       = 12     ; MoveChain x12 per tick in fast phase
VDC_DECAY_NEG          = 2      ; insert head slide (neg->0) fast
VDC_DECAY_POS          = 1      ; cascade rollback (pos->0) smooth
BULLET_HIT_THR         = 16     ; bbox half-side

Track:
  NumSamples           = 2762   (track_640.bin, ~1.0815 px/sample chord)
  CELL_SIZE in samples = 32     (~34.6 px between ball centers)
  Ball diameter        = 32 px
  Visible gap          ~2.6 px между шарами на прямой

TrackNumSlots (cap для HSA, computed at init):
  = NumSamples / CELL_SIZE - 1 = 2762/32 - 1 = 85
```

**Критическое наблюдение:** `VDC_BALLS_TARGET == TrackNumSlots == 85`. После полного спавна HSA доезжает до cap, **и любой insert после этого попадает в edge-case `HSA == cap`**.

В Python: `BALLS_TARGET = 60`, `TrackNumSlots = 85` — буфер 25 cells, HSA редко доходит до cap при типичной игре.

## Модель chain physics

Chain представлена как массив фиксированной длины (`VDC_MAX_SLOTS=240`). State:
- `Slots[i]` — цвет (0..3) или GAP_STOP/GAP_CASCADE/`>= NUM_COLORS` markers.
- `Offsets[i]` — signed byte, смещение шара относительно базовой cell-границы.
- `Shot2[i]` — флаг что слот недавно потревожен (для match-detection).
- `HSA` — head sample address (= где сейчас находится **head** = slot 0).
- `HSub` — sub-sample, инкрементируется каждый кадр, wraps на CELL_SIZE → HSA++.
- `SlotsLen` — текущая длина цепи.

Позиция слота `i` на треке:
```
t = (HSA - i) * CELL_SIZE + HSub + Offsets[i]
TrackData[t] -> (X, Y) для рендера
```

`t < 0` -> шар «за стартом трека» (не рисуется в asm, preserve last_render_pos в Python).
`t >= NumSamples` -> clamp к NumSamples-1 (= killzone position).

## Anatomy of insert (`InsertAt(target_idx, color)`)

1. Compute `new_offset = -CS/2 + (head_off + tail_off) / 2`.
2. shift_right массивов Slots/Offsets/Shot2 от target_idx до конца.
3. `Slots[target_idx] = color`, `Offsets[target_idx] = new_offset`, `Shot2[target_idx] = 1`.
4. `SlotsLen++`.
5. `HSA++` если `HSA < TrackNumSlots-1` (= cap не достигнут).
6. head_comp: `Offsets[0..target_idx-1] -= CS` (с cap'ом -CS).
7. `CheckMatch3(target_idx)`.

**В normal case (HSA < cap):**
- Tail-side balls (idx > target_idx): после shift_right idx стал i+1; HSA++ ⇒ `t_new = (HSA+1 - (i+1))*CS + sub + off = old t`. Balls stay.
- Head-side balls (idx < target_idx): idx тот же; HSA++ ⇒ `t += CS` (head moves forward to killzone by CS); head_comp `off -= CS` компенсирует ⇒ visually stay; затем decay возвращает offset к 0 за CS/DECAY_NEG=16 кадров, давая плавный slide head'а вперёд на CS px.

**В cap case (HSA == cap):** HSA не инкрементируется. Tail-side balls: после shift_right idx стал i+1, HSA не изменилось ⇒ `t_new = (HSA - (i+1))*CS + sub + off = old t - CS`. **Все tail-side balls visually shift backward by CS samples (~34 px)**. Это и есть симптом, который user описывает как «лишний шар в хвосте» — цепь визуально удлиняется в сторону спавна.

## Что я (Claude в этой сессии) уже попробовал

### Попытка 1: gate-fix в `VDC_InsertAt`
По рекомендации коллеги Claude из другой сессии (он ведёт TS-Conf версию того же проекта). Изменил cap-ветку: при `HSA == cap` пропускать **И HSA++, И head_comp** (skip обе операции).

Результат: **баг не исчез**. После анализа понял почему — head_comp работает на `Offsets[0..target_idx-1]` (head-side balls). Tail shift backward происходит из-за shift_right + отсутствия HSA++, head_comp на это не влияет.

### Попытка 2: проверка через дамп памяти
User снял дамп RAM 64KB. Распарсил state: `HSA=75, HSub=5, SlotsLen=17, BallsSpawned=38, TrackNumSlots=85, LastT=1893`. `BallsSpawned < TARGET` — это **не** cap-сценарий, баг тогда не воспроизводился. Дамп не помог.

### Попытка 3: gate-fix не помог, откатил
Откатил Попытку 1 — теперь код ровно как был до моих экспериментов (head_comp выполняется при cap; tail shifts back на CS визуально).

## Что я НЕ понимаю

**Python имеет ту же логику** в `insert_at` (lines 320-321): `if s.hsa < len(self.track)//CELL_SIZE - 1: s.hsa += 1`, потом head_comp выполняется всегда. То есть Python тоже должен иметь tail shift backward при cap. **Но user говорит Python не глючит.**

Возможные объяснения:
1. **В Python TARGET=60 vs cap=85** — буфер 25 cells, HSA не доходит до cap в типичной игре.
2. **Что-то ещё не 1:1** между Python и asm-портом — какая-то семантическая разница которую я пропустил.

Я уже сравнивал TrySpawn, MoveChain, AnimateChain, InsertAt, DoGapStep, ScanForNewMatch, CheckMatch3, DetectMatch3 — нашёл два расхождения, но ни одно не объясняет именно «лишний шар в хвосте» при insert в середину:
- asm `VDC_AnimateChain` не делает `match_scan_idx = 0` перед scan (Python делает).
- asm fast phase делает 12x MoveChain + spawn без hsub gate (у Python нет fast phase).

Эти расхождения **отдельные баги**, но не вызывают tail-shift при insert.

## Запрос на ревью

Я **не справляюсь** с поиском root cause. Прошу провести независимый аудит:

1. Полные файлы asm и Python-эмулятора ниже. Найди семантическое расхождение между ними которое объясняет визуальный баг «tail shifts backward at insert when HSA at cap».

2. Также подскажи **минимальный fix** который устранит баг при сохранении остального gameplay:
   - Вариант A: понизить `VDC_BALLS_TARGET` до 60 (Python parity) — буфер от cap'а.
   - Вариант B: реализовать AbsorbHead — при insert с HSA==cap absorb slot 0 (head «уходит в killzone»), `SlotsLen` остаётся, `HSA` остаётся.
   - Вариант C: что-то ещё что не заметил.

3. **Не предлагай добавлять `last_render_pos`** — этого в asm намеренно нет (комментарий `VDC.asm:12-14`), это известный trade-off.

---

# Файл 1 — Python emulator (reference, works)

`vdc_visual_emulator.py`:

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

# Файл 2 — VDC.asm (asm port, has bug)

`VDC.asm`:

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
                ; Fast phase: ×12 MoveChain (35 шаров «поездом»).
                ; В fast phase spawn без hsub-gate — иначе при wrap-частоте
                ; CELL_SIZE/12 ≈ 3 ticks spawn'ы редки → fast phase ломается.
                LD   B, VDC_FAST_ADVANCE
.upd_fast:      PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd_fast
                CALL VDC_AnimateChain
                JP   VDC_TrySpawn_NoHsubGate
.upd_normal:    ; Normal phase: subdivider /2 + spawn каждые 64 кадра.
                ; TrySpawn (с hsub-gate) синхронен с Python: spawn только когда
                ; chain выровнен по cell-границе.
                LD   A, (ZL_FrameCounter)
                AND  1
                RET  NZ                                ; odd frame → skip всё
                CALL VDC_MoveChain
                CALL VDC_AnimateChain
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
                ; Public entry: с HSub==0 gate (sync с Python try_spawn).
                ; Fast phase обходит gate через VDC_TrySpawn_NoHsubGate.
                LD   A, (VDC_HSub)
                OR   A
                RET  NZ
                ; fallthrough
VDC_TrySpawn_NoHsubGate:
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

                ; HSA++ с cap по TrackNumSlots-1.
                ; Если HSA уже на cap'е → пропускаем И HSA++, И head_comp.
                ; Без skip head_comp вся цепь визуально съезжает на CS назад,
                ; а у спавна возникает «лишний шар» (см. Чат.txt VDC↔VDAC2 2026-05-13).
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   C, .ia_no_head_comp               ; HSA >  cap → skip
                JR   Z, .ia_no_head_comp               ; HSA == cap → skip
                LD   HL, VDC_HSA
                INC  (HL)
                ; offsets[0..idx-1] -= CS, cap to -CS — только если HSA реально инкрементировался
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

---

# Файл 3 — Bullet.asm (collision detection caller InsertAt)

`Bullet.asm`:

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

# End of bundle

**Размер VDC.asm:** 1355 строк. **Bullet.asm:** 335 строк. **Python:** 600 строк.

Я не вношу никаких изменений в код до твоего анализа. Спасибо.
