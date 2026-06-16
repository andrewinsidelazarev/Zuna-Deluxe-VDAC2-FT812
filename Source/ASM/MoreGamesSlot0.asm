; More Games room, menu quit path и system-wide fire input state.
; Хранится в UI overlay (#41): экран вызывается только из меню, а slot0 держим
; свободным для resident helpers.

; Standalone SPG exit path → грузим Wild Commander сами (boot.$C HOBETA с SD).
; MEMCONFIG=0+JP#0000 (Service ROM) НЕ грузит boot.$ (даёт пустой ZX-экран), поэтому
; используем свой HOBETA-загрузчик: найти BOOT.$C → стаб в #4000 (bank5, ниже #6011)
; → режим WC без LCK128 (MemConfig=#01; slot1=bank5/slot2=bank2/slot3=bank0) → JP
; #4000 → стаб читает файл в #6000 (file[17]=WC на #6011) → JP #6011.
; Эталон живого WC со скрина: VConfig=#24, SusConfig=#06, MemConfig=#01, INTMASK=0.
MenuQuitToWC:
                DI
                LD   A, #10
                LD   (Core.Quit_DbgStage), A
                CALL Core.ProbeBootHobeta               ; найти BOOT.$C и первый сектор через старый DFS
                LD   A, (Core.Boot_Found)
                OR   A
                JP   Z, .qFallback

                LD   A, #20
                LD   (Core.Quit_DbgStage), A
                LD   HL, Core.QuitStub_Image            ; стаб уже лежит в Core/page5, копируем ниже BOOT.$C
                LD   DE, #4000
                LD   BC, Core.QuitStub_Len
                LDIR

                LD   A, #30
                LD   (Core.Quit_DbgStage), A
                LD   HL, (Core.Boot_StartLba + 0)
                LD   (Core.QS_Lba + 0), HL
                LD   HL, (Core.Boot_StartLba + 2)
                LD   (Core.QS_Lba + 2), HL
                LD   A, (Core.Boot_SecCount)
                LD   (Core.QS_Cnt), A
                LD   A, (Core.Boot_Blkt)
                LD   (Core.QS_Blkt), A

                CALL .qResetHw                          ; сбросить FT812 до ухода из Zuma
                LD   A, #40
                LD   (Core.Quit_DbgStage), A
                JP   #4000                              ; дальше стаб сам выставляет память и читает BOOT.$C

.qFallback:     CALL .qResetHw                          ; BOOT.$C нет → reset HW + вход TR-DOS
                LD   A, #F0
                LD   (Core.Quit_DbgStage), A
                LD   BC, MEMCONFIG
                LD   A, MEM_ROM128
                OUT  (C), A
                LD   BC, #7FFD
                LD   A, #10
                OUT  (C), A
                JP   #3D2F

; FT812 CORE_RESET (#68) + INTMASK=0 + VCONFIG=0 (вернуть ZX-ULA видео). Остальные
; видео-регистры (VPAGE/TSCONFIG/PALSEL/…) НЕ трогаем — там значения WC.
.qResetHw:      LD   A, SPI_FT_CS_ON
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
                LD   BC, VCONFIG
                OUT  (C), A
                RET

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
                CALL MoreGamesPrimeInputPrev
.loop:          CALL Core.Input_Scan                       ; static screen: poll input as fast as possible
                CALL MoreGamesExitPressed                  ; A=1 на фронте Огонь|ЛКМ|ESC
                OR   A
                JP   NZ, FadeMoreGamesToMenu
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
                SetPage3 UI_OVL_PAGE                    ; More Games работает в UI context (#41): restore его, не #04
                                                         ; раньше #04 оставлял MenuSwapFrame/MenuInflate на wrong page → black screen
                RET

MoreGamesPrimeInputPrev:
                ; Прайм после fade текущим состоянием, а не hard-coded pressed.
                ; Иначе первый ЛКМ мог съедаться, если первый scan ещё видел stale/held down.
                CALL Core.Input_Scan
                CALL Core.Input_FireKey
                LD   HL, MoreGamesFirePrev
                CALL MoreGamesStorePressedFlag
                CALL Core.Input_MouseLMB
                LD   HL, MoreGamesLmbPrev
                CALL MoreGamesStorePressedFlag
                CALL Core.Input_Esc
                LD   HL, MoreGamesEscPrev
MoreGamesStorePressedFlag:
                LD   A, 0
                JR   Z, .store
                INC  A
.store:         LD   (HL), A
                RET

MoreGamesBuildFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                ; 1024×768: scale(1.6)-матрица кадра + окно ×8/5 — как фон level-select
                CALL Core.Resident_EmitScale16
                FT_Begin FT_BITMAPS
                FT_PaletteSource MORE_GAMES_PAL_RAMG
                FT_BitmapHandle 1
                FT_BitmapSource MORE_GAMES_RAMG
                FT_BitmapLayout FT_PALETTED4444, MORE_GAMES_W, MORE_GAMES_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, MORE_GAMES_W * 8 / 5, MORE_GAMES_H * 8 / 5
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

; MoreGamesExitPressed — выход из экрана More Games. Возвращает A=1 на действии:
; огонь-КЛАВИША/ESC по press edge, ЛКМ по press edge ИЛИ release edge.
; 🔴 ВАЖНО: огонь-клавиша и ЛКМ — ОТДЕЛЬНЫЕ фронт-детекторы (НЕ через Input_Fire,
; который их ИЛИ-объединяет). Иначе залипшая/фантомно-нажатая ЛКМ (на этом стенде
; мышиные/Kempston-биты порой читаются «нажато» постоянно — см. Frog.asm) держит
; объединённый сигнал в NZ → у клавиатурного огня НИКОГДА нет фронта (симптом:
; «выходит только по ESC»). Раздельно — залипшая ЛКМ не блокирует огонь с клавы.
; Input_EdgeZ обязан идти СРАЗУ после опроса — промежуточный LD HL,addr флаги не
; трогает, поэтому Z доходит до EdgeZ целым.
MoreGamesExitPressed:
                CALL Core.Input_FireKey                    ; Space|Enter|Kempston (БЕЗ ЛКМ)
                LD   HL, MoreGamesFirePrev
                CALL Core.Input_EdgeZ                      ; NZ=фронт, обновляет (HL)
                JR   NZ, .yes
                CALL Core.Input_MouseLMB                   ; ЛКМ — press/release click
                LD   HL, MoreGamesLmbPrev
                JR   Z, .lmb_released
                LD   A, (HL)
                LD   (HL), 1
                OR   A
                JR   Z, .yes                              ; released->pressed
                JR   .check_esc
.lmb_released:  LD   A, (HL)
                LD   (HL), 0
                OR   A
                JR   NZ, .yes
.check_esc:     CALL Core.Input_Esc                        ; ESC
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
