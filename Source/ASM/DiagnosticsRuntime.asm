; ============================================================================
; DiagnosticsRuntime.asm
; ----------------------------------------------------------------------------
; Runtime-диагностика для патченных/emulator-прогонов. Обычные сборки исключают
; этот файл через RUNTIME_DIAGNOSTICS_ENABLED = 0 в main.asm.
; ============================================================================

                ifdef DIAG_SECTION_GLOBAL_EQU
; --- Circular RAM event log EQU ---------------------------------------------
GAMELOG_ADDR        EQU #4B8C                          ; после двух кешей и временных данных выбора уровня (#4B80..#4B8B)
GAMELOG_IDX_ADDR    EQU #4C80
GAMELOG_FROZEN_ADDR EQU #4C81
LOG_TMP_TYPE_ADDR   EQU #4C82
LOG_TMP_CTX_ADDR    EQU #4C83
LOG_TMP_DATA_ADDR   EQU #4C84
LOG_END_ADDR        EQU #4C88
GAMELOG_ENTRY_COUNT EQU (GAMELOG_IDX_ADDR - GAMELOG_ADDR) / 8
VDC_SEED_SNAPSHOT_ADDR EQU #4CAD
BUILD_CANARY_ADDR   EQU #4C8C                          ; 33 bytes, ends before CMD buffer #4CB0
BUILD_CANARY_LEN    EQU 33
BOOT_CANARY_ADDR    EQU #5044
EVT_SHOT_FIRED      EQU 1
EVT_BBOX_HIT        EQU 2
EVT_HEMI            EQU 3
EVT_INSERT          EQU 4
EVT_CASCADE_TRIGGER EQU 5
EVT_MATCH3          EQU 6
                endif

                ifdef DIAG_SECTION_SLOT0
; --- Slot 0 event log helpers ------------------------------------------------
; Kept near TSLib so gameplay overlay calls stay short.
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
                CP   GAMELOG_ENTRY_COUNT
                JR   C, .le_nowrap
                XOR  A
.le_nowrap:     LD   (GAMELOG_IDX_ADDR), A
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

LogShotFired:                                          ; ctx=Frog_Angle, d1=SmoothX, d2=SmoothY
                PUSH HL
                PUSH AF
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

LogInsert:                                             ; reads VDC_* directly
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

LogMatch3:                                             ; ctx=color, d1=lb|rb, d2=count|marker
                PUSH HL
                PUSH AF
                LD   A, EVT_MATCH3
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   A, (Core.VDC_TmpMC_Color)
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, (Core.VDC_TmpML)
                LD   (LOG_TMP_DATA_ADDR), A
                LD   A, (Core.VDC_TmpMR)
                LD   (LOG_TMP_DATA_ADDR+1), A
                LD   A, (Core.VDC_TmpMCount)
                LD   (LOG_TMP_DATA_ADDR+2), A
                LD   A, (Core.VDC_TmpInsIdx)
                LD   (LOG_TMP_DATA_ADDR+3), A
                CALL LogEvent
                POP  AF
                POP  HL
                RET

LogCascadeTrigger:                                     ; ctx=gap_idx, d1=len|HSA, d2=offset|HSub
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
                LD   DE, (Core.VDC_pOffsets)
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
                endif

                ifdef DIAG_SECTION_CORE_DATA
BuildCanaryBytes:
                DB "ZVDAC2 2026-05-24 PAGE3GUARD",0
                DB #00, #05, #06, #04
BuildCanaryBytesEnd:
                endif

                ifdef DIAG_SECTION_RESIDENT_VARS
; --- Резидентная диагностика, сохраняемая F12 dumps --------------------------
; Защёлка инвариантов VDC. Первый сбой живёт до следующего VDC_Init.
;   code 1: SlotsLen > VDC_MAX_SLOTS
;   code 2: HSA > TrackNumSlots
;   code 3: Slots[i] не color и не GAP marker
;   code 4: Offsets[i] вне [-CELL_SIZE..CELL_SIZE]
;   code 5: ExplodeFrame[i] содержит неверный ExplodeMarker
;   code 6: Shot2[i] не 0/1
VDC_AssertCode:      DEFB 0
VDC_AssertCtx:       DEFB 0
VDC_AssertLen:       DEFB 0
VDC_AssertHSA:       DEFB 0
VDC_AssertValue:     DEFB 0
VDC_AssertFrame:     DEFW 0

; Loader trace резидентный, потому что F12 снимает slot 1/Core, а не loader overlay.
ZiFiTraceStep:       DEFB 0
ZiFiTraceBgOff:      DEFW 0
ZiFiTraceBgSize:     DEFW 0
ZiFiTraceOpenStep:   DEFB 0
ZiFiTraceDirsVisited: DEFB 0
ZiFiTraceZumaFound:  DEFB 0
ZiFiTracePakFound:   DEFB 0
ZiFiTracePakSizeL:   DEFW 0
ZiFiTracePakSizeH:   DEFW 0
                endif

                ifdef DIAG_SECTION_QUIT_TRACE_VARS
QuitTraceStage:      DEFB 0         ; #10 probe, #20 copy, #30 params, #40 jump, #80+ stub
QuitTraceSectors:    DEFB 0         ; sectors, прочитанные quit stub
                endif

                ifdef DIAG_SECTION_VDC
; ============================================================================
; VDC_CheckInvariants — пассивная проверка правил state после кадра.
; Только защёлкивает первое нарушение в VDC_Assert* для F12 dump.
; ============================================================================
VDC_CheckInvariants:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                LD   A, (VDC_AssertCode)
                OR   A
                JP   NZ, .vci_done

                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS + 1
                JR   C, .vci_len_ok
                LD   C, 1
                LD   E, A
                XOR  A
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_len_ok:
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A
                LD   D, 0
                AND  A
                SBC  HL, DE
                JR   NC, .vci_hsa_ok
                LD   C, 2
                LD   A, (VDC_HSA)
                LD   E, A
                XOR  A
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_hsa_ok:
                LD   A, (VDC_SlotsLen)
                OR   A
                JP   Z, .vci_done
                LD   B, A
                LD   C, 0
.vci_loop:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_NUM_COLORS
                JR   C, .vci_slot_ok
                CP   VDC_GAP_STOP
                JR   Z, .vci_slot_ok
                CP   VDC_GAP_CASCADE
                JR   Z, .vci_slot_ok
                LD   A, C
                LD   C, 3
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_slot_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_CELL_SIZE + 1
                JR   C, .vci_offset_ok
                CP   256 - VDC_CELL_SIZE
                JR   NC, .vci_offset_ok
                LD   A, C
                LD   C, 4
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_offset_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .vci_explode_ok
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_GAP_STOP
                JR   Z, .vci_explode_ok
                CP   VDC_GAP_CASCADE
                JR   Z, .vci_explode_ok
                LD   A, C
                LD   C, 5
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_explode_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   2
                JR   C, .vci_next
                LD   A, C
                LD   C, 6
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_next:
                INC  C
                DJNZ .vci_loop
.vci_done:
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

; Вход: C=code, A=index/context, E=value.
VDC_LatchAssert:
                LD   (VDC_AssertCtx), A
                LD   A, C
                LD   (VDC_AssertCode), A
                LD   A, (VDC_SlotsLen)
                LD   (VDC_AssertLen), A
                LD   A, (VDC_HSA)
                LD   (VDC_AssertHSA), A
                LD   A, E
                LD   (VDC_AssertValue), A
                LD   HL, (ZL_FrameCounter)
                LD   (VDC_AssertFrame), HL
                RET
                endif
