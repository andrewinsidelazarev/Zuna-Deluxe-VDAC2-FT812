# Top HUD — reverse engineering

Источник: `~/Desktop/Zuma-Deluxe-HD-ref` (Galaxy Shad incomplete C-port) + классическая PopCap Zuma Deluxe.

Цель — собрать top HUD (Maya рамка верх) на VDAC2 640×480: lives counter / LVL X-Y / SCORE / gauge bar / MENU button.

---

## ⭐ TL;DR — VALIDATED MECHANICS (authoritative for VDAC2)

Проверено 2026-05-20 по HD-ref source, Zuma Wiki/Fandom, GameFAQs FAQ,
Speedrun.com guide и официальному Xbox PopCap manual. Главная механика
совпадает; scoring ниже разделён на **оригинал** и **HD-ref C-port**.

### Gauge bar («Zuma bar») — состояния

```
[ RED socket ] → [ YELLOW capsule растёт ] → [ GREEN capsule full → SPAWN GATE OFF ]
   empty            filling                    completion
```

| Цвет | Source | Условие | Что происходит |
|---|---|---|---|
| **RED** | baked в `gameinterface.png` | `currentScore == 0` или капсула не покрывает | Пустой sock, spawn ON |
| **YELLOW/ORANGE** | `progress_yellow.png` 94×27 | `0 < currentScore < gaugeScore` | Капсула шириной ∝ `(score × 94) / gaugeScore`, spawn ON. Официальный manual называет это **orange Zuma meter**, wiki/FAQ часто говорят **yellow bar** |
| **GREEN** | `progress_green.png` 94×27 | `currentScore >= gaugeScore` | Капсула 94 px; GameFAQs прямо говорит, что полный meter “turn green”; **новые шары перестают спавниться**, sphere trail cuts off, voice `"ZUMA!"` |

### Условие победы уровня — DOUBLE-STEP

1. **Заполнить бар очками** до `gaugeScore` → cap → green → spawn gate OFF (новые шары больше не появляются из хвоста).
2. **Дочистить ВСЕ оставшиеся** на экране шары (хвост, который успел спавниться) → **level complete**.

Если на шаге 2 хвост успеет упасть в skull до того как дочистишь — game over даже с заполненным баром.

### Чем заполняется бар (источники очков)

Per match-3 explosion + bonus event, формула из `Statistics.c:37`:

```
points = ballsCount × 10
       + gapPoints           (выстрел сквозь промежуток в цепи)
       + comboCount × 100    (≥2 explosions одинакового цвета подряд)
       + 100 + 10×(chain-5)  (chain bonus при ≥5 explosions БЕЗ combo)
       + coin_value          (coins, дропающиеся сквозь gap shots)
```

`chain bonus` и `coin bonus` — **быстрый способ** заполнить бар (per wiki).

### gaugeScore target per level

В HD-ref это не надо подбирать: таблица лежит в
`content/levels/levels.xml`, атрибут `score=`.

Для Adventure:
- `lvl11`, `lvl12`: **1000**
- `lvl13`, `lvl14`: **1500**
- дальше значения растут по конкретной таблице уровня
- `lvl101..lvl127`: в основном **5000**
- `lvl131` Space: **10000**

В VDAC2 текущий первый уровень должен использовать **1000**, а не временные
3000/5000.

Важно для текущего порта: пока scoring не совпадает с оригиналом полностью
(gap/chain/coin), `GaugeFull` нельзя подключать к реальному spawn gate — это
ломает игровой процесс. Сначала HUD-индикация и score, затем точная scoring
модель, только после этого gate.

### Игровой feedback на gauge full

- Voice line: `"ZUMA!"` (sample из оригинала).
- Sphere trail визуально обрывается (на конце цепи больше не появляются шары).
- Музыка/темп может ускориться (зависит от мира) — TODO проверить.

### Lives counter

В `HudSystem.c:34` рисуется **один** frog-icon @ (64, 24). Цифра отображается рядом текстом (`FONT_CANCUN_12`). Т.е. это не N-сокетов с лягушками, а **1 icon + numeric counter**.

### Score / Level number

- **SCORE** (большой чёрный сокет): cumulative очки **через все уровни** (не сбрасывается между уровнями, в отличие от gauge).
- **LVL X-Y** (правый красный сокет): где `X` = мир (world, 1..12), `Y` = sub-level в мире (обычно 1..3 или 1..4).

---

## 1. Карта спрайтов из HD-ref

Из `ResourceStore.c:106-149` (texture `gameinterface.png`, 1280×730 reference resolution):

| Sprite | Atlas (x,y,w,h) | Назначение |
|---|---|---|
| `SPR_GAME_HUD_BORDER` | `0, 51, 1280, 730` | Полная рамка экрана (Maya frame) |
| `SPR_GAME_HUD_LIVE` | `40, 18, 40, 36` | Иконка лягушки-жизни |
| `SPR_GAME_HUD_PROGRESS_BAR_GREEN` | `773, 0, 94, 27` | Капсула gauge — **финиш**-state |
| `SPR_GAME_HUD_PROGRESS_BAR_YELLOW` | `773, 28, 94, 27` | Капсула gauge — **filling**-state |
| `SPR_GAME_HUD_BTN_MENU` | `925, 15, 118, 37` | MENU normal |
| `SPR_GAME_HUD_BTN_MENU_HOVER` | `1043, 15, 118, 37` | MENU hover |
| `SPR_GAME_HUD_BTN_MENU_PRESSED` | `1162, 15, 118, 37` | MENU pressed |

Спрайты подготовлены отдельно в `Graphics/Original/sprites/`:
- `life_frog.png`, `progress_green.png`, `progress_yellow.png`, `menu_active.png`, `menu_inactive.png`, `menu_pressed.png`.

**RED-сокет (пустой gauge)** — не отдельный sprite, а **запечённая часть `gameinterface.png`** (red rectangle 94×27 в позиции gauge). Видим его сквозь border, когда жёлтая капсула не покрывает всю ширину.

---

## 2. Механика gauge bar

### Цвета (по наблюдениям юзера в скомпилированном HD-ref + классика)

```
[ RED empty ] → [ YELLOW filling — ширина ∝ score ] → [ GREEN full → spawn stops ]
```

- **RED** = пустой бар = виден baked red socket в `gameinterface.png` (никакая капсула не нарисована или нулевой ширины).
- **YELLOW** (`progress_yellow.png`) = filling. Ширина капсулы линейно растёт от 0 до 94 px по мере накопления очков.
- **GREEN** (`progress_green.png`) = полностью заполнен. **Новые шары перестают спавниться из хвоста**, остаётся доедать цепь — это и есть условие победы уровня.

### Источник данных — `Level.h:22-34`

```c
typedef struct LevelSettings {
    const char*  id;
    float        ballSpd;
    int          ballStartCount;
    int          gaugeScore;     // ← ЦЕЛЕВОЕ значение бара (per-level)
    int          repeatChance;
    int          singleChance;
    int          ballColors;
    int          partTime;
    float        slowFactor;
} LevelSettings;
```

`gauge` = «датчик / шкала» — буквальный английский термин. `gaugeScore` — это **target score**, при достижении которого бар = 100% = green = gate ON.

### Источник очков — `Statistics.c:36-68`

```c
int points = ballsCount_ * 10 + gapPoints_ + comboCount_ * 100;
if (isChainBonus && comboCount_ == 0)
    points += 100 + 10 * (chainCount_ - 5);
```

Формула очков на каждый match-3 explosion:
- `ballsCount_ * 10` — base: 10 за каждый шар в группе
- `+ gapPoints_` — gap bonus (см. `Statistics_AddBulletGap`, dist-based)
- `+ comboCount_ * 100` — combo (одинаковый цвет подряд)
- `+ 100 + 10*(chainCount_-5)` — chain bonus при ≥5 цепных взрывах БЕЗ combo

`currentScore` для гейта = сумма этих points за уровень.

### Псевдокод бара

```python
fill_px = min(94, int(currentScore * 94 / gaugeScore))

if currentScore >= gaugeScore:
    draw_sprite_clipped_by_rect(progress_green, x_socket, y_socket, width=94)
    generator.spawn_enabled = False
elif fill_px > 0:
    draw_sprite_clipped_by_rect(progress_yellow, x_socket, y_socket, width=fill_px)
    # справа от fill_px виден baked RED из border
    generator.spawn_enabled = True
else:
    # ничего не рисуем, виден baked RED полностью
    generator.spawn_enabled = True
```

---

## 3. Что есть и чего НЕТ в HD-ref

### Есть
- Sprite-id'ы (`SPR_GAME_HUD_PROGRESS_BAR_GREEN`, `..._YELLOW`).
- `LevelSettings.gaugeScore` — поле.
- `Statistics.c` с формулой очков на explosion.
- `BallChainGenerator.fastModeBallsCountdown = 32` — но это **другое**: контроль initial burst первых 32 шаров (быстрая раскладка стартовой цепи), к gauge bar отношения не имеет.

### НЕТ (в коде на github commit 56e54f0)
- Render бара. `HudSystem.c:onDraw` рисует только `SPR_GAME_HUD_BORDER`, `"Hello"` placeholder, level display name, `SPR_GAME_HUD_LIVE`. Никакого `DrawSprite(PROGRESS_BAR_*)`.
- Use `gaugeScore` нигде в коде — поле определено, но не читается.
- Gate spawn'а по gauge. `BallChainGenerator_Update` (BallChain.c:551-575) спавнит шары вечно, пока есть headBall.

→ В скомпилированном билде у юзера логика, видимо, дописана локально (не закоммичена). Поведение что описал — **полностью совпадает с механикой оригинальной PopCap-игры**, поэтому реверс по поведению надёжен.

---

## 4. Под VDAC2 — план портирования

### 4.1 Данные

```asm
; Per-level: добавить в LevelTable (рядом с track, dispname, palette):
LEVEL_01_GAUGE_TARGET   EQU  3000   ; пример
LEVEL_02_GAUGE_TARGET   EQU  4500
; ...

; Runtime state:
VDC_GaugeCurrent:  DEFW 0    ; 16-bit, текущие очки за уровень
VDC_GaugeTarget:   DEFW 0    ; загружается при старте уровня
VDC_SpawnGate:     DEFB 0    ; 0=spawn ON, 1=spawn OFF (gauge full)
```

### 4.2 Инкремент

В `Bullet_OnMatch3Explode` после вычисления `count` группы:
```asm
; HL = points = count*10 + gap_bonus + combo*100 [+ chain_bonus]
; (формула 1:1 из Statistics.c:37)
LD   DE, (VDC_GaugeCurrent)
ADD  HL, DE
LD   (VDC_GaugeCurrent), HL
; Проверка переполнения gauge
LD   DE, (VDC_GaugeTarget)
SBC  HL, DE
JR   C, .not_full
LD   A, 1
LD   (VDC_SpawnGate), A
.not_full:
```

### 4.3 Спавн-gate

В `BallChainGenerator_Update` (или аналоге в VDC.asm):
```asm
LD   A, (VDC_SpawnGate)
OR   A
RET  NZ                ; gauge full → нет новых шаров
; ... обычный спавн
```

### 4.4 Render

Подход через **scissor** — самый дешёвый по DL:

```asm
; Полная капсула рисуется всегда. Scissor отрезает справа.

; 1. Вычислить fill_px = (VDC_GaugeCurrent * SPRITE_W) / VDC_GaugeTarget.
; 2. Выбрать sprite:
;       gate=OFF → progress_yellow
;       gate=ON  → progress_green
; 3. Установить scissor:
FT_CMD_BUF (SCISSOR_XY(x_gauge, y_gauge))
FT_CMD_BUF (SCISSOR_SIZE(fill_px, SPRITE_H))
; 4. Begin BITMAPS + DrawSprite (PALETTED4444, full sprite)
; 5. Сбросить scissor на полный экран:
FT_CMD_BUF (SCISSOR_XY(0, 0))
FT_CMD_BUF (SCISSOR_SIZE(640, 480))
```

Альтернатива — pre-render 94 кадров капсулы (yellow + green) с растущей шириной — даёт жирный RAM_G overhead, отвергаем.

### 4.5 Atlas под VDAC2 (PALETTED4444, как Frog/KZ)

Тред-кандидаты для одной shared palette (через alpha-индексы):
- life_frog (40×36) — 1 спрайт
- progress_yellow + progress_green (94×27) — 2 спрайта
- menu × 3 (118×37) — 3 спрайта

Все 6 sprites один colorspace → можно объединить в 1 atlas с одной palette 512B (как balls/frame strips).

Координаты/размеры HUD sprites для VDAC2: исходные extracted sprites взяты из
720p layout, поэтому масштаб **720→480 = 2/3**. Не использовать 1280→640
для этих sprites: это даёт неверный crop/scale.

Примеры:
- MENU: ~118×39 → **79×26**
- progress: ~95×28 → **63×19**

---

## 5. Подтверждение из community wiki / PopCap docs

Найдено в `zuma.fandom.com`, `chace-dream-company.fandom.com`, Wikipedia, GameFAQs (2026-05-19):

- **Официальное название**: «Zuma bar» (gauge bar / progress meter).
- **Цвет-state**: yellow = filling, **green = MAX**. Совпадает с нашим реверсом 1:1.
- **Условие победы уровня**: two-step
  1. Заполнить yellow bar очками → **balls cease spawning off-screen**.
  2. Уничтожить ВСЕ оставшиеся шары на экране (хвост, который уже спавнился).
- **Источники очков для бара**:
  - base за explosion (3+ шаров одного цвета)
  - **coin bonus** (через gaps)
  - **gap bonus** (выстрел сквозь промежуток между шарами)
  - **chain bonus** (≥5 цепных explosions подряд — quick way to fill the bar)
- **Difficulty scaling**: HD-ref содержит конкретные `score=` в `content/levels/levels.xml`: ранние `lvl11/lvl12` = 1000, поздние Adventure уровни обычно 5000, Space `lvl131` = 10000.
- **Game feedback на gauge full**: озвучка `"ZUMA!"` voice + chain visually cuts off спавн.

Это значит:
1. В нашем VDAC2 порте нужен **coin bonus mechanic** (если ещё не реализован) — coins дропаются через gap shots.
2. **`"ZUMA!"` voice sample** — добавить как опциональный sound asset (или skip для VDAC2 — звук на ZX Evo через AY?).
3. **gaugeScore per-level table** — брать напрямую из HD-ref `content/levels/levels.xml`, атрибут `score=`.

---

## 6. Открытые вопросы (для следующих сессий)

- [ ] Точные пиксельные координаты КАЖДОГО сокета на 640×480 версии рамки (life sock, LVL sock, SCORE sock, gauge socket, MENU sock).
- [ ] `gaugeScore` для каждого из 22 уровней — где брать? У PopCap были level-config файлы, у Galaxy Shad'а в коде только LevelSettings struct, файлы конфигов отсутствуют → подобрать эмпирически (или скопировать из дизассемблера оригинала).
- [ ] Шрифт цифр (SCORE, LVL X-Y) — какой? `FONT_CANCUN_12` в HD-ref; для VDAC2 уже есть `nativealien48` (level dispname), `_fonts/` папка — там что-то?
- [ ] Lives counter: 1 frog-icon с цифрой рядом, или N frog-icons в ряд? В HD-ref `HudSystem.c:34` рисует ОДИН frog @ (64, 24) — значит, нумерический счётчик рядом.
- [ ] Звук на gauge-full → spawn stop (в оригинале «ZUMA!» voice).

---

## 7. Алгоритмы начисления очков (VDAC2 implementation 2026-05-20)

Источник истины — HD-ref `Statistics.c:37` + wiki community sources. Реализовано в `VDC.asm:m3_have_marker` и `Bullet.asm:Bullet_CheckCollision`.

### 7.1 Base + combo + chain formula

После каждого match-3 explosion (внутри `VDC_CheckMatch3.m3_have_marker`):

```
points = ballsCount × 10
       + comboCount × 100           // если ≥2 explosions ОДНОГО цвета подряд
       + (100 + 10×(chainCount−5))  // если chainCount ≥ 5 AND combo == 0
```

**Состояния (VDC.asm state vars):**

| Var | Тип | Reset когда |
|---|---|---|
| `VDC_StatCombos` | byte (0..N) | InsertAt на ДРУГОЙ цвет vs previous match |
| `VDC_StatPrevMatchColor` | byte (#FF sentinel) | Updated на каждый match |
| `VDC_StatMaxCombo` | byte | Только при превышении |
| `VDC_StatChainCount` | byte (0..N) | VDC_InsertAt на shot **без** match (BreakChain) |
| `VDC_StatMaxChain` | byte | Только при превышении |

**Combo логика (m3_combo_inc/done):**
1. Если `TmpMC_Color == StatPrevMatchColor` → `StatCombos++`, обновить MaxCombo.
2. Иначе → `StatCombos = 0`, save new color в StatPrevMatchColor.

**Chain логика:**
1. `m3_have_marker:` → `StatChainCount++` (на КАЖДЫЙ explosion, включая cascade).
2. `VDC_InsertAt:` после CheckMatch3 если A=0 (no match) → `StatChainCount = 0`.
3. Cascade match-3 (через `VDC_ScanForNewMatch`) НЕ ресетит chain — наоборот, инкрементит, т.к. проходит через `m3_have_marker`.

**Chain bonus формула:**
- `chainCount < 5` → bonus = 0
- `chainCount == 5` → bonus = 100 (база)
- `chainCount > 5` → bonus = 100 + 10 × (chainCount − 5)
- Mutually exclusive с combo: chain bonus применяется ТОЛЬКО если `StatCombos == 0`.

### 7.2 Gap bonus formula

HD-ref `Statistics_AddBulletGap(float distance)`:
```
distance -= 78           // 52 × 1.5
if distance < 0: distance = 0
MAX_GAP = 450            // 300 × 1.5
gapBonus = 500 × (MAX_GAP − distance) / MAX_GAP
if gapBonus < 10: gapBonus = 10
if gapCount > 1: gapBonus *= 2   // double/triple consecutive gaps
```

**VDC implementation:**
1. State (VDC.asm): `VDC_BulletGapMinDist` (byte, init 255), `VDC_BulletGapCount` (byte).
2. На `Bullet_Spawn`: reset `BulletGapMinDist = 255`.
3. Per-frame в `Bullet_CheckCollision` после BBOX loop'а если no-hit:
   - Iterate Slots[0..SlotsLen-1]
   - Для каждого `Slots[i] >= NUM_COLORS` (GAP_STOP/GAP_CASCADE):
     - `CALL VDC_SlotPosAllowGap` (новый entry без gap-skip) → BC=X, DE=Y
     - Manhattan dist = |bullet_X - X| + |bullet_Y - Y|
     - Если `dist < BulletGapMinDist` → save.
4. На bullet expire (off-screen без hit):
   - Если `BulletGapMinDist <= VDC_GAP_HIT_THR (=24)` → **gap shot**:
     - `BulletGapCount++`
     - Compute bonus per formula выше
     - Добавить к `VDC_GaugeScore` + `VDC_PlayerScore`
     - Check `VDC_GaugeFull`
   - Если `BulletGapMinDist > THR` (no gap-pass) → reset `BulletGapCount = 0` (consecutive streak broken).
   - Также: `VDC_StatChainCount = 0` (промах ломает chain как и shot-без-match).

**Tuning vs HD-ref original (важно):**
Оригинал имеет `base=500` и `MAX_GAP=450` — что в VDAC2 (target=1000) означает 50% бара за один gap-shot.
VDAC2 scale-down: `MAX=32`, slope=1, `clamp≥10` → max bonus ~32 (≈ match-3 magnitude).
×2 consecutive → max 64. Один промах уже не заполняет половину бара.
Если хочется снова сделать gap-shot жирным — поднять `VDC_GAP_MAX` и/или умножить на коэффициент.

### 7.3 Per-pixel fill_px (DrawHudProgress, main.asm)

```
fill_px = (GaugeScore × HUD_PROGRESS_W) / HUD_GAUGE_TARGET
        = (GaugeScore × 63) / 1000
```

Z80 implementation (нет Div16x16, поэтому делим по частям 1000 = 8 × 125):
1. `HL = ZL_Mul16x8(GaugeScore, 63)` — max 999×63 = 62937, fits 16-bit.
2. `HL = HL >> 3` — деление на 8 через `SRL H : RR L` ×3.
3. `HL = VDC_DivHLbyA(HL, 125)` — деление на 125 → quotient в HL.
4. `fill_px = L` (8-bit, 0..62 для GaugeFull=0 ветки).
5. Clamp 1..HUD_PROGRESS_W: если 0 и score>0 → 1 (visible), если >SPRITE_W → SPRITE_W.

**Точность:** sequential /8 then /125 даёт `floor(floor(H/8)/125) ≈ floor(H/1000)`, расхождение ≤1 px на границе — acceptable.

### 7.4 Spawn gate

В `VDC_TrySpawn_NoHsubGate` (после fall-through из VDC_TrySpawn):
```asm
LD A, (VDC_GaugeFull)
OR A
RET NZ                  ; bar full → spawn OFF
```

`VDC_GaugeFull = 1` ставится в `m3_have_marker.m3_gauge_add` когда `GaugeScore ≥ HUD_GAUGE_TARGET` после ADD HL,DE.

### 7.5 Условия достижения GaugeFull (level complete step 1)

Для lvl11 target=1000, без gap/chain bonus:
- Минимум match-3 без combo: `1000 / 30 = 33.3 → 34` explosions
- С combo=1 (первое повторение): `1000 / 130 = 7.7 → 8` matches
- С chain=5+ без combo: первые 5 = 30×5 = 150 + 100 = 250 за 5-й; до 1000 нужно ещё ~3 chain-bonus matches.

С gap+chain+coin bonus уровень проходится за **~10-15 matches**, что совпадает с player feedback на оригинальной игре.

