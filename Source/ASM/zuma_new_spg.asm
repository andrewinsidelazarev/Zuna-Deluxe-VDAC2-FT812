; ===========================================================================
; ZUMA DELUXE - TS-Config (ПОЛНАЯ ИГРА)
; ===========================================================================

    DEVICE ZXSPECTRUM1024          ; SPG-сборка: 64 страницы (для двух canvas-экранов)
    OPT --syntax=ab

; ================================================================
; ПОРТЫ (TS-CONFIG)
; ================================================================
VCONFIG  EQU #00AF
VPAGE    EQU #01AF
TSCONFIG EQU #06AF
PALSEL   EQU #07AF
FMADDR   EQU #15AF
SYSCONG  EQU #20AF
PAGE0    EQU #10AF
PAGE1    EQU #11AF
PAGE2    EQU #12AF
PAGE3    EQU #13AF
INTMASK  EQU #2AAF       ; маска IRQ: бит 0=frame, бит 1=line, бит 2=DMA
INTMSKF  EQU %00000001   ; включить только frame IRQ (vsync, 50 Гц)
TMPAGE   EQU #16AF
T0GPAGE  EQU #17AF
SGPAGE   EQU #19AF
T0XOFSL  EQU #40AF
T0XOFSH  EQU #41AF
T0YOFSL  EQU #42AF
T0YOFSH  EQU #43AF

; ================================================================
; DMA (TS-Conf) — для блита шаров цепочки в canvas
; ================================================================
DMASADL  EQU #1AAF
DMASADH  EQU #1BAF
DMASADX  EQU #1CAF
DMADADL  EQU #1DAF
DMADADH  EQU #1EAF
DMADADX  EQU #1FAF
DMALEN   EQU #26AF
DMACTR   EQU #27AF
DMASTAT  EQU #27AF
DMANUM   EQU #28AF
DMAWNR   EQU #80
DMA_BLT_8BPP_MODE     EQU #B9    ; BLT1 + SALG + DALG + ASZ (с прозрачностью src=0)
DMA_BLT_NOTRANSP_MODE EQU #B1    ; BLT0 + SALG + DALG (БЕЗ прозрачности — для full copy)

; --- Геометрия DMA-шара ---
; Шар BALL_PIX × BALL_PIX (18×18). Решение X×2 granularity (Слободчиков):
; 2 варианта спрайта на цвет:
;   even — ball на col 0..BALL_PIX-1, col BALL_PIX..BALL_PIX+1 = pad (всё равно не
;          копируется DMA: burst = BALL_PIX/2 words).
;   odd  — ball сдвинут на +1 px ВНУТРИ спрайта: col 0 = transparent, ball на
;          col 1..BALL_PIX (для odd последний pixel ball'а орig[BALL_PIX-1] оказывается
;          на col BALL_PIX и DMA не копирует его → теряем 1 px по правому краю
;          шара. На circular-mask edge это обычно прозрачный пиксель).
; При blit'е: dst_X = X & #FE, sprite = (X & 1) ? odd : even.
; Burst = BALL_PIX/2 words (= ширина DMA-копии = BALL_PIX px). Тот же overhead
; что и до X-granularity workaround.
BALL_PIX           EQU 20       ; DMA-burst width в px (DMA_SPRITE_HALF=10, чтобы trackX=10 не уходил в TmpChainX<0 → preserve gap)
DMA_SPRITE_HALF    EQU BALL_PIX / 2          ; 9 — top-left offset = X - DMA_SPRITE_HALF
DMA_BURST_WORDS    EQU BALL_PIX / 2          ; 9 words в burst (DMA копирует BALL_PIX px по X)
CANVAS_W           EQU 360
CANVAS_H           EQU 288
; Ограничение по X: dst_X = X & #FE, DMA пишет dst_X..dst_X+BALL_PIX-1.
; Условие видимости: dst_X+BALL_PIX <= CANVAS_W → X & #FE <= CANVAS_W-BALL_PIX.
; X = CANVAS_W-BALL_PIX+1 даёт dst_X = CANVAS_W-BALL_PIX — допустимо.
DMA_X_MAX          EQU CANVAS_W - BALL_PIX + 2    ; 344 — X >= этого значит шар выходит за правый край

BALLS_DMA_EVEN_PAGE EQU #40    ; #40..#45 — even спрайты 6 цветов (col 0..17 = шар)
BALLS_DMA_ODD_PAGE  EQU #48    ; #48..#4D — odd спрайты (col 1..17 = шар сдвинут +1, col 18+ обрезается DMA-burst'ом)
CANVAS_A_PAGE_BASE EQU #10    ; visible canvas pages #10..#18 (9 pages × 16K)

; ================================================================
; ПОРТЫ КЛАВИАТУРЫ
; ================================================================
KEY_O     EQU #DFFE   ; Бит 1 - влево
KEY_P     EQU #DFFE   ; Бит 0 - вправо
KEY_SPACE EQU #7FFE   ; Бит 0 - пробел (выстрел)

; ================================================================
; ПОРТЫ МЫШИ (Kempston Mouse — ZX Evolution / UnrealSpeccy)
; ================================================================
MOUSE_X   EQU #FBDF   ; X счётчик (8-bit, относительный)
MOUSE_Y   EQU #FFDF   ; Y счётчик (8-bit, относительный)
MOUSE_BTN EQU #FADF   ; Кнопки: бит 0 = правая, бит 1 = левая (1=нажата)

; ================================================================
; КОНСТАНТЫ
; ================================================================
FM_EN    EQU #10    ; %00010000 — FMEN: включает FM доступ (#0000=CRAM, #0200=SFILE)
GFX_PAGE EQU 8
MAP_PAGE EQU 9

; TSU SPSIZE / SPACT / SPLEAP
SPSIZ8   EQU #00    ; размер 8
SPSIZ16  EQU #02    ; размер 16
SPSIZ24  EQU #04    ; размер 24
SPSIZ32  EQU #06    ; размер 32
SPACT    EQU #20    ; бит ACT — спрайт включён
SPLEAP   EQU #40    ; «sprite is last in current layer» (на это полагаться нельзя
                    ; в нашей реализации — оставлено как константа, не используется)

; Раскладка SFILE (85 descriptors × 6 байт = 510 байт #0200..#03FD).
; TSU рендерит descriptors в порядке SFILE, ПОЗДНИЕ поверх ранних (z-order).
; ACT=0 СТОПИТ рендеринг → следующий descriptor не нарисуется. Поэтому:
;  • frog/preview всегда активны;
;  • chain рисуется через DMA в canvas, TSU-слоты DESC_CHAIN0[60] просто
;    держатся off-screen (Y=#2C + ACT=1) чтобы TSU дошёл до курсора;
;  • для летящих шаров неактивные слоты тоже ACT=1 + offscreen.
;   #0200 — лягушка (64×64)
;   #0206 — mouth-preview (24×24)
;   #020C — back-preview (8×8)
;   #0212..#0379 — 60 chain-слотов (360 байт, off-screen для DMA-чейна)
;   #037A..#03D9 — 16 летящих шаров (96 байт)
;   #03DA — курсор (16×16)
;   #03E0..#03FD — пусто
DESC_FROG         EQU #0200    ; 64×64 жаба
DESC_PREVIEW      EQU #0206    ; 24×24 mouth ball — текущий цвет, во рту
DESC_BACK_PREVIEW EQU #020C    ; 8×8 spine preview — следующий цвет, на спине
DESC_CHAIN0       EQU #0212    ; 60 chain-слотов (360 байт) → off-screen, реальный chain в canvas
DESC_BALL0        EQU #037A    ; 16 летящих шаров (96 байт)
DESC_CURSOR       EQU #03DA    ; 16×16 курсор

SCR_W    EQU 360
SCR_H    EQU 288
SPR_SIZE EQU 64                                  ; frog 64×64

MIN_X EQU 0
MAX_X EQU 296                                    ; SCR_W - SPR_SIZE
MIN_Y EQU 0
MAX_Y EQU 224                                    ; SCR_H - SPR_SIZE

; tiltspiral 5:4 (без letterbox) — smart crop tx[26..613], ty[0..470]
; gx=242 gy=248 → screen (132, 152) → top-left (100, 120)
FROG_INIT_X EQU 100
FROG_INIT_Y EQU 120

MOUSE_INIT_X EQU FROG_INIT_X + 72                ; 220 — справа от жабы → стартовый угол ~0
MOUSE_INIT_Y EQU FROG_INIT_Y + 32                ; 144 — центр жабы по Y (SPR_SIZE/2)

; Cursor 16x16 in 360x288 screen — top-left limits
CURSOR_MIN_X EQU 0
CURSOR_MIN_Y EQU 0
CURSOR_MAX_X EQU SCR_W - 16                     ; 344
CURSOR_MAX_Y EQU SCR_H - 16                     ; 272

MAX_BALLS     EQU 16            ; летящих шаров (cooldown 20 frames между выстрелами хватает)
MAX_CHAIN_BALLS EQU 240         ; VDC chain physics limit. HD оригинал: 256. У нас 240 чтобы
                                ; TrackData (12386 байт) поместился в slot 2 (16K) без spillover.
                                ; Если перенести TrackData на свою page — можно поднять до 255.
TSU_CHAIN_SPRITES EQU 60        ; зарезервированных SFILE-дескрипторов для off-screen TSU-цепочки.
                                ; Физический chain рисуется через DMA в canvas; TSU-слоты лишь
                                ; держатся ACT=1+offscreen, чтобы TSU дошёл до courseur. Поэтому
                                ; SFILE-сторона не масштабируется с MAX_CHAIN_BALLS.

; Параметры уровня (level1 / lvl11 в оригинальной Zuma):
LEVEL_START_BALLS  EQU 35       ; быстрая фаза: 35 шаров вылезают «поездом»
LEVEL_REPEAT_BALLS EQU 50       ; нормальная фаза: ещё 50 шаров обычной скоростью
LEVEL_TOTAL_BALLS  EQU LEVEL_START_BALLS + LEVEL_REPEAT_BALLS  ; 85 — после спавн прекращается
FAST_ADVANCE       EQU 12       ; кол-во MoveChain'ов за кадр в fast-фазе (norm = 1 за 2 кадра)
; --- Размер шара и cell-spacing (см. также make_dma_balls.py: BALL_PIX) ---
BALL_DIAMETER      EQU 20       ; диаметр DMA-копии (= 10 words x 20 lines). Visible круг = 18-19 px (radius 9.5 в png-маске).
CELL_SIZE          EQU 32       ; шаг между cell-позициями (в семплах трека).
                                ; cell-step px = TrackLen / TRACK_NUM_SLOTS ~= 1986/96 ~= 20.7.
                                ; Уменьшить до 18..24 если хотим плотнее.
CHAIN_SPACING      EQU CELL_SIZE  ; legacy alias

; ----- VDC (Virtual Discrete Chain) — текущая модель цепочки
;
; Каждый физический трек уровня имеет свой ChainStateBlock. Сейчас один (Chain0).
; В оригинальной Zuma бывают уровни с двумя tracks → потребуется Chain1_*.
; Slot k (целое 0..SlotsLen-1) — ячейка вдоль трека на t-позиции k*CELL_SIZE.
; Координаты берутся из TrackData[t] напрямую — отдельный CellTable не нужен.
;
; Chain0_Slots[k] хранит цвет (0..NUM_BALL_COLORS-1) либо GAP-маркер (>= NUM_BALL_COLORS).
; Chain0_SlotOffsets[k] — signed sub-cell delta (-128..+127) для smooth animation
;   при match/insert/cascade compactify; общее движение — discrete по cell-grid.
; Chain0_HeadSlotAbs — абсолютный track-slot для Chain0_Slots[0] (head).
; Chain0_HeadSub — sub-cell (0..CELL_SIZE-1) для непрерывного движения head'а.
; Chain0_SlotsLen — длина active range (head..tail включительно).
;
; t-позиция шара в slot k:
;   t = (Chain0_HeadSlotAbs - k) * CELL_SIZE + Chain0_HeadSub + Chain0_SlotOffsets[k]
;
; Match-3 detect: window-3 scan по Chain0_Slots[]. s[k]==s[k+1]==s[k+2] && s[k] color → match.
; Match-3 apply: Slots[lb..rb] := GAP_STOP, ChainStalled=1, GapStep начинает закрывать.
; --- VDC GAP-маркеры (виртуальные цвета). Любой Slots[k] >= NUM_BALL_COLORS = GAP. ---
GAP_STOP            EQU #FE   ; после stop-mode match. Двигается вправо (к tail в массиве).
GAP_CASCADE         EQU #FD   ; после cascade-mode match. Двигается влево (к head).
GAP_MARKER          EQU GAP_STOP    ; legacy alias (init/render/scan не различают)
MAX_SLOTS_PER_CHAIN EQU MAX_CHAIN_BALLS  ; 60: совместимо с ChainPrev*[] arrays
NUM_BALL_COLORS     EQU 6                ; max доступных цветов (compile-time, для array sizes / GAP detect).
                                        ; Реальное число цветов на уровне берётся из LevelNumColors (runtime).
GAP_STEP_FRAMES     EQU CELL_SIZE        ; кадров на 1 cell-step (= 32 frames per cell @ 1 px/frame decay)
EXPLOSION_FRAMES    EQU 14               ; длительность explosion-анимации до перехода в GAP_STOP
EXPLOSION_HIDE_AT   EQU 6                ; с какого кадра скрывать шар (frames 1..5 видны, 6..14 скрыты)
DM3_OFFSET_GAP_MAX  EQU 8                ; макс. |offset diff| между соседями run'а в DetectMatch3
                                          ; (= визуальная зазора, при котором ещё считаем что шары
                                          ; «коснулись». При большем — match НЕ считается, ждём
                                          ; пока offset decay сведёт зазор. Полу-ball width = 9 px.)

; BlitChainToShadow per-slot classification (заполняется в BcsPreClassify, читается PASS1/PASS2).
; PRESERVE значит «оставить шар в shadow как есть» — фикс хвоста при cascade roll-back.
BCS_DRAW            EQU 0    ; нормальный blit (есть кэш геометрии)
BCS_DESTROY         EQU 1    ; шар удалён (i>=SlotsLen / GAP) → restore golden, prev → invalid
BCS_PRESERVE        EQU 2    ; off-track / off-canvas → shadow не трогаем, prev не invalid'им

; Killzone (череп с лучами в конце трека) — DMA blit 64×64 на canvas.
; 64x64 при stride 512 = 32K → разбит на 2 src pages: top rows 0..31, bot 32..63.
KILLZONE_DMA_PAGE_TOP EQU #46
KILLZONE_DMA_PAGE_BOT EQU #47
KZ_PIX             EQU 64
ROTATION_SPEED EQU 4

; ================================================================
; СТРУКТУРА ШАРА (8 байт) — летящий после выстрела
; ================================================================
BALL_X      EQU 0
BALL_Y      EQU 2
BALL_ANGLE  EQU 4
BALL_SPEED  EQU 5
BALL_ACTIVE EQU 6
BALL_COLOR  EQU 7

; ================================================================
; ЦЕПОЧКА — VDC МОДЕЛЬ (Virtual Discrete Chain). См. полное описание выше.
; Slots[k] = цвет либо GAP-маркер (>= NUM_BALL_COLORS).
; t_i = (Chain0_HeadSlotAbs - i) * CELL_SIZE + Chain0_HeadSub + SlotOffsets[i]
; SlotsLen — количество активных slots (head=0, tail=SlotsLen-1).
; Insert: shift_right(Slots, idx) + Slots[idx]=color + SlotsLen += 1 + HSA += 1.
; Spawn: Slots[SlotsLen] = color, SlotsLen += 1 (новый шар на хвостовой стороне).
; Match-3: window-3 scan ставит GAP_STOP в lb..rb, GapStep сдвигает GAP'ы к концу
; массива, при close SlotsLen уменьшается на 1.
; ================================================================

; ================================================================
; КОД
; ================================================================
    ORG #6000

Entry:
    DI
    LD SP, #BFFF

    ; ---------- ИНИЦИАЛИЗАЦИЯ ЖЕЛЕЗА ----------
    LD BC, SYSCONG : LD A, %00000110 : OUT (C), A     ; 14 MHz + аппаратный кэш
    LD BC, VCONFIG : LD A, %11000010 : OUT (C), A  ; 360x288, 256c, NOGFX=0 — canvas включён
    LD BC, VPAGE   : LD A, #10       : OUT (C), A  ; canvas-bitmap начинается с page 16

    ; Палитра (включая bg-canvas палитру в CRAM #0100..#01FF)
    ; DMA-шары используют TSU-палитру (#20..#7F) — отдельная загрузка не нужна
    CALL InitPalette

    ; TSU — sprite-graphics в page 6/7 (уже разложены через INCBIN)
    LD BC, SGPAGE  : LD A, 6 : OUT (C), A
    LD BC, TSCONFIG : LD A, %10000000 : OUT (C), A   ; TSU sprites вкл

    ; ---------- ИНИЦИАЛИЗАЦИЯ ИГРЫ ----------
    CALL InitGame

    ; ---------- IM 2 + frame IRQ для Fixed Timestep ----------
    ; ISR-handler в page 5 (наш код). I=#5E, peripheral data byte для frame IRQ
    ; (= INTRAME=#FF). Vector address = (#5E<<8)|#FF = #5EFF. Z80 читает word
    ; #5EFF/#5F00 → ISR address. Записываем эти 2 байта runtime, чтобы получить
    ; адрес IRQHandler в RAM (page 5 byte #1EFF/#1F00).
    LD A, LOW(IRQHandler)
    LD (#5EFF), A
    LD A, HIGH(IRQHandler)
    LD (#5F00), A
    LD A, #5E
    LD I, A
    IM 2
    LD BC, INTMASK : LD A, INTMSKF : OUT (C), A    ; разрешить только frame IRQ
    XOR A : LD (TickCount), A : LD (ProcessedTicks), A
    EI

; ============================================================================
; FIXED TIMESTEP MAIN LOOP
; ISR инкрементирует TickCount каждый vblank (50 Hz). MainLoop "догоняет":
; пока ProcessedTicks < TickCount → выполнить UpdateGame + INC ProcessedTicks.
; Когда тики обработаны — RenderFrame (swap+sprites+DMA blit) и HALT (sleep).
; Если кадр рендера затянулся (>20мс) — успело пройти 2+ IRQ → следующий цикл
; выполнит UpdateGame дважды → game speed остаётся 50 Hz, рендер визуально 25.
; Никаких race conditions: вся логика атомарна в MainLoop, ISR только тик.
; ============================================================================
MainLoop:
    DI
    LD A, (TickCount)
    LD B, A
    LD A, (ProcessedTicks)
    EI
    CP B
    JR Z, .ml_render
    CALL UpdateGame
    LD HL, ProcessedTicks
    INC (HL)
    JR MainLoop
.ml_render:
    CALL RenderFrame
    HALT                                      ; сон до следующего IRQ
    JR MainLoop

; ============================================================================
; UPDATE GAME — атомарный шаг логики (= 1 tick = 20 мс).
; Mouse/input, motion, collisions, chain advance, spawn, cooldown.
; НЕ trogает canvas / DMA / TSU спрайты — это в RenderFrame.
; ============================================================================
UpdateGame:
    CALL HandleMouse
    CALL HandleInput
    CALL UpdateBalls
    CALL CheckCollisions
    CALL CheckBallChainCollisions

    LD A, (FrameCounter)
    INC A
    LD (FrameCounter), A

    LD A, (BallsSpawned)
    CP LEVEL_START_BALLS
    JR C, .ug_fast

    LD A, (FrameCounter)
    AND 1
    JR NZ, .ug_after_advance
    CALL MoveChain
    CALL AnimateChain
.ug_after_advance:

    LD A, (BallsSpawned)
    CP LEVEL_TOTAL_BALLS
    JR NC, .ug_after_spawn
    LD A, (FrameCounter)
    AND 63
    JR NZ, .ug_after_spawn
    CALL TrySpawnAndCount
    JR .ug_after_spawn

.ug_fast:
    LD B, FAST_ADVANCE
.ug_fast_advance:
    PUSH BC
    CALL MoveChain
    POP BC
    DJNZ .ug_fast_advance
    CALL AnimateChain
    CALL TrySpawnAndCount
.ug_after_spawn:

    LD A, (ShotCooldown)
    OR A
    JR Z, .ug_skip_cd
    DEC A
    LD (ShotCooldown), A
.ug_skip_cd:
    RET

; ============================================================================
; RENDER FRAME — atomic swap + все DMA/TSU writes.
; Вызывается раз когда вся логика догнала тики.
; ============================================================================
RenderFrame:
    ; ====== СВОП BUFFER (atomic) ======
    LD A, (VisiblePageBase) : XOR #30 : LD (VisiblePageBase), A
    LD A, (ShadowPageBase)  : XOR #30 : LD (ShadowPageBase), A
    LD A, (VisiblePageBase) : LD BC, VPAGE : OUT (C), A

    ; DEBUG: пиксель (0,287) = цвет FrogAngle
    LD BC, PAGE3 : LD A, #18 : OUT (C), A
    LD A, (FrogAngle)
    LD (#FE00), A
    LD BC, PAGE3 : XOR A : OUT (C), A

    CALL UpdateFrogSprite
    CALL UpdatePreviewSprite
    CALL UpdateBallSprites
    CALL HideChainSprites
    CALL BlitKillzoneToShadow
    CALL UpdateCursorSprite
    CALL BlitChainToShadow
    RET

; ============================================================================
; IRQ HANDLER (IM 2) — единственная задача: инкремент TickCount каждый vblank.
; Никаких DMA/блокирующих writes — иначе race с BlitChainToShadow.
; ============================================================================
IRQHandler:
    PUSH AF
    LD A, (TickCount)
    INC A
    LD (TickCount), A
    POP AF
    EI
    RETI

; ================================================================
; ИНИЦИАЛИЗАЦИЯ ИГРЫ
; ================================================================
InitGame:
    ; Позиция лягушки — центр экрана с поправкой на canvas-сдвиг (SCR_OFFS).
    LD HL, FROG_INIT_X : LD (FrogX), HL
    LD HL, FROG_INIT_Y : LD (FrogY), HL
    XOR A : LD (FrogAngle), A

    ; Очистка всех шаров (MAX_BALLS*8 = 256 байт через LDIR)
    LD HL, BallTable
    LD (HL), 0
    LD DE, BallTable+1
    LD BC, MAX_BALLS*8-1
    LDIR

    ; Очистка SFILE: 510 байт = 85 дескрипторов × 6 байт (#0200..#03FD).
    ; ВАЖНО: LDIR здесь не работает — read через FM_EN отдаёт ROM, не SFILE,
    ; и LDIR копирует ROM в SFILE → случайные ACT bits → призраки.
    ; Поэтому пишем immediate-нулями через LD (HL), 0.
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, #0200
    LD B, 255
.is_clr1:
    LD (HL), 0
    INC HL
    DJNZ .is_clr1
    LD B, 255
.is_clr2:
    LD (HL), 0
    INC HL
    DJNZ .is_clr2                ; всего 510 байт #0200..#03FD
    LD BC, FMADDR : XOR A : OUT (C), A

    ; --- Инициализация цепочки: пусто, шары приедут «поездом» в fast-фазе
    XOR A
    LD (BallsSpawned), A
    LD (ChainStalled), A
    LD (CascadeState), A
    LD (CascadeIdx), A
    LD (CascadeWait), A
    LD (CascadeDelay), A
    LD (StopModeTimer), A
    LD (CompactTimer), A
    LD (GapStepCounter), A
    LD (FrameCounter), A
    LD A, #FF
    LD (MatchScanIdx), A   ; "no scan pending"

    ; --- ВАЖНО: явно инициализируем page bases (после F12 reset значения могут
    ; быть corruptВанные → DMA blit в page 5 (main0 = код/данные) → memory corruption).
    LD A, CANVAS_A_PAGE_BASE
    LD (VisiblePageBase), A
    LD A, CANVAS_B_PAGE_BASE
    LD (ShadowPageBase), A

    ; --- Killzone: позиция = конец трека (TrackData[TRACK_NUM_POINTS-1])
    ; ВАЖНО: track data spillover в slot 2 → нужно явно убедиться что PAGE2=2.
    LD BC, PAGE2 : LD A, 2 : OUT (C), A
    LD HL, TRACK_NUM_POINTS - 1
    ADD HL, HL : ADD HL, HL                 ; HL = (TRACK_NUM_POINTS-1) * 4
    LD DE, TrackData
    ADD HL, DE
    LD A, (HL) : LD (KzCenterX), A : INC HL
    LD A, (HL) : LD (KzCenterX+1), A : INC HL
    LD A, (HL) : LD (KzCenterY), A : INC HL
    LD A, (HL) : LD (KzCenterY+1), A
    XOR A
    LD (KzFrame), A
    LD (KzFrameWait), A
    LD A, 1
    LD (KzVisible), A
    ; --- Chain0 slot-state: заполнить GAP_MARKER (= GAP_STOP), offsets/Shot2/scalars обнулить.
    LD HL, Chain0_Slots
    LD B, MAX_SLOTS_PER_CHAIN
.ig_c0slots_gap:
    LD (HL), GAP_MARKER
    INC HL
    DJNZ .ig_c0slots_gap
    LD HL, Chain0_SlotOffsets
    LD B, MAX_SLOTS_PER_CHAIN
.ig_c0offs_clr:
    LD (HL), 0
    INC HL
    DJNZ .ig_c0offs_clr
    LD HL, Chain0_Shot2
    LD B, MAX_SLOTS_PER_CHAIN
.ig_c0shot2_clr:
    LD (HL), 0
    INC HL
    DJNZ .ig_c0shot2_clr
    XOR A
    LD (Chain0_HeadSlotAbs), A
    LD (Chain0_HeadSub), A
    LD (Chain0_SlotsLen), A

    ; Инициализируем MouseBtnPrev = 1 — pretend "ЛКМ нажата при старте".
    ; Edge detection требует release→press, поэтому первый кадр НЕ выстрелит,
    ; даже если порт показывает LMB pressed (auto-fire bug).
    LD A, 1
    LD (MouseBtnPrev), A

    ; --- RNG seeds. BallColorSeed зарождаем от RTC секунд × константа,
    ;     чтобы preview-цвет был непредсказуем уже с первого выстрела.
    ;     ChainColorSeed — фиксированный (последовательность стабильна).
    CALL ReadRTCSeconds                   ; A = 0..59
    OR A
    JR NZ, .ig_seed_have
    LD A, 17                              ; защита если RTC = 0
.ig_seed_have:
    LD H, A
    LD L, $A5                             ; ненулевой младший байт
    LD (BallColorSeed), HL
    LD HL, $1234
    LD (ChainColorSeed), HL
    LD A, 1
    LD (ChainColorFirst), A               ; первый вызов RandomChainColor scramble через RTC

    ; Уровень: количество цветов (TODO: брать из per-level config)
    LD A, NUM_BALL_COLORS
    LD (LevelNumColors), A

    ; Обнуляем ChainPrevValidA/B (DS не очищает память, мусор → BlitChain crash)
    LD HL, ChainPrevValidA
    LD B, MAX_CHAIN_BALLS
.ig_clr_va:
    LD (HL), 0 : INC HL
    DJNZ .ig_clr_va
    LD HL, ChainPrevValidB
    LD B, MAX_CHAIN_BALLS
.ig_clr_vb:
    LD (HL), 0 : INC HL
    DJNZ .ig_clr_vb

    ; Explosion state: ExplodingFrame[] / ExplodingMarker[] = 0 (без stale при reset).
    LD HL, Chain0_ExplodingFrame
    LD B, MAX_SLOTS_PER_CHAIN
.ig_clr_ef:
    LD (HL), 0 : INC HL
    DJNZ .ig_clr_ef
    LD HL, Chain0_ExplodingMarker
    LD B, MAX_SLOTS_PER_CHAIN
.ig_clr_em:
    LD (HL), 0 : INC HL
    DJNZ .ig_clr_em
    RET

; ================================================================
; ПОРОЖДЕНИЕ ШАРА
; Вход: A = угол, C = скорость
; Позиция = FrogCenter + 6*Dir[N] (= ~24 пикселя от центра жабы по дуге).
; Так шар появляется на ободе жабы в направлении выстрела.
; ================================================================
SpawnBall:
    ; В VDC-модели стрельба разрешена ВСЕГДА: GAP-cells блокируют match-scan по слот-логике,
    ; offsets не используются. Игрок может накладывать gaps для extending pause.
    LD (TmpAngle), A
    LD A, C
    LD (TmpSpeed), A

    ; Поиск свободного слота
    LD IX, BallTable
    LD B, MAX_BALLS
.sb_find:
    LD A, (IX+BALL_ACTIVE)
    OR A
    JR Z, .sb_set
    LD DE, 8
    ADD IX, DE
    DJNZ .sb_find
    RET                          ; нет свободных слотов

.sb_set:
    ; NextBallColor = цвет ТЕКУЩЕГО выстрела (preview-шарик показывает его).
    ; После выстрела генерим новый цвет: LFSR × RTC_seconds mod 6.
    LD A, (NextBallColor)
    LD (IX+BALL_COLOR), A
    CALL RandomBallColor
    LD (NextBallColor), A

    LD A, (TmpAngle)
    LD (IX+BALL_ANGLE), A
    XOR A
    LD (IX+BALL_SPEED), A                 ; 0 = норм. шар (>0 = approach counter)
    LD A, 1
    LD (IX+BALL_ACTIVE), A

    ; Index в таблицах Dir: N = угол >> 3 (0..31)
    LD A, (TmpAngle)
    SRL A : SRL A : SRL A
    LD E, A
    LD D, 0

    ; Стартовая позиция шара 16×16 = позиция preview-шарика во рту (+2*Dir смещение
    ; от центра жабы). Центр шара совпадает с центром preview, шар «выходит изо рта»
    ; в направлении полёта. См. UpdatePreviewSprite.
    ; --- X = FrogX + 8 + 2*DirX[N] ---
    LD HL, DirXTable
    ADD HL, DE
    LD A, (HL)                    ; signed -4..+4
    ADD A, A                      ; A = 2*Dir
    LD L, A
    LD H, 0
    BIT 7, A
    JR Z, .sb_x_pos
    DEC H
.sb_x_pos:
    LD BC, (FrogX)
    ADD HL, BC
    LD BC, 20
    ADD HL, BC                    ; HL = FrogX + 20 + 2*DirX (ball 24x24 top-left = FrogCenter - 12)
    LD (IX+BALL_X), L
    LD A, H
    LD (IX+BALL_X+1), A

    ; --- Y = FrogY + 8 + 2*DirY[N] ---
    LD A, (TmpAngle)
    SRL A : SRL A : SRL A
    LD E, A
    LD D, 0
    LD HL, DirYTable
    ADD HL, DE
    LD A, (HL)
    ADD A, A
    LD L, A
    LD H, 0
    BIT 7, A
    JR Z, .sb_y_pos
    DEC H
.sb_y_pos:
    LD BC, (FrogY)
    ADD HL, BC
    LD BC, 20
    ADD HL, BC                    ; HL = FrogY + 20 + 2*DirY (ball 24x24)
    LD (IX+BALL_Y), L
    LD A, H
    LD (IX+BALL_Y+1), A
    RET

; ================================================================
; ОБРАБОТКА ВВОДА — поворот O/P, выстрел Q
; O = бит 1 порта #DFFE, P = бит 0 порта #DFFE
; ================================================================
HandleInput:
    ; --- Поворот клавишами O/P ---
    LD BC, KEY_O        ; #DFFE — общий порт для O и P
    IN A, (C)
    LD E, A             ; сохранить состояние строки клавиш
    BIT 1, A            ; O нажата?
    JR NZ, .check_p
    LD A, (FrogAngle)
    SUB ROTATION_SPEED
    LD (FrogAngle), A
.check_p:
    LD A, E
    BIT 0, A            ; P нажата?
    JR NZ, .check_space
    LD A, (FrogAngle)
    ADD A, ROTATION_SPEED
    LD (FrogAngle), A

.check_space:
    ; Строгий 1-нажатие = 1-выстрел. KeySpacePrev: 0=ready, 1=fired.
    LD BC, KEY_SPACE
    IN A, (C)
    BIT 0, A
    JR Z, .ks_pressed
    XOR A
    LD (KeySpacePrev), A          ; released → reset
    RET
.ks_pressed:
    LD A, (KeySpacePrev)
    OR A
    RET NZ                         ; уже стреляли — ждём release
    LD A, 1
    LD (KeySpacePrev), A
    JP ShootBall

; ================================================================
; УГОЛ ЛЯГУШКИ К КУРСОРУ МЫШИ
; Вход: MouseAbsX, MouseAbsY; лягушка зафиксирована в FrogX/FrogY
; Выход: FrogAngle (0=вправо, 64=вниз, 128=влево, 192=вверх)
; ================================================================
ComputeFrogAngle:
    ; dx = (MouseAbsX + 8) - (FrogX + 32) = MouseAbsX - FrogX - 24
    ; (центр курсора 16×16 относительно центра жабы 64×64)
    LD HL, (MouseAbsX)
    LD DE, (FrogX)
    AND A
    SBC HL, DE
    LD DE, 24
    AND A
    SBC HL, DE

    LD B, 0             ; флаги: бит0=dx<0, бит1=dy<0, бит2=|dy|>|dx|
    BIT 7, H
    JR Z, .dx_pos
    SET 0, B
    LD A, H : CPL : LD H, A
    LD A, L : CPL : LD L, A
    INC HL
.dx_pos:
    LD C, L             ; C = |dx| (≤200, в 8 бит)

    ; dy = (MouseAbsY + 8) - (FrogY + 32) = MouseAbsY - FrogY - 24
    LD HL, (MouseAbsY)
    LD DE, (FrogY)
    AND A
    SBC HL, DE
    LD DE, 24
    AND A
    SBC HL, DE

    BIT 7, H
    JR Z, .dy_pos
    SET 1, B
    LD A, H : CPL : LD H, A
    LD A, L : CPL : LD L, A
    INC HL
.dy_pos:
    LD E, L             ; E = |dy| (≤167, в 8 бит)

    ; Если |dy| > |dx| — меняем местами, запоминаем флаг октанта
    LD A, E
    CP C
    JR C, .no_swap
    SET 2, B
    LD A, C : LD C, E : LD E, A
.no_swap:
    ; C = max(|dx|,|dy|), E = min(|dx|,|dy|)
    LD A, C
    OR A
    JR Z, .cfa_done     ; курсор на лягушке — не менять угол

    ; t = E*128 / C → 0..128 (4× разрешение vs исходных 32, плавнее на диагоналях)
    LD H, 0
    LD L, E
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                        ; HL = E*128
    CALL Div16by8       ; A = HL / C (0..129)
    CP 129
    JR C, .do_lookup
    LD A, 128           ; clamp до 128 (последний валидный индекс)
.do_lookup:
    LD HL, AtanTable
    LD D, 0 : LD E, A
    ADD HL, DE
    LD A, (HL)          ; A = угол 1-го октанта (0..32 в ед. 1/256 окружности)

    ; Если был swap — зеркалим к 90°: A = 64 - A
    BIT 2, B
    JR Z, .no_mirror
    LD E, A : LD A, 64 : SUB E
.no_mirror:
    ; A = угол в квадранте 0..64 (0°..90° от оси X)
    ; Применяем знаки dx/dy
    BIT 0, B
    JR Z, .dx_pos2
    BIT 1, B
    JR Z, .q2
    ; Q3: dx<0, dy<0 → 128 + A (запад..север)
    LD E, A : LD A, 128 : ADD A, E
    JR .store
.q2:
    ; Q2: dx<0, dy≥0 → 128 - A (юг..запад)
    LD E, A : LD A, 128 : SUB E
    JR .store
.dx_pos2:
    BIT 1, B
    JR Z, .store        ; Q1: dx≥0, dy≥0 → A (восток..юг)
    ; Q4: dx≥0, dy<0 → -A mod 256 (север..восток)
    NEG
.store:
    ; Вход: A = новый угол; C = max(|dx|,|dy|).
    ; Стратегия: гибрид «быстрый/медленный»
    ;   |diff| >= 4  → full update (быстрое движение)
    ;   1 <= |diff| <= 3 → шаг на 1 unit в направлении (плавное следование без отставания)
    ;   |diff| == 0  → no-op
    LD B, A                ; B = new
    LD A, C
    CP 5
    JR C, .cfa_done        ; deadzone: курсор точно на жабе
    LD A, B
    LD HL, FrogAngle
    SUB (HL)               ; A = signed (new - old) через wrap (8-bit)
    JR Z, .cfa_done
    LD D, A                ; D = signed diff (запомним знак)
    BIT 7, A
    JR Z, .gp_pos
    NEG                    ; A = |diff|
.gp_pos:
    CP 4
    JR NC, .gp_full        ; крупный сдвиг → full
    ; малый: шаг +/- 1 в направлении D
    LD A, (HL)             ; A = old FrogAngle
    BIT 7, D
    JR NZ, .gp_dec
    INC A                  ; D >= 0 → шаг +1
    JR .gp_save
.gp_dec:
    DEC A                  ; D < 0 → шаг -1
.gp_save:
    LD (HL), A
    RET
.gp_full:
    LD (HL), B             ; FrogAngle = new
.cfa_done:
    RET

; ================================================================
; Div16by8: HL / C → A (частное 0..129)  C ≠ 0
; ================================================================
Div16by8:
    XOR A
    LD D, 0
.d8_loop:
    LD E, C
    AND A
    SBC HL, DE
    JR C, .d8_restore
    INC A
    CP 130
    JR C, .d8_loop
    RET
.d8_restore:
    ADD HL, DE
    RET

; ================================================================
; ВЫСТРЕЛ — каждое нажатие = отдельный выстрел (контролируется edge detection
; в HandleInput.check_space и HandleMouse).
; ================================================================
SHOT_COOLDOWN_FRAMES EQU 20           ; ~400ms на 50fps

ShootBall:
    LD A, (ShotCooldown)
    OR A
    RET NZ                        ; ещё перезаряжаемся — игнорируем
    LD A, SHOT_COOLDOWN_FRAMES
    LD (ShotCooldown), A
    LD A, (FrogAngle)
    LD C, 3
    JP SpawnBall                 ; tail-call

; ================================================================
; ОБНОВЛЕНИЕ ВСЕХ ШАРОВ
; ================================================================
UpdateBalls:
    LD IX, BallTable
    LD B, MAX_BALLS

.update_loop:
    LD A, (IX+BALL_ACTIVE)
    OR A
    JP Z, .next_ball

    ; Approach state: BALL_SPEED != 0 — шар привязан к target в цепочке
    LD A, (IX+BALL_SPEED)
    OR A
    JP NZ, .approaching

    PUSH BC                 ; MoveBall/MulSigned ломают B
    CALL MoveBall
    CALL CheckBoundary
    POP BC
    JP .next_ball

.approaching:
    PUSH BC
    CALL CheckBoundary       ; снимаем шар если ушёл за screen
    LD A, (IX+BALL_ACTIVE)
    OR A
    JP Z, .ap_not_arrived

    ; Validate target_idx — если >= SlotsLen, цель устарела (match-3 укоротил цепочку)
    PUSH IX : POP HL
    LD DE, BallTable : AND A : SBC HL, DE
    SRL H : RR L : SRL H : RR L : SRL H : RR L
    LD DE, BallTargetIdx : ADD HL, DE
    LD A, (HL)                                  ; A = target_idx
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR C, .ap_target_ok                         ; target_idx < SlotsLen — OK
    XOR A                                       ; иначе — kill ball
    LD (IX+BALL_ACTIVE), A
    LD (IX+BALL_SPEED), A
    JP .ap_not_arrived
.ap_target_ok:
    ; ball_index = (IX - BallTable) / 8
    PUSH IX
    POP HL
    LD DE, BallTable
    AND A : SBC HL, DE
    SRL H : RR L
    SRL H : RR L
    SRL H : RR L
    LD DE, BallTargetIdx
    ADD HL, DE
    LD A, (HL)                            ; A = target_idx
    CALL ComputeApproachTarget            ; → TmpTargetX, TmpTargetY (top-left)

    ; --- движение по X к TmpTargetX (шаг 4 пикс)
    LD L, (IX+BALL_X) : LD H, (IX+BALL_X+1)
    LD DE, (TmpTargetX)
    AND A
    SBC HL, DE                            ; HL = ball - target
    JR NC, .ap_x_ge                       ; ball >= target → шаг назад
    ; ball < target → шаг вперёд
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A          ; HL = |dx|
    LD A, H : OR A : JR NZ, .ap_x_add4
    LD A, L : CP 5 : JR NC, .ap_x_add4
    ; |dx| <= 4 → ball.X = target.X
    LD HL, (TmpTargetX)
    JR .ap_x_store
.ap_x_add4:
    LD L, (IX+BALL_X) : LD H, (IX+BALL_X+1)
    LD DE, 4
    ADD HL, DE
    JR .ap_x_store
.ap_x_ge:
    LD A, H : OR A : JR NZ, .ap_x_sub4
    LD A, L : CP 5 : JR NC, .ap_x_sub4
    LD HL, (TmpTargetX)
    JR .ap_x_store
.ap_x_sub4:
    LD L, (IX+BALL_X) : LD H, (IX+BALL_X+1)
    LD DE, 4
    AND A
    SBC HL, DE
.ap_x_store:
    LD (IX+BALL_X), L
    LD A, H : LD (IX+BALL_X+1), A

    ; --- движение по Y к TmpTargetY
    LD L, (IX+BALL_Y) : LD H, (IX+BALL_Y+1)
    LD DE, (TmpTargetY)
    AND A
    SBC HL, DE
    JR NC, .ap_y_ge
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A
    LD A, H : OR A : JR NZ, .ap_y_add4
    LD A, L : CP 5 : JR NC, .ap_y_add4
    LD HL, (TmpTargetY)
    JR .ap_y_store
.ap_y_add4:
    LD L, (IX+BALL_Y) : LD H, (IX+BALL_Y+1)
    LD DE, 4
    ADD HL, DE
    JR .ap_y_store
.ap_y_ge:
    LD A, H : OR A : JR NZ, .ap_y_sub4
    LD A, L : CP 5 : JR NC, .ap_y_sub4
    LD HL, (TmpTargetY)
    JR .ap_y_store
.ap_y_sub4:
    LD L, (IX+BALL_Y) : LD H, (IX+BALL_Y+1)
    LD DE, 4
    AND A
    SBC HL, DE
.ap_y_store:
    LD (IX+BALL_Y), L
    LD A, H : LD (IX+BALL_Y+1), A

    ; --- если ball == target по обеим осям → insert + delete
    LD L, (IX+BALL_X) : LD H, (IX+BALL_X+1)
    LD DE, (TmpTargetX)
    AND A : SBC HL, DE
    JR NZ, .ap_not_arrived
    LD L, (IX+BALL_Y) : LD H, (IX+BALL_Y+1)
    LD DE, (TmpTargetY)
    AND A : SBC HL, DE
    JR NZ, .ap_not_arrived

    LD A, (TmpChainIdx)
    LD (TmpInsertIdx), A
    LD A, (IX+BALL_COLOR)
    LD (TmpInsertColor), A
    CALL InsertChainBall
    CALL CheckMatch3                          ; pending compaction установит cascade flow
.ap_combo_done:
    XOR A
    LD (IX+BALL_ACTIVE), A
    LD (IX+BALL_SPEED), A
.ap_not_arrived:
    POP BC

.next_ball:
    LD DE, 8
    ADD IX, DE
    DEC B
    JP NZ, .update_loop
    RET

; ================================================================
; ДВИЖЕНИЕ ШАРА: BallX/Y += DirX/Y[N]. Скорость 4 пикс/кадр на осях.
; ================================================================
MoveBall:
    LD A, (IX+BALL_ANGLE)
    SRL A : SRL A : SRL A           ; N = angle >> 3
    LD E, A
    LD D, 0

    LD HL, DirXTable
    ADD HL, DE
    LD A, (HL)
    LD L, A
    LD H, 0
    BIT 7, A
    JR Z, .mb_x_pos
    DEC H
.mb_x_pos:
    LD DE, (IX+BALL_X)
    ADD HL, DE
    LD (IX+BALL_X), L
    LD A, H
    LD (IX+BALL_X+1), A

    LD A, (IX+BALL_ANGLE)
    SRL A : SRL A : SRL A
    LD E, A
    LD D, 0
    LD HL, DirYTable
    ADD HL, DE
    LD A, (HL)
    LD L, A
    LD H, 0
    BIT 7, A
    JR Z, .mb_y_pos
    DEC H
.mb_y_pos:
    LD DE, (IX+BALL_Y)
    ADD HL, DE
    LD (IX+BALL_Y), L
    LD A, H
    LD (IX+BALL_Y+1), A
    RET

; ================================================================
; ПРОВЕРКА ГРАНИЦ — Zuma-стиль: шар вылетает за экран → удаляется.
; Удаляем когда top-left уходит за пределы видимой области.
; ================================================================
CheckBoundary:
    ; X < 0 (signed) → удалить
    LD HL, (IX+BALL_X)
    BIT 7, H
    JR NZ, .cb_remove
    ; X >= SCR_W (360) → удалить
    LD DE, SCR_W
    AND A
    SBC HL, DE
    JR NC, .cb_remove

    ; Y
    LD HL, (IX+BALL_Y)
    BIT 7, H
    JR NZ, .cb_remove
    LD DE, SCR_H
    AND A
    SBC HL, DE
    JR NC, .cb_remove
    RET                         ; шар в пределах экрана

.cb_remove:
    XOR A
    LD (IX+BALL_ACTIVE), A
    ; Очищаем 6 байт дескриптора в SFILE — иначе TSU продолжит рисовать старые
    ; координаты пока UpdateBallSprites не дойдёт до этого слота. С skip-inactive
    ; в UBS, без этой очистки дескриптор живёт вечно.
    PUSH HL
    PUSH DE
    PUSH BC
    PUSH IX
    POP HL                          ; HL = IX
    LD DE, BallTable
    AND A
    SBC HL, DE                      ; HL = slot_index * 8 (BallTable struct stride)
    ; slot = HL/8 (slot 0..31, H=0)
    LD A, L
    SRL A : SRL A : SRL A           ; A = slot
    ; descriptor = DESC_BALL0 + slot*6
    LD H, 0 : LD L, A
    LD D, H : LD E, L               ; DE = slot
    ADD HL, HL                      ; HL = slot*2
    ADD HL, DE                      ; HL = slot*3
    ADD HL, HL                      ; HL = slot*6
    LD DE, DESC_BALL0
    ADD HL, DE                      ; HL = descriptor address
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    XOR A
    LD B, 6
.cb_clr:
    LD (HL), A
    INC HL
    DJNZ .cb_clr
    LD BC, FMADDR : XOR A : OUT (C), A
    POP BC
    POP DE
    POP HL
    RET

; ================================================================
; ПРОВЕРКА КОЛЛИЗИЙ
; ================================================================
CheckCollisions:
    CALL CheckBallCollisions
    RET

CheckBallCollisions:
    LD IX, BallTable
    LD B, MAX_BALLS
.outer:
    LD A, (IX+BALL_ACTIVE)
    OR A
    JR Z, .next_outer
    
    LD IY, BallTable
    LD C, MAX_BALLS
.inner:
    LD A, (IY+BALL_ACTIVE)
    OR A
    JR Z, .next_inner
    
    ; Сравниваем адреса
    LD A, IXL
    CP IYL
    JR NZ, .check
    LD A, IXH
    CP IYH
    JR Z, .next_inner
    
.check:
    PUSH BC                 ; B/C — счётчики циклов, сохраняем
    ; |dx| → стек (BC сохранены, потому push дальше)
    LD HL, (IX+BALL_X)
    LD DE, (IY+BALL_X)
    CALL AbsDiff16
    PUSH HL                 ; save |dx| на стек

    ; |dy| → HL
    LD HL, (IX+BALL_Y)
    LD DE, (IY+BALL_Y)
    CALL AbsDiff16
    POP DE                  ; DE = |dx|

    ; Столкновение если |dx| < 16 и |dy| < 16 (16-bit checks)
    LD A, D
    OR A
    JR NZ, .cbc_no_hit      ; |dx| ≥ 256
    LD A, E
    CP 16
    JR NC, .cbc_no_hit
    LD A, H
    OR A
    JR NZ, .cbc_no_hit
    LD A, L
    CP 16
    JR NC, .cbc_no_hit

    ; Отскок — swap углов
    LD A, (IX+BALL_ANGLE)
    LD D, A
    LD A, (IY+BALL_ANGLE)
    LD (IX+BALL_ANGLE), A
    LD A, D
    LD (IY+BALL_ANGLE), A
.cbc_no_hit:
    POP BC                  ; восстановить счётчики
    
.next_inner:
    LD DE, 8
    ADD IY, DE
    DEC C
    JR NZ, .inner
    
.next_outer:
    LD DE, 8
    ADD IX, DE
    DJNZ .outer
    RET

; ================================================================
; АБСОЛЮТНАЯ РАЗНОСТЬ 16-БИТ
; ================================================================
AbsDiff16:
    AND A
    SBC HL, DE
    JR NC, .positive
    LD A, H
    CPL
    LD H, A
    LD A, L
    CPL
    LD L, A
    INC HL
.positive:
    RET

; ================================================================
; ОБНОВЛЕНИЕ СПРАЙТА ЛЯГУШКИ
; ================================================================
UpdateFrogSprite:
    ; Кешируем CosTab16[N_dir] и SinTab16[N_dir] для последующих UpdatePreview/Back —
    ; не считать заново, экономит ~150 cycles на pre-frame.
    LD A, (FrogAngle)
    SRL A : SRL A : SRL A           ; A = N_dir (0..31, индекс DirTable)
    LD E, A : LD D, 0
    LD HL, CosTab16 : ADD HL, DE
    LD A, (HL) : LD (FrogDirCos), A
    LD HL, SinTab16 : ADD HL, DE
    LD A, (HL) : LD (FrogDirSin), A

    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, #0200

    LD DE, (FrogY)
    LD (HL), E : INC HL
    LD (HL), %00101110              ; SPSIZ64+ACT
    INC HL

    LD DE, (FrogX)
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR %00001110
    LD (HL), A : INC HL

    ; TNUM frog 64×64: N_frame = (FrogAngle+192)>>3, TNUM = (N>>3)*512 + (N&7)*8.
    LD A, (FrogAngle)
    ADD A, 192
    SRL A : SRL A : SRL A           ; A = N_frame (0..31)
    LD D, A
    SRL A : SRL A
    AND %00000110                   ; A = (N>>3)*2 = TNUM[11:8]
    LD E, A
    LD A, D : AND %00000111         ; A = N&7
    ADD A, A : ADD A, A : ADD A, A  ; A = (N&7)*8 = TNUM[7:0]
    LD (HL), A : INC HL
    LD A, E : LD (HL), A

    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; ОБНОВЛЕНИЕ СПРАЙТОВ ШАРОВ — пишем descriptor для ВСЕХ 32 слотов каждый кадр:
; активные = данные шара, неактивные = 6 нулей (ACT=0). Это гарантирует, что
; descriptors шаров не содержат stale данных от предыдущих кадров или ROM-мусор.
; ================================================================
UpdateBallSprites:
    LD IX, BallTable
    LD C, 1
.loop:
    PUSH BC
    CALL UpdateBallSprite
    POP BC
    LD DE, 8
    ADD IX, DE
    INC C
    LD A, C
    CP MAX_BALLS+1
    JR C, .loop
    RET

; ================================================================
; ОБНОВЛЕНИЕ СПРАЙТА ШАРА (16×16, 4bpp).
; Атлас в page 7 на TNUM 768 + COLOR*2 (от 768 до 778). SPAL = 2 + COLOR.
; Если ACTIVE=0, пишем нулевой дескриптор (ACT bit не установлен → невидимый).
; ================================================================
UpdateBallSprite:
    ; HL = DESC_BALL0 + (C-1)*6  (C = 1..MAX_BALLS).
    ; Для C=1: HL = #020C (descriptor 2). Для C=32: HL = #02C6 (descriptor 33).
    LD A, C
    DEC A
    LD L, A
    LD H, 0
    LD D, H : LD E, L                       ; DE = C-1
    ADD HL, HL                              ; HL = 2*(C-1)
    ADD HL, DE                              ; HL = 3*(C-1)
    ADD HL, HL                              ; HL = 6*(C-1)
    LD DE, DESC_BALL0
    ADD HL, DE                              ; HL = DESC_BALL0 + 6*(C-1)

    LD BC, FMADDR : LD A, FM_EN : OUT (C), A

    LD A, (IX+BALL_ACTIVE)
    OR A
    JR Z, .ubs_clear

    LD DE, (IX+BALL_Y)
    LD (HL), E : INC HL                  ; Y_L
    LD A, D : AND 1 : OR SPACT+SPSIZ24
    LD (HL), A : INC HL                  ; Y flags + ACT + SIZE16

    LD DE, (IX+BALL_X)
    LD (HL), E : INC HL                  ; X_L
    LD A, D : AND 1 : OR SPSIZ24
    LD (HL), A : INC HL                  ; X flags + SIZE24

    ; TNUM_L = COLOR * 3 (24×24 ball stride 3 cells; TNUM = 2304 + COLOR*3)
    LD A, (IX+BALL_COLOR)
    LD D, A : ADD A, A : ADD A, D
    LD (HL), A : INC HL

    LD A, (IX+BALL_COLOR)
    ADD A, 2
    ADD A, A : ADD A, A : ADD A, A : ADD A, A
    OR 9
    LD (HL), A
    JR .ubs_done

.ubs_clear:
    LD (HL), #2C : INC HL                ; Y_L = 44 (300 - 256)
    LD (HL), SPACT+SPSIZ24+1 : INC HL    ; Y=300 + ACT + SIZE24
    LD (HL), 0 : INC HL                  ; X_L = 0
    LD (HL), SPSIZ24 : INC HL            ; X_H + SIZE24
    LD (HL), 0 : INC HL                  ; TNUM_L
    LD (HL), 0                            ; TNUM_H + SPAL=0

.ubs_done:
    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; TRY SPAWN AND COUNT — обёртка вокруг SpawnChainBall, считает фактически
; добавленных шаров (ChainLen после − ChainLen до). Saturate at 255.
; ================================================================
TrySpawnAndCount:
    LD A, (Chain0_SlotsLen)
    PUSH AF                                ; сохраняем prev на стек
    CALL SpawnChainBall
    POP DE                                 ; D = prev SlotsLen
    LD A, (Chain0_SlotsLen)
    SUB D
    RET Z
    LD HL, BallsSpawned
    ADD A, (HL)
    JR NC, .tsc_save
    LD A, 255                              ; saturate
.tsc_save:
    LD (HL), A
    RET

; ================================================================
; SPAWN CHAIN BALL — добавить новый шар в tail (Slots[SlotsLen] = color).
; Шар появится на t = (HSA - SlotsLen) * CELL_SIZE + HeadSub — может быть
; отрицательным в начале; станет видимым по мере движения цепочки (HSA растёт).
; ================================================================
; Агрессивный спавн: спавним в цикле, пока есть место (= SlotsLen < MAX_SLOTS_PER_CHAIN)
; и tail настроен (offset=0). Держит хвост прижатым к старту трека.
SpawnChainBall:
.scb_loop:
    ; Pending compaction (visible gap) — стоп.
    LD A, (CompactTimer)
    OR A
    RET NZ

    LD A, (Chain0_SlotsLen)
    CP MAX_SLOTS_PER_CHAIN
    RET NC                               ; full → стоп

    ; Stall-animation safety: спавн разрешён только если tail-шар (SlotsLen-1)
    ; имеет offset=0 (= не двигается).
    OR A
    JR Z, .scb_check_place               ; SlotsLen=0 → нет tail-шара, OK
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    OR A
    RET NZ                               ; tail offset ≠ 0 → не спавн
.scb_check_place:

    ; Должно быть HeadSlotAbs >= SlotsLen (иначе tail за стартом трека).
    LD A, (Chain0_HeadSlotAbs)
    LD HL, Chain0_SlotsLen
    CP (HL)
    RET C                                ; HeadSlotAbs < SlotsLen → нет места

    ; Slots[SlotsLen] = NextChainColor; SlotOffsets[SlotsLen] = 0
    LD A, (Chain0_SlotsLen)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE                              ; HL = &Slots[SlotsLen]

    ; Anti-3-in-row spawn-guard
    LD A, (NextChainColor)
    LD B, A                                 ; B = candidate
    LD A, (Chain0_SlotsLen)
    CP 2
    JR C, .scb_no_avoid                     ; SlotsLen<2 → нечему совпадать
    PUSH HL
    DEC HL                                  ; &Slots[len-1]
    LD A, (HL)
    DEC HL                                  ; &Slots[len-2]
    CP (HL)
    JR NZ, .scb_avoid_done
    CP B
    JR NZ, .scb_avoid_done
    LD A, B
    INC A
    CP NUM_BALL_COLORS
    JR C, .scb_avoid_store
    XOR A
.scb_avoid_store:
    LD B, A
.scb_avoid_done:
    POP HL
.scb_no_avoid:
    LD A, B
    LD (HL), A

    ; SlotOffsets[SlotsLen] = SlotOffsets[SlotsLen-1] (или 0 если цепь пуста).
    ; Шар появляется 32 px позади хвоста с тем же offset → синхронный decay phase,
    ; ровный 32 px spacing, нет «дырок» между ним и хвостом.
    LD A, (Chain0_SlotsLen)
    OR A
    JR Z, .scb_off_zero
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)                               ; A = SlotOffsets[SlotsLen-1]
    JR .scb_off_set
.scb_off_zero:
    XOR A
.scb_off_set:
    LD C, A                                  ; C = new_offset
    LD A, (Chain0_SlotsLen)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD (HL), C

    CALL RandomChainColor
    LD (NextChainColor), A
    LD A, (Chain0_SlotsLen)
    INC A
    LD (Chain0_SlotsLen), A
    JR .scb_loop

; ================================================================
; LFSR16 — Galois 16-битный, polynomial $D008. Период 65535.
; Вход: HL = текущий seed (≠0). Выход: HL = новый seed.
; ================================================================
LFSR16:
    SRL H
    RR L
    RET NC
    LD A, H : XOR $D0 : LD H, A
    LD A, L : XOR $08 : LD L, A
    RET

; ================================================================
; READ RTC SECONDS — читает регистр 0 GLUK CMOS RTC, возвращает binary 0..59.
; Порты #DFF7 (адрес) / #BFF7 (данные). Регистр 0 = секунды (BCD).
; ================================================================
ReadRTCSeconds:
    LD BC, #DFF7
    XOR A
    OUT (C), A                            ; reg 0 = seconds
    LD BC, #BFF7
    IN A, (C)                             ; A = BCD seconds
    LD B, A
    AND $0F                               ; low nibble
    LD C, A
    LD A, B
    AND $F0
    SRL A : SRL A : SRL A : SRL A         ; high nibble (0..5)
    LD B, A
    ; A = high*10 + low
    ADD A, A : ADD A, A : ADD A, B        ; *5
    ADD A, A                              ; *10
    ADD A, C                              ; +low
    RET

; ================================================================
; RANDOM CHAIN COLOR — LFSR без RTC. На ПЕРВОМ вызове seed scrambled
; через умножение low_byte(seed) на RTC секунды → разные стартовые
; последовательности per launch. Subsequent calls — чистый LFSR.
; Возвращает A в 0..5.
; ================================================================
RandomChainColor:
    LD A, (ChainColorFirst)
    OR A
    JR Z, .rcc_normal
    ; Первый вызов: scramble seed RTC секундами
    XOR A
    LD (ChainColorFirst), A
    CALL ReadRTCSeconds
    OR A
    JR NZ, .rcc_have_sec
    LD A, 1                               ; защита от *0
.rcc_have_sec:
    LD HL, (ChainColorSeed)
    LD D, A                               ; D = RTC sec
    LD E, A                               ; multiplier as DE
    LD A, L                               ; A = low seed byte
    LD HL, 0
    LD B, 8
.rcc_mul_seed:
    ADD HL, HL
    SLA A
    JR NC, .rcc_no_add
    ADD HL, DE
.rcc_no_add:
    DJNZ .rcc_mul_seed
    ; HL = low_seed * RTC_sec. Гарантируем не-ноль.
    LD A, H : OR L
    JR NZ, .rcc_seed_ok
    LD HL, $1234
.rcc_seed_ok:
    LD (ChainColorSeed), HL
.rcc_normal:
    LD HL, (ChainColorSeed)
    CALL LFSR16
    LD (ChainColorSeed), HL
    ; mod LevelNumColors: 8x8 multiply A * E → HL, high byte = result.
    LD A, L                               ; A = random low byte
    LD HL, LevelNumColors
    LD E, (HL)
    LD D, 0
    LD HL, 0
    LD B, 8
.rcc_mul_n:
    ADD HL, HL
    SLA A
    JR NC, .rcc_mul_skip
    ADD HL, DE
.rcc_mul_skip:
    DJNZ .rcc_mul_n
    LD A, H
    RET

; ================================================================
; COLOR BIT — для color N в 0..7 возвращает (1 << N).
; Через таблицу, чтобы не клобберить BC. Clobbers HL/DE/A только.
; ================================================================
ColorBitTable: DB 1, 2, 4, 8, 16, 32, 64, 128
ColorBit:
    LD HL, ColorBitTable
    LD D, 0
    LD E, A
    ADD HL, DE
    LD A, (HL)
    RET

; ================================================================
; BUILD COLOR MASK — 6-бит маска цветов, присутствующих в цепочке.
; Bit N = 1 если цвет N встречается в ChainColors[0..ChainLen-1].
; Out: A = mask. Preserves BC, DE, HL.
; ================================================================
BuildColorMask:
    PUSH BC
    PUSH DE
    PUSH HL
    XOR A
    LD (TmpColorMask), A
    LD A, (Chain0_SlotsLen)
    OR A
    JR Z, .bcm_done
    LD B, A
    LD HL, Chain0_Slots
.bcm_loop:
    LD A, (HL)
    CP 6
    JR NC, .bcm_skip                       ; цвет >=6 (включая GAP_STOP=#FE / GAP_CASCADE=#FD) → пропустить
    PUSH BC
    PUSH HL
    CALL ColorBit
    LD HL, TmpColorMask
    OR (HL)
    LD (HL), A
    POP HL
    POP BC
.bcm_skip:
    INC HL
    DJNZ .bcm_loop
.bcm_done:
    LD A, (TmpColorMask)
    POP HL
    POP DE
    POP BC
    RET

; ================================================================
; RANDOM BALL COLOR — LFSR умноженный на RTC секунды + XOR FrogAngle,
; mod 6. После — фильтр через BuildColorMask: если выпавший цвет
; отсутствует в цепочке, циклически перебираем mod 6 до попадания.
; Возвращает A в 0..5.
; ================================================================
RandomBallColor:
    ; Подмешиваем FrogAngle в seed (XOR в low byte) — каждое нажатие игрока
    ; задаёт уникальный угол → дополнительный источник энтропии.
    LD HL, (BallColorSeed)
    LD A, (FrogAngle)
    XOR L
    LD L, A
    CALL LFSR16
    LD (BallColorSeed), HL
    LD A, L
    LD D, A                               ; D = LFSR low byte

    CALL ReadRTCSeconds
    OR A
    JR NZ, .rbc_have_sec
    LD A, 1                               ; защита от *0
.rbc_have_sec:
    LD E, A                               ; E = seconds (1..59)

    ; HL = D * E (8x8 → 16). Старший байт игнорим, низкий идёт в mod 6.
    LD A, D
    LD HL, 0
    LD B, 8
.rbc_mul:
    ADD HL, HL
    SLA A
    JR NC, .rbc_no_add
    ADD HL, DE
.rbc_no_add:
    DJNZ .rbc_mul

    ; mod LevelNumColors: high(L * LevelNumColors). 8x8 multiply, A * E → HL.
    LD A, L                               ; A = random low byte
    LD HL, LevelNumColors
    LD E, (HL)
    LD D, 0
    LD HL, 0
    LD B, 8
.rbc_mul_n:
    ADD HL, HL
    SLA A
    JR NC, .rbc_mul_skip
    ADD HL, DE
.rbc_mul_skip:
    DJNZ .rbc_mul_n
    LD A, H                               ; A = candidate 0..LevelNumColors-1

    ; --- фильтр по цветам цепочки ---
    LD B, A                               ; B = candidate
    CALL BuildColorMask                   ; A = mask, BC сохранён
    OR A
    JR Z, .rbc_done                       ; цепочка пуста → возврат как есть
    LD C, A                               ; C = mask
    LD A, (LevelNumColors)
    LD D, A                               ; max попыток = LevelNumColors
.rbc_filter:
    LD A, B
    CALL ColorBit
    AND C
    JR NZ, .rbc_done                      ; bit B set → цвет валиден
    INC B
    LD A, (LevelNumColors)
    CP B
    JR NZ, .rbc_no_wrap
    LD B, 0
.rbc_no_wrap:
    DEC D
    JR NZ, .rbc_filter
.rbc_done:
    LD A, B
    RET

; ================================================================
; INSERT CHAIN BALL — вставка нового шара в Slots[TmpInsertIdx] с цветом
; TmpInsertColor. shift_right(Slots[idx..len-1]); Slots[idx]=color;
; SlotOffsets[idx]=0; SlotsLen += 1; HSA += 1 (head-half шары визуально сдвигаются
; на +CELL_SIZE вперёд по треку).
; BUG: при SlotsLen >= MAX_SLOTS_PER_CHAIN drop'ает tail (DEC SlotsLen),
;      это видно user'у как «ролл-бэк хвоста на 1 шарик» при выстрелах в полную
;      цепочку. См. project_zuma_full_chain_drop_tail_bug.
; ================================================================
InsertChainBall:
    ; VDC head-forward модель (Python-эквивалент):
    ; 1. Compute new_offset = midpoint между head_neighbor и tail_neighbor.
    ; 2. Shift Slots/SlotOffsets/Shot2 [idx..end] вправо на 1.
    ; 3. Set Slots[idx]=color, SlotOffsets[idx]=new_offset, Shot2[idx]=1.
    ; 4. SlotsLen += 1.
    ; 5. HSA += 1 (с cap по track-end).
    ; 6. SlotOffsets[0..idx-1] -= CELL_SIZE с cap'ом -CELL_SIZE (head компенсация).
    ; 7. ChainFreezeCounter = CELL_SIZE.

    LD A, (Chain0_SlotsLen)
    CP MAX_SLOTS_PER_CHAIN
    JR C, .icb_not_full
    DEC A                                ; drop tail
    LD (Chain0_SlotsLen), A
.icb_not_full:

    ; --- Compute new_offset = -CELL_SIZE/2 + (head_off + tail_off) / 2 (signed) ---
    ; head_off: SlotOffsets[idx-1] если idx>0, иначе SlotOffsets[idx].
    ; tail_off: SlotOffsets[idx] если idx<SlotsLen, иначе SlotOffsets[idx-1].
    LD A, (TmpInsertIdx)
    OR A
    JR Z, .icb_head_off_zero
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)                            ; A = SlotOffsets[idx-1]
    JR .icb_head_off_done
.icb_head_off_zero:
    LD A, (TmpInsertIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .icb_head_off_zero_set         ; idx == SlotsLen → empty chain
    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    JR .icb_head_off_done
.icb_head_off_zero_set:
    XOR A
.icb_head_off_done:
    LD B, A                               ; B = head_off (signed)

    ; tail_off
    LD A, (TmpInsertIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .icb_tail_off_use_idxm1        ; idx >= SlotsLen
    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)                            ; tail_off = SlotOffsets[idx]
    JR .icb_tail_off_done
.icb_tail_off_use_idxm1:
    LD A, (TmpInsertIdx)
    OR A
    JR Z, .icb_tail_off_zero
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    JR .icb_tail_off_done
.icb_tail_off_zero:
    XOR A
.icb_tail_off_done:
    ; (head_off + tail_off) / 2 — signed avg, sign-extend before add.
    ; A = tail_off, B = head_off. Compute (B+A)/2 with arithmetic shift.
    LD C, A                               ; C = tail_off
    LD A, B                               ; A = head_off
    LD H, 0
    BIT 7, A
    JR Z, .icb_avg_h_pos
    DEC H                                 ; H = $FF (sign extend)
.icb_avg_h_pos:
    LD L, A                               ; HL = head_off (signed 16)
    LD A, C
    LD D, 0
    BIT 7, A
    JR Z, .icb_avg_d_pos
    DEC D                                 ; D = $FF
.icb_avg_d_pos:
    LD E, A                               ; DE = tail_off (signed 16)
    ADD HL, DE                            ; HL = head_off + tail_off
    SRA H : RR L                          ; HL >>= 1 (arithmetic, signed)
    ; new_offset = -CELL_SIZE/2 + HL.low. HL уже -16..16 для нормальных offsets.
    LD A, L
    SUB CELL_SIZE / 2                     ; A -= 16
    LD (TmpNewOffset), A                  ; временно сохраним

    ; --- Shift Slots/Offsets/Shot2 [idx..end] right by 1 ---
    LD A, (Chain0_SlotsLen)
    LD HL, TmpInsertIdx
    SUB (HL)
    JR Z, .icb_no_shift
    LD C, A : LD B, 0
    PUSH BC

    ; shift_right Slots[idx..end]
    LD A, (Chain0_SlotsLen)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE                            ; HL = &Slots[SlotsLen-1]
    LD D, H : LD E, L
    INC DE
    LDDR

    ; shift_right SlotOffsets
    POP BC : PUSH BC
    LD A, (Chain0_SlotsLen)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD D, H : LD E, L
    INC DE
    LDDR

    ; shift_right Shot2 (был баг — раньше не сдвигался)
    POP BC
    LD A, (Chain0_SlotsLen)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD D, H : LD E, L
    INC DE
    LDDR

.icb_no_shift:
    ; Slots[idx] = color, SlotOffsets[idx] = new_offset, Shot2[idx] = 1
    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (TmpInsertColor)
    LD (HL), A

    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (TmpNewOffset)
    LD (HL), A

    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1

    ; SlotsLen += 1
    LD A, (Chain0_SlotsLen)
    INC A
    LD (Chain0_SlotsLen), A

    ; HSA += 1 с cap по track-end (chain продвинулся на 1 cell к killzone)
    LD A, (Chain0_HeadSlotAbs)
    CP TRACK_NUM_SLOTS - 1
    JR NC, .icb_no_hsa_inc
    INC A
    LD (Chain0_HeadSlotAbs), A
.icb_no_hsa_inc:

    ; Head компенсация: SlotOffsets[0..idx-1] = max(off - CELL_SIZE, -CELL_SIZE).
    ; Equivalent: if A_orig >= 0 → A_orig - CELL_SIZE; else → -CELL_SIZE.
    LD A, (TmpInsertIdx)
    OR A
    JR Z, .icb_no_head_comp
    LD B, A
    LD HL, Chain0_SlotOffsets
.icb_head_comp_loop:
    LD A, (HL)
    OR A
    JP M, .icb_head_comp_cap               ; A_orig < 0 → cap to -CELL_SIZE
    SUB CELL_SIZE                          ; A_orig >= 0 → subtract CELL_SIZE
    JR .icb_head_comp_store
.icb_head_comp_cap:
    LD A, -CELL_SIZE                       ; cap at -32 = $E0
.icb_head_comp_store:
    LD (HL), A
    INC HL
    DJNZ .icb_head_comp_loop
.icb_no_head_comp:

    ; ChainFreezeCounter = CELL_SIZE — chain пауза на 32 кадра пока head декаит.
    LD A, CELL_SIZE
    LD (ChainFreezeCounter), A
    RET

; ================================================================
; CHECK MATCH-3 — после InsertChainBall ищет run одного цвета через точку
; вставки TmpInsertIdx. Если count >= 3 → удалить run, **симметричный pull**:
;   HeadT -= 10*count (= halfShift),
;   head-half (idx 0..L-1): offset += halfShift  → шары сдвигаются назад,
;   tail-half (new idx L..): offset = old_tail_offset - halfShift → подтягиваются вперёд.
; Обе половинки покрывают одинаковое расстояние 10*count за одно и то же время.
; Шаг между шарами на треке = 30, halfShift=10 даёт небольшой остаточный зазор,
; который доезжает естественным MoveChain (визуально незаметно).
; Без cascading combo (TODO).
; Saturation: clamp count в 12 (halfShift в 120) → fits signed byte после ADD/SUB.
; ================================================================
; ================================================================
; DETECT MATCH-3 ON SLOTS — window scan по Chain0_Slots[] вокруг TmpInsertIdx.
; Идёт влево/вправо пока цвет совпадает И нет физического gap'а с соседом
; (= Chain0_SlotOffsets[i-1] - Chain0_SlotOffsets[i] < 16, иначе разница >= 48 px).
;
; После полного перехода на slot-array delete (= set GAP_MARKER в Slots), gap
; будет встроен в массив через GAP-cells, и offset-based gap check можно убрать
; (TODO: scan просто остановится на GAP).
;
; Inputs: TmpInsertIdx, Chain0_Slots, Chain0_SlotOffsets, Chain0_SlotsLen.
; Outputs: A=1 + TmpMatchLeft/Right/Count если run >= 3, иначе A=0.
; ================================================================
DetectMatch3OnSlots:
    LD A, (Chain0_SlotsLen)
    OR A
    JP Z, .dm3_no
    LD A, (TmpInsertIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JP NC, .dm3_no                          ; idx >= len

    ; color = Slots[idx] (= цвет вставленного шара)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JP NC, .dm3_no                          ; >= NUM_BALL_COLORS = GAP-маркер → не валидный центр
    LD (TmpMatchColor), A
    ; Если slot уже exploding — не центр для нового match'а.
    LD A, (TmpInsertIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingFrame
    ADD HL, DE
    LD A, (HL)
    OR A
    JP NZ, .dm3_no

    ; --- Left scan: B = текущий index, спускаемся к 0 ---
    ; Условия продолжения: Slots[B-1] == color И |offset[B-1] - offset[B]| < DM3_OFFSET_GAP_MAX
    ; (= шары визуально коснулись).
    LD A, (TmpInsertIdx)
    LD B, A
.dm3_l:
    LD A, B
    OR A
    JR Z, .dm3_l_done
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    LD HL, TmpMatchColor
    CP (HL)
    JR NZ, .dm3_l_done

    ; offset gap check: -CELL_SIZE <= (offset[B-1] - offset[B]) < DM3_OFFSET_GAP_MAX.
    ; Ассимметричный диапазон: допускает overlap при insert (diff=-CELL_SIZE),
    ; блокирует cascade-gap (diff=+CELL_SIZE). Python-эквивалент: lb-extension check.
    LD A, B
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD C, A                                   ; C = offset[B-1]
    LD A, B
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    SUB C                                     ; A = offset[B] - offset[B-1]
    NEG                                       ; A = offset[B-1] - offset[B] = d
    ADD A, CELL_SIZE                          ; A = d + CELL_SIZE
    CP CELL_SIZE + DM3_OFFSET_GAP_MAX         ; unsigned compare: d+CS < CS+8 ?
    JR NC, .dm3_l_done                        ; out of [-CS..GAP_MAX-1] → exit

    DEC B
    JR .dm3_l
.dm3_l_done:
    LD A, B
    LD (TmpMatchLeft), A

    ; --- Right scan: C = текущий index, поднимаемся ---
    LD A, (TmpInsertIdx)
    LD C, A
.dm3_r:
    LD A, C
    INC A
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .dm3_r_done
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    LD HL, TmpMatchColor
    CP (HL)
    JR NZ, .dm3_r_done

    ; offset gap check: -CELL_SIZE <= (offset[C] - offset[C+1]) < DM3_OFFSET_GAP_MAX.
    ; Python-эквивалент: rb-extension check (rb forward of rb+1).
    LD A, C
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD B, A                                   ; B = offset[C]  (clobbers TmpMatchLeft cache)
    LD A, C
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    SUB B                                     ; A = offset[C+1] - offset[C]
    NEG                                       ; A = offset[C] - offset[C+1] = d
    ADD A, CELL_SIZE                          ; A = d + CELL_SIZE
    CP CELL_SIZE + DM3_OFFSET_GAP_MAX
    JR NC, .dm3_r_done                        ; out of [-CS..GAP_MAX-1] → exit

    INC C
    JR .dm3_r
.dm3_r_done:
    LD A, C
    LD (TmpMatchRight), A

    ; count = right - left + 1.  B был clobbered в right scan — перезагружаем из TmpMatchLeft.
    LD A, (TmpMatchLeft)
    LD B, A
    LD A, C
    SUB B
    INC A
    CP 3
    JR C, .dm3_no
    LD (TmpMatchCount), A
    LD A, 1
    RET
.dm3_no:
    XOR A
    RET

; Returns: A=1 если был матч (run >=3 detected), A=0 иначе.
; Discrete model с отложенной compaction:
;   1. Detect run >=3 (DetectMatch3OnSlots → TmpMatchLeft/Right/Count)
;   2. Slots[lb..rb] = GAP, SlotOffsets[lb..rb] = 0 — gap visually visible
;   3. ChainStalled=1 (head стоит пока gap)
;   4. CompactTimer = COMPACT_DELAY_FRAMES → AnimateChain через N кадров triggers
;      CompactAndDetectMode (= shift_left + stop/cascade detect).
; TmpMatchLeft/Right/Count сохраняются для последующего compaction.
CheckMatch3:
    CALL DetectMatch3OnSlots
    OR A
    JP Z, .m3_no_match

    ; Cascade detection ON THE FLY: Slots[lb-1] == Slots[rb+1] → GAP_CASCADE, иначе GAP_STOP.
    ; CASCADE только если ОБА соседа — реальные шары (не gap) одного цвета. Иначе
    ; два gap'а (например GAP_STOP с обеих сторон) сравниваются как равные → ложный CASCADE.
    LD B, GAP_STOP                           ; default
    LD A, (TmpMatchLeft)
    OR A
    JR Z, .m3_have_marker                    ; lb==0 → нет head-side соседа
    LD HL, Chain0_SlotsLen
    LD A, (TmpMatchRight)
    INC A
    CP (HL)
    JR NC, .m3_have_marker                   ; rb+1 >= SlotsLen → нет tail-side
    ; Загрузить C = Slots[lb-1], проверить что это не gap.
    LD A, (TmpMatchLeft)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD C, (HL)                               ; C = Slots[lb-1]
    LD A, C
    CP NUM_BALL_COLORS
    JR NC, .m3_have_marker                   ; lb-1 = gap → STOP
    ; Загрузить A = Slots[rb+1], проверить что это не gap.
    LD A, (TmpMatchRight)
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .m3_have_marker                   ; rb+1 = gap → STOP
    CP C
    JR NZ, .m3_have_marker
    LD B, GAP_CASCADE
.m3_have_marker:
    ; ExplodingFrame[lb..rb]=1, ExplodingMarker[lb..rb]=B (GAP_STOP/GAP_CASCADE).
    ; Slots[i] остаются colors до финализации (AnimateChain через EXPLOSION_FRAMES кадров).
    ; SlotOffsets очищены ниже.
    LD A, (TmpMatchLeft)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingFrame
    ADD HL, DE
    LD A, (TmpMatchCount)
    LD C, A
.m3_set_explode_frames:
    LD (HL), 1
    INC HL
    DEC C
    JR NZ, .m3_set_explode_frames

    LD A, (TmpMatchLeft)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingMarker
    ADD HL, DE
    LD A, (TmpMatchCount)
    LD C, A
.m3_set_explode_markers:
    LD (HL), B
    INC HL
    DEC C
    JR NZ, .m3_set_explode_markers

    LD A, (TmpMatchLeft)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (TmpMatchCount)
    LD B, A
.m3_set_gap_offs:
    LD (HL), 0
    INC HL
    DJNZ .m3_set_gap_offs

    ; --- Shot2-маркеры: на соседей GAP-блока (Slots[lb-1] и Slots[rb+1]) ---
    ; После закрытия GAP именно эти позиции — единственные где может произойти
    ; новый match-3 (cascade combo). Ложные match'и в середине цепочки исключены.
    LD A, (TmpMatchLeft)
    OR A
    JR Z, .m3_no_left_shot2                  ; lb=0 → нет соседа слева
    DEC A                                    ; A = lb-1
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.m3_no_left_shot2:
    LD A, (TmpMatchRight)
    INC A
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .m3_no_right_shot2                ; rb+1 >= SlotsLen → нет соседа справа
    LD H, 0 : LD L, A                        ; A = rb+1
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.m3_no_right_shot2:

    ; Head-side rollback push при match'е удалён — конфликтовал с cascade close
    ; offset +=CELL_SIZE компенсацией (давал +30 px instant visual jump).
    ; Rollback приходит ТОЛЬКО от cascade close (HSA-- + offset += CELL_SIZE
    ; → smooth slide за CELL_SIZE кадров).

    ; ChainStalled=1 пока в VDC есть GAP-cells. Очистится в AnimateChain когда последний
    ; GAP вышел через match-1 steps.
    LD A, 1
    LD (ChainStalled), A
    ; Триггерим gap_step на ближайшем hsub=0 wrap'е — иначе случайная пауза 0..32 кадра
    ; между match'ем и началом анимации схлопывания.
    LD A, GAP_STEP_FRAMES
    LD (GapStepCounter), A
    ; chain_freeze на CELL_SIZE кадров — даёт визуальную паузу сразу при match-3
    ; (иначе шары мгновенно становятся невидимыми GAP-маркерами без feedback'а).
    LD A, CELL_SIZE
    LD (ChainFreezeCounter), A
    LD A, 1
    RET
.m3_no_match:
    XOR A
    RET

; --- LEGACY block (CompactAndDetectMode + ScheduleCascade + ProcessCascade)
;     удалён: заменено GAP-step в AnimateChain (см. DoGapStep, ScanForNewMatch).
;     CompactAndDetectMode оставлен как no-op для бинарной совместимости.
CompactAndDetectMode:
    RET
ProcessCascade:
    RET
ScheduleCascade:
    RET
__legacy_unused_skip:

; ================================================================
; COMPUTE SLOT XY — для slot-индекса A возвращает центр шара (TrackData[t]).
; Использует Chain0_HeadSlotAbs/HeadSub/SlotOffsets[]. t<0 → clamp к 0.
; Out: TmpHemX/TmpHemY — 16-bit X,Y. Clobbers A,HL,DE,BC.
; ================================================================
ComputeSlotXY:
    LD (TmpHemSlotIdx), A
    LD A, (Chain0_HeadSlotAbs)
    LD HL, TmpHemSlotIdx
    SUB (HL)
    JR NC, .csxy_hsa_ok
    XOR A
.csxy_hsa_ok:
    LD H, 0 : LD L, A
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL                ; HL = (HSA-i)*32

    LD A, (Chain0_HeadSub)
    LD E, A : LD D, 0
    ADD HL, DE                             ; + HeadSub

    PUSH HL
    LD A, (TmpHemSlotIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD E, A : LD D, 0
    BIT 7, A
    JR Z, .csxy_off_pos
    DEC D
.csxy_off_pos:
    POP HL
    ADD HL, DE                             ; HL = t (signed)
    BIT 7, H
    JR Z, .csxy_t_pos
    LD HL, 0
.csxy_t_pos:
    PUSH HL
    LD DE, TRACK_NUM_POINTS
    AND A
    SBC HL, DE
    POP HL
    JR C, .csxy_t_in
    LD HL, TRACK_NUM_POINTS - 1
.csxy_t_in:
    ADD HL, HL : ADD HL, HL                ; *4 (TrackData stride)
    LD DE, TrackData
    ADD HL, DE
    LD E, (HL) : INC HL
    LD D, (HL) : INC HL
    LD (TmpHemX), DE
    LD E, (HL) : INC HL
    LD D, (HL)
    LD (TmpHemY), DE
    RET

; ================================================================
; MANHATTAN DIST TO BALL — |TmpHemX - TmpBallCX| + |TmpHemY - TmpBallCY|
; Out: HL = 16-bit unsigned дистанция. Clobbers A,DE,HL.
; ================================================================
ManhattanDistToBall:
    LD HL, (TmpHemX)
    LD DE, (TmpBallCX)
    AND A
    SBC HL, DE
    BIT 7, H
    JR Z, .mdb_dx_pos
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A
.mdb_dx_pos:
    PUSH HL                                ; |dx|
    LD HL, (TmpHemY)
    LD DE, (TmpBallCY)
    AND A
    SBC HL, DE
    BIT 7, H
    JR Z, .mdb_dy_pos
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A
.mdb_dy_pos:
    POP DE                                 ; DE = |dx|
    ADD HL, DE                             ; HL = |dx|+|dy|
    RET

; ================================================================
; CHECK BALL-CHAIN COLLISIONS — для каждого летящего шара ищем попадание
; в шар цепочки. Позиция chain-шара i: TrackData[(HSA-i)*CELL_SIZE + Sub + offset[i]].
; При коллизии: TmpInsertIdx = i, CALL InsertChainBall, удалить летящий.
; ================================================================
CheckBallChainCollisions:
    LD IX, BallTable
    LD B, MAX_BALLS
.cbc_outer:
    PUSH BC
    LD A, (IX+BALL_ACTIVE)
    OR A
    JP Z, .cbc_next_outer
    ; Approach state — пропускаем (шар уже привязан к target chain idx)
    LD A, (IX+BALL_SPEED)
    OR A
    JP NZ, .cbc_next_outer

    LD L, (IX+BALL_X) : LD H, (IX+BALL_X+1)
    LD DE, 8 : ADD HL, DE
    LD (TmpBallCX), HL
    LD L, (IX+BALL_Y) : LD H, (IX+BALL_Y+1)
    ADD HL, DE
    LD (TmpBallCY), HL

    ; Обходим цепочку с head к tail (= от меньшего idx к большему).
    ; При наличии GAP в середине цепочки (pending compaction), это даёт
    ; head-side приоритет — шар "приклеивается" к ближнему к голове соседу gap'а.
    LD A, (Chain0_SlotsLen)
    OR A
    JP Z, .cbc_next_outer
    XOR A
    LD (TmpChainIdx), A                   ; i = 0
.cbc_inner:

    ; Skip GAP slots
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JP NC, .cbc_skip_ball                 ; >= NUM_BALL_COLORS = GAP → шар проходит сквозь

    ; Skip exploding slots (любой ExplodingFrame > 0 = "уже исчезает", ball passes through)
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingFrame
    ADD HL, DE
    LD A, (HL)
    OR A
    JP NZ, .cbc_skip_ball

    ; t = (HSA - i) * 32 + HeadSub + sign_extend(SlotOffsets[i])
    LD A, (Chain0_HeadSlotAbs)
    LD HL, TmpChainIdx
    SUB (HL)
    JP C, .cbc_skip_ball                  ; HSA - i < 0 → шар за стартом
    LD H, 0 : LD L, A
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL                ; HL = (HSA-i)*32

    LD A, (Chain0_HeadSub)
    LD E, A
    LD D, 0
    ADD HL, DE                             ; + HeadSub

    PUSH HL
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD E, A
    LD D, 0
    BIT 7, A
    JR Z, .cbc_offset_pos
    DEC D
.cbc_offset_pos:
    POP HL
    ADD HL, DE
.cbc_t_ready:
    BIT 7, H
    JP NZ, .cbc_skip_ball                 ; t < 0 → шар «за стартом», не виден
    PUSH HL
    LD DE, TRACK_NUM_POINTS
    AND A
    SBC HL, DE
    POP HL
    JR C, .cbc_t_ok
    LD HL, TRACK_NUM_POINTS - 1           ; clamp в финал
.cbc_t_ok:
    ADD HL, HL : ADD HL, HL
    LD DE, TrackData
    ADD HL, DE
    LD E, (HL) : INC HL : LD D, (HL) : INC HL
    LD (TmpChainCX), DE
    LD E, (HL) : INC HL : LD D, (HL)
    LD (TmpChainCY), DE

    LD HL, (TmpBallCY)
    LD DE, (TmpChainCY)
    AND A
    SBC HL, DE
    BIT 7, H
    JR Z, .cbc_pos_dy
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A
.cbc_pos_dy:
    LD A, H : OR A : JP NZ, .cbc_skip_ball
    LD A, L : CP 14 : JP NC, .cbc_skip_ball     ; bbox 28 для ball 24×24 (~visible 20 + buffer)

    LD HL, (TmpBallCX)
    LD DE, (TmpChainCX)
    AND A
    SBC HL, DE
    BIT 7, H
    JR Z, .cbc_pos_dx
    XOR A : SUB L : LD L, A
    LD A, 0 : SBC A, H : LD H, A
.cbc_pos_dx:
    LD A, H : OR A : JP NZ, .cbc_skip_ball
    LD A, L : CP 14 : JP NC, .cbc_skip_ball     ; bbox 28

    ; --- КОЛЛИЗИЯ → hemisphere check: target_idx = i или i+1.
    ; Сравниваем Manhattan-дистанцию летящего шара до prev (idx i-1, head-side)
    ; и next (idx i+1, tail-side) ближайших non-GAP соседей.
    ; Если ближе к next → target=i+1 (вставка между i и i+1, tail-side).
    ; Иначе target=i (вставка между i-1 и i, head-side, default).

    LD A, (TmpChainIdx)
    LD (TmpTargetIdx), A                  ; default = i

    ; --- Find prev (non-GAP slot < i) ---
    XOR A
    LD (TmpHasPrev), A
    LD A, (TmpChainIdx)
    OR A
    JR Z, .hem_check_next                 ; i=0 → нет prev
    LD B, A                               ; B = i
.hem_find_prev:
    DEC B                                  ; B = candidate idx
    LD H, 0 : LD L, B
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR C, .hem_have_prev                  ; < NUM → non-GAP
    LD A, B
    OR A
    JR NZ, .hem_find_prev
    JR .hem_check_next
.hem_have_prev:
    LD A, B
    PUSH BC
    CALL ComputeSlotXY
    CALL ManhattanDistToBall
    POP BC
    LD (TmpDistPrev), HL
    LD A, 1
    LD (TmpHasPrev), A

.hem_check_next:
    XOR A
    LD (TmpHasNext), A
    LD A, (TmpChainIdx)
    INC A
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .hem_decide                    ; i+1 >= len → нет next
    LD B, A                               ; B = i+1
.hem_find_next:
    LD H, 0 : LD L, B
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR C, .hem_have_next
    INC B
    LD A, (Chain0_SlotsLen)
    CP B
    JR NZ, .hem_find_next
    JR .hem_decide
.hem_have_next:
    LD A, B
    PUSH BC
    CALL ComputeSlotXY
    CALL ManhattanDistToBall
    POP BC
    LD (TmpDistNext), HL
    LD A, 1
    LD (TmpHasNext), A

.hem_decide:
    LD A, (TmpHasNext)
    OR A
    JR Z, .hem_apply                      ; нет next → keep target=i
    LD A, (TmpHasPrev)
    OR A
    JR Z, .hem_pick_next                  ; нет prev → target=i+1
    LD HL, (TmpDistNext)
    LD DE, (TmpDistPrev)
    AND A
    SBC HL, DE
    JR NC, .hem_apply                     ; dist_next >= dist_prev → keep target=i
.hem_pick_next:
    LD A, (TmpChainIdx)
    INC A
    LD (TmpTargetIdx), A

.hem_apply:
    PUSH IX
    POP HL
    LD DE, BallTable
    AND A
    SBC HL, DE
    SRL H : RR L
    SRL H : RR L
    SRL H : RR L                          ; HL = ball_index
    LD DE, BallTargetIdx
    ADD HL, DE
    LD A, (TmpTargetIdx)
    LD (HL), A                            ; BallTargetIdx[ball_index] = target_idx
    LD A, 1
    LD (IX+BALL_SPEED), A                 ; approach флаг
    JR .cbc_next_outer

.cbc_skip_ball:
    LD A, (TmpChainIdx)
    INC A
    LD HL, Chain0_SlotsLen
    CP (HL)
    JP NC, .cbc_next_outer                ; i = SlotsLen → нет коллизии
    LD (TmpChainIdx), A
    JP .cbc_inner

.cbc_next_outer:
    POP BC
    LD DE, 8
    ADD IX, DE
    DEC B
    JP NZ, .cbc_outer
    RET

; ================================================================
; (CompactChain удалён — в VDC модели не нужен: spacing встроен в slot index.)
; ================================================================

; ================================================================
; COMPUTE APPROACH TARGET — для approach-шара вычисляет (X, Y) точки вставки.
; Вход: A = chain target index (0..ChainLen-1)
; Выход: TmpTargetX, TmpTargetY = top-left позиции (= TrackData[t] - 8 в каждой оси)
;        TmpChainIdx = A (сохранён для дальнейшего использования)
; ================================================================
ComputeApproachTarget:
    LD (TmpChainIdx), A

    ; t = (HSA - i) * 32 + HeadSub + SlotOffsets[i] (signed)
    LD A, (Chain0_HeadSlotAbs)
    LD HL, TmpChainIdx
    SUB (HL)
    JR NC, .cat_hsa_ok
    XOR A                                 ; clamp t→0 если HSA-i<0
.cat_hsa_ok:
    LD H, 0 : LD L, A
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL                ; HL = (HSA-i)*32

    LD A, (Chain0_HeadSub)
    LD E, A
    LD D, 0
    ADD HL, DE                             ; + HeadSub

    PUSH HL
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD E, A
    LD D, 0
    BIT 7, A
    JR Z, .cat_off_pos
    DEC D
.cat_off_pos:
    POP HL
    ADD HL, DE                            ; HL = t (signed)
    BIT 7, H
    JR Z, .cat_t_not_neg
    LD HL, 0
.cat_t_not_neg:
    PUSH HL
    LD DE, TRACK_NUM_POINTS
    AND A
    SBC HL, DE
    POP HL
    JR C, .cat_t_in_range
    LD HL, TRACK_NUM_POINTS - 1
.cat_t_in_range:
    ADD HL, HL : ADD HL, HL
    LD DE, TrackData
    ADD HL, DE
    LD A, (HL) : SUB 12 : LD (TmpTargetX), A : INC HL          ; ball 24x24
    LD A, (HL) : SBC A, 0 : LD (TmpTargetX+1), A : INC HL
    BIT 7, A                                                    ; sign bit set?
    JR Z, .cat_x_ok
    XOR A : LD (TmpTargetX), A : LD (TmpTargetX+1), A          ; clamp X >= 0
.cat_x_ok:
    LD A, (HL) : SUB 12 : LD (TmpTargetY), A : INC HL          ; ball 24x24
    LD A, (HL) : SBC A, 0 : LD (TmpTargetY+1), A
    BIT 7, A
    JR Z, .cat_y_ok
    XOR A : LD (TmpTargetY), A : LD (TmpTargetY+1), A          ; clamp Y >= 0
.cat_y_ok:
    RET

; ================================================================
; ANIMATE CHAIN — VDC модель. Каждый GAP_STEP_FRAMES делает GAP-step:
;   GAP_STOP двигается вправо (к tail в массиве): SWAP с Slots[k+1].
;   GAP_CASCADE двигается влево (к head): SWAP с Slots[k-1].
; Exit GAP с краёв массива → SlotsLen-=1 (для STOP) или shift_left+SlotsLen-=1+HSA-=1 (для CASCADE).
; После GAP-step → match-scan для триггера новых match'ей (cascade chain).
; ChainStalled=1 пока в Slots есть GAP-cells.
; ================================================================
AnimateChain:
    ; --- Explosion-анимация: increment ExplodingFrame, финализация после EXPLOSION_FRAMES ---
    LD A, (Chain0_SlotsLen)
    OR A
    JR Z, .ac_after_explode
    LD B, A
    LD HL, Chain0_ExplodingFrame
.ac_explode_loop:
    LD A, (HL)
    OR A
    JR Z, .ac_explode_next
    INC A
    CP EXPLOSION_FRAMES + 1
    JR C, .ac_explode_save
    ; Frame >= EXPLOSION_FRAMES → финализация: Slots[i]=ExplodingMarker[i], ExplodingFrame[i]=0.
    XOR A
    LD (HL), A                                ; ExplodingFrame[i] = 0
    PUSH HL
    PUSH BC
    LD A, (Chain0_SlotsLen)
    SUB B                                     ; A = i (поскольку B уменьшается с len до 1)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingMarker
    ADD HL, DE
    LD A, (HL)                                ; A = saved GAP_STOP/CASCADE
    LD C, A
    LD A, (Chain0_SlotsLen)
    SUB B
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD (HL), C                                ; Slots[i] = marker
    POP BC
    POP HL
    JR .ac_explode_next
.ac_explode_save:
    LD (HL), A
.ac_explode_next:
    INC HL
    DJNZ .ac_explode_loop
.ac_after_explode:

    ; Каждый кадр decay'им offsets к 0 на 1 px (= плавное движение GAP-step через offsets).
    LD A, (Chain0_SlotsLen)
    OR A
    JR Z, .ac_after_decay
    LD B, A
    LD HL, Chain0_SlotOffsets
.ac_decay_loop:
    LD A, (HL)
    OR A
    JR Z, .ac_decay_skip
    BIT 7, A
    JR NZ, .ac_decay_neg
    DEC A                                     ; positive → 0
    JR .ac_decay_store
.ac_decay_neg:
    INC A                                     ; negative → 0
.ac_decay_store:
    LD (HL), A
.ac_decay_skip:
    INC HL
    DJNZ .ac_decay_loop
.ac_after_decay:

    ; GAP step counter (full SWAP каждые GAP_STEP_FRAMES = CELL_SIZE кадров)
    LD A, (GapStepCounter)
    INC A
    CP GAP_STEP_FRAMES
    JR C, .ac_save_counter
    XOR A
    LD (GapStepCounter), A
    CALL DoGapStep
.ac_save_counter:
    LD (GapStepCounter), A
    ; Persistent scan: каждый кадр проверяем Shot2 markers (offset gap может временно
    ; блокировать match, но через ~25-32 кадра offsets decay'ят и cascade сработает).
    CALL ScanForNewMatch
    CALL UpdateStallByGap
    RET

; ================================================================
; DO GAP STEP — один шаг movement всех GAP-cells.
; STOP-cells: pass right→left (чтобы swap не двигал тот же cell дважды),
;             swap Slots[k] = STOP с Slots[k+1] = (color/non-STOP).
;             Если k+1 == SlotsLen → SlotsLen -= 1 (exit с tail-end).
; CASCADE-cells: pass left→right, swap Slots[k] = CASCADE с Slots[k-1].
;             Если k == 0 → shift_left + HSA -= 1 + SlotsLen -= 1.
; ================================================================
DoGapStep:
    ; --- Pass 1: STOP closure — last GAP_STOP from tail-side (хвост подъезжает к голове) ---
    LD A, (Chain0_SlotsLen)
    OR A
    JP Z, .dgs_cascade_init
    DEC A                                     ; A = SlotsLen-1
    LD C, A                                   ; C = current idx (start at end)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE                                ; HL = &Slots[SlotsLen-1]
.dgs_stop_scan:
    LD A, (HL)
    CP GAP_STOP
    JR Z, .dgs_stop_found
    LD A, C
    OR A
    JP Z, .dgs_cascade_init
    DEC C
    DEC HL
    JR .dgs_stop_scan

.dgs_stop_found:
    ; C = idx последнего GAP_STOP. Сохраняем для offset shift.
    LD A, C
    LD (TmpGapIdx), A

    ; Удалить slot C: shift_left Slots[C+1..end] → Slots[C..end-1]
    LD A, (Chain0_SlotsLen)
    SUB C
    DEC A                                     ; A = count = SlotsLen - C - 1
    JR Z, .dgs_stop_no_shift
    PUSH AF                                   ; save count

    LD A, C
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE                                ; HL = &Slots[C+1]
    LD D, H : LD E, L
    DEC DE                                    ; DE = &Slots[C]
    POP AF
    PUSH AF
    LD C, A : LD B, 0
    LDIR

    ; SlotOffsets shift аналогично
    LD A, (TmpGapIdx)
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD D, H : LD E, L
    DEC DE
    POP AF
    PUSH AF
    LD C, A : LD B, 0
    LDIR

    ; Shot2 shift аналогично
    LD A, (TmpGapIdx)
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD D, H : LD E, L
    DEC DE
    POP AF
    LD C, A : LD B, 0
    LDIR
.dgs_stop_no_shift:
    LD HL, Chain0_SlotsLen
    DEC (HL)

    ; STOP теперь cascade-like: HSA-=1, head комп +CELL_SIZE с cap'ом. Tail НЕ
    ; компенсируем — shift idx-=1 + HSA-=1 = position preserved автоматически.
    LD HL, Chain0_HeadSlotAbs
    LD A, (HL)
    OR A
    JR Z, .dgs_stop_no_hsa_dec
    DEC (HL)
.dgs_stop_no_hsa_dec:
    ; offsets[0..K-1] = min(offsets[j] + CELL_SIZE, CELL_SIZE) — head компенсация с cap'ом.
    ; Equivalent: if A_orig >= 0 → CELL_SIZE; else → A_orig + CELL_SIZE.
    LD A, (TmpGapIdx)
    OR A
    JR Z, .dgs_stop_no_off
    LD B, A                                   ; B = count = K
    LD HL, Chain0_SlotOffsets
.dgs_stop_off_loop:
    LD A, (HL)
    OR A
    JP P, .dgs_stop_off_cap                   ; A_orig >= 0 (signed) → cap
    ADD A, CELL_SIZE                          ; A_orig < 0 → add normally
    JR .dgs_stop_off_store
.dgs_stop_off_cap:
    LD A, CELL_SIZE
.dgs_stop_off_store:
    LD (HL), A
    INC HL
    DJNZ .dgs_stop_off_loop
.dgs_stop_no_off:
    ; Set MatchScanIdx после каждого STOP close — для ScanForNewMatch (Phase 1).
    LD A, (TmpGapIdx)
    LD (MatchScanIdx), A

    ; Compaction-site Shot2: на новом соседе K-1 (= балл который только что встал
    ; рядом с тем, что было K+1). Phase 1 ловит такой compaction-cascade combo
    ; без необходимости Phase 2 full-chain scan'а (= источник «ложных» match'ей).
    ; Также пометить slot K (= shifted-in ball) для симметрии.
    LD A, (TmpGapIdx)
    OR A
    JR Z, .dgs_stop_no_left_shot2          ; K=0 → нет K-1
    DEC A                                   ; A = K-1
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .dgs_stop_no_left_shot2          ; K-1 = GAP → не маркируем
    LD A, (TmpGapIdx)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.dgs_stop_no_left_shot2:
    LD A, (TmpGapIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .dgs_stop_no_self_shot2          ; K >= SlotsLen → нет slot K
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .dgs_stop_no_self_shot2          ; slot K = GAP → не маркируем
    LD A, (TmpGapIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.dgs_stop_no_self_shot2:
    RET                                       ; обработали STOP — не идём в CASCADE pass.
                                              ; Иначе STOP+CASCADE в одном тике дают HSA-=2
                                              ; без двойной компенсации → рывок head -32 px.

.dgs_cascade_init:
    ; --- Pass 2: CASCADE closure — first GAP_CASCADE from head-side
    ;     (голова катится к хвосту, GAP тает от head-стороны) ---
    LD A, (Chain0_SlotsLen)
    OR A
    RET Z
    LD B, A                                   ; B = SlotsLen (DJNZ counter)
    LD C, 0                                   ; C = idx
    LD HL, Chain0_Slots
.dgs_casc_scan:
    LD A, (HL)
    CP GAP_CASCADE
    JR Z, .dgs_casc_found
    INC HL
    INC C
    DJNZ .dgs_casc_scan
    RET                                       ; no CASCADE найден

.dgs_casc_found:
    LD A, C
    LD (TmpGapIdx), A

    ; Удалить slot C: shift_left Slots[C+1..end] → Slots[C..end-1]
    LD A, (Chain0_SlotsLen)
    SUB C
    DEC A
    JR Z, .dgs_casc_no_shift
    PUSH AF

    LD A, C
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD D, H : LD E, L
    DEC DE
    POP AF
    PUSH AF
    LD C, A : LD B, 0
    LDIR

    LD A, (TmpGapIdx)
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD D, H : LD E, L
    DEC DE
    POP AF
    PUSH AF
    LD C, A : LD B, 0
    LDIR

    ; Shot2 shift аналогично
    LD A, (TmpGapIdx)
    INC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD D, H : LD E, L
    DEC DE
    POP AF
    LD C, A : LD B, 0
    LDIR
.dgs_casc_no_shift:
    LD HL, Chain0_SlotsLen
    DEC (HL)
    LD HL, Chain0_HeadSlotAbs
    LD A, (HL)
    OR A
    JR Z, .dgs_casc_no_hsa_dec
    DEC (HL)
.dgs_casc_no_hsa_dec:

    ; Cascade close: HSA-- сдвигает все nominals на -CELL_SIZE. Чтобы head-side
    ; визуально остался на месте В МОМЕНТ close, а потом ПЛАВНО откатился назад
    ; за CELL_SIZE кадров — компенсируем offset += CELL_SIZE с cap'ом max +CELL_SIZE
    ; (без cap'а множественные cascade'ы аккумулируют offsets до 70+ → head зависает).
    LD A, (TmpGapIdx)
    OR A
    JR Z, .dgs_casc_no_off
    LD B, A
    LD HL, Chain0_SlotOffsets
.dgs_casc_off_loop:
    LD A, (HL)
    OR A
    JP P, .dgs_casc_off_cap                   ; A_orig >= 0 (signed) → cap
    ADD A, CELL_SIZE                          ; A_orig < 0 → add normally
    JR .dgs_casc_off_store
.dgs_casc_off_cap:
    LD A, CELL_SIZE
.dgs_casc_off_store:
    LD (HL), A
    INC HL
    DJNZ .dgs_casc_off_loop
.dgs_casc_no_off:
    ; chain_freeze: head компенсация декаит без параллельного chain motion →
    ; head визуально откатывается на CELL_SIZE px назад за CELL_SIZE кадров (видимый rollback).
    LD A, CELL_SIZE
    LD (ChainFreezeCounter), A
    ; Set MatchScanIdx после КАЖДОГО CASCADE close (как и для STOP).
    LD A, (TmpGapIdx)
    LD (MatchScanIdx), A

    ; Compaction-site Shot2 (как в STOP-pass) — Phase 1 ловит cascade combos.
    LD A, (TmpGapIdx)
    OR A
    JR Z, .dgs_casc_no_left_shot2
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .dgs_casc_no_left_shot2
    LD A, (TmpGapIdx)
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.dgs_casc_no_left_shot2:
    LD A, (TmpGapIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .dgs_casc_no_self_shot2
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .dgs_casc_no_self_shot2
    LD A, (TmpGapIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Shot2
    ADD HL, DE
    LD (HL), 1
.dgs_casc_no_self_shot2:
    RET

; ================================================================
; SCAN FOR NEW MATCH — full-chain window-3 scan. При найденном run >= 3
; устанавливает TmpMatch* и вызывает CheckMatch3 без detect (= просто apply).
; Используется AnimateChain после GAP-step — обнаружение новых match'ей
; которые сложились из-за движения GAP'ов или новых spawn'ов.
; ================================================================
ScanForNewMatch:
    ; Persistent Shot2-scan (запускается каждый кадр из AnimateChain). Не gated на
    ; MatchScanIdx — проверяет Shot2 каждый раз. Shot2 НЕ очищается на failed match —
    ; offset gap check в DetectMatch3 может временно блокировать match (offsets=-32
    ; после shift), а через ~25-32 кадров offsets decay'ят и match сработает естественно.
    ; Shot2 очищается ТОЛЬКО при:
    ;  - successful match (= consumed),
    ;  - slot стал GAP'ом (cleanup stale),
    ;  - offsets полностью settled (=0) у k и соседей (= retry done, no cascade).
    LD A, (Chain0_SlotsLen)
    OR A
    RET Z
    LD B, A                                   ; B = SlotsLen iter counter
    LD HL, Chain0_Shot2
    LD C, 0
.snm_shot2_loop:
    LD A, (HL)
    OR A
    JP Z, .snm_shot2_next

    ; --- Cleanup: Slots[C] is GAP → clear Shot2 (stale)  ---
    PUSH BC
    PUSH HL
    LD A, C
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    POP HL
    POP BC
    CP NUM_BALL_COLORS
    JR C, .snm_check_match
    LD (HL), 0                                ; GAP slot → clear Shot2
    JP .snm_shot2_next

.snm_check_match:
    PUSH BC
    PUSH HL
    LD A, C
    LD (TmpInsertIdx), A
    CALL CheckMatch3
    POP HL
    POP BC
    OR A
    RET NZ                                    ; match → cascade продолжается

    ; No match. Clear Shot2 only if offsets near k полностью settled (= retry done).
    PUSH BC
    PUSH HL
    LD A, C
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    OR A
    JR NZ, .snm_unsettled                     ; offset[C] != 0
    ; Check left neighbor
    LD A, C
    OR A
    JR Z, .snm_check_right
    DEC A
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    OR A
    JR NZ, .snm_unsettled
.snm_check_right:
    LD A, C
    INC A
    LD HL, Chain0_SlotsLen
    CP (HL)
    JR NC, .snm_settled
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    OR A
    JR NZ, .snm_unsettled
.snm_settled:
    POP HL
    POP BC
    LD (HL), 0                                ; settled → clear Shot2[C]
    JR .snm_shot2_next
.snm_unsettled:
    POP HL
    POP BC
    ; leave Shot2[C] = 1 для retry next frame

.snm_shot2_next:
    INC HL
    INC C
    DJNZ .snm_shot2_loop
    RET

; ================================================================
; UPDATE STALL BY GAP — ChainStalled=1 если в Slots есть GAP, иначе 0.
; ================================================================
UpdateStallByGap:
    LD A, (Chain0_SlotsLen)
    OR A
    JR Z, .usg_no_activity
    ; Check 1: any GAP в Slots?
    LD B, A
    LD HL, Chain0_Slots
.usg_slots_loop:
    LD A, (HL)
    CP NUM_BALL_COLORS
    JR NC, .usg_has_activity                  ; GAP найден → stall
    INC HL
    DJNZ .usg_slots_loop
    ; Check 2: any non-zero SlotOffset (= анимация в процессе)?
    LD A, (Chain0_SlotsLen)
    LD B, A
    LD HL, Chain0_SlotOffsets
.usg_offs_loop:
    LD A, (HL)
    OR A
    JR NZ, .usg_has_activity
    INC HL
    DJNZ .usg_offs_loop
.usg_no_activity:
    XOR A
    LD (ChainStalled), A
    RET
.usg_has_activity:
    LD A, 1
    LD (ChainStalled), A
    RET

; ================================================================
; MOVE CHAIN — попиксельное движение через HeadSub (0..CELL_SIZE-1).
; HeadSub++ каждый вызов; overflow → HeadSub=0, HeadSlotAbs++.
; Cascade reverse: HeadSub--, underflow → HeadSub=CELL_SIZE-1, HeadSlotAbs--.
; ChainStalled — стоп.
; ================================================================
TRACK_NUM_SLOTS       EQU TRACK_NUM_POINTS / CELL_SIZE  ; 96

MoveChain:
    ; Cascade state — цепочка стоит (instant HSA -= count в .cpt_cascade уже сделан).
    ; Reverse-anim не нужен.
    LD A, (CascadeState)
    OR A
    RET NZ
.mc_normal_check:
    LD A, (ChainStalled)
    OR A
    RET NZ

    ; ChainFreezeCounter > 0 → пауза hsub-инкремента (head компенсация декаит без
    ; параллельного chain motion, иначе net advance = 2 cell вместо 1).
    LD A, (ChainFreezeCounter)
    OR A
    JR Z, .mc_no_freeze
    DEC A
    LD (ChainFreezeCounter), A
    RET
.mc_no_freeze:

    LD A, (Chain0_HeadSub)
    INC A
    CP CELL_SIZE
    JR C, .mc_save_sub
    XOR A
    LD (Chain0_HeadSub), A
    LD A, (Chain0_HeadSlotAbs)
    INC A
    CP TRACK_NUM_SLOTS
    JR C, .mc_save_slot
    LD A, TRACK_NUM_SLOTS - 1
.mc_save_slot:
    LD (Chain0_HeadSlotAbs), A
    RET
.mc_save_sub:
    LD (Chain0_HeadSub), A
    RET

; ================================================================
; UPDATE CHAIN SPRITES — TSU-вариант рендера цепочки (НЕ ИСПОЛЬЗУЕТСЯ).
; Заменён DMA-конвейером BlitChainToShadow + HideChainSprites. Оставлен
; в коде как ссылка/легаси, никем не вызывается. Использовал старую формулу
; t = ChainHeadT - 30*i (rigid body model).
; ================================================================
UpdateChainSprites:
    XOR A
    LD (TmpChainIdx), A                   ; i = 0
.ucss_loop:
    LD A, (TmpChainIdx)
    CP TSU_CHAIN_SPRITES                  ; SFILE-резерв (legacy TSU-вариант)
    RET NC                                ; i >= TSU_CHAIN_SPRITES → конец

    ; Адрес дескриптора в SFILE: HL = DESC_CHAIN0 + 6*i
    LD H, 0 : LD L, A
    LD D, H : LD E, L
    ADD HL, HL
    ADD HL, DE
    ADD HL, HL                            ; HL = i*6
    LD DE, DESC_CHAIN0
    ADD HL, DE
    PUSH HL                               ; сохранить адрес дескриптора

    ; Если i >= SlotsLen → invisible
    LD A, (TmpChainIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JP NC, .ucss_invisible

    ; GAP-cell → invisible
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JP NC, .ucss_invisible                ; >= 3 = GAP (любой тип) → не рендерим

    ; t = (HSA - i) * 32 + HeadSub + sign_extend(SlotOffsets[i])
    LD A, (Chain0_HeadSlotAbs)
    LD HL, TmpChainIdx
    SUB (HL)
    JP C, .ucss_invisible                 ; t < 0
    LD H, 0 : LD L, A
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL                ; HL = (HSA-i)*32

    LD A, (Chain0_HeadSub)
    LD E, A
    LD D, 0
    ADD HL, DE                             ; + HeadSub

    PUSH HL
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD E, A
    LD D, 0
    BIT 7, A
    JR Z, .ucss_offset_pos
    DEC D
.ucss_offset_pos:
    POP HL
    ADD HL, DE
.ucss_t_ready:
    BIT 7, H
    JP NZ, .ucss_invisible                ; t < 0 → шар ещё за стартом

    PUSH HL
    LD DE, TRACK_NUM_POINTS
    AND A
    SBC HL, DE
    POP HL
    JR C, .ucss_t_in_range
    LD HL, TRACK_NUM_POINTS - 1           ; clamp в финал
.ucss_t_in_range:
    ; HL = t. Адрес записи трека = TrackData + 4*t.
    ADD HL, HL : ADD HL, HL
    LD DE, TrackData
    ADD HL, DE

    LD A, (HL) : SUB 12 : LD (TmpChainX), A : INC HL          ; ball 24x24 top-left = center-12
    LD A, (HL) : SBC A, 0 : LD (TmpChainX+1), A : INC HL
    LD A, (HL) : SUB 12 : LD (TmpChainY), A : INC HL
    LD A, (HL) : SBC A, 0 : LD (TmpChainY+1), A

    ; Цвет = Slots[i] (GAP-cell отсеян выше)
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    LD (TmpChainColor), A

    POP HL                                 ; адрес дескриптора
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A

    LD DE, (TmpChainY)
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPACT+SPSIZ24
    LD (HL), A : INC HL
    LD DE, (TmpChainX)
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPSIZ24
    LD (HL), A : INC HL

    LD A, (TmpChainColor)
    LD D, A : ADD A, A : ADD A, D          ; A = COLOR*3 (24×24 stride)
    LD (HL), A : INC HL
    LD A, (TmpChainColor)
    ADD A, 2
    ADD A, A : ADD A, A : ADD A, A : ADD A, A
    OR 9
    LD (HL), A

    LD BC, FMADDR : XOR A : OUT (C), A
    JP .ucss_next

.ucss_invisible:
    POP HL
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD (HL), #2C : INC HL
    LD (HL), SPACT+SPSIZ24+1 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), SPSIZ24 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), 0
    LD BC, FMADDR : XOR A : OUT (C), A

.ucss_next:
    LD A, (TmpChainIdx)
    INC A
    LD (TmpChainIdx), A
    JP .ucss_loop

; ================================================================
; LOAD BALLS DMA PALETTE — копирует 32 CRAM word из BallsDmaPalette
; в FM-mapped CRAM byte offset 256 (= CRAM #80..#9F).
; ================================================================
LoadBallsDmaPalette:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, BallsDmaPalette
    LD DE, #01C0                              ; CRAM #E0 word = byte offset 448 = #01C0
    LD BC, 64                                 ; 32 words × 2 byte
    LDIR
    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; CANVAS A=#10..#18, B=#20..#28. Golden=#30..#38. Учебная схема:
; full copy golden→shadow + blit chain + atomic VPAGE swap в начале vblank.
; ================================================================
CANVAS_B_PAGE_BASE EQU #20
GOLDEN_PAGE_BASE   EQU #30

; ================================================================
; COPY GOLDEN TO SHADOW — DMA 9 страниц фона в текущий shadow buffer.
; ShadowPageBase обновляется при swap.
; ================================================================
CopyGoldenToShadow:
    LD BC, FMADDR : XOR A : OUT (C), A
    LD A, 256-1 : LD BC, DMALEN : OUT (C), A   ; burst = 256 words = 512 byte (1 строка)
    LD A, 32-1  : LD BC, DMANUM : OUT (C), A   ; 32 строки = 16K = 1 страница

    LD A, GOLDEN_PAGE_BASE : LD (.cgs_src), A
    LD A, (ShadowPageBase) : LD (.cgs_dst), A
    LD A, 9 : LD (.cgs_cnt), A
.cgs_loop:
    XOR A : LD BC, DMASADL : OUT (C), A
    XOR A : LD BC, DMASADH : OUT (C), A
    LD A, (.cgs_src) : LD BC, DMASADX : OUT (C), A
    XOR A : LD BC, DMADADL : OUT (C), A
    XOR A : LD BC, DMADADH : OUT (C), A
    LD A, (.cgs_dst) : LD BC, DMADADX : OUT (C), A
    LD A, DMA_BLT_8BPP_MODE : LD BC, DMACTR : OUT (C), A
.cgs_wait:
    IN A, (C)
    AND DMAWNR
    JR NZ, .cgs_wait
    LD A, (.cgs_src) : INC A : LD (.cgs_src), A
    LD A, (.cgs_dst) : INC A : LD (.cgs_dst), A
    LD A, (.cgs_cnt) : DEC A : LD (.cgs_cnt), A
    JR NZ, .cgs_loop
    RET
.cgs_src: DB 0
.cgs_dst: DB 0
.cgs_cnt: DB 0

; ================================================================
; BLIT CHAIN TO SHADOW — три прохода:
;   PRE:   BcsPreClassify заполняет SkipFlag[i] и кэш геометрии для DRAW.
;   PASS1: restore prev positions, НО только если SkipFlag != PRESERVE.
;          Это сохраняет хвост в shadow при cascade roll-back (HSA-i<0 / t<0).
;   PASS2: для DRAW — blit из кэша + сохранить новый prev. DESTROY — invalidate.
;          PRESERVE — не трогать prev/shadow.
; Двух-pass нужен чтобы не "выгрызать" outline соседним restore'ом.
; ================================================================
BlitChainToShadow:
    LD BC, FMADDR : XOR A : OUT (C), A        ; FM_EN=0 для DMA
    LD A, DMA_BURST_WORDS-1 : LD BC, DMALEN : OUT (C), A   ; 9 words burst
    ; DMANUM ставится индивидуально каждым blit/restore (partial-blit: переменное число строк)

    ; --- Выбор golden offset по текущему shadow buffer ---
    LD A, (ShadowPageBase)
    CP CANVAS_A_PAGE_BASE
    JR NZ, .bcs_use_b
    LD A, #20 : LD (BcsGoldenOff), A           ; canvas A → golden = +#20
    JR .bcs_have
.bcs_use_b:
    LD A, #10 : LD (BcsGoldenOff), A           ; canvas B → golden = +#10
.bcs_have:

    ; --- PRE-PASS: классификация slot'ов и кэш геометрии для DRAW ---
    CALL BcsPreClassify

    ; ===================== PASS 1: restore prev (только !PRESERVE) =====================
    LD A, (ShadowPageBase)
    CP CANVAS_A_PAGE_BASE
    JR NZ, .p1_use_b
    LD IX, ChainPrevDstA
    LD IY, ChainPrevValidA
    JR .p1_start
.p1_use_b:
    LD IX, ChainPrevDstB
    LD IY, ChainPrevValidB
.p1_start:
    LD HL, BcsSkipFlag
    LD B, MAX_CHAIN_BALLS
.p1_loop:
    PUSH BC
    PUSH HL
    LD A, (IY+0)
    OR A
    JR Z, .p1_skip                            ; PrevValid=0 — нечего restore
    LD A, (HL)
    CP BCS_PRESERVE
    JR Z, .p1_skip                            ; PRESERVE — оставляем шар в shadow

    ; restore: golden и shadow на одной X/Y зоне → src/dst low/mid одинаковы,
    ; различаются только page (golden = shadow + BcsGoldenOff).
    LD A, (IX+0) : LD BC, DMASADL : OUT (C), A
    LD A, (IX+1) : LD BC, DMASADH : OUT (C), A
    LD A, (IX+2)
    LD B, A
    LD A, (BcsGoldenOff)
    ADD A, B
    LD BC, DMASADX : OUT (C), A
    LD A, (IX+0) : LD BC, DMADADL : OUT (C), A
    LD A, (IX+1) : LD BC, DMADADH : OUT (C), A
    LD A, (IX+2) : LD BC, DMADADX : OUT (C), A
    LD A, (IX+3) : DEC A : LD BC, DMANUM : OUT (C), A   ; num_lines-1 (под partial-blit)
    LD A, DMA_BLT_8BPP_MODE : LD BC, DMACTR : OUT (C), A
.p1_wait:
    IN A, (C)
    AND DMAWNR
    JR NZ, .p1_wait

.p1_skip:
    POP HL
    INC HL
    LD BC, 4 : ADD IX, BC
    INC IY
    POP BC
    DJNZ .p1_loop

    ; ===================== PASS 2: blit DRAW (из кэша), invalidate DESTROY, не трогать PRESERVE
    LD A, (ShadowPageBase)
    CP CANVAS_A_PAGE_BASE
    JR NZ, .p2_use_b
    LD IX, ChainPrevDstA
    LD IY, ChainPrevValidA
    JR .p2_start
.p2_use_b:
    LD IX, ChainPrevDstB
    LD IY, ChainPrevValidB
.p2_start:
    XOR A : LD (TmpChainIdx), A
.bcs_loop:
    LD A, (TmpChainIdx)
    CP MAX_CHAIN_BALLS
    JP NC, .bcs_done

    ; flag = SkipFlag[i]
    LD H, 0 : LD L, A
    LD DE, BcsSkipFlag
    ADD HL, DE
    LD A, (HL)
    OR A                                       ; BCS_DRAW=0
    JP Z, .bcs_draw
    CP BCS_DESTROY
    JP Z, .bcs_destroy
    ; PRESERVE: prev не трогаем
    JP .bcs_advance

.bcs_destroy:
    LD (IY+0), 0
    JP .bcs_advance

.bcs_draw:
    ; HL ← &BcsCacheStruct[i*6]; загружаем кэш в Bcs* temp vars
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD D, H : LD E, L                          ; DE = i
    ADD HL, HL                                 ; HL = i*2
    ADD HL, DE                                 ; HL = i*3
    ADD HL, HL                                 ; HL = i*6
    LD DE, BcsCacheStruct
    ADD HL, DE
    LD A, (HL) : LD (BcsDstLow),    A : INC HL
    LD A, (HL) : LD (BcsDstMid),    A : INC HL
    LD A, (HL) : LD (BcsPageOver),  A : INC HL
    LD A, (HL) : LD (BcsNumLines),  A : INC HL
    LD A, (HL) : LD (BcsClipTop),   A : INC HL
    LD A, (HL) : LD (BcsXOdd),      A

    ; --- DMA setup: NumLines-1, src offset = ClipTop*512 ---
    LD A, (BcsNumLines) : DEC A : LD BC, DMANUM : OUT (C), A
    XOR A : LD BC, DMASADL : OUT (C), A
    LD A, (BcsClipTop)
    ADD A, A                                  ; src_high = ClipTop * 2
    LD BC, DMASADH : OUT (C), A

    ; --- src page: (XOdd ? ODD : EVEN) + color ---
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    AND 7                                     ; защита: цвет 0..5
    LD B, A
    LD A, (BcsXOdd)
    OR A
    JR Z, .bcs_src_even
    LD A, BALLS_DMA_ODD_PAGE
    JR .bcs_src_have
.bcs_src_even:
    LD A, BALLS_DMA_EVEN_PAGE
.bcs_src_have:
    ADD A, B
    LD BC, DMASADX : OUT (C), A

    ; --- dst (текущий shadow) ---
    LD A, (BcsDstLow) : LD BC, DMADADL : OUT (C), A
    LD A, (BcsDstMid) : LD BC, DMADADH : OUT (C), A
    LD A, (BcsPageOver)
    LD B, A
    LD A, (ShadowPageBase)
    ADD A, B
    LD BC, DMADADX : OUT (C), A

    LD A, DMA_BLT_8BPP_MODE : LD BC, DMACTR : OUT (C), A
.bcs_blit_wait:
    IN A, (C)
    AND DMAWNR
    JR NZ, .bcs_blit_wait

    ; --- save new dst as prev ---
    LD A, (BcsDstLow)  : LD (IX+0), A
    LD A, (BcsDstMid)  : LD (IX+1), A
    LD A, (BcsPageOver)
    LD B, A
    LD A, (ShadowPageBase)
    ADD A, B
    LD (IX+2), A
    LD A, (BcsNumLines) : LD (IX+3), A
    LD (IY+0), 1

.bcs_advance:
    LD BC, 4
    ADD IX, BC
    INC IY
    LD A, (TmpChainIdx)
    INC A
    LD (TmpChainIdx), A
    JP .bcs_loop
.bcs_done:
    RET

; ================================================================
; BcsPreClassify — для каждого slot 0..MAX_CHAIN_BALLS-1:
;   - i >= SlotsLen      → DESTROY
;   - Slots[i] is GAP    → DESTROY
;   - HSA-i < 0          → PRESERVE  (cascade roll-back, шар "за стартом")
;   - t < 0              → PRESERVE  (HeadSub overflow)
;   - off-canvas (X/Y)   → PRESERVE  (визуально невидимо, но ball ещё logical)
;   - иначе              → DRAW + кэш геометрии в BcsCacheStruct[i*6..i*6+5]
; ================================================================
BcsPreClassify:
    XOR A : LD (TmpChainIdx), A
    LD B, MAX_CHAIN_BALLS
.bpc_loop:
    PUSH BC

    ; --- Test 1: i >= SlotsLen ---
    LD A, (TmpChainIdx)
    LD HL, Chain0_SlotsLen
    CP (HL)
    JP NC, .bpc_destroy

    ; --- Test 2: Slots[i] is GAP color ---
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_Slots
    ADD HL, DE
    LD A, (HL)
    CP NUM_BALL_COLORS
    JP NC, .bpc_destroy                       ; >= NUM_BALL_COLORS = GAP_STOP/GAP_CASCADE/etc

    ; --- Test 2b: Exploding shар скрывается при frame >= EXPLOSION_HIDE_AT ---
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_ExplodingFrame
    ADD HL, DE
    LD A, (HL)
    CP EXPLOSION_HIDE_AT
    JP NC, .bpc_destroy                       ; frame >= HIDE_AT → не рисуем (blank flash)

    ; --- Test 3: HSA - i < 0 ---
    LD A, (Chain0_HeadSlotAbs)
    LD HL, TmpChainIdx
    SUB (HL)
    JP C, .bpc_preserve

    LD H, 0
    LD L, A
    ADD HL, HL : ADD HL, HL : ADD HL, HL
    ADD HL, HL : ADD HL, HL                    ; HL = (HSA-i)*32

    LD A, (Chain0_HeadSub)
    LD E, A : LD D, 0
    ADD HL, DE                                 ; +HeadSub

    PUSH HL
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD DE, Chain0_SlotOffsets
    ADD HL, DE
    LD A, (HL)
    LD E, A : LD D, 0
    BIT 7, A
    JR Z, .bpc_so_pos
    DEC D                                      ; sign-extend negative SlotOffset
.bpc_so_pos:
    POP HL
    ADD HL, DE                                 ; HL = t (signed)
    BIT 7, H
    JP NZ, .bpc_preserve                       ; t < 0 → PRESERVE

    ; Clamp t to TRACK_NUM_POINTS-1 (чтобы хвост на конце трека не лез за границу)
    PUSH HL
    LD DE, TRACK_NUM_POINTS
    AND A
    SBC HL, DE
    POP HL
    JR C, .bpc_t_in
    LD HL, TRACK_NUM_POINTS - 1
.bpc_t_in:
    ADD HL, HL : ADD HL, HL                    ; t*4 (TrackData stride)
    LD DE, TrackData
    ADD HL, DE
    LD A, (HL) : SUB DMA_SPRITE_HALF : LD (TmpChainX), A   : INC HL
    LD A, (HL) : SBC A, 0            : LD (TmpChainX+1), A : INC HL
    LD A, (HL) : SUB DMA_SPRITE_HALF : LD (TmpChainY), A   : INC HL
    LD A, (HL) : SBC A, 0            : LD (TmpChainY+1), A

    ; --- Horizontal: X out of [0..DMA_X_MAX-1] → PRESERVE ---
    LD HL, (TmpChainX)
    BIT 7, H
    JP NZ, .bpc_preserve
    LD DE, DMA_X_MAX
    AND A
    SBC HL, DE
    JP NC, .bpc_preserve

    ; --- Vertical clip: ClipTop / ClipBot, clamp Y_dst к [0..CANVAS_H-BALL_PIX] ---
    XOR A
    LD (BcsClipTop), A
    LD (BcsClipBot), A

    LD HL, (TmpChainY)
    BIT 7, H
    JR Z, .bpc_y_not_neg
    LD A, H
    INC A
    JP NZ, .bpc_preserve                       ; Y_high != #FF → слишком далеко вверх
    LD A, L
    NEG
    CP BALL_PIX
    JP NC, .bpc_preserve                       ; clip_top >= BALL_PIX → невидим
    LD (BcsClipTop), A
    XOR A : LD (TmpChainY), A : LD (TmpChainY+1), A
.bpc_y_not_neg:

    LD HL, (TmpChainY)
    LD DE, CANVAS_H - BALL_PIX + 1
    AND A
    SBC HL, DE
    JR C, .bpc_y_in
    INC HL
    LD A, H
    OR A
    JP NZ, .bpc_preserve
    LD A, L
    CP BALL_PIX
    JP NC, .bpc_preserve
    LD (BcsClipBot), A
.bpc_y_in:

    ; NumLines = BALL_PIX - ClipTop - ClipBot
    LD A, BALL_PIX
    LD HL, BcsClipTop
    SUB (HL)
    LD HL, BcsClipBot
    SUB (HL)
    JP Z, .bpc_preserve
    JP M, .bpc_preserve
    LD (BcsNumLines), A

    ; --- Compute DMA dst bytes ---
    LD A, (TmpChainY)
    LD B, A                                    ; B = Y_low8
    SRL A : SRL A : SRL A : SRL A : SRL A
    LD C, A
    LD A, (TmpChainY+1)
    AND 1
    SLA A : SLA A : SLA A
    OR C
    LD (BcsPageOver), A

    LD A, B
    AND #1F
    ADD A, A
    LD C, A
    LD A, (TmpChainX+1)
    AND 1
    OR C
    LD (BcsDstMid), A

    LD A, (TmpChainX)
    LD B, A
    AND 1
    LD (BcsXOdd), A
    LD A, B
    AND #FE
    LD (BcsDstLow), A

    ; --- Save cache[i] = [DstLow, DstMid, PageOver, NumLines, ClipTop, XOdd] ---
    LD A, (TmpChainIdx)
    LD H, 0 : LD L, A
    LD D, H : LD E, L
    ADD HL, HL
    ADD HL, DE                                 ; i*3
    ADD HL, HL                                 ; i*6
    LD DE, BcsCacheStruct
    ADD HL, DE
    LD A, (BcsDstLow)    : LD (HL), A : INC HL
    LD A, (BcsDstMid)    : LD (HL), A : INC HL
    LD A, (BcsPageOver)  : LD (HL), A : INC HL
    LD A, (BcsNumLines)  : LD (HL), A : INC HL
    LD A, (BcsClipTop)   : LD (HL), A : INC HL
    LD A, (BcsXOdd)      : LD (HL), A

    LD A, BCS_DRAW
    JP .bpc_set_flag

.bpc_destroy:
    LD A, BCS_DESTROY
    JP .bpc_set_flag

.bpc_preserve:
    LD A, BCS_PRESERVE

.bpc_set_flag:
    LD HL, BcsSkipFlag
    LD E, A                                    ; save flag in E
    LD A, (TmpChainIdx)
    LD D, 0
    LD C, A
    LD B, 0
    ADD HL, BC
    LD (HL), E

    LD A, (TmpChainIdx)
    INC A
    LD (TmpChainIdx), A

    POP BC
    DEC B
    JP NZ, .bpc_loop
    RET

BcsDstLow:    DB 0
BcsDstMid:    DB 0
BcsPageOver:  DB 0
BcsPrevLow:   DB 0
BcsPrevMid:   DB 0
BcsPrevPage:  DB 0
BcsGoldenOff: DB 0
BcsClipTop:   DB 0   ; число обрезанных верхних строк шара (0..BALL_PIX-1), 0 если шар полностью внутри
BcsClipBot:   DB 0   ; число обрезанных нижних строк шара (0..BALL_PIX-1)
BcsNumLines:  DB 0   ; реальное число копируемых строк = BALL_PIX - ClipTop - ClipBot
BcsXOdd:      DB 0   ; bit 0 от X (top-left) — выбор even/odd-спрайта при blit'е

; Killzone DMA temp variables
TmpKzX:        DW 0
TmpKzY:        DW 0
TmpKzLow:      DB 0
TmpKzMid:      DB 0
TmpKzPageOver: DB 0
TmpKzSrcPage:  DB 0

VisiblePageBase: DB CANVAS_A_PAGE_BASE
ShadowPageBase:  DB CANVAS_B_PAGE_BASE

; Per-slot prev: 4 байта (dst_low, dst_mid, dst_page, num_lines) + 1 valid-флаг.
; num_lines нужно для restore: при partial-blit (clip top/bot) копируется не BALL_PIX,
; а столько же сколько было при оригинальном blit'е.
ChainPrevDstA:    DS MAX_CHAIN_BALLS * 4
ChainPrevValidA:  DS MAX_CHAIN_BALLS
ChainPrevDstB:    DS MAX_CHAIN_BALLS * 4
ChainPrevValidB:  DS MAX_CHAIN_BALLS

; BcsPreClassify заполняет SkipFlag[i] (0=DRAW, 1=DESTROY, 2=PRESERVE) и
; BcsCacheStruct[i*6..i*6+5] = (DstLow, DstMid, PageOver, NumLines, ClipTop, XOdd) для DRAW.
; PASS1 и PASS2 потом читают это вместо повторного вычисления геометрии.
BcsSkipFlag:      DS MAX_CHAIN_BALLS
BcsCacheStruct:   DS MAX_CHAIN_BALLS * 6

; ================================================================
; BLIT KILLZONE TO SHADOW — рисует анимированный череп в конце трека на canvas.
; Always restore golden→shadow + always blit current frame (без prev tracking).
; Использует BcsGoldenOff установленный ранее в BlitChainToShadow.
; ================================================================
BlitKillzoneToShadow:
    LD A, (KzVisible)
    OR A
    RET Z

    LD BC, FMADDR : XOR A : OUT (C), A
    LD A, KZ_PIX/2-1 : LD BC, DMALEN : OUT (C), A   ; 32 words = 64 px wide
    LD A, KZ_PIX/2-1 : LD BC, DMANUM : OUT (C), A   ; 32 lines per half

    ; top-left = center - 32
    LD HL, (KzCenterX)
    LD DE, KZ_PIX/2
    AND A
    SBC HL, DE
    LD (TmpKzX), HL
    BIT 7, H
    RET NZ
    LD DE, 360 - KZ_PIX + 1                          ; = 297
    AND A
    SBC HL, DE
    JR C, .kz_x_ok
    RET
.kz_x_ok:
    LD HL, (KzCenterY)
    LD DE, KZ_PIX/2
    AND A
    SBC HL, DE
    LD (TmpKzY), HL
    BIT 7, H
    RET NZ
    LD DE, 288 - KZ_PIX + 1                          ; = 225
    AND A
    SBC HL, DE
    JR C, .kz_y_ok
    RET
.kz_y_ok:

    LD A, (TmpKzX)
    LD (TmpKzLow), A

    ; ============= TOP HALF: rows 0..31, dst Y = TmpKzY ===========
    LD A, (TmpKzY)
    LD B, A
    SRL A : SRL A : SRL A : SRL A : SRL A
    LD C, A
    LD A, (TmpKzY+1)
    AND 1
    SLA A : SLA A : SLA A
    OR C
    LD (TmpKzPageOver), A
    LD A, B
    AND #1F
    ADD A, A
    LD C, A
    LD A, (TmpKzX+1)
    AND 1
    OR C
    LD (TmpKzMid), A

    CALL KzRestoreHalf
    LD A, KILLZONE_DMA_PAGE_TOP
    CALL KzBlitHalf

    ; ============= BOTTOM HALF: rows 32..63, dst Y = TmpKzY + 32 ===
    LD HL, (TmpKzY)
    LD DE, KZ_PIX/2
    ADD HL, DE
    LD (TmpKzY), HL

    LD A, L
    LD B, A
    SRL A : SRL A : SRL A : SRL A : SRL A
    LD C, A
    LD A, H
    AND 1
    SLA A : SLA A : SLA A
    OR C
    LD (TmpKzPageOver), A
    LD A, B
    AND #1F
    ADD A, A
    LD C, A
    LD A, (TmpKzX+1)
    AND 1
    OR C
    LD (TmpKzMid), A

    CALL KzRestoreHalf
    LD A, KILLZONE_DMA_PAGE_BOT
    CALL KzBlitHalf
    RET

; --- KzRestoreHalf: golden → shadow на (TmpKzLow, TmpKzMid, TmpKzPageOver) ---
KzRestoreHalf:
    LD A, (TmpKzLow) : LD BC, DMASADL : OUT (C), A
    LD A, (TmpKzMid) : LD BC, DMASADH : OUT (C), A
    LD A, (TmpKzPageOver)
    LD B, A
    LD A, (BcsGoldenOff)
    ADD A, B
    LD C, A
    LD A, (ShadowPageBase)
    ADD A, C
    LD BC, DMASADX : OUT (C), A
    LD A, (TmpKzLow) : LD BC, DMADADL : OUT (C), A
    LD A, (TmpKzMid) : LD BC, DMADADH : OUT (C), A
    LD A, (TmpKzPageOver)
    LD B, A
    LD A, (ShadowPageBase)
    ADD A, B
    LD BC, DMADADX : OUT (C), A
    LD A, DMA_BLT_8BPP_MODE : LD BC, DMACTR : OUT (C), A
.kzr_wait:
    IN A, (C) : AND DMAWNR : JR NZ, .kzr_wait
    RET

; --- KzBlitHalf: src page (в A) → shadow на (TmpKzLow, TmpKzMid, TmpKzPageOver) ---
KzBlitHalf:
    LD (TmpKzSrcPage), A
    XOR A : LD BC, DMASADL : OUT (C), A
    XOR A : LD BC, DMASADH : OUT (C), A
    LD A, (TmpKzSrcPage)
    LD BC, DMASADX : OUT (C), A
    LD A, (TmpKzLow) : LD BC, DMADADL : OUT (C), A
    LD A, (TmpKzMid) : LD BC, DMADADH : OUT (C), A
    LD A, (TmpKzPageOver)
    LD B, A
    LD A, (ShadowPageBase)
    ADD A, B
    LD BC, DMADADX : OUT (C), A
    LD A, DMA_BLT_8BPP_MODE : LD BC, DMACTR : OUT (C), A
.kzb_wait:
    IN A, (C) : AND DMAWNR : JR NZ, .kzb_wait
    RET

; ================================================================
; HIDE CHAIN SPRITES — обнуляет SFILE-дескрипторы цепочки в active+invisible.
; ВАЖНО: ACT=1 нужен чтобы TSU не остановился перед cursor (иначе курсор пропадает).
; ================================================================
HideChainSprites:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, DESC_CHAIN0
    LD B, TSU_CHAIN_SPRITES                    ; SFILE-резерв, не VDC max
.hcs_loop:
    LD (HL), #2C : INC HL                     ; Y_L (off-screen)
    LD (HL), SPACT+SPSIZ24+1 : INC HL         ; ACT=1, SIZE=24, Y[8]=1
    LD (HL), 0 : INC HL                       ; X_L
    LD (HL), SPSIZ24 : INC HL                 ; X[8]=0
    LD (HL), 0 : INC HL                       ; TNUM
    LD (HL), 0 : INC HL                       ; SPAL
    DJNZ .hcs_loop
    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; ОБНОВЛЕНИЕ СПРАЙТА КУРСОРА
; Дескриптор #020C (после жабы и preview-шарика).
; Спрайт 16x16, TNUM=512 (первый тайл страницы 7), SPAL=1.
; ================================================================
UpdateCursorSprite:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, DESC_CURSOR

    LD DE, (MouseAbsY)
    LD (HL), E : INC HL                         ; Y_L
    LD A, D : AND 1 : OR SPACT+SPSIZ16          ; курсор остаётся 16×16
    LD (HL), A : INC HL

    LD DE, (MouseAbsX)
    LD (HL), E : INC HL                         ; X_L
    LD A, D : AND 1 : OR SPSIZ16
    LD (HL), A : INC HL

    LD (HL), 0 : INC HL                         ; TNUM_L = 0 (TNUM=2048 в page 10)
    LD (HL), #18                                ; TNUM_H=8 + SPAL=1 (<<4=#10) → byte = 0x18

    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; ОБНОВЛЕНИЕ MOUTH-BALL (16×16) — текущий цвет, во рту лягушки.
; Frog 64×64, центр (FrogX+32, FrogY+32). Mouth = +Dir сторона.
; Ball center = frog_center + 8*Dir, top-left (16×16) = center - 8 = FrogX + 24 + 8*Dir.
; TNUM = 2304 + COLOR*2 (atlas balls 16×16 в page 10), SPAL = COLOR + 2.
; ================================================================
UpdatePreviewSprite:
    LD A, (ShotCooldown)
    OR A
    JP NZ, .ups_invisible

    ; --- X = FrogX + 20 + Cos*9/8 (mouth ball на distance 18 от центра frog)
    LD A, (FrogDirCos)
    LD L, A : LD H, 0
    BIT 7, A
    JR Z, .ups_x_pos
    DEC H
.ups_x_pos:
    LD A, (FrogDirCos)
    SRA A : SRA A : SRA A                 ; A = Cos/8 (signed -2..+2)
    LD E, A : LD D, 0
    BIT 7, A
    JR Z, .ups_x_p2
    DEC D
.ups_x_p2:
    ADD HL, DE                            ; HL = Cos + Cos/8 = Cos*9/8
    LD BC, (FrogX)
    ADD HL, BC
    LD BC, 20
    ADD HL, BC
    PUSH HL

    ; --- Y = FrogY + 20 + Sin*9/8
    LD A, (FrogDirSin)
    LD L, A : LD H, 0
    BIT 7, A
    JR Z, .ups_y_pos
    DEC H
.ups_y_pos:
    LD A, (FrogDirSin)
    SRA A : SRA A : SRA A
    LD E, A : LD D, 0
    BIT 7, A
    JR Z, .ups_y_p2
    DEC D
.ups_y_p2:
    ADD HL, DE
    LD BC, (FrogY)
    ADD HL, BC
    LD BC, 20
    ADD HL, BC

    LD BC, FMADDR : LD A, FM_EN : OUT (C), A

    EX DE, HL                             ; DE = Y
    LD HL, DESC_PREVIEW
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPACT+SPSIZ24
    LD (HL), A : INC HL

    POP DE                                ; DE = X
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPSIZ24
    LD (HL), A : INC HL

    ; TNUM/SPAL по NextBallColor (ball atlas 24×24: TNUM=2304+COLOR*3)
    LD A, (NextBallColor)
    LD D, A : ADD A, A : ADD A, D
    LD (HL), A : INC HL
    LD A, (NextBallColor)
    ADD A, 2
    ADD A, A : ADD A, A : ADD A, A : ADD A, A
    OR 9
    LD (HL), A

    LD BC, FMADDR : XOR A : OUT (C), A
    JP UpdateBackPreviewSprite

.ups_invisible:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, DESC_PREVIEW
    LD (HL), 44 : INC HL
    LD (HL), SPACT+SPSIZ24+1 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), SPSIZ24 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), 0
    LD BC, FMADDR : XOR A : OUT (C), A
    JP UpdateBackPreviewSprite

; ================================================================
; ОБНОВЛЕНИЕ BACK-PREVIEW (8×8) — следующий цвет, на спине лягушки.
; Spine = -Dir сторона. Center = frog_center - 8*Dir, top-left (8×8) = center - 4
;   = FrogX + 28 - 8*Dir.
; TNUM = 2432 + COLOR (preview atlas 8×8 в page 10), SPAL = COLOR + 2.
; (NextBallColor — это цвет ТЕКУЩЕГО выстрела; для true "следующего" нужен
;  отдельный индекс. Пока показываем тот же цвет — дополнительный preview.)
; ================================================================
UpdateBackPreviewSprite:
    LD A, (ShotCooldown)
    OR A
    JP NZ, .bps_invisible

    LD A, (FrogAngle)
    SRL A : SRL A : SRL A
    LD E, A
    LD D, 0

    LD HL, CosTab16
    ADD HL, DE
    LD A, (HL)
    NEG                                   ; -Cos для spine-side
    LD L, A : LD H, 0
    BIT 7, A
    JR Z, .bps_x_pos
    DEC H
.bps_x_pos:
    LD BC, (FrogX)
    ADD HL, BC
    LD BC, 28
    ADD HL, BC                            ; X = FrogX + 28 - Cos*16
    PUSH HL

    LD HL, SinTab16
    ADD HL, DE
    LD A, (HL)
    NEG
    LD L, A : LD H, 0
    BIT 7, A
    JR Z, .bps_y_pos
    DEC H
.bps_y_pos:
    LD BC, (FrogY)
    ADD HL, BC
    LD BC, 28
    ADD HL, BC                            ; Y = FrogY + 28 - 8*DirY

    LD BC, FMADDR : LD A, FM_EN : OUT (C), A

    EX DE, HL
    LD HL, DESC_BACK_PREVIEW
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPACT+SPSIZ8
    LD (HL), A : INC HL

    POP DE
    LD (HL), E : INC HL
    LD A, D : AND 1 : OR SPSIZ8
    LD (HL), A : INC HL

    ; TNUM = 2496 + COLOR (preview atlas — carpet row 39, после balls 24×24 в rows 36..38)
    LD A, (NextBallColor)
    ADD A, 192                            ; TNUM_L = 192 + COLOR (0xC0 + COLOR = 2496+COLOR low byte)
    LD (HL), A : INC HL
    LD A, (NextBallColor)
    ADD A, 2
    ADD A, A : ADD A, A : ADD A, A : ADD A, A
    OR 9
    LD (HL), A

    LD BC, FMADDR : XOR A : OUT (C), A
    RET

.bps_invisible:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD HL, DESC_BACK_PREVIEW
    LD (HL), 44 : INC HL
    LD (HL), SPACT+SPSIZ8+1 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), SPSIZ8 : INC HL
    LD (HL), 0 : INC HL
    LD (HL), 0
    LD BC, FMADDR : XOR A : OUT (C), A
    RET

; ================================================================
; ОБРАБОТКА МЫШИ — абс. позиция курсора + левая кнопка = выстрел
; Kempston Mouse: счётчики X/Y относительные (8-bit wrap), знаковая дельта
; ================================================================
HandleMouse:
    ; Сбрасываем флаг "мышь двигалась" — взводим только при ненулевой дельте
    XOR A
    LD (MouseMoved), A

    ; --- X (накапливаем абсолютную позицию курсора) ---
    LD BC, MOUSE_X
    IN A, (C)
    LD HL, MouseXPrev
    LD B, (HL)
    LD (HL), A
    SUB B               ; A = дельта X (знаковый 8-bit)
    CALL ClampDelta     ; |delta|>100 → 0 (фильтр выбросов 8-bit wrap)
    JR Z, .mx_zero
    PUSH AF
    LD A, 1
    LD (MouseMoved), A
    POP AF
.mx_zero:
    LD E, A
    LD D, 0
    BIT 7, A
    JR Z, .mx_pos
    DEC D
.mx_pos:
    LD HL, (MouseAbsX)
    ADD HL, DE
    BIT 7, H
    JR Z, .mx_hi
    LD HL, 0
    JR .mx_done
.mx_hi:
    LD DE, CURSOR_MAX_X
    LD A, H : CP D : JR C, .mx_done
    JR NZ, .mx_clamp
    LD A, L : CP E : JR C, .mx_done
.mx_clamp:
    LD HL, CURSOR_MAX_X
.mx_done:
    LD (MouseAbsX), HL

    ; --- Y (накапливаем абсолютную позицию курсора) ---
    LD BC, MOUSE_Y
    IN A, (C)
    LD HL, MouseYPrev
    LD B, (HL)
    LD (HL), A
    SUB B
    NEG                 ; Kempston Y: positive=up, invert for screen Y-down
    CALL ClampDelta     ; |delta|>100 → 0 (фильтр выбросов 8-bit wrap)
    JR Z, .my_zero
    PUSH AF
    LD A, 1
    LD (MouseMoved), A
    POP AF
.my_zero:
    LD E, A
    LD D, 0
    BIT 7, A
    JR Z, .my_pos
    DEC D
.my_pos:
    LD HL, (MouseAbsY)
    ADD HL, DE
    BIT 7, H
    JR Z, .my_hi
    LD HL, 0
    JR .my_done
.my_hi:
    LD DE, CURSOR_MAX_Y
    LD A, H : CP D : JR C, .my_done
    JR NZ, .my_clamp
    LD A, L : CP E : JR C, .my_done
.my_clamp:
    LD HL, CURSOR_MAX_Y
.my_done:
    LD (MouseAbsY), HL

    ; Повернуть лягушку в сторону курсора — только если мышь двигалась
    LD A, (MouseMoved)
    OR A
    CALL NZ, ComputeFrogAngle

    ; Mouse fire: Unreal Speccy кладёт ЛКМ в бит 0 порта #FADF (а не в бит 1
    ; как стандарт Kempston). Polarity нормальная: 1=нажата.
    ; Нарастающий фронт 0→1 = выстрел ровно один раз при нажатии.
    LD BC, MOUSE_BTN
    IN A, (C)
    AND %00000001                  ; ЛКМ — бит 0 в Unreal
    LD HL, MouseBtnPrev
    LD B, (HL)
    LD (HL), A
    OR A
    JR Z, .no_shot                 ; ЛКМ не нажата → ничего
    LD A, B
    OR A
    JR NZ, .no_shot                ; ЛКМ была нажата в прошлом кадре → не первый кадр
    CALL ShootBall
.no_shot:
    RET

; ================================================================
; ClampDelta — фильтр выбросов от 8-bit wrap Kempston Mouse
; Вход:  A = знаковая дельта (-128..127)
; Выход: A = A если |A|<=100, иначе 0. Z флаг отражает результат.
; Сохраняет: BC, DE, HL.
; ================================================================
ClampDelta:
    ; В fullscreen mouse capture wrap почти не возникает — порог поднят до 127.
    ; Так что фактически фильтр пропускает любую дельту, оставаясь как safety.
    OR A
    RET Z
    PUSH BC
    LD C, A
    BIT 7, A
    JR Z, .cd_pos
    NEG
    CP 128
    JR NC, .cd_zero
    LD A, C
    POP BC
    OR A
    RET
.cd_pos:
    CP 128
    JR NC, .cd_zero
    POP BC
    OR A
    RET
.cd_zero:
    POP BC
    XOR A
    RET

; ================================================================
; ПАЛИТРА:
; SPAL=0 (CRAM #0000-#001F) — жаба (frog_pal.bin)
; SPAL=1 (CRAM #0020-#003F) — курсор (cursor_pal.bin)
; SPAL=2..7 (CRAM #0040-#00FF) — 6 шаров (balls_pal.bin, 192 байта)
; CRAM #0100..#01FF — 128 цветов фона уровня (canvas pixel value = direct CRAM index 128..255)
; ================================================================
InitPalette:
    LD BC, FMADDR : LD A, FM_EN : OUT (C), A
    LD BC, PALSEL : XOR A : OUT (C), A
    LD HL, PaletteData   : LD DE, #0000 : LD BC, 512 : LDIR
    LD HL, CursorPalette : LD DE, #0020 : LD BC, 32  : LDIR
    LD HL, BallsPalette  : LD DE, #0040 : LD BC, 192 : LDIR
    LD HL, BgCanvasPalette : LD DE, #0100 : LD BC, 256 : LDIR
    LD BC, FMADDR : XOR A : OUT (C), A
    RET


; ================================================================
; ДАННЫЕ
; ================================================================
FrogX:      DW FROG_INIT_X
FrogY:      DW FROG_INIT_Y
FrogAngle:  DB 0
LevelNumColors: DB 6   ; runtime-число цветов на текущем уровне (1..NUM_BALL_COLORS).
                       ; RandomBallColor / RandomChainColor берут mod этого значения.
NextBallColor: DB 0    ; цвет следующего выстрела (RandomBallColor: LFSR × RTC сек)
BallColorSeed:  DW 0   ; seed LFSR для NextBallColor (init из RTC секунд)
ChainColorSeed: DW 0   ; seed LFSR для NextChainColor (init фикс, scramble RTC при первом вызове)
ChainColorFirst: DB 1  ; флаг "первый вызов RandomChainColor" (для RTC scramble)
CascadeState:    DB 0  ; legacy, не используется в VDC-модели (= всегда 0)
CascadeIdx:      DB 0
CascadeWait:     DB 0
CascadeDelay:    DB 0
StopModeTimer:   DB 0
CompactTimer:    DB 0
GapStepCounter:  DB 0  ; subdivider для GAP movement (1 step каждые GAP_STEP_FRAMES)
ChainFreezeCounter: DB 0 ; пауза hsub-инкремента на N кадров после insert/cascade-close
MatchScanIdx:    DB 0  ; idx где scan для new match (set после GAP closure), #FF = no scan
TmpGapIdx:       DB 0  ; рабочий регистр в DoGapStep (idx найденного GAP-cell для удаления)
KzFrame:         DB 0  ; current killzone animation frame (0..KZ_NUM_FRAMES-1)
KzFrameWait:     DB 0  ; счётчик кадров до switch на след. anim-frame
KzCenterX:       DW 0  ; центр killzone (= TrackData[TRACK_NUM_POINTS-1])
KzCenterY:       DW 0
KzVisible:       DB 0  ; 1 = killzone готов к рендеру (после Init)
TmpColorMask:    DB 0  ; 6-бит маска цветов цепочки (BuildColorMask)
ShotCooldown:    DB 0  ; счётчик кадров между выстрелами (preview скрыт когда > 0)
KeySpacePrev: DB 0     ; флаг debounce Space
MouseXPrev: DB 0
MouseYPrev: DB 0
MouseAbsX:  DW MOUSE_INIT_X   ; курсор справа от лягушки → стартовый угол ~0
MouseAbsY:  DW MOUSE_INIT_Y
MouseMoved:       DB 0  ; флаг: 1 если мышь двигалась в этом кадре
MouseBtnPrev:     DB 3  ; "нейтральное" состояние кнопок мыши (запомнено в InitGame)
MouseBtnFireFlag: DB 0  ; 1 = выстрел уже сработал на текущем нажатии (debounce)
TmpAngle:         DB 0  ; временный угол для SpawnBall
TmpSpeed:         DB 0  ; временная скорость для SpawnBall
TmpChainX:        DW 0  ; top-left X (UpdateChainSprites)
TmpChainY:        DW 0  ; top-left Y
TmpChainColor:    DB 0  ; цвет (UpdateChainSprites)
TmpChainIdx:      DB 0  ; текущий индекс i в цикле по цепочке
FrameCounter:     DB 0  ; счётчик кадров
TickCount:        DB 0  ; инкрементируется ISR каждый vblank IRQ (50 Hz)
ProcessedTicks:   DB 0  ; счётчик обработанных в MainLoop тиков (Fixed Timestep)
BallsSpawned:     DB 0  ; всего заспавнено шаров для уровня (0..LEVEL_TOTAL_BALLS, saturate 255)
ChainStalled:     DB 0  ; 1 = head ждёт хвост (stop-mode после match-3); 0 = норм. движение
NextChainColor:   DB 0  ; цвет следующего шара спавна цепочки (0..3, цикл)
TmpBallCX:        DW 0  ; центр летящего шара (коллизия)
TmpBallCY:        DW 0
TmpChainCX:       DW 0  ; центр шара цепочки (из TrackData)
TmpChainCY:       DW 0
TmpInsertIdx:     DB 0  ; индекс вставки (InsertChainBall)
TmpHemSlotIdx:    DB 0  ; вход для ComputeSlotXY
TmpHemX:          DW 0  ; выход ComputeSlotXY: X
TmpHemY:          DW 0  ; выход ComputeSlotXY: Y
TmpDistPrev:      DW 0  ; Manhattan дистанция от ball до prev-соседа
TmpDistNext:      DW 0  ; Manhattan дистанция от ball до next-соседа
TmpHasPrev:       DB 0  ; 1 если найден non-GAP сосед слева от hit
TmpHasNext:       DB 0  ; 1 если найден non-GAP сосед справа от hit
TmpTargetIdx:     DB 0  ; финальный target_idx для InsertChainBall (i или i+1)
TmpNewOffset:     DB 0  ; временный offset для нового шара (midpoint formula)
TmpInsertColor:   DB 0  ; цвет вставляемого шара
TmpTargetX:       DW 0  ; target top-left X для approach-шара
TmpTargetY:       DW 0
TmpMatchColor:    DB 0  ; цвет run'а в CheckMatch3
TmpMatchLeft:     DB 0  ; левая граница run'а (включительно)
TmpMatchRight:    DB 0  ; правая граница run'а (включительно)
TmpMatchCount:    DB 0  ; длина run'а (>=3)
TmpMatchHalfShift: DB 0 ; legacy от rigid-body модели; в VDC не используется
; Кеш направления frog (заполняется в UpdateFrogSprite, читается в Update*Preview):
FrogDirCos: DB 0       ; signed: -16..+16 (CosTab16[FrogAngle>>3])
FrogDirSin: DB 0       ; signed: -16..+16 (SinTab16[FrogAngle>>3])
TmpCopyCount:     DB 0  ; число шаров хвоста, которые двигаем влево

BallTable:
    DS MAX_BALLS * 8

BallTargetIdx:
    DS MAX_BALLS                        ; цель chain-индекс для approach-state шаров

; --- ChainStateBlock для Chain0 (slot-array model, единственный источник правды).
Chain0_Slots:           DS MAX_SLOTS_PER_CHAIN ; цвет либо GAP_MARKER (Init заполнит GAP)
Chain0_SlotOffsets:     DS MAX_SLOTS_PER_CHAIN ; signed sub-cell offset для match/insert anim
Chain0_Shot2:           DS MAX_SLOTS_PER_CHAIN ; виртуальный выстрел тип 2 (= match-trigger
                                               ; рядом с закрытым GAP). 1=marker, 0=пусто.
                                               ; Ставится CheckMatch3 на Slots[lb-1] и Slots[rb+1]
                                               ; при появлении GAP. Сканируется после GAP closure:
                                               ; если рядом 3-в-ряд → match-3, иначе marker очищается.
Chain0_ExplodingFrame:  DS MAX_SLOTS_PER_CHAIN ; 0 = норм, 1..EXPLOSION_FRAMES = идёт анимация взрыва.
                                               ; В первых EXPLOSION_HIDE_AT-1 кадров шар виден (Slots[i]=color),
                                               ; затем DESTROY (не рендерится). После EXPLOSION_FRAMES финализация →
                                               ; Slots[i]=ExplodingMarker[i], ExplodingFrame[i]=0, DoGapStep продолжает.
Chain0_ExplodingMarker: DS MAX_SLOTS_PER_CHAIN ; GAP_STOP или GAP_CASCADE — value для финализации после anim.
Chain0_HeadSlotAbs:     DB 0                   ; абс. track-slot для Chain0_Slots[0]
Chain0_HeadSub:         DB 0                   ; 0..CELL_SIZE-1 sub-cell progress головы
Chain0_SlotsLen:        DB 0                   ; длина active range

; ================================================================
; ДАННЫЕ ПАЛИТРЫ И ТАБЛИЦ — РАЗМЕЩЕНЫ ПЕРЕД ТРЕКОМ.
; Палитра и таблицы должны быть в slot 1 (page 5), потому что код их адресует
; абсолютным адресом и читает в InitGame/runtime, ДО восстановления PAGE2=2.
; Большой track последним — может вылезать в slot 2 (page 2), нормально читается
; пока PAGE2 register = 2 (что мы восстанавливаем после tile-fill в InitGame).
; ================================================================
; atan(i/128)*256/(2*pi) для i=0..128, 129 элементов
; 4× разрешение vs исходной 33-элементной таблицы.
; Idx 128 (= точная диагональ E=C) = 32 unit = 45°
AtanTable:
    DB  0,  0,  1,  1,  1,  2,  2,  2
    DB  3,  3,  3,  3,  4,  4,  4,  5
    DB  5,  5,  6,  6,  6,  7,  7,  7
    DB  8,  8,  8,  8,  9,  9,  9, 10
    DB 10, 10, 11, 11, 11, 11, 12, 12
    DB 12, 13, 13, 13, 13, 14, 14, 14
    DB 15, 15, 15, 15, 16, 16, 16, 17
    DB 17, 17, 17, 18, 18, 18, 18, 19
    DB 19, 19, 19, 20, 20, 20, 20, 21
    DB 21, 21, 21, 22, 22, 22, 22, 23
    DB 23, 23, 23, 23, 24, 24, 24, 24
    DB 25, 25, 25, 25, 25, 26, 26, 26
    DB 26, 26, 27, 27, 27, 27, 27, 28
    DB 28, 28, 28, 28, 29, 29, 29, 29
    DB 29, 29, 30, 30, 30, 30, 30, 31
    DB 31, 31, 31, 31, 31, 32, 32, 32
    DB 32

; Sin/Cos нормализованные направления (-4..+4) для 32 кадров стрельбы.
; Используются в SpawnBall (стартовая позиция шара = жабо-центр + 6*Dir)
; и в MoveBall (BallX/Y += Dir каждый кадр).
DirXTable:
    DB   4,   4,   4,   3,   3,   2,   2,   1
    DB   0, 255, 254, 254, 253, 253, 252, 252
    DB 252, 252, 252, 253, 253, 254, 254, 255
    DB   0,   1,   2,   2,   3,   3,   4,   4
DirYTable:
    DB   0,   1,   2,   2,   3,   3,   4,   4
    DB   4,   4,   4,   3,   3,   2,   2,   1
    DB   0, 255, 254, 254, 253, 253, 252, 252
    DB 252, 252, 252, 253, 253, 254, 254, 255

; Cos/Sin × 16, signed 8-bit, 32 точки на круге (шаг 11.25°). Константный радиус 16,
; используются для размещения mouth-ball и back-preview на edge frog 64×64.
; CosTab[N] = X-component, SinTab[N] = Y-component (screen-coords: +Y вниз).
CosTab16:
    DB  16,  16,  15,  13,  11,   9,   6,   3
    DB   0, 253, 250, 247, 245, 243, 241, 240
    DB 240, 240, 241, 243, 245, 247, 250, 253
    DB   0,   3,   6,   9,  11,  13,  15,  16
SinTab16:
    DB   0,   3,   6,   9,  11,  13,  15,  16
    DB  16,  16,  15,  13,  11,   9,   6,   3
    DB   0, 253, 250, 247, 245, 243, 241, 240
    DB 240, 240, 241, 243, 245, 247, 250, 253

PaletteData:
    INCBIN "frog_pal.bin"           ; 512 байт CRAM, записи 0-15 = жаба (SPAL=0)
CursorPalette:
    INCBIN "cursor_pal.bin"         ; 32 байта CRAM, 16 записей для SPAL=1
BallsPalette:
    INCBIN "balls_pal.bin"          ; 192 байт = 6 палитр × 32 (SPAL 2..7)
BgCanvasPalette:
    INCBIN "level_01_canvas_pal.bin"  ; 256 байт = 128 цветов CRAM #0100..#01FF
BallsDmaPalette:
    INCBIN "balls_dma_pal.bin"        ; 64 байта = 32 word, грузить в CRAM #80 (= byte offset 256)

; Трек уровня — последний (большой массив, может вылезать в slot 2).
; Формат: DW X, DW Y, ..., DW #FFFF (LE uint16 пары + маркер).
TrackData:
    INCBIN "level_01.bin"
TrackEnd:
TRACK_NUM_POINTS EQU (TrackEnd - TrackData - 2) / 4

    ; Frog 64×64 — 4 страницы (carpet rows 0..31). SGPAGE=6.
    SLOT 1 : PAGE 6 : ORG #4000
    INCBIN "frog_gfx_64.bin", 0, 16384

    SLOT 1 : PAGE 7 : ORG #4000
    INCBIN "frog_gfx_64.bin", 16384, 16384

    SLOT 1 : PAGE 8 : ORG #4000
    INCBIN "frog_gfx_64.bin", 32768, 16384

    SLOT 1 : PAGE 9 : ORG #4000
    INCBIN "frog_gfx_64.bin", 49152, 16384

    ; Cursor + balls + preview в page 10 (=#A): начинается с carpet row 32 = TNUM 2048
    SLOT 1 : PAGE 10 : ORG #4000
    INCBIN "cursor_gfx.bin"          ; курсор 16×16 — carpet rows 32..33 (TNUM 2048..2051)
    DEFS 4096, 0                     ; carpet rows 34..35 пусто
    INCBIN "balls24_gfx.bin"         ; 6 шаров 24×24 — carpet rows 36..38 (TNUM 2304..)
    INCBIN "preview_gfx.bin"         ; 6 preview 8×8 — carpet row 38 (TNUM 2432..)

    SLOT 1 : PAGE 5

    ; Экспорт в бинарники для SPG-сборки.
    SAVEBIN "Build/Legacy/main0.bin", #6000, #2000     ; slot 1 part — 8K
    SAVEBIN "Build/Legacy/main1.bin", #8000, #4000     ; slot 2 part — 16K (TrackData spillover + zeros)

    SLOT 1 : PAGE 6
    SAVEBIN "frog_p0.bin", #4000, #4000   ; frog 64×64 page 6 — 16K
    SLOT 1 : PAGE 7
    SAVEBIN "frog_p1.bin", #4000, #4000   ; frog 64×64 page 7 — 16K
    SLOT 1 : PAGE 8
    SAVEBIN "frog_p2.bin", #4000, #4000   ; frog 64×64 page 8 — 16K
    SLOT 1 : PAGE 9
    SAVEBIN "frog_p3.bin", #4000, #4000   ; frog 64×64 page 9 — 16K
    SLOT 1 : PAGE 10
    SAVEBIN "Build/Legacy/page_a.bin", #4000, #4000    ; cursor+balls+preview — 16K

    LABELSLIST "Build/Legacy/user.l"




