# Releases — Zuma Deluxe VDAC2 / FT812

Снэпшоты по эпохам разработки. **Свежее — сверху.**

Каждая папка — копия core-исходников (`.asm` + `*.py` + `spgbld_vdac2.ini` + `zuma_vdac2.spg`)
на момент того состояния. Ассеты-`.bin` лежат в корне проекта и шарятся между всеми
baseline'ами (они аддитивные — atlas/bg/sprites только дополняются).

---

## baseline_2026-05-18_per_ball_grouped_6colors  *(09:37)* ⭐ **CURRENT**

User-verified on real FT812 hardware: **no tearing, no segment flicker, all 6 colors visible.**

Три связанных изменения:

1. **Per-ball matrix с grouped emit.** Замена 32-bucket классификатора на
   per-slot byte-level hysteresis (threshold 8 BRAD = ширина бакета). В draw
   loop квантуем stable tangent к 8 BRAD и пропускаем `cmd_setmatrix` пакет
   когда у соседних шаров цепи квантованный tangent совпадает. Типичная цепь —
   ~8-15 matrix emits/кадр вместо 35 (3-4× меньше coproc-нагрузки). Голый
   per-ball без grouping рвал кадры на 74Hz vblank window — grouped версия
   укладывается.

2. **6 цветов.** `VDC_NUM_COLORS 4 → 6`. `FT_Cell` DL опкод 7-битный (wrap at
   128), поэтому для цветов 4-5 добавлен второй `BITMAP_HANDLE 9` с источником
   `RAM_G #090000` (атлас offset для cells 128+). Per-ball loop выбирает
   handle по биту 7 cell-индекса; Bullet/Frog mouth+next используют helper
   `ZL_EmitBallHandle` для общей логики.

3. **RNG fix.** `VDC_RandomColor` имел LFSR-bias: для poly `#B400` бит-pattern
   `(L XOR H) & 7` почти не выдавал значения 2 и 5. Жёлтый (color 5)
   практически не появлялся в цепи. Замена на mul-then-shift через
   `ZL_Mul16x8`: `((L XOR H) * NUM_COLORS) >> 8`. Bias ≤ 1.4%, все 6 цветов
   спавнятся.

Побочные фиксы:
- **B-clobber bug** в Bullet/Frog: макросы `FT_BitmapLayout/Size` клобают BCDE.
  Pattern «save color in B → emit macros → re-read B» давал мусорный cell
  index. Симптом: пуля рендерилась цветом X, в цепь вставлялась цветом Y.
  Fix: перечитывать color из памяти после макросов.
- **AND 1 + RET NZ** subdivider закомментирован — физика теперь 60 Гц (было 30).
  Цепь и spin в 2× быстрее реал-тайма.

Учебник: Глава 24 разбирает паттерн per-slot hysteresis + grouped emit,
B-clobber pitfall, mul-then-shift vs AND-mask для RNG bias.

Core 8134 байт (58 байт свободно до #8000). Все тесты PASS.

## baseline_2026-05-18_pre_per_ball_6_colors  *(07:39)*

Pre-change snapshot перед per-ball рефакторингом. Использовался для отката если
эксперимент сломается на реале (не понадобился). Эквивалентен предыдущему
production-baseline `2026-05-17_killzone_smooth_absorb` плюс утренний Codex'овский
combined ball rotation jitter fix (offline-сглаженный track tangent + compact
per-slot bucket hysteresis at #4100). 32 buckets + Manhattan-46 wrong-insert
filter в Bullet.

---

## baseline_2026-05-10_classic_calibrated  *(23:50)*

Calibration под classic Zuma: ball **32×32 native** (без upscale), **4 цвета**,
ровно **85 шаров** на уровне, `CELL_SIZE = 28`, atlas с 16 фазами sparkle.
Bullet/collision/match-3 интегрированы.

**Open:** match-3 cascade даёт визуальный «разрыв», `ExplodingFrame` animation
не реализован (frame-stages только в коде, без графики).

## baseline_2026-05-10_collision_vsync  *(21:28)*

Bullet → ball **collision** (bbox `THR = 28`) + match-3 destroy + **parallel
build/render** с FT INT sync (HighLander pattern). Стрельба пробивает цепочку,
match-3 удаляет, цепь компактится.

**Open:** mouse-motion artifact (горизонтальные «всплески» вокруг лягушки при
быстром mouse-move) — кандидат на фикс.

## baseline_2026-05-10_bullet_flying  *(19:54)*

Single-bullet MVP — spawn по `LMB` / `SPACE` с правильным цветом из лягушки,
полёт по `cos/sin` тангенса прицела, deactivate за экраном.

**Open:** collision не реализован, шар улетает за край без эффекта.

## baseline_2026-05-10_full_input  *(19:40)*

Полный input-стек: **mouse + arrows + O/P + LMB + SPACE + Kempston FIRE**, с
обязательным `FM_EN` toggle вокруг Spectrum keyboard port reads (`#FE`) —
иначе TS-Conf FM перенаправляет port на регистры и keyboard перестаёт работать.

## baseline_2026-05-10_cursor_arrow1_kbd  *(18:21)*

Custom cursor sprite **24×24** (стрелка) + **клавиатура** `←` / `→` для
прицела лягушки. Raw mouse для cursor, smoothed для frog aim.

## baseline_2026-05-10_overlay_cell_fixed  *(17:29)*

Стабильная **HD-лягушка** без overlay-flicker. Root cause: `Cell` register
persistent в DL между Begin/End и сменой `BITMAP_HANDLE` — overlay наследовал
`Cell = N` от NextBall, читал zero-padding и был невидим. Fix: `XOR A : Cell`
перед каждым `Vertex2f`.

## baseline_2026-05-10_frog_full_composition  *(15:28)*

Полная HD-композиция лягушки: **plate + body + tongue + ball + next + overlay**.
Overlay 122×122 (=size of body), balls 16→8 phases.

**Open:** overlay flicker после выстрела (стало baseline для следующего фикса
`overlay_cell_fixed`).

---

## Восстановление baseline'а

```
cd <baseline_dir>
copy *.asm  ..\..\
copy *.py   ..\..\
copy spgbld_vdac2.ini  ..\..\
cd ..\..
build.cmd
```

Или просто запустить `zuma_vdac2.spg` из baseline-папки в Unreal без пересборки.
