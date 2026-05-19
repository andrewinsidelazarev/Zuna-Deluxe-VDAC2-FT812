; ============================================================================
; Zuma Deluxe VDAC2 — main.asm
; ----------------------------------------------------------------------------
; Точка сборки. Использует TSLib из Docs/TSLib/.
; Layout:
;   Page 0 (#0000..#3FFF mapped at slot 0): TSLib code, ORG #1000
;   Page 5 (#4000..#7FFF mapped at slot 1): Core code, ORG #6000
; После Init_Core slot/page mapping: page1=5, page2=2, page3=8.
; Стек в slot 1 (#40F2) — между Resolution* указателями и началом кода.
; ============================================================================

                DEVICE ZXSPECTRUM4096
                define MAPPING_REGISTERS              ; реестры через FMADDR_REGS

; ----------------------------------------------------------------------------
; FT command buffer: TSLib дефолтит на #C000 (slot 3). После main0/main1 split
; main1_play код живёт в slot 3 → буфер перекрывает код → corruption за кадр.
; Перенесён в slot 1 free area после main0 (#5DA0..#7FFF = 8.5KB).
; ----------------------------------------------------------------------------
                define CMD_ADDRESS_PTR #5E00

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #5C00                        ; slot 1 (page 5), keep Core below #8000
StackTop             EQU #40F2
ResolutionWidthPtr   EQU #40F3                        ; куда FT_RESOLUTION пишет ширину (W word)
ResolutionHeightPtr  EQU #40F5                        ; высоту (H word)
MemoryPages          EQU #40F7                        ; page-numbers cache (для не-MAPPING_REGISTERS)
InterruptVA          EQU #4000                        ; IM2 vector area (page-aligned)

TSLib                EQU #1000                        ; адрес где живёт TSLib
TSLibPage            EQU #00                          ; страница TSLib

; --- Circular RAM log EQU (используется и в slot 0 Log routines, и в slot 1 Core hooks) ---
GAMELOG_ADDR        EQU #4800
GAMELOG_IDX_ADDR    EQU #5000
GAMELOG_FROZEN_ADDR EQU #5001
LOG_TMP_TYPE_ADDR   EQU #5002
LOG_TMP_CTX_ADDR    EQU #5003
LOG_TMP_DATA_ADDR   EQU #5004
LOG_END_ADDR        EQU #5008
EVT_SHOT_FIRED      EQU 1
EVT_BBOX_HIT        EQU 2
EVT_HEMI            EQU 3
EVT_INSERT          EQU 4
EVT_CASCADE_TRIGGER EQU 5

; --- Text atlases (nativealien48 ARGB4, red-yellow gradient). Объявлены здесь
; (ДО TSLib block) чтобы EQU были доступны во всех slot 0/1/3 функциях через
; sjasmplus forward-resolve. FT_RAM_G #0000..#10000 = 64K free area (раньше
; не использовалась, bg начинается с #010000). Размеры см. text_*.info.
TEXT_GAMEOVER_PAGE     EQU #20
TEXT_GAMEOVER_RAMG     EQU #000000
TEXT_GAMEOVER_W        EQU 169
TEXT_GAMEOVER_H        EQU 46

; LEVEL 1-1 — source 36 px tall, hardware scale ×16/9 → 64 px на дисплее.
TEXT_LEVEL11_PAGE      EQU #21
TEXT_LEVEL11_RAMG      EQU #004000
TEXT_LEVEL11_W         EQU 89
TEXT_LEVEL11_H         EQU 36
TEXT_LEVEL11_DRAW_W    EQU 158                          ; 89 * 16/9 = 158.2
TEXT_LEVEL11_DRAW_H    EQU 64                           ; 36 * 16/9 = 64

; SPIRAL OF DOOM — native 36 px, без scaling
TEXT_SPIRALDOOM_PAGE   EQU #22
TEXT_SPIRALDOOM_RAMG   EQU #008000
TEXT_SPIRALDOOM_W      EQU 192
TEXT_SPIRALDOOM_H      EQU 36

TEXT_GAMEOVER_HANDLE   EQU 10
TEXT_LEVEL11_HANDLE    EQU 11
TEXT_SPIRALDOOM_HANDLE EQU 12

; Sparkle/diamond — 24×24 ARGB4 для track-preview анимации в intro state.
SPARKLE_PAGE           EQU #24
SPARKLE_RAMG           EQU #00C000                       ; free area между spiraldoom и bg
SPARKLE_W              EQU 24
SPARKLE_H              EQU 24
SPARKLE_HANDLE         EQU 13
SPARKLE_COUNT          EQU 22                            ; sparkles вдоль track
SPARKLE_HALF           EQU 12                            ; для центрирования Vertex2f

; --- Frame strips PALETTED4444 (16K-aligned blocks для UnpackAndUploadPage) ---
FRAME_PAL_PAGE       EQU #3F
FRAME_PAL_RAMG       EQU #080200                         ; raw 512B после balls palette (4-byte aligned)
FRAME_TOP_P0_PAGE    EQU #3A
FRAME_TOP_P1_PAGE    EQU #3B
FRAME_TOP_RAMG       EQU #084000                         ; 32K block (2×16K aligned)
FRAME_TOP_W          EQU 640
FRAME_TOP_H          EQU 44
FRAME_BOT_PAGE       EQU #3C
FRAME_BOT_RAMG       EQU #08C000                         ; 16K block
FRAME_BOT_W          EQU 640
FRAME_BOT_H          EQU 24
FRAME_LEFT_PAGE      EQU #3D
FRAME_LEFT_RAMG      EQU #090000                         ; 16K block
FRAME_LEFT_W         EQU 24
FRAME_LEFT_H         EQU 412
FRAME_RIGHT_PAGE     EQU #3E
FRAME_RIGHT_RAMG     EQU #094000                         ; 16K block (next free until #098000)
FRAME_RIGHT_W        EQU 24
FRAME_RIGHT_H        EQU 412
FRAME_TOP_HANDLE     EQU 14
FRAME_BOT_HANDLE     EQU 15
FRAME_LEFT_HANDLE    EQU 16
FRAME_RIGHT_HANDLE   EQU 17

; --- Frog RTC entropy state (slot 1 free RAM, между GAMELOG и Core @ #6000) ---
; Каждый 128-й вызов Frog_NewNextColor взводит FLAG; picker (Frog_FilteredRandomColor)
; XOR'ит RTC seconds в RAND_BYTE (= ВЫХОД LFSR), не трогая seed state — LFSR
; продолжает свой математически гарантированный цикл, а RTC даёт точечный
; перетряс распределения раз в ~128 выстрелов (~3-5 минут реальной игры).
; (Совет Gemini: не XOR'ить в seed — это сбивает цикл LFSR и может создавать
; короткие повторяющиеся петли.)
FROG_RTC_MIX_CNT_ADDR  EQU #5009                       ; 1 byte, 0..127 cyclic
FROG_RTC_MIX_FLAG_ADDR EQU #500A                       ; 1 byte, 0/1 pending mix
FROG_EXCLUDE_COLOR_ADDR EQU #500B                      ; 1 byte; 0xFF=no excl, else=color → drop bit from mask при popcount>=3 (consume-and-reset)

; --- TSLib block (page 0) ------------------------------------------------
                ORG TSLib
TSLIB_Start:
                include "../../Docs/TSLib/Include/TSConf.inc"
                include "../../Docs/TSLib/Include/Memory/Include.inc"
                include "../../Docs/TSLib/Include/Cache/Macro.inc"
                include "../../Docs/TSLib/Include/Video/Macro.inc"
                include "../../Docs/TSLib/Include/System/Macro.inc"
                include "../../Docs/TSLib/Include/INT/Macro.inc"
                include "../../Docs/TSLib/Include/FT/81x Const.inc"
                include "../../Docs/TSLib/Include/FT/DL  Macro.inc"
                include "../../Docs/TSLib/Include/FT/812 Macro.inc"
                module FT
                include "../../Docs/TSLib/Include/FT/812 Func.asm"
                include "../../Docs/TSLib/Include/FT/Coprocessor/Include.inc"
                endmodule
                include "../../Docs/TSLib/Include/Input/Include.inc"
TSLIB_End:
TSLIB_Size       EQU TSLIB_End - TSLIB_Start
                display "TSLib:    \t", /A, TSLIB_Start, " size=", /D, TSLIB_Size, " bytes"

; --- Log_Init и LogEvent в slot 0 (page 0) после TSLib --------------------
; Перенесено из Core (slot 1) чтобы не превысить 8 KB предел Core.
; Free zone после TSLIB_End (~12 KB до #3FFF). EQU адресов (GAMELOG_ADDR,
; LOG_TMP_*) определены в MainLoop.asm — forward references работают.
Log_Init:       LD   HL, GAMELOG_ADDR
                LD   DE, GAMELOG_ADDR + 1
                LD   BC, LOG_END_ADDR - GAMELOG_ADDR - 1
                LD   (HL), 0
                LDIR
                RET

LogEvent:       PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                LD   A, (GAMELOG_IDX_ADDR)
                LD   H, 0
                LD   L, A
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL                            ; HL = idx * 8
                LD   DE, GAMELOG_ADDR
                ADD  HL, DE
                LD   A, (LOG_TMP_TYPE_ADDR)
                LD   (HL), A
                INC  HL
                LD   A, (LOG_TMP_CTX_ADDR)
                LD   (HL), A
                INC  HL
                LD   A, (Core.ZL_FrameCounter)         ; low byte
                LD   (HL), A
                INC  HL
                XOR  A
                LD   (HL), A
                INC  HL
                EX   DE, HL
                LD   HL, LOG_TMP_DATA_ADDR
                LD   BC, 4
                LDIR
                LD   A, (GAMELOG_IDX_ADDR)
                INC  A
                LD   (GAMELOG_IDX_ADDR), A
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

; ----- 4 logger helpers (slot 0) — Core code просто CALL LogXxx 3 байта вместо
;       30 байт inline payload. Все preserve регистры.
LogShotFired:                                          ; SHOT_FIRED: ctx=Frog_Angle, d1=SmoothX, d2=SmoothY
                PUSH HL                                ; (Frog_Angle — реальное направление bullet velocity,
                PUSH AF                                ; SmoothXY — куда курсор aim. Сравнение даёт grace stale)
                LD   A, EVT_SHOT_FIRED
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   A, (Core.Frog_Angle)
                LD   (LOG_TMP_CTX_ADDR), A
                LD   HL, (Core.ZL_SmoothX)
                LD   (LOG_TMP_DATA_ADDR), HL
                LD   HL, (Core.ZL_SmoothY)
                LD   (LOG_TMP_DATA_ADDR+2), HL
                CALL LogEvent
                POP  AF
                POP  HL
                RET

LogBboxHit:                                            ; in: A=best_hit_idx
                PUSH HL
                PUSH AF
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, EVT_BBOX_HIT
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   HL, (Core.Bullet_X)
                LD   (LOG_TMP_DATA_ADDR), HL
                LD   HL, (Core.Bullet_Y)
                LD   (LOG_TMP_DATA_ADDR+2), HL
                CALL LogEvent
                POP  AF
                POP  HL
                RET

LogHemi:                                               ; in: A=target_idx
                PUSH HL
                PUSH BC
                PUSH DE
                PUSH AF
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, EVT_HEMI
                LD   (LOG_TMP_TYPE_ADDR), A
                POP  AF                                ; restore target_idx in A
                PUSH AF
                CALL Core.VDC_SlotPos                  ; BC=X, DE=Y, CF=skip
                JR   NC, .lh_ok
                LD   BC, #FFFF
                LD   DE, #FFFF
.lh_ok:         LD   (LOG_TMP_DATA_ADDR), BC
                LD   (LOG_TMP_DATA_ADDR+2), DE
                CALL LogEvent
                POP  AF
                POP  DE
                POP  BC
                POP  HL
                RET

LogInsert:                                             ; in: nothing (reads VDC_* directly)
                PUSH HL
                PUSH AF
                LD   A, EVT_INSERT
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   A, (Core.VDC_TmpInsIdx)
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, (Core.VDC_SlotsLen)
                LD   (LOG_TMP_DATA_ADDR), A
                LD   A, (Core.VDC_HSA)
                LD   (LOG_TMP_DATA_ADDR+1), A
                LD   A, (Core.VDC_TmpInsColor)
                LD   (LOG_TMP_DATA_ADDR+2), A
                LD   A, (Core.VDC_HSub)
                LD   (LOG_TMP_DATA_ADDR+3), A
                CALL LogEvent
                POP  AF
                POP  HL
                RET

LogCascadeTrigger:                                     ; CASCADE_TRIGGER: ctx=gap_idx, d1=len|HSA, d2=offset|HSub
                PUSH HL
                PUSH DE
                PUSH AF
                LD   A, EVT_CASCADE_TRIGGER
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   A, (Core.VDC_TmpGapIdx)
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, (Core.VDC_SlotsLen)
                LD   (LOG_TMP_DATA_ADDR), A
                LD   A, (Core.VDC_HSA)
                LD   (LOG_TMP_DATA_ADDR+1), A
                LD   A, (Core.VDC_TmpGapIdx)
                LD   H, 0
                LD   L, A
                LD   DE, Core.VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   (LOG_TMP_DATA_ADDR+2), A
                LD   A, (Core.VDC_HSub)
                LD   (LOG_TMP_DATA_ADDR+3), A
                CALL LogEvent
                POP  AF
                POP  DE
                POP  HL
                RET

ClampOffsetOrder:                                      ; Prevent positive tail offsets from inverting visual slot order.
                PUSH AF
                PUSH BC
                PUSH HL
                LD   A, (Core.VDC_SlotsLen)
                CP   2
                JR   C, .co_done
                DEC  A
                LD   B, A                              ; pairs len-1
                LD   HL, Core.VDC_Offsets              ; HL = prev offset
.co_loop:       LD   A, (HL)
                INC  HL                                ; HL = current offset
                LD   C, A                              ; C = prev
                LD   A, (HL)                           ; A = current
                OR   A
                JR   Z, .co_next
                JP   M, .co_next                       ; only positive current offsets can create backward overlap
                BIT  7, C
                JR   NZ, .co_clamp                     ; prev negative, current positive -> inverted
                CP   C
                JR   C, .co_next
                JR   Z, .co_next
.co_clamp:      LD   (HL), C
.co_next:       DJNZ .co_loop
.co_done:       POP  HL
                POP  BC
                POP  AF
                RET

; ============================================================================
; DrawKillzoneDual — dual-pass kill-zone draw: hole (cell 0) под skull (cell N).
; Перенесён сюда из Core.MainLoop чтобы освободить байты Core (Core был
; 8189/8192). Должен вызываться внутри активного FT_Begin FT_BITMAPS блока.
;
; Координаты центра kill-zone — per-level setting (KZ_DEFAULT_X/Y).  Не из
; track end: track[N-1] не обязан попадать в визуальный центр sun-черепа в bg
; (cell-grid CELL_SIZE=32 ≠ pixel-aligned bg art).  Для level 1 (Spiral of Doom)
; центр bg-bbox золотых пикселей = (208, 217).
; ============================================================================
KZ_DEFAULT_X       EQU 211
KZ_DEFAULT_Y       EQU 217

DrawKillzoneDual:
                ; Idle (KzFrame=1) = закрытый череп уже запечён в bg, overlay
                ; не нужен. Для KzFrame=0 (open black hole во время INTRO/PREVIEW
                ; и Game Over) ИЛИ KzFrame>=2 (animation opening / absorb) рисуем.
                LD   A, (Core.VDC_KzFrame)
                CP   1
                RET  Z
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle 3
                FT_BitmapSource Core.KZ_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, 64 * 2, 64
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, 64, 64
                ; FT.Coprocessor.Cell корраптит BC/DE → загружаем coords ПОСЛЕ Cell.
                ; top-left = (KZ_DEFAULT_X - 32, KZ_DEFAULT_Y - 32) in 1/16 px.
                ; --- pass 1: hole (Cell 0) ---
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (KZ_DEFAULT_X - 32) * 16
                LD   DE, (KZ_DEFAULT_Y - 32) * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- pass 2: skull frame (Cell = VDC_KzFrame) ---
                LD   A, (Core.VDC_KzFrame)
                CALL FT.Coprocessor.Cell
                LD   BC, (KZ_DEFAULT_X - 32) * 16
                LD   DE, (KZ_DEFAULT_Y - 32) * 16
                JP   FT.Coprocessor.Vertex2f

; ----------------------------------------------------------------------------
; DrawGameOverText — рисует "GAME OVER" в nativealien48 шрифте, центр X
; (320 - W/2 = 320 - 66 = 254), Y = 72 (как было с cmd_text).
; ----------------------------------------------------------------------------
DrawGameOverText:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB                ; tint = white (gradient уже в bitmap)
                FT_BitmapHandle TEXT_GAMEOVER_HANDLE
                FT_BitmapSource TEXT_GAMEOVER_RAMG
                FT_BitmapLayout FT_ARGB4, TEXT_GAMEOVER_W * 2, TEXT_GAMEOVER_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, TEXT_GAMEOVER_W, TEXT_GAMEOVER_H
                XOR  A : CALL FT.Coprocessor.Cell           ; Cell 0
                LD   BC, (320 - TEXT_GAMEOVER_W / 2) * 16   ; X centered
                LD   DE, 72 * 16
                JP   FT.Coprocessor.Vertex2f

; ----------------------------------------------------------------------------
; DrawIntroText — нижний правый угол: LEVEL 1-1 (большой, 64 px via cmd_scale)
; + SPIRAL OF DOOM (36 px native). Используется когда VDC_GameState == INTRO.
; Layout (640×480 screen, 30 px margin от правой/нижней рамки):
;   LEVEL 1-1: X=452, Y=320 (158×64 displayed, BILINEAR scale ×16/9 from 89×36)
;   SPIRAL OF DOOM: X=418, Y=414 (192×36 native)
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; DrawPreviewSparkles — sparkle wave анимация по track (state=PREVIEW).
; Параметры:
;   N=20 sparkles, head_sample = elapsed * SPEED, trail spacing 60 samples
;   SPEED = 24, PREVIEW_TICKS = 120 → head_sample reaches NumSamples (~2774)
; Sparkle skipped если sample < 0 или sample >= NumSamples (head ещё не дошёл / уже прошёл).
; Tint: warm gold. Caller восстановит белый ColorRGB.
; TrackData в slot 2 page 6 (default mapping).
; ----------------------------------------------------------------------------
; Comet: 8 sparkles spaced 16 samples = ~128 samples trail (короткая «очередь»),
; head advances 30 samples/tick → ~92 ticks для прохода 2774 samples (вместо 120).
PREVIEW_SPARKLE_COUNT   EQU 8
PREVIEW_SPARKLE_SPEED   EQU 15
PREVIEW_SPARKLE_SPACING EQU 16

DrawPreviewSparkles:
                LD   C, 255 : LD D, 220 : LD E, 80
                CALL FT.Coprocessor.ColorRGB
                FT_BitmapHandle SPARKLE_HANDLE
                FT_BitmapSource SPARKLE_RAMG
                FT_BitmapLayout FT_ARGB4, SPARKLE_W * 2, SPARKLE_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, SPARKLE_W, SPARKLE_H
                XOR  A : CALL FT.Coprocessor.Cell

                ; head_sample = elapsed * PREVIEW_SPARKLE_SPEED
                ; where elapsed = PREVIEW_TICKS - VDC_PreviewTick
                LD   A, Core.VDC_PREVIEW_TICKS
                LD   HL, Core.VDC_PreviewTick
                SUB  (HL)                              ; A = elapsed
                LD   H, 0 : LD L, A
                LD   D, H : LD E, L                    ; DE = elapsed
                LD   HL, 0
                LD   B, PREVIEW_SPARKLE_SPEED
.dps_mul:       ADD  HL, DE
                DJNZ .dps_mul
                LD   (.dps_sample), HL

                LD   A, PREVIEW_SPARKLE_COUNT
                LD   (.dps_count), A
.dps_loop:      LD   HL, (.dps_sample)
                ; sample >= 0?
                BIT  7, H
                JR   NZ, .dps_advance
                ; sample < NumSamples?
                LD   DE, (Core.TrackData)              ; word at #8000 = NumSamples
                AND  A
                SBC  HL, DE
                JR   NC, .dps_advance                  ; sample >= NumSamples
                ADD  HL, DE                            ; restore sample
                ; addr = TrackData + 2 + sample*5
                LD   D, H : LD E, L
                ADD  HL, HL : ADD HL, HL               ; *4
                ADD  HL, DE                            ; *5
                LD   DE, Core.TrackData + 2
                ADD  HL, DE
                ; Read X word, Y word
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   (.dps_xword), DE
                LD   E, (HL) : INC HL
                LD   D, (HL)                           ; DE = Y
                LD   (.dps_yword), DE
                ; BC = (X-12) * 16
                LD   DE, (.dps_xword)
                LD   HL, -SPARKLE_HALF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                ; DE = (Y-12) * 16
                LD   DE, (.dps_yword)
                LD   HL, -SPARKLE_HALF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f
.dps_advance:
                LD   HL, (.dps_sample)
                LD   DE, -PREVIEW_SPARKLE_SPACING
                ADD  HL, DE
                LD   (.dps_sample), HL
                LD   A, (.dps_count)
                DEC  A
                LD   (.dps_count), A
                JR   NZ, .dps_loop
                RET
.dps_sample:    DW 0
.dps_count:     DB 0
.dps_xword:     DW 0
.dps_yword:     DW 0

; ----------------------------------------------------------------------------
; DrawFrameStrips — 4 PALETTED4444 strip'а вокруг прозрачного centra.
; Каждая strip имеет свой handle и BITMAP_SOURCE; общая FT_PaletteSource.
; Z-order: рисуется поверх playfield, под курсором. Native 640×480 (no scale).
; ----------------------------------------------------------------------------
DrawFrameStrips:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource FRAME_PAL_RAMG
                ; --- TOP 640×44 at (0, 0) ---
                FT_BitmapHandle FRAME_TOP_HANDLE
                FT_BitmapSource FRAME_TOP_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_TOP_W, FRAME_TOP_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_TOP_W, FRAME_TOP_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; --- BOTTOM 640×24 at (0, 480-24) ---
                FT_BitmapHandle FRAME_BOT_HANDLE
                FT_BitmapSource FRAME_BOT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_BOT_W, FRAME_BOT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_BOT_W, FRAME_BOT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, (480 - FRAME_BOT_H) * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- LEFT 24×412 at (0, 44) ---
                FT_BitmapHandle FRAME_LEFT_HANDLE
                FT_BitmapSource FRAME_LEFT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_LEFT_W, FRAME_LEFT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_LEFT_W, FRAME_LEFT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, FRAME_TOP_H * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- RIGHT 24×412 at (640-24, 44) ---
                FT_BitmapHandle FRAME_RIGHT_HANDLE
                FT_BitmapSource FRAME_RIGHT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_RIGHT_W, FRAME_RIGHT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_RIGHT_W, FRAME_RIGHT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, (640 - FRAME_RIGHT_W) * 16
                LD   DE, FRAME_TOP_H * 16
                JP   FT.Coprocessor.Vertex2f

DrawIntroText:
                ; --- Fade-out alpha: VDC_IntroTick 240→0; last 60 ticks fade ---
                ; alpha = (tick<60) ? tick*4 : 255
                LD   A, (Core.VDC_IntroTick)
                CP   60
                JR   NC, .dit_full_alpha
                ADD  A, A
                ADD  A, A                              ; A = tick*4 (max 4*59=236)
                JR   .dit_alpha_set
.dit_full_alpha:
                LD   A, 255
.dit_alpha_set:
                LD   E, A
                CALL FT.Coprocessor.ColorA

                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; --- LEVEL 1-1 — apply hardware scale ×16/9 (1.7778) ---
                CALL Core.ZL_EmitLoadId
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF #0001C71C                   ; sx = 16/9 ≈ 1.7778 (16.16)
                FT_CMD_BUF #0001C71C                   ; sy = same
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle TEXT_LEVEL11_HANDLE
                FT_BitmapSource TEXT_LEVEL11_RAMG
                FT_BitmapLayout FT_ARGB4, TEXT_LEVEL11_W * 2, TEXT_LEVEL11_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, TEXT_LEVEL11_DRAW_W, TEXT_LEVEL11_DRAW_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, (640 - TEXT_LEVEL11_DRAW_W - 30) * 16
                LD   DE, (480 - TEXT_LEVEL11_DRAW_H - 90) * 16
                CALL FT.Coprocessor.Vertex2f

                ; --- Reset matrix to identity для SPIRAL (no scale) ---
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle TEXT_SPIRALDOOM_HANDLE
                FT_BitmapSource TEXT_SPIRALDOOM_RAMG
                FT_BitmapLayout FT_ARGB4, TEXT_SPIRALDOOM_W * 2, TEXT_SPIRALDOOM_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, TEXT_SPIRALDOOM_W, TEXT_SPIRALDOOM_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, (640 - TEXT_SPIRALDOOM_W - 30) * 16
                LD   DE, (480 - TEXT_SPIRALDOOM_H - 30) * 16
                JP   FT.Coprocessor.Vertex2f

VDC_UpdateAbsorb:
                LD   A, (Core.VDC_GameOverTick)
                INC  A
                LD   (Core.VDC_GameOverTick), A
                LD   A, (Core.VDC_KzFrame)
                CP   11
                JR   NC, .ua_frame_done
                INC  A
                LD   (Core.VDC_KzFrame), A
.ua_frame_done:
                ; Plitnaya advance цепи в kill-zone: HSub++ × VDC_ABSORB_ADVANCE
                ; per tick.  На wrap (HSub == CS) → array shift (remove slot 0),
                ; HSA capped, HSub=0.  Визуально: tail-балы плавно скользят
                ; вперёд (sub-pixel HSub), head clamped на последнем сэмпле трека,
                ; alpha fade пропорционально HSub.
                LD   B, Core.VDC_ABSORB_ADVANCE
.ua_loop:       PUSH BC
                CALL .ua_move_once
                POP  BC
                LD   A, (Core.VDC_GameState)
                CP   1
                JR   NZ, .ua_state_changed              ; transitioned to state=2
                DJNZ .ua_loop
.ua_state_changed:
                ; Alpha = 255 - HSub*8 (HSub 0..31 → alpha 255..7).  Когда HSub=0
                ; (только что был wrap+remove) → alpha=255 для нового head.
                LD   A, (Core.VDC_HSub)
                ADD  A, A : ADD A, A : ADD A, A
                CPL
                LD   (Core.VDC_HeadAbsorbAlpha), A
                RET

.ua_move_once:  LD   A, (Core.VDC_HSub)
                INC  A
                CP   Core.VDC_CELL_SIZE
                JR   C, .ua_save_hsub
                ; Wrap: HSub=0, remove slot 0.  HSA остаётся capped — head
                ; ball «застрял» на последнем сэмпле трека (clamped), новый
                ; head после shift попадает туда же → 1px continuity jump.
                XOR  A
                LD   (Core.VDC_HSub), A
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                JR   Z, .ua_done
                XOR  A
                LD   (Core.VDC_TmpGapIdx), A
                CALL Core.VDC_RemoveSlotAt
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                RET  NZ
.ua_done:       LD   A, 2
                LD   (Core.VDC_GameState), A
                XOR  A
                LD   (Core.VDC_KzFrame), A
                LD   (Core.VDC_GameOverTick), A
                LD   A, 255
                LD   (Core.VDC_HeadAbsorbAlpha), A
                RET
.ua_save_hsub:  LD   (Core.VDC_HSub), A
                RET

; ============================================================================
; VDC_CheckKillzone — proximity-based skull animation.
; Каждый кадр вычисляет remaining_samples = (TrackNumSlots-HSA)*CS + KzEndSub-HSub.
;   rem > 2*CS (=64)  → KzFrame=1 (closed skull, idle)
;   rem in [1..64]    → KzFrame = 2 + ((64-rem) >> 3) ∈ [2..10] (opening)
;   rem <= 0          → trigger absorb (state=1, KzFrame=11)
; Rollback (match-3 cascade двигает HSA назад) → rem растёт → frame уменьшается
; обратно к 1 автоматически. Никаких отдельных rollback hook'ов.
; ============================================================================
VDC_CheckKillzone:
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                RET  Z
                ; --- cells_to_go = TrackNumSlots - HSA ---
                LD   HL, (Core.VDC_TrackNumSlots)      ; L = TNS low (TNS≈86 fits)
                LD   A, L
                LD   HL, Core.VDC_HSA
                SUB  (HL)                              ; A = TNS - HSA (signed-ish)
                JR   Z, .ck_eqcell                     ; equal cells
                JR   C, .ck_trigger                    ; HSA > TNS → past
                ; --- HSA < TNS: rem = A*CS + KzEndSub - HSub ---
                LD   H, 0
                LD   L, A
                ADD  HL, HL : ADD HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL               ; HL = A * 32 (CELL_SIZE)
                LD   A, (Core.VDC_KzEndSub)
                LD   D, A
                LD   A, (Core.VDC_HSub)
                LD   E, A
                LD   A, D
                SUB  E                                 ; A = KzEndSub - HSub (signed)
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .ck_add_delta
                DEC  D                                 ; sign-extend negative
.ck_add_delta:  ADD  HL, DE                            ; HL = remaining samples
                JR   .ck_set_frame
.ck_eqcell:     ; HSA == TNS: rem = KzEndSub - HSub ∈ [1..CS-1] always opening range
                LD   A, (Core.VDC_KzEndSub)
                LD   D, A
                LD   A, (Core.VDC_HSub)
                CP   D
                JR   NC, .ck_trigger                   ; HSub >= KzEndSub → past
                LD   E, A                              ; HSub
                LD   A, D
                SUB  E                                 ; A = KzEndSub - HSub (1..CS-1)
                LD   H, 0
                LD   L, A
.ck_set_frame:  ; HL = remaining samples (positive)
                LD   A, H
                OR   A
                JR   NZ, .ck_closed                    ; rem > 255 → > 64 → closed
                LD   A, L
                CP   65
                JR   NC, .ck_closed
                ; rem ∈ [1..64]: KzFrame = 2 + ((64 - rem) >> 3) ∈ [2..10]
                LD   B, A
                LD   A, 64
                SUB  B
                SRL  A : SRL A : SRL A
                ADD  A, 2
                LD   (Core.VDC_KzFrame), A
                RET
.ck_closed:     LD   A, 1
                LD   (Core.VDC_KzFrame), A
                RET
.ck_trigger:    LD   A, 1
                LD   (Core.VDC_GameState), A
                LD   A, 11                             ; full-open at trigger (was 1; now 11 = wide-open mouth absorb)
                LD   (Core.VDC_KzFrame), A
                XOR  A
                LD   (Core.VDC_GameOverTick), A
                LD   A, 255
                LD   (Core.VDC_HeadAbsorbAlpha), A      ; head fade начинается с 255
                RET

; ============================================================================
; Frog_FilteredRandomColor — RandomColor с фильтром цветов цепи.
; Out: A = color (0..3), guaranteed to be present in VDC_Slots if chain non-empty.
; Fallback: unfiltered random AND 3 если chain пуст или все retry'ы промахнулись.
; Preserves: BC, DE, HL (стандартные slot-0 caller-saves).
; ============================================================================
Frog_FilteredRandomColor:                              ; in A: 0xFF=force fresh; else=check & keep if in mask
                PUSH BC
                PUSH DE
                PUSH HL
                LD   B, A                              ; B = input color (0xFF=force fresh)
                ; --- Build mask in D from VDC_Slots[0..SlotsLen-1] ---
                LD   D, 0                              ; D = mask (bits 0..3 = colors present)
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                JP   Z, .frc_fb_in                     ; empty chain → fallback (JP — JR диапазон превысился после exclude block)
                LD   C, A
                LD   HL, Core.VDC_Slots
.frc_ml:        LD   A, (HL)
                INC  HL
                CP   Core.VDC_NUM_COLORS
                JR   NC, .frc_msk_skip                 ; GAP marker (>=NUM_COLORS) → skip
                LD   E, A                              ; E = bit index
                LD   A, 1
                INC  E
.frc_sh:        DEC  E
                JR   Z, .frc_sh_done
                ADD  A, A
                JR   .frc_sh
.frc_sh_done:   OR   D
                LD   D, A
.frc_msk_skip:  DEC  C
                JR   NZ, .frc_ml
                ; --- Check input color B against mask D (skip if 0xFF) ---
                LD   A, B
                CP   Core.VDC_NUM_COLORS
                JR   NC, .frc_pick_new                 ; B >= NUM_COLORS (including 0xFF) → force fresh
                LD   E, A                              ; check bit B in mask
                LD   A, 1
                INC  E
.frc_chsh:      DEC  E
                JR   Z, .frc_chsh_done
                ADD  A, A
                JR   .frc_chsh
.frc_chsh_done: AND  D
                JR   Z, .frc_pick_new                  ; B not in mask → fresh
                LD   A, B                              ; keep input color
                JR   .frc_exit
.frc_pick_new:
                ; --- Popcount mask D → B (число цветов в цепи) ---
                LD   B, 0
                LD   E, Core.VDC_NUM_COLORS            ; parametric (Gemini fix)
                LD   A, D
.frc_pc:        RRCA
                JR   NC, .frc_pc_skip
                INC  B
.frc_pc_skip:   DEC  E
                JR   NZ, .frc_pc
                ; --- Exclude bit (если popcount >= 3 и FROG_EXCLUDE_COLOR_ADDR valid) ---
                LD   A, B
                CP   3
                JR   C, .frc_no_excl
                LD   A, (FROG_EXCLUDE_COLOR_ADDR)
                CP   Core.VDC_NUM_COLORS
                JR   NC, .frc_excl_reset               ; #FF / out-of-range → no excl, но reset
                LD   E, A
                LD   A, 1
                INC  E
.frc_xsh:       DEC  E
                JR   Z, .frc_xsh_done
                ADD  A, A
                JR   .frc_xsh
.frc_xsh_done:  LD   E, A                              ; E = bit mask
                AND  D
                JR   Z, .frc_excl_reset                ; bit not в mask → skip
                LD   A, E
                CPL
                AND  D
                LD   D, A                              ; mask -= bit
                DEC  B                                  ; popcount--
.frc_excl_reset:
                LD   A, #FF
                LD   (FROG_EXCLUDE_COLOR_ADDR), A      ; consume — RefilterCurrent calls должны не unaffected
.frc_no_excl:
                LD   A, B
                OR   A
                JR   Z, .frc_fb                        ; mask empty → fallback
                ; --- pick index 0..B-1 via mul-then-shift: (rand8 * B) >> 8.
                ; Bias ≤ 1/(256/B) ≤ 1.6%. Старый `AND 3 + mod B` на 4-value
                ; источнике давал при popcount=3 LSB-цвету маски 50% vs 25% —
                ; визуально «слишком много <цвет-0-маски>» (purple bias).
                PUSH DE                                ; save D = mask (E irrelevant)
                PUSH BC                                ; save B = popcount
                CALL VDC_Random8                       ; A = 0..255 uniform LFSR
                LD   D, A                              ; D = rand (preserve)
                ; --- Optional RTC mix into RAND BYTE (not seed!) every 128th NewNextColor ---
                LD   HL, FROG_RTC_MIX_FLAG_ADDR
                LD   A, (HL)
                OR   A
                JR   Z, .frc_no_rtc_mix
                LD   (HL), 0                           ; consume flag
                PUSH DE
                CALL Core.ReadRTCSeconds               ; A = 0..59 binary
                POP  DE                                 ; D = rand
                XOR  D                                  ; rand XOR RTC
                LD   D, A
.frc_no_rtc_mix:
                POP  BC                                 ; restore B = popcount
                LD   E, B                              ; E = popcount
                CALL Core.Frog_Mul8x8u                 ; HL = D*E (clobbers A,B,DE)
                POP  DE                                 ; restore D = mask
                LD   C, H                              ; C = (rand*B)>>8 = 0..B-1
                ; --- Walk mask D LSB→MSB, return color of C-th set bit ---
                LD   E, 0                              ; E = current color index
.frc_walk:      LD   A, D
                AND  #01
                JR   Z, .frc_walk_skip
                LD   A, C
                OR   A
                JR   Z, .frc_walk_found
                DEC  C
.frc_walk_skip: SRL  D
                INC  E
                JR   .frc_walk
.frc_walk_found:
                LD   A, E
                JR   .frc_exit
.frc_fb_in:     ; empty chain: keep input B if valid, else random unfiltered
                LD   A, B
                CP   Core.VDC_NUM_COLORS
                JR   C, .frc_exit                      ; B < NUM_COLORS → keep
.frc_fb:        CALL Core.VDC_RandomColor              ; уже выдаёт 0..NUM_COLORS-1
                ; (убрана hardcoded AND 3 — Gemini fix; VDC_RandomColor сам маскирует)
.frc_exit:      POP  HL
                POP  DE
                POP  BC
                RET

; Frog_RefilterCurrent — каждый кадр check BallColor/NextBallColor against
; chain mask; replace если color удалён cascade match-3.
Frog_RefilterCurrent:
                LD   A, (Core.Frog_BallColor)
                CALL Frog_FilteredRandomColor
                LD   (Core.Frog_BallColor), A
                LD   A, (Core.Frog_NextBallColor)
                CALL Frog_FilteredRandomColor
                LD   (Core.Frog_NextBallColor), A
                RET

; Frog_NewNextColor — force fresh new NextBallColor (= после promote при start fire).
; Counter mod 128: каждый 128-й вызов взводит FLAG, и следующий pick в
; Frog_FilteredRandomColor XOR'ит RTC seconds в RAND BYTE (выход LFSR, не seed).
; Это сохраняет цикл LFSR неприкосновенным (Gemini совет), но добавляет точечный
; перетряс распределения раз в ~128 выстрелов.
Frog_NewNextColor:
                LD   HL, FROG_RTC_MIX_CNT_ADDR
                LD   A, (HL)
                INC  A
                AND  #7F                              ; counter mod 128
                LD   (HL), A
                OR   A
                JR   NZ, .nnc_no_flag                 ; cnt != 0 → no boundary
                LD   A, 1
                LD   (FROG_RTC_MIX_FLAG_ADDR), A      ; mark for picker to consume
.nnc_no_flag:
                ; Exclude BallColor from mask если popcount активных цветов >= 3.
                ; Юзер: «следующий шар лягушки» не должен совпадать с предыдущим
                ; (когда в цепи 3+ цветов; иначе чередование вынужденное).
                LD   A, (Core.Frog_BallColor)
                LD   (FROG_EXCLUDE_COLOR_ADDR), A
                LD   A, #FF                            ; sentinel: force fresh
                CALL Frog_FilteredRandomColor
                LD   (Core.Frog_NextBallColor), A
                RET

; ============================================================================
; VDC_Random8 — LFSR Galois 16-bit (poly 0xB400), 8-bit uniform 0..255.
; Тот же LFSR step что Core.VDC_RandomColor, но без AND-mask. Используется
; Frog_FilteredRandomColor для unbiased mod-B через (rand * B) >> 8 — это
; нужно когда popcount(mask) не степень двойки (B=3 в основном). Старый AND 3
; + mod B давал bias 50%/25%/25% для popcount=3 → видимый перекос колора.
; Разделяет Core.VDC_LfsrSeed с VDC_RandomColor (оба stepper'а двигают одну
; и ту же последовательность атомарно — без корреляции).
; ============================================================================
VDC_Random8:
                LD   HL, (Core.VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   Z, .r8_no_xor
                LD   D, #B4 : LD E, 0
                LD   A, H : XOR D : LD H, A
                LD   A, L : XOR E : LD L, A
.r8_no_xor:
                LD   (Core.VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; 8-bit uniform
                RET

; ----------------------------------------------------------------------------
; ZX7 Turbo decompressor (Einar Saukas / Urusergi). HL = compressed src,
; DE = destination. Восстановлен из ~/Desktop/Zuma Deluxe (src/ASM,
; zuma_new_spg.asm:4466). Размер ~62 байта. Не корраптит I, IX, IY.
; Используется через UnpackZX7Page wrapper. На входе HL/DE должны указывать
; в WRITABLE области (исходник можно в slot 2 ROM-like, dest в RAM).
; ----------------------------------------------------------------------------
Dzx7Turbo:
                LD   A, #80
.zx7_copy_byte_loop:
                LDI
.zx7_main_loop:
                ADD  A, A
                CALL Z, .zx7_load_bits
                JR   NC, .zx7_copy_byte_loop
                PUSH DE
                LD   BC, 1
                LD   D, B
.zx7_len_size_loop:
                INC  D
                ADD  A, A
                CALL Z, .zx7_load_bits
                JR   NC, .zx7_len_size_loop
                JP   .zx7_len_value_start
.zx7_len_value_loop:
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   C
                RL   B
                JR   C, .zx7_exit
.zx7_len_value_start:
                DEC  D
                JR   NZ, .zx7_len_value_loop
                INC  BC
                LD   E, (HL)
                INC  HL
                DB   #CB, #33                          ; SLL E / SLS E (undoc)
                JR   NC, .zx7_offset_end
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                CCF
                JR   C, .zx7_offset_end
                INC  D
.zx7_offset_end:
                RR   E
                EX   (SP), HL
                PUSH HL
                SBC  HL, DE
                POP  DE
                LDIR
.zx7_exit:
                POP  HL
                JP   NC, .zx7_main_loop
                RET
.zx7_load_bits:
                LD   A, (HL)
                INC  HL
                RLA
                RET

; ----------------------------------------------------------------------------
; SCRATCH_PAGE — свободная SPG page для decomp output. Используется
; UnpackAndUploadPage в Initialize между bg/balls/frog uploads.
; Page #01 не задействован ни одним Block в spgbld_vdac2.ini — безопасно.
; ----------------------------------------------------------------------------
SCRATCH_PAGE    EQU #01

; ----------------------------------------------------------------------------
; UnpackAndUploadPage: расжать compressed src page A → SCRATCH_PAGE,
; залить 16K из SCRATCH_PAGE в FT_RAM_G по адресу (Core.BgRamH:BgRamL),
; продвинуть указатель FT_RAM_G на +#4000.
;
; In:  A = compressed source SPG page; Core.BgRamH/L = FT_RAM_G dest 24-bit
; Out: Core.BgRamH/L advanced by 16K
; Slots после RET: slot 2 = src (не восстановлен), slot 3 = SCRATCH (не восст.).
;                  Caller обязан восстановить SetPage2 6 / SetPage3 #04 после
;                  серии вызовов.
; ----------------------------------------------------------------------------
UnpackAndUploadPage:
                DI
                LD   (.uaup_src), A
                LD   (.uaup_saved_sp), SP
                LD   SP, .uaup_temp_stack_top

                ; slot 2 = compressed src
                LD   A, (.uaup_src) : LD BC, PAGE2 : OUT (C), A
                ; slot 3 = scratch (decomp dest)
                LD   A, SCRATCH_PAGE : LD BC, PAGE3 : OUT (C), A

                ; Dzx7Turbo: HL=src, DE=dst
                LD   HL, #8000
                LD   DE, #C000
                CALL Dzx7Turbo

                ; FT.WriteMem(HL=#C000 in slot 3, BC=16384, A:DE=FT_RAM_G addr)
                LD   HL, #C000
                LD   BC, 16384
                LD   A, (Core.BgRamH)
                LD   DE, (Core.BgRamL)
                CALL FT.WriteMem

                ; Advance Core.BgRamL/H by 16K
                LD   HL, (Core.BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (Core.BgRamL), HL
                JR   NC, .uaup_no_carry
                LD   A, (Core.BgRamH) : INC A : LD (Core.BgRamH), A
.uaup_no_carry:
                LD   SP, (.uaup_saved_sp)
                EI
                RET
.uaup_src:        DB 0
.uaup_saved_sp:   DW 0
.uaup_temp_stack: DEFS 64
.uaup_temp_stack_top:

; ----------------------------------------------------------------------------
; UnpackZX7Page: расжать compressed page A → dest page B.
; Source = slot 2 (#8000), dest = slot 3 (#C000). После RET слоты восстановлены:
; slot 2 → page 6 (TrackData), slot 3 → page #04 (main1_play).
; Stack пересажен на uzx7_temp_stack чтобы LDIR в slot 3 не зацепил наш стек.
; ----------------------------------------------------------------------------
UnpackZX7Page:
                DI
                LD   (.uzx7_src), A
                LD   A, B  : LD (.uzx7_dst), A
                LD   (.uzx7_saved_sp), SP
                LD   SP, .uzx7_temp_stack_top
                LD   A, (.uzx7_src) : LD BC, PAGE2 : OUT (C), A
                LD   A, (.uzx7_dst) : LD BC, PAGE3 : OUT (C), A
                LD   HL, #8000
                LD   DE, #C000
                CALL Dzx7Turbo
                LD   A, 6   : LD BC, PAGE2 : OUT (C), A   ; restore slot 2 = TrackData page
                LD   A, #04 : LD BC, PAGE3 : OUT (C), A   ; restore slot 3 = main1_play page
                LD   SP, (.uzx7_saved_sp)
                EI
                RET
.uzx7_src:        DB 0
.uzx7_dst:        DB 0
.uzx7_saved_sp:   DW 0
.uzx7_temp_stack: DEFS 64
.uzx7_temp_stack_top:

LOG_BLOCK_END:

TSLIB_TOTAL_SIZE EQU LOG_BLOCK_END - TSLIB_Start
                display "Log:      \t", /A, Log_Init, " end=", /A, LOG_BLOCK_END
                SAVEBIN "TSLib.bin", TSLIB_Start, TSLIB_TOTAL_SIZE

; --- Core block (page 5) -------------------------------------------------
                ORG EntryPoint
                module Core
Start:
                ; ----- EntryPoint -----
                LD   SP, StackTop
                CALL Initialize
                JP   MainLoop

                ; ----- Initialize -----
Initialize:     CALL Init_Core
                CALL Init_Int                         ; EI/HALT — ждём первого FRAME INT (HW stab)
                CALL Init_Video                       ; FT_BOOT_UP + 640×480 + FT_INT_SWAP enable
                CALL Input.Mouse.Initialize           ; курсор в центр (W/2, H/2)
                ; Init завершён — отключаем TS-Conf frame INT 50 Hz, чтобы он не бился
                ; с FT812 vsync 57.25 Hz. Синхронизация в MainLoop через FT_INT_SWAP.
                DI
                INT_Setting 0

                ; Залить bg_level01 (640x480 RGB565, 38 страниц 7..44) в RAM_G
                ; начиная с #010000. Каждая страница = 16384 байт по адресу #8000
                ; в slot 2.
                ; ВАЖНО: bg грузится ПЕРВЫМ. 38×16384=622592 байт реально пишется в
                ; #010000..#0A8000, тогда как реальный bg — 614400 байт (#010000..#0A0000),
                ; последние 8192 байт = padding zeros последней spgbld page. Если atlas
                ; (#0A6000..) залить до bg — bg-padding затрёт первые 8 КБ atlas
                ; = Cell 0 + начало Cell 1 → невидимый шар. Поэтому: bg первым,
                ; atlas вторым (atlas-padding потом уходит в свободную область после #0F2000).
                LD   A, BG_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BG_PAGE_COUNT
.UploadBg:      PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000                          ; источник в slot 2
                LD   BC, 16384
                LD   A,  (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                ; advance RAM_G addr += #4000
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarry
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarry:       LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBg

                ; Залить balls_atlas (6 colors × 8 frames × 56×56 ARGB4 = 301 056 байт)
                ; в RAM_G #0A6000. Atlas грузится ПОСЛЕ bg чтобы перезаписать
                ; bg-padding в #0A6000..#0A8000 реальными sprite-данными. Handle 0 в DL.
                LD   A, BALLS_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BALLS_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BALLS_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BALLS_PAGE_COUNT
.UploadBalls:   PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem 16K, advance BgRamH/L
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBalls

                ; Palette ARGB4 СТРОГО 512 байт → FT_RAM_G #080000 (PALETTED4444).
                ; Размер ровно 512: FT812 при больших значениях считывает мусор за
                ; концом палитры; при меньшем зависает (out-of-range index).
                LD   A, BALLS_PALETTE_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512                          ; ARGB4 = 256 × 2 bytes
                LD   A, (BALLS_PALETTE_RAMG >> 16) & 0xFF
                LD   DE, BALLS_PALETTE_RAMG & 0xFFFF
                CALL FT.WriteMem

                ; Залить frog body / plate / tongue / face-overlay в RAM_G.
                ; Layout (FROG_TOTAL_PAGES=7 pages подряд от FROG_PAGE):
                ;   pages 0x52..0x53 — body    (2 pages, 122×122 ARGB4)
                ;   pages 0x54..0x55 — plate   (2 pages)
                ;   page  0x56       — tongue  (1 page tight 32×80, padding 11 КБ
                ;                                перезаписывается next overlay
                ;                                upload, но overlay начинается at
                ;                                OVERLAY_RAMG_ADDR = #0F8000 — gap
                ;                                #0F5000..#0F8000 остаётся zeros)
                ;   pages 0x57..0x58 — overlay (2 pages, HD blink frame 0)
                ; Loop пишет 16 КБ на page и advance RAM_G на #4000 — для tongue
                ; padding zeros (11 КБ) ложится в gap до overlay (no harm).
                LD   A, FROG_PAGE
                LD   (BgPg), A
                LD   HL, FROG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FROG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, FROG_TOTAL_PAGES
.UploadFrog:    PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadFrog

                ; Залить killzone + match-3 explosion atlases contiguous в RAM_G.
                LD   A, KZ_PAGE
                LD   (BgPg), A
                LD   HL, KZ_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (KZ_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, KZ_PAGE_COUNT
.UploadKz:      PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadKz

                ; Залить cursor (page #5A, compressed ZX7) в RAM_G CURSOR_RAMG_ADDR.
                ; UnpackAndUploadPage заливает 16K — последние ~15K = zeros (padding),
                ; не страшно потому что #0D0000+1152..#0D4000 пустая зона
                ; (killzone начинается с #0D4000 и уже залит).
                LD   HL, CURSOR_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, CURSOR_PAGE
                CALL UnpackAndUploadPage

                ; Залить text atlases (GAME OVER + LEVEL 1-1 + SPIRAL OF DOOM)
                ; в FT_RAM_G #0..#10000 (свободная зона до bg).
                LD   HL, TEXT_GAMEOVER_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (TEXT_GAMEOVER_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, TEXT_GAMEOVER_PAGE
                CALL UnpackAndUploadPage

                LD   HL, TEXT_LEVEL11_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (TEXT_LEVEL11_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, TEXT_LEVEL11_PAGE
                CALL UnpackAndUploadPage

                LD   HL, TEXT_SPIRALDOOM_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (TEXT_SPIRALDOOM_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, TEXT_SPIRALDOOM_PAGE
                CALL UnpackAndUploadPage

                ; Sparkle (24×24 ARGB4) для intro track preview
                LD   HL, SPARKLE_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (SPARKLE_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, SPARKLE_PAGE
                CALL UnpackAndUploadPage

                ; --- Frame strips: palette raw + 5 strip pages ZX7 (16K-aligned blocks) ---
                ; Palette 512 байт raw → FRAME_PAL_RAMG.
                LD   A, FRAME_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (FRAME_PAL_RAMG >> 16) & 0xFF
                LD   DE, FRAME_PAL_RAMG & 0xFFFF
                CALL FT.WriteMem
                ; 5 ZX7-compressed strips through UnpackAndUploadPage (each 16K block).
                ; Setup BgRamH/L to FRAME_TOP_RAMG, then loop через 5 страниц подряд.
                LD   HL, FRAME_TOP_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FRAME_TOP_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FRAME_TOP_P0_PAGE
                CALL UnpackAndUploadPage              ; #084000 ← top_p0 (16K)
                LD   A, FRAME_TOP_P1_PAGE
                CALL UnpackAndUploadPage              ; #088000 ← top_p1 (11.5K + junk)
                LD   A, FRAME_BOT_PAGE
                CALL UnpackAndUploadPage              ; #08C000 ← bot
                LD   A, FRAME_LEFT_PAGE
                CALL UnpackAndUploadPage              ; #090000 ← left
                LD   A, FRAME_RIGHT_PAGE
                CALL UnpackAndUploadPage              ; #094000 ← right

                ; Восстановить слоты после серии compressed uploads:
                ; slot 2 = TrackData (page 6), slot 3 = main1_play (page #04).
                SetPage2 6
                SetPage3 #04

                ; --- VDC physics init (TrackData уже доступен в slot 2) ---
                CALL VDC_Init
                CALL Frog_Init
                CALL Bullet_Init
                CALL Log_Init                          ; circular RAM log для F12-dump
                RET

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 15                                ; DXT1_L4 640×480 (c0|c1|L4 = 230400 bytes, 15 × 16K pages, last padded)
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BALLS_FIRST_PAGE   EQU #2D                             ; balls_atlas paletted pages 0x2D..0x38 (12 pages)
BALLS_PAGE_COUNT   EQU 12                              ; PALETTED4444: 6×32×32×32 1bpp = 192 KB
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000)
BALLS_PALETTE_PAGE EQU #39                             ; palette ARGB4 СТРОГО 512 байт (256 entries × 2 bytes)
BALLS_PALETTE_RAMG EQU #080000                         ; FT_RAM_G — после balls (192K=#080000), 4-byte aligned
FROG_PAGE          EQU #52                             ; spgbld first page (frog body)
FROG_PAGE_COUNT    EQU 2                                ; 122×122 ARGB4 = 2 pages each
FROG_TOTAL_PAGES   EQU FROG_PAGE_COUNT * 4              ; body+plate+tongue+overlay = 8 pages
FROG_RAMG_ADDR     EQU #0B0000                         ; after 24-page balls atlas (#050000..#0AFFFF)
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #4000 * FROG_PAGE_COUNT     ; #0A4000
TONGUE_RAMG_ADDR   EQU PLATE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT    ; #0AC000
OVERLAY_RAMG_ADDR  EQU TONGUE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT   ; #0B4000
KZ_PAGE            EQU #16
KZ_PAGE_COUNT      EQU 10                              ; killzone 6 pages + destroy 4 pages
KZ_RAMG_ADDR       EQU #0D4000                         ; after cursor page, below RAM_G 1 MB limit
DESTROY_PAGE       EQU #1C
DESTROY_RAMG_ADDR  EQU #0EC000                         ; after killzone atlas, below RAM_G 1 MB limit

; --- Cursor 24×24 ARGB4 (1 page) ---
CURSOR_PAGE        EQU #5A
CURSOR_RAMG_ADDR   EQU #0D0000                         ; after frog overlay area
CURSOR_W           EQU 24                              ; матчится с make_cursor.py CURSOR_W
CURSOR_H           EQU 24
CURSOR_TIP_X       EQU 0                               ; острие sprite-coords (см. make_cursor.py)
CURSOR_TIP_Y       EQU 0

BgPg:           DEFB 0
BgRamL:         DEFW 0
BgRamH:         DEFB 0

Init_Core:      FMapAddrInit                          ; FT_EN, MEM_WO, page0=TSLibPage
                System_Setting SYS_ZCLK14 | SYS_CACHEEN
                Cache_Setting  EN_0000 | EN_4000 | EN_8000
                SetPage1 5                            ; #4000 → Core code page (main0 resident)
                SetPage2 6                            ; #8000 → TrackData (track_640.bin)
                SetPage3 #04                          ; #C000 → main1_play (scene-specific code)
                RET

TrackData       EQU #8000                             ; в slot 2 (page 6)

Init_Int:       ; Стандартная IM2 + frame INT инициализация (как в TSLib HelloWorld).
                ; HALT перед RET КРИТИЧЕН: ждём первый FRAME interrupt — это даёт
                ; TS-Conf время стабилизировать timing, иначе FT_BOOT_UP стартует
                ; до того как HW готова → видеорежим выходит неправильный.
                LD   HL, INT_Handler
                LD   (InterruptVA + INT_VEC_FRAME), HL
                LD   A,  HIGH InterruptVA
                LD   I,  A
                IM   2
                INT_Setting INT_MSK_FRAME
                EI
                HALT
                RET

INT_Handler:    EI
                RET
Main0_End:                                            ; MUST be after ALL main0 code (Init_Core/Init_Int/INT_Handler)

                ; ----- main1_play (slot 3, page #04) — scene-specific code -----
                SLOT 3 : PAGE #04 : ORG #C000
Main1_Start:
                include "Init_Video.asm"
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"
Main1_End:
                endmodule

Main0_Size       EQU Core.Main0_End - Core.Start
Main1_Size       EQU Core.Main1_End - Core.Main1_Start
                display "Main0:    \t", /A, Core.Start,       " size=", /D, Main0_Size, " bytes (slot 1 page 5)"
                display "Main1:    \t", /A, Core.Main1_Start, " size=", /D, Main1_Size, " bytes (slot 3 page #04)"
                SAVEBIN "Core.bin",        Core.Start,       Main0_Size
                SAVEBIN "main1_play.bin",  Core.Main1_Start, Main1_Size

                END EntryPoint
