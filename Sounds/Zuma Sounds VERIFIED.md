# Выверенная карта звуков Zuma — по исходникам, не по Wiki

Составлено сверкой ТРЁХ источников (2026-06-12):
1. **HD-исходники** `Zuma-Deluxe-HD-release-v010-ref/src` — точный механизм
   срабатывания, НО это ремейк с УПРОЩЁННЫМ звуком (часть событий оригинала
   выпилена — см. колонку «HD-ремейк»).
2. **Наш порт** `Source/ASM` — что реально вызывается (GS_PlaySfx).
3. **`Zuma Sounds.md`** (Wiki) — для понимания ОРИГИНАЛА; местами неточна.

Маппинг ID→файл в HD: enum `_SoundID` (алфавитный) индексирует `filesSounds[38]`.
Музыка — один трекерный модуль `zuma.mo3`, MUS_* = order-позиции:
MUS_GAME=0, MUS_NEAR_HOLE=36, MUS_WIN=38, MUS_GAME_OVER=39.

---

## ⭐ Звук взрыва матч-3 (про что было сомнение)

**Wiki-карта НЕТОЧНА.** Она разносит `ballsdestroyed1..5` («вариация 1-5») и
`chime1` («match-3 stinger») как два независимых события. На деле при КАЖДОМ
взрыве группы (`BallChain_ExplodeBalls`, BallChain.c:454-476) играют ОБА
ОДНОВРЕМЕННО:
- `ballsdestroyed{N}.ogg`, где **N выбирается по уровню комбо** (0/1/2/3/4+),
  а не случайно;
- `chime1.ogg` с **питчем = 2×combo** полутонов (0/2/4/6/8).

**Наш порт уже делает ровно это** ([VDC.asm:1805](../Source/ASM/VDC.asm:1805)
`BALLSDESTROYED1+combo` + [VDC.asm:1815](../Source/ASM/VDC.asm:1815)
`CHIME1` через `GS_PlaySfxNote` с нотой `combo*2`). ✅ Совпадает.

---

## Полная карта: событие → звук → статус у нас

| Событие (момент) | HD-ремейк | Оригинал (Wiki) | Наш порт | Статус |
| :--- | :--- | :--- | :--- | :--- |
| Кнопка меню (press) | button1 | button1 | SND_BUTTON1 (Menu/LevelSelect) | ✅ |
| Наведение на кнопку (hover) | — | button2 | таблица ts-dos.asm:2270-71 | ✅ есть |
| Музыка меню | (mo3) | mo3 | GS menu music (ZUMAAUD.PAK) | ✅ |
| Старт уровня | chant1 + MUS_GAME | chant1 | SND_CHANT1 ([VDC.asm:547](../Source/ASM/VDC.asm:547)) | ⚠️ нет game-музыки |
| Интро (искра-трейл к черепу) | lighttrail2 (питч −1/повтор) | lighttrail2 | — | ❌ нет |
| Конец интро / выкат цепи | rolling (старт) | rolling | SND_ROLLING ([VDC.asm:587](../Source/ASM/VDC.asm:587)) | ✅ |
| Цепь заполнена → стоп выката | stop rolling | — | SND_SILENCE ([VDC.asm:619](../Source/ASM/VDC.asm:619)) | ✅ |
| Выстрел шара | fireball1 | fireball1 | SND_FIREBALL1 ([Bullet.asm:69](../Source/ASM/Bullet.asm:69)) | ✅ |
| Смена шара во рту (правый клик) | pop? | pop | — | ❓ проверить |
| Попадание шара в цепь | ballclick2 | ballclick2 | SND_BALLCLICK2 ([Bullet.asm:252](../Source/ASM/Bullet.asm:252)) | ✅ |
| Стыковка разорванной цепи | ballclick1 | ballclick1 | SND_BALLCLICK1 ([VDC.asm:2350](../Source/ASM/VDC.asm:2350)) | ✅ pull |
| Взрыв матч-3 | ballsdestroyed{combo}+chime1{pitch} | (см. выше) | ✅ оба | ✅ |
| Chain bonus (≥5) | **не используется** | chain1 | SND_CHAIN1 ([VDC.asm:1882](../Source/ASM/VDC.asm:1882)) | ✅ мы ближе к ориг. |
| Gap bonus (сквозь просвет) | gapbonus1 | gapbonus1 | SND_GAPBONUS1 ([main.asm:3894](../Source/ASM/main.asm:3894)) | ✅ |
| **Шкала заполнена (ZUMA)** | **chant4** | **choral1 (хор)** | SND_CHORAL1 ([VDC.asm:1916](../Source/ASM/VDC.asm:1916)) | ⚠️ см. ниже |
| Extra life (50k) | extralife | extralife | SND_EXTRALIFE ([main.asm:2015](../Source/ASM/main.asm:2015)) | ✅ |
| **WIN-триггер (посл. шар)** | MUS_WIN (музыка) | — | — | ❌ нет |
| WIN-аутро: попы вдоль трека | endoflevelpop1 ×N (+100 каждый) | endoflevelpop1 | SND_ENDOFLEVELPOP1 ([main.asm:3650](../Source/ASM/main.asm:3650)) | ✅ |
| **WIN-аутро конец** | **chant2** | chant2 | — | ❌ нет |
| **LOSE: шар дошёл до черепа** | тишина | **earthquake** | — | ❌ (см. ниже) |
| Опасность у черепа (сирена) | **не используется** | warning1 | — | ❌ нет |
| LOSE: всасывание шаров в череп | тишина | **pop с растущим питчем** | — | ❌ нет |
| **LOSE: цепь слилась, есть жизни** | **chant14** | chant14 | — | ❌ нет |
| **GAME OVER (0 жизней)** | **chant8 + MUS_GAME_OVER** | chant8 | — | ❌ нет |
| Приземление лягушки (старт/смерть) | **не используется** | frogland2 | — | ❌ нет |
| Сбор монеты | coingrab | coingrab | — | (монет нет) |
| Появление/исчез. монеты | jewelappear/gemvanishes | — | — | (монет нет) |

---

## Главные пробелы нашего порта (для решения)

### A. Финальные чанты конца уровня — ОТСУТСТВУЮТ
Нигде не вызываются `CHANT2` (win-аутро конец), `CHANT4` (альт. шкалы),
`CHANT8` (game over), `CHANT14` (потеря жизни) — хотя загружены в пак.
Это самый заметный пробел: концовки уровня сейчас без голосового акцента.
Дёшево добавить — сэмплы уже в ZUMAAUD.PAK, нужны 4 вызова GS_PlaySfx в
точках win-outro-конец / lose-restart / game-over.

### B. Игровая музыка — ОТСУТСТВУЕТ
Есть только музыка меню (`GS_InitAndStartMenuMusic`); при входе в уровень
[main.asm:3256](../Source/ASM/main.asm:3256) `GS_StopMenuMusic` — и в игре
тишина (только SFX). HD играет `MUS_GAME` (order 0 zuma.mo3) в цикле +
переключения на MUS_WIN / MUS_GAME_OVER. Дорого: нужен трек в ZUMAAUD.PAK
и переключение order'ов. — Решение за тобой.

### C. LOSE-секвенция — у HD НЕЛЬЗЯ копировать
HD-ремейк УПРОСТИЛ: при достижении черепа — тишина, всасывание — тишина.
В ОРИГИНАЛЕ (Wiki + здравый смысл): `earthquake` (тряска), `warning1`
(сирена при опасности), всасывание шаров — `pop` с нарастающим питчем.
Сэмплы у нас есть (earthquake/warning1/pop загружены). Для аутентичности
ориентир — оригинал, не HD. — Нужно твоё ухо: как в оригинале точно.

### D. Спорное: шкала заполнена (ZUMA)
Мы играем `choral1` (хор «Zuma!»), HD — `chant4`. Wiki подтверждает choral1
как «достижение ZUMA». **Наш вариант, вероятно, аутентичнее HD** — менять
не стоит без твоего слуха.

### E. Мелочи на проверку
- Интро-«искра» `lighttrail2` (питч понижается) — у нас не озвучена.
- Смена шара во рту по правому клику — `pop`; есть ли у нас звук?
- Приземление лягушки `frogland2` — не озвучено.
