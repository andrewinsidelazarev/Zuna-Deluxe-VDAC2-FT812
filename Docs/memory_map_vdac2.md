# Zuma Deluxe VDAC2: актуальная карта памяти

Дата среза: 2026-07-05, build после `v098-2026-07-05-loading-level-hold-reference`.

Документ описывает текущую рабочую раскладку проекта. Источники истины для
проверки:

- `Source/ASM/main.asm`
- `Source/ASM/top_mask_overlay_meta.inc`
- `spgbld_boot.ini`
- `spgbld_vdac2.ini`
- `Source/OTHER/check_memory_map.py`
- `Source/OTHER/audit_ramg_full.py`
- свежий `Build/zuma.sym`

Перед правками памяти запускать:

```powershell
python Source\OTHER\check_memory_map.py
python Source\OTHER\audit_ramg_full.py
```

Текущий результат: обе проверки проходят. `Main1` почти полон: free 248 bytes.

## Правила

- FT812 `RAM_G` ровно 1 MiB: `#000000..#100000`.
- Адреса `>= #100000` нельзя использовать: на железе это выход за пределы
  графической RAM_G.
- `RAM_G` разделён на профили сцен. Перекрытия между профилями допустимы только
  если сцена полностью перезагружает свои assets.
- Перекрытия внутри одного активного профиля запрещены, кроме явно описанных
  swap/overlay зон.
- `#0AC000..#0CC000` не свободная память. Это swap-zone: tunnel top-mask в
  активном gameplay или dialog frame в pause/dialog.
- `LOADING LEVEL X-X` при входе в gameplay временно использует `#0AC000`.
  Перед загрузкой tunnel top-mask эта область гасится чёрным DL.
- `Build/` содержит итоговые артефакты сборки. AY SFX data живёт в
  `Sounds/AY/ay_sfx_data.bin`, не в `Build/`.

## Z80 Layout

Текущие размеры из `Build/*.bin`:

| Блок | CPU/slot | Файл | Размер | Свободно |
|---|---:|---|---:|---:|
| TSLib/slot0 | `#1000`, page `#00` | `Build/TSLib.bin` | 12244 | n/a |
| Core/Main0 | `#5C00`, page `#05` | `Build/Core.bin` | 9211 | n/a |
| Gameplay overlay | `#C000`, page `#04` | `Build/main1_play.bin` | 16136 | 248 |
| UI overlay | `#C000`, page `#41` | `Build/ui_ovl.bin` | 14510 | 1874 |
| Loader overlay | `#C000`, page `#40` | `Build/loader_ovl.bin` | 12351 | 4033 |

Стартовая схема:

| Slot | CPU range | Обычная page | Назначение |
|---|---:|---:|---|
| 0 | `#0000..#3FFF` | `#00` | TSLib + slot0 helpers |
| 1 | `#4000..#7FFF` | `#05` | Core/Main0, resident state |
| 2 | `#8000..#BFFF` | `#06` | Track V2 page после загрузки уровня |
| 3 | `#C000..#FFFF` | `#04/#40/#41` | gameplay / loader / UI overlay |

Временные Z80 pages:

| Page | Назначение |
|---:|---|
| `#01` | `SCRATCH_PAGE` для ZX7 unpack |
| `#03` | RawPak sector/staging buffer |
| `#04` | gameplay overlay |
| `#06` | Track V2 page A |
| `#07..#0E` | fallback/staging bg pages |
| `#0F/#10/#12` | дополнительные Track V2 pages |
| `#40` | loader overlay |
| `#41` | UI overlay |
| `#F4` | AY SFX page, source `Sounds/AY/ay_sfx_data.bin` |

## Runtime Artifacts

| Файл | Размер |
|---|---:|
| `Build/ZUMA_VD2.SPG` | 377344 |
| `Build/ZUMAMAIN.PAK` | 3670016 |
| `Build/ZUMALVL.PAK` | 7139840 |
| `Build/ZUMAAUD.PAK` | 802136 |
| `Build/ZUMASND.PAK` | 1215488 |
| `Sounds/AY/ay_sfx_data.bin` | 11714 |

`spgbld` пишет секунду времени сборки в заголовок SPG по offset `0x3C`, поэтому
SHA всего `.spg` не является стабильным payload-хешем.

## SPG Pages

Boot SPG (`spgbld_boot.ini`) содержит минимальный boot/runtime набор:

| Page | Источник |
|---:|---|
| `#00` | `Build/TSLib.bin` |
| `#05` | `Build/Core.bin` |
| `#F4` | `Sounds/AY/ay_sfx_data.bin` |
| `#40` | `Build/loader_ovl.bin` |
| `#41` | `Build/ui_ovl.bin` |
| `#25..#27` | loading text pages |
| `#A8..#C4` | boot loading artwork/logo/authors |

Full profile (`spgbld_vdac2.ini`) дополнительно описывает gameplay/menu/level
assets. `ZUMAMAIN.PAK` генерируется из `spgbld_vdac2.ini`; страницы boot-набора
исключаются как уже resident, остальные попадают в pack table.

Важные page owners:

| Pages | Владелец |
|---:|---|
| `#04` | gameplay overlay |
| `#06` | fallback/track page |
| `#07..#0E` | fallback bg pages |
| `#11` | fallback bg palette |
| `#16..#1F` | killzone + destroy |
| `#20..#27` | text/loading/sparkle |
| `#28..#2C` | WIN explosion |
| `#3A..#3F` | frame strips + palette |
| `#40` | loader overlay |
| `#41` | UI overlay |
| `#42` | level chain table |
| `#43..#4F` | L19 balls atlas + palette |
| `#52..#5F` | frog/cursor/HUD |
| `#60..#6D` | dialog/fonts |
| `#70..#92` | main menu |
| `#93` | free |
| `#94..#BB` | level-select |
| `#BC..#CB` | More Games |
| `#CC..#F3` | tunnel top-mask data |
| `#F4` | AY SFX data |

Level-select previews не живут в SPG. Они грузятся из `ZUMALVL.PAK`.

## FT812 RAM_G: Boot Loading

| Range | Asset |
|---:|---|
| `#000000..#03C000` | boot loading DXT-L4 bg |
| `#03C000..#044000` | boot loading bar |
| `#044000..#06C000` | ZX Evolution TS anim |
| `#06C000..#070000` | SFX authors atlas |
| `#070000..#074000` | PopCap logo |

Max end: `#074000`.

## FT812 RAM_G: Main Menu

| Range | Asset |
|---:|---|
| `#000000..#04B000` | menu foreground |
| `#04B000..#065180` | menu sky |
| `#065180..#0670C4` | sun |
| `#0670C4..#071D08` | glow |
| `#071D08..#0ABA58` | buttons |
| `#0ABA60..#0ABC60` | sky palette |
| `#0ABC60..#0ABE60` | UI palette |
| `#0AC000..#0ACB48` | menu cursor bitmap |

Cursor details:

- Финальный bitmap курсора: 38x38 ARGB4 = `#B48` bytes, `#0AC000..#0ACB48`.
- Глобальный `Graphics/Converted/cursor_p00.zlib` распаковывается padded page на
  `#0AC000..#0B0000`; палитры `#0ABA60..#0ABE60` после этого пишутся заново.
- `check_memory_map.py` держит для `MENU_CURSOR` защитное окно
  `#0AC000..#0AD200`, поэтому его max end для `main_menu` = `#0AD200`.

Max end финальных живых данных: `#0ACB48`.
Max end статической проверки: `#0AD200`.

## FT812 RAM_G: Level Select

| Range | Asset |
|---:|---|
| `#000000..#04B000` | level-select bg |
| `#04B000..#082658` | sky/UI/buttons/badges |
| `#084000..#08C000` | `LOADING LEVELS...` bitmap |
| `#0ABA60..#0ABC60` | sky palette |
| `#0ABC60..#0ABE60` | UI palette |
| `#0AC000..#0ACB48` | cursor bitmap |
| `#0B0000..#0B2810` | preview markers/frog/killzone |
| `#0B3000..#0D3000` | preview bg buffer B |
| `#0D4000..#0F4000` | preview bg buffer A |

Max end: `#0F4000`.

Как и в главном меню, cursor bitmap занимает только `#480` bytes, но
`check_memory_map.py` проверяет `LS_CURSOR_REUSE` как `#0AC000..#0AD200`, а
одноразовая zlib-распаковка пишет padded page до `#0B0000` до загрузки
preview markers и палитр.

## FT812 RAM_G: More Games

| Range | Asset |
|---:|---|
| `#000000..#04B000` | More Games bg |
| `#0ABC60..#0ABE60` | More Games palette |

Max end: `#0ABE60`.

## FT812 RAM_G: Gameplay

Steady-state после загрузки уровня:

| Range | Asset |
|---:|---|
| `#000000..#004000` | GAME OVER text |
| `#004000..#00C000` | `FONT_LEVEL48` |
| `#00C000..#010000` | sparkle |
| `#010000..#02D4C0` | level background indices |
| `#02D500..#02D700` | bg palette |
| `#02D800..#030000` | dialog OK button |
| `#030000..#050000` | frog/plate/tongue/overlay ARGB4 |
| `#050000..#080000` | balls atlas |
| `#080000..#080200` | balls palette |
| `#080200..#080400` | frame palette |
| `#080400..#084000` | top-mask window A |
| `#084000..#08C000` | frame top |
| `#08C000..#090000` | frame bottom |
| `#090000..#094000` | frame left |
| `#094000..#098000` | frame right |
| `#098000..#0A0000` | native font |
| `#0A0000..#0A4000` | Cancun10 stats font |
| `#0A4000..#0AC000` | Cancun8 HUD font |
| `#0AC000..#0CC000` | top-mask swap / dialog frame |
| `#0CC000..#0CC200` | HUD life frog |
| `#0CC200..#0CC400` | HUD palette |
| `#0CC400..#0CC600` | dialog palette |
| `#0CC800..#0CE400` | HUD menu atlas |
| `#0CE400..#0CED60` | HUD progress atlas |
| `#0D0000..#0D4000` | cursor upload block |
| `#0D4000..#0FC000` | killzone + destroy |
| `#0FC000..#100000` | top-mask window B |

Max end: `#100000`.

Dialog/pause state:

- `#0AC000..#0CC000` содержит `DIALOG_FRAME`.
- Renderer не рисует tunnel top-cover, пока dialog frame занимает swap-zone.

WIN state:

- `#050000..#064000` содержит `WINEXP_ATLAS` поверх balls atlas.
- Это допустимо только после окончания gameplay-шаров.

Loading gameplay transient:

- `LOADING_TEXT_GAME_RAMG=#0AC000`.
- `LOADING LEVEL X-X` рисуется из этой временной области.
- Frame strips в `#084000..#098000` можно грузить без раннего гашения текста.
- Перед `ZL_UploadTopMasksMaybe` ставится чёрный DL, потому что top-mask может
  занять `#0AC000..#0CC000`.

## ZUMALVL.PAK

Формат:

- sector 0: header `ZLVP`
- sector 1: TOC, 22 entries x 20 bytes
- sector 2..N: data blob

Секции уровня:

| Section | Runtime target |
|---|---|
| bg | `BG_RAMG_ADDR=#010000`, 8 x 16K pages |
| pal | `BG_PALETTE_RAMG=#02D500`, 512 bytes |
| track | Track V2 pages `#06/#0F/#10/#12` |
| title | title atlas/data section |
| preview | level-select preview ping-pong buffers |

`ZUMALVL.PAK` сейчас 7139840 bytes. Все 22 уровня имеют bg/palette/track/title/preview.

## Audio

GS:

- `ZUMAAUD.PAK` содержит MOD/audio pack.
- `ZUMASND.PAK` содержит GS SFX pack.

AY fallback:

- Исходные WAV берутся из `Sounds/Converted/WAV_GS`.
- Конвертер: `Source/OTHER/make_ay_sfx.py`.
- Готовый AY pack: `Sounds/AY/ay_sfx_data.bin`.
- Отчёт аппроксимации: `Sounds/AY/ay_sfx_report.txt`.
- ASM metadata: `Source/ASM/ay_sfx_meta.inc`.
- Runtime player: `Source/ASM/AYSfx.asm`.

## Текущие Допустимые Перекрытия

Cross-profile reuse:

- `level_select:LS_PREVIEW_BG_A` пересекает gameplay `KZ+DESTROY`.
- `level_select:LS_PREVIEW_BG_B` пересекает gameplay `DIALOG_FRAME`.
- `main_menu:MENU_CURSOR` пересекает gameplay `DIALOG_FRAME`.
- `level_select:LS_CURSOR` пересекает gameplay `DIALOG_FRAME`.

Same-profile intentional overlaps:

- `KILLZONE_DESTROY_UPLOAD` и `DESTROY_HANDLE_SOURCE`.
- WIN-only `WINEXP_ATLAS` поверх balls atlas.
- `TOP_MASK_SWAP` и `DIALOG_FRAME` как разные состояния одной swap-zone.

## Проверка

Актуальный успешный вывод `check_memory_map.py`:

```text
[ramg] gameplay: 23 ranges, max end #0FC000
[ramg] level_select: 10 ranges, max end #0F4000
[ramg] main_menu: 6 ranges, max end #0AD200
[ramg] more_games: 2 ranges, max end #0ABE60
[build] Main0_Size=9211 bytes
[build] Main1_Size=16136 bytes, free=248 bytes (gameplay overlay page #04)
[build] UiOvl_Size=14510 bytes, free=1874 bytes (ui overlay page #41)
[build] LoaderOvl_Size=12351 bytes, free=4033 bytes (loader overlay page #40)
PASS: memory-map checks
```

Актуальный успешный вывод `audit_ramg_full.py` заканчивается:

```text
OK: все профили влезают в 1МБ, живых перекрытий нет.
```
