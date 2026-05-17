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

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #6000                        ; slot 1 (page 5)
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
                ; Idle (KzFrame=1) и финальный Game Over (KzFrame=0) — закрытый
                ; череп уже запечён в bg, overlay не нужен.  Рисуем только когда
                ; KzFrame>=2 (animation opening / absorb).
                LD   A, (Core.VDC_KzFrame)
                CP   2
                RET  C
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

DrawGameOverText:
                LD   C, 255 : LD D, 214 : LD E, 64
                CALL FT.Coprocessor.ColorRGB
                FT_Text 320, 72, 30, FT_OPT_CENTER
                FT_String GameOverText, GameOverText.Size
                LD   C, 255 : LD D, 255 : LD E, 255
                JP   FT.Coprocessor.ColorRGB

GameOverText:
                BYTE "GAME OVER", 0, 0, 0
.Size           EQU $ - GameOverText

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
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryB
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryB:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBalls

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
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryF
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryF:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadFrog

                ; Залить killzone atlas 12×64×64 ARGB4 в RAM_G KZ_RAMG_ADDR.
                LD   A, KZ_PAGE
                LD   (BgPg), A
                LD   HL, KZ_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (KZ_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, KZ_PAGE_COUNT
.UploadKz:      PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryKz
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryKz:     LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadKz

                ; Залить cursor 24×24 ARGB4 (1152 байт) в RAM_G CURSOR_RAMG_ADDR.
                ; Single page 0x5A. Padding в page безопасен (RAM_G #0BC000+1152..
                ; #0C0000 = пустая зона, никто не читает).
                LD   A, CURSOR_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, CURSOR_W * CURSOR_H * 2
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                LD   DE, CURSOR_RAMG_ADDR & 0xFFFF
                CALL FT.WriteMem

                ; Восстановить slot 2 на TrackData (page 6)
                SetPage2 6

                ; --- VDC physics init (TrackData уже доступен в slot 2) ---
                CALL VDC_Init
                CALL Frog_Init
                CALL Bullet_Init
                CALL Log_Init                          ; circular RAM log для F12-dump
                RET

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 15                                ; DXT1_L4 640×480 (c0|c1|L4 = 230400 bytes, 15 × 16K pages, last padded)
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BALLS_FIRST_PAGE   EQU #2D                             ; balls_atlas pages 0x2D..0x38 (12 pages)
BALLS_PAGE_COUNT   EQU 12                                ; 6 colors × 16 phases × 32×32 ARGB4 = 192 KB
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000)
FROG_PAGE          EQU #52                             ; spgbld first page (frog body)
FROG_PAGE_COUNT    EQU 2                                ; 122×122 ARGB4 = 2 pages each
FROG_TOTAL_PAGES   EQU FROG_PAGE_COUNT * 4              ; body+plate+tongue+overlay = 8 pages
FROG_RAMG_ADDR     EQU #09C000                         ; после balls (19 pages = 0x4C000 от #050000)
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #4000 * FROG_PAGE_COUNT     ; #0A4000
TONGUE_RAMG_ADDR   EQU PLATE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT    ; #0AC000
OVERLAY_RAMG_ADDR  EQU TONGUE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT   ; #0B4000
KZ_PAGE            EQU #16
KZ_PAGE_COUNT      EQU 6                               ; 12 cells 64x64 ARGB4
KZ_RAMG_ADDR       EQU #080000                         ; free gap before frog assets

; --- Cursor 24×24 ARGB4 (1 page) ---
CURSOR_PAGE        EQU #5A
CURSOR_RAMG_ADDR   EQU #0BC000                         ; сразу после overlay area
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
                SetPage1 5                            ; #4000 → Core code page
                SetPage2 6                            ; #8000 → TrackData (track_640.bin)
                SetPage3 8
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

                ; ----- Init_Video, VDC и MainLoop из отдельных файлов -----
                include "Init_Video.asm"
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"

End:
                endmodule

Core_Size        EQU Core.End - Core.Start
                display "Core:     \t", /A, Core.Start, " size=", /D, Core_Size, " bytes"
                SAVEBIN "Core.bin", Core.Start, Core_Size

                END EntryPoint
