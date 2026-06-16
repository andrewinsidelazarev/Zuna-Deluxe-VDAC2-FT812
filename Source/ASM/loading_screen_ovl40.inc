; ============================================================================
; OVL_DrawNextLevelLoadingScreen — «LOADING LEVEL X-X» (1024×768, глифы ×1.6).
; Перенесён из page 0 (была забита) в loader overlay #40 (2026-06-11):
; вызывается ТОЛЬКО из EnterGameplayForCurrentLevel при slot3=#40, ДО
; SetPage3 #04. Зависимости: HudScaleXTo16 (page 0), Core.VDC_DivHLbyA
; (Main0-резидент), FT.Coprocessor.* (page 0) — все доступны при slot3=#40.
; Core.ZL_EmitScale16Matrix (#04) НЕдоступен → локальный эмит матрицы
; готовым CMD-блоком (OVL_Scale16Cmds → LDIR в BufferPtr).
; ============================================================================
OVL_DrawNextLevelLoadingScreen:
                CALL OVL_BuildLoadingLevelBuf
                CALL OVL_LoadingLevelTextWidth           ; DE = level number width
                LD   (OVL_LoadingLevelNumW), DE
                LD   HL, LOADING_TEXT_PREFIX_W           ; суффикс «...» убран
                ADD  HL, DE                              ; total width
                LD   D, H : LD E, L
                SRL  D : RR E                            ; DE = total / 2
                LD   HL, 320
                AND  A
                SBC  HL, DE
                LD   (OVL_LoadingLevelX), HL

                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_CMD_BUF #04FFFFFF                    ; COLOR_RGB white
                ; 1024×768: расчёты в 640-логике, конверсия ×8/5 на vertex'ах;
                ; глифы растягивает scale(1.6)-матрица (локальный CMD-блок).
                LD   HL, OVL_Scale16Cmds
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 24
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                FT_Begin FT_BITMAPS

                ; Префикс: "LOADING LEVEL "
                FT_BitmapHandle LOADING_TEXT_HANDLE
                FT_BitmapSource LOADING_TEXT_RAMG
                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LOADING_TEXT_PREFIX_W * 8 / 5, LOADING_TEXT_H * 8 / 5
                LD   HL, (OVL_LoadingLevelX)
                CALL HudScaleXTo16                       ; ×8/5 → screen, ×16
                LD   B, H : LD C, L
                LD   DE, ((480 - LOADING_TEXT_H) / 2 * 8 / 5) * 16
                CALL FT.Coprocessor.Vertex2f

                ; Динамический level number "X-X" тем же bitmap-slice способом.
                LD   HL, (OVL_LoadingLevelX)
                LD   DE, LOADING_TEXT_PREFIX_W
                ADD  HL, DE
                LD   (OVL_LoadingLevelCurX), HL
                LD   HL, OVL_LoadingLevelBuf
.dnl_num_loop:  LD   A, (HL)
                OR   A
                JR   Z, .dnl_num_done
                INC  HL
                PUSH HL
                CALL OVL_DrawLoadingLevelCharSlice
                POP  HL
                JR   .dnl_num_loop
.dnl_num_done:
                FT_End
                FT_Display
                FT_CMD_Count
.dnl_wait_swap: FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .dnl_wait_swap
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

OVL_LoadingLevelTextWidth:
                LD   HL, OVL_LoadingLevelBuf
                LD   DE, 0
.lltw_loop:     LD   A, (HL)
                OR   A
                RET  Z
                INC  HL
                PUSH HL
                CALL OVL_LoadingLevelCharWidth          ; A = slice width
                LD   H, 0 : LD L, A
                ADD  HL, DE
                LD   D, H : LD E, L
                POP  HL
                JR   .lltw_loop

OVL_LoadingLevelCharWidth:
                CP   '-'
                JR   Z, .llcw_dash
                CP   '0'
                JR   C, .llcw_zero
                CP   '9' + 1
                JR   NC, .llcw_zero
                SUB  '0'
                LD   C, A
                LD   B, 0
                LD   HL, OVL_LoadingDigitWTable
                ADD  HL, BC
                LD   A, (HL)
                RET
.llcw_dash:     LD   A, LOADING_TEXT_DASH_W
                RET
.llcw_zero:     XOR  A
                RET

OVL_DrawLoadingLevelCharSlice:
                CP   '-'
                JR   Z, .dllc_dash
                CP   '0'
                RET  C
                CP   '9' + 1
                RET  NC
                SUB  '0'
                LD   E, A
                LD   D, 0
                LD   HL, OVL_LoadingDigitXTable
                ADD  HL, DE
                ADD  HL, DE
                LD   E, (HL) : INC HL
                LD   D, (HL)                            ; DE = slice x
                PUSH DE
                LD   H, 0 : LD L, A
                LD   DE, OVL_LoadingDigitWTable
                ADD  HL, DE
                LD   A, (HL)                            ; A = width
                POP  DE
                JR   OVL_DrawLoadingSliceAtCurX
.dllc_dash:     LD   DE, LOADING_TEXT_DASH_X
                LD   A, LOADING_TEXT_DASH_W
                ; дальше сразу OVL_DrawLoadingSliceAtCurX

OVL_DrawLoadingSliceAtCurX:
                LD   (OVL_LoadingSliceW), A
                EX   DE, HL                             ; HL = slice x in pixels
                ADD  HL, HL                             ; bytes for ARGB4
                LD   DE, LOADING_TEXT_RAMG & #FFFF
                ADD  HL, DE
                LD   A, (LOADING_TEXT_RAMG >> 16) & #FF
                JR   NC, .dls_src_ok
                INC  A
.dls_src_ok:    LD   B, #01                              ; BITMAP_SOURCE
                LD   C, A
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                ; BITMAP_SIZE_H = 0: после широкого префикса (608>511) H-биты
                ; залипли в DL-стейте — без сброса окно слайса станет 512+.
                LD   B, #29
                LD   C, 0
                LD   DE, 0
                CALL FT.Coprocessor.Command_BCDE
                LD   A, (OVL_LoadingSliceW)
                LD   H, 0 : LD L, A
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; ×8
                LD   A, 5
                CALL Core.VDC_DivHLbyA                  ; ширина окна ×8/5 (экранная)
                ADD  HL, HL : ADD HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; width << 9
                LD   DE, LOADING_TEXT_H * 8 / 5
                ADD  HL, DE
                LD   B, #08                              ; BITMAP_SIZE, nearest/border/border
                LD   C, 0
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                LD   HL, (OVL_LoadingLevelCurX)
                CALL HudScaleXTo16                       ; ×8/5 → screen, ×16
                LD   B, H : LD C, L
                LD   DE, ((480 - LOADING_TEXT_H) / 2 * 8 / 5) * 16
                CALL FT.Coprocessor.Vertex2f

                LD   A, (OVL_LoadingSliceW)
                LD   H, 0 : LD L, A
                LD   DE, (OVL_LoadingLevelCurX)
                ADD  HL, DE
                LD   (OVL_LoadingLevelCurX), HL
                RET

OVL_BuildLoadingLevelBuf:
                LD   DE, OVL_LoadingLevelBuf
                LD   A, (CurrentLevel)
                INC  A                                  ; N = 1..22
                LD   B, '0'
.bll_n_tens:    CP   10
                JR   C, .bll_n_units
                SUB  10
                INC  B
                JR   .bll_n_tens
.bll_n_units:   LD   C, A
                LD   A, B
                CP   '0'
                JR   Z, .bll_n_skip
                LD   (DE), A : INC DE
.bll_n_skip:    LD   A, C : ADD A, '0'
                LD   (DE), A : INC DE
                LD   A, '-'
                LD   (DE), A : INC DE
                LD   A, (CurrentDifficulty)
                INC  A
                ADD  A, '0'
                LD   (DE), A : INC DE
                XOR  A
                LD   (DE), A
                RET

; Готовый DL-блок: ЗАПЕЧЁННЫЕ BITMAP_TRANSFORM (A=E=160/256 = ровно 1/1.6),
; 6 слов = 24 байта. НЕ CMD_SCALE — его инверсия усечённая (159/256 = ×1.6101).
OVL_Scale16Cmds:
                DEFD #150000A0                          ; BITMAP_TRANSFORM_A = 160/256
                DEFD #16000000                          ; B = 0
                DEFD #17000000                          ; C = 0
                DEFD #18000000                          ; D = 0
                DEFD #190000A0                          ; BITMAP_TRANSFORM_E = 160/256
                DEFD #1A000000                          ; F = 0

OVL_LoadingLevelBuf:  DEFS 6                            ; "NN-M" + 0
OVL_LoadingLevelX:    DEFW 0
OVL_LoadingLevelNumW: DEFW 0
OVL_LoadingLevelCurX: DEFW 0
OVL_LoadingSliceW:    DEFB 0
OVL_LoadingDigitXTable:
                DEFW LOADING_TEXT_DIGIT_0_X, LOADING_TEXT_DIGIT_1_X, LOADING_TEXT_DIGIT_2_X, LOADING_TEXT_DIGIT_3_X, LOADING_TEXT_DIGIT_4_X
                DEFW LOADING_TEXT_DIGIT_5_X, LOADING_TEXT_DIGIT_6_X, LOADING_TEXT_DIGIT_7_X, LOADING_TEXT_DIGIT_8_X, LOADING_TEXT_DIGIT_9_X
OVL_LoadingDigitWTable:
                DEFB LOADING_TEXT_DIGIT_0_W, LOADING_TEXT_DIGIT_1_W, LOADING_TEXT_DIGIT_2_W, LOADING_TEXT_DIGIT_3_W, LOADING_TEXT_DIGIT_4_W
                DEFB LOADING_TEXT_DIGIT_5_W, LOADING_TEXT_DIGIT_6_W, LOADING_TEXT_DIGIT_7_W, LOADING_TEXT_DIGIT_8_W, LOADING_TEXT_DIGIT_9_W
