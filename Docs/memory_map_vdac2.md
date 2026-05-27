# Zuma Deluxe VDAC2: карта памяти

Дата среза: 2026-05-27 (опорная **v041**, host-verified).

Документ фиксирует текущий runtime layout проекта после перехода к `ZUMALVL.PAK`.
Главная цель: больше не добавлять превью, загрузчики и временные буферы "на глаз" в уже занятые области.

> Ревизия 2026-05-27: размеры (Core 4881→5095, main1 15→18 B free, TSLib 11845→11890),
> page `#0F` снова занят в рантайме (chunkB трека — `TRACK_PAGE2`), верхние уровни
> ПОЧИНЕНЫ (корень — «трек ≤ 1 страница», не фрагментация), добавлен резидентный
> `VDC_ReadSampleAtHL` (page-aware чтение сэмплов трека), адреса резидентных vars
> пересняты по `Build/zuma.sym`. Открытая задача: вынести FAT-загрузчик из Core +
> поддержка сегментированного (фрагментированного) PAK — см. §3a и §9.

## 1. Правила владения

- `spgbld_vdac2.ini` описывает только SPG-страницы. Это не доказывает, что runtime RAM_G не конфликтует.
- FT812 `RAM_G` должен рассматриваться как набор профилей:
  - `gameplay` - фон, шары, frog, cursor, killzone, explosion, HUD, fonts, dialogs.
  - `main menu` - полноэкранное меню и его кнопки.
  - `level select` - фон выбора уровня, кнопки, badges, preview.
  - `more games` - отдельный полноэкранный экран.
- Профили могут переиспользовать один и тот же RAM_G диапазон только если при входе в комнату весь нужный профиль заново загружается, а код не ожидает сохранности данных из другого профиля.
- Общие assets, которые должны жить между комнатами, нельзя размещать в диапазонах, которые комнаты перезаливают.
- Любой код, который временно мапит `PAGE3` не на `#04`, обязан делать это под `DI`, восстанавливать `PAGE3=#04`, затем `EI`.
- `main1_play` почти заполнен. Новые диагностические/загрузочные процедуры по возможности выносить в slot 0 или Core.

## 2. Z80 адресное пространство

Текущий стартовый layout:

| Slot | CPU range | Normal page | Владелец | Примечание |
|---|---:|---:|---|---|
| 0 | `#0000..#3FFF` | `#00` | TSLib + slot0 helpers | `TSLib.bin`, ORG `#1000`; +circular log/slot0 helpers (end `#3E71`). `FT.WriteMem` тут. |
| 1 | `#4000..#7FFF` | `#05` | Core | `Core.bin`, ORG `#5C00`; stack `#40F2`; resident vars; `VDC_ReadSampleAtHL`; loader-трамплины. FAT-загрузчик ВЫНЕСЕН в overlay (см. §3a). |
| 2 | `#8000..#BFFF` | `#06` | TrackData (chunkA) | Fallback L1 track / chunkA трека из PAK; загрузчик временно мапит сюда staging-страницы (`#03` буфер, `#07..#0E` bg) при чтении SD. |
| 3 | `#C000..#FFFF` | `#04` / `#40` | `main1_play` / loader overlay | Gameplay/menu/level-select (page #04, ⚠️ 18 байт свободно). Во время загрузки трамплин мапит сюда page **#40** = FAT-загрузчик RawPak (§3a). |

Фактические размеры (loader-overlay билд, `Build/zuma.sym` / `Build/*.bin`, срез 2026-05-27):

| Блок | Адрес | Размер | Диапазон |
|---|---:|---:|---:|
| `TSLib.bin` | `#1000` | 11890 (`#2E72`) | `#1000..#3E71` |
| `Core.bin` | `#5C00` | **2127** (`#84F`) | `#5C00..#644E` (FAT-загрузчик вынесен → ~6.9 КБ свободно до `#8000`) |
| `main1_play.bin` | `#C000` page #04 | 16366 (`#3FEE`) | `#C000..#FFED` — ⚠️ только 18 байт до переполнения page! |
| `loader_ovl.bin` | `#C000` page #40 | 4159 (`#103F`) | `#C000..#D03E` — RawPak loader, dormant вне загрузок (из 16 КБ страницы) |

> ⚠️ ЛОВУШКА SAVEBIN (DEVICE ZXSPECTRUM4096): main1_play (#04) и loader overlay (#40)
> ассемблируются на одном логическом `#C000`, но РАЗНЫХ физических страницах. Перед каждым
> `SAVEBIN` обязательно `SLOT n : PAGE m` (замапить нужную страницу), иначе SAVEBIN сдампит
> последнюю замапленную (overlay) в main1_play.bin → порча Main1 (поймано харнессом
> test_page3_inflate_guards). Код в хвосте main.asm.

SPG: **1284608 байт** (v041; v039 был 1284096). Был 1929216 у нерабочих билдов — раздутый SPG вешал WC-загрузчик; срезаны page #0F (бандл-драйвер) + `Dbg_DriverState` + превью вынесены в PAK. (NB: миф «размер SPG ломает загрузку» позже опровергнут — SF Слободчикова 3.17 МБ грузится; реальная причина наших фейлов — флака SD/битый блок. См. память `reference_zuma_vdac2_spg_size_breaks_wc_loader`.) `ZUMALVL.PAK` = 5587456 байт. Релиз теперь ПАПКА `releases/v041-2026-05-26-.../{ZUMA_VD2.SPG, ZUMALVL.PAK, README.txt}`.

Важные resident адреса (Core, slot 1, v041 по `Build/zuma.sym`; адреса ПЛАВАЮТ при росте Core — всегда сверять по свежему sym):

| Адрес | Владелец | Назначение |
|---:|---|---|
| `#4800..#5007` | log | circular F12/debug log. |
| `#5009..#500B` | frog randomizer | RTC mix/exclude flags. |
| `#5010` | FT command buffer pointer | `CMD_ADDRESS_PTR`; нельзя возвращать на `#6000`. |
| `#5020..#5040` | build canary | `ZVDAC2 ...`, пишется в `Init_Core`. |
| `#5044..#5047` | boot canary | `"BOOT"`, пишется ПЕРВОЙ инструкцией `Start` (#5C00). НЕНАДЁЖНА: затирается в геймплее; «нет канарейки» ≠ boot hang. |
| `#612E..#6130` | Core | `BgRamL/BgRamH`. |
| `#6481..#6482` | Core | `PauseFadeTimer`, `VDC_PauseAlpha` (пауза fade-out, state 4). |
| `#65FB` | Core | `ZiFi_GpDbgStep`; рядом `ZiFi_DbgGamesA` (`#6600`) + `Found` (диаг загрузчика PAK). |
| `#6A38` | Core | `VDC_ReadSampleAtHL` — page-aware чтение сэмпла трека (#06 если t<3276, иначе #0F). Вызывается per-frame из `VDC_SlotPos` (Main1) как tail-jump. |
| `#6AB1` | Core | `RawPak_TargetName`/`EntName` (LFN-буферы по 64 B), далее `RawPak_FatBuf` 512B (`#6B4F`). |
| `#6D4F..#6D53` | Core | `RawPak_PakLba` (LBA лог. сектора 0 PAK), `RawPak_LogCur`. |
| `#6D56` | Core | `ZiFi_LevelTOC` 20 bytes. |
| `#6E40..#6E42` | Core | `FadeAlpha`, `CurrentDifficulty`, `CurrentLevel`. |

Core (v041) = 5095 B (+214 B к v039): подключены параметры уровней из таблицы (`GetCurrentLevelSettingRecord` и геттеры скорости/цвета/lead-in), перенос счёта между уровнями, page-aware `VDC_ReadSampleAtHL` (вынесен из Main1, который полон). Свой FAT32-драйвер RawPak (CMD17 + LFN + двухфазный загрузчик) + `RawPak_FatBuf` 512B. `Source/ASM/sd_zc.asm` ВКЛЮЧЁН (CMD17-чтение SD). См. память `reference_zuma_vdac2_fat32_driver_rawpak`.

> ✅ СДЕЛАНО (2026-05-27): FAT-загрузчик RawPak — «резидентная задача» (отработал на
> загрузке → спит) — **вынесен из Core** в overlay-страницу #40 (slot 3), мапимую только на
> время загрузки. Резидентным в Core остались `VDC_ReadSampleAtHL` (per-frame) + cross-load
> vars + 2 трамплина (`loader_resident.asm`). Core 5095→2127. Локально проверено (gate). См. §3a.

Уже найденная ошибка: раньше `CurrentLevel/CurrentDifficulty/FadeAlpha` были объявлены вне Core и попали в TSLib/code область около `#1937..#1938`; это приводило к мусорному номеру уровня и зависанию ZiFi seek. Сейчас они в Core.

## 3. Временные Z80 pages

| Page | Использование | Статус |
|---:|---|---|
| `#01` | `SCRATCH_PAGE` для ZX7 unpack в `UnpackAndUploadPage` | Временно мапится в slot 3; после вызова restore `PAGE3=#04`. |
| `#03` | `ZIFI_BUFFER_PAGE` — 512-byte буфер RawPak (TOC, FAT-сектор каталога, палитра, SD-stream) | Временно мапится в slot 2. Не должен содержать постоянный SPG block. |
| `#04` | `main1_play` | Должен быть нормальным `PAGE3` вне критических loader sections. |
| `#06` | fallback track + chunkA трека из PAK (`TRACK_L01_PAGE`) | Нормальный `PAGE2` после `SetCurrentTrackPage`. Сэмплы `t<3276`. |
| `#07..#0E` | компилированный fallback L1 bg + staging для bg из PAK (SD-фаза пишет сюда L2+ bg, потом FT.WriteMem) | |
| `#0F` | **chunkB трека** (`TRACK_PAGE2`) — сэмплы `t>=3276` для длинных треков (>1 страницы 16K) | Рантайм-скретч (НЕ SPG block). Пишется SD-фазой загрузчика, читается `VDC_ReadSampleAtHL`. |

(Бандл TS-DOS драйвер на page `#0F` УБРАН в v039 — мы перешли на свой CMD17/RawPak. С v041 page `#0F` ПЕРЕИСПОЛЬЗОВАН как runtime-страница chunkB трека: в SPG её как block нет, но в рантайме она мапится в слот 2 при чтении/проигрывании длинного трека. См. `reference_zuma_vdac2_upper_levels_track_too_big`.)

## 3a. Свой FAT32-драйвер RawPak (актуально для v041)

Бандл-WC-драйвер (page #0F, CORE32 LOAD512) дрейфил ровно −128 секторов из SPG-контекста (stateful CORE32, stale high-word позиции при ремонте mount). Вместо его починки в v039 написан **свой self-contained FAT32-драйвер RawPak** (`Source/ASM/ts-dos.asm` RawPak_* + `sd_zc.asm` CMD17). Бандл-драйвер полностью убран (page #0F как block не в SPG; в v041 переиспользован под chunkB трека в рантайме — см. §3).

RawPak: CMD17 (одиночный сектор, #57/#77), BPB superfloppy (bps=512 spc=1 reserved=32 fats=2 fatsz=1601 root=2 datastart=3234), свой FAT-walk (`FatNext`: cluster>>7+FatStart, отдельный `FatBuf`), LFN-сопоставление имён, двухфазная загрузка SD→FT (FT812+SD на одной SPI-шине). Полный разбор внутренностей и граблей — память `reference_zuma_vdac2_fat32_driver_rawpak`.

Два пути чтения:
- **Общий (FAT-walk):** `RawPak_AdvanceOne`/`RawPak_FatNext` (+ `RawPak_ReadSectors`/`SkipB`, ныне legacy) — идёт по FAT-цепочке, поддерживает фрагментацию. Используется для обхода каталога (`FindInCurrentDir`). TOC читается уже быстрым путём.
- **Быстрый (таблица секторов):** `RawPak_ReadOneLogicalIX` через кэш `RawPak_PakLba`, `LBA = PakLba + N`. **Допущение непрерывности** файла. Это путь геймплейного загрузчика (`LoadGameplayLevelSpecificFromPack`) — даёт чтение секции одним SD-burst без пер-секторного FAT-walk.

✅ ВЕРХНИЕ УРОВНИ ПОЧИНЕНЫ (v041). Корень был **НЕ фрагментация** (PAK физически непрерывен, проверено `check_pak_chain.py`), а лимит «трек ≤ 1 страница 16K»: загрузчик отвергал трек ≥33 секторов (`CP 33`). Падали L04/07/16/17/18/20-22. Фикс — трек на 2 страницы (chunkA #06 + chunkB #0F, см. §3/§8). Память `reference_zuma_vdac2_upper_levels_track_too_big`.

⚠️ ОТКРЫТО (текущая задача): требование юзера — читать **и непрерывный, и сегментированный (фрагментированный)** PAK. Сейчас геймплейный путь полагается на `LBA=PakLba+N` (непрерывность); пока PAK непрерывен — работает, но фрагментация сломает чтение. План: **мультиран-таблица секторов** — при открытии PAK пройти FAT-цепочку, построить список экстентов (runs) {LBA, len}, и `RawPak_ReadOneLogicalIX` транслирует логический сектор → физический LBA через таблицу (непрерывный = 1 run; фрагментированный = несколько). Для дешёвого построения добавить кэш FAT-сектора в `FatNext`.

## 4. FT812 RAM_G: gameplay profile

| Диапазон | Владелец | Источник |
|---:|---|---|
| `#000000..#003FFF` | `TEXT_GAMEOVER` | page `#20`, ZX7, ARGB4. |
| `#004000..#007FFF` | `TEXT_LEVEL11` | page `#21`, ZX7, ARGB4. |
| `#008000..#00BFFF` | `TEXT_SPIRALDOOM/OSPREY` | page `#22/#23`, ZX7, ARGB4. |
| `#00C000..#00FFFF` | `SPARKLE` | page `#24`, ZX7, ARGB4. |
| `#010000..#02D4FF` | gameplay background | 400x300 PALETTED4444 indices, 120000 bytes. |
| `#02D500..#02D6FF` | gameplay bg palette | 512 bytes ARGB4. |
| `#02D800..#02FFFF` | dialog OK button | raw PALETTED4444. |
| `#030000..#04FFFF` | frog ARGB4 layers | body/plate/tongue/overlay, 4 x 32K upload blocks. |
| `#050000..#07FFFF` | balls ARGB4 atlas | 192K, pages `#2D..#38`. |
| `#080000..#0801FF` | balls palette legacy slot | Сейчас ARGB4 balls не используют palette, но адрес занят концептуально. |
| `#080200..#0803FF` | frame palette | 512 bytes. |
| `#084000..#097FFF` | frame strips | top/bottom/left/right, 5 x 16K upload blocks. |
| `#098000..#09FFFF` | native font | pages `#68..#69`. |
| `#0A0000..#0A3FFF` | Cancun10 stats font | page `#6A`. |
| `#0A4000..#0ABFFF` | Cancun8 font | pages `#6B..#6C`. |
| `#0AC000..#0CBFFF` | dialog frame | 8 x 16K upload blocks. |
| `#0CC000..#0CC1FF` | HUD life frog | 400 bytes, raw. |
| `#0CC200..#0CC3FF` | HUD palette | 512 bytes. |
| `#0CC400..#0CC5FF` | dialog palette | 512 bytes. |
| `#0CC800..#0CE3FF` | HUD menu atlas | raw PALETTED4444. |
| `#0CE400..#0CFFFF` | HUD progress atlas | raw PALETTED4444. |
| `#0D0000..#0D3FFF` | gameplay cursor upload block | cursor itself small, rest padded zeros. |
| `#0D4000..#0EBFFF` | killzone atlas | `KZ_PAGE_COUNT=10` includes killzone + destroy upload sequence. |
| `#0EC000..#0F9FFF` | destroy atlas handle source | Overlaps tail of previous 10-page upload by design because destroy starts at page `#1C`. |

Текущая неоднозначность: `KZ_PAGE_COUNT=10` starts at `#0D4000`, so upload covers `#0D4000..#0FBFFF`; `DESTROY_RAMG_ADDR=#0EC000` lies inside that same contiguous upload. This is intentional only if code treats killzone+destroy as one contiguous combined upload.

## 5. FT812 RAM_G: menu/room profiles

Main menu:

| Диапазон | Владелец |
|---:|---|
| `#000000..#04AFFF` | main menu foreground/canvas chunks. |
| `#04B000..#06517F` | sky strip. |
| `#065180..#0ABA5F` | sun/glow/buttons. |
| `#0ABA60..#0ABBFF` | sky palette. |
| `#0ABC60..#0ABE5F` | UI palette. |
| `#0AC000..#0ADFFF` | cursor. |

Level select:

| Диапазон | Владелец |
|---:|---|
| `#000000..#04AFFF` | level-select background. |
| `#04B000..#06517F` | level-select sky strip. |
| `#065180..#082657` | buttons and difficulty badges. |
| `#0ABA60..#0ABBFF` | sky palette. |
| `#0ABC60..#0ABE5F` | UI palette. |
| `#0AC000..#0ADFFF` | cursor reused from menu. |
| `#0B0000..#0B20B1` | preview frog + killzone markers. |
| `#0D4000..#0EA57F` | selected preview bitmap, 280x170 ARGB4. |

More Games:

| Диапазон | Владелец |
|---:|---|
| `#000000..#04AFFF` | full-screen promo canvas chunks. |
| `#0ABC60..#0ABE5F` | palette. |

## 6. Текущие конфликты и красные зоны

1. `LS_PREVIEW_BG_RAMG=#0D4000` совпадает с gameplay `KZ_RAMG_ADDR=#0D4000`.
   Это допустимо только как room-profile reuse. Нельзя считать preview постоянным asset и нельзя стартовать gameplay без полной перезагрузки killzone/destroy.

2. `LS_PREVIEW_FROG_RAMG=#0B0000` в level-select profile находится внутри gameplay dialog/font/frog-paletted legacy зоны. Сейчас gameplay ARGB4 frog живет в `#030000..#04FFFF`, но область `#0B0000` все равно не должна считаться общей.

3. `MENU_CURSOR_RAMG`, `LS_CURSOR_RAMG` и gameplay `DIALOG_FRAME_RAMG` используют `#0AC000` в разных профилях. Это нормальный reuse, но только при полной перезаливке профиля.

4. `main1_play` свободен только на **18 байт** (v041). Любая новая логика в page `#04` переполнит страницу → corruption. Новые процедуры — в slot 0 (TSLib) или Core, либо (для загрузчика) в отдельную overlay-страницу.

5. [OBSOLETE для v039] Старый `ZiFi_StreamSection` (стрим в RAM_G с чередованием SD/FT) заменён **двухфазным загрузчиком** (`LoadGameplayLevelSpecificFromPack`): сначала ВСЯ SD-фаза в RAM, потом FT-фаза. FT812+SD на одной SPI-шине #57/#77 — чередование крашит, отсюда разделение. Подробно: память `reference_zuma_vdac2_fat32_driver_rawpak`.

6. [OBSOLETE для v039] Превью L01-L22 ВЫНЕСЕНЫ в PAK (v038); страницы `#CC..#FA` закомментированы в `spgbld_vdac2.ini`. (Исторически: были SPG-resident zlib на `#CC..#FA` с page-local offset `#0200`, чтобы первые 512 байт держались подальше от raw zlib-опкодов при загрузке SPG.)

## 7. SPG pages: основные владельцы

| Pages | Владелец |
|---:|---|
| `#00` | `TSLib.bin`. |
| `#04` | `main1_play.bin`. |
| `#05` | `Core.bin`. |
| `#06` | fallback level 1 track (chunkA трека из PAK в рантайме). |
| `#07..#0E` | fallback level 1 background pages. |
| `#0F` | НЕ SPG block. Рантайм-страница chunkB длинного трека (`TRACK_PAGE2`). Бандл-драйвер `WDFCVBI2.COD` убран в v039. |
| `#11` | fallback level 1 background palette. |
| `#16..#1F` | killzone + destroy atlases. |
| `#20..#24` | gameplay text/sparkle atlases. |
| `#2D..#39` | balls atlas + legacy palette page. |
| `#3A..#3F` | frame strips + frame palette. |
| `#52..#5A` | frog layers + cursor. |
| `#5B..#6D` | HUD/dialog/fonts. |
| `#70..#93` | main menu assets. |
| `#94..#BB` | level-select screen/buttons/badges/markers. |
| `#BC/#BF/#C2/#C5/#C8/#CB` | More Games. |
| `#CC..#FA` | — (ВЫНЕСЕНЫ в PAK в v038: превью L01-L22 закомментированы в `spgbld_vdac2.ini`, грузятся из `ZUMALVL.PAK`). |

Проверка на 2026-05-27: прямых дублей `Block` pages в `spgbld_vdac2.ini` нет (141 занятая страница).

**Свободные SPG-страницы** (для overlay-загрузчика и будущих assets), срез 2026-05-27 по `spgbld_vdac2.ini`:

`#02, #10, #12-#15, #25-#2C, #41-#51, #6E-#6F, #71, #73, #75-#76, #78-#79, #7B-#7C, #7E-#7F, #96, #98, #9A, #9C, #9E-#9F, #BD-#BE, #C0-#C1, #C3-#C4, #C6-#C7, #C9-#CA, #CC-#FA`

Крупные непрерывные дыры: `#25-#2C` (8), `#41-#51` (17), `#CC-#FA` (47 — бывшие превью, теперь в PAK). Занятые с 2026-05-27: **`#40`** = loader overlay (RawPak). Рантайм-скретч (НЕ выделять как постоянный block): `#01` (ZX7 unpack), `#03` (RawPak буфер), `#0F` (chunkB трека).

## 8. ZUMALVL.PAK

Формат:

- sector 0: header `ZLVP`, version 1, level_count 22, sector size 512.
- sector 1: TOC, 22 entries x 20 bytes.
- sector 2..N: data blob, per level: bg, palette, track, title, preview.

Секции на уровень:

| Section | Назначение | Runtime target |
|---|---|---|
| `bg` | 8 x 16K PALETTED4444 index pages | `BG_RAMG_ADDR=#010000`. |
| `pal` | 512-byte ARGB4 palette | `BG_PALETTE_RAMG=#02D500`. |
| `track` | canonical 640x480 track | chunkA → `TRACK_L01_PAGE=#06` (сэмплы <3276), chunkB → `TRACK_PAGE2=#0F` (>=3276). Pack-стадия `make_level_pack.pagesplit_track` бьёт трек по сэмпл-границе; загрузчик принимает ≤64 сектора (`CP 65`). |
| `title` | ZX7 text title | Сейчас preview titles рисуются live text; section есть в паке. |
| `preview` | raw ARGB4 preview pages | Грузятся из PAK в level-select (вынесены из SPG в v038). |

Текущее состояние (v041): `LoadGameplayLevelSpecificFromPack` АКТИВЕН — двухфазно (SD→FT) стримит bg/pal/track из PAK (CMD17 + LFN). **Все 22 уровня грузятся** (фикс «трек на 2 страницы»). bg = ровно 256 секторов (8×16K, валидируется), track ≤64 секторов, pal = 1 сектор. Геймплейный путь использует быструю таблицу (`LBA=PakLba+N`) — пока PAK непрерывен. При `CF=0` — fallback на компилированный L1. Открыто: поддержка фрагментированного PAK (см. §3a).

## 9. Что проверить перед исправлением загрузки уровней

### Текущая задача (2026-05-27): вынос загрузчика из Core + сегментированный PAK

1. **Вынести RawPak из Core** в overlay-страницу (свободные — §7). Резидентным остаётся только `VDC_ReadSampleAtHL` (per-frame). Проблема execution-slot: загрузчик грузит данные в slot 2 (#8000) и зовёт `FT.WriteMem` (TSLib, slot 0) → сам код не может жить в slot 2/0; нужен резидентный в Core диспетчер-трамплин, который мапит overlay-страницу и зовёт её.
2. **Сегментированный PAK**: мультиран-таблица (см. §3a) + кэш FAT-сектора в `FatNext`. Регрессия на непрерывном образе обязана совпасть с `LBA=PakLba+N`.
3. **Тест локально, не на хосте** (юзер платит за сессии): `Source/OTHER/test_rawpak_z80.py` гоняет реальный Z80 RawPak против FAT-образа (`Build/test_wc.img`). Желательно собрать фрагментированный тест-образ. Доп.: `verify_lfn_walk.py`, `check_pak_chain.py`, `check_host_wc_img.py`.

### Историческая методичка (OBSOLETE для v041 — старый ZiFi-стриминг с чередованием SD/FT)

1. Не чинить ZiFi streaming вслепую. Сначала добавить маленький controlled harness/dump marker в Core/slot0, не в `main1_play`.
2. При входе в `ZiFi_StreamSection` логировать:
   - `PAGE0..PAGE3`,
   - `SP`,
   - `DE remaining`,
   - chunk size,
   - `BgRamH:BgRamL`,
   - return адрес до/после `FT.WriteMem`.
3. Перед `CALL FT.WriteMem` гарантировать `PAGE0=#00` и `PAGE3=#04` или явно документированную source page.
4. После `FT.WriteMem` восстановить `PAGE0=#0F` только если следующий вызов действительно ZiFi driver.
5. Не использовать stack в page, который может быть перезатерт streaming/load512.
6. После успешного stream bg/pal/track обязательно восстановить normal mapping: `PAGE0=#00`, `PAGE2=track page`, `PAGE3=#04`.
7. После восстановления ZiFi loader вернуть L02+ не через compiled fallback, а через pack section targets.
