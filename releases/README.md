# Releases — Zuma Deluxe VDAC2 / FT812

Снэпшоты по эпохам разработки. **Свежее — сверху.**

Каждая папка — копия core-исходников (`.asm` + `*.py` + `spgbld_vdac2.ini` + `zuma_vdac2.spg`)
на момент того состояния. Ассеты-`.bin` лежат в корне проекта и шарятся между всеми
baseline'ами (они аддитивные — atlas/bg/sprites только дополняются).

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
