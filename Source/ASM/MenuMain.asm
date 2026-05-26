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
                CALL LoadMainMenuAssets
                LD   HL, 0
                LD   (MenuSkyPos), HL
                XOR  A
                LD   (MenuSkyFrac), A
                LD   (MenuLmbPrev), A
                CALL FadeInMenu

.loop:          CALL Input.Mouse.UpdateMouseState
                CALL MenuUpdateButtons
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
                SetPage3 #04
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
                SetPage3 #04
                LD   HL, 0
                EXX
                LD   B, 1
                EXX
                LD   A, (MenuInflateDestHi)
                CALL SafeInflatePage2
                SetPage3 #04
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
                LD   A, (MenuSkyFrac)
                ADD  A, 2                              ; HD 1 px at 720p -> 2/3 px at 480p
                CP   3
                JR   C, .store_frac
                SUB  3
                LD   HL, (MenuSkyPos)
                INC  HL
                LD   DE, MENU_SKY_W
                PUSH HL
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .store_pos
                LD   HL, 0
.store_pos:     LD   (MenuSkyPos), HL
.store_frac:    LD   (MenuSkyFrac), A
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
                MenuCheckButton MENU_QUIT_X + MENU_BUTTON_HIT_BORDER, MENU_QUIT_Y + MENU_BUTTON_HIT_BORDER, MENU_QUIT_W - MENU_BUTTON_HIT_BORDER * 2, MENU_QUIT_H - MENU_BUTTON_HIT_BORDER * 2, MenuButtonStateQuit, MenuQuitClick
                LD   A, (MenuLmbNow)
                LD   (MenuLmbPrev), A
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
                LD   HL, (MenuSkyPos)
                CALL MenuEmitSkyX
                LD   HL, (MenuSkyPos)
                LD   DE, -639
                ADD  HL, DE
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                PUSH HL
                POP  BC
                LD   DE, 0
                JP   FT.Coprocessor.Vertex2f

MenuEmitSkyX:
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                PUSH HL
                POP  BC
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
                ; HD reference draws sun and tinted glow after Menu_Draw.
                FT_PaletteSource MENU_UI_PAL_RAMG
                FT_BitmapHandle MENU_HANDLE_SUN
                FT_BitmapSource MENU_SUN_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_SUN_W, MENU_SUN_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_SUN_W, MENU_SUN_H
                LD   BC, -1 * 16
                LD   DE, 11 * 16
                CALL FT.Coprocessor.Vertex2f
                LD   C, 255 : LD D, 192 : LD E, 0
                CALL FT.Coprocessor.ColorRGB
                LD   E, 152
                CALL FT.Coprocessor.ColorA
                FT_BitmapHandle MENU_HANDLE_GLOW
                FT_BitmapSource MENU_GLOW_RAMG
                FT_BitmapLayout FT_PALETTED4444, MENU_GLOW_W, MENU_GLOW_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MENU_GLOW_W, MENU_GLOW_H
                LD   BC, -61 * 16
                LD   DE, -45 * 16
                CALL FT.Coprocessor.Vertex2f
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                JP   FT.Coprocessor.ColorA

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

MenuSkyPos:               DEFW 0
MenuSkyFrac:              DEFB 0
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

                endif ; _ZUMA_MENU_MAIN_
