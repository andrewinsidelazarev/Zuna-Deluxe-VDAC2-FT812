                ifndef _ZUMA_MENU_MAIN_
                define _ZUMA_MENU_MAIN_

; ============================================================================
; Главная FT812 menu scene. RAM_G здесь — menu-only profile; при клике Adventure
; он полностью заменяется через LoadGameplayAssets.
; ============================================================================

MENU_FG_RAMG        EQU #000000
MENU_FG_W           EQU 640
MENU_FG_H           EQU 480
MENU_FG_Z0_PAGE     EQU #70
MENU_FG_Z1_PAGE     EQU #72
MENU_FG_Z2_PAGE     EQU #74
MENU_FG_Z3_PAGE     EQU #77
MENU_FG_Z4_PAGE     EQU #7A
MENU_FG_Z0_SIZE     EQU 16454
MENU_FG_Z1_SIZE     EQU 31581
MENU_FG_Z2_SIZE     EQU 33371
MENU_FG_Z3_SIZE     EQU 34174
MENU_FG_Z4_SIZE     EQU 35338
MENU_FG_Z_CHUNK     EQU #00F000

MENU_SKY_RAMG       EQU #04B000
MENU_SKY_W          EQU 640
MENU_SKY_H          EQU 167
; Скролл неба ведём в 1/16 пикселя и рисуем субпиксельно (Vertex2f), иначе целые
; пиксели при 2/3 px/кадр давали джиттер «двинуть-двинуть-пропустить». 11/16 ≈ 0.69
; px/кадр (≈ прежние 2/3), но КОНСТАНТНЫЙ шаг = плавно.
MENU_SKY_SCROLL16   EQU 11
MENU_SKY_Z_PAGE     EQU #7D
MENU_SKY_Z_SIZE     EQU 35710

MENU_SUN_RAMG       EQU #065180
MENU_SUN_W          EQU 87
MENU_SUN_H          EQU 92
MENU_SUN_Z_PAGE     EQU #80
MENU_SUN_Z_SIZE     EQU 2290
MENU_GLOW_RAMG      EQU #0670C4
MENU_GLOW_W         EQU 210
MENU_GLOW_H         EQU 210
MENU_GLOW_Z_PAGE    EQU #81
MENU_GLOW_Z_SIZE    EQU 5468

MENU_ADV_W          EQU 163
MENU_ADV_H          EQU 92
MENU_ADV_X          EQU 453
MENU_ADV_Y          EQU 63
MENU_ADV_N_RAMG     EQU #071D08
MENU_ADV_H_RAMG     EQU #07579C
MENU_ADV_P_RAMG     EQU #079230

MENU_GAUNT_W        EQU 180
MENU_GAUNT_H        EQU 83
MENU_GAUNT_X        EQU 437
MENU_GAUNT_Y        EQU 153
MENU_GAUNT_N_RAMG   EQU #07CCC4
MENU_GAUNT_H_RAMG   EQU #080720
MENU_GAUNT_P_RAMG   EQU #08417C

MENU_OPT_W          EQU 199
MENU_OPT_H          EQU 86
MENU_OPT_X          EQU 420
MENU_OPT_Y          EQU 236
MENU_OPT_N_RAMG     EQU #087BD8
MENU_OPT_H_RAMG     EQU #08BEB4
MENU_OPT_P_RAMG     EQU #090190

MENU_MORE_W         EQU 118
MENU_MORE_H         EQU 127
MENU_MORE_X         EQU 393
MENU_MORE_Y         EQU 301
MENU_MORE_N_RAMG    EQU #09446C
MENU_MORE_H_RAMG    EQU #097EF8
MENU_MORE_P_RAMG    EQU #09B984

MENU_QUIT_W         EQU 120
MENU_QUIT_H         EQU 141
MENU_QUIT_X         EQU 495
MENU_QUIT_Y         EQU 313
MENU_QUIT_N_RAMG    EQU #09F410
MENU_QUIT_H_RAMG    EQU #0A3628
MENU_QUIT_P_RAMG    EQU #0A7840

; HD menu hit-tests игнорируют ornamental border вокруг кнопок. Мёртвая кайма
; также не даёт пересекающимся Options/More/Quit sprite rects нажимать несколько
; кнопок одной pointer position.
MENU_BUTTON_HIT_BORDER EQU 11

MENU_SKY_PAL_RAMG   EQU #0ABA60
MENU_UI_PAL_RAMG    EQU #0ABC60
MENU_CURSOR_RAMG    EQU #0AC000
MENU_CURSOR_Z_PAGE  EQU #93
MENU_CURSOR_Z_SIZE  EQU 335
MENU_SKY_PAL_PAGE   EQU #91
MENU_UI_PAL_PAGE    EQU #92

MENU_ADV_N_Z_PAGE   EQU #82
MENU_ADV_H_Z_PAGE   EQU #83
MENU_ADV_P_Z_PAGE   EQU #84
MENU_ADV_N_Z_SIZE   EQU 5864
MENU_ADV_H_Z_SIZE   EQU 6585
MENU_ADV_P_Z_SIZE   EQU 7548
MENU_GAUNT_N_Z_PAGE EQU #85
MENU_GAUNT_H_Z_PAGE EQU #86
MENU_GAUNT_P_Z_PAGE EQU #87
MENU_GAUNT_N_Z_SIZE EQU 5922
MENU_GAUNT_H_Z_SIZE EQU 6533
MENU_GAUNT_P_Z_SIZE EQU 7790
MENU_OPT_N_Z_PAGE   EQU #88
MENU_OPT_H_Z_PAGE   EQU #89
MENU_OPT_P_Z_PAGE   EQU #8A
MENU_OPT_N_Z_SIZE   EQU 6712
MENU_OPT_H_Z_SIZE   EQU 7400
MENU_OPT_P_Z_SIZE   EQU 8267
MENU_MORE_N_Z_PAGE  EQU #8B
MENU_MORE_H_Z_PAGE  EQU #8C
MENU_MORE_P_Z_PAGE  EQU #8D
MENU_MORE_N_Z_SIZE  EQU 5828
MENU_MORE_H_Z_SIZE  EQU 6286
MENU_MORE_P_Z_SIZE  EQU 7276
MENU_QUIT_N_Z_PAGE  EQU #8E
MENU_QUIT_H_Z_PAGE  EQU #8F
MENU_QUIT_P_Z_PAGE  EQU #90
MENU_QUIT_N_Z_SIZE  EQU 5871
MENU_QUIT_H_Z_SIZE  EQU 6731
MENU_QUIT_P_Z_SIZE  EQU 7767

MENU_HANDLE_SKY     EQU 0
MENU_HANDLE_FG      EQU 1
MENU_HANDLE_BUTTON  EQU 2
MENU_HANDLE_SUN     EQU 3
MENU_HANDLE_GLOW    EQU 4

MenuMain:
                CALL ClearRamGForMenu                       ; освободить RAM_G от загрузочного экрана / остатков прошлой сцены
                CALL GS_InitAndStartMenuMusic
                CALL LoadMainMenuAssets
                LD   HL, 0
                LD   (MenuSkyPos), HL                        ; позиция неба в 1/16 px
                XOR  A
                LD   (MenuLmbPrev), A
                LD   (MenuSelection), A                     ; по умолчанию выбрана Adventure (0)
                LD   (MenuInputMode), A                     ; 0=mouse, 1=keyboard
                LD   A, #FF
                LD   (MenuMouseHoverNow), A
                LD   (MenuMouseHoverPrev), A
                LD   A, 1                                   ; фронт-флаги = «нажато» -> гасим перенос
                LD   (MenuKbdUpPrev), A                     ; нажатия с предыдущей сцены (напр. Fire,
                LD   (MenuKbdDownPrev), A                   ; которым выбрали Adventure) до отпускания
                LD   (MenuKbdFirePrev), A
                CALL FadeInMenu

.loop:          CALL Input_Scan                            ; мышь + PS/2-клавиатура (глобально)
                CALL MenuUpdateButtons
                CALL MenuKeyboardNav                       ; навигация Вверх/Вниз + огонь = выбор
                LD   A, (MenuAdventureClick)
                OR   A
                JR   NZ, .start_adventure
                LD   A, (MenuGauntletClick)
                OR   A
                JR   NZ, .start_gauntlet
                LD   A, (MenuMoreClick)
                OR   A
                JR   NZ, .show_more
                LD   A, (MenuQuitClick)
                OR   A
                JP   NZ, MenuQuitToWC
                CALL MenuAdvanceSky
                CALL MenuBuildFrame
                CALL MenuSwapFrame
                JP   .loop

.start_adventure:
                JP   FadeMenuToAdventure
.start_gauntlet:
                LD   A, 1
                LD   (CurrentGameMode), A
                CALL LevelSelectClampCurrent             ; Space/22-4 re-enters Gauntlet as last selectable 21-4
                JP   FadeMenuToLevelSelect
.show_more:     JP   FadeMenuToMoreGames

FadeMenuToAdventure:
                LD   HL, Core.MenuBuildFrame
                CALL FadeOutRoom
                XOR  A
                LD   (CurrentGameMode), A
                LD   (AdventurePos), A
                LD   (CurrentDifficulty), A
                CALL Score_Reset
                JP   Core.EnterGameplayForCurrentLevel

LoadMainMenuAssets:
                ; SafeInflatePage2 держит PAGE3 на main1_play, пока source стримится через PAGE2.
                LD   B, MenuInflateAssetsCount
                LD   HL, MenuInflateAssets
                CALL MenuInflateAssetsFromTable

                LD   A, MENU_SKY_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (MENU_SKY_PAL_RAMG >> 16) & #FF
                LD   DE, MENU_SKY_PAL_RAMG & #FFFF
                CALL FT.WriteMem
                LD   A, MENU_UI_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (MENU_UI_PAL_RAMG >> 16) & #FF
                LD   DE, MENU_UI_PAL_RAMG & #FFFF
                CALL FT.WriteMem
                SetPage2 6
                SetPage3 UI_OVL_PAGE                    ; код работает на UI overlay (#41); restore его, не #04
                RET

                macro MenuInflateAsset Destination?, Page?, Size?
                DEFB (Destination?) & #FF
                DEFB ((Destination?) >> 8) & #FF
                DEFB ((Destination?) >> 16) & #FF
                DEFB (Page?) & #FF
                DEFW (Size?) & #FFFF
                endm

; Вход: B = table entries, HL = entries. Все текущие menu stream <64K и начинаются
; с source offset #0000, поэтому table хранит только RAM_G dest/page/size.
MenuInflateAssetsFromTable:
.next:          PUSH BC
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                INC  HL
                LD   A, (HL)
                INC  HL
                LD   (MenuInflateDestHi), A
                LD   A, (HL)
                INC  HL
                EX   AF, AF'
                LD   C, (HL)
                INC  HL
                LD   B, (HL)
                INC  HL
                PUSH HL
                DI
                SetPage3 UI_OVL_PAGE                    ; держать slot 3 на UI overlay code page (#41) во время inflate
                LD   HL, 0
                EXX
                LD   B, 1
                EXX
                LD   A, (MenuInflateDestHi)
                CALL SafeInflatePage2
                SetPage3 UI_OVL_PAGE                    ; restore UI overlay code page (routine работает на #41)
                EI
                POP  HL
                POP  BC
                DJNZ .next
                RET

MenuInflateAssets:
                MenuInflateAsset MENU_FG_RAMG + MENU_FG_Z_CHUNK * 0, MENU_FG_Z0_PAGE, MENU_FG_Z0_SIZE
                MenuInflateAsset MENU_FG_RAMG + MENU_FG_Z_CHUNK * 1, MENU_FG_Z1_PAGE, MENU_FG_Z1_SIZE
                MenuInflateAsset MENU_FG_RAMG + MENU_FG_Z_CHUNK * 2, MENU_FG_Z2_PAGE, MENU_FG_Z2_SIZE
                MenuInflateAsset MENU_FG_RAMG + MENU_FG_Z_CHUNK * 3, MENU_FG_Z3_PAGE, MENU_FG_Z3_SIZE
                MenuInflateAsset MENU_FG_RAMG + MENU_FG_Z_CHUNK * 4, MENU_FG_Z4_PAGE, MENU_FG_Z4_SIZE
                MenuInflateAsset MENU_SKY_RAMG, MENU_SKY_Z_PAGE, MENU_SKY_Z_SIZE
                MenuInflateAsset MENU_SUN_RAMG, MENU_SUN_Z_PAGE, MENU_SUN_Z_SIZE
                MenuInflateAsset MENU_GLOW_RAMG, MENU_GLOW_Z_PAGE, MENU_GLOW_Z_SIZE
                MenuInflateAsset MENU_ADV_N_RAMG, MENU_ADV_N_Z_PAGE, MENU_ADV_N_Z_SIZE
                MenuInflateAsset MENU_ADV_H_RAMG, MENU_ADV_H_Z_PAGE, MENU_ADV_H_Z_SIZE
                MenuInflateAsset MENU_ADV_P_RAMG, MENU_ADV_P_Z_PAGE, MENU_ADV_P_Z_SIZE
                MenuInflateAsset MENU_GAUNT_N_RAMG, MENU_GAUNT_N_Z_PAGE, MENU_GAUNT_N_Z_SIZE
                MenuInflateAsset MENU_GAUNT_H_RAMG, MENU_GAUNT_H_Z_PAGE, MENU_GAUNT_H_Z_SIZE
                MenuInflateAsset MENU_GAUNT_P_RAMG, MENU_GAUNT_P_Z_PAGE, MENU_GAUNT_P_Z_SIZE
                MenuInflateAsset MENU_OPT_N_RAMG, MENU_OPT_N_Z_PAGE, MENU_OPT_N_Z_SIZE
                MenuInflateAsset MENU_OPT_H_RAMG, MENU_OPT_H_Z_PAGE, MENU_OPT_H_Z_SIZE
                MenuInflateAsset MENU_OPT_P_RAMG, MENU_OPT_P_Z_PAGE, MENU_OPT_P_Z_SIZE
                MenuInflateAsset MENU_MORE_N_RAMG, MENU_MORE_N_Z_PAGE, MENU_MORE_N_Z_SIZE
                MenuInflateAsset MENU_MORE_H_RAMG, MENU_MORE_H_Z_PAGE, MENU_MORE_H_Z_SIZE
                MenuInflateAsset MENU_MORE_P_RAMG, MENU_MORE_P_Z_PAGE, MENU_MORE_P_Z_SIZE
                MenuInflateAsset MENU_QUIT_N_RAMG, MENU_QUIT_N_Z_PAGE, MENU_QUIT_N_Z_SIZE
                MenuInflateAsset MENU_QUIT_H_RAMG, MENU_QUIT_H_Z_PAGE, MENU_QUIT_H_Z_SIZE
                MenuInflateAsset MENU_QUIT_P_RAMG, MENU_QUIT_P_Z_PAGE, MENU_QUIT_P_Z_SIZE
                MenuInflateAsset MENU_CURSOR_RAMG, MENU_CURSOR_Z_PAGE, MENU_CURSOR_Z_SIZE
MenuInflateAssetsEnd:
MenuInflateAssetsCount EQU (MenuInflateAssetsEnd - MenuInflateAssets) / 6
MenuInflateDestHi:     DEFB 0

MenuAdvanceSky:
                ; pos += шаг (в 1/16 px); если pos >= W*16 — вычесть W*16 (плавный wrap
                ; без потери остатка). Шаг << W*16, поэтому одного вычитания хватает.
                LD   HL, (MenuSkyPos)
                LD   DE, MENU_SKY_SCROLL16 * 8 / 5     ; 1024: та же визуальная скорость
                ADD  HL, DE
                LD   DE, (MENU_SKY_W * 8 / 5) * 16     ; wrap по экранной ширине (= период копий)
                AND  A
                SBC  HL, DE
                JR   NC, .store                        ; >=0 -> wrapped, оставить остаток
                ADD  HL, DE                            ; <0  -> не дошли до края, вернуть
.store:         LD   (MenuSkyPos), HL
                ; две НЕЗАВИСИМЫЕ фазы с разной скоростью → масштаб солнца и пульс
                ; свечения расходятся (асинхронно): солнце +2 (~2 с), свечение +3 (~1.3 с).
                LD   A, (MenuSunPhase)
                ADD  A, 2
                LD   (MenuSunPhase), A
                LD   A, (MenuGlowPhase)
                ADD  A, 3
                LD   (MenuGlowPhase), A
                RET

                macro MenuCheckButton X?, Y?, W?, H?, State?, ClickVar?
                ; 1024×768: hit-box ×8/5 (мышь в экранных 1024-координатах)
                LD   BC, (X?) * 8 / 5
                LD   DE, ((X?) + (W?)) * 8 / 5
                LD   IX, (Y?) * 8 / 5
                LD   IY, ((Y?) + (H?)) * 8 / 5
                CALL MenuPointInside
                LD   A, C
                OR   A
                JR   Z, .outside?
                LD   A, (MenuLmbNow)
                OR   A
                LD   A, 1
                JR   Z, .store?
                INC  A
.store?:        LD   (State?), A
                if ClickVar?
                ; Активировать по первому press edge. Также принять release edge,
                ; чтобы press снаружи и release внутри всё равно считались click.
                LD   A, (MenuLmbNow)
                OR   A
                JR   NZ, .press_edge?
                LD   A, (MenuLmbPrev)
                CP   1
                JR   NZ, .outside?
                JR   .do_click?
.press_edge?:  LD   A, (MenuLmbPrev)
                OR   A
                JR   NZ, .outside?
.do_click?:
                LD   A, 1
                LD   (ClickVar?), A
                LD   A, SND_BUTTON1
                CALL GS_PlaySfx
                endif
.outside?:
                endm

MenuUpdateButtons:
                XOR  A
                LD   (MenuAdventureClick), A
                LD   (MenuGauntletClick), A
                LD   (MenuMoreClick), A
                LD   (MenuQuitClick), A
                LD   (MenuButtonStateAdventure), A
                LD   (MenuButtonStateGauntlet), A
                LD   (MenuButtonStateOptions), A
                LD   (MenuButtonStateMore), A
                LD   (MenuButtonStateQuit), A
                CALL Input_MouseLMB
                LD   A, 0
                JR   Z, .lmb_ready
                INC  A
.lmb_ready:     LD   (MenuLmbNow), A
                MenuCheckButton MENU_ADV_X + MENU_BUTTON_HIT_BORDER, MENU_ADV_Y + MENU_BUTTON_HIT_BORDER, MENU_ADV_W - MENU_BUTTON_HIT_BORDER * 2, MENU_ADV_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateAdventure, MenuAdventureClick
                MenuCheckButton MENU_GAUNT_X + MENU_BUTTON_HIT_BORDER, MENU_GAUNT_Y + MENU_BUTTON_HIT_BORDER, MENU_GAUNT_W - MENU_BUTTON_HIT_BORDER * 2, MENU_GAUNT_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateGauntlet, MenuGauntletClick
                MenuCheckButton MENU_OPT_X + MENU_BUTTON_HIT_BORDER, MENU_OPT_Y + MENU_BUTTON_HIT_BORDER, MENU_OPT_W - MENU_BUTTON_HIT_BORDER * 2, MENU_OPT_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateOptions, 0
                MenuCheckButton MENU_MORE_X + MENU_BUTTON_HIT_BORDER, MENU_MORE_Y + MENU_BUTTON_HIT_BORDER, MENU_MORE_W - MENU_BUTTON_HIT_BORDER * 2, MENU_MORE_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateMore, MenuMoreClick
                ; Quit временно неактивен: не даём hover/click мышью.
                CALL MenuUpdateHoverFocus
                LD   A, (MenuLmbNow)
                LD   (MenuLmbPrev), A
                RET

MenuUpdateHoverFocus:
                LD   A, #FF
                LD   (MenuMouseHoverNow), A
                LD   A, (MenuButtonStateAdventure)
                OR   A
                JR   Z, .hf_gaunt
                XOR  A
                LD   (MenuMouseHoverNow), A                 ; 0=Adventure
                JR   .hf_ready
.hf_gaunt:      LD   A, (MenuButtonStateGauntlet)
                OR   A
                JR   Z, .hf_opt
                LD   A, 1
                LD   (MenuMouseHoverNow), A                 ; 1=Gauntlet
                JR   .hf_ready
.hf_opt:        LD   A, (MenuButtonStateOptions)
                OR   A
                JR   Z, .hf_more
                LD   A, 3
                LD   (MenuMouseHoverNow), A                 ; 3=Options (not keyboard-navigable)
                JR   .hf_ready
.hf_more:       LD   A, (MenuButtonStateMore)
                OR   A
                JR   Z, .hf_ready
                LD   A, 2
                LD   (MenuMouseHoverNow), A                 ; 2=More
.hf_ready:      LD   A, (MenuMouseHoverNow)
                LD   B, A
                LD   A, (MenuMouseHoverPrev)
                CP   B
                JR   Z, .hf_lmb
                LD   A, B
                LD   (MenuMouseHoverPrev), A
                CP   #FF
                JR   Z, .hf_lmb
                XOR  A
                LD   (MenuInputMode), A                     ; вход на другую кнопку отдаёт focus мыши
.hf_lmb:        LD   A, (MenuLmbNow)
                OR   A
                JR   Z, .hf_mode
                XOR  A
                LD   (MenuInputMode), A                     ; LMB отдаёт focus мыши даже без hover change
.hf_mode:       LD   A, (MenuInputMode)
                OR   A
                JP   NZ, MenuClearButtonStates              ; keyboard focus: неподвижный cursor не владеет hover
                LD   A, (MenuMouseHoverNow)
                CP   0
                JR   NZ, .hf_not_adv
                LD   (MenuSelection), A                     ; 0=Adventure
                RET
.hf_not_adv:    CP   1
                JR   NZ, .hf_not_gaunt
                LD   (MenuSelection), A                     ; 1=Gauntlet
                RET
.hf_not_gaunt:  CP   2
                RET  NZ
                LD   (MenuSelection), A                     ; 2=More
                RET

; ----------------------------------------------------------------------------
; Клавиатурная навигация главного меню. Активные кнопки (порядок навигации):
;   0 = Adventure, 1 = Gauntlet, 2 = More (Options/Quit без действия — пропущены).
; Вверх/Вниз ходят по списку (по просьбе юзера ТОЛЬКО Вверх/Вниз — Влево/Вправо в
;   этом меню НЕ участвуют). Огонь = нажатие текущей кнопки (тот же Click-флаг, что
;   и мышь).
; Зовётся ПОСЛЕ MenuUpdateButtons (тот сбросил Click-флаги и проставил hover мышью).
; ----------------------------------------------------------------------------
MenuKeyboardNav:
                ; nav-вверх = Up
                LD   A, (Input_EvUp)
                OR   A
                JR   Z, .up_level
                LD   (MenuKbdUpPrev), A
                JR   .up_step
.up_level:      CALL Input_Up
                LD   HL, MenuKbdUpPrev
                CALL Input_EdgeZ
                JR   Z, .chk_down
.up_step:
                CALL MenuKeyboardTakeFocus
                LD   A, (MenuSelection)
                OR   A
                JR   Z, .chk_down                          ; уже на верхней (Adventure)
                DEC  A
                LD   (MenuSelection), A
                CALL MenuButtonSfx
.chk_down:      ; nav-вниз = Down
                LD   A, (Input_EvDown)
                OR   A
                JR   Z, .down_level
                LD   (MenuKbdDownPrev), A
                JR   .down_step
.down_level:    CALL Input_Down
                LD   HL, MenuKbdDownPrev
                CALL Input_EdgeZ
                JR   Z, .highlight
.down_step:
                CALL MenuKeyboardTakeFocus
                LD   A, (MenuSelection)
                CP   2
                JR   NC, .highlight                        ; уже на нижней активной (More)
                INC  A
                LD   (MenuSelection), A
                CALL MenuButtonSfx
.highlight:     CALL MenuHighlightSelection
                ; огонь = выбор текущей кнопки
                LD   A, (Input_EvFireKey)
                OR   A
                JR   Z, .fire_level
                LD   (MenuKbdFirePrev), A
                JR   .fire_step
.fire_level:    CALL Input_FireKey
                LD   HL, MenuKbdFirePrev
                CALL Input_EdgeZ
                RET  Z
.fire_step:
                CALL MenuKeyboardTakeFocus
                LD   A, (MenuSelection)
                OR   A
                JR   NZ, .not_adv
                LD   A, 1 : LD (MenuAdventureClick), A : JP MenuButtonSfx
.not_adv:       CP   1
                JR   NZ, .not_gaunt
                LD   A, 1 : LD (MenuGauntletClick), A : JP MenuButtonSfx
.not_gaunt:     CP   2
                RET  NZ
                LD   A, 1 : LD (MenuMoreClick), A
                JP   MenuButtonSfx

MenuButtonSfx:
                LD   A, SND_BUTTON1
                JP   GS_PlaySfx

MenuKeyboardTakeFocus:
                LD   A, 1
                LD   (MenuInputMode), A
                JP   MenuClearButtonStates

MenuClearButtonStates:
                XOR  A
                LD   (MenuButtonStateAdventure), A
                LD   (MenuButtonStateGauntlet), A
                LD   (MenuButtonStateOptions), A
                LD   (MenuButtonStateMore), A
                LD   (MenuButtonStateQuit), A
                RET

; Подсветить клавиатурный выбор только если мышь не на кнопке.
; Если любой MenuButtonState* != 0 — мышь активна, keyboard hover не показываем.
; MenuButtonState* лежат подряд: Adventure, Gauntlet, Options, More, Quit (5 байт).
MenuHighlightSelection:
                LD   HL, MenuButtonStateAdventure
                LD   B, 5
.any_hover:     LD   A, (HL)
                OR   A
                RET  NZ                                    ; мышь на кнопке — не трогаем
                INC  HL
                DJNZ .any_hover
                ; мышь нигде — подсветить текущий keyboard selection
                LD   A, (MenuSelection)
                OR   A
                JR   NZ, .hs_not0
                LD   A, 1
                LD   (MenuButtonStateAdventure), A         ; 0=Adventure
                RET
.hs_not0:       CP   1
                JR   NZ, .hs_not1
                LD   A, 1
                LD   (MenuButtonStateGauntlet), A          ; 1=Gauntlet
                RET
.hs_not1:       CP   2
                RET  NZ
                LD   A, 1
                LD   (MenuButtonStateMore), A              ; 2=More
                RET

MenuBuildFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                CALL MenuDrawSky
                CALL MenuDrawForeground
                CALL MenuDrawButtons
                CALL MenuDrawSun
                CALL MenuDrawCredit
                CALL MenuDrawCursor
                CALL DrawFadeOverlay
                FT_End
                FT_Display
                FT_CMD_Count
                RET

MenuDrawCredit:
                ; "Italy, 2026" — на месте игровых часов (45,712), тот же ROM font 26
                ; native: свой сброс матрицы (кадр меню идёт под scale 1.6), после —
                ; вернуть 1.6 для курсора.
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_Text 45, 712, 26, 0
                LD   HL, .txt
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 12
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                JP   Core.Resident_EmitScale16
.txt:           DB   "Italy, 2026", 0                  ; 11+NUL = 12 байт — ровно 3 CMD-слова

MenuSwapFrame:
                CALL Core.AY_Game.AY_Update
                ; UI frame pacing: сначала строим frame, затем submit сразу после
                ; следующего FT812 swap event, когда edge доступен.
                ; Ожидание bounded: после static screen (More Games) или потерянного
                ; clear-on-read INT edge бесконечное ожидание здесь замораживает
                ; transition. Fallback на DLSWAP==0 сохраняет старый безопасный путь.
                ;
                ; Держать чтения INT_FLAGS централизованно здесь. На реальном FT812
                ; чтение очищает flag; write ниже нужен для Unreal, где очистка
                ; по записи. DrawBlackTransitionFrame ждёт только DLSWAP, поэтому
                ; не потребляет второй INT_SWAP event.
.wait_int_init:
                LD   L, 64
.wait_int:      FT_RD_REG8 FT_REG_INT_FLAGS
                AND  FT_INT_SWAP
                JR   NZ, .got_int
                DEC  L
                JR   NZ, .wait_int
                JR   .wait_swap_init
.got_int:
                FT_WR_REG8 FT_REG_INT_FLAGS, FT_INT_SWAP
.wait_swap_init:
                LD   L, 64
.wait_swap:     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   Z, .submit
                DEC  L
                JR   NZ, .wait_swap
.submit:
                CALL Core.ZL_FT_CMD_Write_DMA
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

; ----------------------------------------------------------------------------
; ClearRamDlForShortUiFrame — короткие статичные DL оставляют хвост RAM_DL от
; предыдущего длинного кадра. FT812 останавливается на DISPLAY, но валидатор
; Unreal читает дальше и может попасть на старый CALL/JUMP. Перед short-DL
; переходом затираем весь RAM_DL прямой SPI-записью; после этого coprocessor
; перезапишет начало новым кадром, а хвост останется DISPLAY(0).
; ----------------------------------------------------------------------------
ClearRamDlForShortUiFrame:
                LD   DE, 0
                LD   B, 8                              ; 8192 / 1024
.clear_loop:    PUSH BC
                LD   HL, Core.ClearRamGZeroBuf
                LD   BC, 1024
                CALL FT.WriteDL                        ; advances RAM_DL offset in DE
                POP  BC
                DJNZ .clear_loop
                RET

MenuDrawSky:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                ; 1024×768: scale(1.6)-матрица на кадр (fg/кнопки наследуют);
                ; небо BILINEAR (решение юзера для level-select — консистентно).
                CALL Core.Resident_EmitScale16
                FT_Begin FT_BITMAPS
                FT_PaletteSource MENU_SKY_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_SKY
                ; NEAREST (решение юзера): BILINEAR-края окна полупрозрачны (BORDER),
                ; и стык двух копий неизбежно просвечивал чёрным; у NEAREST стык глухой.
                FT_BitmapSource MENU_SKY_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_SKY_W, MENU_SKY_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_SKY_W * 8 / 5, MENU_SKY_H * 8 / 5
                ; MenuSkyPos уже в 1/16 px ЭКРАННЫХ — рисуем напрямую.
                LD   BC, (MenuSkyPos)
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; wrap-копия слева: x = pos − (экранная ширина − 1) px (схема 640-оригинала)
                LD   HL, (MenuSkyPos)
                LD   DE, -((MENU_SKY_W * 8 / 5 - 1) * 16)
                ADD  HL, DE
                LD   B, H : LD C, L
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

MenuDrawForeground:
                FT_PaletteSource MENU_UI_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_FG
                FT_BitmapSource MENU_FG_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_FG_W, MENU_FG_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_FG_W * 8 / 5, MENU_FG_H * 8 / 5
                LD   BC, 0
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

MenuDrawButtons:
                FT_PaletteSource MENU_UI_PAL_RAMG
                CALL MenuDrawAdventure
                CALL MenuDrawGauntlet
                CALL MenuDrawOptions
                CALL MenuDrawMore
                JP   MenuDrawQuit

MenuDrawSun:
                ; Солнце и свечение — отдельные спрайты поверх фона. Анимация по фазе
                ; MenuSunPhase: солнце плавно «дышит» масштабом (cmd_scale), свечение —
                ; пульс alpha. Значения считаем В ПАМЯТЬ заранее (макросы FT_Bitmap*
                ; клобают BCDE).
                ; alpha свечения = 150 + sin(GlowPhase)>>2 → 119..181 (своя фаза/скорость)
                LD   A, (MenuGlowPhase)
                LD   B, 2
                CALL MenuSinShiftHL
                LD   A, L
                ADD  A, 150
                LD   (MenuGlowAlpha), A
                ; 1024×768: масштаб солнца 16.16 на базе 1.6, ТОЛЬКО уменьшение:
                ;   s = 1.6 + (sin-127)*13/65536 → s ∈ [1.550 .. 1.6] (та же глубина
                ;   дыхания ±3.1%, что и было на базе 1.0: offset ×13 ≈ ×8×1.6).
                ;   Только shrink — у спрайта солнца НЕТ прозрачных полей (лучи до
                ;   краёв), при увеличении лучи бы обрезались фиксированным BITMAP_SIZE.
                ;   offset ∈ [-3302..0] не андерфлоит #999A → ScaleHi = 1 ВСЕГДА.
                LD   A, (MenuSunPhase)
                LD   E, A : LD D, 0
                LD   HL, MenuSunSinTable
                ADD  HL, DE
                LD   A, (HL)                            ; A = sin(phase), signed
                LD   L, A : ADD A, A : SBC A, A : LD H, A   ; HL = sign-extended sin (-128..127)
                LD   DE, -127
                ADD  HL, DE                             ; HL = sin - 127  (-254..0)
                LD   D, H : LD E, L                     ; DE = x
                ADD  HL, HL                             ; 2x
                ADD  HL, DE                             ; 3x
                ADD  HL, HL                             ; 6x
                ADD  HL, HL                             ; 12x
                ADD  HL, DE                             ; HL = (sin-127)*13 (offset, -3302..0)
                LD   DE, #999A                          ; дробная часть 1.6 (0x0001999A)
                ADD  HL, DE
                LD   (MenuSunScaleLo), HL
                LD   HL, 1
                LD   (MenuSunScaleHi), HL

                ; --- матрица масштаба для солнца (cmd_loadidentity; cmd_scale sx,sy; cmd_setmatrix) ---
                CALL Core.ZL_EmitLoadId
                LD   BC, FT_CMD_SCALE >> 16
                LD   DE, FT_CMD_SCALE & #FFFF
                CALL FT.Coprocessor.Command_BCDE
                LD   BC, (MenuSunScaleHi)
                LD   DE, (MenuSunScaleLo)
                CALL FT.Coprocessor.Command_BCDE        ; sx
                LD   BC, (MenuSunScaleHi)
                LD   DE, (MenuSunScaleLo)
                CALL FT.Coprocessor.Command_BCDE        ; sy
                CALL Core.ZL_EmitSetMatrix

                ; --- солнце (масштабируется матрицей), позиция фиксирована ---
                ; 1024×768: окно ×8/5, позиция (−1,11)×1.6 → (−2,18)
                FT_PaletteSource MENU_UI_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_SUN
                FT_BitmapSource MENU_SUN_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_SUN_W, MENU_SUN_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_SUN_W * 8 / 5, MENU_SUN_H * 8 / 5
                LD   BC, -2 * 16
                LD   DE, 18 * 16
                CALL FT.Coprocessor.Vertex2f

                ; --- матрица обратно в чистую 1.6: свечение/курсор тоже ×1.6 ---
                CALL Core.Resident_EmitScale16

                ; --- свечение: фикс. позиция, пульсирующая alpha (тинт оранжевый) ---
                ; 1024×768: окно ×8/5, позиция (−61,−45)×1.6 → (−98,−72)
                LD   C, 255 : LD D, 192 : LD E, 0
                CALL FT.Coprocessor.ColorRGB
                LD   A, (MenuGlowAlpha)
                LD   E, A
                CALL FT.Coprocessor.ColorA
                FT_BitmapHandle MENU_HANDLE_GLOW
                FT_BitmapSource MENU_GLOW_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_GLOW_W, MENU_GLOW_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_GLOW_W * 8 / 5, MENU_GLOW_H * 8 / 5
                LD   BC, -98 * 16
                LD   DE, -72 * 16
                CALL FT.Coprocessor.Vertex2f

                ; reset color/alpha → белый непрозрачный (для последующих рисовалок)
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                JP   FT.Coprocessor.ColorA

; MenuSinShiftHL — HL = sign-extend( MenuSunSinTable[A] >> B ).  A=индекс фазы (0..255),
; B=кол-во арифм. сдвигов вправо (>=1). Таблица локальная (overlay #41), т.к. меню НЕ
; видит gameplay-овский Frog_SinTable (#04). Клобает AF, DE, B, HL.
MenuSinShiftHL:
                LD   E, A
                LD   D, 0
                LD   HL, MenuSunSinTable
                ADD  HL, DE
                LD   A, (HL)
.mss_shift:     SRA  A
                DJNZ .mss_shift
                LD   L, A                              ; младший байт
                ADD  A, A                              ; CF = знак
                SBC  A, A                              ; A = #FF (отриц.) / #00 (полож.)
                LD   H, A
                RET

; sin(i*2π/256)*127, signed byte (two's-complement), i=0..255. Копия Frog_SinTable,
; но в UI-overlay (#41) — доступна из меню/выбора уровня без свопа страницы.
MenuSunSinTable:
                DB   0,   3,   6,   9,  12,  16,  19,  22,  25,  28,  31,  34,  37,  40,  43,  46
                DB  49,  51,  54,  57,  60,  63,  65,  68,  71,  73,  76,  78,  81,  83,  85,  88
                DB  90,  92,  94,  96,  98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116
                DB 117, 118, 120, 121, 122, 122, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127
                DB 127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 122, 122, 121, 120, 118
                DB 117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100,  98,  96,  94,  92
                DB  90,  88,  85,  83,  81,  78,  76,  73,  71,  68,  65,  63,  60,  57,  54,  51
                DB  49,  46,  43,  40,  37,  34,  31,  28,  25,  22,  19,  16,  12,   9,   6,   3
                DB   0, 253, 250, 247, 244, 240, 237, 234, 231, 228, 225, 222, 219, 216, 213, 210
                DB 207, 205, 202, 199, 196, 193, 191, 188, 185, 183, 180, 178, 175, 173, 171, 168
                DB 166, 164, 162, 160, 158, 156, 154, 152, 150, 149, 147, 145, 144, 143, 141, 140
                DB 139, 138, 136, 135, 134, 134, 133, 132, 131, 131, 130, 130, 130, 129, 129, 129
                DB 129, 129, 129, 129, 130, 130, 130, 131, 131, 132, 133, 134, 134, 135, 136, 138
                DB 139, 140, 141, 143, 144, 145, 147, 149, 150, 152, 154, 156, 158, 160, 162, 164
                DB 166, 168, 171, 173, 175, 178, 180, 183, 185, 188, 191, 193, 196, 199, 202, 205
                DB 207, 210, 213, 216, 219, 222, 225, 228, 231, 234, 237, 240, 244, 247, 250, 253

MenuDrawCursor:
                FT_BitmapHandle 7
                FT_BitmapSource MENU_CURSOR_RAMG
                FT_BitmapLayout FT_ARGB4, CURSOR_W * 2, CURSOR_H
                ; Окно = DRAW (38): и меню, и level-select рисуют кадр при
                ; scale(1.6)-матрице → курсор 38px (24×8/5), позиция = мышь (1024).
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, CURSOR_DRAW, CURSOR_DRAW
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, CURSOR_TIP_X
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, CURSOR_TIP_Y
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL
                EX   DE, HL
                JP   FT.Coprocessor.Vertex2f

MenuPointInside:
                ; Вход: BC=x0, DE=x1, IX=y0, IY=y1. Выход: C=1 внутри, C=0 снаружи.
                LD   HL, (Input.Mouse.PositionX)
                AND  A
                SBC  HL, BC
                JR   C, .out
                LD   HL, (Input.Mouse.PositionX)
                AND  A
                SBC  HL, DE
                JR   NC, .out
                PUSH IX
                POP  DE
                LD   HL, (Input.Mouse.PositionY)
                AND  A
                SBC  HL, DE
                JR   C, .out
                PUSH IY
                POP  DE
                LD   HL, (Input.Mouse.PositionY)
                AND  A
                SBC  HL, DE
                JR   NC, .out
                LD   C, 1
                RET
.out:           LD   C, 0
                RET

                macro MenuDrawOne Name?, State?, Normal?, Hover?, Pressed?, X?, Y?, W?, H?
Name?:          FT_BitmapHandle MENU_HANDLE_BUTTON
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
                ; 1024×768: окно и позиция ×8/5 (scale-матрица кадра растягивает
                ; только выборку атласа; vertex — экранные 1024-координаты)
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, W? * 8 / 5, H? * 8 / 5
                LD   BC, (X? * 8 / 5) * 16
                LD   DE, (Y? * 8 / 5) * 16
                JP   FT.Coprocessor.Vertex2f
                endm

                MenuDrawOne MenuDrawAdventure, MenuButtonStateAdventure, MENU_ADV_N_RAMG, MENU_ADV_H_RAMG, MENU_ADV_P_RAMG, MENU_ADV_X, MENU_ADV_Y, MENU_ADV_W, MENU_ADV_H
                MenuDrawOne MenuDrawGauntlet, MenuButtonStateGauntlet, MENU_GAUNT_N_RAMG, MENU_GAUNT_H_RAMG, MENU_GAUNT_P_RAMG, MENU_GAUNT_X, MENU_GAUNT_Y, MENU_GAUNT_W, MENU_GAUNT_H
                MenuDrawOne MenuDrawOptions, MenuButtonStateOptions, MENU_OPT_N_RAMG, MENU_OPT_H_RAMG, MENU_OPT_P_RAMG, MENU_OPT_X, MENU_OPT_Y, MENU_OPT_W, MENU_OPT_H
                MenuDrawOne MenuDrawMore, MenuButtonStateMore, MENU_MORE_N_RAMG, MENU_MORE_H_RAMG, MENU_MORE_P_RAMG, MENU_MORE_X, MENU_MORE_Y, MENU_MORE_W, MENU_MORE_H
                MenuDrawOne MenuDrawQuit, MenuButtonStateQuit, MENU_QUIT_N_RAMG, MENU_QUIT_H_RAMG, MENU_QUIT_P_RAMG, MENU_QUIT_X, MENU_QUIT_Y, MENU_QUIT_W, MENU_QUIT_H

MenuSkyPos:               DEFW 0                        ; позиция неба в 1/16 px (субпиксельный скролл)
MenuSunPhase:             DEFB 0                        ; фаза масштаба солнца (+2/кадр)
MenuGlowPhase:            DEFB 0                        ; фаза пульса свечения (+3/кадр — иная скорость → асинхронно)
MenuSunScaleLo:           DEFW 0                        ; масштаб солнца 16.16 — младшее слово
MenuSunScaleHi:           DEFW 0                        ; масштаб солнца 16.16 — старшее слово (0/1)
MenuGlowAlpha:            DEFB 0                        ; пульсирующая alpha свечения
MenuLmbNow:               DEFB 0
MenuLmbPrev:              DEFB 0
MenuMouseHoverNow:        DEFB #FF
MenuMouseHoverPrev:       DEFB #FF
MenuInputMode:            DEFB 0   ; 0=mouse hover/click owns focus, 1=keyboard owns focus
MenuAdventureClick:       DEFB 0
MenuGauntletClick:        DEFB 0
MenuMoreClick:            DEFB 0
MenuQuitClick:            DEFB 0
MenuButtonStateAdventure: DEFB 0
MenuButtonStateGauntlet:  DEFB 0
MenuButtonStateOptions:   DEFB 0
MenuButtonStateMore:      DEFB 0
MenuButtonStateQuit:      DEFB 0
MenuSelection:            DEFB 0   ; выбранная клавиатурой кнопка: 0=Adventure,1=Gauntlet,2=More
MenuKbdUpPrev:            DEFB 1   ; фронт-флаги навигации (1 на старте = гасит перенос нажатия)
MenuKbdDownPrev:          DEFB 1
MenuKbdFirePrev:          DEFB 1

                endif ; _ZUMA_MENU_MAIN_
