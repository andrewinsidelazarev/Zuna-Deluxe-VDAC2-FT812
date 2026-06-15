                ifndef _ZUMA_MENU_MAIN_
                define _ZUMA_MENU_MAIN_

; ============================================================================
; Main FT812 menu scene. RAM_G contents are a menu-only profile and are replaced
; by LoadGameplayAssets when Adventure is clicked.
; ============================================================================

MENU_FG_RAMG        EQU #000000
MENU_FG_W           EQU 640
MENU_FG_H           EQU 480
MENU_FG_Z0_PAGE     EQU #70
MENU_FG_Z1_PAGE     EQU #72
MENU_FG_Z2_PAGE     EQU #74
MENU_FG_Z3_PAGE     EQU #77
MENU_FG_Z4_PAGE     EQU #7A
MENU_FG_Z0_SIZE     EQU 16295
MENU_FG_Z1_SIZE     EQU 31376
MENU_FG_Z2_SIZE     EQU 33457
MENU_FG_Z3_SIZE     EQU 34172
MENU_FG_Z4_SIZE     EQU 35375
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
MENU_SUN_Z_SIZE     EQU 2175
MENU_GLOW_RAMG      EQU #0670C4
MENU_GLOW_W         EQU 210
MENU_GLOW_H         EQU 210
MENU_GLOW_Z_PAGE    EQU #81
MENU_GLOW_Z_SIZE    EQU 6057

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

; HD menu hit-tests ignore the ornament border around each button. Keeping the
; dead border also prevents overlapping Options/More/Quit sprite rects from
; pressing several buttons at one pointer position.
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
MENU_ADV_N_Z_SIZE   EQU 5600
MENU_ADV_H_Z_SIZE   EQU 6360
MENU_ADV_P_Z_SIZE   EQU 7445
MENU_GAUNT_N_Z_PAGE EQU #85
MENU_GAUNT_H_Z_PAGE EQU #86
MENU_GAUNT_P_Z_PAGE EQU #87
MENU_GAUNT_N_Z_SIZE EQU 5321
MENU_GAUNT_H_Z_SIZE EQU 5321
MENU_GAUNT_P_Z_SIZE EQU 5321
MENU_OPT_N_Z_PAGE   EQU #88
MENU_OPT_H_Z_PAGE   EQU #89
MENU_OPT_P_Z_PAGE   EQU #8A
MENU_OPT_N_Z_SIZE   EQU 6172
MENU_OPT_H_Z_SIZE   EQU 6892
MENU_OPT_P_Z_SIZE   EQU 8055
MENU_MORE_N_Z_PAGE  EQU #8B
MENU_MORE_H_Z_PAGE  EQU #8C
MENU_MORE_P_Z_PAGE  EQU #8D
MENU_MORE_N_Z_SIZE  EQU 5491
MENU_MORE_H_Z_SIZE  EQU 5908
MENU_MORE_P_Z_SIZE  EQU 7005
MENU_QUIT_N_Z_PAGE  EQU #8E
MENU_QUIT_H_Z_PAGE  EQU #8F
MENU_QUIT_P_Z_PAGE  EQU #90
MENU_QUIT_N_Z_SIZE  EQU 5525
MENU_QUIT_H_Z_SIZE  EQU 6171
MENU_QUIT_P_Z_SIZE  EQU 7505

MENU_HANDLE_SKY     EQU 0
MENU_HANDLE_FG      EQU 1
MENU_HANDLE_BUTTON  EQU 2
MENU_HANDLE_SUN     EQU 3
MENU_HANDLE_GLOW    EQU 4

MenuMain:
                CALL GS_InitAndStartMenuMusic
                CALL LoadMainMenuAssets
                CALL GS_PlayMenuMusic
                LD   HL, 0
                LD   (MenuSkyPos), HL                        ; позиция неба в 1/16 px
                XOR  A
                LD   (MenuLmbPrev), A
                LD   (MenuSelection), A                     ; по умолчанию выбрана Adventure (0)
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
                JR   NZ, .start_game
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

.start_game:    JP   FadeMenuToLevelSelect
.show_more:     JP   FadeMenuToMoreGames

LoadMainMenuAssets:
                ; SafeInflatePage2 keeps PAGE3 on main1_play while streaming source via PAGE2.
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
                SetPage3 UI_OVL_PAGE                    ; this code runs on the UI overlay (#41); restore it, not #04
                RET

                macro MenuInflateAsset Destination?, Page?, Size?
                DEFB (Destination?) & #FF
                DEFB ((Destination?) >> 8) & #FF
                DEFB ((Destination?) >> 16) & #FF
                DEFB (Page?) & #FF
                DEFW (Size?) & #FFFF
                endm

; In: B = table entries, HL = entries. Every current menu stream is <64K and
; starts at source offset #0000, so the table keeps only RAM_G dest/page/size.
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
                SetPage3 UI_OVL_PAGE                    ; keep slot 3 on the UI overlay code page (#41) across inflate
                LD   HL, 0
                EXX
                LD   B, 1
                EXX
                LD   A, (MenuInflateDestHi)
                CALL SafeInflatePage2
                SetPage3 UI_OVL_PAGE                    ; restore UI overlay code page (this routine runs on #41)
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
                LD   DE, MENU_SKY_SCROLL16
                ADD  HL, DE
                LD   DE, MENU_SKY_W * 16
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
                LD   BC, X?
                LD   DE, X? + W?
                LD   IX, Y?
                LD   IY, Y? + H?
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
                CP   1
                JR   NZ, .outside?
                LD   A, (MenuLmbPrev)
                CP   1
                JR   NZ, .outside?
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
                LD   (MenuMoreClick), A
                LD   (MenuQuitClick), A
                LD   (MenuButtonStateAdventure), A
                LD   (MenuButtonStateGauntlet), A
                LD   (MenuButtonStateOptions), A
                LD   (MenuButtonStateMore), A
                LD   (MenuButtonStateQuit), A
                LD   A, Input.Mouse.SVK_LBUTTON
                CALL Input.Mouse.KeyState
                LD   A, 0
                JR   Z, .lmb_ready
                INC  A
.lmb_ready:     LD   (MenuLmbNow), A
                MenuCheckButton MENU_ADV_X + MENU_BUTTON_HIT_BORDER, MENU_ADV_Y + MENU_BUTTON_HIT_BORDER, MENU_ADV_W - MENU_BUTTON_HIT_BORDER * 2, MENU_ADV_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateAdventure, MenuAdventureClick
                ; Gauntlet disabled — no hit-test, always normal (gray) state.
                MenuCheckButton MENU_OPT_X + MENU_BUTTON_HIT_BORDER, MENU_OPT_Y + MENU_BUTTON_HIT_BORDER, MENU_OPT_W - MENU_BUTTON_HIT_BORDER * 2, MENU_OPT_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateOptions, 0
                MenuCheckButton MENU_MORE_X + MENU_BUTTON_HIT_BORDER, MENU_MORE_Y + MENU_BUTTON_HIT_BORDER, MENU_MORE_W - MENU_BUTTON_HIT_BORDER * 2, MENU_MORE_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateMore, MenuMoreClick
                ; Quit временно неактивен: не даём hover/click мышью.
                LD   A, (MenuLmbNow)
                LD   (MenuLmbPrev), A
                RET

; ----------------------------------------------------------------------------
; Клавиатурная навигация главного меню. Активные кнопки (порядок навигации):
;   0 = Adventure, 1 = More (Gauntlet/Options/Quit без действия — пропущены).
; Вверх/Вниз ходят по списку (по просьбе юзера ТОЛЬКО Вверх/Вниз — Влево/Вправо в
;   этом меню НЕ участвуют). Огонь = нажатие текущей кнопки (тот же Click-флаг, что
;   и мышь).
; Зовётся ПОСЛЕ MenuUpdateButtons (тот сбросил Click-флаги и проставил hover мышью).
; ----------------------------------------------------------------------------
MenuKeyboardNav:
                ; nav-вверх = Up
                CALL Input_Up
                LD   HL, MenuKbdUpPrev
                CALL Input_EdgeZ
                JR   Z, .chk_down
                LD   A, (MenuSelection)
                OR   A
                JR   Z, .chk_down                          ; уже на верхней (Adventure)
                DEC  A
                LD   (MenuSelection), A
.chk_down:      ; nav-вниз = Down
                CALL Input_Down
                LD   HL, MenuKbdDownPrev
                CALL Input_EdgeZ
                JR   Z, .highlight
                LD   A, (MenuSelection)
                CP   1
                JR   NC, .highlight                        ; уже на нижней активной (More)
                INC  A
                LD   (MenuSelection), A
.highlight:     CALL MenuHighlightSelection
                ; огонь = выбор текущей кнопки
                CALL Input_FireKey
                LD   HL, MenuKbdFirePrev
                CALL Input_EdgeZ
                RET  Z
                LD   A, (MenuSelection)
                OR   A
                JR   NZ, .not_adv
                LD   A, 1 : LD (MenuAdventureClick), A : RET
.not_adv:       CP   1
                RET  NZ
                LD   A, 1 : LD (MenuMoreClick), A
                RET

; Подсветить выбранную с клавиатуры кнопку (state=hover), если мышь её не трогает.
MenuHighlightSelection:
                LD   A, (MenuSelection)
                OR   A
                JR   NZ, .not0
                LD   HL, MenuButtonStateAdventure
                JR   .apply
.not0:          CP   1
                RET  NZ
                LD   HL, MenuButtonStateMore
                JR   .apply
.apply:         LD   A, (HL)
                OR   A
                RET  NZ                                    ; мышь уже навела/жмёт — не трогаем
                LD   (HL), 1                               ; hover
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
                CALL MenuDrawCursor
                CALL DrawFadeOverlay
                FT_End
                FT_Display
                FT_CMD_Count
                RET

MenuSwapFrame:
.wait_swap:     FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .wait_swap
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

MenuDrawSky:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_BITMAPS
                FT_PaletteSource MENU_SKY_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_SKY
                FT_BitmapSource MENU_SKY_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_SKY_W, MENU_SKY_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_SKY_W, MENU_SKY_H
                ; MenuSkyPos уже в 1/16 px — рисуем напрямую (субпиксельно).
                LD   BC, (MenuSkyPos)
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; wrap-копия слева: x = pos - 639 px (= pos16 - 639*16)
                LD   HL, (MenuSkyPos)
                LD   DE, -(639 * 16)
                ADD  HL, DE
                LD   B, H : LD C, L
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

MenuDrawForeground:
                FT_PaletteSource MENU_UI_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_FG
                FT_BitmapSource MENU_FG_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_FG_W, MENU_FG_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_FG_W, MENU_FG_H
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
                ; масштаб солнца 16.16, ТОЛЬКО уменьшение: s = 1.0 + (sin-127)*8/65536
                ;   → s ∈ [0.969 .. 1.0] (±0..3.1%). Только shrink — у спрайта солнца НЕТ
                ;   прозрачных полей (лучи до краёв), при увеличении лучи бы обрезались
                ;   фиксированным BITMAP_SIZE. Уменьшение безопасно (внутри рамки, по краям
                ;   прозрачно). offset = (sin-127)*8 ≤ 0; scale = #00010000 + offset, т.е.
                ;   scaleLo = offset(как есть), scaleHi = 1 только при offset==0 иначе 0.
                LD   A, (MenuSunPhase)
                LD   E, A : LD D, 0
                LD   HL, MenuSunSinTable
                ADD  HL, DE
                LD   A, (HL)                            ; A = sin(phase), signed
                LD   L, A : ADD A, A : SBC A, A : LD H, A   ; HL = sign-extended sin (-128..127)
                LD   DE, -127
                ADD  HL, DE                             ; HL = sin - 127  (-254..0)
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; HL = (sin-127)*8  (offset, -2032..0)
                LD   (MenuSunScaleLo), HL
                LD   A, 1
                BIT  7, H
                JR   Z, .scale_hi                       ; H bit7=0 → offset==0 → Hi=1 (s=1.0)
                DEC  A                                  ; offset<0 → Hi=0 (s<1.0)
.scale_hi:      LD   L, A : LD H, 0
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
                FT_PaletteSource MENU_UI_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_SUN
                FT_BitmapSource MENU_SUN_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_SUN_W, MENU_SUN_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_SUN_W, MENU_SUN_H
                LD   BC, -1 * 16
                LD   DE, 11 * 16
                CALL FT.Coprocessor.Vertex2f

                ; --- СБРОС матрицы в identity: свечение/курсор/прочее НЕ масштабируем ---
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix

                ; --- свечение: фикс. позиция, пульсирующая alpha (тинт оранжевый) ---
                LD   C, 255 : LD D, 192 : LD E, 0
                CALL FT.Coprocessor.ColorRGB
                LD   A, (MenuGlowAlpha)
                LD   E, A
                CALL FT.Coprocessor.ColorA
                FT_BitmapHandle MENU_HANDLE_GLOW
                FT_BitmapSource MENU_GLOW_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_GLOW_W, MENU_GLOW_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_GLOW_W, MENU_GLOW_H
                LD   BC, -61 * 16
                LD   DE, -45 * 16
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
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, CURSOR_W, CURSOR_H
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
                ; In: BC=x0, DE=x1, IX=y0, IY=y1. Out: C=1 inside, C=0 outside.
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
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, W?, H?
                LD   BC, X? * 16
                LD   DE, Y? * 16
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
MenuAdventureClick:       DEFB 0
MenuMoreClick:            DEFB 0
MenuQuitClick:            DEFB 0
MenuButtonStateAdventure: DEFB 0
MenuButtonStateGauntlet:  DEFB 0
MenuButtonStateOptions:   DEFB 0
MenuButtonStateMore:      DEFB 0
MenuButtonStateQuit:      DEFB 0
MenuSelection:            DEFB 0   ; выбранная клавиатурой кнопка: 0=Adventure,1=More
MenuKbdUpPrev:            DEFB 1   ; фронт-флаги навигации (1 на старте = гасит перенос нажатия)
MenuKbdDownPrev:          DEFB 1
MenuKbdFirePrev:          DEFB 1

                endif ; _ZUMA_MENU_MAIN_
