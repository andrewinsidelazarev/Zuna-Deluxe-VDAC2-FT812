
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
                CALL Input.Mouse.UpdateMouseState
                CALL ZL_AimUpdate
                CALL ZL_SmoothMouse
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

                ; --- 3. Sync с FT812 vsync (HighLander pattern). Wait ПОСЛЕ build,
                ; ПЕРЕД write — FT812 закончил рендер prev frame, освободил RAM_DL.
.WaitIntSync    FT_RD_REG8 FT_REG_INT_FLAGS
                AND  FT_INT_SWAP
                JR   Z, .WaitIntSync
                FT_WR_REG8 FT_REG_INT_FLAGS, FT_INT_SWAP   ; Clear flag
.WaitDLSwap     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .WaitDLSwap

                ; --- 4. Burst write Z80 buffer → FT812 RAM_CMD (in vblank window) ---
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
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
ZL_ATLAS_PHASES            EQU 32
ZL_SPIN_DIAM_SAMPLES       EQU VDC_CELL_SIZE / 2
ZL_SPIN_K_NUM              EQU 256 * ZL_ATLAS_PHASES * 113
ZL_SPIN_K_DEN              EQU 355 * ZL_SPIN_DIAM_SAMPLES
ZL_SPIN_K_DEFAULT          EQU (ZL_SPIN_K_NUM + ZL_SPIN_K_DEN / 2) / ZL_SPIN_K_DEN
ZL_SPIN_MASK               EQU ZL_ATLAS_PHASES - 1

; --- Bucket-based tangent rotation: цепь группирована по buckets, 1 cmd_rotate per bucket.
; ZL_BUCKETS = 8/16/32/64. Чем больше — тем плавнее rotation, но больше cmd_rotate/frame.
; bucket = (tangent + step/2) / step mod N. step = 256/N BRAD.
ZL_BUCKETS      EQU 32                                ; (dead-code legacy; per-ball replaced bucket loop 2026-05-18)

; --- Dual BITMAP_HANDLE для 6 цветов (FT_Cell mask 0x7F → cells 128+ wrap'ятся).
; Handle 0 source = BALLS_RAMG_ADDR (colors 0-3, cells 0..127).
; Handle 9 source = BALLS_RAMG_ADDR + 128 * cell_stride (colors 4-5, cells 0..63).
BALLS_HANDLE9_OFFSET EQU 128 * ZL_BALL_W * 2 * ZL_BALL_H

ZL_BG_W         EQU 640                               ; DXT1_L4_RGB565 decoded output W
ZL_BG_H         EQU 480                               ; DXT1_L4_RGB565 decoded output H
ZL_BG_RAMG_ADDR EQU #010000                           ; raw = c0 + c1 + l2 in RAM_G
ZL_BG_BLOCK_W   EQU ZL_BG_W / 4
ZL_BG_BLOCK_H   EQU ZL_BG_H / 4
ZL_BG_C0_SIZE   EQU ZL_BG_BLOCK_W * ZL_BG_BLOCK_H * 2
ZL_BG_C1_SIZE   EQU ZL_BG_C0_SIZE
ZL_BG_COLOR_ADDR EQU ZL_BG_RAMG_ADDR
ZL_BG_L2_ADDR   EQU ZL_BG_RAMG_ADDR + ZL_BG_C0_SIZE + ZL_BG_C1_SIZE
ZL_BG_COLOR_STRIDE EQU ZL_BG_BLOCK_W * 2
ZL_BG_L2_STRIDE EQU ZL_BG_W / 2                       ; FT_L4 = 4bpp → 2 пикс/байт
ZL_BG_L2_HANDLE EQU 8
ZL_BG_SIZE_W_LO EQU ZL_BG_W & 511
ZL_BG_SIZE_H_LO EQU ZL_BG_H & 511
ZL_BG_SIZE_HI   EQU ((ZL_BG_W >> 9) << 2) | (ZL_BG_H >> 9)

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

ZL_DrawFrame:
                ; --- Tint: белый (без модуляции цвета bitmap) ---
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; bg DXT1_L4_RGB565 raw layout (ft812_dxt_convert output):
                ;   c0/c1: RGB565 cells W/4 × H/4, stride=(W/4)*2, cell 0/1
                ;   L4   : FT_L4 full image mask W × H, stride=W/2 (4bpp)
                ; FT_CMD_BUF аргументы ОБЯЗАТЕЛЬНО в скобках — без них | парсится криво
                ; и в макрос попадает только первый operand.
                FT_CMD_BUF (ZL_DL_SAVE_CONTEXT)
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix

                ; handle 1: RGB565 color cells, cell 0 = c0, cell 1 = c1.
                FT_BitmapHandle 1
                FT_BitmapSource ZL_BG_COLOR_ADDR
                FT_BitmapLayout FT_RGB565, ZL_BG_COLOR_STRIDE, ZL_BG_BLOCK_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BG_W, ZL_BG_H

                ; handle 8: full-resolution L4 mask
                FT_BitmapHandle ZL_BG_L2_HANDLE
                FT_BitmapSource ZL_BG_L2_ADDR
                FT_BitmapLayout ZL_FT_L2, ZL_BG_L2_STRIDE, ZL_BG_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BG_W, ZL_BG_H

                FT_Begin FT_BITMAPS
                FT_CMD_BUF (ZL_DL_COLOR_MASK | ZL_COLOR_MASK_A)
                FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_ONE << 3) | ZL_BLEND_ZERO)
                FT_CMD_BUF (ZL_DL_COLOR_A | 255)
                FT_Vertex2ii 0, 0, ZL_BG_L2_HANDLE, 0

                FT_CMD_BUF (ZL_DL_COLOR_MASK | ZL_COLOR_MASK_RGB)
                CALL ZL_EmitLoadId
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF #00040000                  ; sx = 4.0
                FT_CMD_BUF #00040000                  ; sy = 4.0
                CALL ZL_EmitSetMatrix

                FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_DST_ALPHA << 3) | ZL_BLEND_ZERO)
                FT_Vertex2ii 0, 0, 1, 1              ; c1 where alpha=1
                FT_CMD_BUF (ZL_DL_BLEND_FUNC | (ZL_BLEND_ONE_MINUS_DST_ALPHA << 3) | ZL_BLEND_ONE)
                FT_Vertex2ii 0, 0, 1, 0              ; c0 where alpha=0
                FT_End
                FT_CMD_BUF (ZL_DL_RESTORE_CONTEXT)

                ; One bitmap primitive for the remaining bitmap layers.
                FT_Begin FT_BITMAPS

                ; ============================================================
                ; Killzone: hole (cell 0) → skull (cell VDC_KzFrame) на последнем
                ; track-sample. Перенесено в slot 0 helper (Core size).
                ; ============================================================
                CALL DrawKillzoneDual

                ; ============================================================
                ; Frog composition (HD Frog_Draw порядок):
                ;   plate (под body, no rotation)
                ;   body (rotation matrix к курсору, atan2)
                ;   tongue (та же rotation matrix, offset = tongueExpand·dir)
                ; tongueExpand втягивается в рот при выстреле (ЛКМ); recoil
                ; pos.x/y вычисляется в Frog_TickRecoil из Frog_Update.
                ; ============================================================
                XOR  A
                CALL FT.Coprocessor.Cell
                CALL Frog_DrawPlate
                CALL Frog_DrawBody
                CALL Frog_DrawTongue
                CALL Frog_DrawBallNow                  ; в рот, на pos+ballExpand·dir
                CALL Frog_DrawNextBall                 ; на спине, pos-28·dir
                CALL Frog_DrawFaceOverlay              ; face overlay поверх всего

                CALL Bullet_Draw                       ; летящий шар (если активен)

                ; ============================================================
                ; Цепь шаров — DUAL HANDLE для обхода CELL>=128 wrap (FT812 limit).
                ;   Handle 0: colors 0-3 (cells 0..127),  source = #050000
                ;   Handle 9: colors 4-5 (cells 0..63),   source = #090000 (BALLS+0x40000)
                ; Каждый цвет = 32 phases × 32×32 ARGB4 (stride 64, cell stride 2048).
                ; Per-ball выбор handle по биту 7 global cell. После draw chain handle 0
                ; остаётся выбранным (нужно для cursor/restore).
                ; ============================================================
                LD   A, 9
                CALL ZL_EmitBallHandle
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_W, ZL_BALL_H
                XOR  A
                CALL ZL_EmitBallHandle
                FT_BitmapLayout FT_ARGB4, ZL_BALL_W * 2, ZL_BALL_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, ZL_BALL_W, ZL_BALL_H

                ; --- VDC chain rendering: group-by-tangent (32 buckets × 11.25°).
                ; Algorithm:
                ;   Pre-pass: для каждого шара кэшируем (bucket, cell, Vx, Vy) — 6 байт.
                ;   Outer (32 buckets): emit cmd_rotate(bucket*8) + setmatrix.
                ;   Inner: scan кэш, emit Cell + Vertex2f для шаров текущего бакета.
                ; Снижение cmd_rotate с N (per ball) до 32 (per frame), но с меньшим
                ; угловым шагом, чтобы шары не дёргались на изгибах трека.
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
                ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A    ; x32
                ADD  A, D                             ; cell = color*32 + spin
                LD   (ZL_TmpFrame), A
                ; --- stable raw tangent (per-ball matrix замена bucket-loop 2026-05-18) ---
                ; Hysteresis: меняем сохранённый tangent только если raw отличается на
                ; ≥ THR (3 BRAD ≈ 4.2°). State address = #4100 + slot_idx (LOW=0 заведомо
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
                ; Init last-emitted-tangent sentinel (0x01 — never matches multiple-of-8).
                LD   A, #01
                LD   (ZL_TmpLastTangent), A
                LD   A, (ZL_BallCount)
                LD   B, A
                LD   IX, ZL_BALL_CACHE_ADDR
.PerBallLoop:   LD   A, (IX+1)                        ; cell (+1) — 0xFF = gap marker
                CP   #FF
                JP   Z, .PBSkip                       ; (JR out of range — body grew)
                PUSH BC
                ; --- Skip matrix emit если quantized tangent совпал с предыдущим
                ; emit'ом (соседи цепи часто в одном bucket'е). 8 BRAD quantization.
                LD   A, (IX+0)                        ; stable tangent
                AND  #F8                              ; round to 8 BRAD (32 buckets)
                LD   HL, ZL_TmpLastTangent
                CP   (HL)
                JR   Z, .PBNoMatrix                   ; same bucket → reuse matrix
                LD   (HL), A                          ; save new emitted tangent
                ; emit matrix
                CALL ZL_EmitLoadId
                LD   HL, ZL_BALL_HALF
                LD   DE, ZL_BALL_HALF
                CALL ZL_EmitTranslate
                LD   A, (ZL_TmpLastTangent)
                CALL ZL_EmitRotate
                LD   HL, -ZL_BALL_HALF
                LD   DE, -ZL_BALL_HALF
                CALL ZL_EmitTranslate
                CALL ZL_EmitSetMatrix
.PBNoMatrix:
                ; --- dual handle: cell<128 → handle 0; cell>=128 → handle 9 ---
                LD   A, (IX+1)                        ; cell
                AND  #80                              ; bit 7 → 0 или 0x80
                LD   A, 0
                JR   Z, .PBHSet                       ; handle 0
                LD   A, 9                             ; handle 9
.PBHSet:        CALL ZL_EmitBitmapHandle              ; clobbers BCDE
                LD   A, (IX+1)                        ; re-read cell (IX preserved across helper)
                AND  #7F                              ; local cell within handle
                CALL FT.Coprocessor.Cell
                ; ── HEAD ABSORB ALPHA WRAP ── (state=1 И slot 0)
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
.PBSkip:        LD   DE, 6
                ADD  IX, DE                            ; next record
                DEC  B
                JP   NZ, .PerBallLoop
.ChainEnd:
                ; --- Reset BITMAP_TRANSFORM к identity для cursor + следующих кадров ---
                CALL ZL_EmitLoadId
                CALL ZL_EmitSetMatrix

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

                LD   A, (VDC_GameState)
                CP   2
                CALL Z, DrawGameOverText

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
;   In:  A = 0 (handle 0, colors 0-3) или 9 (handle 9, colors 4-5).
;   Clobbers AF, BC, DE, HL. Caller follows up с BITMAP_LAYOUT/SIZE если нужно.
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
ZL_CacheWPtr:   DEFW 0                                ; write ptr в prepass
                ; Per-ball cache: bucket, cell, Vx_lo, Vx_hi, Vy_lo, Vy_hi = 6 байт.
                ; bucket = #FF → skip (gap/off-track).
                ; Размещён в свободной зоне slot 1 ниже Core (page 5 #4000-#5FFF),
                ; чтобы 1440 байт cache не раздували Core за границу 8 КБ (#7FFF).
ZL_BALL_CACHE_ADDR EQU #4200                          ; (max 240 × 6 = 1440 = #5A0; до #47A0)
ZL_BALL_BUCKET_STATE_ADDR EQU #4100                   ; 240 bytes: stable tangent bucket per slot (dead-code legacy)
ZL_BALL_TANGENT_STATE_ADDR EQU #4100                  ; 240 bytes: stable raw tangent (BRAD) per slot для per-ball hysteresis
ZL_BALL_TANGENT_HYSTERESIS_THR EQU 8                  ; 8 BRAD ≈ 11.25° — bucket size, prevent in-bucket oscillation

; Circular RAM log EQU (GAMELOG_ADDR, EVT_*) определены в main.asm перед
; TSLib block — чтобы быть видимыми и из slot 0 (Log routines) и из slot 1
; (Core hooks). См. main.asm. RAM zone #4800..#5007 в slot 1 page 5.

                endif ; ~_ZUMA_MAIN_LOOP_
