# Программное профилирование производительности на ZX Evolution с FT812 (VDAC2)

## Руководство по измерению тактов кадра при активном экране FT812

---

## 📋 Оглавление

1. [Проблема](#проблема)
2. [Программные способы профилирования](#программные-способы-профилирования)
3. [Способ 1: REG_CLOCK FT812](#способ-1-reg_clock-ft812-рекомендуется)
4. [Способ 2: Отображение результата на FT812](#способ-2-отображение-результата-на-ft812)
5. [Способ 3: Z80 R-регистр](#способ-3-z80-r-регистр)
6. [Способ 4: Прерывания 50 Hz](#способ-4-прерывания-50-hz)
7. [Способ 5: TS-Config LINE/VSINT](#способ-5-ts-config-linevsint)
8. [Полное решение](#полное-решение-для-zuma)
9. [Сравнение методов](#сравнение-методов)
10. [Регистры FT812](#полезные-регистры-ft812)

---

## Проблема

При работе с **VDAC2 (FT812)** на ZX Evolution:

- ❌ FT812 полностью забирает видеовыход
- ❌ Экран TS-Config отключен
- ❌ Бордюр через `OUT (#FE), A` НЕ ВИДЕН
- ❌ Классические методы профилирования ZX Spectrum не работают

### Что доступно:
- ✅ Видим только то, что рендерит FT812
- ✅ Z80 продолжает работать
- ✅ TS-Config работает (но его вывод не виден)
- ✅ FT812 имеет встроенные счетчики

---

## Программные способы профилирования

При активном FT812 нужны **специальные методы**, не зависящие от видимого экрана TS-Config.

---

## Способ 1: REG_CLOCK FT812 (РЕКОМЕНДУЕТСЯ)

FT812 имеет встроенный **32-битный счетчик тактов**, работающий на **60 МГц**.

### Регистры:

```asm
REG_CLOCK   EQU #302008  ; 32-bit счетчик тактов (60 МГц)
REG_FRAMES  EQU #302004  ; 32-bit счетчик кадров
```

### Преимущества:
- ✅ Высокая точность (60 МГц = ~16.6 нс на такт)
- ✅ 32-битный счетчик (не переполняется ~71 секунду)
- ✅ Работает независимо от Z80
- ✅ Доступен через SPI

### Чтение REG_CLOCK:

```asm
; ----------------------------------------------------------------
; Читаем REG_CLOCK в HLDE (32 бита)
; HL = старшие 16 бит, DE = младшие 16 бит
; ----------------------------------------------------------------
ReadFT812Clock:
    ; CS_N = 0 (активация FT812)
    CALL FT812_CS_Low
    
    ; Команда READ + 22-bit адрес 0x302008
    LD A, #30          ; (адрес >> 16) | 0x00 (READ command)
    CALL SPI_Send
    LD A, #20
    CALL SPI_Send
    LD A, #08
    CALL SPI_Send
    LD A, #00          ; Dummy byte
    CALL SPI_Send
    
    ; Читаем 4 байта (little-endian)
    CALL SPI_Read : LD E, A
    CALL SPI_Read : LD D, A
    CALL SPI_Read : LD L, A
    CALL SPI_Read : LD H, A
    
    CALL FT812_CS_High
    RET
```

### Профилирование секции:

```asm
ProfileSection:
    ; Сохраняем начальное значение CLOCK
    CALL ReadFT812Clock
    LD (StartClockLo), DE
    LD (StartClockHi), HL
    
    ; === ЗАМЕРЯЕМЫЙ КОД ===
    CALL UpdatePhysics
    ; ======================
    
    ; Читаем конечное значение
    CALL ReadFT812Clock
    
    ; Вычисляем разницу (HLDE - StartClock)
    CALL CalcDelta
    
    ; Сохраняем результат
    LD (PhysicsTicks), DE
    LD (PhysicsTicksHi), HL
    RET

CalcDelta:
    PUSH HL
    EX DE, HL
    LD BC, (StartClockLo)
    OR A
    SBC HL, BC          ; младшие 16 бит
    EX DE, HL
    
    POP HL
    LD BC, (StartClockHi)
    SBC HL, BC          ; старшие 16 бит
    RET

StartClockLo:    DW 0
StartClockHi:    DW 0
PhysicsTicks:    DW 0
PhysicsTicksHi:  DW 0
```

### Конвертация в миллисекунды:

```
1 такт FT812 = 1 / 60,000,000 секунды
            = 16.67 нс

1 мс = 60,000 тактов FT812
1 кадр (16.67 мс) = ~1,000,000 тактов FT812

Пример: PhysicsTicks = 45,000
45,000 / 60,000 = 0.75 мс
```

---

## Способ 2: Отображение результата на FT812

Поскольку видно только FT812, выводим результат **через него**.

### Команда CMD_NUMBER:

FT812 имеет команду для отображения чисел:

```c
CMD_NUMBER(x, y, font, options, number)
```

Параметры:
- `x, y` - координаты (16-bit each)
- `font` - номер шрифта (16-28)
- `options` - 0 = normal, OPT_SIGNED для знаковых
- `number` - число для отображения (32-bit)

### Реализация на ассемблере:

```asm
; ----------------------------------------------------------------
; Отображение числа PhysicsTicks через FT812
; ----------------------------------------------------------------
ShowProfileResults:
    ; Заполняем команду CMD_NUMBER в буфер
    LD HL, FT812_CmdBuffer
    
    ; Опкод CMD_NUMBER = 0xFFFFFF2E
    LD A, #2E
    LD (HL), A : INC HL
    LD A, #FF
    LD (HL), A : INC HL
    LD A, #FF
    LD (HL), A : INC HL
    LD A, #FF
    LD (HL), A : INC HL
    
    ; X = 10 (16-bit)
    LD A, 10
    LD (HL), A : INC HL
    XOR A
    LD (HL), A : INC HL
    
    ; Y = 10 (16-bit)
    LD A, 10
    LD (HL), A : INC HL
    XOR A
    LD (HL), A : INC HL
    
    ; Font = 28
    LD A, 28
    LD (HL), A : INC HL
    XOR A
    LD (HL), A : INC HL
    
    ; Options = 0
    XOR A
    LD (HL), A : INC HL
    LD (HL), A : INC HL
    
    ; Number = (PhysicsTicks) - 32-bit
    LD DE, (PhysicsTicks)
    LD (HL), E : INC HL
    LD (HL), D : INC HL
    LD DE, (PhysicsTicksHi)
    LD (HL), E : INC HL
    LD (HL), D : INC HL
    
    ; Отправляем в FT812 CMD FIFO
    CALL SendCmdBuffer
    RET
```

### Результат на экране:

```
┌─────────────────────────────────┐
│  Physics: 45234                 │ ← тактов FT812
│  Draw:    23567                 │
│  Total:   68801                 │
│                                  │
│         ИГРОВОЙ ЭКРАН            │
│         (Zuma)                   │
│                                  │
└─────────────────────────────────┘
```

### Визуальный график:

```c
// Полоска в нижней части экрана
void draw_performance_bar(uint16_t physics, uint16_t draw, uint16_t ft812_time) {
    uint16_t total_ticks = 1000000;  // ~1 кадр в тактах FT812
    
    int physics_w = (physics * 640) / total_ticks;
    int draw_w = (draw * 640) / total_ticks;
    int ft812_w = (ft812_time * 640) / total_ticks;
    
    // Красная = физика
    FT81x_Cmd_DL(COLOR_RGB(255, 0, 0));
    FT81x_Cmd_DL(BEGIN(RECTS));
    FT81x_Cmd_DL(VERTEX2F(0, 470 * 16));
    FT81x_Cmd_DL(VERTEX2F(physics_w * 16, 480 * 16));
    
    // Зеленая = отрисовка
    FT81x_Cmd_DL(COLOR_RGB(0, 255, 0));
    FT81x_Cmd_DL(VERTEX2F(physics_w * 16, 470 * 16));
    FT81x_Cmd_DL(VERTEX2F((physics_w + draw_w) * 16, 480 * 16));
    
    // Желтая = FT812
    FT81x_Cmd_DL(COLOR_RGB(255, 255, 0));
    FT81x_Cmd_DL(VERTEX2F((physics_w + draw_w) * 16, 470 * 16));
    FT81x_Cmd_DL(VERTEX2F((physics_w + draw_w + ft812_w) * 16, 480 * 16));
    
    FT81x_Cmd_DL(END());
}
```

---

## Способ 3: Z80 R-регистр

Для замера **Z80 кода** не нужен FT812 вообще.

### Принцип:

R-регистр Z80 — это **счетчик памяти обновления**, инкрементируется на **каждой команде**.

```asm
GameLoop:
    ; --- Начало замера физики ---
    LD A, R
    LD (StartR), A
    
    CALL UpdatePhysics
    
    LD A, R
    LD B, A
    LD A, (StartR)
    NEG
    ADD A, B
    LD (PhysicsR), A     ; Команды для физики (M1-циклы)

StartR:    DB 0
PhysicsR:  DB 0
```

### Особенности:
- ✅ Точность ±1 команда Z80
- ✅ Не требует FT812
- ⚠️ Только 7 бит (256 значений макс)
- ⚠️ Считает M1-циклы (не такты)

### Расширенный счетчик:

```asm
; Счетчик для длинных операций (16-bit)
ExtendedMeasure:
    LD A, R
    LD (LastR), A
    LD HL, 0
    LD (TickCount), HL
    
    ; Внутри основного цикла периодически вызываем:
.check_loop:
    LD A, R
    LD B, A
    LD A, (LastR)
    LD (LastR), B          ; Обновляем
    NEG
    ADD A, B               ; Разница
    LD C, A
    LD B, 0
    LD HL, (TickCount)
    ADD HL, BC
    LD (TickCount), HL
    RET

LastR:     DB 0
TickCount: DW 0
```

### Преобразование M1 → такты:

```
Среднее время M1-цикла:
- NOP: 4 такта (1 M1)
- LD A,n: 7 тактов (2 M1)
- LD HL,nn: 10 тактов (3 M1)

Примерно: 1 M1 ≈ 3-4 такта Z80
```

---

## Способ 4: Прерывания 50 Hz

Используем стандартные прерывания TS-Config (50 Гц = 20 мс).

### Реализация:

```asm
ORG #38   ; Стандартный IM 1 вектор
    PUSH AF
    LD A, (FrameCounter)
    INC A
    LD (FrameCounter), A
    POP AF
    EI
    RETI

FrameCounter: DB 0

; В коде:
StartMeasure:
    XOR A
    LD (FrameCounter), A
    EI
    RET

EndMeasure:
    DI
    LD A, (FrameCounter)
    ; A = количество прерываний (1 = 20мс)
    EI
    RET
```

### Особенности:
- ✅ Простота
- ⚠️ Точность только 20 мс
- ⚠️ Подходит для длинных операций (загрузка уровней и т.п.)

---

## Способ 5: TS-Config LINE/VSINT

TS-Config может генерировать прерывания на **определенной строке экрана**.

### Регистры:

```asm
HSINT   EQU #22AF  ; Horizontal INT Position (0-223)
VSINTL  EQU #23AF  ; Vertical INT Position low
VSINTH  EQU #24AF  ; Vertical INT Position high
INTMask EQU #2AAF  ; INT Enable Mask
```

### Настройка:

```asm
SetupLineINT:
    ; Включаем LINE interrupt
    LD BC, INTMask
    LD A, %00000010    ; LINE bit
    OUT (C), A
    
    ; Прерывание на каждой строке
    LD BC, HSINT
    LD A, 100          ; Позиция X=100
    OUT (C), A
    RET

LineINT:
    PUSH AF
    PUSH HL
    LD HL, (LineCounter)
    INC HL
    LD (LineCounter), HL
    POP HL
    POP AF
    EI
    RETI

LineCounter: DW 0
```

### Точность:
- ~64 мкс на строку
- Идеально для замера среднего диапазона

---

## Полное решение для Zuma

```asm
DEVICE ZXSPECTRUM128
    OPT --syntax=ab

; ================================================================
; PROFILER для Zuma на ZX Evolution с активным FT812 (VDAC2)
; ================================================================

REG_CLOCK   EQU #302008
REG_FRAMES  EQU #302004

ORG #6000

Entry:
    DI
    LD SP, #BFFF
    
    ; Инициализация FT812
    CALL InitFT812
    
    EI
    IM 1

MainLoop:
    HALT  ; Синхронизация с кадром
    
    ; === Замер физики через REG_CLOCK ===
    CALL ReadFT812Clock
    LD (StartClockL), DE
    LD (StartClockH), HL
    
    CALL UpdatePhysics
    
    CALL ReadFT812Clock
    CALL CalcDelta
    LD (PhysicsTicks), DE
    LD (PhysicsTicksH), HL
    
    ; === Замер отрисовки ===
    CALL ReadFT812Clock
    LD (StartClockL), DE
    LD (StartClockH), HL
    
    CALL DrawScene
    
    CALL ReadFT812Clock
    CALL CalcDelta
    LD (DrawTicks), DE
    LD (DrawTicksH), HL
    
    ; === Замер общего времени кадра ===
    CALL ReadFT812Clock
    LD (StartClockL), DE
    LD (StartClockH), HL
    
    CALL UpdateFT812
    
    CALL ReadFT812Clock
    CALL CalcDelta
    LD (FT812Ticks), DE
    LD (FT812TicksH), HL
    
    ; === Отрисовка статистики на FT812 ===
    CALL ShowStatsOnFT812
    
    JR MainLoop

; ----------------------------------------------------------------
; Чтение REG_CLOCK (32 бита) в HLDE
; ----------------------------------------------------------------
ReadFT812Clock:
    CALL FT812_CS_Low
    
    LD A, #30          ; READ + addr[23:16] = 0x30
    CALL SPI_Send
    LD A, #20          ; addr[15:8]
    CALL SPI_Send
    LD A, #08          ; addr[7:0]
    CALL SPI_Send
    LD A, #00          ; Dummy
    CALL SPI_Send
    
    CALL SPI_Read : LD E, A
    CALL SPI_Read : LD D, A
    CALL SPI_Read : LD L, A
    CALL SPI_Read : LD H, A
    
    CALL FT812_CS_High
    RET

; ----------------------------------------------------------------
; Вычисление HLDE - StartClock в HLDE
; ----------------------------------------------------------------
CalcDelta:
    PUSH HL
    EX DE, HL
    LD BC, (StartClockL)
    OR A
    SBC HL, BC
    EX DE, HL
    
    POP HL
    LD BC, (StartClockH)
    SBC HL, BC
    RET

; ----------------------------------------------------------------
; Отображение статистики на FT812
; ----------------------------------------------------------------
ShowStatsOnFT812:
    ; CMD_DLSTART
    CALL FT812_CmdDLStart
    
    ; Очистка экрана
    CALL FT812_ClearAll
    
    ; "Physics: NNNN"
    LD HL, 10           ; X
    LD DE, 10           ; Y
    LD BC, (PhysicsTicks)
    CALL FT812_CmdNumber
    
    ; "Draw: NNNN"
    LD HL, 10
    LD DE, 30
    LD BC, (DrawTicks)
    CALL FT812_CmdNumber
    
    ; "FT812: NNNN"
    LD HL, 10
    LD DE, 50
    LD BC, (FT812Ticks)
    CALL FT812_CmdNumber
    
    ; CMD_DISPLAY + CMD_SWAP
    CALL FT812_CmdDisplay
    CALL FT812_CmdSwap
    RET

; ================================================================
; Данные
; ================================================================
StartClockL:    DW 0
StartClockH:    DW 0
PhysicsTicks:   DW 0
PhysicsTicksH:  DW 0
DrawTicks:      DW 0
DrawTicksH:     DW 0
FT812Ticks:     DW 0
FT812TicksH:    DW 0

; ================================================================
; Заглушки (заменить реальным кодом)
; ================================================================
UpdatePhysics:
    LD B, 100
.loop: NOP : NOP : NOP
    DJNZ .loop
    RET

DrawScene:
    LD B, 200
.loop: NOP : NOP : NOP
    DJNZ .loop
    RET

UpdateFT812:
    LD B, 50
.loop: NOP : NOP : NOP
    DJNZ .loop
    RET

InitFT812:        RET
FT812_CS_Low:     RET
FT812_CS_High:    RET
SPI_Send:         RET
SPI_Read:         LD A, 0 : RET
FT812_CmdDLStart: RET
FT812_ClearAll:   RET
FT812_CmdNumber:  RET
FT812_CmdDisplay: RET
FT812_CmdSwap:    RET

    SAVESNA "profiler.sna", Entry
```

---

## Сравнение методов

| Метод | Точность | Видимость | Сложность | Доп. память |
|-------|----------|-----------|-----------|-------------|
| **REG_CLOCK FT812** | 60 МГц (16 нс) | Через FT812 | ⭐⭐⭐ Средне | 8 байт |
| **Z80 R-регистр** | 1 команда | Через FT812 | ⭐⭐ Легко | 2 байта |
| **Прерывания 50Hz** | 20 мс | Через FT812 | ⭐ Простой | 1 байт |
| **TS-Config LINE INT** | 64 мкс | Через FT812 | ⭐⭐⭐⭐ Сложно | 4 байта |
| **GPIO FT812** | 16 нс | Только через прибор | ⭐⭐⭐ Средне | 0 |

### Рекомендация по применению:

| Что замеряем | Лучший метод |
|--------------|--------------|
| Физика игры (короткая) | **REG_CLOCK FT812** ✅ |
| Отрисовка кадра | **REG_CLOCK FT812** ✅ |
| Загрузка уровня (длинная) | Прерывания 50 Hz |
| Отдельные функции Z80 | R-регистр |
| Профилирование инструкций | R-регистр |
| Общее время кадра | REG_FRAMES (счетчик кадров) |

---

## Полезные регистры FT812

### Регистры для профилирования:

```c
#define REG_CLOCK         0x302008  // 32-bit счетчик тактов (60 МГц)
#define REG_FRAMES        0x302004  // 32-bit счетчик кадров
#define REG_RENDERMODE    0x302010  // Режим рендеринга
#define REG_TRIM          0x302180  // Внутренний trim
#define REG_CMDB_SPACE    0x302574  // Свободно в CMD FIFO
#define REG_CMD_READ      0x3020F8  // CMD FIFO read pointer
#define REG_CMD_WRITE     0x3020FC  // CMD FIFO write pointer
```

### Регистры GPIO (для внешних индикаторов):

```c
#define REG_GPIO_DIR      0x302090  // GPIO direction (1 = output)
#define REG_GPIO          0x302094  // GPIO values
#define REG_GPIOX_DIR     0x302098  // Extended GPIO direction
#define REG_GPIOX         0x30209C  // Extended GPIO values
```

### Регистры состояния:

```c
#define REG_PWM_HZ        0x3020D0  // PWM частота
#define REG_PWM_DUTY      0x3020D4  // PWM duty cycle (0-128)
#define REG_INT_FLAGS     0x302100  // Флаги прерываний
#define REG_INT_EN        0x302104  // Разрешение прерываний
#define REG_INT_MASK      0x302108  // Маска прерываний
```

---

## Команды FT812 для отображения

### CMD_NUMBER - отображение числа

```c
CMD_NUMBER(x, y, font, options, number)

Параметры:
- x, y      : координаты (16-bit signed)
- font      : 16-31 (системные шрифты)
- options   : 0=normal, OPT_SIGNED=со знаком, OPT_CENTER=центр
- number    : число для отображения (32-bit)
```

### CMD_TEXT - отображение текста

```c
CMD_TEXT(x, y, font, options, "string")

Параметры:
- x, y      : координаты
- font      : 16-31
- options   : 0=normal, OPT_CENTERX, OPT_CENTERY, OPT_RIGHTX
- string    : null-terminated строка
```

### Пример вывода всех счетчиков:

```c
void draw_profile_info(uint32_t physics, uint32_t draw, uint32_t total) {
    FT81x_Cmd_DL_Start();
    
    // Полупрозрачный черный фон
    FT81x_Cmd_DL(CLEAR_COLOR_RGB(0, 0, 0));
    FT81x_Cmd_DL(CLEAR(1, 1, 1));
    
    // Заголовок
    FT81x_Cmd_Text(10, 10, 28, 0, "PROFILE INFO");
    
    // Метки
    FT81x_Cmd_Text(10, 40, 26, 0, "Physics:");
    FT81x_Cmd_Number(150, 40, 26, 0, physics);
    
    FT81x_Cmd_Text(10, 60, 26, 0, "Draw:");
    FT81x_Cmd_Number(150, 60, 26, 0, draw);
    
    FT81x_Cmd_Text(10, 80, 26, 0, "Total:");
    FT81x_Cmd_Number(150, 80, 26, 0, total);
    
    // В мс
    FT81x_Cmd_Text(10, 110, 26, 0, "ms:");
    FT81x_Cmd_Number(150, 110, 26, 0, total / 60000);
    
    FT81x_Cmd_DL(DISPLAY());
    FT81x_Cmd_Swap();
}
```

---

## Заключение

### Ключевые принципы профилирования с FT812:

1. **Бордюр НЕ работает** - FT812 перехватывает экран
2. **Используйте REG_CLOCK** - встроенный высокоточный счетчик
3. **Выводите результаты через FT812** - CMD_NUMBER и CMD_TEXT
4. **Графики на экране** - для визуализации в реальном времени

### Pipeline профилирования:

```
1. ReadFT812Clock  → StartClock
2. Замеряемый код
3. ReadFT812Clock  → EndClock
4. EndClock - StartClock = ticks
5. ticks → CMD_NUMBER → экран FT812
```

### Конвертация значений:

```
Такты FT812 (60 МГц) → миллисекунды:
ms = ticks / 60000

Такты FT812 → процент кадра (60 FPS):
percent = (ticks * 100) / 1000000
```

---

## Ссылки

### Документация FT812:
- [FT81x Datasheet](https://brtchip.com/wp-content/uploads/2025/02/DS_FT81x.pdf)
- [FT81x Programmer Guide](https://brtchip.com/wp-content/uploads/Support/Documentation/Programming_Guides/ICs/EVE/FT81X_Series_Programmer_Guide.pdf)

### Документация TS-Config:
- [TS-Config Forum](https://forum.tslabs.info/)
- [TS-Conf Documentation](https://github.com/tslabs/zx-evo/blob/master/pentevo/docs/TSconf/tsconf_en.md)

### Дополнительные ресурсы:
- [Z80 Instruction Timings](https://clrhome.org/table/)
- [ZX Evolution Wiki](https://zx-pk.ru/)

---

**Документ создан:** 2026-05-08  
**Версия:** 1.0  
**Платформа:** ZX Evolution + VDAC2 (FT812)  
**Автор:** Claude (Anthropic)  
**Лицензия:** MIT / CC BY 4.0

---

*Удачи с оптимизацией Zuma Deluxe на ZX Evolution! 🎮🚀*
