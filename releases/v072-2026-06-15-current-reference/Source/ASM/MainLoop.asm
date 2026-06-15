
                ifndef _ZUMA_MAIN_LOOP_
                define _ZUMA_MAIN_LOOP_

; ============================================================================
; MainLoop — главный игровой цикл Zuma VDAC2 (640×480 через FT812)
; ----------------------------------------------------------------------------
; Каркас: на этом этапе DL содержит только тёмный фон + анимированную точку
; (proof-of-life). По мере добавления game-state'а сюда подключатся:
;   • VDC engine update (move_chain, animate_chain, try_spawn, scan_match…)
;   • Background bitmap из RAM_G
;   • Цикл по slots[] → BITMAP cells шаров (FT_Vertex2ii)
;   • Frog с rotation matrix к курсору
;   • Cursor + score
;
; Зависимости подключаются ровно те же что для Init_Video.asm
; (TSConf + Video + FT/81x Const + DL + 812 Macro + module FT 812 Func + Coprocessor).
;
; Контракт: MainLoop вызывается из EntryPoint после Init_Video и не возвращается.
; ============================================================================

; --- Константы кадра (всё в subpixel'ах: VertexFormat=4 → 1/16 px) ----------
; 1024×768 = ровно ×1.6 от 640×480. Геймплейные позиции шаров приходят уже
; в 1024-пространстве из track LUT (track gen умножает X/Y ×1.6 при том же
; числе сэмплов → физика/feel не меняются). Размеры спрайтов и фиксированные
; UI-координаты масштабируются ×1.6 как compile-time (×8/5) или через матрицу.
; Апскейл ×1.6 = ×8/5. Литералы координат/размеров пишем как (N*8+2)/5.
ZL_SCR_W        EQU 1024
ZL_SCR_H        EQU 768
ZL_SUB          EQU 16                                ; subpixel множитель
ZL_CMD_WARN_BYTES EQU #0F00                           ; warn до потолка: буфер #4CB0..#5C00 = 3920 байт,
                                                      ; дальше Core-код. Worst замер (dual+tunnel, полная
                                                      ; анимация) = 2872б — см. test_cmd_buffer_budget_z80.py.
ZL_FT_CMD_DMA_ENABLED EQU 1                           ; 1=send frame CMD buffer to FT812 via TS-Config DMA_RAM_SPI
ZL_PROFILER_ENABLED EQU 0                             ; 1=show FT812 timing overlay
ZL_FROG_DRAW_ENABLED EQU 1                            ; canary master: isolate frog tearing source
ZL_FROG_DRAW_PLATE   EQU 1                            ; no rotation
ZL_FROG_DRAW_BODY    EQU 1                            ; rotated main body
ZL_FROG_DRAW_TONGUE  EQU 1                            ; rotated tongue
ZL_FROG_DRAW_BALL_NOW  EQU 1                          ; ball on tongue / in mouth
ZL_FROG_DRAW_NEXT_BALL EQU 1                          ; next ball on frog back
ZL_FROG_DRAW_OVERLAY EQU 1                            ; rotated face overlay
ZL_SPACE_LEVEL_INDEX EQU LEVEL_RUNTIME_COUNT - 1       ; Space is the last runtime board
ZL_SPACE_STARS_PER_LAYER EQU 24
ZL_TRACKF_TUNNEL     EQU #01                           ; track flags bit0: no bullet hit
ZL_TRACKF_DRAW_ABOVE EQU #02                           ; track flags bit1: draw after top layer

; ----------------------------------------------------------------------------
; MainLoop — точка входа. Никогда не возвращается.
; ----------------------------------------------------------------------------
MainLoop:       ; --- Init game state (одноразово при первом входе) ---
                LD   HL, 0
                LD   (ZL_FrameCounter), HL
                LD   A, #FF
                LD   (ZL_TopMaskUploadedLevel), A
                ; Spin K — runtime (per-level калибровка). Default = level 1.
                LD   A, ZL_SPIN_K_DEFAULT
                LD   (ZL_SpinK), A

.Loop           ; --- 1. Update input + game state (Z80-only, параллельно с FT812 render) ---
                if ZL_PROFILER_ENABLED
                CALL ZL_ProfileReadClock
                LD   (ZL_ProfileLoopStartLo), DE
                LD   (ZL_ProfileLoopStartHi), HL
                endif
                CALL Input_Scan                      ; единый опрос ввода: мышь + PS/2-клавиатура
                CALL EscToMenu                       ; ESC = нажатие кнопки MENU (открыть pause-меню)
                CALL ZL_AimUpdate
                CALL ZL_SmoothMouse
                CALL UpdateDialog                    ; mouse hit-test на retry-dialog кнопках
                CALL UpdateHudMenu                   ; top MENU button hover/press + input block
                LD   A, (VDC_HasSecondChain)
                OR   A
                JR   Z, .frog_update_chain1
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   NZ, .frog_update_chain1
                LD   A, (VDC2_SlotsLen)
                OR   A
                JR   Z, .frog_update_chain1
                CALL VDC_SwapChains
                CALL Frog_Update
                CALL VDC_SwapChains
                JR   .frog_update_done
.frog_update_chain1:
                CALL Frog_Update
.frog_update_done:
                CALL VDC_UpdateAllChains
                CALL Bullet_Update
                CALL Bullet_CheckCollisionAllChains
                CALL GS_UpdateSfxMuteMaybe
                CALL VDC_CheckInvariants

                ; --- 2. Build DL в Z80 buffer (тоже параллельно с render). Тяжёлый
                ; build (mouse motion → ComputeFrogAngle/atan2) не съедает FT812
                ; vblank window — write всегда попадает строго в vblank.
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x102030
                FT_ClearAll
                CALL ZL_DrawFrame
                CALL DrawDebugClock
                FT_Display
                FT_CMD_Count
                LD   (ZL_CmdBytes), BC
                LD   HL, ZL_CMD_WARN_BYTES
                AND  A
                SBC  HL, BC
                JR   NC, .CmdSizeOk
                LD   A, 1
                LD   (ZL_CmdOverflow), A
.CmdSizeOk

                if ZL_PROFILER_ENABLED
                CALL ZL_ProfileReadClock
                LD   BC, (ZL_ProfileLoopStartLo)
                LD   IX, (ZL_ProfileLoopStartHi)
                CALL ZL_ProfileDeltaK
                LD   (ZL_ProfileBuildK), HL
                LD   (ZL_ProfilePostBuildLo), DE
                LD   (ZL_ProfilePostBuildHi), IX
                endif

                ; --- 3. Sync с FT812 swap interrupt, then wait until previous
                ; DLSWAP request completed.  On real VDAC2, letting the
                ; coprocessor rebuild RAM_DL during active scanout tears badly.
.WaitIntSync    FT_RD_REG8 FT_REG_INT_FLAGS
                AND  FT_INT_SWAP
                JR   Z, .WaitIntSync
                FT_WR_REG8 FT_REG_INT_FLAGS, FT_INT_SWAP   ; Clear flag
.WaitDLSwap     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .WaitDLSwap

                if ZL_PROFILER_ENABLED
                CALL ZL_ProfileReadClock
                LD   BC, (ZL_ProfilePostBuildLo)
                LD   IX, (ZL_ProfilePostBuildHi)
                CALL ZL_ProfileDeltaK
                LD   (ZL_ProfileIdleK), HL
                LD   (ZL_ProfilePreWriteLo), DE
                LD   (ZL_ProfilePreWriteHi), IX
                endif

                ; --- 4. Burst write Z80 buffer → FT812 RAM_CMD in the swap window,
                ; wait until coprocessor has produced RAM_DL, then request swap.
                if ZL_FT_CMD_DMA_ENABLED
                CALL ZL_FT_CMD_Write_DMA
                else
                FT_CMD_Write
                endif
                CALL FT.Coprocessor.WaitFlush
                if ZL_PROFILER_ENABLED
                CALL ZL_ProfileReadClock
                LD   BC, (ZL_ProfilePreWriteLo)
                LD   IX, (ZL_ProfilePreWriteHi)
                CALL ZL_ProfileDeltaK
                LD   (ZL_ProfileWriteK), HL
                endif
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME

                ; --- 5. Frame counter ---
                LD   HL, (ZL_FrameCounter)
                INC  HL
                LD   (ZL_FrameCounter), HL

                JP   .Loop

; ----------------------------------------------------------------------------
; Log_Init и LogEvent — в slot 0 (page 0) после TSLib (main.asm). Перенесены
; туда из-за переполнения Core 8 KB предела. См. main.asm.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; ZL_DrawFrame — собрать DL-команды текущего кадра
; ----------------------------------------------------------------------------
ZL_BALL_DIAM_PX  EQU 32                               ; atlas cell size (BitmapLayout/stride/offset) — НЕ масштабировать
ZL_BALL_VISIBLE  EQU ZL_BALL_DIAM_PX                  ; visible diameter = atlas cell (без alpha-padding)
ZL_BALL_W        EQU ZL_BALL_DIAM_PX                  ; atlas cell для BitmapLayout
ZL_BALL_H        EQU ZL_BALL_DIAM_PX
ZL_BALL_DRAW     EQU 51                               ; 1024×768: экранный размер = round(32×8/5); BitmapSize
ZL_BALL_HALF     EQU 26                               ; центр draw-rect'а (round(51/2)) для VERTEX2F centering
                                                     ; (вращение/scale запечены в chain_matrix_lut.bin, pivot=16 atlas)
; --- Spin physics: rolling-without-slip связь между движением t и phase atlas ---
; t — позиция шара на треке в track samples. Phase меняется ТОЛЬКО когда t движется
; → автоматически пропорционально скорости шаров (быстрее цепь → быстрее phase).
;
; Формула: spin_frame = ((t * K) >> 8) & (ATLAS_PHASES-1), где
;   K = 256 * ATLAS_PHASES / (π * D_samples)
; t измеряется в track samples. Физически точное rolling-without-slip для D=VDC_CELL_SIZE
; даёт K≈41, но при текущей скорости цепи это визуально слишком медленно для Zuma-feel.
; Поэтому используем визуальный период в 2 раза короче: D_samples = VDC_CELL_SIZE/2.
; Для CELL_SIZE=32, phases=16:
;   K = 256*16*113/(355*16) ≈ 81.49 → 81.
;
; K держится в RAM (ZL_SpinK) — runtime, можно менять per-level. Default = compile-time.
                if BALLS_ARGB4_ENABLED
ZL_ATLAS_PHASES            EQU 16
                else
ZL_ATLAS_PHASES            EQU 32
                endif
ZL_SPIN_DIAM_SAMPLES       EQU VDC_CELL_SIZE / 2
ZL_SPIN_K_NUM              EQU 256 * ZL_ATLAS_PHASES * 113
ZL_SPIN_K_DEN              EQU 355 * ZL_SPIN_DIAM_SAMPLES
ZL_SPIN_K_DEFAULT          EQU (ZL_SPIN_K_NUM + ZL_SPIN_K_DEN / 2) / ZL_SPIN_K_DEN
ZL_SPIN_MASK               EQU ZL_ATLAS_PHASES - 1

; --- Bucket-based tangent rotation: цепь группирована по buckets, 1 cmd_rotate per bucket.
; ZL_BUCKETS = 8/16/32/64. Чем больше — тем плавнее rotation, но больше cmd_rotate/frame.
; bucket = (tangent + step/2) / step mod N. step = 256/N BRAD.
ZL_BUCKETS      EQU 32                                ; (dead-code legacy; per-ball replaced bucket loop 2026-05-18)

; --- PALETTED4444 dual handle: 6×32 = 192 cells > 128 → split в 2 handle.
; Handle 0 source = BALLS_RAMG_ADDR (cells 0..127).
; Handle 9 source = BALLS_RAMG_ADDR + 128 × ZL_BALL_W × ZL_BALL_H (cells 0..63 = global 128..191).
BALLS_HANDLE9_OFFSET EQU 128 * ZL_BALL_W * ZL_BALL_H        ; PALETTED = 1 byte/pixel cell
ZL_DESTROY_HANDLE EQU 10                             ; match-3 серый animBallDestroy
ZL_DESTROY_W      EQU 48                               ; atlas cell (layout) — НЕ масштабировать
ZL_DESTROY_H      EQU 48
ZL_DESTROY_DRAW   EQU 77                               ; 1024×768: экранный размер = round(48×8/5)
ZL_DESTROY_HALF_DELTA EQU ((ZL_DESTROY_DRAW - ZL_BALL_DRAW) / 2) * 16
ZL_DESTROY_FRAMES EQU 13                              ; match-3 destroy: 13 кадров
; WIN-взрыв (оранжевый HD-ref animExplosion) — ОТДЕЛЬНЫЙ атлас/handle/RAM_G:
ZL_WINEXP_HANDLE  EQU 9                               ; handle шаров (в WIN-стейте шаров нет → свободен).
                                                     ; ВАЖНО: ≤15, вне диапазона ROM-шрифтов FT812 (16..31).
                                                     ; Раньше был 26 — совпадал с font 26 у DrawDebugClock:
                                                     ; взрыв перенастраивал BITMAP_SOURCE(26) на свой атлас
                                                     ; #050000, и часы (CMD_NUMBER font 26) читали глифы из
                                                     ; атласа взрыва → мусор на месте цифр (только на железе,
                                                     ; эмулятор залипание per-handle source не моделирует).
ZL_WINEXP_FRAMES  EQU 17                              ; HD-ref animExplosion: 17 кадров
ZL_WINEXP_DRAW    EQU 128                             ; 1024×768: 80×1.6 (рисуется при scale(1.6)-матрице)
ZL_WINEXP_XOFF    EQU 2                               ; 1×1.6 manual screen offset
ZL_WINEXP_YOFF    EQU -3                              ; -2×1.6
ZL_BG_W         EQU 400                               ; native bg storage, upscaled to 1024x768
ZL_BG_H         EQU 300
ZL_BG_DRAW_W    EQU 1024
ZL_BG_DRAW_H    EQU 768
ZL_BG_SCALE     EQU #00028F5C                         ; 2.56 in f16.16 (1024/400 = 768/300)
ZL_BG_HANDLE    EQU 1

; Local DL command constants not covered by existing TSLib macros.
ZL_FT_L2        EQU FT_L4                              ; legacy DXT boot-mask constant; gameplay top-cover uses ARGB4 meta
ZL_DL_BLEND_FUNC EQU #0B000000
ZL_DL_COLOR_A   EQU #10000000
ZL_DL_COLOR_MASK EQU #20000000
ZL_DL_BITMAP_SIZE_H EQU #29000000
ZL_DL_SAVE_CONTEXT EQU #22000000
ZL_DL_RESTORE_CONTEXT EQU #23000000
ZL_BLEND_ZERO   EQU 0
ZL_BLEND_ONE    EQU 1
ZL_BLEND_DST_ALPHA EQU 3
ZL_BLEND_ONE_MINUS_DST_ALPHA EQU 5
ZL_COLOR_MASK_RGB EQU %00001110
ZL_COLOR_MASK_A EQU %00000001

ZL_BALL_COLORS  EQU 6

; ============================================================================
; DrawDebugClock — HH:MM:SS в левом нижнем углу над bottom frame.
; Bottom frame занимает Y=456..479 (24 px). Clock на Y=438 (18 px выше).
; X=28 — сразу за left frame (24 px) + 4 px отступ.
; Font 26 = FT812 ROM 8×16, "HH:MM:SS" ≈ 64 px wide.
; ============================================================================
DrawDebugClock:
                ; Tint white
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                ; Компактно (1024-порт): форматируем "HH:MM:SS" в буфер и рисуем
                ; ОДНИМ CMD_TEXT (глифы ×1.6 масштабирует матрица, оставшаяся от
                ; курсора). Было 3×CMD_NUMBER + 2×CMD_TEXT инлайнами = 465 байт.
                LD   HL, ZL_ClockBuf
                LD   A, 4                             ; RTC 4 = часы (binary)
                CALL ReadRTCRegister
                CALL .two
                LD   (HL), ':' : INC HL
                LD   A, 2                             ; RTC 2 = минуты
                CALL ReadRTCRegister
                CALL .two
                LD   (HL), ':' : INC HL
                XOR  A                                ; RTC 0 = секунды
                CALL ReadRTCRegister
                CALL .two
                LD   (HL), 0                          ; null + паддинг (буфер 12б, хвост нули)
                ; Часы — СИСТЕМНЫМ ROM-шрифтом БЕЗ масштабирования (решение юзера
                ; 2026-06-11): сбрасываем матрицу (курсор оставил scale 1.6).
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                FT_Text 45, 712, 26, 0                ; над нижней рамкой: верх рамки 768−38=730,
                                                      ; часы 730−16(шрифт)−2(зазор) — пропорция оригинала
                                                      ; (640: рамка 456, часы 438)
                LD   HL, ZL_ClockBuf
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 12                           ; "HH:MM:SS\0" + паддинг до 4
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                RET
.two:           ; A = 0..59 binary → два ASCII-знака в (HL)+
                LD   C, '0'
.t10:           CP   10
                JR   C, .t1
                SUB  10
                INC  C
                JR   .t10
.t1:            LD   (HL), C : INC HL
                ADD  A, '0'
                LD   (HL), A : INC HL
                RET

ZL_ClockBuf:    DEFB 0,0,0,0,0,0,0,0,0,0,0,0          ; "HH:MM:SS\0" + 4-байт паддинг

ZL_DrawFrame:
                ; --- Tint: белый (без модуляции цвета bitmap) ---
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; 400x300 PALETTED4444 background: one pass, NEAREST upscale to 640x480.
                CALL ZL_EmitLoadId
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF ZL_BG_SCALE
                FT_CMD_BUF ZL_BG_SCALE
                CALL ZL_EmitSetMatrix
                FT_PaletteSource BG_PALETTE_RAMG
                FT_BitmapHandle ZL_BG_HANDLE
                FT_BitmapSource BG_RAMG_ADDR
                FT_BitmapLayout FT_PALETTED4444, ZL_BG_W, ZL_BG_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BG_DRAW_W, ZL_BG_DRAW_H
                FT_Begin FT_BITMAPS
                XOR  A
                CALL FT.Coprocessor.Cell
                FT_Vertex2ii 0, 0, ZL_BG_HANDLE, 0
                FT_End
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                CALL ZL_DrawSpaceStarsMaybe

                ; One bitmap primitive for the remaining bitmap layers.
                FT_Begin FT_BITMAPS

                ; ============================================================
                ; Killzone: hole (cell 0) → skull (cell VDC_KzFrame) на последнем
                ; track-sample. Перенесено в slot 0 helper (Core size).
                ; ============================================================
                CALL DrawKillzoneDual

                ; ============================================================
                ; Цепь шаров — PALETTED4444 dual handle (cell<128 handle 0, ≥128 handle 9).
                ; Palette ARGB4 (256 × 2 = 512 байт) в FT_RAM_G #080000.
                ; FT_PaletteSource устанавливает указатель для текущей primitive.
                ; ============================================================
                if !BALLS_ARGB4_ENABLED
                FT_PaletteSource BALLS_PALETTE_RAMG
                LD   A, 9
                CALL ZL_EmitBallHandle
                FT_BitmapLayout FT_PALETTED4444, ZL_BALL_W, ZL_BALL_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_DRAW, ZL_BALL_DRAW
                endif
                XOR  A
                CALL ZL_EmitBallHandle
                if BALLS_ARGB4_ENABLED
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                else
                FT_BitmapLayout FT_PALETTED4444, ZL_BALL_W, ZL_BALL_H
                endif
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_DRAW, ZL_BALL_DRAW

                ; --- VDC chain rendering: per-ball tangent + grouped matrix emit.
                ; Algorithm:
                ;   Pre-pass: cache stable tangent, cell, Vx, Vy for each ball.
                ;   Draw: quantize tangent to 8 BRAD and emit matrix only when it
                ;   differs from the previous visible ball. This keeps per-slot
                ;   tangent stability without the old bucket segment flicker.
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                ; 1024×768: гейты heavy-dual/top-mask сняты — спин/вращение на всех
                ; уровнях. ZL_HeavyTunnelDual/ZL_HeavyBallCount больше не нужны
                ; (мёртвый код удалён, освобождает Main1). Оставлен только
                ; ZL_HasTopMaskLevel — его читает top-mask рендер тоннельных уровней.
                XOR  A
                LD   (ZL_HasTopMaskLevel), A
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                OR   A
                JR   Z, .HeavyTunnelDone
                LD   A, 1
                LD   (ZL_HasTopMaskLevel), A
.HeavyTunnelDone:
                LD   A, (VDC_DialogState)
                LD   (ZL_BallRotationDisabled), A
                CALL ZL_DrawActiveChainForLevel
                LD   A, (VDC_HasSecondChain)
                OR   A
                JP   Z, ZL_AfterChains
                CALL VDC_SwapChains
                CALL SetSecondTrackPage
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                CALL ZL_DrawActiveChainForLevel
                CALL VDC_SwapChains
                CALL SetCurrentTrackPage
                XOR  A
                LD   (ZL_BallRotationDisabled), A
                JP   ZL_AfterChains

; ----------------------------------------------------------------------------
; Space-only procedural starfield. Drawn after the bitmap background, before all
; gameplay bitmaps, so stars are above the Space picture but below track/balls.
; Uses FT812 POINTS only: no RAM_G, no assets, no persistent star state.
; ----------------------------------------------------------------------------
ZL_DrawSpaceStarsMaybe:
                LD   A, (CurrentLevel)
                CP   ZL_SPACE_LEVEL_INDEX
                RET  NZ

                LD   C, 235 : LD D, 240 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; 1024×768: поле на ВЕСЬ экран (было 640×480 — правые 384px и низ
                ; пустые), wrap по 1024 (= AND, степень двойки), размеры точек ×1.6.
                LD   HL, (ZL_FrameCounter)
                SRL  H : RR L
                CALL ZL_ReduceHLMod1024
                LD   (ZL_StarOffset), HL
                LD   HL, ZL_StarsFar
                LD   A, 80
                LD   DE, 19                              ; 12×1.6
                CALL ZL_DrawSpaceStarLayer

                LD   HL, (ZL_FrameCounter)
                CALL ZL_ReduceHLMod1024
                LD   (ZL_StarOffset), HL
                LD   HL, ZL_StarsMid
                LD   A, 130
                LD   DE, 29                              ; 18×1.6
                CALL ZL_DrawSpaceStarLayer

                LD   HL, (ZL_FrameCounter)
                ADD  HL, HL
                CALL ZL_ReduceHLMod1024
                LD   (ZL_StarOffset), HL
                LD   HL, ZL_StarsNear
                LD   A, 205
                LD   DE, 45                              ; 28×1.6
                CALL ZL_DrawSpaceStarLayer

                LD   E, 255
                CALL FT.Coprocessor.ColorA
                LD   C, 255 : LD D, 255 : LD E, 255
                JP   FT.Coprocessor.ColorRGB

; In: HL=seed pairs, A=alpha, DE=point size in 1/16 px.
ZL_DrawSpaceStarLayer:
                LD   (ZL_StarPtr), HL
                LD   (ZL_StarPointSize), DE
                LD   E, A
                CALL FT.Coprocessor.ColorA
                LD   DE, (ZL_StarPointSize)
                CALL FT.Coprocessor.PointSize
                FT_Begin FT_POINTS
                LD   A, ZL_SPACE_STARS_PER_LAYER
                LD   (ZL_StarCount), A
.star_loop:     LD   HL, (ZL_StarPtr)
                LD   A, (HL)
                INC  HL
                LD   E, A                                ; E = x seed
                LD   D, (HL)                             ; D = y seed
                INC  HL
                LD   (ZL_StarPtr), HL

                ; 1024×768: x = seed×4 (+2 при бите D) → 0..1022 шагом 2 (та же
                ; гранулярность относительно ширины, что seed×2 на 640)
                LD   L, E
                LD   H, 0
                ADD  HL, HL                              ; ×2
                ADD  HL, HL                              ; ×4 → 0..1020
                BIT  0, D
                JR   Z, .x_no_hi
                INC  HL
                INC  HL                                  ; +2 → межколоночный сдвиг
.x_no_hi:       PUSH DE
                LD   DE, (ZL_StarOffset)
                ADD  HL, DE                              ; + скролл слоя
                LD   A, H
                AND  #03                                 ; mod 1024 одним AND
                LD   H, A
                POP  DE
                ADD  HL, HL                              ; x subpx = px*16
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                LD   B, H
                LD   C, L

                ; y = seed×3 → 0..765: ВСЯ высота (было seed(mod 240)×2 = 0..478,
                ; нижние 290px экрана оставались пустыми)
                LD   L, D
                LD   H, 0
                LD   E, D
                LD   D, 0
                ADD  HL, HL                              ; 2·seed
                ADD  HL, DE                              ; 3·seed
                ADD  HL, HL                              ; y subpx = px*16
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f

                LD   HL, ZL_StarCount
                DEC  (HL)
                JR   NZ, .star_loop
                FT_End
                RET

ZL_ReduceHLMod1024:
                ; 1024 — степень двойки: mod = AND #03FF (вместо цикла вычитаний)
                LD   A, H
                AND  #03
                LD   H, A
                RET

ZL_StarOffset:    DEFW 0
ZL_StarCount:     DEFB 0
ZL_StarPtr:       DEFW 0
ZL_StarPointSize: DEFW 0

ZL_StarsFar:
                DB  11,  33,  91, 207, 174,  68,  42, 149, 223,  17,  68, 232
                DB 137, 115,  29,  86, 198, 188,  77,  51, 241, 132,   5, 221
                DB 156,  13, 101, 176, 213, 244,  54,  98, 189,  39,  25, 163
                DB 232, 201, 118,  72,  64, 255, 145,  25,   7, 121, 204,  44
ZL_StarsMid:
                DB  36, 196, 128,  57,  13, 239, 218, 104,  84,  23, 167, 155
                DB 249,  82,  59, 214, 191,   9, 104, 128,   3,  73, 228, 186
                DB 150, 252,  72,  41,  20, 142, 206, 226, 112,  12,  45, 171
                DB 238, 119, 132,  94,  94, 231, 176,  64,  61, 201, 220,  31
ZL_StarsNear:
                DB  71,  29, 201, 218,  19, 109, 143,  46, 233, 177,  52,  88
                DB 116, 243, 252,  14,  39, 151, 183, 197,  97,  61,   8, 227
                DB 164, 127,  26,  69, 221,  35,  86, 209, 242, 100,  58, 251
                DB 134,  18, 194, 166,   4,  78, 155, 234,  66, 139, 212,  54

; EnsureDialogFrameUploaded — DIALOG_FRAME_RAMG это gameplay swap-окно.
; Активный tunnel gameplay может использовать #0AC000..#0CC000 под качественный
; top-cover. Pause/dialog по требованию перезагружает frame и инвалидирует
; top masks, чтобы resume заново залил tunnel cover перед активной игрой.
EnsureDialogFrameUploaded:
                LD   A, (DialogFrameLoaded)
                OR   A
                JR   Z, .not_loaded
                LD   A, 1
                RET
.not_loaded:    LD   A, (ZL_DialogFrameUploadDeferred)
                OR   A
                JR   Z, .check_live_topmask
                CP   2
                JR   NC, .upload_now
                INC  A
                LD   (ZL_DialogFrameUploadDeferred), A
                XOR  A
                RET
.check_live_topmask:
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                OR   A
                JR   Z, .upload_now
                LD   A, (CurrentLevel)
                LD   B, A
                LD   A, (ZL_TopMaskUploadedLevel)
                CP   B
                JR   NZ, .upload_now
                LD   A, 1
                LD   (ZL_DialogFrameUploadDeferred), A
                XOR  A
                RET
.upload_now:    XOR  A
                LD   (ZL_DialogFrameUploadDeferred), A
                LD   HL, DIALOG_FRAME_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (DIALOG_FRAME_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, DIALOG_FRAME_PAGE_BASE
                LD   B, DIALOG_FRAME_NUM_PAGES
.UploadDFrame:  PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage                ; auto-advances RAM_G +16K
                POP  AF
                INC  A
                POP  BC
                DJNZ .UploadDFrame
                LD   A, 1
                LD   (DialogFrameLoaded), A
                LD   A, #FF
                LD   (ZL_TopMaskUploadedLevel), A       ; dialog upload вытесняет tunnel swap payload
                LD   A, 1
                RET

ZL_DrawActiveChainForLevel:
                if !TOP_MASK_ENABLED
                JP   ZL_DrawActiveChain
                endif
                CALL ZL_RestoreActiveTrackPage
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                OR   A
                JP   Z, ZL_DrawActiveChain
                LD   A, (Core.VDC_DialogState)
                OR   A
                JR   Z, .gameplay_top_mask
.dialog_state:
                LD   A, (DialogFrameLoaded)
                OR   A
                JR   NZ, .dialog_skip_tunnel
                LD   A, (ZL_DialogFrameUploadDeferred)
                OR   A
                JR   NZ, .dialog_skip_tunnel
                LD   A, (CurrentLevel)
                LD   B, A
                LD   A, (ZL_TopMaskUploadedLevel)
                CP   B
                JR   NZ, .dialog_skip_tunnel
                CALL ZL_SetupBallBitmapState
                LD   A, 3
                LD   (ZL_ChainDrawPass), A             ; first pause frame: hide tunnel balls while top-cover is still on
                CALL ZL_DrawActiveChainWithMode
                JP   ZL_DrawTopMaskOverlay
.dialog_skip_tunnel:
                LD   A, 3
                LD   (ZL_ChainDrawPass), A             ; pause/dialog: пропуск TRACKF_TUNNEL, без top-cover
                JP   ZL_DrawActiveChainWithMode
.gameplay_top_mask:
                CALL ZL_UploadTopMasksMaybe
                CALL ZL_RestoreActiveTrackPage
                CALL ZL_SetupBallBitmapState
                LD   A, 1
                LD   (ZL_ChainDrawPass), A             ; top-mask levels: under/tunnel balls first
                CALL ZL_DrawActiveChainWithMode
                CALL ZL_DrawTopMaskOverlay
                CALL ZL_SetupBallBitmapState
                LD   A, 2
                LD   (ZL_ChainDrawPass), A             ; then draw balls marked above the tunnel cover
                JP   ZL_DrawActiveChainWithMode

ZL_GetTopMaskForCurrentLevel:
                LD   A, (CurrentLevel)
                CP   LEVEL_RUNTIME_COUNT
                JR   C, .ok
                XOR  A
.ok:            LD   E, A
                LD   D, 0
                LD   HL, TopMaskLevelTable
                ADD  HL, DE
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

ZL_UploadTopMasksMaybe:
                LD   A, (CurrentLevel)
                LD   B, A
                LD   A, (ZL_TopMaskUploadedLevel)
                CP   B
                RET  Z
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                INC  HL
                LD   (ZL_TopMaskCount), A
                OR   A
                JR   Z, .mark_level
                LD   E, (HL)                            ; offset in TOP_MASK_META_PAGE
                INC  HL
                LD   D, (HL)
                LD   HL, #8000
                ADD  HL, DE
                LD   A, TOP_MASK_META_PAGE
                SetPage2_A
.upload_loop:   LD   A, (HL)                            ; SPG page
                INC  HL
                LD   (ZL_TopMaskSrcPage), A
                LD   E, (HL)                            ; source offset inside SPG page
                INC  HL
                LD   D, (HL)
                INC  HL
                LD   (ZL_TopMaskSrcLo), DE
                LD   E, (HL)                            ; RAM_G low word
                INC  HL
                LD   D, (HL)
                INC  HL
                LD   (ZL_TopMaskRamLo), DE
                LD   A, (HL)                            ; RAM_G high byte
                INC  HL
                LD   (ZL_TopMaskRamHi), A
                LD   C, (HL)                            ; upload size
                INC  HL
                LD   B, (HL)
                INC  HL
                LD   DE, TOP_MASK_CMD_BYTES
                ADD  HL, DE
                LD   (ZL_TopMaskTablePtr), HL
                LD   A, (ZL_TopMaskSrcPage)
                SetPage2_A
                LD   HL, #8000
                LD   DE, (ZL_TopMaskSrcLo)
                ADD  HL, DE
                LD   A, (ZL_TopMaskRamHi)
                LD   DE, (ZL_TopMaskRamLo)
                CALL FT.WriteMem
                LD   A, TOP_MASK_META_PAGE
                SetPage2_A
                LD   HL, (ZL_TopMaskTablePtr)
                LD   A, (ZL_TopMaskCount)
                DEC  A
                LD   (ZL_TopMaskCount), A
                JR   NZ, .upload_loop
.topmask_uploaded:
                XOR  A
                LD   (DialogFrameLoaded), A             ; tunnel top-cover владеет swap-окном до reload диалога
                LD   (ZL_DialogFrameUploadDeferred), A
.mark_level:    LD   A, (CurrentLevel)
                LD   (ZL_TopMaskUploadedLevel), A
                RET

ZL_SetupBallBitmapState:
                FT_Begin FT_BITMAPS
                if !BALLS_ARGB4_ENABLED
                FT_PaletteSource BALLS_PALETTE_RAMG
                LD   A, 9
                CALL ZL_EmitBallHandle
                FT_BitmapLayout FT_PALETTED4444, ZL_BALL_W, ZL_BALL_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_DRAW, ZL_BALL_DRAW
                endif
                XOR  A
                CALL ZL_EmitBallHandle
                if BALLS_ARGB4_ENABLED
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                else
                FT_BitmapLayout FT_PALETTED4444, ZL_BALL_W, ZL_BALL_H
                endif
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_DRAW, ZL_BALL_DRAW
                RET

ZL_DrawTopMaskOverlay:
                FT_End
                CALL ZL_EmitLoadId
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF ZL_BG_SCALE
                FT_CMD_BUF ZL_BG_SCALE
                CALL ZL_EmitSetMatrix
                FT_BitmapHandle TOP_MASK_HANDLE
                FT_Begin FT_BITMAPS
                XOR  A
                CALL FT.Coprocessor.Cell
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                INC  HL
                LD   (ZL_TopMaskCount), A
                LD   E, (HL)                            ; offset in TOP_MASK_META_PAGE
                INC  HL
                LD   D, (HL)
                LD   HL, #8000
                ADD  HL, DE
                LD   A, TOP_MASK_META_PAGE
                SetPage2_A
.mask_loop:     LD   A, (ZL_TopMaskCount)
                OR   A
                JR   Z, .mask_done
                LD   DE, TOP_MASK_CMD_OFFSET
                ADD  HL, DE
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, TOP_MASK_CMD_BYTES
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                LD   A, (ZL_TopMaskCount)
                DEC  A
                LD   (ZL_TopMaskCount), A
                JR   .mask_loop
.mask_done:     FT_End
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                CALL ZL_RestoreActiveTrackPage
                RET

ZL_RestoreActiveTrackPage:
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A
                RET

ZL_DrawActiveChain:
                XOR  A
                LD   (ZL_ChainDrawPass), A             ; 0 = legacy/all balls in one pass
ZL_DrawActiveChainWithMode:
                LD   A, (VDC_SlotsLen)
                LD   (ZL_BallCount), A
                OR   A
                JP   Z, .ChainEnd
                LD   B, A                             ; B = loop count
                LD   C, 0                             ; C = i
                LD   HL, ZL_BALL_CACHE_ADDR                 ; cache write ptr
                LD   (ZL_CacheWPtr), HL
.PrePassLoop:   PUSH BC                               ; save count+i
                LD   A, C
                LD   (ZL_TmpSlotIdx), A
                LD   HL, (ZL_CacheWPtr)
                ; --- gap-проверка ---
                LD   A, C
                LD   D, 0 : LD E, A
                PUSH HL                               ; save cache ptr (DE = i)
                LD   HL, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)                          ; Slots[i]
                POP  HL                               ; restore cache ptr
                CP   VDC_NUM_COLORS                   ; ≥ 6 → gap
                JP   NC, .PrePassMark
                LD   (ZL_TmpFrame), A                 ; color
                LD   A, C
                PUSH HL                               ; save cache ptr
                CALL VDC_SlotPos                      ; BC=X, DE=Y, CF=1=skip
                POP  HL                               ; restore cache ptr
                JP   C, .PrePassMark
                LD   (ZL_TmpBallX), BC
                LD   (ZL_TmpBallY), DE
                ; 1024×768: шар ЦЕЛИКОМ вне экрана → gap-маркер (не эмитим).
                ; За правым краем (X≥1050) corner-вершина (X−26)*16 ≥ 16384 НЕ
                ; влезает в 15-битное signed поле VERTEX2F и заворачивается в
                ; минус — формально мусорная вершина (старт L11: x=1115 →
                ; «призрак» на −997px). На FT812 призрак за левым краем невидим,
                ; но это та же 15-битная граната, что фейд-рект и Vertex2ii бара.
                ; Заодно экономит CMD-бюджет (спавн-хвост за экраном не эмитится).
                PUSH HL                               ; cache ptr
                LD   HL, (ZL_TmpBallX)
                LD   DE, ZL_BALL_HALF
                ADD  HL, DE                           ; HL = X+26
                BIT  7, H
                JR   NZ, .PrePassCull                 ; X < −26 → целиком слева
                LD   DE, 1024 + ZL_BALL_DRAW + 1
                AND  A
                SBC  HL, DE
                JR   NC, .PrePassCull                 ; X ≥ 1050 → целиком справа
                LD   HL, (ZL_TmpBallY)
                LD   DE, ZL_BALL_HALF
                ADD  HL, DE
                BIT  7, H
                JR   NZ, .PrePassCull                 ; Y < −26 → целиком сверху
                LD   DE, 768 + ZL_BALL_DRAW + 1
                AND  A
                SBC  HL, DE
                JR   NC, .PrePassCull                 ; Y ≥ 794 → целиком снизу
                POP  HL                               ; cache ptr — шар (частично) на экране
                LD   A, (VDC_LastTrackFlags)
                LD   (ZL_TmpTrackFlags), A
                ; --- spin --- (1024×768: полная анимация на ВСЕХ уровнях,
                ; гейты tunnel/top-mask и heavy-dual≥70 сняты по решению юзера)
                PUSH HL                               ; save cache ptr
                LD   HL, (VDC_LastT)
                CALL ZL_SpinPhase                     ; A = spin 0..15/31
                LD   D, A
.PrePassSpinDone:
                LD   A, (ZL_TmpFrame)                 ; color
                if BALLS_ARGB4_ENABLED
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A               ; x16
                else
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A    ; x32
                endif
                ADD  A, D                             ; cell = color*32 + spin
                LD   (ZL_TmpFrame), A
                ; Raw tangent only. The old per-slot hysteresis state lived near
                ; #4000 and collided with the runtime stack at #40F2 on hardware.
                LD   A, (VDC_LastTangent)
                POP  HL                               ; restore cache ptr
                LD   (HL), A : INC HL                 ; +0 tangent
                LD   A, (ZL_TmpFrame)
                LD   (HL), A : INC HL                 ; +1 global cell (0..191, или 0xFF=gap)
                ; Vx = (BallX - HALF) × SUB
                PUSH HL
                LD   HL, (ZL_TmpBallX)
                LD   DE, ZL_BALL_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL              ; ×16
                EX   DE, HL                            ; DE = Vx
                POP  HL                               ; cache ptr
                LD   (HL), E : INC HL                 ; +2 Vx lo
                LD   (HL), D : INC HL                 ; +3 Vx hi
                ; Vy = (BallY - HALF) × SUB
                PUSH HL
                LD   HL, (ZL_TmpBallY)
                LD   DE, ZL_BALL_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL              ; ×16
                EX   DE, HL                            ; DE = Vy
                POP  HL
                LD   (HL), E : INC HL                 ; +4 Vy lo
                LD   (HL), D : INC HL                 ; +5 Vy hi
                LD   A, (ZL_TmpTrackFlags)
                LD   (HL), A : INC HL                 ; +6 track flags
                LD   (ZL_CacheWPtr), HL
                POP  BC
                INC  C
                DEC  B
                JP   NZ, .PrePassLoop
                JP   .ChainDraw

.PrePassCull:   POP  HL                               ; cache ptr → как gap
                JP   .PrePassMark

.PrePassMark:   ; gap / off-track: cell (+1) = 0xFF (per-ball loop тест на gap по cell).
                LD   (HL), 0                          ; +0 tangent (ignored для gap)
                INC  HL
                LD   (HL), #FF                        ; +1 cell = gap marker
                LD   BC, 6
                ADD  HL, BC
                LD   (ZL_CacheWPtr), HL
                POP  BC
                INC  C
                DEC  B
                JP   NZ, .PrePassLoop

                ; ============================================================
                ; Per-ball matrix loop (2026-05-18, замена bucket-loop'а).
                ; Для каждого шара: emit cmd_loadid + translate(HALF) + rotate(tang)
                ; + translate(-HALF) + setmatrix + handle select + cell + vertex2f.
                ; Стоимость ~52 байта RAM_CMD/шар × 85 = ~4.4KB/кадр (FIFO).
                ; Dual handle: cell<128 → handle 0; cell>=128 → handle 9 (colors 4-5).
                ; ============================================================
.ChainDraw:     LD   A, (ZL_BallCount)
                OR   A
                JP   Z, .ChainEnd
                ; Init sentinels: tangent (0x01 — never matches mod-8) и handle (#FF — force first emit).
                LD   A, #01
                LD   (ZL_TmpLastTangent), A
                LD   A, #FF
                LD   (ZL_TmpLastHandle), A              ; lazy BITMAP_HANDLE switch
                LD   A, (ZL_BallCount)
                LD   B, A
                LD   C, 0
                LD   IX, ZL_BALL_CACHE_ADDR
.PerBallLoop:   LD   A, C
                LD   (ZL_TmpSlotIdx), A
                ; Предохранитель ступень 2 (жёсткий): у самого края буфера скипаем
                ; шар целиком — гарантия, что хвост кадра (~1100б) не затронет Core.
                LD   A, (FT.Coprocessor.BufferPtr + 1)
                CP   #5B                              ; BufferPtr ≥ #5B00 → skip ball
                JP   NC, .PBSkip
                LD   A, (IX+1)                        ; cell (+1) — 0xFF = gap marker
                CP   #FF
                JP   Z, .PBSkip                       ; (JR out of range — body grew)
                LD   A, (ZL_ChainDrawPass)
                OR   A
                JR   Z, .PBPassOk
                CP   1
                JR   Z, .PBPassUnder
                CP   3
                JR   Z, .PBPassSkipTunnel
                LD   A, (IX+6)
                AND  ZL_TRACKF_TUNNEL
                JP   NZ, .PBSkip                      ; pass 2: tunnel balls stay under the top mask
                LD   A, (IX+6)
                AND  ZL_TRACKF_DRAW_ABOVE
                JP   Z, .PBSkip                       ; pass 2: only priority/above balls
                JR   .PBPassOk
.PBPassSkipTunnel:
                LD   A, (IX+6)
                AND  ZL_TRACKF_TUNNEL
                JP   NZ, .PBSkip                      ; pause/dialog: вместо top-cover просто не рисуем tunnel balls
                JR   .PBPassOk
.PBPassUnder:   LD   A, (IX+6)
                AND  ZL_TRACKF_TUNNEL
                JR   NZ, .PBPassOk                    ; tunnel wins over drawAbove
                LD   A, (IX+6)
                AND  ZL_TRACKF_DRAW_ABOVE
                JP   NZ, .PBSkip                      ; pass 1: only under/top-covered balls
.PBPassOk:
                PUSH BC
                LD   A, (ZL_BallRotationDisabled)
                OR   A
                JR   NZ, .PBNoMatrix
                ; ПОЛНАЯ анимация (spin+rotation) на ВСЕХ уровнях, включая тоннельные
                ; (worst dual+tunnel ungated = 2872б из 3920б — test_cmd_buffer_budget_z80).
                ; Предохранитель ступень 1: буфер #4CB0..#5C00, дальше Core-код. Если
                ; экстремальный кадр подходит к краю — оставшиеся шары без матриц
                ; (теряют наклон), Core не затирается, звук не портится.
                LD   A, (FT.Coprocessor.BufferPtr + 1)
                CP   #58                              ; BufferPtr ≥ #5800 → запас 1024б на хвост кадра
                JP   NC, .PBNoMatrix
.PBQuantByCount:
                ; --- Skip matrix emit если quantized tangent совпал с предыдущим
                ; emit'ом (соседи цепи часто в одном bucket'е). 16 BRAD canary quantization.
                LD   A, (IX+0)                        ; stable tangent
                LD   D, A
                LD   A, (ZL_BallCount)
                CP   70
                LD   A, D
                JR   C, .PBQuant16
                AND  #E0                              ; 8 buckets only at full chain
                JR   .PBQuantDone
.PBQuant16:     AND  #F0                              ; 16 buckets normally
.PBQuantDone:
                LD   HL, ZL_TmpLastTangent
                CP   (HL)
                JR   Z, .PBNoMatrix                   ; same bucket → reuse matrix
                LD   (HL), A                          ; save new emitted tangent
                ; --- Emit matrix via pre-baked LUT (bypass FT812 coproc) ---
                LD   A, (ZL_TmpLastTangent)
                CALL ZL_EmitBallMatrixFromBRAD
.PBNoMatrix:
                ; --- dual handle: cell<128 → handle 0; cell>=128 → handle 9 ---
                if BALLS_ARGB4_ENABLED
                XOR  A
                else
                LD   A, (IX+1)                        ; cell (= color*32 + spin)
                AND  #80
                LD   A, 0
                JR   Z, .PBHSet
                LD   A, 9
                endif
.PBHSet:        ; lazy: skip BITMAP_HANDLE emit если same как previous ball
                LD   HL, ZL_TmpLastHandle
                CP   (HL)
                JR   Z, .PBHandleSame
                LD   (HL), A
                CALL ZL_EmitBitmapHandle              ; clobbers BCDE
.PBHandleSame:
                LD   A, (IX+1)
                if !BALLS_ARGB4_ENABLED
                AND  #7F                              ; local cell within handle
                endif
                CALL FT.Coprocessor.Cell
                ; Match-3 visual phase: draw the normal ball with hardware fade-out.
                ; ColorA is persistent, so restore 255 immediately after this vertex.
                LD   A, (ZL_TmpSlotIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .PBCheckHeadAbsorb
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A   ; frame * 16
                LD   E, A
                LD   A, 255
                SUB  E
                LD   E, A
                CALL FT.Coprocessor.ColorA
                LD   C, (IX+2) : LD B, (IX+3)
                LD   E, (IX+4) : LD D, (IX+5)
                CALL FT.Coprocessor.Vertex2f
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                JR   .PBDrawDone
                ; ── HEAD ABSORB ALPHA WRAP ── (state=1 И slot 0)
.PBCheckHeadAbsorb:
                LD   A, (VDC_GameState)
                CP   1
                JR   NZ, .PBNormalDraw
                LD   A, (VDC_KzFrame)
                CP   11
                JR   NZ, .PBNormalDraw                ; rush-to-killzone: no fade until the head reaches the skull
                LD   A, (VDC_HeadAbsorbAlpha)
                CP   255
                JR   Z, .PBNormalDraw                 ; absorb not visually fading yet
                PUSH IX : POP HL
                LD   A, H
                CP   ZL_BALL_CACHE_ADDR >> 8
                JR   NZ, .PBNormalDraw
                LD   A, L
                CP   ZL_BALL_CACHE_ADDR & #FF
                JR   NZ, .PBNormalDraw
                LD   A, (VDC_HeadAbsorbAlpha)
                LD   E, A
                CALL FT.Coprocessor.ColorA
                LD   C, (IX+2) : LD B, (IX+3)
                LD   E, (IX+4) : LD D, (IX+5)
                CALL FT.Coprocessor.Vertex2f
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                JR   .PBDrawDone
.PBNormalDraw:  LD   C, (IX+2) : LD B, (IX+3)         ; BC = Vx
                LD   E, (IX+4) : LD D, (IX+5)         ; DE = Vy
                CALL FT.Coprocessor.Vertex2f
.PBDrawDone:    POP  BC
.PBSkip:        INC  C
                LD   DE, 7
                ADD  IX, DE                            ; next record
                DEC  B
                JP   NZ, .PerBallLoop
                LD   A, (ZL_ChainDrawPass)
                CP   1
                CALL NZ, ZL_DrawExplosions
.ChainEnd:
                RET

; [ZL_DrawActiveChainSimple удалён 2026-06-09: мёртвый код (ни одного вызова во
;  всём дереве), освобождает ~120 байт Main1 под 1024×768 scale-код.]

; ============================================================================
; WIN-анимация (точно по оригиналу): рисуем ПУЛ независимых частиц-взрывов,
; которые роняет бегущий по треку эмиттер (логика в VDC_UpdateWin/Core). Здесь —
; только отрисовка живых частиц: каждая в своей точке (X,Y), кадр = f2/2 (0..16).
; Спрайт оранжевый WINEXP, рисуем крупно (ZL_WINEXP_DRAW) — как scale 1.5 оригинала.
; ============================================================================
DrawWinStateVisual:
                LD   A, (VDC_WinOutroActive)
                OR   A
                RET  Z                                  ; аутро не запущено — ничего
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                CALL ZL_EmitScale16Matrix               ; 1024×768: взрыв ×1.6 (частицы уже в 1024 с трека)
                FT_BitmapHandle ZL_WINEXP_HANDLE
                FT_BitmapSource WINEXP_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, ZL_DESTROY_W * 2, ZL_DESTROY_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, ZL_WINEXP_DRAW, ZL_WINEXP_DRAW
                LD   IX, VDC_WinPrtcl
                LD   B, WIN_PRTCL_MAX
.dp_loop:       LD   A, (IX+4)
                CP   255
                JR   Z, .dp_next                        ; мёртвая
                PUSH BC
                SRL  A                                  ; cell = f2/2 (frame 0..16)
                CALL FT.Coprocessor.Cell
                LD   L, (IX+0) : LD H, (IX+1)           ; X (абс. экранный)
                LD   DE, ZL_WINEXP_DRAW / 2
                AND  A
                SBC  HL, DE
                LD   DE, ZL_WINEXP_XOFF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   L, (IX+2) : LD H, (IX+3)           ; Y
                LD   DE, ZL_WINEXP_DRAW / 2
                AND  A
                SBC  HL, DE
                LD   DE, ZL_WINEXP_YOFF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f
                POP  BC
.dp_next:       LD   DE, 5
                ADD  IX, DE
                DJNZ .dp_loop
                RET

; ----------------------------------------------------------------------------
; Frog/bullet layer. Must be above tunnel top-cover: the cover hides chain balls
; under bridges/tunnels, but the frog is a foreground gameplay sprite.
; ----------------------------------------------------------------------------
ZL_DrawFrogLayer:
                ; Frog composition. Pause dialog (3) may still have live balls on
                ; screen, so it keeps the old hide-after-dialog-load guard. Lose
                ; retry/gameover (1/2) and win done/fade (5/6) keep the frog
                ; visible: by then chains are empty, so dialog upload cannot tear
                ; against ball rendering.
                LD   A, (Core.VDC_DialogState)
                OR   A
                JR   Z, .draw_frog
                CP   3
                JR   Z, .draw_until_dialog_loaded
                JR   .draw_frog
.draw_until_dialog_loaded:
                LD   A, (DialogFrameLoaded)
                OR   A
                RET  NZ
.draw_frog:
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                FT_Begin FT_BITMAPS
                if ZL_FROG_DRAW_ENABLED
                XOR  A
                CALL FT.Coprocessor.Cell
                if ZL_FROG_DRAW_PLATE
                CALL Frog_DrawPlate
                endif
                if ZL_FROG_DRAW_BODY
                CALL Frog_DrawBody
                endif
                if ZL_FROG_DRAW_TONGUE
                CALL Frog_DrawTongue
                endif
                if ZL_FROG_DRAW_BALL_NOW
                CALL Frog_DrawBallNow                  ; held ball: в окне, на pos+ballExpand·dir
                endif
                if ZL_FROG_DRAW_NEXT_BALL
                CALL Frog_DrawNextBall                 ; на спине, pos-offset·dir
                endif
                if ZL_FROG_DRAW_OVERLAY
                CALL Frog_DrawFaceOverlay              ; face overlay поверх (как в HD-оригинале)
                endif
                endif

                CALL Bullet_Draw                       ; flying ball, if active
                RET

ZL_AfterChains:
                CALL ZL_DrawFrogLayer                 ; frog/bullet are above tunnel top-cover

                LD   A, (VDC_GameState)
                CP   VDC_STATE_WIN
                CALL Z, DrawWinStateVisual

                ; --- Reset BITMAP_TRANSFORM к identity для cursor + следующих кадров ---
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; --- Frame strips PALETTED4444 (рисуем ПОВЕРХ playfield, ПОД курсором) ---
                CALL DrawFrameStrips

                ; --- HUD: lives counter (N жаб-иконок в green sock'е top bar) ---
                CALL DrawLivesCounter
                CALL DrawHudTopText
                CALL DrawHudProgress
                CALL DrawHudMenu
                if ZL_PROFILER_ENABLED
                CALL ZL_DrawProfiler
                endif

                ; --- Retry dialog (показывается когда VDC_DialogState != 0) ---
                ; 1024×768: рамка/глифы/OK диалога рисуются при scale(1.6)-матрице,
                ; позиции в EQU уже экранные ×1.6.
                CALL ZL_EmitScale16Matrix
                CALL DrawRetryDialog

                ; ============================================================
                ; Cursor — деревянная стрелка 48×48 ARGB4 (handle 7).
                ; Острие sprite в (CURSOR_TIP_X, CURSOR_TIP_Y) — рисуем sprite
                ; со смещением, чтобы острие попадало точно в (SmoothX, SmoothY) =
                ; точка срабатывания (= куда летит шар при выстреле).
                ; ============================================================
                LD   C, 255 : LD D, 255 : LD E, 255   ; tint = white (без модуляции)
                CALL FT.Coprocessor.ColorRGB
                ; 1024×768: своя scale(1.6)-матрица (без неё курсор наследует scaled
                ; матрицу шаров/frog → битый). Острие в (0,0) → scale-about-origin держит его.
                CALL ZL_EmitScale16Matrix
                FT_BitmapHandle 7
                FT_BitmapSource CURSOR_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, CURSOR_W * 2, CURSOR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, CURSOR_DRAW, CURSOR_DRAW
                XOR  A                                ; Cell(0) — chain оставил Cell ≠ 0
                CALL FT.Coprocessor.Cell
                ; Cursor рисуем по SMOOTHED мыши (как и Frog_Angle aim).
                ; 2026-05-16: переключено с raw на smoothed чтобы устранить
                ; wrong-target glitch — раньше курсор показывал raw position
                ; (instant), а bullet летел в направлении smoothed (alpha=1/8
                ; lag ~7 frames). Юзер видел курсор в новой точке, bullet
                ; летел в старую = "не туда". Теперь курсор и aim sync.
                ; Vertex2f((SmoothX - CURSOR_TIP_X)*16, (SmoothY - CURSOR_TIP_Y)*16)
                LD   HL, (ZL_SmoothX)
                LD   DE, CURSOR_TIP_X
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   HL, (ZL_SmoothY)
                LD   DE, CURSOR_TIP_Y
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f
                ; БЕЗ reset: курсор — последний спрайт кадра, scale(1.6)-матрица
                ; сознательно остаётся для DrawDebugClock (ROM-шрифт часов ×1.6).
                ; Следующий кадр начинает bg со своей матрицей.

                ; GAME OVER text теперь рисуется ВНУТРИ retry-dialog (DrawRetryDialog),
                ; старый top-center nativealien48 banner подавлен — dialog покрывает экран.
                LD   A, (VDC_GameState)
                CP   VDC_STATE_INTRO
                CALL Z, DrawIntroText
                LD   A, (VDC_GameState)
                CP   VDC_STATE_PREVIEW
                CALL Z, DrawPreviewSparklesAll

                ; --- LEVEL DONE fade-out overlay (поверх всего). При FadeAlpha=0
                ; (обычный геймплей) DrawFadeOverlay сразу RET — безвредно. ---
                CALL DrawFadeOverlay

                ; ============================================================
                ; SPI/GPU load indicator (temporary):
                ;   bar в (0,0), длина = ZL_SpiCounter >> 5 px.
                ;   Длинный = FT812 ещё рендерит когда Z80 готов = FT812 загружен.
                ;   Короткий = FT812 быстро отрендерил, есть headroom.
                ; ============================================================
                RET

; ----------------------------------------------------------------------------
; ZL_EmitLoadId — append cmd_loadidentity (4 байт opcode) в CMD буфер.
; ----------------------------------------------------------------------------
; (ZL_StableBallBucket удалён 2026-05-18 — per-ball loop не использует buckets.)

; ZL_EmitBitmapHandle: emit DL command BITMAP_HANDLE(A) runtime.
;   In:  A = handle (0..31). Out: nothing. Clobbers AF, BC, DE, HL.
ZL_EmitBitmapHandle:
                AND  #1F
                LD   E, A
                LD   D, 0
                LD   BC, #0500
                JP   FT.Coprocessor.Command_BCDE

; ZL_EmitBallHandle: setup ball atlas — emit BITMAP_HANDLE + BITMAP_SOURCE.
;   In:  A = 0 (handle 0, cells 0..127) или 9 (handle 9, cells 128..191).
;   Clobbers AF, BC, DE, HL.
ZL_EmitBallHandle:
                PUSH AF
                CALL ZL_EmitBitmapHandle
                POP  AF
                OR   A
                JR   Z, .ebh_src0
                LD   DE, (BALLS_RAMG_ADDR + BALLS_HANDLE9_OFFSET) & #FFFF
                LD   BC, (((BALLS_RAMG_ADDR + BALLS_HANDLE9_OFFSET) >> 16) & #FF) | (#01 << 8)
                JP   FT.Coprocessor.Command_BCDE
.ebh_src0:      LD   DE, BALLS_RAMG_ADDR & #FFFF
                LD   BC, ((BALLS_RAMG_ADDR >> 16) & #FF) | (#01 << 8)
                JP   FT.Coprocessor.Command_BCDE

; ZL_EmitBallColorRGB: emit COLOR_RGB(table[A]) для tinting L8 ball.
;   In: A = color index (0..5). Out: nothing. Clobbers AF, BC, DE, HL.
ZL_EmitBallColorRGB:
                AND  #07                              ; clamp 0..7
                LD   E, A
                ADD  A, A                             ; *2
                ADD  A, E                             ; *3
                LD   E, A : LD D, 0
                LD   HL, ZL_BallColorRGB
                ADD  HL, DE                            ; HL → entry
                LD   C, (HL) : INC HL                 ; R
                LD   D, (HL) : INC HL                 ; G — wait, ColorRGB ждёт C=R, D=G, E=B.
                LD   E, (HL)                          ; B
                ; FT.Coprocessor.ColorRGB: in C=R, D=G, E=B → emits COLOR_RGB
                JP   FT.Coprocessor.ColorRGB

ZL_BallColorRGB:
                ; 6 цветов: classic Zuma. Tint значения >255 насыщения учитывают
                ; что silver source имеет L_max ~230 (output = tint × L / 255).
                DEFB 130, 200, 255           ; 0 BLUE  (light sky blue)
                DEFB 60, 255, 80             ; 1 GREEN (vivid)
                DEFB 255, 70, 60             ; 2 RED
                DEFB 255, 230, 30            ; 3 YELLOW
                DEFB 255, 90, 240            ; 4 PURPLE/PINK
                DEFB 255, 255, 255           ; 5 WHITE

; ZL_DrawExplosions — separate pass for match-3 destroy sprites.
; Uses cached chain positions; draws 64x64 frames centered on the fading ball.
; ZL_EmitScale16Matrix — точная scale(1.6)-матрица ЗАПЕЧЁННЫМИ DL-словами
; BITMAP_TRANSFORM (A=E=160/256 = ровно 1/1.6). НЕ через CMD_SCALE: его
; инверсия в копроцессоре усечённая (A=159/256 = факт. ×1.6101) — весь контент
; дрейфовал до +6px у правого края (hover-кнопка MENU не совпадала с
; запечённой в рамке). Канон как у boot (BootEmitScale16Transforms).
; Scale-about-origin для axis-aligned спрайтов: курсор/destroy/win-взрыв/рамки.
ZL_EmitScale16Matrix:
                LD   HL, .blk
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 24
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                RET
.blk:           DEFD #150000A0                        ; BITMAP_TRANSFORM_A = 160/256
                DEFD #16000000                        ; B = 0
                DEFD #17000000                        ; C = 0
                DEFD #18000000                        ; D = 0
                DEFD #190000A0                        ; BITMAP_TRANSFORM_E = 160/256
                DEFD #1A000000                        ; F = 0

ZL_DrawExplosions:
                CALL ZL_EmitScale16Matrix             ; 1024×768: destroy 48→77
                FT_BitmapHandle ZL_DESTROY_HANDLE
                FT_BitmapSource DESTROY_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, ZL_DESTROY_W * 2, ZL_DESTROY_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, ZL_DESTROY_DRAW, ZL_DESTROY_DRAW
                LD   A, (ZL_BallCount)
                OR   A
                RET  Z
                LD   B, A
                LD   IX, ZL_BALL_CACHE_ADDR
                LD   HL, (VDC_pExplodeFrame)
.de_loop:       LD   A, (HL)
                OR   A
                JR   Z, .de_next
                PUSH BC
                PUSH HL
                DEC  A
                SRL  A
                CP   ZL_DESTROY_FRAMES
                JR   C, .de_cell_ok
                LD   A, ZL_DESTROY_FRAMES - 1
.de_cell_ok:    CALL FT.Coprocessor.Cell
                LD   A, (IX+1)
                if BALLS_ARGB4_ENABLED
                RRCA : RRCA : RRCA : RRCA
                AND  #0F                              ; ARGB4 atlas: cell = color*16 + spin
                else
                AND  #E0
                RRCA : RRCA : RRCA : RRCA : RRCA
                endif
                CALL ZL_ExplosionColorRGB
                LD   L, (IX+2) : LD H, (IX+3)
                LD   DE, ZL_DESTROY_HALF_DELTA
                AND  A
                SBC  HL, DE
                LD   B, H : LD C, L
                LD   L, (IX+4) : LD H, (IX+5)
                LD   DE, ZL_DESTROY_HALF_DELTA
                AND  A
                SBC  HL, DE
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f
                POP  HL
                POP  BC
.de_next:       LD   DE, 7
                ADD  IX, DE
                INC  HL
                DJNZ .de_loop
                RET

ZL_ExplosionColorRGB:
                LD   E, A
                ADD  A, A
                ADD  A, E                              ; A = color * 3
                LD   E, A
                LD   D, 0
                LD   HL, ZL_ExplosionRGBTable
                ADD  HL, DE
                LD   C, (HL)                           ; R
                INC  HL
                LD   D, (HL)                           ; G
                INC  HL
                LD   E, (HL)                           ; B
                JP   FT.Coprocessor.ColorRGB

ZL_ExplosionRGBTable:
                DEFB 48,120,255, 64,255,80, 255,72,48
                DEFB 255,220,0, 210,80,255, 255,255,255

; [ZL_EmitLoadId -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
; [ZL_EmitTranslate -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
ZL_EmitRotate:  ADD  A, 192                          ; offset native face direction
                LD   D, A : LD E, 0
                LD   (ZL_TmpAngle), DE
                LD   DE, FT_CMD_ROTATE & #FFFF
                LD   BC, FT_CMD_ROTATE >> 16
                CALL FT.Coprocessor.Command_BCDE
                LD   BC, 0
                LD   DE, (ZL_TmpAngle)
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitSetMatrix — append cmd_setmatrix (4 байт opcode).
; Применяет текущую coprocessor матрицу как BITMAP_TRANSFORM_A..F (6 DL cmds).
; ----------------------------------------------------------------------------
; [ZL_EmitSetMatrix -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
ZL_KBD_STEP     EQU 4                                 ; BRAD/frame, ≈1.4°/frame ≈ 80°/sec @57Hz
ZL_MOTION_THR   EQU 1                                 ; px threshold для motion detection

ZL_AimUpdate:
                ; Управление лягушкой через ГЛОБАЛЬНЫЙ Input.asm (PS/2-стрелки ←/→ +
                ; Kempston). Матрицу #FE больше НЕ читаем напрямую → переключать FM_EN
                ; не нужно (держим его ON для пейджинга через FMADDR_REGS). Это убирает
                ; прежний хрупкий хак «выключить FM_EN на время чтения клавиатуры».
                ; --- Вращение: Влево = ←/Kempston-Left, Вправо = →/Kempston-Right ---
                CALL Input_Left
                JR   Z, .check_right
                LD   A, (Frog_Angle)
                SUB  ZL_KBD_STEP                      ; 8-бит, по кругу
                LD   (Frog_Angle), A
.check_right:   CALL Input_Right
                JR   Z, .check_fire
                LD   A, (Frog_Angle)
                ADD  A, ZL_KBD_STEP
                LD   (Frog_Angle), A

.check_fire:    ; Огонь = Space | Enter | Kempston (ЛКМ — отдельно в Frog.asm).
                CALL Input_FireKey
                JR   NZ, .fire_pressed
                XOR  A
                LD   (Frog_KeySpacePrev), A
                JR   .check_motion
.fire_pressed:  CALL Frog_FireKeyboard                ; внутри debounce KeySpacePrev

                ; --- 2. Detect mouse motion (|raw - prev| ≥ ZL_MOTION_THR) ---
.check_motion:  XOR  A
                LD   (ZL_MouseMoved), A               ; default = 0
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, (ZL_PrevRawX)
                AND  A
                SBC  HL, DE                           ; HL = raw_X - prev_X (signed)
                CALL ZL_AbsHL
                LD   DE, ZL_MOTION_THR
                AND  A
                SBC  HL, DE
                JR   NC, .motion                      ; |dx| ≥ threshold
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, (ZL_PrevRawY)
                AND  A
                SBC  HL, DE
                CALL ZL_AbsHL
                LD   DE, ZL_MOTION_THR
                AND  A
                SBC  HL, DE
                JR   C, ZL_FmEnRestore                ; |dy| < threshold → no motion

.motion:        ; Mouse moved → set flag + reset grace counter + save prev_raw.
                LD   A, 1
                LD   (ZL_MouseMoved), A
                LD   A, 8                             ; grace: после motion stop ещё 8 кадров обновлять angle (Smooth догоняет raw)
                LD   (ZL_MotionGrace), A
                LD   HL, (Input.Mouse.PositionX)
                LD   (ZL_PrevRawX), HL
                LD   HL, (Input.Mouse.PositionY)
                LD   (ZL_PrevRawY), HL
                JR   ZL_FmEnRestore

; Общий выход ZL_AimUpdate. FM_EN больше не трогаем (всегда ON) — метка оставлена,
; т.к. на неё прыгают ветки motion-детекции.
ZL_FmEnRestore: RET

; ----------------------------------------------------------------------------
; ZL_Mul16x8 — unsigned 16x8 multiply, low 16 bits of result.
;   In:  HL = multiplicand (unsigned 16-bit), A = multiplier (unsigned 8-bit)
;   Out: HL = (HL_in * A_in) & #FFFF
;   Scratch: BC, A, F. ~14 байт, ~155 t-states avg.
;   Используется для runtime K в spin formula (по 1 вызову на шар цепи).
; ----------------------------------------------------------------------------
ZL_Mul16x8:     LD   C, L : LD B, H                   ; BC = multiplicand
                LD   HL, 0                             ; HL = accumulator
                LD   D, 8                             ; bit counter
.lp:            ADD  HL, HL                            ; HL <<= 1
                ADD  A, A                             ; CF = top bit of multiplier
                JR   NC, .skip
                ADD  HL, BC                            ; if bit set → +BC
.skip:          DEC  D
                JR   NZ, .lp
                RET

; ----------------------------------------------------------------------------
; ZL_SpinPhase — A = ((t * ZL_SPIN_K_DEFAULT) >> 8) & ZL_SPIN_MASK.
;   In: HL = VDC_LastT. Out: A = spin phase. Scratch: BC, DE, HL, AF.
;   Current ARGB4 build has K=81, so avoid the 8-iteration generic multiply in
;   the per-ball render hot path. If compile-time K changes, fall back safely.
; ----------------------------------------------------------------------------
ZL_SpinPhase:
                if ZL_SPIN_K_DEFAULT = 81
                LD   D, H : LD E, L                    ; DE = t
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL                            ; HL = t * 16
                LD   B, H : LD C, L                    ; BC = t * 16
                ADD  HL, HL
                ADD  HL, HL                            ; HL = t * 64
                ADD  HL, BC                            ; HL = t * 80
                ADD  HL, DE                            ; HL = t * 81
                LD   A, H
                AND  ZL_SPIN_MASK
                RET
                else
                LD   A, (ZL_SpinK)
                CALL ZL_Mul16x8
                LD   A, H
                AND  ZL_SPIN_MASK
                RET
                endif

; [ZL_FT_CMD_Write_DMA перенесён в shared_render.asm (Main0-резидент) 2026-06-11:
;  теперь его зовут И MainLoop (#04), И меню/level-select (#41) — единый быстрый
;  DMA-путь отправки кадра вместо медленного OTIR в сценах меню.]

; ----------------------------------------------------------------------------
; ZL_AbsHL — HL = |HL| (16-bit signed → unsigned magnitude).
; ----------------------------------------------------------------------------
ZL_AbsHL:       BIT  7, H
                RET  Z
                LD   A, H : CPL : LD H, A
                LD   A, L : CPL : LD L, A
                INC  HL
                RET


; ----------------------------------------------------------------------------
; ZL_SmoothMouse — exponential low-pass filter (alpha = 1/4, восстановлено
; 2026-05-17 после жалобы на «желейный» прицел):
;   new = old + (raw - old) / 4 = old*3/4 + raw/4
; Latency ~3-4 кадра (~70 ms @57Hz). 1-px jitter Hyper-V подавляется т.к.
; ±1/4 в integer = 0 → Smooth не дрожит при идле raw=±1 px.
; ----------------------------------------------------------------------------
ZL_SmoothMouse: ; --- X axis ---
                LD   HL, (ZL_SmoothX)                 ; HL = old
                LD   D, H : LD E, L                   ; DE = old
                LD   BC, (Input.Mouse.PositionX)
                AND  A
                SBC  HL, BC                           ; HL = old - raw (signed)
                SRA  H : RR L
                SRA  H : RR L                         ; HL = (old-raw)/4 signed
                EX   DE, HL                           ; HL = old, DE = (old-raw)/4
                AND  A
                SBC  HL, DE                           ; HL = old - (old-raw)/4 = new
                LD   (ZL_SmoothX), HL

                ; --- Y axis ---
                LD   HL, (ZL_SmoothY)
                LD   D, H : LD E, L
                LD   BC, (Input.Mouse.PositionY)
                AND  A
                SBC  HL, BC
                SRA  H : RR L
                SRA  H : RR L
                EX   DE, HL
                AND  A
                SBC  HL, DE
                LD   (ZL_SmoothY), HL
                RET

; ----------------------------------------------------------------------------
; Game state в коде (data section). DEFW = 2 байта LE.
; При SAVEBIN эти ячейки попадают в .bin — на старте у них валидные значения,
; MainLoop их сразу переписывает (см. начало MainLoop).
; ----------------------------------------------------------------------------
ZL_FrameCounter:DEFW 0
; [ZL_SmoothX -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
; [ZL_SmoothY -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
ZL_PrevRawX:    DEFW 512                              ; raw mouse prev — для motion detection (центр 1024×768)
ZL_PrevRawY:    DEFW 384
ZL_MouseMoved:  DEFB 0                                ; 0=stationary, 1=moved (≥THR per axis)
ZL_MotionGrace: DEFB 0                                ; frames left для catch-up Smooth после mouse motion
ZL_ChainHSA:    DEFW 0                                ; head sample на треке
ZL_ChainTick:   DEFB 0                                ; subdivider 4 для медленного движения
ZL_ColorIdx:    DEFB 0                                ; текущий cell для CELL()-эмита в цепи
ZL_TmpFrame:    DEFB 0                                ; cell/spin frame scratch (chain rendering)
ZL_TmpSlotIdx:  DEFB 0                                ; current VDC slot index for bucket hysteresis
ZL_TmpTrackFlags: DEFB 0                              ; track flags captured from VDC_LastTrackFlags
ZL_ChainDrawPass: DEFB 0                              ; 0=all, 1=under top layer, 2=above top layer
ZL_TopMaskUploadedLevel: DEFB #FF                     ; current level whose tunnel top masks are in RAM_G
ZL_TopMaskCount: DEFB 0
ZL_TopMaskTablePtr: DEFW 0
ZL_TopMaskSrcPage: DEFB 0
ZL_TopMaskSrcLo: DEFW 0
ZL_TopMaskRamLo: DEFW 0
ZL_TopMaskRamHi: DEFB 0
ZL_DialogFrameUploadDeferred: DEFB 0
; [ZL_TmpTx -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
; [ZL_TmpTy -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
; [ZL_TmpAngle -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
ZL_TmpBallX:    DEFW 0                                ; chain render: текущий шар X (px)
ZL_TmpBallY:    DEFW 0                                ; chain render: текущий шар Y (px)
ZL_TmpAngleByte:DEFB 0                                ; chain render: combined rotation byte
ZL_SpinK:       DEFB ZL_SPIN_K_DEFAULT                ; runtime spin multiplier (per-level)
; [ZL_CmdDmaWordsHi/Lo переехали в shared_render.asm вместе с DMA-функцией]
ZL_CmdBytes:    DEFW 0                                ; last FT812 RAM_CMD byte count before write
ZL_CmdOverflow: DEFB 0                                ; sticky: 1 if command stream crossed warn threshold
ZL_BallCount:   DEFB 0                                ; cached VDC_SlotsLen для bucket prepass
ZL_TmpBucket:   DEFB 0                                ; current bucket в outer loop (legacy)
ZL_TmpLastTangent: DEFB 0                             ; per-ball loop: last emitted quantized tangent
ZL_TmpLastHandle:  DEFB 0xFF                          ; lazy BITMAP_HANDLE — last emitted ball handle (0/9, #FF=reset)
ZL_BallRotationDisabled: DEFB 0                       ; pause/dialog guard: skip per-ball matrix state
ZL_HeavyTunnelDual: DEFB 0                            ; heavy level: second chain or current level has top mask
ZL_HasTopMaskLevel: DEFB 0                            ; current level has tunnel top-mask: disable ball anim/rotation
ZL_HeavyBallCount: DEFB 0                             ; dual heavy levels use chain1+chain2 count for threshold
ZL_CacheWPtr:   DEFW 0                                ; write ptr в prepass
; (WIN-частицы хранятся резидентно в VDC_WinPrtcl; рабочих ZL-переменных нет.)
ZL_ProfileLoopStartLo: DEFW 0
ZL_ProfileLoopStartHi: DEFW 0
ZL_ProfilePostBuildLo: DEFW 0
ZL_ProfilePostBuildHi: DEFW 0
ZL_ProfilePreWriteLo:  DEFW 0
ZL_ProfilePreWriteHi:  DEFW 0
ZL_ProfileBuildK:      DEFW 0                         ; FT812 REG_CLOCK ticks / 1024
ZL_ProfileIdleK:       DEFW 0
ZL_ProfileWriteK:      DEFW 0
ZL_ProfileDeltaEndLo:  DEFW 0
ZL_ProfileDeltaEndHi:  DEFW 0
                ; Per-ball cache: tangent, cell, Vx_lo, Vx_hi, Vy_lo, Vy_hi, flags = 7 bytes.
                ; bucket = #FF → skip (gap/off-track).
                ; Размещён в свободной зоне slot 1 ниже Core (page 5 #4000-#5FFF),
                ; чтобы 1440 байт cache не раздували Core за границу 8 КБ (#7FFF).
ZL_BALL_CACHE_ADDR EQU #4100                          ; (max 128 × 7 = 896 = #380; до #4480, дальше GAMELOG)

; Circular RAM log EQU (GAMELOG_ADDR, EVT_*) определены в main.asm перед
; TSLib block — чтобы быть видимыми и из slot 0 (Log routines) и из slot 1
; (Core hooks). См. main.asm. RAM zone #4800..#5007 в slot 1 page 5.

; ----------------------------------------------------------------------------
; ZL_ChainMatrixLUT — pre-baked rotation matrices для 32 buckets (8 BRAD step).
; Каждый bucket = 24 байта = 6 BITMAP_TRANSFORM_A..F opcodes. Sgnerированы
; make_chain_matrix_lut.py (Q8.8 cos/sin, Q23.8 translation centered at +16/-16).
; Bypass FT812 coprocessor — LDIR прямо в CMD буфер.
; ----------------------------------------------------------------------------
ZL_ChainMatrixLUT:
                INCBIN "Graphics/Converted/chain_matrix_lut.bin"
ZL_ChainMatrixLUT_END:
ZL_CHAIN_MATRIX_LUT_STRIDE EQU 24

; ----------------------------------------------------------------------------
; ZL_EmitBallMatrixFromBRAD — LDIR matrix block в CMD буфер.
;   In: A = BRAD (0..255), любые битья. Внутри квантуется к 8 BRAD (32 buckets).
;   Out: matrix эмитнут в FT BufferPtr.
;   Clobbers: AF, BC, DE, HL.
; Reusable между chain rendering и FrogBallNow / прочими 32×32 sprites.
; ----------------------------------------------------------------------------
ZL_EmitBallMatrixFromBRAD:
                AND  #F0                                ; quantize to 16 BRAD (uses even entries in 8-BRAD LUT)
                SRL  A : SRL A : SRL A                  ; A = bucket (0..31)
                LD   E, A : LD D, 0
                LD   HL, 0
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; ×8
                LD   B, H : LD C, L
                ADD  HL, HL                             ; ×16
                ADD  HL, BC                             ; ×24
                LD   DE, ZL_ChainMatrixLUT
                ADD  HL, DE
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, ZL_CHAIN_MATRIX_LUT_STRIDE
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                RET

; ----------------------------------------------------------------------------
; FT812 frame profiler (diagnostic overlay).
; B/W/I are REG_CLOCK delta / 1024. At 60 MHz FT812 clock:
;   74 Hz frame ~= 792, 57 Hz frame ~= 1028.
; If B+W approaches frame budget and I is near zero, Z80/SPI path misses vblank.
; ----------------------------------------------------------------------------
ZL_ProfileReadClock:
                FT_RD_REG32 FT_REG_CLOCK                ; BCDE = 32-bit little-endian value
                LD   H, B
                LD   L, C
                RET                                     ; HLDE = clock

; In: HLDE=end clock, IXBC=start clock. Out: HL=(delta >> 10), DE=end lo, IX=end hi.
ZL_ProfileDeltaK:
                LD   (ZL_ProfileDeltaEndLo), DE
                LD   (ZL_ProfileDeltaEndHi), HL
                EX   DE, HL                             ; HL=end low, DE=end high
                AND  A
                SBC  HL, BC                             ; HL=delta low
                EX   DE, HL                             ; DE=delta low, HL=end high
                PUSH IX
                POP  BC                                 ; BC=start high
                SBC  HL, BC                             ; HL=delta high
                ; Convert 32-bit delta HL:DE to 16-bit delta/1024.
                ; result bits: low=(D>>2)|(L<<6), high=(L>>2)|((H&3)<<6)
                LD   A, D
                SRL  A
                SRL  A
                LD   C, A
                LD   A, L
                ADD  A, A
                ADD  A, A
                ADD  A, A
                ADD  A, A
                ADD  A, A
                ADD  A, A
                OR   C
                LD   E, A                               ; result low byte temp
                LD   A, L
                SRL  A
                SRL  A
                LD   B, A
                LD   A, H
                AND  3
                RRCA
                RRCA
                OR   B
                LD   D, A                               ; result high byte temp
                EX   DE, HL                             ; HL=result
                LD   DE, (ZL_ProfileDeltaEndLo)
                LD   IX, (ZL_ProfileDeltaEndHi)
                RET

ZL_DrawProfiler:
                CALL SetFontCancun8
                LD   C, 255 : LD D, 242 : LD E, 168
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_BITMAPS

                LD   HL, str_prof_b
                LD   BC, 26 * 16
                LD   DE, 454 * 16
                CALL DrawString
                LD   HL, (ZL_ProfileBuildK)
                CALL DrawWordValue

                LD   HL, str_prof_w
                LD   BC, 126 * 16
                LD   DE, 454 * 16
                CALL DrawString
                LD   HL, (ZL_ProfileWriteK)
                CALL DrawWordValue

                LD   HL, str_prof_i
                LD   BC, 226 * 16
                LD   DE, 454 * 16
                CALL DrawString
                LD   HL, (ZL_ProfileIdleK)
                CALL DrawWordValue

                LD   HL, str_prof_c
                LD   BC, 326 * 16
                LD   DE, 454 * 16
                CALL DrawString
                LD   HL, (ZL_CmdBytes)
                CALL DrawWordValue

                LD   C, 255 : LD D, 255 : LD E, 255
                JP   FT.Coprocessor.ColorRGB

str_prof_b:    DEFB "B", 0
str_prof_w:    DEFB "W", 0
str_prof_i:    DEFB "I", 0
str_prof_c:    DEFB "C", 0

                endif ; ~_ZUMA_MAIN_LOOP_
