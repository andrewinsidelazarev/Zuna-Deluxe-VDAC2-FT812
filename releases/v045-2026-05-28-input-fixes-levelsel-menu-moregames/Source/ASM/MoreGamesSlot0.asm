; More Games room, menu quit path and system-wide fire input state.
; Kept in slot 0 because main1_play is close to its 16K page limit.

; Standalone SPG exit path. Reset FT812 first, undo the TS-Conf video state
; enabled by both Zuma variants, then enter the ROM reset vector.
MenuQuitToWC:
                DI
                LD   A, SPI_FT_CS_ON
                OUT  (SPI_CTRL), A
                LD   A, FT_CMD_RST_PULSE
                OUT  (SPI_DATA), A
                XOR  A
                OUT  (SPI_DATA), A
                OUT  (SPI_DATA), A
                LD   A, SPI_FT_CS_OFF
                OUT  (SPI_CTRL), A
                LD   BC, INTMASK
                XOR  A
                OUT  (C), A
                LD   BC, TSCONFIG
                OUT  (C), A
                LD   BC, VCONFIG
                OUT  (C), A
                LD   BC, VPAGE
                OUT  (C), A
                LD   BC, SGPAGE
                OUT  (C), A
                LD   BC, PALSEL
                OUT  (C), A
                LD   BC, CACHECONFIG
                OUT  (C), A
                LD   BC, SYSCONFIG
                OUT  (C), A
                LD   BC, FMADDR
                OUT  (C), A
                LD   BC, MEMCONFIG
                LD   A, MEM_ROM128 | MEM_WO_MAP
                OUT  (C), A
                LD   BC, #7FFD
                LD   A, #10
                OUT  (C), A
                JP   #0000

MORE_GAMES_RAMG       EQU #000000
MORE_GAMES_W          EQU 640
MORE_GAMES_H          EQU 480
MORE_GAMES_PAL_RAMG   EQU #0ABC60
MORE_GAMES_Z_CHUNK    EQU #00F000
MORE_GAMES_Z0_PAGE    EQU #BC
MORE_GAMES_Z1_PAGE    EQU #BF
MORE_GAMES_Z2_PAGE    EQU #C2
MORE_GAMES_Z3_PAGE    EQU #C5
MORE_GAMES_Z4_PAGE    EQU #C8
MORE_GAMES_PAL_PAGE   EQU #CB
MORE_GAMES_Z0_SIZE    EQU 40562
MORE_GAMES_Z1_SIZE    EQU 38097
MORE_GAMES_Z2_SIZE    EQU 35430
MORE_GAMES_Z3_SIZE    EQU 34340
MORE_GAMES_Z4_SIZE    EQU 37533

MoreGames:
                CALL LoadMoreGamesAssets
                CALL FadeInMoreGames
                ; Прайм фронт-детекторов ПОСЛЕ фейда: считаем Огонь/ЛКМ/ESC «уже
                ; нажатыми», чтобы клавиша/ЛКМ, которой выбрали More (и которую ещё
                ; держат), не вызвала мгновенный выход — нужен свежий фронт.
                LD   A, 1
                LD   (MoreGamesFirePrev), A
                LD   (MoreGamesLmbPrev), A
                LD   (MoreGamesEscPrev), A
.loop:          CALL Core.Input_Scan                       ; мышь + PS/2-клавиатура (раз/кадр)
                CALL MoreGamesExitPressed                  ; A=1 на фронте Огонь|ЛКМ|ESC
                OR   A
                JP   NZ, FadeMoreGamesToMenu
                CALL MoreGamesBuildFrame
                CALL Core.MenuSwapFrame
                JP   .loop

LoadMoreGamesAssets:
                LD   B, MoreGamesInflateAssetsCount
                LD   HL, MoreGamesInflateAssets
                CALL Core.MenuInflateAssetsFromTable
                LD   A, MORE_GAMES_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (MORE_GAMES_PAL_RAMG >> 16) & #FF
                LD   DE, MORE_GAMES_PAL_RAMG & #FFFF
                CALL FT.WriteMem
                SetPage2 6
                SetPage3 UI_OVL_PAGE                    ; More Games runs in UI context (#41): restore it, not #04
                                                         ; (was #04 — left MenuSwapFrame/MenuInflate on the wrong page → black screen)
                RET

MoreGamesBuildFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_Begin FT_BITMAPS
                FT_PaletteSource MORE_GAMES_PAL_RAMG
                FT_BitmapHandle 1
                FT_BitmapSource MORE_GAMES_RAMG
                FT_BitmapLayout FT_PALETTED4444, MORE_GAMES_W, MORE_GAMES_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MORE_GAMES_W, MORE_GAMES_H
                LD   BC, 0
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                CALL DrawFadeOverlay
                FT_End
                FT_Display
                FT_CMD_Count
                RET

                macro MoreGamesInflateAsset Destination?, Page?, Size?
                DEFB (Destination?) & #FF
                DEFB ((Destination?) >> 8) & #FF
                DEFB ((Destination?) >> 16) & #FF
                DEFB (Page?) & #FF
                DEFW (Size?) & #FFFF
                endm

MoreGamesInflateAssets:
                MoreGamesInflateAsset MORE_GAMES_RAMG + MORE_GAMES_Z_CHUNK * 0, MORE_GAMES_Z0_PAGE, MORE_GAMES_Z0_SIZE
                MoreGamesInflateAsset MORE_GAMES_RAMG + MORE_GAMES_Z_CHUNK * 1, MORE_GAMES_Z1_PAGE, MORE_GAMES_Z1_SIZE
                MoreGamesInflateAsset MORE_GAMES_RAMG + MORE_GAMES_Z_CHUNK * 2, MORE_GAMES_Z2_PAGE, MORE_GAMES_Z2_SIZE
                MoreGamesInflateAsset MORE_GAMES_RAMG + MORE_GAMES_Z_CHUNK * 3, MORE_GAMES_Z3_PAGE, MORE_GAMES_Z3_SIZE
                MoreGamesInflateAsset MORE_GAMES_RAMG + MORE_GAMES_Z_CHUNK * 4, MORE_GAMES_Z4_PAGE, MORE_GAMES_Z4_SIZE
MoreGamesInflateAssetsEnd:
MoreGamesInflateAssetsCount EQU (MoreGamesInflateAssetsEnd - MoreGamesInflateAssets) / 6

; MoreGamesExitPressed — выход из экрана More Games. Возвращает A=1 на ФРОНТЕ
; нажатия ЛЮБОГО из: огонь-КЛАВИША (Space|Enter|Kempston-Fire, Core.Input_FireKey),
; ЛКМ (Core.Input_MouseLMB) или ESC (Core.Input_Esc). Иначе A=0.
; 🔴 ВАЖНО: огонь-клавиша и ЛКМ — ОТДЕЛЬНЫЕ фронт-детекторы (НЕ через Input_Fire,
; который их ИЛИ-объединяет). Иначе залипшая/фантомно-нажатая ЛКМ (на этом стенде
; мышиные/Kempston-биты порой читаются «нажато» постоянно — см. Frog.asm) держит
; объединённый сигнал в NZ → у клавиатурного огня НИКОГДА нет фронта (симптом:
; «выходит только по ESC»). Раздельно — залипшая ЛКМ не блокирует огонь с клавы.
; Input_EdgeZ обязан идти СРАЗУ после опроса — промежуточный LD HL,addr флаги не
; трогает, поэтому Z доходит до EdgeZ целым. *Prev primed=1 гасят перенос из меню.
MoreGamesExitPressed:
                CALL Core.Input_FireKey                    ; Space|Enter|Kempston (БЕЗ ЛКМ)
                LD   HL, MoreGamesFirePrev
                CALL Core.Input_EdgeZ                      ; NZ=фронт, обновляет (HL)
                JR   NZ, .yes
                CALL Core.Input_MouseLMB                   ; ЛКМ — изолированный фронт
                LD   HL, MoreGamesLmbPrev
                CALL Core.Input_EdgeZ
                JR   NZ, .yes
                CALL Core.Input_Esc                        ; ESC
                LD   HL, MoreGamesEscPrev
                CALL Core.Input_EdgeZ
                JR   NZ, .yes
                XOR  A
                RET
.yes:           LD   A, 1
                RET

MoreGamesFirePrev: DEFB 0
MoreGamesLmbPrev:  DEFB 0
MoreGamesEscPrev:  DEFB 0
