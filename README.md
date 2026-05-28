# Zuma Deluxe — VDAC2 / FT812 порт (640×480)

Порт классической **Zuma Deluxe** под аппаратную связку **ZX-Evo (Pentevo) + VDAC2 + FT812**
в нативном разрешении **640×480 RGB565**. Шары летят через атлас на FT812, фон скейлится
кооператорной командой `cmd_scale`, лягушка собирается из 4-х компонент (plate / body /
tongue / overlay) и вращается матрицей `T·R·T⁻¹`.

Параллельная **VDC-ветка** (нативное 360×288 на TS-Conf без VDAC2) живёт в `c:/z80/zuma/`
и общается с этой через **append-only [Чат.txt](Чат.txt)**.

---

## Hardware target

| Компонент          | Параметр                                              |
|--------------------|-------------------------------------------------------|
| CPU                | Z80 @ 14 МГц (TS-Conf), кэш через `SYSCONG.bit2`      |
| Графика            | FT812 (Gameduino 2 / BridgeTek BT81x клон)            |
| Разрешение         | 640×480 RGB565, FT_INT_SWAP vsync 57.25 Гц            |
| RAM_G              | 1 МБ — bg `#010000`, atlas `#0A6000`, frog `#04C000`  |
| SPI                | порты `#77` (CTRL), `#57` (DATA), `#AF` (VCONFIG)     |
| Эмулятор           | Unreal x64 (`Renderer = Double size` в `Unreal.ini`)  |

---

## Раскладка файлов

```
.
├── main.asm              -- точка сборки: TSLib block (page 0) + Core block (page 5)
├── MainLoop.asm          -- основной цикл, ввод, render-state machine
├── VDC.asm               -- Virtual Discrete Chain (физика шаров) + render
├── Frog.asm              -- лягушка: aim, rotation, sprite composition, выстрел
├── Bullet.asm            -- летящий шар: spawn по LMB/SPACE, движение, collision bbox
├── Init_Video.asm        -- FT_BOOT_UP + 640×480 timings + INT_SWAP
├── spgbld_vdac2.ini      -- описание .spg-страниц для spgbld
├── build.cmd             -- sjasmplus → spgbld → запуск в Unreal
│
├── make_balls_atlas.py   -- генерация balls_atlas (6 цв × 16 фаз × 32×32 ARGB4)
├── make_bg_level01.py    -- 400×300 RGB565 fade с матрицей scale 1.6×
├── make_bg_tile.py       -- bg-тайл 64×64 для не-level превью
├── make_misc_sprites.py  -- frog/plate/tongue/overlay (122×122) + killzone + GAME OVER
├── make_cursor.py        -- стрелка-курсор 24×24
├── make_track_640.py     -- TrackData (X,Y по 640×480, stride 6 байт)
├── make_test_ball.py     -- одиночный test ball 40×40
│
├── *.bin                 -- ассеты для spgbld (генерируются из .png make_*-скриптами)
├── *.spg                 -- сборка для эмулятора (Unreal)
│
├── visual_emulator.py    -- Python tkinter тестер для frog/aim/rotation
├── full_vdc_simulation.py-- stochastic VDC test (50+ random runs)
├── vdc_visual_emulator.py-- VDC chain physics reference (port from c:/z80/zuma)
├── sim_*.py              -- prototyping rotation/pivot/tongue до asm-порта
│
├── Docs/
│   ├── uchebnik_tsconf_vdac2.{md,html}  -- учебник (накопительный конспект)
│   ├── FT81x.pdf                        -- FT81x datasheet
│   ├── The_Gameduino_2_Tutorial_*.pdf   -- главный референс по API (Bowman 2013)
│   ├── VDAC2 #2 - Первые шаги.docx      -- ZX-Evo VDAC2 SPI tutorial
│   ├── _*.txt                           -- текстовые дампы тех же PDF/DOCX
│   └── TSLib/                           -- готовая asm-обвязка от автора VDAC2
│
├── releases/             -- baseline-снэпшоты по эпохам (см. releases/README.md)
├── _hd_refs/             -- Frog.c/.h / ResourceStore.c/.h из Zuma-Deluxe-HD
└── Чат.txt               -- cross-project канал общения с VDC-веткой (append-only)
```

---

## Build

```
build.cmd
```

Делает три шага:

1. **`sjasmplus Source/ASM/main.asm`** → `Build/TSLib.bin`, `Build/Core.bin`, `Build/main1_play.bin`, `Build/main.lst`, `Build/zuma.sym`
2. **`spgbld -b spgbld_vdac2.ini Build/zuma_vdac2.spg`** — упаковывает code blocks и graphics assets в `.spg`
3. **запуск** `Build/zuma_vdac2.spg` в Unreal x64

Пути к `sjasmplus.exe` / `spgbld.exe` / `Unreal.exe` зашиты в `build.cmd` —
поправьте под себя.

Ассеты-`.bin` хранятся в репо (генерируются из spritesheet'ов соседнего проекта
Zuma Deluxe — `~/Desktop/Zuma Deluxe/graphics/...`). Регенерировать локально:

```
python make_balls_atlas.py
python make_bg_level01.py
python make_misc_sprites.py
python make_cursor.py
python make_track_640.py
```

---

## Учебник / документация

Главный накопительный конспект — **[`Docs/uchebnik_tsconf_vdac2.md`](Docs/uchebnik_tsconf_vdac2.md)**.

Туда складываются:

- открытия по FT812 (matrix pattern, cmd_scale inverse, paletted не работает в Unreal,
  bg-padding overlap atlas, …),
- решения нетривиальных багов (overlay Cell persistent state, FM_EN ломает keyboard
  port reads, BITMAP_TRANSFORM работает на UV не screen, …),
- архитектурные приёмы (chain-TSU поверх canvas, parallel build/render с FT INT
  sync, late vblank TSU writes, …).

---

## Параллельная ветка

VDC-версия (TS-Conf без VDAC2, 360×288) — `c:/z80/zuma/`.
Обе ветки идут одновременно; общий канал —
[`Чат.txt`](Чат.txt). Туда пишутся только **критические находки**
(root-cause багов, архитектурные решения, фиксы) с маркером `VDC → VDAC2` /
`VDAC2 → VDC` / `VDC ↔ VDAC2`.
