# Учебник «Программирование TS-Conf + VDAC2 для ZX-Evo»

> Накопительный конспект материала. По мере разбора датшитов, источников
> и собственных экспериментов — здесь оседают факты, формулы, код-примеры,
> схемы и решения. Из этого вырастет полноценный учебник.

**Целевая аудитория:** разработчики на Z80 (sjasmplus / asm), знакомые с TS-Conf,
расширяющие свой код на работу с FT812 через VDAC2.

**Источники, осмысленные на сегодня:**
- `VDAC2 #2 - Первые шаги.docx` (русскоязычный учебник #2 — порты ZX-Evo, SPI обвязка, Z80 asm-функции FT_RD/FT_WR)
- `FT81x.pdf` (FTDI FT_001165, datasheet FT81X Embedded Video Engine, v1.2 / 2015) — memory map, регистры, RGB-таймминги
- `FT81X_Series_Programmer_Guide.pdf` (FTDI, 4 МБ) — полное программерское руководство с opcode таблицами
- `BRT_AN_033_BT81X-Series-Programming-Guide.pdf` (Bridgetek, 4.8 МБ) — расширение для BT81x (совместимая семья)
- `AN_303 FT800 Image File Conversion.pdf` — конвертация изображений в FT-форматы
- `The_Gameduino_2_Tutorial,_Reference_and_Cookbook` (J. Bowman, 2013) — высокоуровневое API через C++ Gameduino wrapper, Cookbook с практиками
- **`TSLib`** (DeadlyKom, GitHub) — готовая asm-библиотека для ZX-Evo + FT812. Лежит локально в `Docs\TSLib\` (исходники + полная FTDI документация в `Docs\TSLib\FT812\Docs\`). Главный практический референс.

---

## 1. Аппаратная связка ZX-Evo + VDAC2

### 1.1. Что такое VDAC2

VDAC2 — расширительная плата для ZX-Evo, заменяющая стандартный 5-bit VDAC.
Содержит чип **FT812** (FTDI Embedded Video Engine):
- 1 MB graphics RAM (RAM_G)
- Display List engine (8 KB RAM_DL)
- Co-processor с командным буфером (4 KB RAM_CMD)
- VGA-выход до 800×600 (для нас целевой режим — 640×480)
- 8/8/8 RGB output
- SPI-интерфейс к хосту (Z80) до 30 MHz (на ZX-Evo тактирование меньше)

В STATUS-регистре TS-Conf версия адаптера:
- `000` — 2-bit VDAC + PWM
- `001`/`010`/`011` — 3/4/5-bit VDAC
- `111` — VDAC2 (FT812)  ← **наш случай**

Sanity-check на старте программы:
```asm
    IN A, (0xAF)      ; STATUS
    AND %00000111
    CP  %00000111
    JR  NZ, .no_vdac2 ; на этой плате FT812 нет → fallback на TS-Conf рендер
```

### 1.2. Порты TS-Conf для общения с FT812

| Порт   | Назначение            | R/W | Биты |
|--------|-----------------------|-----|------|
| 0xAF   | STATUS                | R   | [2..0] версия видеоадаптера |
| 0xAF   | VCONFIG               | W   | [2] FT_EN (0=TS-Config / 1=FT812), [5] NO_GFX (1=отключить TS-Config gfx, освободить DMA-циклы) |
| 0x77   | SPI_CTRL              | W   | bit 0 — ZX-Evolution flag, bit 1 — SD CS (0=en/1=dis), bit 2 — FT812 CS (0=dis/1=en) |
| 0x57   | SPI_DATA              | R/W | байтовый обмен с активным SPI устройством |

**Магические значения SPI_CTRL:**
- `0x03` — `SPI_FT_CS_OFF` (FT812 disable)
- `0x07` — `SPI_FT_CS_ON`  (FT812 enable)

### 1.3. VCONFIG для VDAC2-режима

```asm
    LD  A, %00100100   ; FT_EN=1 (bit 2), NO_GFX=1 (bit 5)
    OUT (0xAF), A
```

`NO_GFX=1` отключает обычный TS-Config рендер пикселей. Это экономит **DMA-циклы**:
лимит DMA на строку = 448 циклов, обычно расходуются на чтение VRAM для отрисовки спектрум-экрана.
С NO_GFX=1 эти циклы целиком уходят CPU и DMA-пересылке байт в FT812. На бордюре чтения и так нет —
там всегда полный лимит свободен.

---

## 2. SPI-протокол FT812

### 2.1. Три типа транзакций (по 2-битному префиксу)

| Префикс | Тип            | Структура                                      |
|---------|----------------|------------------------------------------------|
| `00b`   | Memory Read    | 2b prefix + 22b address + dummy byte + N data bytes |
| `10b`   | Memory Write   | 2b prefix + 22b address + N data bytes        |
| `01b`   | Host Command   | 2b prefix + 6b cmd code + arg byte + 0x00     |
| `11b`   | (зарезервирован) | — |

На уровне Z80 префикс — это два старших бита первого отправляемого байта адреса:
- Read: первый байт = `addr[21:16]` (биты 7..6 = `00`)
- Write: первый байт = `addr[21:16] OR 0x80` (биты 7..6 = `10`)
- Host command: первый байт = `0x40 OR cmd[5:0]`

### 2.2. Каждая транзакция в обёртке CS

```
FT_ON                  ; OUT (0x77), 0x07 — взвести CS
... последовательность OUT/IN через 0x57 ...
FT_OFF                 ; OUT (0x77), 0x03 — снять CS
```

Внутри одной транзакции **адрес FT812 авто-инкрементируется** — длина блока не ограничена,
если данные пишутся в непрерывную область памяти. Это позволяет одной транзакцией залить
весь Display List или большой bitmap.

### 2.3. Готовые asm-функции (из учебника #2)

#### Макросы CS

```asm
FT_ON:   MACRO
    LD  A, 0x07         ; SPI_FT_CS_ON
    OUT (0x77), A       ; SPI_CTRL
ENDM

FT_OFF:  MACRO
    LD  A, 0x03         ; SPI_FT_CS_OFF
    OUT (0x77), A
ENDM

FT_VMODE: MACRO
    LD  A, %00100100    ; FT_EN=1, NO_GFX=1
    OUT (0xAF), A
ENDM
```

#### FT_RD8 — чтение байта из RAM_REG

```asm
; In:  DE = addr[15..0] (адрес внутри RAM_REG, старший байт фиксирован = 0x30)
; Out: A  = прочитанный байт
; Corrupts: AF
FT_RD8:
    FT_ON
    LD  A, 0x30          ; FT_RAM_REG >> 16 = 0x30
    OUT (0x57), A        ; addr[21..16] (префикс 00b — read)
    LD  A, D
    OUT (0x57), A        ; addr[15..8]
    LD  A, E
    OUT (0x57), A        ; addr[7..0]
    OUT (0x57), A        ; dummy OUT (FT812 готовится)
    IN  A, (0x57)        ; dummy IN (особенность чтения)
    IN  A, (0x57)        ; реальные данные
    PUSH AF
    FT_OFF
    POP AF
    RET
```

**Важно:** для чтения **всегда** нужен один dummy OUT + один dummy IN после трёх байт адреса,
иначе следующий IN вернёт мусор.

#### FT_RD16

```asm
; In:  DE = addr[15..0]
; Out: BC = прочитанное 16-битное значение (little-endian)
FT_RD16:
    FT_ON
    LD  A, 0x30 : OUT (0x57), A
    LD  A, D    : OUT (0x57), A
    LD  A, E    : OUT (0x57), A
    OUT (0x57), A         ; dummy OUT
    IN  A, (0x57)         ; dummy IN
    IN  A, (0x57) : LD C, A   ; младший байт
    IN  A, (0x57) : LD B, A   ; старший байт
    FT_OFF
    RET
```

#### FT_WR8 — запись байта в регистр

```asm
; In:  DE = addr[15..0], A = записываемое значение
FT_WR8:
    PUSH AF
    FT_ON
    LD  A, (0x30) OR 0x80   ; bit 7 = 1 → префикс 10b → write
    OUT (0x57), A
    LD  A, D : OUT (0x57), A
    LD  A, E : OUT (0x57), A
    POP AF
    OUT (0x57), A           ; данные
    FT_OFF
    RET
```

#### FT_Write — блочная запись через OTIR

```asm
; In:  HL = Z80-источник, BC = количество байт,
;      A  = addr[21..16] (без bit 7), DE = addr[15..0]
; Out: HL += BC, ADE += BC (для chained-вызовов)
FT_Write:
    PUSH AF
    FT_ON
    POP  AF
    PUSH AF
    OR   0x80               ; включаем bit 7 — write префикс
    OUT  (0x57), A
    LD   A, D : OUT (0x57), A
    LD   A, E : OUT (0x57), A
    POP  AF

    ; пересчитать адрес для следующего вызова: HL += BC, ADE += BC
    EX   DE, HL
    ADD  HL, BC
    EX   DE, HL
    ADC  A, 0
    PUSH AF

    ; основной OTIR loop (256-байтные пакеты)
    LD   A, C   : OR A      ; есть младший хвост?
    LD   A, B               ; A = количество полных пакетов
    LD   B, C               ; B = младший байт count'а
    LD   C, 0x57            ; SPI_DATA
    JR   Z, .loop

    OTIR                    ; неполный пакет
    OR   A
    JR   Z, .exit

.loop:
    OTIR                    ; B=0 → 256 байт
    DEC  A
    JR   NZ, .loop

.exit:
    FT_OFF
    POP  AF
    RET
```

`FT_Read` строится симметрично через `INIR`, без bit 7 в первом байте + dummy перед циклом.

### 2.4. Когда размер блока удобен

- Заливка bitmap в RAM_G — одна транзакция на килобайты
- Полный DL (до 8 KB) — одна транзакция
- Запись в RAM_CMD кольцевого буфера — порциями до wrap'а

---

## 3. Memory Map FT812

22-битное адресное пространство; всё mapped единообразно по SPI:

| Диапазон             | Размер | Имя         | Назначение                           |
|----------------------|--------|-------------|--------------------------------------|
| `0x000000-0x0FFFFF`  | 1024 KB| RAM_G       | Графика общего назначения (bitmaps)  |
| `0x1E0000-0x2FFFFB`  | 1152 KB| ROM_FONT    | Шрифты ROM                           |
| `0x300000-0x301FFF`  | 8 KB   | RAM_DL      | Display List                         |
| `0x302000-0x302FFF`  | 4 KB   | RAM_REG     | Регистры                             |
| `0x308000-0x308FFF`  | 4 KB   | RAM_CMD     | Co-processor command buffer (ring)   |

**Endianness**: little-endian для всех многобайтных значений (Z80-friendly).

### 3.1. Ключевые регистры RAM_REG

| Адрес      | Имя                | Биты | Сброс    | Назначение |
|------------|-------------------|------|----------|------------|
| `0x302000` | REG_ID            | 8 ro | `0x7C`   | Сигнатура чипа (sanity-check) |
| `0x302004` | REG_FRAMES        | 32 ro| 0        | Счётчик кадров от reset |
| `0x30200C` | REG_FREQUENCY     | 28 rw| 60000000 | Тактовая частота в Hz |
| `0x30202C` | REG_HCYCLE        | 12 rw| 0x224    | Полное число PCLK на строку |
| `0x302030` | REG_HOFFSET       | 12 rw| 0x02B    | H-offset (front porch + sync + back porch) |
| `0x302034` | REG_HSIZE         | 12 rw| 0x1E0    | Видимая ширина в PCLK = пикселях |
| `0x302038` | REG_HSYNC0        | 12 rw| 0x000    | H-sync front porch |
| `0x30203C` | REG_HSYNC1        | 12 rw| 0x029    | H-sync front + pulse |
| `0x302040` | REG_VCYCLE        | 12 rw| 0x124    | Полное число строк на кадр |
| `0x302044` | REG_VOFFSET       | 12 rw| 0x00C    | V-offset |
| `0x302048` | REG_VSIZE         | 12 rw| 0x110    | Видимая высота в строках |
| `0x30204C` | REG_VSYNC0        | 10 rw| 0        | V-sync front porch |
| `0x302050` | REG_VSYNC1        | 10 rw| 0x00A    | V-sync front + pulse |
| `0x302054` | REG_DLSWAP        | 2 rw | 0        | Управление flip'ом DL (0/1/2) |
| `0x302070` | REG_PCLK          | 8 rw | 0        | Делитель PCLK (0=PCLK выкл) |
| `0x30206C` | REG_PCLK_POL      | 1 rw | 0        | Полярность PCLK |
| `0x302100` | REG_CMD_DL        | 13 rw|          | Co-processor pointer в DL |

### 3.2. DLSWAP modes

| Значение | Имя              | Эффект |
|----------|------------------|--------|
| 0        | `DLSWAP_DONE`    | Текущий swap завершён (read) |
| 1        | `DLSWAP_LINE`    | Swap по строке |
| 2        | `DLSWAP_FRAME`   | Swap в начале vsync (стандарт) |

После записи нового DL → `FT_WR8(REG_DLSWAP, DLSWAP_FRAME)` — кадр обновится в следующем vsync.

---

## 4. Видеотаймминги для 640×480

TSLib содержит выверенные таблицы для **трёх** режимов 640×480 (`Include\FT\81x Const.inc:359-391`):

### 4.1. VM_640_480_57Hz (PCLK 24 MHz, F_MUL=3) — целевой для Zuma

| Параметр    | H (Horizontal) | V (Vertical) |
|-------------|---------------:|-------------:|
| Front porch | 16             | 11           |
| Sync pulse  | 96             | 2            |
| Back porch  | 48             | 31           |
| Visible     | **640**        | **480**      |
| Total       | 800            | 524          |

`F_MUL` = множитель базового clock'а 8 МГц (REG_FREQUENCY основа). 8 × 3 = 24 МГц pixel clock.
TSLib-константа: `F0_MUL=3, H0_FPORCH=16, H0_SYNC=96, H0_BPORCH=48, H0_VISIBLE=640, V0_FPORCH=11, V0_SYNC=2, V0_BPORCH=31, V0_VISIBLE=480`.

### 4.2. VM_640_480_74Hz (PCLK 32 MHz, F_MUL=4) — повышенная частота

`F1_MUL=4, H1_FPORCH=24, H1_SYNC=40, H1_BPORCH=128, V1_FPORCH=9, V1_SYNC=3, V1_BPORCH=28`.

### 4.3. VM_640_480_76Hz (PCLK 32 MHz, F_MUL=4)

`F2_MUL=4, H2_FPORCH=16, H2_SYNC=96, H2_BPORCH=48, V2_FPORCH=11, V2_SYNC=2, V2_BPORCH=31`.

### 4.4. Соответствие регистрам FT812

TSLib `FT_ModeTab` (`81x Const.inc:460`) укладывает значения в следующие регистры FT812:

| Регистр       | Формула                       | для VM_640_480_57Hz |
|---------------|-------------------------------|--------------------:|
| REG_HSYNC0    | H_FPORCH                      | 16                  |
| REG_HSYNC1    | H_FPORCH + H_SYNC             | 112                 |
| REG_HOFFSET   | H_FPORCH + H_SYNC + H_BPORCH  | 160                 |
| REG_HSIZE     | H_VISIBLE                     | 640                 |
| REG_HCYCLE    | H_FPORCH+SYNC+BPORCH+VISIBLE  | 800                 |
| REG_VSYNC0    | V_FPORCH − 1                  | 10                  |
| REG_VSYNC1    | V_FPORCH + V_SYNC − 1         | 12                  |
| REG_VOFFSET   | V_FPORCH+V_SYNC+V_BPORCH − 1  | 43                  |
| REG_VSIZE     | V_VISIBLE                     | 480                 |
| REG_VCYCLE    | V_FPORCH+V_SYNC+V_BPORCH+V_VISIBLE | 524            |
| REG_PCLK      | F_MUL                         | 3 (PCLK = 8×3 = 24 МГц) |
| REG_PCLK_POL  | 0                             | 0                   |

### 4.5. Применение через TSLib-макрос

В TSLib переключение режима — одна строчка:

```asm
                FT_RESOLUTION VM_640_480_57Hz, ResolutionWidthPtr
```

Где `ResolutionWidthPtr` — Z80-указатель на 2-байтную ячейку в RAM, куда макрос
сохраняет ширину экрана для последующего использования (`Examples\2.HelloWorld\Include.inc:8`).

`FT_RESOLUTION` (`Include\FT\812 Macro.inc:354`) сам разворачивается в нужную таблицу
+ серию `FT_WR_REG16` по адресам HCYCLE/HOFFSET/HSIZE/HSYNC0/HSYNC1/VCYCLE/VOFFSET/VSIZE/VSYNC0/VSYNC1
+ `FT_WR_REG8 FT_REG_PCLK` со значением F_MUL.

### 4.6. Полная init-последовательность (TSLib `FT_BOOT_UP`)

`Include\FT\812 Macro.inc:104`:

```asm
FT_BOOT_UP      macro
                FT_SEND_COMMAND FT_CMD_PWRDOWN_       ; #50 — power-down
                FT_DELAY 3
                FT_SEND_COMMAND FT_CMD_CLKEXT         ; #44 — внешний clock
                FT_DELAY 3
                LD B, FT_CMD_CLKSEL                   ; #61 — clock select
                LD C, #C0                             ; PLL range / MUL
                CALL FT.SendCommand.Param
                FT_SEND_COMMAND FT_CMD_ACTIVE         ; #00 — активировать
                FT_DELAY 15

.WaitIntReady   FT_RD_REG8 FT_REG_ID                  ; ждать REG_ID == 0x7C
                CP #7C
                JR NZ, .WaitIntReady

.WaitCPU_Reset  FT_RD_REG8 FT_REG_CPURESET            ; ждать REG_CPURESET == 0
                OR A
                JR NZ, .WaitCPU_Reset

                FT_WR_REG8  FT_REG_PCLK,    0         ; PCLK выкл — таймминги настраиваются "тихо"
                FT_WR_REG16 FT_REG_HCYCLE,  0x224     ; default тайминги
                FT_WR_REG16 FT_REG_HOFFSET, 0x02B
                ; ... HSYNC0/1, VCYCLE/OFFSET/VSYNC0/1, SWIZZLE, PCLK_POL ...
                FT_WR_REG16 FT_REG_HSIZE,   0x1E0
                FT_WR_REG16 FT_REG_VSIZE,   0x110
                FT_WR_REG16 FT_REG_CSPREAD, 0x001
                FT_WR_REG16 FT_REG_DITHER,  0x001
                FT_WR_REG16 FT_REG_OUTBITS, 0x000
                FT_WR_REG16 FT_REG_GPIOX_DIR, 0xFFFF  ; все GPIOX выходы
                FT_WR_REG16 FT_REG_GPIOX,     0xFFFF  ; включить DISP
                FT_WR_REG8  FT_REG_PCLK,    2         ; PCLK on (default 60/2 = 30 МГц)
                endm
```

После `FT_BOOT_UP` нужный режим выставляется через `FT_RESOLUTION VM_640_480_57Hz`.
Финальный шаг — переключить выход TS-Conf на FT812 и отключить обычный gfx:

```asm
                Video_Setting VID_FT812 | VID_NOGFX  ; OUT (0xAF), %00100100
```

`Video_Setting` — TSLib-макрос (`Include\Cache\Macro.inc` и др.), эквивалент учебника #2.

---

## 5. Display List

### 5.1. Структура

DL = массив 32-bit команд в RAM_DL (`0x300000`..`0x301FFF`). Максимум 2048 команд.
Каждая команда — 4 байта little-endian. Последняя команда обязана быть `DISPLAY()`.

После записи DL → `REG_DLSWAP=DLSWAP_FRAME` → следующий vsync покажет новый кадр.

### 5.2. Базовые opcodes (минимальный набор для Zuma)

| Команда                      | Opcode | Формат |
|------------------------------|--------|--------|
| `DISPLAY()`                  | 0x00 << 24 | конец DL |
| `BEGIN(prim)`                | 0x1F << 24 \| prim | старт примитива |
| `END()`                      | 0x21 << 24 | конец примитива |
| `CLEAR_COLOR_RGB(r,g,b)`     | 0x02 << 24 \| (r<<16) \| (g<<8) \| b | цвет очистки |
| `CLEAR(c,s,t)`               | 0x26 << 24 \| (c<<2) \| (s<<1) \| t | очистка буферов |
| `COLOR_RGB(r,g,b)`           | 0x04 << 24 \| (r<<16) \| (g<<8) \| b | цвет рисования |
| `COLOR_A(a)`                 | 0x10 << 24 \| a | альфа |
| `BLEND_FUNC(src,dst)`        | 0x0B << 24 \| (src<<3) \| dst | смешивание |
| `POINT_SIZE(s)`              | 0x0D << 24 \| s | радиус точки в 1/16 px |
| `LINE_WIDTH(w)`              | 0x0E << 24 \| w | толщина линии 1/16 |
| `BITMAP_HANDLE(h)`           | 0x05 << 24 \| h | активный handle (0..31) |
| `BITMAP_SOURCE(addr)`        | 0x01 << 24 \| addr | источник в RAM_G |
| `BITMAP_LAYOUT(fmt,stride,h)`| 0x07 << 24 \| (fmt<<19) \| (stride<<9) \| h | формат + stride |
| `BITMAP_SIZE(filter,wrx,wry,w,h)` | 0x08 << 24 \| (filter<<20) \| (wrx<<19) \| (wry<<18) \| (w<<9) \| h | визуальный размер |
| `CELL(c)`                    | 0x06 << 24 \| c | номер cell в атласе |
| `VERTEX2II(x,y,h,c)`         | 0x80000000 \| (x<<21) \| (y<<12) \| (h<<7) \| c | вершина integer + handle + cell |
| `VERTEX2F(x,y)`              | 0x40000000 \| (sx<<15) \| sy | subpixel вершина (1/16) |
| `SCISSOR_XY(x,y)`            | 0x1B << 24 \| (x<<11) \| y | clip origin |
| `SCISSOR_SIZE(w,h)`          | 0x1C << 24 \| (w<<12) \| h | clip size |
| `SAVE_CONTEXT()`             | 0x22 << 24 | стек контекста push |
| `RESTORE_CONTEXT()`          | 0x23 << 24 | pop |

`prim` для `BEGIN`:
- 1 BITMAPS, 2 POINTS, 3 LINES, 4 LINE_STRIP, 5 EDGE_STRIP_R/L/A/B (6,7,8,9), 9 RECTS

### 5.3. Минимальный «Hello World» DL

Заливаем экран синим цветом:

```
0x02_00_00_64  ; CLEAR_COLOR_RGB(0,0,100)   [синий]
0x26_00_00_07  ; CLEAR(1,1,1)               [color, stencil, tag]
0x00_00_00_00  ; DISPLAY()
```

Записать 12 байт в `0x300000`, затем `REG_DLSWAP = 2` → синий экран на следующем vsync.

### 5.4. Цепочка спрайтов из атласа

Для рендера 240 шаров Zuma из атласа (handle 0, 6 cells × 40×40):

```
SAVE_CONTEXT()
BITMAP_HANDLE(0)
BEGIN(BITMAPS)
; per-ball loop:
;   COLOR_RGB(255,255,255)     ; без тинта
;   VERTEX2II(x, y, 0, color)  ; одна 32-bit команда на шар
END()
RESTORE_CONTEXT()
DISPLAY()
```

Для 240 шаров = ~244 32-bit команды = ~976 байт DL (вмещается в 8KB).

### 5.5. Co-processor (RAM_CMD) — для удобства

Командный буфер `0x308000`+ — кольцевой, читается co-processor'ом FT812. Команды:
- `cmd_dlstart` — открыть новый DL
- `cmd_swap` — REG_DLSWAP
- `cmd_loadimage` — JPEG/PNG → RAM_G
- `cmd_text`, `cmd_number` — рендер текста (DL команды генерируются автоматически)
- `cmd_rotate`, `cmd_translate`, `cmd_scale`, `cmd_setmatrix` — матричные трансформации

Запись в RAM_CMD управляется парой `REG_CMD_WRITE` (наша запись) и `REG_CMD_READ` (читает FT812).
Wrapping — 4KB. После записи → `REG_CMD_WRITE = новый offset`. Ждать пока FT812 не прочитает: `REG_CMD_READ == REG_CMD_WRITE`.

---

## 6. Bitmap-форматы для FT812

| Формат         | Бит/пиксель | Описание                    | Применение |
|----------------|-------------|-----------------------------|------------|
| ARGB1555       | 16          | 5R 5G 5B 1A                 | Спрайты с 1-bit маской |
| L1             | 1           | Чёрно-белый                  | Биткарты |
| L2             | 2           | 4 уровня серого             | Полупрозрачные текстуры (есть нюанс — см. Bowman 15.2) |
| L4             | 4           | 16 серых                    | Шрифты |
| L8             | 8           | 256 серых                   | Маски |
| RGB332         | 8           | 3R 3G 2B                    | Фон без точности |
| ARGB2          | 8           | 2A 2R 2G 2B                 | Лёгкая прозрачность |
| ARGB4          | 16          | 4 на канал                  | Полупрозрачные спрайты |
| RGB565         | 16          | Стандарт без альфы          | Backgrounds, спрайты без прозрачности |
| PALETTED4/8/565| 4/8/8       | Через CRAM                  | Наши шары/фон с экономией памяти |
| BARGRAPH       | spec.       | Гистограммы                 | UI |

**Для Zuma 640×480 рекомендации:**
- Background: PALETTED8 (256 цветов) → 640×480 = 307KB; либо RGB565 → 614KB.
- Шары 6 цветов × 40×40: PALETTED8 → 9.6KB атлас; либо RGB565 → 19.2KB. Маска 1-bit для прозрачности отдельным L1-bitmap'ом.
- Жаба 128×128: ARGB4 (есть альфа) → 32KB.
- Курсор 32×32: ARGB1555 → 2KB.
- Killzone 64×64 (1 frame): ARGB4 → 8KB.

Итого ~360 KB из 1024 KB RAM_G — есть запас на анимации.

---

## 7. Производительность и DMA

### 7.1. Оценка bandwidth Z80 → FT812 через SPI

- ZX-Evo Z80 на ~7 MHz
- `OTIR` = 21 такта/байт = ~333 KB/s максимум
- Через DMA TS-Conf (если задействована) — выше, до ~1 MB/s

### 7.2. Полный кадр при 60 fps

- Frame budget: 16.7 ms
- DL обновление 240 шаров: ~1 KB → 3 ms через OTIR
- Background не обновляется каждый кадр (статичен в RAM_G после init)

### 7.3. NO_GFX=1 экономит DMA

С `NO_GFX=1` лимит DMA на строку (448 циклов) полностью доступен для FT812-передач,
а не делится с TS-Config рендером. Это критично для частых обновлений RAM_G (анимация фона).

---

## 8. План разработки Zuma VDAC2 (контекст)

1. ✅ Базовая 360×288-версия Zuma собирается в папке проекта.
2. ✅ Python-эмулятор VDC масштабирован под 640×480 (визуальная отладка).
3. ⏳ Init-последовательность FT812: detect → power → таймминги 640×480 → REG_PCLK.
4. ⏳ Первый «hello DL» — синий экран через VDAC2.
5. ⏳ Загрузка тестового bitmap в RAM_G + рендер одной точкой.
6. ⏳ Атлас шаров → BITMAP_HANDLE → VERTEX2II loop по slots[].
7. ⏳ Background (палитра + bitmap из конвертера).
8. ⏳ Жаба + cursor + killzone как handles 1/2/3.
9. ⏳ Sync VDC engine 360×288 ↔ FT812 рендер 640×480 (scale ×2 в координатах).

---

## 9. Главный цикл рендера (Hello World pattern из TSLib)

`Examples\2.HelloWorld\Core\MainLoop.asm` — образцовая структура кадра:

```asm
.Loop           FT_CMD_Start                 ; начать собирать команды в буфер RAM Z80
                FT_DL_Start                  ; команда DLSTART для co-processor

                FT_ClearColorRGB32 0x000000  ; чёрный фон
                FT_ClearAll                  ; clear color + stencil + tag

                CALL ShowText                ; <- наш контент
                CALL Fizz

                FT_Display                   ; конец DL
                FT_CMD_Write                 ; залить буфер из RAM Z80 в RAM_CMD FT812

                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME  ; запросить swap

.WaitIntSwap    FT_RD_REG8 FT_REG_INT_FLAGS  ; дождаться SWAP interrupt
                AND FT_INT_SWAP
                JR Z, .WaitIntSwap

                FT_DELAY 2
                JP .Loop
```

### 9.1. Что делает `FT_CMD_Start`/`FT_CMD_Write`

`FT_CMD_Start` — устанавливает Z80-указатель `FT.Coprocessor.BufferPtr` в начало
**локального буфера** `CMD_ADDRESS_PTR` в RAM Z80 (см. `BufferMacro.inc:5`).
Все последующие `FT_CMD_BUF`/`FT_ClearAll`/`FT_Begin`/`FT_Vertex2ii` — это **запись 4-байтных
команд в этот локальный буфер** (через `LD (HL), E : INC HL` × 4).

`FT_CMD_Write` — считает длину буфера (текущий ptr − начало) и блочно отправляет всё
в RAM_CMD FT812 через `FT.Coprocessor.Write` (вызывает `FT_Write`/OTIR-цикл).

Это ключевой паттерн: **DL собирается в RAM Z80**, затем **одной транзакцией** уходит
в FT812. Гораздо эффективнее чем командировать FT812 по одной команде за раз.

### 9.2. FT_DLSWAP_FRAME / FT_INT_SWAP

После записи команд `REG_DLSWAP = FT_DLSWAP_FRAME (=2)` запрашивает swap в начале
ближайшего vsync. `REG_INT_FLAGS` бит `FT_INT_SWAP` поднимается когда swap состоялся —
это сигнал «можно начинать новый кадр». Без ожидания будут «глитчи»: писать в DL пока
FT-engine ещё рендерит — undefined.

`FT_INT_MASK` и `FT_INT_EN` нужно настроить в init (Hello World делает: `FT_REG_INT_MASK = FT_INT_SWAP`, `FT_REG_INT_EN = 1`).

## 10. TSLib API — карта макросов

### 10.1. Низкий уровень: `Include\FT\812 Macro.inc`

| Макрос                               | Описание |
|--------------------------------------|----------|
| `FT_ON` / `FT_OFF`                   | CS управление (= OUT 0x77) |
| `FT_VMODE`                           | OUT (VCONFIG), VID_FT812 |
| `FT_ACTIVE`                          | host command #00 → выйти из standby |
| `FT_BOOT_UP`                         | полная init-последовательность (см. §4.6) |
| `FT_CMD_RESET`                       | сброс co-processor (CMD_READ/WRITE = 0) |
| `FT_SEND_COMMAND`                    | host command (3 байта) |
| `FT_DELAY Count?`                    | NOP-задержка |
| `FT_RD_REG8` / `FT_RD_REG16` / `FT_RD_REG32`  | чтение регистра |
| `FT_WR_REG8` / `FT_WR_REG16` / `FT_WR_REG32`  | запись регистра |
| `FT_RESOLUTION VM_*, RefPtr`         | переключение видеорежима |

### 10.2. Прямой Display List в RAM_DL: `Include\FT\DL  Macro.inc`

Каждый макрос разворачивается в `DEFD <opcode>` (4 байта в текущем месте сборки).
Используется когда DL **зашит в постоянную область** (например, статическая графика
уровня), не строится каждый кадр.

| Макрос                          | Opcode | Назначение |
|---------------------------------|--------|------------|
| `FT_DISPLAY`                    | 0x00   | Конец DL (обязателен) |
| `FT_BITMAP_SOURCE Address?`     | 0x01   | Источник в RAM_G |
| `FT_CLEAR_COLOR_RGB R,G,B`      | 0x02   | Цвет очистки |
| `FT_TAG`                        | 0x03   | Тег для touch |
| `FT_COLOR_RGB R,G,B`            | 0x04   | Цвет рисования |
| `FT_BITMAP_HANDLE H`            | 0x05   | Активный handle (0..31) |
| `FT_CELL c`                     | 0x06   | Cell в атласе |
| `FT_BITMAP_LAYOUT fmt,stride,h` | 0x07   | Формат + stride |
| `FT_BITMAP_SIZE filter,wx,wy,w,h` | 0x08 | Размер для рендера |
| `FT_ALPHA_FUNC`                 | 0x09   | Альфа-тест |
| `FT_STENCIL_FUNC`               | 0x0A   | Stencil-тест |
| `FT_BLEND_FUNC src,dst`         | 0x0B   | Смешивание |
| `FT_POINT_SIZE s`               | 0x0D   | Радиус точки 1/16 |
| `FT_LINE_WIDTH w`               | 0x0E   | Толщина линии |
| `FT_COLOR_A a`                  | 0x10   | Альфа |
| `FT_BITMAP_TRANSFORM_A..F`      | 0x15-1A| Матрица 2D трансформации |
| `FT_SCISSOR_XY x,y`             | 0x1B   | Clip origin |
| `FT_SCISSOR_SIZE w,h`           | 0x1C   | Clip size |
| `FT_BEGIN prim`                 | 0x1F   | Старт примитива |
| `FT_END`                        | 0x21   | Конец примитива |
| `FT_SAVE_CONTEXT`               | 0x22   | Push контекст |
| `FT_RESTORE_CONTEXT`            | 0x23   | Pop контекст |

`prim` для `BEGIN`: 1=BITMAPS, 2=POINTS, 3=LINES, 4=LINE_STRIP, 5/6/7/8=EDGE_STRIP_*, 9=RECTS.

### 10.3. Сборка DL через co-processor: `Include\FT\Coprocessor\BufferMacro.inc`

Те же команды, но макросы пишут не `DEFD`, а `FT_CMD_BUF` (накапливают в RAM Z80
для последующего `FT_CMD_Write`). Используется в `MainLoop` каждый кадр.

| Макрос                    | Что делает |
|---------------------------|------------|
| `FT_CMD_Start`            | Сбросить указатель Z80-буфера |
| `FT_DL_Start`             | Команда CMD_DLSTART (открыть новый DL) |
| `FT_ClearColorRGB32 RGB?` | Цвет очистки 0xRRGGBB |
| `FT_ClearAll`             | Clear all (color + stencil + tag) |
| `FT_Clear C,S,T`          | Selective clear |
| `FT_Begin prim` / `FT_End` | Примитивы |
| `FT_Vertex2f X,Y`         | Вершина float (1/16 px) |
| `FT_Vertex2ii X,Y,H,C`    | Вершина integer + handle + cell в одной команде |
| `FT_PointSize s`          | Радиус точки |
| `FT_LineWidth w`          | Толщина линии |
| `FT_ColorRGB` / `FT_ColorRGB32` | Цвет |
| `FT_ColorA a`             | Альфа |
| `FT_BitmapHandle H`       | Активный handle |
| `FT_BitmapSource addr`    | Указать на bitmap в RAM_G |
| `FT_BitmapLayout fmt,stride,h` | Формат |
| `FT_BitmapSize filter,wx,wy,w,h` | Размер |
| `FT_Cell c`               | Cell в атласе |
| `FT_BlendFunc src,dst`    | Смешивание |
| `FT_ScissorXY` / `FT_ScissorSize` | Clip |
| `FT_SaveContext` / `FT_RestoreContext` | Стек контекста |
| `FT_Tag t` / `FT_TagMask` | Touch теги |
| `FT_VertexFormat frac`    | Точность Vertex2f (бит 0..7 = 1/2..1/256 px) |
| `FT_VertexTranslateX/Y`   | Смещение всех последующих Vertex |
| `FT_PaletteSource`        | Палитра PALETTED-форматов |
| `FT_FGColor` / `FT_BGColor` / `FT_GRADColor` | Цвета для widgets |
| `FT_Text X,Y,Font,Opt`    | Текст |
| `FT_String addr,len`      | Строка для FT_Text |
| `FT_Gradient x1,y1,rgb1,x2,y2,rgb2` | Градиент |
| `FT_Display`              | Конец DL |
| `FT_CMD_Swap`             | CMD_SWAP (через co-processor) |
| `FT_CMD_Interrupt ms`     | CMD_INTERRUPT |

### 10.4. Coprocessor функции (`Include\FT\Coprocessor\Buffer.asm` + Cmd.asm)

Дополнительные runtime-функции:
- `FT.Coprocessor.PointSize` — `LD DE, size` → пишет POINT_SIZE в буфер
- `FT.Coprocessor.ColorRGB` — `LD C, R : LD D, G : LD E, B`
- `FT.Coprocessor.ColorA` — `LD E, A`
- `FT.Coprocessor.Vertex2f` — `LD HL, X : LD DE, Y` (subpixel)
- `FT.Coprocessor.WaitFlush` — ждать пока FT прочитает RAM_CMD
- `FT.Coprocessor.GetPtr` — получить текущий REG_CMD_DL (для return-адресов в DL)
- `FT.Coprocessor.IsFault` — проверка ошибки co-processor
- `FT.Coprocessor.Inflate` — распаковать deflate-blob в RAM_G

### 10.5. Прочее

- `Include\Cache\Macro.inc` — `Cache_Setting EN_0000 | EN_4000 | EN_8000` — TS-Conf cache
- `Include\DMA\Macro.inc` — TS-Conf DMA helpers (для блочных копий, в т.ч. в FT812 — но про DMA-FT учебник #3+)
- `Include\Input\Kempston\Mouse\*` — мышь Kempston (готовое)
- `Include\Math\F16\*`, `Fixed\18.14\*`, `Fixed\2.14\*`, `Lerp.asm`, `Mul/*`, `Div/*` — fixed-point/F16 математика

### 10.6. Готовый Init_Video для Zuma VDAC2

Реализовано в `Init_Video.asm` в корне проекта. Собирается под sjasmplus (--syntax=ab) с TSLib без ошибок (smoke-build см. `_test_init_video.asm`).

Зависимости (порядок важен):
```asm
                DEVICE ZXSPECTRUM4096
                define MAPPING_REGISTERS              ; Video_Setting через FMADDR

                include "Docs/TSLib/Include/TSConf.inc"
                include "Docs/TSLib/Include/Video/Macro.inc"
                include "Docs/TSLib/Include/FT/81x Const.inc"
                include "Docs/TSLib/Include/FT/DL  Macro.inc"
                include "Docs/TSLib/Include/FT/812 Macro.inc"
                module FT
                include "Docs/TSLib/Include/FT/812 Func.asm"
                endmodule

ResolutionWidthPtr   EQU #40F3                        ; Z80-RAM ячейки (FT_RESOLUTION пишет туда W/H)
ResolutionHeightPtr  EQU #40F5

                include "Init_Video.asm"
```

Сама логика (см. файл):

1. **Sanity-check VDAC2**: `IN A,(STATUS) : AND %111 : CP %111` — если бит-маска ≠ 111, возврат с Z=0 (нет VDAC2 на плате).
2. **`FT_BOOT_UP`** — полная init FT812: PWRDOWN→CLKEXT→CLKSEL #C0→ACTIVE, ждать REG_ID=0x7C, default тайминги, GPIOX=0xFFFF, REG_PCLK=2 → видеовыход активирован.
3. **`FT_CMD_RESET`** — обнулить REG_CMD_READ/WRITE (на случай висящих команд).
4. **`FT_RESOLUTION VM_640_480_57Hz, ResolutionWidthPtr`** — переключить таймминги: PCLK=24 МГц (F_MUL=3), HCYCLE 800, VCYCLE 524, HSIZE/VSIZE 640×480.
5. **Залить пустой DL** (12 байт = `CLEAR_COLOR_RGB(0,0,0); CLEAR(1,1,1); DISPLAY()`) в RAM_DL через `FT.WriteDL`, потом `REG_DLSWAP=2` — чёрный экран до первого MainLoop-кадра.
6. **`REG_INT_MASK = FT_INT_SWAP, REG_INT_EN = 1`** — разрешить swap-interrupt для синхронизации MainLoop'а.
7. **`Video_Setting VID_FT812 | VID_NOGFX`** = `OUT (0xAF), %00100100` — переключить TS-Conf выход на FT812 + отключить TS-Config gfx (освобождает 448 DMA-циклов/строку).

Возврат: A=0/Z=1 на успех, A=1/Z=0 если VDAC2 не обнаружен (caller выбирает fallback).

После Init_Video можно входить в MainLoop с FT_CMD_Start/FT_CMD_Write/DLSWAP паттерном (§9).

### 10.7. Готовый MainLoop для Zuma VDAC2 (каркас)

Реализовано в `MainLoop.asm` в корне проекта. Собирается без ошибок (см. `_test_init_video.asm` — там полная цепочка include'ов и `Init_Video → MainLoop` точка входа).

На текущем этапе MainLoop — **proof-of-life каркас**: тёмно-синий фон + одна оранжевая точка 16 px радиуса, отскакивающая от краёв 640×480. По мере добавления game-state'а сюда подключатся VDC engine update, цикл по `slots[]`, frog/cursor/score.

Структура одного кадра (6 шагов):

```asm
.Loop           ; 1. Открываем DL, заливаем общую очистку
                FT_CMD_Start
                FT_DL_Start
                FT_ClearColorRGB32 0x102030
                FT_ClearAll

                ; 2. Контент кадра
                CALL ZL_DrawFrame             ; PointSize + ColorRGB + Begin POINTS + Vertex2f + End

                ; 3. Закрытие DL и заливка в FT812
                FT_Display
                FT_CMD_Write                  ; OTIR-блок RAM Z80 → RAM_CMD FT812

                ; 4. Запросить swap при следующем vsync
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME

                ; 5. Заблокироваться до swap-interrupt'а
.WaitIntSwap    FT_RD_REG8 FT_REG_INT_FLAGS
                AND FT_INT_SWAP
                JR Z, .WaitIntSwap

                ; 6. Update game state (между swap'ом и следующим DL)
                CALL ZL_UpdateGame
                JP .Loop
```

**Важно про порядок** в одном кадре:
- `FT_CMD_Start` сбрасывает указатель локального буфера в RAM Z80 (`CMD_ADDRESS_PTR`, по умолчанию `#C000`).
- Все макросы группы `FT_*` из `BufferMacro.inc` **только пишут в этот буфер** — пока не вызван `FT_CMD_Write`, ничего на FT812 не уходит.
- `FT_CMD_Write` — **одна** OTIR-транзакция в `REG_CMDB_WRITE` (FT_RAM_CMD). Эффективнее команд по одной.
- `REG_DLSWAP=FT_DLSWAP_FRAME` запрашивает swap. Без ожидания `FT_INT_SWAP` следующий DL может начать строиться поверх ещё рендерящегося → артефакты.
- `Update` после `WaitIntSwap` — пока FT-engine отрисовывает только что засвопленный кадр, Z80 свободен для физики. Это **естественный double-buffering**: кадр N+1 готовится пока кадр N показывается.

**Точка состояния (`ZL_PointX`/`ZL_PointY` etc.)** хранится в коде через `DEFW 0` — после загрузки .bin это валидные ячейки, MainLoop при первом входе явно их инициализирует на `(SCR_W/2, SCR_H/2)` и скорость `(3, 2)` px/frame в 1/16-формате (`VertexFormat=4`, по умолчанию).

**`ZL_DrawFrame`** использует runtime-функции `FT.Coprocessor.ColorRGB`/`PointSize`/`Vertex2f` (из `Coprocessor/Buffer.asm`) — они принимают значения в регистрах (BC/DE), а не immediate, что нужно для динамической позиции.

**`ZL_UpdateGame`** — bouncing: `X += VelX`, если `X >= MAX_X` или `X < MIN_X` → clamp + `VelX = -VelX` через мини-helper `ZL_NegateW`. То же по Y.

Smoke-test: `_test_init_video.asm` — точка входа `Init_Video → MainLoop`, при сборке через sjasmplus 1.18.3 даёт `Errors: 0, warnings: 0, compiled: 4370 lines`. Не запускался на реальном hardware/эмуляторе — это следующий шаг (нужен spgbld + правильные SAVEBIN директивы под ZX-Evo memory layout).

## 11. Открытые вопросы / TODO для углубления учебника

- ✅ ~~Точные таймминги VGA 640×480~~ — закрыто (TSLib `81x Const.inc:359-391`, см. §4).
- ✅ ~~Полный список opcodes DL~~ — закрыто (TSLib `DL Macro.inc` + `BufferMacro.inc`, см. §10).
- ⏳ RAM_CMD wrapping и синхронизация с REG_CMD_READ/WRITE — есть пример в TSLib `Coprocessor\Buffer.asm`, разобрать и перенести в учебник.
- ⏳ Touch-engine — нам не нужен, но в учебник для полноты: описать REG_TOUCH_*.
- ⏳ Аудио через FT812 — есть mono PCM/ADPCM; в Zuma можно подключить sfx (clicks при insert/match).
- ⏳ DMA-передача в FT812 (упомянута в учебнике #2, но детали в #3+) — раздел дописать после.
- ⏳ Bitmap-конвертация PNG → FT-формат: разобрать `AN_303 FT800 Image File Conversion.pdf` + изучить `Examples/3.Bitmap/Core/TexturesCharacter.inc` / `TexturesParallax.inc` — паттерн как загружают спрайты в RAM_G.
- ⏳ Tilemap для backgrounds — `Examples/Game/Core/Tilemap_DL.asm` (1116 байт) разобрать и перенести в учебник.
- ⏳ FT81X_Series_Programmer_Guide.pdf (4 МБ) — извлечь в txt и дописать недостающие детали (особенно секции про blend modes, color formats, optimization tips).
- ⏳ BRT_AN_033 BT81X Programming Guide (4.8 МБ) — BT81x совместим с FT81x по DL, но добавляет ASTC bitmap formats и CMD_FLASH* — может быть полезно если когда-нибудь будет VDAC3.

---

## §N. Bitmap rendering — matrix transform, scale, paletted formats (опыт 2026-05-09)

### N.1 Главный урок: BITMAP_TRANSFORM работает на bitmap UV, не на screen position

В FT81x матрица `BITMAP_TRANSFORM_A..F` (set через `cmd_setmatrix` после `cmd_loadidentity` + операций) трансформирует **bitmap UV-coordinates** (= какой пиксель bitmap читать), не screen position.

Render-formula: pixel at screen `(vertex_pos.x + u, vertex_pos.y + v)` reads bitmap at `M * (u, v)`.

Из этого следует:
- **`cmd_translate(X, Y)` сдвигает источник** читаемых пикселей. Для UV outside bitmap → BORDER возвращает transparent → sprite **невидим**.
- **Screen position спрайта** задаётся через `Vertex2f((X-half)*16, (Y-half)*16)` (subpixel coords), не через matrix.
- **Matrix используется только для transformations внутри sprite-rect**: rotation вокруг центра, scale, shear.

#### Pattern для rotated sprite (rotation around center)

Sprite size 56×56, центр (28, 28):
```z80
CALL ZL_EmitLoadId
LD HL, 28 : LD DE, 28 : CALL ZL_EmitTranslate     ; UV center to origin
LD A, (tangent) : CALL ZL_EmitRotate              ; rotate UV around (0,0) which is sprite center
LD HL, -28 : LD DE, -28 : CALL ZL_EmitTranslate   ; restore offset
CALL ZL_EmitSetMatrix                              ; emits BITMAP_TRANSFORM_A..F (6 DL cmds)
FT_BitmapHandle 0 / FT_BitmapSource ...
FT_Begin FT_BITMAPS
LD A, cell : CALL FT.Coprocessor.Cell
LD BC, (X-28)*16 : LD DE, (Y-28)*16 : CALL FT.Coprocessor.Vertex2f
FT_End
```

Matrix формула: `M = T(28,28) * R(angle) * T(-28,-28)`. Combined rotations (tangent + spin) можно складывать в одну: `R(tangent + spin)` → один `cmd_rotate`.

### N.2 cmd_scale convention

`cmd_scale(sx, sy)` где `sx, sy` — f16.16 fixed-point. **`scale(N, N)` отображает bitmap в N раз больше** на экране (= sprite displayed at N× native size), не наоборот. Counter-intuitive потому что matrix transforms UV.

Пример: bg хранится 400×300 в RAM_G, нужно отобразить 640×480. Scale factor = 640/400 = 480/300 = 1.6. `cmd_scale(0x1999A, 0x1999A)` (= 1.6 in f16.16).

### N.3 BITMAP_SIZE при upscale

`FT_BitmapSize filter, wrap_x, wrap_y, screen_width, screen_height` определяет **output area on screen** (clipping bounds). При upscale указываем целевой размер 640×480, не native размер bitmap.

`FT_BitmapLayout format, linestride_bytes, native_height` определяет storage в RAM_G — linestride = native_width × bpp, height = native_height (= 300 для 400×300 RGB565).

Filter `FT_BILINEAR` (vs `FT_NEAREST`) даёт smooth interpolation между native pixels при upscale — обязательно для качественного render scaled bitmap.

### N.4 Memory budget для bg (1 MB RAM_G FT812)

bg 640×480 в разных форматах:
| Format | Size | Quality | Эмулятор Unreal |
|---|---|---|---|
| RGB565 (full) | 614 KB | high | ✓ |
| RGB565 + scale 0.5x (320×240) | 154 KB | средне | ✓ |
| RGB565 + scale 0.625x (400×300) | 240 KB | хорошее (compromise) | ✓ |
| RGB332 (1 byte/px) | 307 KB | плохо | ✓ |
| L8 grayscale | 307 KB | greyscale only | ✓ (диагностика) |
| PALETTED8 (1 byte index + 1 KB ARGB8 palette) | 308 KB | хорошее | ✗ серый фон |
| PALETTED4 / PALETTED4444 | 154 KB | 16 colors | ✗ серый фон |

**Unreal эмулятор НЕ реализует palette-formats** — серый фон при попытке. На реальном железе ZX-Evo+FT812 PALETTED должен работать (стандарт FT81x).

### N.5 Asymmetric downscale (X≠Y)

Можно хранить bg с разными scale по осям. Пример: 480×240 RGB565 (X=0.75×, Y=0.5×) = 230 KB. cmd_scale(640/480, 480/240) = cmd_scale(1.33×, 2×). Полезно если detail неравномерно: больше горизонтально (Y blur приемлем) или вертикально.

Для типичных Zuma backgrounds (rotational symmetry — спираль, swirley) — detail изотропен, симметричный downscale (320×240, 400×300) лучше.

### N.6 spgbld page-padding gotcha

Каждая spgbld page = 16384 байт. Если data меньше → padding zeros. При upload через циклы `FT.WriteMem 16384` → padding zeros пишутся в RAM_G **после** реальных данных.

**Опасность:** если RAM_G layout плотный (data1 immediately followed by data2), padding data1 затирает начало data2. Решения:
1. Order: data2 ПОСЛЕ data1 (padding идёт после data2 в свободную область).
2. Gap: ≥16384 байт между блоками.
3. Точный last-page byte count: передавать `BC = real_size mod 16384` для last page.

См. также §N.X (root cause flicker chain 2026-05-09: bg-padding затирал atlas).

### N.7 Compression: PNG/JPEG

GPU FT812 рендерит **только uncompressed pixel buffer** в RAM_G (нужен random pixel access). PNG/JPEG как source — только для compression в spg-файле:
- `cmd_loadimage` (coprocessor): JPEG/PNG → uncompressed RAM_G (single-pass decode).
- `cmd_inflate` (coprocessor): zlib → uncompressed RAM_G.

Это уменьшает spg-file, но НЕ RAM_G. RAM_G всегда хранит uncompressed.

### N.8 Финальный выбор для Zuma VDAC2 (level 1 spiral)

`make_bg_level01.py`: source `levels/level_src_<NN>.png` (clean 640×480) → resize 400×300 LANCZOS → RGB565 LE.
`MainLoop.asm` ZL_DrawFrame: cmd_loadidentity + cmd_scale(0x1999A, 0x1999A) + cmd_setmatrix + bg setup + Begin/Vertex2ii(0,0,1,0)/End.

Memory: 240 KB bg + ~310 KB atlas + freedom для дальнейших assets (frog, score, particles).

### N.8.1 Полный pipeline компрессии bg (нюансы практики)

**Workflow `make_bg_level01.py` → spg → RAM_G:**

1. **Source PNG** — `levels/level_src_<NN>.png` (clean 640×480). НЕ jpeg оригинал, потому что jpg-artifacts усиливаются после downscale + bilinear upscale в FT812.
2. **Downscale 640×480 → 400×300** (LANCZOS) на Z80-стороне через Python. **Важно** — LANCZOS, не BICUBIC: на резких границах spirale Zuma BICUBIC ringing artifacts.
3. **RGB565 LE pack** — каждый пиксель 2 байта `((g>>2 & 7)<<13) | (b>>3) | ... ` little-endian. На FT812 LE — нативный порядок.
4. **Запись в `.bin` файл** размером 240 000 байт.
5. **spgbld pack** — `Block = #0000, #07..#15, bg_level01_pNN.bin` (15 pages × 16384 = 245 760 байт, padding 5760 zero-bytes на последней page).
6. **Z80 upload-loop** в `Initialize:` ставит page в slot 2, копирует через `FT.WriteMem` 16384 байт за раз в RAM_G начиная с `BG_RAMG_ADDR=#010000`.
7. **DL render** в `ZL_DrawFrame`: `loadidentity` + `cmd_scale(0x1999A, 0x1999A)` + `setmatrix` + `BITMAP_LAYOUT FT_RGB565, ZL_BG_W*2, ZL_BG_H` (stride 800 байт, height 300) + `BITMAP_SIZE FT_BILINEAR, BORDER, BORDER, 640, 480` + `Begin BITMAPS / Vertex2ii(0,0,1,0) / End`.

---

## Глава 18. Frog с полной HD-композицией (2026-05-10)

### 18.1 Render order (HD-1:1)

```
plate (no rotation)         — диск под лягушкой
body (rotation matrix)      — frog с лапами + face/mouth
tongue (rotation matrix)    — язык, position = pos + tongueExpand·dir
ball-now (no rotation)      — выстреливаемый шар, position = pos + ballExpand·dir
next-ball (no rotation)     — индикатор на спине, position = pos - 28·dir
overlay (rotation matrix)   — face без лап (HD blink frame 0), маскирует корни tongue
```

Все 4 rotated спрайта (body, tongue, overlay) — **одного размера 122×122**. Это критично для **feature alignment**: после rotation eyes body и eyes overlay должны совпадать → они должны быть на одинаковых **относительных** pixel-offsets от sprite centra. Разный размер → разные относительные offsets → "moon-like" дрейф features при rotation.

### 18.2 RAM_G layout (1 МБ, baseline 2026-05-10)

```
#010000..#04C000  bg (15 pages, 400×300 RGB565 + scale 1.6 upscale)
#04C000..#04E000  killzone (1 page real, в bg padding zone)
#050000..#09C000  balls atlas (19 pages — 6 colors × 8 phases × 56×56 ARGB4)
#09C000..#0A4000  body 122×122 ARGB4 (2 pages)
#0A4000..#0AC000  plate 122×122
#0AC000..#0B4000  tongue 122×122
#0B4000..#0BC000  overlay 122×122 (HD blink frame 0)
свободно           272 КБ для будущих assets
```

**Balls atlas сжат с 16 phases до 8** — освободило 18 pages для overlay full-size.
Chain spin formula поменялась: `& 7` вместо `& 15`, `cell = color*8` вместо `*16`.

### 18.3 Tongue — pos + tongueExpand·dir (HD orbit)

В отличие от tight-cropped sprite (32×80) с pivot (16, 29) — full 122×122 sprite даёт ту же rotation pattern что body:

```asm
; Frog_DrawTongue:
;   matrix = T(61, 61) · R(angle + 192) · T(-61, -61)
;   Vertex2f at (TmpX-61, TmpY-61), screen rect 122×122
;   TmpX = PosX + cos·tongueExpand/128
;   TmpY = PosY + sin·tongueExpand/128
```

`tongueExpand = 24` idle (HD), 0..24 при выстреле. Tongue native асимметричный (stripe внутри 162×162 native занимает y=53..133), поэтому при rotation вокруг centra (61, 61) tongue tip "выходит" из mouth area body.

### 18.4 Ball-now / Next-ball через chain atlas (handle 0)

Используется **тот же** atlas что и chain rendering. Cell = `color*8 + 0` (frame 0, не вращается). Native размер 56×56, рендерится без cmd_scale.

```asm
; Frog_DrawBallNow:
;   no rotation matrix (identity).
;   BITMAP_HANDLE 0 / SOURCE BALLS_RAMG_ADDR / LAYOUT 56*2/56 / SIZE 56/56.
;   Cell(ballColor*8) → frame 0 selected color.
;   Vertex2f((TmpX-28)*16, (TmpY-28)*16), centred at TmpX, TmpY.
;   TmpX = PosX + cos·ballExpand/128 (idle = 24).
```

Next-ball аналогично, но `pos - NEXT_OFFSET·dir` (= -28·dir, на спине после rotation body).

### 18.5 Recoil cycle (HD-style fire animation)

ЛКМ rise-edge → `isFire=1, recoilTick=0, ballExpand=0, ballColor=nextBallColor, nextBallColor=random(0..3)`.

Каждый кадр:
- `recoilTick += 10 BRAD` (≈0.245 rad, HD = 0.25).
- `recoil = sin(recoilTick)` (signed byte, -127..127).
- Пока recoil ≥ 0:
  - `tongueExpand = 24 - (recoil·24)>>7` → язык втягивается в рот (24→0).
  - `ballExpand += 2` (cap 24) → шар выезжает.
  - `pos = posStart - (cos·recoil)/2048, posStart - (sin·recoil)/2048` → тело откатывается на ~8 px max.
- recoil < 0 → end fire, всё в idle.

Полу-цикл синуса = 13 кадров (≈260ms на 50fps), полное возврат ballExpand до 24 — ещё ~5 кадров.

### 18.6 FT81x cmd_scale: matrix хранит INVERSE

Param scale = visual ratio = output/native:
- bg upscale 400→640: `cmd_scale(1.6)` = 0x1999A. Matrix внутри S(1/1.6) = S(0.625). UV = 0.625·screen → UV(640) = 400. ✓ samples full bg.
- ball downscale 56→32: `cmd_scale(0.5714)` = 0x9249. Matrix S(1.75). UV = 1.75·screen → UV(32) = 56. ✓ samples full ball.

Документация FT81x неоднозначна — проверять empirically через bg upscale.

### 18.7 Critical bugs found and fixed (2026-05-10 session)

**Bug 1 — Frog_ComputeAngle truncate без clamp.**
`LD C, L` для `|dx| > 255` обрезает high byte H, остаётся младший байт. E.g., dx=313=0x139 → C=0x39=57. Swap-логика `|dy| > |dx|` инвертируется → frog резко крутится у краёв экрана.

Fix:
```asm
.dx_pos:
    LD   A, H
    OR   A
    JR   Z, .dx_clamped
    LD   L, 255              ; saturate to 255 if H ≠ 0
.dx_clamped:
    LD   C, L                ; true 8-bit clamp
```

То же для `.dy_pos`.

**Bug 2 — Frog_DrawNextBall забывал cmd_scale.**
DrawBallNow применял scale matrix, DrawNextBall пропускал → next-ball рендерился at native 56×56 в screen rect 32×32, центрирован через 16-px half → визуально "огромный шар" с неправильной позицией.

Fix: либо добавить scale matrix в DrawNextBall, либо (как в baseline 2026-05-10) убрать scale из обеих функций и рендерить native 56×56.

**Bug 3 — Multi-sprite feature alignment.**
Body 122 + overlay 80 → eyes на разных pixel-offsets от sprite centra → после rotation eyes body и overlay расходятся → "две точки вращения как Луна".

Fix: все спрайты с одинаковыми features ОДНОГО размера. Required: balls atlas 16→8 phases для освобождения RAM_G.

### 18.8 Python visual_emulator.py — prototype-first workflow

Прототипирование parameters (rotation formula, pivot, offsets, recoil curve) в `visual_emulator.py` (tkinter+PIL) даёт Х30-Х100 ускорение vs цикла sjasmplus → spgbld → Unreal. Параметры подбираются интерактивно через keys (стрелки, `[`/`]`, `,`/`.`, `r`), затем переносятся в asm как численные EQU.

Visual emulator не симулирует FT812 cmd_translate/rotate/scale 1:1 — но даёт визуальный **target behavior** для asm transfer. Различия rendering pipeline (PIL bilinear vs FT812 BILINEAR + cmd_scale convention) могут давать ±1-2 px смещения, но архитектурные параметры (radii, pivots, formulas) переносятся точно.


**Ключевые количественные приёмы:**

- **scale 1.6 = `0x1999A`** в f16.16 (0.6×65536 ≈ 0x9999, целая 1 = 0x10000). **Не `0x19999`, не `0x1A000`** — точное значение.
- **stride = native_width × bpp**, НЕ display_width. Для 400×300 RGB565 stride = 400×2 = 800. Если поставить 1280 (= 640×2 для display) — bitmap читается из неправильных адресов в RAM_G, на экране каша.
- **BITMAP_SIZE.W/H = display, BITMAP_LAYOUT.height = native.** Это обязательная асимметрия: SIZE определяет output rect (для clipping), LAYOUT — storage в RAM_G.
- **FT_BILINEAR обязательно** для качества. С `FT_NEAREST` 400×300→640×480 даёт ступеньки на диагоналях.

**Что НЕ использовали и почему:**

| Approach | Причина отказа |
|---|---|
| Full 640×480 RGB565 (614 KB) | занимает 60% RAM_G, не оставляет места под atlas (300+ KB) |
| 320×240 RGB565 + scale 2× (154 KB) | заметная потеря деталей на детализированной spirale |
| RGB332 (307 KB) | работает, но 256 цветов + dithering = грязный gradient на воде |
| PALETTED8 (308 KB + 1 KB palette) | **Unreal эмулятор не поддерживает** — серый экран. На реальном железе должно работать (стандарт FT81x), но без возможности отладки на эмуляторе — не используем. |
| `cmd_loadimage` JPEG decode | RAM_CMD coprocessor decode 640×480 на загрузку (overhead ~2 сек), нужен `cmd_inflate` для zlib потоков; spg-файл становится меньше, но RAM_G всё равно uncompressed. Не оправдано когда spg ёмкость не критична. |

**Полученный bg memory layout:**

```
RAM_G:
  #000000..#040FFF  → reserved (DL/FONT/HANDLES area FT812)
  #010000..#04A8FF  → bg_level01 (240 000 bytes RGB565 400×300)
  #04A900..#04FFFF  → bg padding (~5 KB) + free
  #050000..#0E4FFF  → balls atlas (602 112 bytes ARGB4 6×16×56×56)
  #0E5000..#0FCFFF  → frog body/plate/tongue (3×30 KB ARGB4 122×122)
  #0FD000..#0FEFFF  → killzone (8 KB)
```

Дальше по AvailableRamG ещё ~6 KB до 1 MB конца — запас для score, particles.

### N.8.2 Bug retro: bg-padding затирает atlas (#0A6000..#0A8000)

Эта история относится к §N.6 page-padding gotcha. **Хронология:**
- bg первый раз грузился ПОСЛЕ atlas. atlas в `#050000..#0A6000` (302 KB старая версия 6×8 frames). bg в `#010000..#04A800` (240 KB).
- spgbld bg padding = `0A8000 - 04A800 = 5C800` нулей. Они шли в `#04A800..#0A8000`, **затирая первые 8 KB atlas** (`#0A6000..#0A8000`) — это были последние пара cells, рендерились как пустые → flicker chain.
- Fix: bg грузится **первым**, atlas — вторым. Atlas pages пишут поверх bg-padding в `#0A6000+` свежими данными → atlas цел.

Универсальное правило для FT812-проектов: **порядок upload pages = обратный к RAM_G layout** (старший адрес последним), либо gap ≥16 KB между блоками.

---

## §M. Frog composition: HD-стиль pipeline (опыт 2026-05-09/10)

Композиция лягушки в Zuma-Deluxe (HD-версия `github.com/GalaxyShad/Zuma-Deluxe-HD`) — multi-sprite c rotation matrix. В VDAC2 реализуется через FT812 multiple BITMAP_HANDLE + matrix manipulation.

### M.1 Источники подспрайтов в `frog.png`

`frog.png` (324×648 RGBA) — sprite-sheet. Координаты 1:1 из `Zuma-Deluxe-HD/src/zuma/ResourceStore.c`:

| Sprite | crop (X,Y,W,H) | Назначение |
|---|---|---|
| `SPR_FROG` | (0, 0, 162, 162) | body (frog с открытым ртом) |
| `SPR_FROG_TONGUE` | (162, 0, 162, 162) | язык (накладывается над body) |
| `SPR_FROG_PLATE` | (162, 162, 162, 162) | круглый диск-подставка |
| `ANIM_FROG_BLINK[0..2]` | (0, 162N, 162, 162) | моргание (frames N=1,2,3) |
| `ANIM_FROG_BALLS` ×6 | (234, 633, 15, 15) горизонтальный strip | индикаторы цвета next-ball |

Resize 162→122 (LANCZOS) даёт scale ≈ 0.753. Соотношение body/ball = 122/40 ≈ 3.05 (HD соотношение 162/48 = 3.375; -10% — компромисс под 640×480).

### M.2 Render pipeline (Frog_Draw порядок)

Из HD `Frog.c`:
```c
Frog_Draw:
    DrawSprite(plate)                   // no rotation
    DrawSetAngle(angle - π/2)           
    DrawSprite(body)                    // rotated
    DrawSprite(tongue, pos + tongueExpand·dir)   // rotated
Frog_DrawTop:
    DrawSprite(currentBall, pos + ballExpand·dir)   // rotated
    DrawSetScale(1.5)
    DrawSprite(nextBallIndicator, pos - 40·dir)     // rotated
    DrawSprite(blinkAnim, pos)          // rotated
```

VDAC2 эквивалент в `Frog.asm`:
1. **`Frog_DrawPlate`** — handle 4, no matrix (обнулять matrix не нужно если предыдущий блок identity).
2. **`Frog_DrawBody`** — handle 2, matrix `T(61,61) · R(angle-64) · T(-61,-61)` (где 61 = sprite_W/2, -64 = -π/2 для native face=south).
3. **`Frog_DrawTongue`** — handle 5, та же matrix как body + offset Vertex2f на `tongueExpand·dir`. (на текущем этапе отключён до реализации recoil).

### M.3 Rotation matrix pattern (см. также §N.1)

```z80
Frog_DrawBody:
    CALL ZL_EmitLoadId
    LD HL, 61 : LD DE, 61 : CALL ZL_EmitTranslate    ; T(+61,+61)
    LD A, (Frog_Angle) : CALL ZL_EmitRotate          ; R(angle-64), -64 встроен в EmitRotate
    LD HL, -61 & 0xFFFF : LD DE, -61 & 0xFFFF
    CALL ZL_EmitTranslate                             ; T(-61,-61)
    CALL ZL_EmitSetMatrix                             ; emit BITMAP_TRANSFORM_A..F
    
    FT_BitmapHandle 2
    FT_BitmapSource FROG_RAMG_ADDR
    FT_BitmapLayout FT_ARGB4, 122*2, 122
    FT_BitmapSize FT_BILINEAR, FT_BORDER, FT_BORDER, 122, 122
    FT_Begin FT_BITMAPS
    LD BC, FROG_VTX_X : LD DE, FROG_VTX_Y : CALL FT.Coprocessor.Vertex2f
    FT_End
    
    ; reset → identity для последующих ops в DL
    CALL ZL_EmitLoadId : CALL ZL_EmitSetMatrix
    RET
```

`FROG_VTX_X = FROG_X*16 - 61*16` (subpixel top-left). `Frog_Angle` — raw BRAD 0..255 (0=east, 64=south, 128=west, 192=north). `ZL_EmitRotate` сам делает `ADD A, 192` (= -64) для коррекции native face direction.

**Ключевой урок:** matrix НЕ задаёт screen position (это делает Vertex2f), matrix трансформирует **UV-чтение** внутри bitmap-rect. T(+61,+61) переносит UV-origin в центр sprite, R(angle) вращает UV вокруг этого origin, T(-61,-61) возвращает; результат — rotated bitmap внутри своего фиксированного screen-rect.

### M.4 Atan2 от курсора → angle

Источник: `c:\z80\zuma\zuma_new_spg.asm:793 ComputeFrogAngle` (TS-Conf версия, скопирован 1:1 в `Frog.asm`). Алгоритм:

1. `dx = SmoothMouseX - FrogX`, `dy = SmoothMouseY - FrogY` (16-bit signed).
2. **Флаги октанта** (3 бита): `b0=dx<0`, `b1=dy<0`, `b2=swap` (если `|dy|>|dx|`).
3. **|dx|, |dy|** через CPL+INC. Swap так чтобы C = max, E = min.
4. **t = E*128 / C** (16-bit/8-bit deление). 128, не 32 — даёт 4× разрешение и плавность на диагоналях.
5. **Atan LUT[129]**: `atan(i/128) × 256/(2π)`, i=0..128, выход 0..32 BRAD.
6. **Mirror at 90°** если был swap: `A = 64 - A`.
7. **Apply квадрант** по флагам dx/dy: Q1 → A, Q2 → 128-A, Q3 → 128+A, Q4 → 256-A.

Возвращает BRAD 0..255: 0=east, 64=south, 128=west, 192=north.

### M.5 Hybrid follow для плавного rotation

Прямое присваивание `Frog_Angle = computed` даёт jitter при mouse-jitter (kempston через Hyper-V — особенно):
- Big diff (≥4 BRAD = >5.6°) → snap
- Small diff (1..3 BRAD) → ±1 BRAD/frame ramp
- Diff = 0 → no-op
- Deadzone: `max(|dx|,|dy|)<5` → не менять (курсор в frog-center)

Subjective результат: при медленном движении мыши лягушка плавно догоняет, при быстром — мгновенно прыгает. То же самое было в TS-Conf версии, проверено годами.

### M.6 Tongue bbox (для будущего расчёта tongueExpand)

Native tongue (162×162 region из frog.png):
- bbox непрозрачных пикселей: x=59..103, y=53..132 (45×80)
- centroid (81, 89), sprite center (81, 81)

Это значит native tongue: язык чуть выше центра sprite до низа. После resize 162→122 bbox переходит в y=40..99. Если рендерить tongue в той же position что и body, язык **физически выше центра body** (до y=40 после resize).

В HD `tongueExpand=24` (idle) сдвигает tongue по `dir·24` вниз по native-face=south — язык легализуется под подбородком body. На рендере в VDAC2 (где rotation atan2-driven) это значит:
```
tongueX = FROG_X + (24·cos_lut[Frog_Angle]) >> 4
tongueY = FROG_Y + (24·sin_lut[Frog_Angle]) >> 4
Vertex2f((tongueX-61)*16, (tongueY-61)*16)
```
+ та же matrix что и body. Реализуем когда дойдём до recoil/fire анимации.

---

## §R. RNG: LFSR Galois + bias + RTC-scramble (опыт 2026-05-10)

### R.1 LFSR Galois 16-bit

Базовый PRNG, периодом 65535 (на любом non-zero seed):
```z80
LFSR16:                          ; state в HL
    LD A, L : AND 1              ; LSB
    SRL H : RR L                 ; HL >>= 1
    JR Z, .no_xor                
    LD D, #B4 : LD E, 0          ; poly 0xB400 (CRC-16-IBM reverse)
    LD A, H : XOR D : LD H, A
    LD A, L : XOR E : LD L, A
.no_xor:
    RET                          ; HL = новое state
```
Альтернативные полиномы `#D008`, `#A005` — те же свойства period-65535.

### R.2 Bias-ловушка: `AND N + clamp` на не-степени двойки

Распространённая ошибка для распределения LFSR-output на N значений:
```z80
LD A, L
AND 7                ; 0..7
CP 6
JR C, .ok
SUB 6                ; 6→0, 7→1
.ok:
RET                  ; A в 0..5
```
**Проблема:** distribution неравномерное. Для NUM=6:
- Values 0, 1: вероятность 2/8 = **25% каждое**
- Values 2..5: вероятность 1/8 = **12.5% каждое**

Visible эффект: на экране **в 2 раза больше синих и красных шаров** (если color 0=blue, 1=red).

### R.3 Mul-then-shift: равномерное распределение

```z80
LD A, L : XOR H              ; смешать обе половины LFSR (8 бит entropy)
LD H, 0 : LD L, A
LD D, 0 : LD E, A
ADD HL, HL                   ; HL = A*2
ADD HL, DE                   ; HL = A*3
ADD HL, HL                   ; HL = A*6  (A * NUM_COLORS=6)
LD A, H                      ; A = (A*N) >> 8 → 0..N-1
RET
```
Distribution: 256/N не делится нацело → bias ≤1/N. Для N=6 максимальное отклонение `2 / 256 = 0.78%`.

Generic вариант для произвольного N:
```z80
LD E, N                      ; multiplier из RAM
LD HL, 0
LD B, 8
.loop:
    ADD HL, HL
    SLA A
    JR NC, .skip
    ADD HL, DE
.skip:
    DJNZ .loop
LD A, H                      ; (A * N) >> 8
RET
```

### R.4 RTC-scramble seed (для разнообразия per launch)

LFSR с фиксированным seed → одна и та же последовательность каждый запуск. Решение — scramble через TS-Conf RTC секунды:
```z80
ReadRTCSeconds:
    LD BC, #DFF7 : XOR A : OUT (C), A     ; reg 0 = seconds
    LD BC, #BFF7 : IN A, (C)              ; A = BCD seconds
    LD B, A
    AND $0F : LD C, A                     ; low nibble
    LD A, B : AND $F0
    SRL A : SRL A : SRL A : SRL A         ; high nibble
    LD B, A
    ADD A, A : ADD A, A : ADD A, B        ; *5
    ADD A, A                              ; *10
    ADD A, C                              ; +low → 0..59 binary
    RET

VDC_Init:
    LD HL, #ACE1 : LD (VDC_LfsrSeed), HL
    CALL ReadRTCSeconds
    OR A : JR NZ, .have : LD A, 17        ; защита если RTC=0
.have:
    LD D, A : LD E, A                     ; multiplier
    LD HL, (VDC_LfsrSeed) : LD A, L       ; A = low_byte(seed)
    LD HL, 0 : LD B, 8
.mul:                                      ; HL = low_byte * RTC_sec через 8x mult
    ADD HL, HL : SLA A : JR NC, .skip
    ADD HL, DE
.skip:
    DJNZ .mul
    LD A, H : OR L : JR NZ, .ok
    LD HL, #1234                           ; protection если результат=0
.ok:
    LD (VDC_LfsrSeed), HL
    RET
```
Каждая секунда (RTC ticks) = разный multiplier → разное seed → разная LFSR-цепочка цветов в каждом запуске.


## Глава 19. FT81x DL persistent state — Cell, BITMAP_HANDLE и ловушки наследования (2026-05-10)

После сборки полной HD-композиции лягушки (глава 18) проявился неприятный
интермиттент-баг: **«крышка» (face overlay) иногда исчезала на N кадров
после выстрела**. Видимое поведение — после fire ~75% случаев overlay
пропадает до следующего fire, ~25% случаев overlay виден.

### Что мы исключили (типичные кандидаты, оказавшиеся неверными)

1. **Координата overlay (recoil-сдвиг)** — `Frog_PosX/Y` смещаются на ±8 px
   во время recoil. Заменили вычисление overlay-вершины на `Frog_PosStartX/Y`
   (статика). Баг **остался** → координаты ни при чём.
2. **Cmd-buffer overflow** — буфер CMD_ADDRESS_PTR=#C000 на 16 КБ, фактически
   используется ~2.5 КБ за кадр. Не близко к лимиту.
3. **Coprocessor exception** — после exception coprocessor останавливается, всё
   что после игнорируется. Но overlay рендерится ПЕРЕД chain block, и chain
   рендерится корректно → coprocessor жив.
4. **DL пострадал** — снимок Z80 RAM (F12-dump) показал что DL для overlay
   полностью корректный: handle=6, source=#0B4000, ARGB4 244×122 BILINEAR,
   matrix valid, vertex (266, 170) внутри 640×480.
5. **Matrix corruption** — overlay использует **ту же matrix** что body
   (`T(61)·R(angle+192)·T(-61)`). Body не пропадает, overlay пропадает →
   matrix не виновата.
6. **RAM_G corruption** — overlay area #0B4000..#0BB740 не имеет writers
   после Initialize (никто туда не пишет). Layout правильный, padding
   tongue заканчивается ровно на #0B4000 (overlay start), не наезжает.

### Root cause — Cell как persistent DL state

Frog block рендерит спрайты в порядке:
```
plate     handle 4   Vertex2f  без Cell  → cell наследован
body      handle 2   Vertex2f  без Cell  → cell наследован
tongue    handle 5   Vertex2f  без Cell  → cell наследован
ball-now  handle 0   Cell(BallColor*8) + Vertex2f  → cell ставится
next-ball handle 0   Cell(NextBallColor*8) + Vertex2f → cell перезаписывается
overlay   handle 6   Vertex2f  без Cell  → cell НАСЛЕДОВАН от next-ball!
```

**Перед frog-блоком** идёт bg, который рендерится через `Vertex2ii(0, 0, 1, 0)`.
Vertex2ii — **специальная** компактная команда, которая включает в себя
**handle и cell прямо в опкоде** (поля 7 бит handle, 7 бит cell). Она ставит
DL state cell=0 как побочный эффект.

После bg DL state: **cell=0**. Killzone, plate, body, tongue читают этот cell=0.
Когда ball-now эмитит `Cell(BallColor*8)` — DL state cell меняется. Next-ball
аналогично. После next-ball cell = NextBallColor*8.

Overlay не эмитит Cell перед своим Vertex2f → **наследует cell от next-ball**.

Overlay = 122×122 ARGB4 stride 244 = 29768 байт = 1 cell в layout. FT81x вычисляет
адрес pixel-data:
```
addr = BITMAP_SOURCE + cell * cell_size_bytes
     = OVERLAY_RAMG_ADDR + cell * 29768
     = #0B4000 + cell * 0x7448
```

Для NextBallColor=1 → cell=8 → addr = #0B4000 + 8*29768 = **#EE200**. Это
**далеко за пределами реального overlay sprite** в RAM_G (overlay-data
заканчивается на #0BB740 < #EE200). Зона #EE200 — **не используется**, в RAM_G
там zeros. ARGB4 нулевые байты = alpha=0 для всех пикселей → **overlay
полностью прозрачный → невидим**.

Когда NextBallColor=0 (= 25% случаев в randomize 0..3) → cell=0 → читаем
правильный overlay из #0B4000 → виден. Отсюда **интермиттент**.

### Fix

```z80
Frog_DrawFaceOverlay:
                  ; ... matrix setup ...
                  FT_BitmapHandle 6
                  FT_BitmapSource OVERLAY_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  FT_Begin FT_BITMAPS
                  XOR  A
                  CALL FT.Coprocessor.Cell      ; <-- сброс cell в 0
                  CALL Frog_EmitVertex2f_PosCentered
                  FT_End
                  ...
```

`FT.Coprocessor.Cell` = TSLib helper, эмитит DL command `0x06000000 | (cell & 0x7F)`.

### Универсальное правило: какой DL state в FT81x persists

| Команда                | Persists | Scope       |
|------------------------|----------|-------------|
| BITMAP_HANDLE          | да       | global      |
| BITMAP_SOURCE          | да       | per-handle  |
| BITMAP_LAYOUT/SIZE     | да       | per-handle  |
| BITMAP_TRANSFORM_A..F  | да       | global      |
| **CELL**               | **да**   | **global**  |
| COLOR_RGB              | да       | global      |
| COLOR_A                | да       | global      |
| BLEND_FUNC             | да       | global      |
| LINE_WIDTH             | да       | global      |
| POINT_SIZE             | да       | global      |
| SCISSOR_XY/SIZE        | да       | global      |

Practical rule: **любой Vertex2f, идущий после atlas-блока (где Cell≠0 был
эмитен), должен явно эмитить нужный Cell** (даже Cell(0) для single-cell
sprite). Не полагайся на наследование = 0 by default.

### Методология поиска

Ловушка для одиночного отладчика — баг локализован в DL pipeline state, который
**не виден в дампе Z80 RAM** (DL state живёт в FT81x регистрах). Дамп показывал
все правильные команды; вычислить наследование Cell можно только мысленным
прохождением DL.

**Diagnostic A** (изолировать координату): заменить Vertex источник на статику
(Pos→PosStart). Баг не ушёл → не координаты.

**Главная подсказка** пришла от пользователя: «чем крышка отличается от
остальных слоёв спрайта» — заставило сесть и **последовательно сравнить**
overlay с другими frog-спрайтами по всем атрибутам. Различие в **позиции
в DL pipeline относительно atlas-блока** (overlay = единственный single-cell
sprite ПОСЛЕ atlas-блока) и привело к Cell.

Похожие ловушки могут возникнуть с **любым** persistent DL state. При добавлении
новых sprite в frame — пройти по всем persistent settings и проверить, что
текущий sprite их не наследует случайно (или явно ресетит).


## Глава 20. Vsync-first sync: race между Z80 build и FT812 render (2026-05-10)

После сборки полного gameplay loop (chain physics + bullet + match-3) на реальном
железе ZX-Evo + FT812 проявился класс артефактов: «цветной мусор / линии посередине
экрана при ≥30 шарах в цепи». На эмуляторе Unreal x64 артефакт **минимален или
отсутствует**. На железе — линейно нарастает с числом шаров и **усиливается при
движении мыши**.

### Гипотезы и проверка

**Гипотеза 1 — RAM_CMD overflow (4 KB ring).**
Решение TSLib `FT.Coprocessor.Write` уже опрашивает `REG_CMDB_SPACE` перед каждой
SPI-записью и ждёт пока coprocessor освободит место. **Overflow невозможен** через
TSLib API. Гипотеза отклонена.

**Гипотеза 2 — RAM_DL overflow (8K commands = 32 KB).**
Подсчёт DL команд на кадр: bg ~24 + killzone ~14 + frog 6 спрайтов с matrix
~75 + chain N шаров × 8 + cursor ~14 + bullet 1 × 8 ≈ 149 + 8N.
При 60 шарах ≈ 629 DL — **далеко от 8192 лимита**. Подтверждено визуально через
красную полоску внизу экрана (диагностика, потом убрана). Отклонено.

**Гипотеза 3 — `cmd_swap` через CMD-FIFO вместо `REG_DLSWAP`.**
По FT81x документации `cmd_swap` = «coprocessor сам выполнит swap когда DL
готов». Заменили manual `REG_DLSWAP=FRAME` на `FT_CMD_Swap`. **Программа
зависла** (deadlock в CMD-FIFO). Откат, гипотеза отклонена.

**Гипотеза 4 — vsync-first sync (HighLander).**
Кадровый sync с FT812 vsync **перед** SPI write. Идея: write попадает в vblank
window, не накладывается на render. На железе **частично помогло** — артефакт
исчез при стационарной мыши, остался при mouse motion.

**Корень оставшегося артефакта**: тяжёлый build при mouse motion.
`ZL_AimUpdate` детектит motion → `Frog_ComputeAngle` запускается с atan2 LUT[129] +
hybrid follow + 8-octant logic = десятки сложений/делений. Build удлиняется,
SPI write **выходит за vblank window** в render time → race с FT812 RAM_DL read.

### Решение — parallel build + vsync-first write

Перестраиваем main loop:

```z80
.Loop           ; --- 1. Input + game state + Build DL в Z80 buffer ---
                ; ВЫПОЛНЯЕТСЯ ПАРАЛЛЕЛЬНО с FT812 рендером prev frame.
                CALL Input.Mouse.UpdateMouseState
                CALL ZL_AimUpdate                  ; mouse/keyboard → Frog_Angle
                CALL ZL_SmoothMouse
                CALL Frog_Update                   ; ComputeFrogAngle + recoil
                CALL VDC_Update
                CALL Bullet_Update
                CALL Bullet_CheckCollision
                FT_CMD_Start                       ; reset Z80 buffer ptr
                FT_DL_Start                        ; cmd_dlstart
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x102030
                FT_ClearAll
                CALL ZL_DrawFrame                  ; bg + frog + chain + cursor + bullet
                FT_Display

                ; --- 2. Sync с FT812 vsync ПОСЛЕ build ---
.WaitIntSync    FT_RD_REG8 FT_REG_INT_FLAGS
                AND  FT_INT_SWAP
                JR   Z, .WaitIntSync
.WaitDLSwap     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .WaitDLSwap

                ; --- 3. Burst write Z80 buffer → FT812 RAM_CMD (в vblank window) ---
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                JP .Loop
```

Ключевое отличие от предыдущей схемы: **wait FT INT_SWAP** перенесён **в середину
loop**, между build и write. Z80 cycles на input + game state + DL build идут
**в параллель** с тем, что FT812 рендерит предыдущий кадр. Когда Z80 готов —
ждёт vsync, затем SPI burst попадает строго в vblank.

### Почему это работает

| Pipeline                     | Build location  | Write location       | Race                |
|------------------------------|-----------------|----------------------|---------------------|
| Старая (wait в начале)       | После vblank    | В render time        | Mouse motion → race |
| HighLander (wait в начале v2)| После vblank    | В render time        | Mouse motion → race |
| **Parallel + vsync write**   | Параллельно с render | **Vblank window** | Нет                  |

При mouse motion build занимает ~3-5 ms (atan2 в `ZL_KbdAimUpdate` + matrix
calc для frog). FT812 render @ 57Hz занимает ~15.5 ms из 17.5 ms кадра, vblank
~2 ms. В старой схеме build ел кусок vblank → write попадал в render. В новой —
build делается в render time, write строго в vblank.

### Урок (универсальный)

**Sync на vsync должен быть ПЕРЕД сторонним I/O write, не ПОСЛЕ.** Z80-only
работа (input read из port, game state update в RAM, DL build в Z80 buffer) НЕ
трогает FT812 → может идти в любое время, в т.ч. параллельно с render.

Только I/O в FT812 (`FT_CMD_Write`, `FT_WR_REG`) требует vblank window. Поэтому
правильный sync = «build в любое время, sync прямо перед I/O burst».

### Открытое (TODO для следующей итерации)

- Подтверждение fix mouse-motion artifact на железе. Текущая версия —
  кандидат на полный fix.
- Hemisphere insert (target = i vs i+1 по ближайшему neighbour).


## Глава 21. DXT1-эмуляция на FT812: компрессия фона до 0.5 байт/пикс через L2-mask + RGB565 blend (2026-05-12)

### Задача

Фон уровня 640×480 в нативном RGB565 занимает **614 400 байт** в RAM_G FT812 —
60% от всего 1 МБ. Для multi-level игры (22 уровня Zuma Deluxe) это неприемлемо:
22 × 614 400 = 13.5 МБ — нужен какой-то стриминг или сжатие.

Раньше использовали трюк «400×300 RGB565 + cmd_scale(1.6) NEAREST до 640×480»:
240 000 байт, но качество ступенчатое (см. `reference_zuma_vdac2_bg_compression.md`).
Хочется честные 640×480 при минимальном объёме.

**Block-compressed форматы (DXT, ETC, ASTC) FT812 не поддерживает hardware'но.**
Список `BITMAP_LAYOUT.format` (FT81X PG Table 7): только ARGB1555, L1/L2/L4/L8,
RGB332, ARGB2/4, RGB565, TEXT8X8, TEXTVGA, BARGRAPH, PALETTED565/4444/8. Никаких
DXT/S3TC. `BITMAP_EXT_FORMAT` (под ASTC) появился только с BT815/816.

### Идея

DXT1 кодирует 4×4 пиксельный блок 8 байтами:
- 2 байта c0 endpoint (RGB565)
- 2 байта c1 endpoint (RGB565)
- 4 байта = 16 × 2-битных индексов выбора цвета

Декодирование на лету: для каждого пикселя индекс 0..3 определяет цвет:
- `0` → `c0`
- `1` → `c1`
- `2` → `(2·c0 + c1) / 3` (≈ ⅔c0 + ⅓c1)
- `3` → `(c0 + 2·c1) / 3` (≈ ⅓c0 + ⅔c1)

FT812 умеет каждый из этих кусков по-отдельности:
- **c0 и c1 endpoint цвета** = два RGB565 цвета на блок 4×4 = массив `(W/4)×(H/4)` RGB565
- **Индекс выбора** = 2 бита на пиксель = формат `FT_L2` `W×H`
- **Интерполяция между c0 и c1** через индекс → реализуется аппаратным **alpha-blending'ом**:
  L2 пишет alpha канал, c0/c1 рисуются с `DST_ALPHA` / `ONE_MINUS_DST_ALPHA` blend

Это классический трюк из EVE Application Note **AN_340** (DXT1 emulation,
Bridgetek). Конвертер `ft812_dxt_convert.py` (автор — Lina, TSL community)
раскладывает обычный DXT1 в нужный layout.

### Формат raw файла

```
+------------------+ offset 0
|   c0 plane       |  RGB565, (W/4) × (H/4)
|   38400 bytes    |  для 640×480 → 160 × 120 cells × 2 байта
+------------------+ offset 38400
|   c1 plane       |  RGB565, (W/4) × (H/4)
|   38400 bytes    |
+------------------+ offset 76800
|   L2 mask        |  2 бит/пикс, W × H
|   76800 bytes    |  для 640×480 → 640 × 480 / 4 = 76800
+------------------+ offset 153600
```

**Всего: 153 600 байт для 640×480** ровно 0.5 байт/пикс — теоретический минимум
среди форматов FT812 (PALETTED8 = 1 байт/пикс минимум). Экономия **75%** vs raw
RGB565.

### L2 alpha mapping (нелинейный)

Эмпирически FT812 декодирует 2-битный raw L2 в 8-битную alpha по таблице
`(0, 255, 85, 170)` для (raw 0, 1, 2, 3). **Не линейно** — `raw=1 → alpha=255`,
а не `85`.

```python
L2_ALPHAS = (0, 255, 85, 170)
```

Конвертер использует эту таблицу при выборе selector-ов так, чтобы итоговый
композит после blend = `c0 * (1-A/255) + c1 * A/255` давал:

| sel | alpha | финальный цвет     | смысл DXT1   |
|-----|-------|--------------------|--------------|
| 0   | 0     | c0                 | endpoint c0  |
| 1   | 255   | c1                 | endpoint c1  |
| 2   | 85    | ⅔c0 + ⅓c1          | интерполяция |
| 3   | 170   | ⅓c0 + ⅔c1          | интерполяция |

Это **точно** DXT1 декомпрессия, без потерь относительно стандартного DXT1.

### Display List — 3 прохода

```asm
        FT_CMD_BUF (ZL_DL_SAVE_CONTEXT)
        CALL  ZL_EmitLoadId
        CALL  ZL_EmitSetMatrix

        ; handle 1: RGB565 color cells (cell 0=c0, cell 1=c1)
        FT_BitmapHandle 1
        FT_BitmapSource ZL_BG_COLOR_ADDR
        FT_BitmapLayout FT_RGB565, ZL_BG_COLOR_STRIDE, ZL_BG_BLOCK_H
        FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BG_W, ZL_BG_H

        ; handle 8: L2 mask на full resolution
        FT_BitmapHandle ZL_BG_L2_HANDLE
        FT_BitmapSource ZL_BG_L2_ADDR
        FT_BitmapLayout ZL_FT_L2, ZL_BG_L2_STRIDE, ZL_BG_H
        FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BG_W, ZL_BG_H

        FT_Begin FT_BITMAPS

        ;--- Pass 1: L2 → alpha канал dst.A ---
        FT_CMD_BUF (ZL_DL_COLOR_MASK | ZL_COLOR_MASK_A)         ; только A
        FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_ONE << 3) | ZL_BLEND_ZERO)
        FT_CMD_BUF (ZL_DL_COLOR_A | 255)
        FT_Vertex2ii 0, 0, ZL_BG_L2_HANDLE, 0

        ;--- готовимся к color planes ---
        FT_CMD_BUF (ZL_DL_COLOR_MASK | ZL_COLOR_MASK_RGB)       ; только RGB
        CALL  ZL_EmitLoadId
        FT_CMD_BUF FT_CMD_SCALE
        FT_CMD_BUF #00040000                  ; sx = 4.0
        FT_CMD_BUF #00040000                  ; sy = 4.0
        CALL  ZL_EmitSetMatrix

        ;--- Pass 2: c1 plane с DST_ALPHA blend ---
        FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_DST_ALPHA << 3) | ZL_BLEND_ZERO)
        FT_Vertex2ii 0, 0, 1, 1               ; cell 1 = c1, out = c1 * A

        ;--- Pass 3: c0 plane с ONE_MINUS_DST_ALPHA сверху ---
        FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_ONE_MINUS_DST_ALPHA << 3) | ZL_BLEND_ONE)
        FT_Vertex2ii 0, 0, 1, 0               ; cell 0 = c0, out = c0*(1-A) + dst

        FT_End
        FT_CMD_BUF (ZL_DL_RESTORE_CONTEXT)
```

Математика итогового пикселя:
```
после pass1: dst.A = L2_ALPHAS[selector] (∈ {0, 255, 85, 170})
после pass2: dst.RGB = c1 * dst.A / 255
после pass3: dst.RGB = c0 * (1 - dst.A/255) + dst.RGB * 1
           = c0 * (1 - A/255) + c1 * (A/255)
```

### Подводные камни (на отладку ушёл вечер)

#### 1. sjasmplus parsing macro-аргументов с `|`

В `--syntax=ab` запись `FT_CMD_BUF ZL_DL_COLOR_MASK | 15` парсится криво —
в макрос приходит **только первый operand** (`ZL_DL_COLOR_MASK` = `#20000000`),
а `| 15` пропадает.

Результат: COLOR_MASK эмитится с битами `0000` (всё запрещено к записи), все
последующие draw-ы становятся no-op-ами, экран = clear color.

**Лечение:** ВСЕГДА оборачивать в скобки.
```asm
FT_CMD_BUF (ZL_DL_COLOR_MASK | 15)        ; правильно
FT_ColorMask 1, 1, 1, 1                    ; или штатный TSLib-макрос
```

#### 2. `FT_BitmapSize` уже эмитит BITMAP_SIZE_H

```asm
FT_BitmapSize macro Filter?, WrapX?, WrapY?, Width?, Height?
    FT_CMD_BUF ((0x29 << 24) | ((W>>9)<<2) | (H>>9))    ; BITMAP_SIZE_H
    FT_CMD_BUF ((0x08 << 24) | ... | (W & 511) | ...)   ; BITMAP_SIZE
endm
```

Передаём 640/480 **напрямую** в макрос. Если попытаться вручную предварительно
эмитить `FT_CMD_BUF (ZL_DL_BITMAP_SIZE_H | hi)` + потом `FT_BitmapSize` с
младшими `W_LO, H_LO` — макрос **затирает** ручной SIZE_H своим (с нулевыми
hi-битами, потому что W_LO=128, H_LO=480 укладываются в 9 бит). Высокие биты
теряются → BITMAP_SIZE становится 128×480, draws обрезаются.

Также `FT_BitmapLayout` сам эмитит `BITMAP_LAYOUT_H` для linestride > 1023 /
height > 511.

#### 3. BITMAP_SIZE = screen extent, не source

Для c0/c1 cells источник 160×120 + `cmd_scale(4,4)` → screen draws 640×480.
`FT_BitmapSize` должен быть **640×480** (final screen extent после matrix),
не source 160×120. Иначе draws обрезаются до 160×120 в верхнем-левом углу.

L2 plane (handle 8) — source уже 640×480 нативно, scale identity → BITMAP_SIZE
тоже 640×480.

#### 4. Vertex2ii max 511×511

`VERTEX2II` имеет 9-битные поля координат (max 511). Для рисования full-screen
640×480 надо использовать `Vertex2f` с `VertexFormat` 0 (1 px) или 4 (1/16 px).

В нашем случае все draws начинаются с (0,0), поэтому Vertex2ii ОК — позиция
ноль помещается, а размер контролируется через BITMAP_SIZE.

### Сравнение объёмов 640×480

| Формат                                    | Байт      | vs DXT1-эмул |
|-------------------------------------------|-----------|--------------|
| Raw RGB565                                | 614 400   | 4.0×         |
| ARGB4                                     | 614 400   | 4.0×         |
| 400×300 RGB565 + scale 1.6 (старый bg)    | 240 000   | 1.56×        |
| **DXT1-эмуляция (c0+c1+L2)**              | **153 600** | **1.0×**   |
| 320×240 RGB565 + scale 2.0                | 153 600   | 1.0× (мыло)  |
| PALETTED8                                 | 308 224   | 2.0×         |
| L8 (grayscale)                            | 307 200   | 2.0×         |

### Когда использовать

OK Фотореалистичный фон (level background, splash screen)
OK Текстуры с плавными цветовыми переходами
OK Когда RAM_G сильно ограничен (multi-level игра)

NOT Спрайты с резкими краями и небольшим количеством цветов — артефакты на
   границах (DXT1 теряет alpha, плохо ловит тонкие линии). Для шаров/frog
   эффективнее ARGB4.
NOT Текст и UI — здесь DXT1 даёт «лесенки» из-за грубых endpoint цветов.

### Конвертер ft812_dxt_convert.py

Опции качества (effort `-e 0..10`):
- `-e 0` — быстро, шумный (видны блоки 4×4 на градиентах)
- `-e 3` — почти неотличим от оригинала (рекомендация Lina)
- `-e 6+` — perceptual weights + seam smoothing + residual diffusion, медленно

Базовый запуск:
```
python ft812_dxt_convert.py level01.png -o out/level01 -f l2 -t raw -e 3 -p
```

Выход:
- `out/level01_l2.raw` — 153 600 байт raw в формате c0|c1|L2 (грузим в RAM_G как есть)
- `out/level01_l2.h` — C-заголовок с offset-ами/strides (для интеграции)
- `out/level01_l2_preview.png` — реконструкция (для визуальной оценки качества)

### Multi-level в Zuma — что меняется

22 уровня × 153 600 = 3.4 МБ DXT1-эмуляции vs 13.5 МБ raw RGB565. Сейчас один
уровень упаковывается в 10 spgbld-страниц по 16 КБ. При переключении уровней
upload bg = ~150 КБ через SPI ≈ 70 мс на 14 МГц Z80 (вполне допустимая пауза
при level transition).

Объёмы по сравнению с zlib (`cmd_inflate` план):
- DXT1-эмуляция: 153 КБ uncompressed, ~70 мс upload, hardware decode
- ZX0/zlib: ~100 КБ compressed → ~150 КБ uncompressed, ~120 мс upload + decode

DXT1-эмуляция выигрывает по uncompressed size (тот же объём в SPI transfer),
проще в реализации (нет decode-кода), и качество фотореалистичных фонов
визуально приемлемое начиная с `-e 3`.

### Источники

- **EVE Application Note AN_340** (Bridgetek, "Compressing texture using DXT1 with EVE2/EVE3 chipsets") — оригинальная идея трюка.
- `ft812_dxt_convert.py` — реализация конвертера, автор Lina (TSL community).
- `reference_zuma_vdac2_dxt1_emulation_l2_blend.md` — компактная памятка по технике.
- `feedback_sjasmplus_macro_or_parens.md` — про скобки в FT_CMD_BUF.

## Глава 22. Апгрейд DXT1-эмуляции с L2 до L4: +50% SPI за фотокачество (2026-05-12)

### Зачем понадобился L4

Глава 21 описала DXT1 на L2-маске: 0.5 байт/пикс, 153 600 байт на 640×480.
Объёмно идеально, но на каменной текстуре фона `level_src_01` оставалась
заметная **блочность 4×4**.

Корень: L2-маска даёт всего **4 уровня** между endpoints (`{0, 85, 170, 255}` →
четыре цвета: c0, ⅔c0+⅓c1, ⅓c0+⅔c1, c1). На гладких градиентах внутри блока
8 уникальных оттенков в исходнике вынуждены коллапсировать в 4 → видна
ступенька в каждом блоке.

Чтобы оценить «насколько лучше» — переходим на L4:
- **16 уровней** маски (линейный ramp `0..255` шагом 17)
- 4×4 блок цветов c0/c1 тот же, размер endpoint planes не меняется
- **mask** 4bpp вместо 2bpp → +76 800 байт (76800 → 153600)
- Итого raw: **230 400 байт** vs 153 600 = +50%

Пиксельный «бюджет фона» 200 КБ был принятой границей бюджета SPI/RAM_G.
230 КБ — чуть выше потолка, но bg уже **по-настоящему фотореалистичен**.

### Сравнение L2 vs L4 в одном блоке

```
оригинал блока 4×4:          цвета на пиксель
+---+---+---+---+
| A | A | B | B |            A   = (200, 90,  60)
| A | A | B | B |            B   = (210, 130, 80)
| C | C | D | D |            C   = (180, 100, 70)
| C | C | D | D |            D   = (170, 110, 90)
+---+---+---+---+

L2 (4 уровня):                L4 (16 уровней):
endpoints: c0=A, c1=D         endpoints: c0=A, c1=D
selectors per pixel:          selectors per pixel:
  A→0  B→2 (⅔A+⅓D)             A→0   B→5  (a~85)
  C→3 (⅓A+⅔D)  D→1              C→10 (a~170)  D→15
ошибка перекраски:            ошибка перекраски:
  B → ⅔A+⅓D отличается от B     B → a*A+(1-a)*D с лучше подбираемым α
  → видимый шов между блоками  → плавная интерполяция, шов невидим
```

### Что меняется в raw layout

Только размер маски и её stride:

```
+------------------+ offset 0
|   c0 plane       |  RGB565, (W/4) × (H/4)
|   38400 bytes    |  для 640×480 → 160 × 120 cells × 2 байта
+------------------+ offset 38400
|   c1 plane       |  RGB565, (W/4) × (H/4)
|   38400 bytes    |
+------------------+ offset 76800
|   L4 mask        |  4 бит/пикс, W × H  (вместо 2 бит/пикс)
|   153600 bytes   |  для 640×480 → 640 × 480 / 2 = 153600  ← х2 от L2
+------------------+ offset 230400
```

### Изменения в asm (минимально)

#### main.asm: 10 → 15 spgbld pages

```asm
BG_FIRST_PAGE      EQU 7
; было:
; BG_PAGE_COUNT    EQU 10                ; DXT1-decomp 640×480 (c0|c1|L2 = 153600)
; стало:
BG_PAGE_COUNT      EQU 15                ; DXT1_L4 640×480 (c0|c1|L4 = 230400, last padded)
```

RAM_G layout не меняется: BG занимает `#010000..#04C000` = 245 760 байт
(230400 реальных + 15 360 padding из последней spgbld-страницы). Killzone
сидит ровно на `#04C000` — без overlap.

#### MainLoop.asm: формат маски и stride

```asm
; было:
; ZL_BG_L2_STRIDE EQU ZL_BG_W / 4                ; FT_L2 = 2bpp → 4 пикс/байт
; ZL_FT_L2        EQU 17                         ; format code FT_L2

; стало:
ZL_BG_L2_STRIDE EQU ZL_BG_W / 2                  ; FT_L4 = 4bpp → 2 пикс/байт
ZL_FT_L2        EQU FT_L4                        ; format code FT_L4 (=2)
```

`FT_L4` = 2, `FT_L2` = 17 — две разные ячейки в `BITMAP_LAYOUT.format`
(см. FT81x PG §4.7.7, Table 7). Stride для 4bpp = `(W+1)/2`.

#### DL pipeline — без изменений

```asm
;--- Pass 1: маска → dst.A через ONE/ZERO blend ---
FT_CMD_BUF (ZL_DL_COLOR_MASK | ZL_COLOR_MASK_A)
FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_ONE << 3) | ZL_BLEND_ZERO)
FT_CMD_BUF (ZL_DL_COLOR_A | 255)
FT_Vertex2ii 0, 0, ZL_BG_L2_HANDLE, 0          ; теперь L4 mask

;--- Pass 2/3: c1/c0 с DST_ALPHA blend — те же команды ---
```

L4 декодируется FT812 в **линейный** 8-битный alpha: `raw_value × 17`
(значения 0, 17, 34, ..., 255). В отличие от L2 (`{0, 255, 85, 170}`), L4
без перестановок — selector `k` даёт alpha ≈ `k/15 * 255`. Конвертер
автоматически использует правильное соответствие.

Финальный blend `dst.RGB = c0*(1-A) + c1*A` алгебраически одинаков —
просто `A` теперь имеет 16 значений вместо 4.

### Подводный камень: CPU энкодер на Windows нежизнеспособен

Для 640×480 = 19 200 блоков 4×4. Локальный энкодер (без GPU):

| Режим                       | Результат                                     |
|-----------------------------|-----------------------------------------------|
| `-j 0` (auto = 6 cores)     | **BrokenProcessPool** (OOM при effort 8 / L4) |
| `-j 1` (single-process)     | ~3 мин до 2% при effort 4 → ~2.5 часа total   |
| `-j 2` effort 6             | ~2 мин до 0%, не дождались                    |

Multiprocessing у `concurrent.futures.ProcessPoolExecutor` на Windows
**не shared memory**: каждый воркер получает копию `blocks` через pickle.
Для 230 КБ blocks × 6 воркеров = 1.4 МБ × Python overhead ~50× = ~70 МБ
накапливается; через несколько итераций OOM на 4 ГБ VM.

Single-process работает стабильно, но 19 200 блоков × ~0.5 сек/блок (effort 4
с perceptual weights) = 160 мин. Эта длительность была подтверждена
эмпирически на CPU `2 × Xeon Gold 6132` под Hyper-V.

**Решение: запускать энкодер на хост-машине с GPU через pyopencl.**

```
python ft812_dxt_convert.py level_src_01.png -o out -f l4 -t raw -x -p -e 8
```

На AMD `gfx1032` весь pipeline (initial pair generation + hybrid refine + write)
проходит **менее чем за 30 секунд** на effort 8. Готовые файлы
(`out/level_src_01_l4.raw` 230 400 байт) копируются в проект, режутся на
страницы, собираются.

### Сплит в spgbld pages

```python
# split_l4.py
PAGE = 16384
data = open('level_src_01_l4.raw', 'rb').read()
assert len(data) == 230400
n_pages = (len(data) + PAGE - 1) // PAGE     # = 15
for i in range(n_pages):
    chunk = data[i*PAGE:(i+1)*PAGE]
    if len(chunk) < PAGE:
        chunk += b'\x00' * (PAGE - len(chunk))   # padding zeros
    open(f'bg_l4_p{i:02d}.bin', 'wb').write(chunk)
# wrote 15 файлов, последний с 1024 реальных байт + 15360 нулей
```

`spgbld_vdac2.ini`:

```ini
Block = #0000, #07, bg_l4_p00.bin
Block = #0000, #08, bg_l4_p01.bin
...
Block = #0000, #15, bg_l4_p14.bin
Block = #0000, #16, killzone_p00.bin     ; следом, без overlap
```

### Итоговый бюджет

| Формат                                | Байт      | vs Raw  | Качество        |
|---------------------------------------|-----------|---------|-----------------|
| Raw RGB565 640×480                    | 614 400   | 1.00×   | reference       |
| 400×300 RGB565 + scale 1.6 NEAREST    | 240 000   | 0.39×   | ступенька 1.6×  |
| DXT1_L2 (Глава 21)                    | 153 600   | 0.25×   | блочность 4×4   |
| **DXT1_L4 (эта глава)**               | **230 400** | **0.38×** | **фоторовно** |
| ARGB4 native 640×480                  | 614 400   | 1.00×   | reference       |

L4 даёт **2/3 объёма** native RGB565 при визуально неотличимом качестве —
ровно та точка цена/качество, которая нужна для multi-level Zuma:
22 × 230 КБ = 5 МБ vs 13.5 МБ raw. Помещается в обычный TR-DOS + spgbld.

### Когда выбирать L2 vs L4

- **L2**: tile-фон, splash-screen с большими flat-зонами, ограниченный RAM_G.
  Если 75% экономии важнее минимальной блочности — берём L2.
- **L4**: фотореалистичные уровни, фоны с плавными градиентами (наш случай),
  splash-screen с тонкой деталировкой. +50% к L2, но качество скачком вверх.

### Источники

- `ft812_dxt_convert.py` — light версия (1197 строк) после автора;
  hybrid GPU/CPU pipeline через pyopencl + numpy.
- `reference_zuma_vdac2_baseline_2026-05-12_bg_dxt_l4.md` — опорный baseline
  после интеграции.
- FT81x PG §4.7.7 — таблица `BITMAP_LAYOUT.format` (FT_L1/L2/L4/L8 codes).

## Глава 23. Render-loop оптимизации и DL-emit ловушки (2026-05-17)

Главы 18-22 закрыли визуальную часть Zuma. Эта глава — три приёма, которые
выжали из FT812 ещё несколько процентов и закрыли тонкий баг рендера.
Появились в процессе финального полировок kill-zone (плавное поглощение
шаров) и frog-композиции.

### 23.1 Bucket-grouped tangent rotation: 32 cmd_rotate → 16, а потом обратно

VDC выдаёт каждому шару в цепи `tangent` 0..255 — направление трека в точке.
HD-источник вращает каждый шар своим `cmd_rotate(angle)`, но на FT812 это
N call'ов `cmd_loadidentity → cmd_translate → cmd_rotate → cmd_translate
→ cmd_setmatrix` на каждый шар. При длине цепи 85 шаров это ~30% бюджета DL.

**Bucket-grouping** — группировка шаров по углу:

1. Pre-pass: для каждого шара вычисляем `bucket = (tangent + N/2) >> log2(N)`
   и кешируем (bucket, cell, Vx, Vy) в RAM.
2. Outer loop по N бакетам: emit matrix для `bucket * (256/N)`,
   inner scan — все шары с этим bucket'ом → Cell + Vertex2f.

При N=32: шаг 11.25° (256/32 = 8 BRAD = 11.25°). Шар получит
visually-acceptable rotation, плюс цены matrix-emit'а только 32 раза за кадр.

```asm
; 32-bucket scheme: bucket = (tangent+4) >> 3
LD   A, (VDC_LastTangent)
ADD  A, 4                              ; round-nearest
RRCA : RRCA : RRCA                    ; >> 3
AND  31                                ; mod 32
LD   (cache_bucket), A
; ...позже, в outer loop:
LD   A, (current_bucket)
ADD  A, A : ADD A, A : ADD A, A        ; bucket * 8
CALL ZL_EmitRotate                     ; A = BRAD 0..255
```

**Lesson: 16 vs 32**. Изначально 32 бакета считались избыточными — попробовали
16 (шаг 22.5°). На статичных шарах выглядело норм, но на быстро двигающихся
по крутой кривой (вход в killzone, головной шар) проявился **визуальный
jitter** — глаз ловит ступеньки. Откатили обратно в 32. Урок: не оптимизируй
"на глаз" в статике; смотри на самые быстрые моменты gameplay.

### 23.2 Per-sprite alpha fade через COLOR_A — плавное поглощение

FT812 имеет команду `COLOR_A(alpha)` — умножает alpha-канал последующего
bitmap'а на 0..255. Это позволяет делать **dissolve-эффект на спрайте без
изменения текстуры**.

В нашем случае: head-шар цепи во время Game Over absorb должен плавно
исчезать в kill-zone, а не пропадать дискретно. Алгоритм:

```asm
; Каждый тик absorb (state=1):
LD   A, (VDC_HSub)             ; HSub 0..31 in cell
ADD  A, A : ADD A, A : ADD A, A  ; * 8 (max 31*8 = 248)
CPL                              ; alpha = 255 - HSub*8
LD   (VDC_HeadAbsorbAlpha), A   ; смыкается с 255 до 7 за цикл

; В .BInner bucket-loop, перед Vertex2f head-шара:
LD   A, (VDC_HeadAbsorbAlpha)
LD   E, A
CALL FT.Coprocessor.ColorA      ; emit COLOR_A(alpha)
LD   C, (IX+2) : LD B, (IX+3)   ; перезагрузить BC (Cell/ColorA уничтожили)
LD   E, (IX+4) : LD D, (IX+5)
CALL FT.Coprocessor.Vertex2f
LD   E, 255
CALL FT.Coprocessor.ColorA      ; восстановить для остальных шаров
```

Ловушка: COLOR_A — **persistent state DL**. Если не восстановить до 255, все
последующие спрайты в этом кадре будут полупрозрачные.

**Identify the target sprite**: head-шар = первая запись в кеше bucket-prepass
по адресу `ZL_BALL_CACHE_ADDR`. В .BInner проверяем `IX == ZL_BALL_CACHE_ADDR`
(PUSH IX / POP HL / CP HIGH / CP LOW) — это slot[0]. COLOR_A применяется только
к этому одному `Vertex2f`.

### 23.3 Cell/ColorA корраптят BC/DE — координаты грузить ПОСЛЕ, а не ДО

Все одноаргументные DL-команды TSLib (`Cell`, `ColorA`, `Tag`, `LineWidth`...)
эмитятся через `Command_BCDE` — формируют 4 байта опкода в BC/DE и пишут в
буфер. **После такого CALL'а BC и DE мусор.**

Из этого следует жёсткое правило для пары Cell+Vertex2f:

```asm
; WRONG — баг, который у нас прятался месяц в DrawKillzoneDual:
LD   BC, x_scaled              ; BC = X
LD   DE, y_scaled              ; DE = Y
XOR  A
CALL FT.Coprocessor.Cell        ; BC, DE corrupted!
CALL FT.Coprocessor.Vertex2f    ; uses corrupted BC, DE → sprite в ?,?

; RIGHT — Cell первым, координаты после:
XOR  A
CALL FT.Coprocessor.Cell
LD   BC, x_scaled
LD   DE, y_scaled
CALL FT.Coprocessor.Vertex2f
```

Bug-symptom при wrong ordering: спрайт рисуется в верхнем-левом углу или вообще
не виден — Cell оставляет в BC значение `0x0600` (опкод Cell), Vertex2f
интерпретирует это как X*16 = 1536, что выходит за разумный экранный диапазон,
либо clip.

**Эвристика**: если sprite появляется не там где ожидаешь, или мигает, или
"то ли есть, то ли нет" — **первое что проверить**: между LD BC,coords и
Vertex2f нет ли промежуточного CALL'а к Cell/ColorA/Tag/etc. Если есть —
переставить порядок.

### 23.4 Скип лишнего DL: bg-baked = overlay не нужен

Иногда самый быстрый рендер — **не рисовать вообще**. Kill-zone "закрытый
череп" уже запечён в bg-арте (golden 8-pointed sun); рисовать overlay
поверх в idle-state — двойная работа.

```asm
DrawKillzoneDual:
                LD   A, (VDC_KzFrame)
                CP   2
                RET  C                  ; KzFrame=0/1 (idle / final GO) → bg сам показывает
                ; ...emit Cell + Vertex2f только когда KzFrame >= 2 (анимация)
```

Это экономит **~10 байт DL × 60 FPS = 600 байт/сек** трафика SPI, который
освобождает Z80 cycles для chain physics + input + sound. Микроптимизация,
но накладывается на каждый "статичный" sprite в render-loop'е.

### 23.5 Continuous-motion absorb через HSub-advance (mirror of fast-spawn)

Last optimization-pattern: **используй существующий механизм движения, не пиши
свой**. Игра уже умеет двигать цепь плавно — в fast-spawn phase chain
двигается HSub++ × `VDC_FAST_ADVANCE`=12 раз за тик. Это даёт плавное
скольжение шаров по треку.

Для Game Over absorb разумно использовать **тот же механизм с другими
параметрами**:

```asm
VDC_UpdateAbsorb:
                LD   B, VDC_ABSORB_ADVANCE  ; e.g., 8 (32/8 = 4 ticks/cell)
.aa_loop:       PUSH BC
                CALL .ua_move_once          ; HSub++; on wrap → array shift, HSA capped
                POP  BC
                DJNZ .aa_loop
                ; alpha рассчитывается из HSub → синхрон с motion
```

`.ua_move_once`:
```asm
LD   A, (VDC_HSub)
INC  A
CP   VDC_CELL_SIZE
JR   C, .save                 ; HSub < CS → просто save
XOR  A                         ; wrap: HSub=0
LD   (VDC_HSub), A
; remove slot[0] (array shift), HSA capped → новый head в том же clamped
; последнем track sample → 1px continuity jump (invisible)
```

Эффект: tail-шары плавно скользят (sub-pixel HSub), head clamped на последнем
сэмпле трека, alpha fade ↔ HSub progress. При wrap — array shift И сброс
alpha в 255. **Visual continuity = 1 px разрыв** вместо discrete cell-jump.

Аналогичный паттерн можно применить к: уменьшению цепи после match-3 cascade,
выбросу bonus-шаров, любым "цепь сжимается/растягивается" анимациям.

### Источники

- `releases/baseline_2026-05-17_killzone_smooth_absorb/` — production-ready
  baseline после применения всех пяти приёмов.
- `Source/ASM/MainLoop.asm`:`.BInner` — bucket loop с per-head COLOR_A inject.
- `Source/ASM/main.asm`:`DrawKillzoneDual`, `VDC_UpdateAbsorb` — Cell-order
  fix + skip-in-idle + HSub-based absorb.
- FT81x PG §4.5 — `COLOR_A` opcode + persistent DL state.


## Глава 24. Per-ball matrix с per-slot hysteresis и grouped emit (2026-05-18)

### 24.1 Постановка задачи

Шары цепи Zuma вращаются по тангенсу трека: на изгибе спрайт повёрнут так,
чтобы рисунок (рельеф/блик) шёл по направлению движения, а не «лежал на
боку». На каждый шар нужна BITMAP_TRANSFORM с углом = tangent_at_track[i].

В лоб через FT812 это:

```asm
; per ball: 5 coproc-commands → 6 BITMAP_TRANSFORM_X DL entries
CALL ZL_EmitLoadId                ; cmd_loadidentity
LD   HL, ZL_BALL_HALF
LD   DE, ZL_BALL_HALF
CALL ZL_EmitTranslate             ; cmd_translate(+16, +16)
LD   A, (cache+0)
CALL ZL_EmitRotate                ; cmd_rotate(tangent_byte)
LD   HL, -ZL_BALL_HALF
LD   DE, -ZL_BALL_HALF
CALL ZL_EmitTranslate             ; cmd_translate(-16, -16)
CALL ZL_EmitSetMatrix             ; cmd_setmatrix
```

Translate(+16) → Rotate(θ) → Translate(-16) — стандартная связка чтобы
повернуть spritе вокруг центра bitmap (16,16) для атласа 32×32, а не вокруг
угла (0,0).

Стоимость на цепь 35 шаров: **175 coproc-команд + 210 DL-записей BITMAP_TRANSFORM**.

FT812 coproc'у на это не хватает vblank-окна даже на 74Hz → **тиринг на реале.**

### 24.2 Альтернатива #1: бакеты — почему не подошло

Классический способ дёшево покрыть N шаров: разбить tangent диапазон 0..255 BRAD
на K корзин (buckets), назначить каждому шару ближайшую корзину, и в outer-loop
эмитить матрицу 1 раз на корзину, а внутри обходить все шары своей корзины.

```
матрицы за кадр = K (фиксированно)
DL записи      = K × 6 transform + N × (cell + vertex)
```

K=32 → 11.25° на bucket, ~6× быстрее чем per-ball. Так и было сделано до 2026-05-18.

**Проблема:** «глобальный flip». Если raw tangent шара трамплинит между двумя
бакетами кадр-к-кадру (например, из-за округления track-данных), его
поворот скачет на 11.25°. И — что хуже — поскольку соседние шары находятся
в **одной с ним** корзине (общая матрица), они визуально мигают **сегментом
цепи целиком**. Глаз ловит «волну» на изгибах.

Это была реальная жалоба пользователя за всю прошедшую неделю работы.

### 24.3 Альтернатива #2: чистый per-ball — почему сломалось на реале

Прямой переход к per-ball matrix (для каждого шара свой `cmd_setmatrix`) убирает
эффект «сегмент мигает» начисто — каждый шар вращается независимо. Visual quality
максимальный.

Но coproc-нагрузка взлетела в ~6 раз. На баре эмуляторе (Unreal x64) кадр строился,
на реальном FT812 при 74Hz и DL ≥ 300 записей **vblank-окна не хватало**:
коприйцессор не успевал обработать команды до следующего DLSWAP — экран рвало.

Симптом: верхняя половина — frame N, нижняя — frame N−1, с горизонтальной чертой
разрыва. Появляется в самых нагруженных моментах (длинная цепь + жаба + bullet).

### 24.4 Гибрид: per-slot hysteresis + run-length grouped emit

Идея: **хранить tangent per-ball независимо** (это уже даёт per-slot stability —
flicker нет), но **эмитить матрицу только когда у соседних шаров в цепи tangent
действительно поменялся**.

На спирали Zuma соседние шары цепи находятся на одной дуге трека, поэтому их
tangent'ы очень близки. С разумной квантизацией (8 BRAD = ширина бакета)
адъяцентные шары часто попадают в **одинаковую дольку** — для них достаточно
одной матрицы.

#### 24.4.1 Per-slot byte-level hysteresis

Pre-pass для каждого шара хранит **свой** «стабильный» tangent в page-5 RAM
(`#4100 + slot_idx`), обновляется только когда raw отличается на ≥ THR=8 BRAD:

```asm
; D = raw tangent (preserved). HL = state addr через H = STATE_HI, L = slot.
LD   A, (VDC_LastTangent)
LD   D, A
LD   A, C                              ; slot index
LD   H, ZL_BALL_TANGENT_STATE_ADDR >> 8 ; #41 (low byte STATE_ADDR = 0 заведомо)
LD   L, A
LD   A, (HL)                           ; prev stable
LD   E, A
LD   A, D                              ; raw
SUB  E                                  ; (raw - prev) mod 256
JP   P, .stab_pos                      ; signed sign-bit check
NEG
.stab_pos: CP   ZL_BALL_TANGENT_HYSTERESIS_THR  ; = 8
JR   NC, .stab_update                  ; |delta| >= THR → update
LD   A, E                              ; else keep prev
JR   .stab_done
.stab_update: LD   A, D
LD   (HL), A
.stab_done:                            ; A = stable tangent (raw if updated, prev else)
```

**Почему именно 8 BRAD threshold:** должен быть ≥ ширине квантизационной
корзины (8 BRAD), иначе raw, осциллирующий на границе ±4, заставит stable
скакать между двумя бакетами. С 8: stable меняется только если raw уехал
заметно в новую область → stable settles в одной корзине.

**Почему ёлки H=STATE_ADDR>>8, L=slot** (а не `LD HL,…+LD DE,slot+ADD HL,DE`):
выбрали ZL_BALL_TANGENT_STATE_ADDR=`#4100` с low-byte=0 специально, чтобы 8-bit
slot index ставился прямо в L без сложения. Сохраняет регистр D (с raw
tangent) от затирания через `LD DE, addr`.

#### 24.4.2 Quantize-then-compare в draw loop

В per-ball loop **квантуем** stable tangent к ближайшему 8 BRAD (`AND #F8` =
32 корзины) и сравниваем с tangent'ом, для которого мы УЖЕ эмитили матрицу.
Если совпал — пропускаем `cmd_setmatrix` пакет:

```asm
.ChainDraw:
                LD   A, #01                         ; sentinel (не multiple-of-8)
                LD   (ZL_TmpLastTangent), A
                LD   A, (ZL_BallCount)
                LD   B, A                            ; loop count
                LD   IX, ZL_BALL_CACHE_ADDR
.PerBallLoop:   LD   A, (IX+1)                       ; cell (+1) = 0xFF marks gap
                CP   #FF
                JP   Z, .PBSkip
                PUSH BC
                ; Skip matrix emit если quantized tangent совпал с предыдущим.
                LD   A, (IX+0)                       ; stable tangent
                AND  #F8                              ; quantize к multiple-of-8
                LD   HL, ZL_TmpLastTangent
                CP   (HL)
                JR   Z, .PBNoMatrix                  ; same bucket → reuse матрицу
                LD   (HL), A                          ; новый bucket → save
                ; emit full matrix pack (5 coproc-cmds)
                CALL ZL_EmitLoadId
                LD   HL, ZL_BALL_HALF
                LD   DE, ZL_BALL_HALF
                CALL ZL_EmitTranslate
                LD   A, (ZL_TmpLastTangent)
                CALL ZL_EmitRotate
                LD   HL, -ZL_BALL_HALF
                LD   DE, -ZL_BALL_HALF
                CALL ZL_EmitTranslate
                CALL ZL_EmitSetMatrix
.PBNoMatrix:
                ; ... handle, cell, vertex2f для текущего шара (без матрицы) ...
```

Sentinel `#01` гарантирует что первый шар всегда триггерит matrix emit
(никакой реальный quantized stable tangent не равен 1, т.к. они кратны 8).

#### 24.4.3 Что в итоге

На спирали с 35 шарами цепи статистически на цепь приходится ~8–15 уникальных
quantized buckets, и balls внутри bucket'а лежат подряд (соседи по track) →
matrix emit срабатывает ~8–15 раз вместо 35. **3–4× падение coproc-нагрузки.**

Метрики:
```
              Bucketed (старое)    Per-ball naive     Per-ball + grouped
matrix/frame         32              35                  8-15
coproc-cmd/frame     160             175                 40-75
DL entries (chain)   294             315                 ~150
flip-flicker         YES             NO                  NO
vblank ok @ 74Hz     YES             NO (tear)           YES
```

### 24.5 Ловушки реализации

#### Регистр-сейв (B-clobber)

Helpers `FT_BitmapLayout`, `FT_BitmapSize` — макросы, разворачивающиеся в
инлайн через FT_CMD_BUF, который **клобает BCDE**. Поэтому паттерн «сохрани
цвет в B → emit setup macros → возьми обратно из B» молча даёт мусор:

```asm
LD A, (Bullet_Color)
LD B, A                                ; "save"
... CALL ZL_EmitBallHandle ...
FT_BitmapLayout ...                    ; ← кладёт B = 0x07 (opcode)
FT_BitmapSize ...                      ; ← кладёт B = 0x08
LD A, B                                ; ← А не цвет! → cell wrong
AND 3
CALL Cell                              ; рисует случайный цвет
```

**Симптом был:** жаба стреляет одним цветом, в цепь вставляется другой. Потому
что **в памяти** `Bullet_Color` корректный (`VDC_InsertAt(Bullet_Color)`),
а **на экране** во время полёта пуля рисовалась мусорным cell.

**Фикс:** перечитать color из памяти после макросов, не из регистра:

```asm
LD A, (Bullet_Color)
CP 4
LD A, 0
JR C, .h0
LD A, 9
.h0: CALL ZL_EmitBallHandle
FT_BitmapLayout ...
FT_BitmapSize ...
LD A, (Bullet_Color)                   ; re-read — macros clobbered registers
AND 3
ADD A,A : ... *32
CALL Cell
```

Аналогично для chain draw, но там есть `IX → (IX+1)` cache pointer — Cell
читаем оттуда, IX через хелперы сохраняется.

#### Sentinel выбор

`ZL_TmpLastTangent` инициализируется `#01`, а не `#FF` — потому что после
`AND #F8` реальные quantized tangent'ы могут быть `0, 8, 16, ..., 248`. Значение
`#FF` после AND F8 даёт `#F8` (валидный bucket), и если у первого шара
quantized = 248 = `#F8`, он бы совпал с sentinel и **пропустил matrix emit** —
а матрицы ещё нет (FT812 unitialized state) → шар нарисуется с identity matrix.
Sentinel `#01` гарантированно не совпадает ни с одним quantized = multiple-of-8.

#### JR vs JP — out of range

После добавления matrix-skip логики body цикла вырос. `JR Z, .PBSkip` (2 байта,
±127 диапазон) перестал доставать. Заменил на `JP Z, .PBSkip` (+1 байт но
absolute address). Уроки прошлых сессий: при росте кода всегда чекать
JR-distances через `--lst`.

### 24.6 RNG bias как побочный bug (2026-05-18)

Параллельно с per-ball рефакторингом расширил `VDC_NUM_COLORS` с 4 до 6 (атлас
уже содержал colors 4-5: white + yellow). Жёлтый не появлялся в цепи СОВСЕМ.

LFSR Galois с polynomial `#B400`:

```asm
LD HL, (VDC_LfsrSeed)
LD A, L
AND 1                          ; bit out
SRL H : RR L                   ; shift HL right
JR Z, .no_xor
LD A, H : XOR #B4 : LD H, A    ; feed back via poly
.no_xor:
LD (VDC_LfsrSeed), HL
LD A, L
XOR H                          ; 8-bit "random"
AND 7                          ; → 0..7
CP NUM_COLORS                  ; reject если >= NUM
JR NC, retry
RET
```

**Скрытая корреляция битов:** для конкретного poly `#B400`, после XOR L⊕H и
маски `AND 7` результат покрывает почти исключительно `{0,1,3,4}`, а значения
`{2,5,6,7}` встречаются ~1 раз на 1000. Rejection (`CP NUM_COLORS`) отсекает
6,7 — а 2 и 5 он не лечит. Цвета 2 (фиолетовый) и 5 (жёлтый) выпадают почти
никогда.

**Замер на baseline:** 1000 вызовов `VDC_RandomColor` дали `[306, 231, 2, 230, 230, 1]`.

**Фикс — mul-then-shift вместо bit-masking:**

```asm
LD A, L
XOR H                          ; A = 8-bit raw rand
LD L, A
LD H, 0                        ; HL = rand byte
LD A, VDC_NUM_COLORS           ; A = 6
CALL ZL_Mul16x8                ; HL = rand * NUM (max 6*255=1530, <16-bit)
LD A, H                        ; A = (rand * NUM) >> 8 = 0..NUM-1
RET
```

Принцип: любое значение rand 0..255 распределяется по NUM_COLORS bucket'ов
пропорционально размеру bucket'а. Bias ≤ 1.4% даже при равномерном rand,
и НЕ требует, чтобы определённые биты были некоррелированы.

После замера: `[166, 111, 110, 57, 222, 334]` — все 6 цветов появляются.
Дистрибуция всё ещё неравномерна из-за самой неравномерности LFSR-байта,
но **колор 5 теперь в игре**.

### 24.7 Применимость в других случаях

Паттерн «per-slot hysteresis + run-length grouped emit» обобщается:

1. **Условие применимости:** есть много объектов, которым нужно индивидуальное
   состояние (color, scale, rotation), но в смежных объектах состояние часто
   одинаково.
2. **Шаг 1:** state per-object с byte-level hysteresis (storage = N байт RAM,
   threshold ≥ quantization step).
3. **Шаг 2:** в draw-loop сравнивай с last-emitted state, пропускай emit при
   совпадении.

Кандидаты на это в Zuma VDAC2:
- Spin frame (cell number): соседние шары на одной фазе rolling — сейчас
  они **уже** имеют разные cell индексы из-за `t × K`, group skip = no-op.
- Bitmap handle 0 vs 9 (для colors 4-5 split): группировать по color group —
  уже работает (handle меняется только при cell ≥ 128).

### Источники

- `Source/ASM/MainLoop.asm`:`.ChainDraw` / `.PerBallLoop` — финальная реализация.
- `Source/ASM/VDC.asm`:`VDC_RandomColor` — mul-then-shift fix.
- `releases/baseline_2026-05-18_pre_per_ball_6_colors/` — pre-change snapshot
  для отката.
- FT81x PG §4.7 — BITMAP_TRANSFORM_A..F state, persistent across vertex2f.
