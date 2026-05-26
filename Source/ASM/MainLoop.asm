
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
ZL_SCR_W        EQU 640
ZL_SCR_H        EQU 480
ZL_SUB          EQU 16                                ; subpixel множитель
ZL_CMD_WARN_BYTES EQU #0E00                           ; warn before RAM_CMD FIFO pressure (4096 bytes)
ZL_PROFILER_ENABLED EQU 0                             ; 1=show FT812 timing overlay
ZL_FROG_DRAW_ENABLED EQU 1                            ; canary master: isolate frog tearing source
ZL_FROG_DRAW_PLATE   EQU 1                            ; no rotation
ZL_FROG_DRAW_BODY    EQU 1                            ; rotated main body
ZL_FROG_DRAW_TONGUE  EQU 1                            ; rotated tongue
ZL_FROG_DRAW_BALL_NOW  EQU 1                          ; ball on tongue / in mouth
ZL_FROG_DRAW_NEXT_BALL EQU 1                          ; next ball on frog back
ZL_FROG_DRAW_OVERLAY EQU 1                            ; rotated face overlay

; ----------------------------------------------------------------------------
; MainLoop — точка входа. Никогда не возвращается.
; ----------------------------------------------------------------------------
MainLoop:       ; --- Init game state (одноразово при первом входе) ---
                LD   HL, 0
                LD   (ZL_FrameCounter), HL
                ; Spin K — runtime (per-level калибровка). Default = level 1.
                LD   A, ZL_SPIN_K_DEFAULT
                LD   (ZL_SpinK), A

.Loop           ; --- 1. Update input + game state (Z80-only, параллельно с FT812 render) ---
                if ZL_PROFILER_ENABLED
                CALL ZL_ProfileReadClock
                LD   (ZL_ProfileLoopStartLo), DE
                LD   (ZL_ProfileLoopStartHi), HL
                endif
                CALL Input.Mouse.UpdateMouseState
                CALL ZL_AimUpdate
                CALL ZL_SmoothMouse
                CALL UpdateDialog                    ; mouse hit-test на retry-dialog кнопках
                CALL UpdateHudMenu                   ; top MENU button hover/press + input block
                CALL Frog_Update
                CALL VDC_Update
                CALL Bullet_Update
                CALL Bullet_CheckCollision

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
                FT_CMD_Write
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
ZL_BALL_DIAM_PX  EQU 32                               ; atlas cell size (BitmapLayout/Size)
ZL_BALL_VISIBLE  EQU ZL_BALL_DIAM_PX                  ; visible diameter = atlas cell (без alpha-padding)
ZL_BALL_W        EQU ZL_BALL_DIAM_PX                  ; native classic ball cell
ZL_BALL_H        EQU ZL_BALL_DIAM_PX
ZL_BALL_HALF     EQU ZL_BALL_DIAM_PX / 2              ; центр rect'а (= pivot для cmd_rotate)
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
ZL_DESTROY_HANDLE EQU 10
ZL_DESTROY_W      EQU 64
ZL_DESTROY_H      EQU 64
ZL_DESTROY_HALF_DELTA EQU ((ZL_DESTROY_W - ZL_BALL_W) / 2) * 16
ZL_BG_W         EQU 400                               ; native bg storage, upscaled to 640x480
ZL_BG_H         EQU 300
ZL_BG_DRAW_W    EQU 640
ZL_BG_DRAW_H    EQU 480
ZL_BG_SCALE     EQU #0001999A                         ; 1.6 in f16.16
ZL_BG_HANDLE    EQU 1

; Local DL command constants not covered by existing TSLib macros.
ZL_FT_L2        EQU FT_L4                              ; mask layout: 4bpp linear ramp 0..15→0..255
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
                ; HH @ (28, 438)
                LD   A, 4
                CALL ReadRTCRegister
                LD   C, A : LD B, 0
                LD   DE, 0
                FT_NumberDEBC 28, 438, 26, 2
                ; ':' @ (46, 438)
                FT_Text 46, 438, 26, 0
                FT_CMD_BUF #0000003A
                ; MM @ (52, 438)
                LD   A, 2
                CALL ReadRTCRegister
                LD   C, A : LD B, 0
                LD   DE, 0
                FT_NumberDEBC 52, 438, 26, 2
                ; ':' @ (70, 438)
                FT_Text 70, 438, 26, 0
                FT_CMD_BUF #0000003A
                ; SS @ (76, 438)
                XOR  A
                CALL ReadRTCRegister
                LD   C, A : LD B, 0
                LD   DE, 0
                FT_NumberDEBC 76, 438, 26, 2
                RET

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

                ; One bitmap primitive for the remaining bitmap layers.
                FT_Begin FT_BITMAPS

                ; ============================================================
                ; Killzone: hole (cell 0) → skull (cell VDC_KzFrame) на последнем
                ; track-sample. Перенесено в slot 0 helper (Core size).
                ; ============================================================
                CALL DrawKillzoneDual

                ; ============================================================
                ; Frog composition — SKIP при показанном dialog (states 1/2/3).
                ; Draw during PLAY (0) AND during pause fade-out (4): the frog
                ; appears from the first fade frame so it is ready when the
                ; window finishes fading and PLAY resumes.
                ; ============================================================
                LD   A, (Core.VDC_DialogState)
                OR   A
                JR   Z, .draw_frog
                CP   4
                JR   NZ, .skip_frog
.draw_frog:
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
                CALL Frog_DrawBallNow                  ; в рот, на pos+ballExpand·dir
                endif
                if ZL_FROG_DRAW_NEXT_BALL
                CALL Frog_DrawNextBall                 ; на спине, pos-28·dir
                endif
                if ZL_FROG_DRAW_OVERLAY
                CALL Frog_DrawFaceOverlay              ; face overlay поверх всего
                endif
                endif

                CALL Bullet_Draw                       ; flying ball, if active
.skip_frog:

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
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_W, ZL_BALL_H
                endif
                XOR  A
                CALL ZL_EmitBallHandle
                if BALLS_ARGB4_ENABLED
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                else
                FT_BitmapLayout FT_PALETTED4444, ZL_BALL_W, ZL_BALL_H
                endif
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_W, ZL_BALL_H

                ; --- VDC chain rendering: per-ball tangent + grouped matrix emit.
                ; Algorithm:
                ;   Pre-pass: cache stable tangent, cell, Vx, Vy for each ball.
                ;   Draw: quantize tangent to 8 BRAD and emit matrix only when it
                ;   differs from the previous visible ball. This keeps per-slot
                ;   tangent stability without the old bucket segment flicker.
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
                LD   HL, VDC_Slots
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
                ; --- spin ---
                PUSH HL                               ; save cache ptr
                LD   HL, (VDC_LastT)
                LD   A, (ZL_SpinK)
                CALL ZL_Mul16x8                       ; HL = t × K
                LD   A, H
                AND  ZL_SPIN_MASK                      ; spin 0..31
                LD   D, A
                LD   A, (ZL_TmpFrame)                 ; color
                if BALLS_ARGB4_ENABLED
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A               ; x16
                else
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A    ; x32
                endif
                ADD  A, D                             ; cell = color*32 + spin
                LD   (ZL_TmpFrame), A
                ; --- stable raw tangent (per-ball matrix замена bucket-loop 2026-05-18) ---
                ; Hysteresis: меняем сохранённый tangent только если raw отличается на
                ; ≥ THR (8 BRAD = bucket width). State address = #4100 + slot_idx (LOW=0 заведомо
                ; → используем `LD H, #41 : LD L, slot` без ADD HL, DE — это сохраняет D).
                LD   A, (VDC_LastTangent)
                LD   D, A                             ; D = raw tangent (preserved)
                LD   A, C                             ; A = slot index
                LD   H, ZL_BALL_TANGENT_STATE_ADDR >> 8
                LD   L, A                             ; HL = state[slot]
                LD   A, (HL)                          ; A = prev stable tangent
                LD   E, A                             ; E = prev
                LD   A, D                             ; A = raw
                SUB  E                                ; A = (raw - prev) mod 256 (signed wrap-aware)
                JP   P, .stab_pos
                NEG
.stab_pos:      CP   ZL_BALL_TANGENT_HYSTERESIS_THR
                JR   NC, .stab_update
                LD   A, E                             ; |delta| < THR → keep prev
                JR   .stab_done
.stab_update:   LD   A, D                             ; |delta| >= THR → update stable = raw
                LD   (HL), A
.stab_done:     POP  HL                               ; restore cache ptr
                LD   (HL), A : INC HL                 ; +0 stable tangent
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
                LD   (ZL_CacheWPtr), HL
                POP  BC
                INC  C
                DEC  B
                JP   NZ, .PrePassLoop
                JP   .ChainDraw

.PrePassMark:   ; gap / off-track: cell (+1) = 0xFF (per-ball loop тест на gap по cell).
                LD   (HL), 0                          ; +0 tangent (ignored для gap)
                INC  HL
                LD   (HL), #FF                        ; +1 cell = gap marker
                LD   BC, 5
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
                LD   A, (IX+1)                        ; cell (+1) — 0xFF = gap marker
                CP   #FF
                JP   Z, .PBSkip                       ; (JR out of range — body grew)
                PUSH BC
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
                LD   DE, VDC_ExplodeFrame
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
                LD   DE, 6
                ADD  IX, DE                            ; next record
                DEC  B
                JP   NZ, .PerBallLoop
                CALL ZL_DrawExplosions
.ChainEnd:
                ; --- Reset BITMAP_TRANSFORM к identity для cursor + следующих кадров ---
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix

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
                CALL DrawRetryDialog

                ; ============================================================
                ; Cursor — деревянная стрелка 48×48 ARGB4 (handle 7).
                ; Острие sprite в (CURSOR_TIP_X, CURSOR_TIP_Y) — рисуем sprite
                ; со смещением, чтобы острие попадало точно в (SmoothX, SmoothY) =
                ; точка срабатывания (= куда летит шар при выстреле).
                ; ============================================================
                LD   C, 255 : LD D, 255 : LD E, 255   ; tint = white (без модуляции)
                CALL FT.Coprocessor.ColorRGB
                FT_BitmapHandle 7
                FT_BitmapSource CURSOR_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, CURSOR_W * 2, CURSOR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, CURSOR_W, CURSOR_H
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

                ; GAME OVER text теперь рисуется ВНУТРИ retry-dialog (DrawRetryDialog),
                ; старый top-center nativealien48 banner подавлен — dialog покрывает экран.
                LD   A, (VDC_GameState)
                CP   VDC_STATE_INTRO
                CALL Z, DrawIntroText
                LD   A, (VDC_GameState)
                CP   VDC_STATE_PREVIEW
                CALL Z, DrawPreviewSparkles
                LD   A, (VDC_GameState)
                CP   VDC_STATE_WIN
                CALL Z, DrawPreviewSparkles

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
ZL_DrawExplosions:
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix
                FT_BitmapHandle ZL_DESTROY_HANDLE
                FT_BitmapSource DESTROY_RAMG_ADDR
                FT_BitmapLayout FT_ARGB4, ZL_DESTROY_W * 2, ZL_DESTROY_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, ZL_DESTROY_W, ZL_DESTROY_H
                LD   A, (ZL_BallCount)
                OR   A
                RET  Z
                LD   B, A
                LD   IX, ZL_BALL_CACHE_ADDR
                LD   HL, VDC_ExplodeFrame
.de_loop:       LD   A, (HL)
                OR   A
                JR   Z, .de_next
                PUSH BC
                PUSH HL
                DEC  A
                SRL  A
                CP   7
                JR   C, .de_cell_ok
                LD   A, 6
.de_cell_ok:    CALL FT.Coprocessor.Cell
                LD   A, (IX+1)
                AND  #E0
                RRCA : RRCA : RRCA : RRCA : RRCA
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
.de_next:       LD   DE, 6
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
                DEFB 48,120,255, 64,255,80, 210,80,255
                DEFB 255,72,48, 255,255,255, 255,220,0

ZL_EmitLoadId:  LD   DE, FT_CMD_LOADIDENTITY & #FFFF
                LD   BC, FT_CMD_LOADIDENTITY >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitTranslate — append cmd_translate(tx, ty) в CMD буфер.
;   In:  HL = tx_int_px (signed 16), DE = ty_int_px (signed 16)
;   Параметры передаются в FT812 как fixed-point 1/65536 px:
;   tx_subpx = tx_px * 65536 → low_word = 0, high_word = tx_px.
; ----------------------------------------------------------------------------
ZL_EmitTranslate:
                LD   (ZL_TmpTx), HL
                LD   (ZL_TmpTy), DE
                LD   DE, FT_CMD_TRANSLATE & #FFFF
                LD   BC, FT_CMD_TRANSLATE >> 16
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTx)
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTy)
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitRotate — append cmd_rotate(angle) в CMD буфер.
;   In:  A = tangent byte 0..255 (256 = full circle)
;   Native sprite face direction в spritesheet — DOWN (0° = низ экрана).
;   tangent байт = atan2(dy, dx): 0=right, 64=down, 128=left, 192=up.
;   Чтобы face шёл по track-направлению, поворачиваем на (tangent - 64),
;   то есть для tangent=64 (= down) поворот=0 (face остаётся внизу = вдоль
;   движения). Эквивалент `ADD A, 192` (= -64 mod 256).
; ----------------------------------------------------------------------------
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
ZL_EmitSetMatrix:
                LD   DE, FT_CMD_SETMATRIX & #FFFF
                LD   BC, FT_CMD_SETMATRIX >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_AimUpdate — detect mouse motion (с threshold для подавления Hyper-V Kempston
; jitter) + keyboard arrows меняют Frog_Angle напрямую.
;
; Архитектура (1:1 с VDC коллеги): Frog_Angle = primary state (8-bit BRAD wraps
; → 360° автоматом). Если мышь двинулась — set ZL_MouseMoved=1, иначе =0.
; Frog_Update вызывает ComputeFrogAngle ТОЛЬКО при ZL_MouseMoved=1 — иначе
; угол от клавиш сохраняется. Combine, не mode-toggle: клавиши применяются
; КАЖДЫЙ кадр (до atan2-проверки), мышь wins при движении.
;
; Threshold ZL_MOTION_THR = 1 px: отсекает только полный «zero motion» когда мышь
; физически не движется (защищает клавиатурный режим от ложных takeover при
; idle mouse). Sub-pixel Hyper-V jitter подавляется EMA-фильтром в ZL_SmoothMouse,
; не deadzone'ом — иначе медленный aim (1-2 px/frame) теряется.
; ----------------------------------------------------------------------------
ZL_KBD_STEP     EQU 4                                 ; BRAD/frame, ≈1.4°/frame ≈ 80°/sec @57Hz
ZL_MOTION_THR   EQU 1                                 ; px threshold для motion detection

ZL_AimUpdate:
                ; FM_EN постоянно ON в нашей сборке (нужен для page mapping
                ; через FMADDR_REGS). Это ломает port reads на #FE (TS-Conf
                ; перенаправляет некоторые keyboard rows на регистры). Временно
                ; выключаем FM_EN на время keyboard reads, потом включаем обратно.
                LD   BC, FMADDR
                XOR  A
                OUT  (C), A
                ; --- 1. Apply keyboard к Frog_Angle (LEFT = ←/O, RIGHT = →/P) ---
                ; Spectrum keyboard читаем напрямую port'ом #DFFE (row Y..P).
                ; bit 0 = P, bit 1 = O. Active LOW (pressed = bit clear).
                ; (TSLib Spectrum.KeyState ожидает INDEX в таблицу, а SVK_X
                ; константы = bit mask — не годится для прямого вызова.)
                LD   A, Input.VK_KEMPSTON_LEFT
                CALL Input.Kempston.KeyState
                JR   NZ, .do_left
                LD   BC, #DFFE
                IN   A, (C)
                BIT  1, A                             ; O (bit 1)
                JR   NZ, .check_right                 ; bit set → released → skip
.do_left:       LD   A, (Frog_Angle)
                SUB  ZL_KBD_STEP                      ; 8-bit wraps
                LD   (Frog_Angle), A

.check_right:   LD   A, Input.VK_KEMPSTON_RIGHT
                CALL Input.Kempston.KeyState
                JR   NZ, .do_right
                LD   BC, #DFFE
                IN   A, (C)
                BIT  0, A                             ; P (bit 0)
                JR   NZ, .check_fire                  ; не нажата → не пропускаем fire-check
.do_right:      LD   A, (Frog_Angle)
                ADD  A, ZL_KBD_STEP
                LD   (Frog_Angle), A

.check_fire:    ; FIRE = SPACE (port #7FFE bit 0) ИЛИ Kempston FIRE (port #1F bit 4).
                LD   BC, #7FFE
                IN   A, (C)
                BIT  0, A                             ; SPACE (bit 0, active LOW)
                JR   Z, .fire_pressed
                LD   A, Input.VK_KEMPSTON_B          ; bit 4 = Kempston FIRE
                CALL Input.Kempston.KeyState
                JR   NZ, .fire_pressed                ; Kempston active HIGH (NZ = pressed)
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

; Все RET в ZL_AimUpdate выше → ZL_FmEnRestore (включить FM_EN обратно).
ZL_FmEnRestore: LD   BC, FMADDR
                LD   A, FM_EN
                OUT  (C), A
                RET

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
ZL_SmoothX:     DEFW 320                              ; центр 640×480
ZL_SmoothY:     DEFW 240
ZL_PrevRawX:    DEFW 320                              ; raw mouse prev — для motion detection
ZL_PrevRawY:    DEFW 240
ZL_MouseMoved:  DEFB 0                                ; 0=stationary, 1=moved (≥THR per axis)
ZL_MotionGrace: DEFB 0                                ; frames left для catch-up Smooth после mouse motion
ZL_ChainHSA:    DEFW 0                                ; head sample на треке
ZL_ChainTick:   DEFB 0                                ; subdivider 4 для медленного движения
ZL_ColorIdx:    DEFB 0                                ; текущий cell для CELL()-эмита в цепи
ZL_TmpFrame:    DEFB 0                                ; cell/spin frame scratch (chain rendering)
ZL_TmpSlotIdx:  DEFB 0                                ; current VDC slot index for bucket hysteresis
ZL_TmpTx:       DEFW 0                                ; ZL_EmitTranslate scratch X
ZL_TmpTy:       DEFW 0                                ; ZL_EmitTranslate scratch Y
ZL_TmpAngle:    DEFW 0                                ; ZL_EmitRotate scratch angle
ZL_TmpBallX:    DEFW 0                                ; chain render: текущий шар X (px)
ZL_TmpBallY:    DEFW 0                                ; chain render: текущий шар Y (px)
ZL_TmpAngleByte:DEFB 0                                ; chain render: combined rotation byte
ZL_SpinK:       DEFB ZL_SPIN_K_DEFAULT                ; runtime spin multiplier (per-level)
ZL_CmdBytes:    DEFW 0                                ; last FT812 RAM_CMD byte count before write
ZL_CmdOverflow: DEFB 0                                ; sticky: 1 if command stream crossed warn threshold
ZL_BallCount:   DEFB 0                                ; cached VDC_SlotsLen для bucket prepass
ZL_TmpBucket:   DEFB 0                                ; current bucket в outer loop (legacy)
ZL_TmpLastTangent: DEFB 0                             ; per-ball loop: last emitted quantized tangent
ZL_TmpLastHandle:  DEFB 0xFF                          ; lazy BITMAP_HANDLE — last emitted ball handle (0/9, #FF=reset)
ZL_CacheWPtr:   DEFW 0                                ; write ptr в prepass
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
                ; Per-ball cache: stable tangent, cell, Vx_lo, Vx_hi, Vy_lo, Vy_hi = 6 bytes.
                ; bucket = #FF → skip (gap/off-track).
                ; Размещён в свободной зоне slot 1 ниже Core (page 5 #4000-#5FFF),
                ; чтобы 1440 байт cache не раздували Core за границу 8 КБ (#7FFF).
ZL_BALL_CACHE_ADDR EQU #4200                          ; (max 240 × 6 = 1440 = #5A0; до #47A0)
ZL_BALL_BUCKET_STATE_ADDR EQU #4100                   ; 240 bytes: stable tangent bucket per slot (dead-code legacy)
ZL_BALL_TANGENT_STATE_ADDR EQU #4100                  ; 240 bytes: stable raw tangent (BRAD) per slot для per-ball hysteresis
ZL_BALL_TANGENT_HYSTERESIS_THR EQU 16                 ; 16 BRAD ≈ 22.5° — reduce matrix churn for 74 Hz

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
