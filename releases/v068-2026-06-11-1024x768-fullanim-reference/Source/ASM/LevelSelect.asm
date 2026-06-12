                ifndef _ZUMA_LEVEL_SELECT_
                define _ZUMA_LEVEL_SELECT_

; ============================================================================
; FT812 level-select room. The generated asset profile reuses the main-menu
; RAM_G span: the rooms never need to stay resident at the same time.
; ============================================================================

                include "level_select_assets.inc"

LS_HANDLE_SKY       EQU MENU_HANDLE_SKY
LS_HANDLE_BG        EQU MENU_HANDLE_FG
LS_HANDLE_BUTTON    EQU MENU_HANDLE_BUTTON
LS_HANDLE_BADGE     EQU 5

LevelSelect:
                CALL LoadLevelSelectAssets
                LD   HL, 0
                LD   (LevelSelectSkyPos), HL                ; позиция неба в 1/16 px
                XOR  A
                LD   (LevelSelectLmbPrev), A
                LD   A, 1                                   ; фронт-флаги = «нажато» -> гасим перенос
                LD   (LevelSelectKbdUpPrev), A             ; нажатий с предыдущей сцены (Fire, которым
                LD   (LevelSelectKbdDownPrev), A           ; вошли) до их отпускания
                LD   (LevelSelectKbdLeftPrev), A
                LD   (LevelSelectKbdRightPrev), A
                LD   (LevelSelectKbdFirePrev), A
                LD   (LevelSelectKbdEscPrev), A
                CALL FadeInLevelSelect

.loop:          CALL Input_Scan                            ; мышь + PS/2-клавиатура (глобально)
                CALL LevelSelectUpdateControls
                LD   A, (LevelSelectMainMenuClick)
                OR   A
                JP   NZ, FadeLevelSelectToMenu
                LD   A, (LevelSelectPlayClick)
                OR   A
                JR   NZ, .play
                CALL LevelSelectAdvanceSky
                CALL LevelSelectBuildFrame
                CALL MenuSwapFrame
                JP   .loop

.play:          LD   A, 1
                LD   (CurrentGameMode), A
                JP   FadeLevelSelectToGameplay

LoadLevelSelectAssets:
                LD   B, LevelSelectInflateAssetsCount
                LD   HL, LevelSelectInflateAssets
                CALL MenuInflateAssetsFromTable
                CALL LoadLevelSelectPreviewAssets
                CALL LoadLevelSelectFontNative
                CALL LoadLevelSelectPreviewMarkers

                LD   A, LS_SKY_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (LS_SKY_PAL_RAMG >> 16) & #FF
                LD   DE, LS_SKY_PAL_RAMG & #FFFF
                CALL FT.WriteMem
                LD   A, LS_UI_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (LS_UI_PAL_RAMG >> 16) & #FF
                LD   DE, LS_UI_PAL_RAMG & #FFFF
                CALL FT.WriteMem
                SetPage2 6
                SetPage3 UI_OVL_PAGE                    ; this code runs on the UI overlay (#41); restore it, not #04
                RET

LevelSelectIsFirstLevel:
                LD   A, (CurrentLevel)
                OR   A
                RET

LevelSelectInflateAssets:
                MenuInflateAsset LS_BG_RAMG + LS_BG_Z_CHUNK * 0, LS_BG_Z0_PAGE, LS_BG_Z0_SIZE
                MenuInflateAsset LS_BG_RAMG + LS_BG_Z_CHUNK * 1, LS_BG_Z1_PAGE, LS_BG_Z1_SIZE
                MenuInflateAsset LS_BG_RAMG + LS_BG_Z_CHUNK * 2, LS_BG_Z2_PAGE, LS_BG_Z2_SIZE
                MenuInflateAsset LS_BG_RAMG + LS_BG_Z_CHUNK * 3, LS_BG_Z3_PAGE, LS_BG_Z3_SIZE
                MenuInflateAsset LS_BG_RAMG + LS_BG_Z_CHUNK * 4, LS_BG_Z4_PAGE, LS_BG_Z4_SIZE
                MenuInflateAsset LS_SKY_RAMG, LS_SKY_Z_PAGE, LS_SKY_Z_SIZE
                MenuInflateAsset LS_MM_N_RAMG, LS_MM_N_Z_PAGE, LS_MM_N_Z_SIZE
                MenuInflateAsset LS_MM_H_RAMG, LS_MM_H_Z_PAGE, LS_MM_H_Z_SIZE
                MenuInflateAsset LS_MM_P_RAMG, LS_MM_P_Z_PAGE, LS_MM_P_Z_SIZE
                MenuInflateAsset LS_BACK_N_RAMG, LS_BACK_N_Z_PAGE, LS_BACK_N_Z_SIZE
                MenuInflateAsset LS_BACK_H_RAMG, LS_BACK_H_Z_PAGE, LS_BACK_H_Z_SIZE
                MenuInflateAsset LS_BACK_P_RAMG, LS_BACK_P_Z_PAGE, LS_BACK_P_Z_SIZE
                MenuInflateAsset LS_PLAY_N_RAMG, LS_PLAY_N_Z_PAGE, LS_PLAY_N_Z_SIZE
                MenuInflateAsset LS_PLAY_H_RAMG, LS_PLAY_H_Z_PAGE, LS_PLAY_H_Z_SIZE
                MenuInflateAsset LS_PLAY_P_RAMG, LS_PLAY_P_Z_PAGE, LS_PLAY_P_Z_SIZE
                MenuInflateAsset LS_NEXT_N_RAMG, LS_NEXT_N_Z_PAGE, LS_NEXT_N_Z_SIZE
                MenuInflateAsset LS_NEXT_H_RAMG, LS_NEXT_H_Z_PAGE, LS_NEXT_H_Z_SIZE
                MenuInflateAsset LS_NEXT_P_RAMG, LS_NEXT_P_Z_PAGE, LS_NEXT_P_Z_SIZE
                MenuInflateAsset LS_RBT_N_RAMG, LS_RBT_N_Z_PAGE, LS_RBT_N_Z_SIZE
                MenuInflateAsset LS_RBT_H_RAMG, LS_RBT_H_Z_PAGE, LS_RBT_H_Z_SIZE
                MenuInflateAsset LS_RBT_P_RAMG, LS_RBT_P_Z_PAGE, LS_RBT_P_Z_SIZE
                MenuInflateAsset LS_EGL_N_RAMG, LS_EGL_N_Z_PAGE, LS_EGL_N_Z_SIZE
                MenuInflateAsset LS_EGL_H_RAMG, LS_EGL_H_Z_PAGE, LS_EGL_H_Z_SIZE
                MenuInflateAsset LS_EGL_P_RAMG, LS_EGL_P_Z_PAGE, LS_EGL_P_Z_SIZE
                MenuInflateAsset LS_JAG_N_RAMG, LS_JAG_N_Z_PAGE, LS_JAG_N_Z_SIZE
                MenuInflateAsset LS_JAG_H_RAMG, LS_JAG_H_Z_PAGE, LS_JAG_H_Z_SIZE
                MenuInflateAsset LS_JAG_P_RAMG, LS_JAG_P_Z_PAGE, LS_JAG_P_Z_SIZE
                MenuInflateAsset LS_SUN_N_RAMG, LS_SUN_N_Z_PAGE, LS_SUN_N_Z_SIZE
                MenuInflateAsset LS_SUN_H_RAMG, LS_SUN_H_Z_PAGE, LS_SUN_H_Z_SIZE
                MenuInflateAsset LS_SUN_P_RAMG, LS_SUN_P_Z_PAGE, LS_SUN_P_Z_SIZE
LevelSelectInflateAssetsEnd:
LevelSelectInflateAssetsCount EQU (LevelSelectInflateAssetsEnd - LevelSelectInflateAssets) / 6

LS_SKY_SCROLL16 EQU 11                                 ; 1/16 px/кадр (≈2/3), субпиксельно — без джиттера
LevelSelectAdvanceSky:
                ; pos += шаг (1/16 px); wrap вычитанием W*16 без потери остатка.
                LD   HL, (LevelSelectSkyPos)
                LD   DE, LS_SKY_SCROLL16
                ADD  HL, DE
                LD   DE, LS_SKY_W * 16
                AND  A
                SBC  HL, DE
                JR   NC, .store                        ; >=0 -> wrapped
                ADD  HL, DE                            ; <0  -> вернуть
.store:         LD   (LevelSelectSkyPos), HL
                RET

                macro LevelSelectCheckControl X?, Y?, W?, H?, State?, ClickVar?
                LD   BC, X?
                LD   DE, X? + W?
                LD   IX, Y?
                LD   IY, Y? + H?
                CALL MenuPointInside
                LD   A, C
                OR   A
                JR   Z, .outside?
                LD   A, (LevelSelectLmbNow)
                OR   A
                LD   A, 1
                JR   Z, .store?
                INC  A
.store?:        LD   (State?), A
                if ClickVar?
                CP   1
                JR   NZ, .outside?
                LD   A, (LevelSelectLmbPrev)
                CP   1
                JR   NZ, .outside?
                LD   A, 1
                LD   (ClickVar?), A
                LD   A, SND_BUTTON1
                CALL GS_PlaySfx
                endif
.outside?:
                endm

LevelSelectUpdateControls:
                XOR  A
                LD   (LevelSelectMainMenuClick), A
                LD   (LevelSelectPlayClick), A
                LD   (LevelSelectBackClick), A
                LD   (LevelSelectNextClick), A
                LD   (LevelSelectRabbitClick), A
                LD   (LevelSelectEagleClick), A
                LD   (LevelSelectJaguarClick), A
                LD   (LevelSelectSunGodClick), A
                LD   (LevelSelectButtonStateMainMenu), A
                LD   (LevelSelectButtonStateBack), A
                LD   (LevelSelectButtonStatePlay), A
                LD   (LevelSelectButtonStateNext), A
                LD   (LevelSelectBadgeStateRabbit), A
                LD   (LevelSelectBadgeStateEagle), A
                LD   (LevelSelectBadgeStateJaguar), A
                LD   (LevelSelectBadgeStateSunGod), A
                CALL Input_MouseLMB
                LD   A, 0
                JR   Z, .lmb_ready
                INC  A
.lmb_ready:     LD   (LevelSelectLmbNow), A
                LevelSelectCheckControl LS_MM_X, LS_MM_Y, LS_MM_W, LS_MM_H, LevelSelectButtonStateMainMenu, LevelSelectMainMenuClick
                CALL LevelSelectIsFirstLevel
                JR   Z, .skip_back_control
                LevelSelectCheckControl LS_BACK_X, LS_BACK_Y, LS_BACK_W, LS_BACK_H, LevelSelectButtonStateBack, LevelSelectBackClick
.skip_back_control:
                LevelSelectCheckControl LS_PLAY_X, LS_PLAY_Y, LS_PLAY_W, LS_PLAY_H, LevelSelectButtonStatePlay, LevelSelectPlayClick
                LevelSelectCheckControl LS_NEXT_X, LS_NEXT_Y, LS_NEXT_W, LS_NEXT_H, LevelSelectButtonStateNext, LevelSelectNextClick
                LevelSelectCheckControl LS_RBT_X, LS_RBT_Y, LS_RBT_W, LS_RBT_H, LevelSelectBadgeStateRabbit, LevelSelectRabbitClick
                LevelSelectCheckControl LS_EGL_X, LS_EGL_Y, LS_EGL_W, LS_EGL_H, LevelSelectBadgeStateEagle, LevelSelectEagleClick
                LevelSelectCheckControl LS_JAG_X, LS_JAG_Y, LS_JAG_W, LS_JAG_H, LevelSelectBadgeStateJaguar, LevelSelectJaguarClick
                LevelSelectCheckControl LS_SUN_X, LS_SUN_Y, LS_SUN_W, LS_SUN_H, LevelSelectBadgeStateSunGod, LevelSelectSunGodClick
                CALL LevelSelectKeyboard                   ; клавиатура: сложность/уровень/Play/ESC
                CALL LevelSelectRedHoverDifficulty
                CALL LevelSelectApplyDifficultyClick
                CALL LevelSelectApplyLevelClick
                CALL LevelSelectPressDifficulty
                LD   A, (LevelSelectLmbNow)
                LD   (LevelSelectLmbPrev), A
                RET

; ----------------------------------------------------------------------------
; Клавиатурное управление выбором уровня (схема юзера):
;   Вверх/Вниз  — сложность ПО ЭКРАНУ. Бейджи идут сверху вниз Sun God(3) / Jaguar(2)
;                 / Eagle(1) / Rabbit(0) (Y = 30 / 83 / 131 / 180), поэтому Вверх =
;                 к верхнему бейджу (CurrentDifficulty++, clamp 3 = Sun God), Вниз =
;                 к нижнему (CurrentDifficulty--, clamp 0 = Rabbit). Иначе стрелки
;                 двигали подсветку в противоположную сторону экрана.
;   Влево/Вправо — уровень (как кнопки Back/Next: ставит Click-флаги, дальше их
;                  обработает LevelSelectApplyLevelClick — там же guard L1 и wrap);
;   Огонь — Play;  ESC — выход в главное меню.
; Зовётся в LevelSelectUpdateControls ПОСЛЕ сброса Click-флагов и hit-test'ов мыши,
; но ДО Apply*-рутин — поэтому выставленные тут флаги и CurrentDifficulty доедут.
; ----------------------------------------------------------------------------
LevelSelectKeyboard:
                ; Вверх — к верхнему бейджу (Sun God): CurrentDifficulty++, clamp 3
                CALL Input_Up
                LD   HL, LevelSelectKbdUpPrev
                CALL Input_EdgeZ
                JR   Z, .chk_down
                LD   A, (CurrentDifficulty)
                CP   3
                JR   NC, .chk_down                         ; уже Sun God (3, верх)
                INC  A
                LD   (CurrentDifficulty), A
.chk_down:      ; Вниз — к нижнему бейджу (Rabbit): CurrentDifficulty--, clamp 0
                CALL Input_Down
                LD   HL, LevelSelectKbdDownPrev
                CALL Input_EdgeZ
                JR   Z, .chk_left
                LD   A, (CurrentDifficulty)
                OR   A
                JR   Z, .chk_left                          ; уже Rabbit (0, низ)
                DEC  A
                LD   (CurrentDifficulty), A
.chk_left:      ; Влево — предыдущий уровень (как Back)
                CALL Input_Left
                LD   HL, LevelSelectKbdLeftPrev
                CALL Input_EdgeZ
                JR   Z, .chk_right
                LD   A, 1
                LD   (LevelSelectBackClick), A
.chk_right:     ; Вправо — следующий уровень (как Next)
                CALL Input_Right
                LD   HL, LevelSelectKbdRightPrev
                CALL Input_EdgeZ
                JR   Z, .chk_fire
                LD   A, 1
                LD   (LevelSelectNextClick), A
.chk_fire:      ; Огонь — Play
                CALL Input_FireKey
                LD   HL, LevelSelectKbdFirePrev
                CALL Input_EdgeZ
                JR   Z, .chk_esc
                LD   A, 1
                LD   (LevelSelectPlayClick), A
.chk_esc:       ; ESC — выход в главное меню
                CALL Input_Esc
                LD   HL, LevelSelectKbdEscPrev
                CALL Input_EdgeZ
                RET  Z
                LD   A, 1
                LD   (LevelSelectMainMenuClick), A
                RET

LevelSelectApplyDifficultyClick:
                LD   A, (LevelSelectRabbitClick)
                OR   A
                JR   Z, .eagle
                XOR  A
                LD   (CurrentDifficulty), A
.eagle:         LD   A, (LevelSelectEagleClick)
                OR   A
                JR   Z, .jaguar
                LD   A, 1
                LD   (CurrentDifficulty), A
.jaguar:        LD   A, (LevelSelectJaguarClick)
                OR   A
                JR   Z, .sun_god
                LD   A, 2
                LD   (CurrentDifficulty), A
.sun_god:       LD   A, (LevelSelectSunGodClick)
                OR   A
                RET  Z
                LD   A, 3
                LD   (CurrentDifficulty), A
                RET

LevelSelectApplyLevelClick:
                LD   A, (LevelSelectBackClick)
                OR   A
                JR   Z, .next
                LD   A, (CurrentLevel)
                OR   A
                JR   Z, .next
                DEC  A
                LD   (CurrentLevel), A
                CALL LoadLevelSelectPreviewAssets
.next:          LD   A, (LevelSelectNextClick)
                OR   A
                RET  Z
                LD   A, (CurrentLevel)
                INC  A
                CP   LEVEL_RUNTIME_COUNT
                JR   C, .store_next
                XOR  A
.store_next:    LD   (CurrentLevel), A
                JP   LoadLevelSelectPreviewAssets

LevelSelectRedHoverDifficulty:
                LD   HL, LevelSelectBadgeStateRabbit
                LD   B, 4
.next:          LD   A, (HL)
                OR   A
                JR   Z, .keep
                LD   (HL), 2
.keep:          INC  HL
                DJNZ .next
                RET

LevelSelectPressDifficulty:
                LD   HL, LevelSelectBadgeStateRabbit
                LD   A, (CurrentDifficulty)
                OR   A
                JR   Z, .press
                INC  HL
                CP   1
                JR   Z, .press
                INC  HL
                CP   2
                JR   Z, .press
                INC  HL
.press:         LD   A, (HL)
                LD   (HL), 1
                RET

LevelSelectBuildFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                CALL LevelSelectDrawSky
                CALL DrawLevelSelectPreview              ; render machinery is now resident (shared_render.asm) — no page swap needed
                CALL LevelSelectDrawBackground
                CALL LevelSelectDrawBadges
                CALL LevelSelectDrawButtons
                CALL MenuDrawCursor
                CALL DrawFadeOverlay
                FT_End
                FT_Display
                FT_CMD_Count
                RET

LevelSelectDrawSky:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_BITMAPS
                FT_PaletteSource LS_SKY_PAL_RAMG
                FT_BitmapHandle LS_HANDLE_SKY
                FT_BitmapSource LS_SKY_RAMG
                FT_BitmapLayout FT_PALETTED4444, LS_SKY_W, LS_SKY_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, LS_SKY_W, LS_SKY_H
                ; LevelSelectSkyPos уже в 1/16 px — рисуем напрямую (субпиксельно).
                LD   BC, (LevelSelectSkyPos)
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; wrap-копия слева: x = pos - 639 px
                LD   HL, (LevelSelectSkyPos)
                LD   DE, -(639 * 16)
                ADD  HL, DE
                LD   B, H : LD C, L
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

LevelSelectDrawBackground:
                FT_PaletteSource LS_UI_PAL_RAMG
                FT_BitmapHandle LS_HANDLE_BG
                FT_BitmapSource LS_BG_RAMG
                FT_BitmapLayout FT_PALETTED4444, LS_BG_W, LS_BG_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, LS_BG_W, LS_BG_H
                LD   BC, 0
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

LevelSelectDrawButtons:
                FT_PaletteSource LS_UI_PAL_RAMG
                CALL LevelSelectDrawMainMenu
                CALL LevelSelectDrawBackButton
                CALL LevelSelectDrawPlay
                JP   LevelSelectDrawNext

LevelSelectDrawBadges:
                FT_PaletteSource LS_UI_PAL_RAMG
                CALL LevelSelectDrawRabbit
                CALL LevelSelectDrawEagle
                CALL LevelSelectDrawJaguar
                JP   LevelSelectDrawSunGod

                macro LevelSelectDrawThree Name?, State?, Normal?, Hover?, Pressed?, X?, Y?, W?, H?, Handle?
Name?:          FT_BitmapHandle Handle?
                LD   A, (State?)
                CP   1
                JR   Z, .hover?
                CP   2
                JR   Z, .pressed?
                FT_BitmapSource Normal?
                JR   .draw?
.hover?:        FT_BitmapSource Hover?
                JR   .draw?
.pressed?:      FT_BitmapSource Pressed?
.draw?:         FT_BitmapLayout FT_PALETTED4444, W?, H?
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, W?, H?
                LD   BC, X? * 16
                LD   DE, Y? * 16
                JP   FT.Coprocessor.Vertex2f
                endm

                LevelSelectDrawThree LevelSelectDrawMainMenu, LevelSelectButtonStateMainMenu, LS_MM_N_RAMG, LS_MM_H_RAMG, LS_MM_P_RAMG, LS_MM_X, LS_MM_Y, LS_MM_W, LS_MM_H, LS_HANDLE_BUTTON
                LevelSelectDrawThree LevelSelectDrawBack, LevelSelectButtonStateBack, LS_BACK_N_RAMG, LS_BACK_H_RAMG, LS_BACK_P_RAMG, LS_BACK_X, LS_BACK_Y, LS_BACK_W, LS_BACK_H, LS_HANDLE_BUTTON
                LevelSelectDrawThree LevelSelectDrawPlay, LevelSelectButtonStatePlay, LS_PLAY_N_RAMG, LS_PLAY_H_RAMG, LS_PLAY_P_RAMG, LS_PLAY_X, LS_PLAY_Y, LS_PLAY_W, LS_PLAY_H, LS_HANDLE_BUTTON
                LevelSelectDrawThree LevelSelectDrawNext, LevelSelectButtonStateNext, LS_NEXT_N_RAMG, LS_NEXT_H_RAMG, LS_NEXT_P_RAMG, LS_NEXT_X, LS_NEXT_Y, LS_NEXT_W, LS_NEXT_H, LS_HANDLE_BUTTON
                LevelSelectDrawThree LevelSelectDrawRabbit, LevelSelectBadgeStateRabbit, LS_RBT_N_RAMG, LS_RBT_H_RAMG, LS_RBT_P_RAMG, LS_RBT_X, LS_RBT_Y, LS_RBT_W, LS_RBT_H, LS_HANDLE_BADGE
                LevelSelectDrawThree LevelSelectDrawEagle, LevelSelectBadgeStateEagle, LS_EGL_N_RAMG, LS_EGL_H_RAMG, LS_EGL_P_RAMG, LS_EGL_X, LS_EGL_Y, LS_EGL_W, LS_EGL_H, LS_HANDLE_BADGE
                LevelSelectDrawThree LevelSelectDrawJaguar, LevelSelectBadgeStateJaguar, LS_JAG_N_RAMG, LS_JAG_H_RAMG, LS_JAG_P_RAMG, LS_JAG_X, LS_JAG_Y, LS_JAG_W, LS_JAG_H, LS_HANDLE_BADGE
                LevelSelectDrawThree LevelSelectDrawSunGod, LevelSelectBadgeStateSunGod, LS_SUN_N_RAMG, LS_SUN_H_RAMG, LS_SUN_P_RAMG, LS_SUN_X, LS_SUN_Y, LS_SUN_W, LS_SUN_H, LS_HANDLE_BADGE

LevelSelectDrawBackButton:
                CALL LevelSelectIsFirstLevel
                JR   Z, .disabled
                JP   LevelSelectDrawBack
.disabled:      LD   E, 96
                CALL FT.Coprocessor.ColorA
                CALL LevelSelectDrawBack
                LD   E, 255
                JP   FT.Coprocessor.ColorA

LevelSelectSkyPos:              DEFW 0                 ; позиция неба в 1/16 px (субпиксельный скролл)
; LevelSelectPreviewFrogAngle -> hoisted to loader_resident.asm (resident Core):
; the resident preview renderer reads/writes it while the gameplay overlay (#04)
; is mapped, so it can't live on this UI overlay page (#41).
LevelSelectLmbNow:              DEFB 0
LevelSelectLmbPrev:             DEFB 0
LevelSelectMainMenuClick:       DEFB 0
LevelSelectPlayClick:           DEFB 0
LevelSelectBackClick:           DEFB 0
LevelSelectNextClick:           DEFB 0
LevelSelectRabbitClick:         DEFB 0
LevelSelectEagleClick:          DEFB 0
LevelSelectJaguarClick:         DEFB 0
LevelSelectSunGodClick:         DEFB 0
LevelSelectButtonStateMainMenu: DEFB 0
LevelSelectButtonStateBack:     DEFB 0
LevelSelectButtonStatePlay:     DEFB 0
LevelSelectButtonStateNext:     DEFB 0
LevelSelectBadgeStateRabbit:    DEFB 0
LevelSelectBadgeStateEagle:     DEFB 0
LevelSelectBadgeStateJaguar:    DEFB 0
LevelSelectBadgeStateSunGod:    DEFB 0
LevelSelectKbdUpPrev:           DEFB 1   ; фронт-флаги клавиатуры (1 = гасит перенос нажатия со входа)
LevelSelectKbdDownPrev:         DEFB 1
LevelSelectKbdLeftPrev:         DEFB 1
LevelSelectKbdRightPrev:        DEFB 1
LevelSelectKbdFirePrev:         DEFB 1
LevelSelectKbdEscPrev:          DEFB 1

                endif ; _ZUMA_LEVEL_SELECT_
