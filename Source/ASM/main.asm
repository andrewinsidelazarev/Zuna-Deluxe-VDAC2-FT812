; ============================================================================
; Zuma Deluxe VDAC2 — main.asm
; ----------------------------------------------------------------------------
; Точка сборки. Использует TSLib из Docs/TSLib/.
; Layout:
;   Page 0 (#0000..#3FFF mapped at slot 0): код TSLib, ORG #1000
;   Page 5 (#4000..#7FFF mapped at slot 1): код Core, ORG #6000
; После Init_Core slot/page mapping: page1=5, page2=2, page3=8.
; Стек в slot 1 (#40F2) — между Resolution* указателями и началом кода.
; ============================================================================

                DEVICE ZXSPECTRUM4096
                define MAPPING_REGISTERS              ; реестры через FMADDR_REGS
RUNTIME_DIAGNOSTICS_ENABLED EQU 0                      ; 1 = включить отдельный runtime diagnostics ASM
                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_GLOBAL_EQU
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_GLOBAL_EQU
                endif

; ----------------------------------------------------------------------------
; FT command buffer: TSLib дефолтит на #C000 (slot 3). После main0/main1 split
; main1_play код живёт в slot 3 → буфер перекрывает код → corruption за кадр.
; Держать в slot 1 RAM до EntryPoint; #6000 теперь занят кодом.
; ----------------------------------------------------------------------------
                ; 1024×768: база сдвинута #5010→#4C90 (ball-cache ужат 240→128 слотов,
                ; GAMELOG переехал). Кадровый CMD-буфер: #4C90..#5C00 = 3952 байта —
                ; полная анимация (worst dual+tunnel замерен 2872б, тест
                ; test_cmd_buffer_budget_z80.py) + запас.
                define CMD_ADDRESS_PTR #4CB0

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #5C00                        ; slot 1 (page 5), держать Core ниже #8000
StackTop             EQU #40F2
ResolutionWidthPtr   EQU #40F3                        ; куда FT_RESOLUTION пишет ширину (W word)
ResolutionHeightPtr  EQU #40F5                        ; высоту (H word)
MemoryPages          EQU #40F7                        ; cache номеров pages (для не-MAPPING_REGISTERS)
InterruptVA          EQU #4000                        ; область IM2 vectors в resident page

TSLib                EQU #1000                        ; адрес где живёт TSLib
TSLibPage            EQU #00                          ; страница TSLib

; Адреса/hooks runtime-диагностики живут в DiagnosticsRuntime.asm и не входят
; в обычную сборку.

; --- Текстовые atlases (nativealien48 ARGB4, red-yellow gradient). Объявлены здесь
; (ДО TSLib block) чтобы EQU были доступны во всех slot 0/1/3 функциях через
; sjasmplus forward-resolve. FT_RAM_G #0000..#10000 = 64K свободной зоны (раньше
; не использовалась, bg начинается с #010000). Размеры см. text_*.info.
FROG_ARGB4_ENABLED    EQU 1
BALLS_ARGB4_ENABLED   EQU 0                         ; global balls atlas: PALETTED4444 50px-in-51px guarded cells
; Slot-3 overlay pages (logical #C000, разные physical pages, never co-resident).
; Определено здесь (global, before module Core), чтобы resident Fade* transitions
; и Init_Core видели UI_OVL_PAGE без forward ref. LOADER_OVL_PAGE живёт в
; loader_resident.asm (используется только внутри module Core). #04 = gameplay overlay.
UI_OVL_PAGE           EQU #41                       ; Init_Video + MenuMain + LevelSelect
TEXT_GAMEOVER_PAGE     EQU #20
TEXT_GAMEOVER_RAMG     EQU #000000
TEXT_GAMEOVER_W        EQU 169
TEXT_GAMEOVER_H        EQU 46

; LEVEL N-M intro: native-48 nativealien glyph-font (рисуется 1:1, БЕЗ upscale).
; Заняло RAM_G #004000..#00C000 — это бывшие TEXT_LEVEL11 + TEXT_SPIRALDOOM, которые
; грузились, но НЕ рисовались (строку «LEVEL N-M» давно строит DrawIntroText через
; DrawString; названия уровней — отдельный 30px nativealien). 2 ZX7-чанка, SPG #21/#22.
FONT_LEVEL48_PAGE_BASE EQU #21                          ; SPG pages #21,#22
FONT_LEVEL48_NUM_PAGES EQU 2
FONT_LEVEL48_RAMG      EQU #004000                      ; 2×16K окно → #004000..#00C000
FONT_LEVEL48_HANDLE    EQU 11
FONT_LEVEL48_META_PAGE EQU #23                          ; glyph metadata tables, mapped in slot 2 on demand

TEXT_SPIRALDOOM_H      EQU 36                            ; опорная высота строки для Y-раскладки интро (исторический ориентир)

; «LOADING LEVELS...» — пред-рендеренный баннер nativealien48 48px (тот же шрифт/
; градиент, что и LEVEL N-M). Экран загрузки показывается ДО загрузки глифовых
; атласов, поэтому строка запечена в одну картинку. RAM_G #084000 — свободная зона
; в профиле level-select (#082658..#098000), поэтому баннер ПЕРЕЖИВАЕТ медленный
; поиск PAK (грузится в неё ассетами меню перед показом — меню уже погашено).
                include "loading_text_meta.inc"            ; LOADING_TEXT_W / _H / _NUM_PAGES (только EQU)
                include "boot_loading_assets.inc"          ; boot-only ARGB4 assets loading screen
LOADING_TEXT_PAGE_BASE EQU #25                             ; SPG pages #25,#26 (свободны)
LOADING_TEXT_RAMG      EQU #084000                         ; загрузка level-select: затем FRAME_TOP
LOADING_TEXT_GAME_RAMG EQU #0AC000                         ; временная загрузка gameplay: swap-zone до top-mask/dialog
LOADING_TEXT_HANDLE    EQU 12

BOOT_LOADING_BG_RAMG     EQU #000000
BOOT_LOADING_BAR_RAMG    EQU #03C000
BOOT_TS_ANIM_RAMG        EQU #044000
BOOT_SFX_AUTHORS_RAMG    EQU #06C000
BOOT_POPCAP_RAMG         EQU #070000
BOOT_LOADING_BG_HANDLE   EQU 14
BOOT_LOADING_BAR_HANDLE  EQU 15
BOOT_TS_ANIM_HANDLE      EQU 16
BOOT_LOADING_BG_ENABLED  EQU 1                         ; DXT-L4 boot background, raw pages (no ZX7)
BOOT_LOADING_BG_MASK_HANDLE EQU 17
BOOT_SFX_AUTHORS_HANDLE  EQU 18
BOOT_POPCAP_HANDLE       EQU 19
BOOT_LOADING_BG_X        EQU 0
BOOT_LOADING_BG_Y        EQU 0
BOOT_LOADING_BAR_X       EQU 122
BOOT_LOADING_BAR_Y       EQU 356
BOOT_POPCAP_X            EQU 890                       ; native 1024×768 pixels, без FT812 upscale
BOOT_POPCAP_Y            EQU 644
BOOT_TS_ANIM_X           EQU 226
BOOT_TS_ANIM_Y           EQU 272
BOOT_TS_SHADOW_DX        EQU 4
BOOT_TS_SHADOW_DY        EQU 5
BOOT_TS_SHADOW_A         EQU 96

TEXT_GAMEOVER_HANDLE   EQU 10

; Sparkle/diamond — 24×24 ARGB4 для track-preview анимации в intro state.
SPARKLE_PAGE           EQU #24
SPARKLE_RAMG           EQU #00C000                       ; free area между spiraldoom и bg
SPARKLE_W              EQU 24                            ; atlas (layout)
SPARKLE_H              EQU 24
SPARKLE_DRAW           EQU 38                            ; 1024×768: 24×1.6 (рисуется при scale(1.6)-матрице)
SPARKLE_HANDLE         EQU 13
SPARKLE_COUNT          EQU 22                            ; sparkles вдоль track
SPARKLE_HALF           EQU 19                            ; центр draw-rect'а (38/2) для Vertex2f

; --- Frame strips PALETTED4444 (16K-aligned blocks для UnpackAndUploadPage) ---
FRAME_PAL_PAGE       EQU #3F
FRAME_PAL_RAMG       EQU #080200                         ; raw 512B после balls palette (4-byte aligned)
FRAME_TOP_P0_PAGE    EQU #3A
FRAME_TOP_P1_PAGE    EQU #3B
FRAME_TOP_RAMG       EQU #084000                         ; 32K block (2×16K aligned)
FRAME_TOP_W          EQU 640
FRAME_TOP_H          EQU 44
FRAME_BOT_PAGE       EQU #3C
FRAME_BOT_RAMG       EQU #08C000                         ; 16K block
FRAME_BOT_W          EQU 640
FRAME_BOT_H          EQU 24
FRAME_LEFT_PAGE      EQU #3D
FRAME_LEFT_RAMG      EQU #090000                         ; 16K block
FRAME_LEFT_W         EQU 24
FRAME_LEFT_H         EQU 412
FRAME_RIGHT_PAGE     EQU #3E
FRAME_RIGHT_RAMG     EQU #094000                         ; 16K block (next free until #098000)
FRAME_RIGHT_W        EQU 24
FRAME_RIGHT_H        EQU 412
FRAME_TOP_HANDLE     EQU 14
FRAME_BOT_HANDLE     EQU 15
FRAME_LEFT_HANDLE    EQU 16
FRAME_RIGHT_HANDLE   EQU 17
; 1024×768 порт: рамки рисуются ×1.6 (atlas-размеры W/H выше — для layout; ниже —
; экранный draw-размер). Одна точная scale(1.6)-матрица в DrawFrameStrips.
FRAME_TOP_DRAW_W     EQU 1024                            ; 640×1.6
FRAME_TOP_DRAW_H     EQU 70                              ; 44×1.6
FRAME_BOT_DRAW_W     EQU 1024
FRAME_BOT_DRAW_H     EQU 38                              ; 24×1.6
FRAME_LEFT_DRAW_W    EQU 38                              ; 24×1.6
FRAME_LEFT_DRAW_H    EQU 659                             ; 412×1.6
FRAME_RIGHT_DRAW_W   EQU 38
FRAME_RIGHT_DRAW_H   EQU 659
LIFE_FROG_HANDLE     EQU 18

; --- Tunnel top-cover: 400x300 ARGB4 tiles, сгенерированные из HD image-top PNGs.

; --- HUD top bar lives counter ---
;   life_frog 20×20 PALETTED4444 (raw upload, 400 bytes).
;   Shared HUD palette 512 bytes ARGB4 LE (место для будущих menu/progress sprites).
;   Размещение в RAM_G: после dialog frame (#0AC000..#0CC000), до cursor (#0D0000).
LIFE_FROG_PAGE       EQU #5B
LIFE_FROG_RAMG       EQU #0CC000                         ; 4-byte aligned, free slot
LIFE_FROG_W          EQU 20
LIFE_FROG_H          EQU 20
LIFE_FROG_BYTES      EQU 400                             ; W * H для PALETTED4444 8bpp
HUD_PALETTE_PAGE     EQU #5C
HUD_PALETTE_RAMG     EQU #0CC200                         ; 4-byte aligned, 512 байт
HUD_MENU_PAGE        EQU #5E
HUD_MENU_RAMG        EQU #0CC800                         ; 3 cells 79×25, free before cursor
HUD_MENU_W           EQU 79
HUD_MENU_H           EQU 26
HUD_MENU_BYTES       EQU HUD_MENU_W * HUD_MENU_H * 3
HUD_PROGRESS_PAGE    EQU #5F
HUD_PROGRESS_RAMG    EQU #0CE400                         ; 2 cells 63×19
HUD_PROGRESS_W       EQU 63
HUD_PROGRESS_H       EQU 19
HUD_PROGRESS_BYTES   EQU HUD_PROGRESS_W * HUD_PROGRESS_H * 2

; --- Dialog FRAME (Maya stone border + skull, 400×327 PALETTED4444) ---
;   130800 bytes raw → 8 чанков ZX7 по 16K, страницы #60..#67, RAM_G #0AC000..#0CC000.
;   Shared dialog_palette на #5D → RAM_G #0CC400.
DIALOG_PALETTE_PAGE     EQU #5D
DIALOG_PALETTE_RAMG     EQU #0CC400                       ; 4-byte aligned, 512 байт
DIALOG_FRAME_PAGE_BASE  EQU #60
DIALOG_FRAME_NUM_PAGES  EQU 8
DIALOG_FRAME_RAMG       EQU #0AC000                        ; после Cancun8 font, перед HUD area
DIALOG_FRAME_W          EQU 400
DIALOG_FRAME_H          EQU 327
DIALOG_FRAME_HANDLE     EQU 21
; 1024×768: диалог рисуется при scale(1.6)-матрице (ставится в MainLoop перед
; CALL DrawRetryDialog) → атлас 400×327 рисуется 640×523. Позиции экранные.
DIALOG_FRAME_DRAW_W     EQU 640                            ; 400×1.6
DIALOG_FRAME_DRAW_H     EQU 523                            ; 327×1.6
DIALOG_FRAME_X          EQU 192                            ; 120×1.6 — ПРОПОРЦИОНАЛЬНО оригиналу
DIALOG_FRAME_Y          EQU 96                             ; 60×1.6 — тогда ВСЕ внутренние ×1.6
                                                           ; координаты совпадают с оригиналом 1:1
DIALOG_OK_DRAW_W        EQU 480                            ; 300×1.6
DIALOG_OK_DRAW_H        EQU 54                             ; 34×1.6
DIALOG_OK_PAGE          EQU #6D
DIALOG_OK_RAMG          EQU #02D800                        ; gap after BG palette, before frog ARGB4
DIALOG_OK_W             EQU 300
DIALOG_OK_H             EQU 34
DIALOG_OK_BYTES         EQU DIALOG_OK_W * DIALOG_OK_H
DIALOG_OK_HANDLE        EQU 24

; --- Native alien font atlas (ARGB4, A-Z+0-9+:.) ---
;   643×24 = 30864 bytes raw, ZX7 в 2 SPG чанках #68..#69, RAM_G #098000.
;   Используется через DrawString runtime glyph-blit. Per-char metadata в font_native_meta.inc.
FONT_NATIVE_PAGE_BASE   EQU #68
FONT_NATIVE_NUM_PAGES   EQU 2                            ; nativealien48 compact atlas, 2×16K
FONT_NATIVE_RAMG        EQU #098000                       ; 4-byte aligned, free zone (96K)
FONT_NATIVE_HANDLE      EQU 22

; --- Cancun fonts: compact 1024-native grey HUD/stats glyph atlases ---
;   Cancun10 stats: 304x18, 1 ZX7 chunk. Cancun8 HUD: 462x34, 2 ZX7 chunks.
FONT_CANCUN10_STATS_PAGE EQU #6A
FONT_CANCUN10_STATS_RAMG EQU #0A0000
FONT_CANCUN10_STATS_HANDLE EQU 25
FONT_CANCUN8_PAGE_BASE  EQU #6B
FONT_CANCUN8_NUM_PAGES_VDAC EQU 2
FONT_CANCUN8_RAMG       EQU #0A4000
FONT_CANCUN8_HANDLE     EQU 23

; --- HUD lives counter geometry (sock на frame_top.png, замеренная Python'ом) ---
;   Sock interior: x=26..103 (78 px), y=3..25 (22 px на 640×480 frame).
;   3 жабы 20×20 центрируются: margin=(78-60)/2=9, start_x=26+9=35, y=4.
; 1024×768: HUD рисуется ПОСЛЕ DrawFrameStrips — scale(1.6)-матрица уже активна,
; спрайты сэмплируются ×1.6 автоматически. Здесь только DRAW-размеры (BitmapSize)
; и позиции/hit-box ×1.6 (= ×8/5). Atlas-размеры (layout) не трогаем.
LIFE_SOCK_X          EQU 56                            ; 35×1.6
LIFE_SOCK_Y          EQU 6                             ; 4×1.6
LIFE_STEP            EQU 32                            ; 20×1.6 (= draw width жабы)
LIFE_FROG_DRAW       EQU 32                            ; 20×1.6 экранный размер иконки
LIFE_MAX_DRAW        EQU 3                             ; ограничить displayed count (sock 125px вмещает 3×32)
; Позиция hover/pressed — ТОЧНО на запечённой в frame_top idle-кнопке: рамка
; рисуется матрицей 1.6 от (0,0), кнопка в strip-координатах (539,3) → экран
; (862.4, 4.8). Вершина в 1/16 px (VERTEX2F) — дробная позиция, сетки NEAREST
; рамки и спрайта совпадают попиксельно (обе — точные 160/256-матрицы).
HUD_MENU_X16         EQU 13798                         ; 539×1.6×16 = 13798.4
HUD_MENU_Y16         EQU 77                            ; 3×1.6×16 = 76.8
HUD_MENU_DRAW_W      EQU 126                           ; 79×1.6
HUD_MENU_DRAW_H      EQU 42                            ; 26×1.6
HUD_MENU_HIT_X       EQU 851                           ; 532×1.6
HUD_MENU_HIT_Y       EQU 0
HUD_MENU_HIT_W       EQU 154                           ; 96×1.6
HUD_MENU_HIT_H       EQU 54                            ; 34×1.6
HUD_PROGRESS_X       EQU 651                           ; 407×1.6
HUD_PROGRESS_Y       EQU 2                             ; 1×1.6
HUD_PROGRESS_DRAW_W  EQU 101                           ; 63×1.6 (fill_px и scissor в ЭКРАННЫХ px)
HUD_PROGRESS_DRAW_H  EQU 30                            ; 19×1.6
; HUD_GAUGE_TARGET: оригинальный lvl1 = 3000 (юзер 2026-05-20 проверил в оригинале:
; «при 3000 очков прогресс-бар в первом уровне становится зеленым»).
; HD-ref levels.xml имеет 1000 для lvl11/lvl12, но это другая нумерация (lvl11 = level 1-1).
; Сейчас целевое значение 1000 синхронизировано с DrawHudProgress (/125).
; При возврате к оригинальным 3000 нужно одновременно заменить делитель на /375
; или вынести расчёт в generic Div16x16.
HUD_GAUGE_TARGET     EQU 1000

; --- Frog RTC entropy state (slot 1 free RAM, между GAMELOG и Core @ #6000) ---
; Каждый 128-й вызов Frog_NewNextColor взводит FLAG; picker (Frog_FilteredRandomColor)
; XOR'ит RTC seconds в RAND_BYTE (= ВЫХОД LFSR), не трогая seed state — LFSR
; продолжает свой математически гарантированный цикл, а RTC даёт точечный
; перетряс распределения раз в ~128 выстрелов (~3-5 минут реальной игры).
; Важно: RTC нельзя XOR'ить прямо в seed, иначе ломается цикл LFSR и возможны
; короткие повторяющиеся петли.
FROG_RTC_MIX_CNT_ADDR  EQU #4C89                       ; 1 byte, 0..127 cyclic (сдвиг −#380 с GAMELOG)
FROG_RTC_MIX_FLAG_ADDR EQU #4C8A                       ; 1 byte, 0/1 pending mix
FROG_EXCLUDE_COLOR_ADDR EQU #4C8B                      ; 1 byte; 0xFF=no excl, иначе color → убрать bit из mask при popcount>=3 (consume-and-reset)

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

                ORG TSLIB_End

                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_SLOT0
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_SLOT0
                endif

Cache_C000_OnMainLoop:
                LD   HL, FMADDR_REGS + HIGH CACHECONFIG
                LD   (HL), EN_0000 | EN_4000 | EN_C000
                JP   Core.MainLoop

Cache_C000_Off:
                LD   HL, FMADDR_REGS + HIGH CACHECONFIG
                LD   (HL), EN_0000 | EN_4000
                RET

ClampOffsetOrder:                                      ; не позволить соседним шарам поменяться местами
                PUSH AF
                PUSH BC
                PUSH HL
                LD   A, (Core.VDC_SlotsLen)
                CP   2
                JR   C, .co_done
                DEC  A
                LD   B, A                              ; pairs len-1
                LD   HL, (Core.VDC_pOffsets)           ; HL = предыдущее смещение активной цепочки
.co_loop:       LD   A, (HL)                           ; signed prev в смещённой шкале 0..255
                XOR  #80
                ADD  A, Core.VDC_CELL_SIZE - 1         ; оставить минимум один sample между центрами
                INC  HL                                ; HL = current offset
                JR   C, .co_next                       ; порог выше +127: любой current допустим
                LD   C, A                              ; C = допустимый current в смещённой шкале
                LD   A, (HL)
                XOR  #80
                CP   C
                JR   C, .co_next
                JR   Z, .co_next
                LD   A, C
                XOR  #80
                LD   (HL), A
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
KZ_SPR_W           EQU 88                              ; atlas (layout) — НЕ масштабировать
KZ_SPR_H           EQU 88
KZ_SPR_DRAW        EQU 141                             ; 1024×768: экранный размер = round(88×8/5)
KZ_SPR_HALF        EQU 70                              ; round(141/2) — центр draw-rect'а (scale-about-origin)
FROG_DEFAULT_X     EQU 327
FROG_DEFAULT_Y     EQU 231

; Room transitions держат текущий DL видимым, пока его полностью не перекроет
; black overlay. После этого RAM_G можно перезагружать без показа half-written art.
FadeMenuToLevelSelect:
                LD   HL, Core.MenuBuildFrame
                CALL FadeOutRoom
                ; Только первый раз: PAK sector map ещё не собран, поэтому upcoming
                ; asset load запускает медленный recursive search. Показываем
                ; "LOADING LEVELS..." поверх погашенного menu, пока он работает.
                ; Поздние transitions используют cached map: почти мгновенно, без текста.
                LD   A, (Core.LevelsMapLoaded)
                OR   A
                JR   NZ, .skip_loading
                CALL UploadLoadingText                  ; залить баннер в RAM_G #084000 (меню погашено)
                CALL Core.DrawLoadingLevelsScreen
.skip_loading:
                JP   Core.LevelSelect

; UploadLoadingText — расжать «LOADING LEVELS...» (nativealien48 48px) в RAM_G
; #084000. Зона свободна в профиле level-select (#082658..#098000), поэтому баннер
; переживает медленный поиск PAK, пока кадр отрисован. Вызывать ДО DrawLoadingScreen.
UploadLoadingText:
                LD   HL, LOADING_TEXT_RAMG & 0xFFFF
                LD   (Core.BgRamL), HL
                LD   A, (LOADING_TEXT_RAMG >> 16) & 0xFF
                LD   (Core.BgRamH), A
                JR   UploadLoadingTextAtBgRam

; UploadGameplayLoadingText — тот же atlas, но во временный gameplay-буфер.
; #0AC000 не трогаем до конца загрузки уровня; поэтому «LOADING LEVEL X-X»
; остаётся видимым, пока #084000 уже можно перезаписывать frame strips.
UploadGameplayLoadingText:
                LD   HL, LOADING_TEXT_GAME_RAMG & 0xFFFF
                LD   (Core.BgRamL), HL
                LD   A, (LOADING_TEXT_GAME_RAMG >> 16) & 0xFF
                LD   (Core.BgRamH), A
UploadLoadingTextAtBgRam:
                LD   A, LOADING_TEXT_PAGE_BASE
                LD   B, LOADING_TEXT_NUM_PAGES
.ult_loop:      PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage                ; advances RAM_G +16K
                POP  AF
                INC  A
                POP  BC
                DJNZ .ult_loop
                RET

FadeMenuToMoreGames:
                LD   HL, Core.MenuBuildFrame
                CALL FadeOutRoom
                JP   Core.MoreGames

FadeLevelSelectToMenu:
                LD   HL, Core.LevelSelectBuildFrame
                CALL FadeOutRoom
                JP   Core.MenuMain

FadeLevelSelectToGameplay:
                LD   HL, Core.LevelSelectBuildFrame
                CALL FadeOutRoom                        ; оставляет FadeAlpha=255 (сбросит EnterGameplayForCurrentLevel)
                CALL Score_Reset                        ; новый прогон adventure → счёт=0, NextLifeScore=50000
                ; Единый вход в геймплей: сброс fade + SetPage3 #04 + CurrentCodePage +
                ; loading-экран + LoadGameplayAssets + JP MainLoop. ТОТ ЖЕ код, что и
                ; win-переход (LoadNextLevelWithLoading) — расхождение путей убрано.
                JP   Core.EnterGameplayForCurrentLevel

FadeGameplayToMenu:
                CALL Cache_C000_Off
                SetPage3 UI_OVL_PAGE                     ; slot 3 -> UI overlay СНАЧАЛА: DrawBlackTransitionFrame
                                                         ; вызывает MenuSwapFrame, который живёт на UI page
                LD   A, UI_OVL_PAGE : LD (CurrentCodePage), A   ; отследить scene page
                CALL Core.DrawBlackTransitionFrame
                JP   Core.MenuMain

FadeGameplayToCurrentLevel:
                CALL Cache_C000_Off
                SetPage3 UI_OVL_PAGE                     ; DrawBlackTransitionFrame needs UI MenuSwapFrame mapped
                LD   A, UI_OVL_PAGE : LD (CurrentCodePage), A
                CALL Core.DrawBlackTransitionFrame
                JP   Core.EnterGameplayForCurrentLevel

FadeInMenu:
                LD   HL, Core.MenuBuildFrame
                JP   FadeInRoom

FadeInLevelSelect:
                LD   HL, Core.LevelSelectBuildFrame
                JP   FadeInRoom

FadeInMoreGames:
                LD   HL, Core.MoreGamesBuildFrame
                JP   FadeInRoom

FadeMoreGamesToMenu:
                LD   HL, Core.MoreGamesBuildFrame
                CALL FadeOutRoom
                SetPage3 UI_OVL_PAGE                     ; гарантировать slot 3 -> UI overlay перед MenuMain
                LD   A, UI_OVL_PAGE : LD (CurrentCodePage), A   ; отследить scene page
                JP   Core.MenuMain

FadeOutRoom:
                LD   (FadeRoomBuilder + 1), HL
                XOR  A
.fade_out:      ADD  A, 32
                JR   NC, .fade_out_store
                LD   A, 255
.fade_out_store:
                LD   (FadeAlpha), A
                PUSH AF
                CALL FadeRoomFrame
                POP  AF
                CP   255
                JR   NZ, .fade_out
                ; Сцена погашена → свопнуть ЧИСТЫЙ чёрный DL (без ссылок на
                ; bitmap'ы) и дождаться показа: дальше пойдёт перезапись RAM_G,
                ; и кадр с битмапами на экране превратился бы в мусор.
                JP   Core.DrawBlackTransitionFrame

FadeInRoom:
                LD   (FadeRoomBuilder + 1), HL
                LD   A, 255
.fade_in:       LD   (FadeAlpha), A
                PUSH AF
                CALL FadeRoomFrame
                POP  AF
                OR   A
                RET  Z
                SUB  32
                JR   NC, .fade_in
                XOR  A
                JR   .fade_in

FadeRoomFrame:
FadeRoomBuilder:
                CALL #0000
                JP   Core.MenuSwapFrame

; DrawBlackTransitionFrame перенесён в shared_render.asm (Core-резидент, Main0):
; page0 забит под #4000, а Main0 имеет запас. Вызовы — Core.DrawBlackTransitionFrame.

DrawFadeOverlay:
                LD   A, (FadeAlpha)
                OR   A
                RET  Z
                PUSH AF
                FT_End
                FT_SaveContext
                FT_BlendFunc FT_SRC_ALPHA, FT_ONE_MINUS_SRC_ALPHA
                FT_ColorRGB 0, 0, 0
                POP  AF
                LD   E, A
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_RECTS
                LD   BC, 0
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; 1024×768: правый-нижний угол. 1024*16=16384 ПЕРЕПОЛНЯЕТ 15-битный
                ; signed VERTEX2F (max +16383) — рект уезжал в минус и НЕ закрывал
                ; экран: фейды не работали, переходы шли через мусор вместо чёрного.
                ; Кламп 16383 = 1023.94px; непокрытые 1/16 px правой кромки невидимы.
                LD   BC, 16383
                LD   DE, 768 * 16
                CALL FT.Coprocessor.Vertex2f
                FT_End
                FT_RestoreContext
                RET

; Adventure state vars выделены в loader_resident.asm (Core module); здесь aliases,
; чтобы bare references в TSLib-region code (FadeIn/Out etc) still resolve.
ADVENTURE_LEVEL_COUNT EQU 22
FadeAlpha          EQU Core.FadeAlpha
CurrentDifficulty  EQU Core.CurrentDifficulty
CurrentLevel       EQU Core.CurrentLevel
CurrentSettingIndex EQU Core.CurrentSettingIndex
CurrentGameMode    EQU Core.CurrentGameMode
AdventurePos       EQU Core.AdventurePos

                include "level_runtime_table.inc"

SPACE_LEVEL_INDEX      EQU LEVEL_RUNTIME_COUNT - 1      ; board 22 / Space: final WIN-only board
LAST_NORMAL_LEVEL_INDEX EQU LEVEL_RUNTIME_COUNT - 2      ; board 21 / Inverse Spiral
LEVEL_SELECT_COUNT     EQU LEVEL_RUNTIME_COUNT - 1      ; level-select exposes boards 1..21 only
ADVENTURE_SPACE_POS    EQU ADVENTURE_CHAIN_COUNT - 1    ; final Adventure entry is Space
ADVENTURE_RANK2_POS    EQU 15
ADVENTURE_RANK3_POS    EQU 33
ADVENTURE_RANK4_POS    EQU 54

; Level-select thumbnails — raw ARGB4 streams из ZUMALVL.PAK.
; Два RAM_G buffers позволяют Back/Next грузить новый thumbnail, не трогая
; RAM_G region, на которую ещё ссылается текущий display list.
LS_PREVIEW_BG_RAMG_B     EQU #0B3000
LS_PREVIEW_BG_RAMG_A     EQU #0D4000
LS_PREVIEW_BG_RAMG       EQU LS_PREVIEW_BG_RAMG_A
LS_PREVIEW_BG_X          EQU 177                          ; 640-логика (для пропорций)
LS_PREVIEW_BG_Y          EQU 240
LS_PREVIEW_BG_SX         EQU 283                          ; 177×1.6 — экранная позиция превью
LS_PREVIEW_BG_SY         EQU 384                          ; 240×1.6
LS_PREVIEW_BG_DRAW_W     EQU 490                          ; 306×1.6 (окно при scale(1.6)-матрице)
LS_PREVIEW_BG_DRAW_H     EQU 314                          ; 196×1.6
LS_PREVIEW_BG_W          EQU 306
LS_PREVIEW_BG_H          EQU 196
LS_PREVIEW_BG_HANDLE     EQU 6

LevelSelectPreviewDrawRamL:  DEFW LS_PREVIEW_BG_RAMG_A & #FFFF
LevelSelectPreviewDrawRamH:  DEFB (LS_PREVIEW_BG_RAMG_A >> 16) & #FF
LevelSelectPreviewLoadRamL:  DEFW LS_PREVIEW_BG_RAMG_A & #FFFF
LevelSelectPreviewLoadRamH:  DEFB (LS_PREVIEW_BG_RAMG_A >> 16) & #FF
LevelSelectPreviewActiveBuf: DEFB 0
LevelSelectPreviewLoadBuf:   DEFB 0

                include "level_select_preview_markers.inc"
                include "level_select_preview_spg.inc"

DrawLevelSelectPreview:
                FT_End
                ; 1024×768: превью ×1.6. РЕЗИДЕНТНЫЙ эмиттер: превью-цепочка идёт
                ; БЕЗ маппинга #04 (machinery resident) — #04-хелпер тут недоступен!
                CALL Core.Resident_EmitScale16
                FT_BitmapHandle LS_PREVIEW_BG_HANDLE
                LD   B, #01                             ; BITMAP_SOURCE
                LD   A, (LevelSelectPreviewDrawRamH)
                LD   C, A
                LD   DE, (LevelSelectPreviewDrawRamL)
                CALL FT.Coprocessor.Command_BCDE
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_BG_W * 2, LS_PREVIEW_BG_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, LS_PREVIEW_BG_DRAW_W, LS_PREVIEW_BG_DRAW_H
                FT_Begin FT_BITMAPS
                FT_Vertex2ii LS_PREVIEW_BG_SX, LS_PREVIEW_BG_SY, LS_PREVIEW_BG_HANDLE, 0
                FT_End
                CALL LevelSelectDrawPreviewMarkers
                JP   DrawLevelSelectTitle

DrawLevelSelectTitle:
                CALL Core.Resident_EmitScale16          ; глифы названия ×1.6 (резидент)
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                CALL SetFontNative
                FT_Begin FT_BITMAPS
                CALL Core.GetCurrentLevelTitlePtr
                LD   (LevelTitlePtrTmp), HL
                CALL StrWidth
                LD   HL, 640
                AND  A
                SBC  HL, DE
                SRL  H
                RR   L
                CALL HudScaleXTo16                      ; (640−W)/2 в 640-логике → ×8/5 экран, ×16
                LD   B, H
                LD   C, L
                LD   DE, (382 * 8 / 5) * 16
                LD   HL, (LevelTitlePtrTmp)
                JP   DrawString

DrawKillzoneDual:
                ; Рисовать каждый frame. При 400x300 PALETTED4444 bg запечённая
                ; kill-zone area заметно деградирует, поэтому overlay закрывает и
                ; idle KzFrame=1.
                CALL UpdateKillzoneDrawXY
DrawKillzoneAfterXY:
                CALL Core.ZL_EmitScale16Matrix        ; 1024×768: scale 1.6 точным блоком (88→141)
                FT_BitmapHandle 3
                FT_PaletteSource Core.KZ_PALETTE_RAMG
                FT_BitmapSource Core.KZ_RAMG_ADDR
                FT_BitmapLayout FT_PALETTED4444, KZ_SPR_W, KZ_SPR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, KZ_SPR_DRAW, KZ_SPR_DRAW
                ; FT.Coprocessor.Cell корраптит BC/DE → загружаем coords ПОСЛЕ Cell.
                ; top-left = (KZ_DEFAULT_X/Y - half) in 1/16 px.
                ; --- pass 1: hole (Cell 0) ---
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (KzDrawX16)
                LD   DE, (KzDrawY16)
                CALL FT.Coprocessor.Vertex2f
                ; --- pass 2: skull frame ---
                LD   A, (Core.VDC_KzFrame)
                LD   B, A
                LD   A, (CurrentLevel)
                CP   18
                LD   A, B
                JR   NZ, .kz1_have_frame
                LD   A, (Core.VDC_GameState)
                CP   3
                LD   A, B
                JR   NC, .kz1_have_frame
                LD   A, (Core.VDC2_KzFrame)
                CP   B
                JR   NC, .kz1_have_frame
                LD   A, B
.kz1_have_frame:
                CALL FT.Coprocessor.Cell
                LD   BC, (KzDrawX16)
                LD   DE, (KzDrawY16)
                CALL FT.Coprocessor.Vertex2f

                LD   A, (Core.VDC_HasSecondChain)
                OR   A
                RET  Z
                LD   A, (CurrentLevel)
                CP   18
                RET  Z
                JP   DrawSecondKillzoneDual

DrawSecondKillzoneDual:
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (Core.VDC2_KzDrawX16)
                LD   DE, (Core.VDC2_KzDrawY16)
                CALL FT.Coprocessor.Vertex2f
                ; --- кадр черепа цепочки 2 ---
                ; В PLAY (0) и ABSORB (1) у каждой килл-зоны свой череп: насколько
                ; близко СВОЯ цепочка — VDC2_KzFrame обновляет CheckKillzone цепочки 2.
                ; В INTRO/PREVIEW/CLOSING/GAMEOVER/WIN анимация черепа — событие ВСЕЙ
                ; игры (closing 11→1 и т.п.), но её гоняет только VDC_Update на цепочке 1
                ; (VDC_KzFrame); VDC2_KzFrame в эти фазы застывает → черепа рассинхрон.
                ; Поэтому в не-PLAY/ABSORB рисуем оба черепа общим VDC_KzFrame.
                LD   A, (Core.VDC_GameState)
                CP   3                                    ; <3 = PLAY/ABSORB/GAMEOVER → свой кадр
                LD   A, (Core.VDC2_KzFrame)
                JR   C, .ks2_have_frame
                LD   A, (Core.VDC_KzFrame)                ; >=2 → общий кадр цепочки 1
.ks2_have_frame:
                CALL FT.Coprocessor.Cell
                LD   BC, (Core.VDC2_KzDrawX16)
                LD   DE, (Core.VDC2_KzDrawY16)
                JP   FT.Coprocessor.Vertex2f

UpdateKillzoneDrawXY:
                CALL Core.GetCurrentKzX
                LD   DE, KZ_SPR_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                LD   (KzDrawX16), HL
                CALL Core.GetCurrentKzY
                LD   DE, KZ_SPR_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                LD   (KzDrawY16), HL
                RET

KzDrawX16:      DEFW 0
KzDrawY16:      DEFW 0

; ----------------------------------------------------------------------------
; DrawGameOverText — рисует "GAME OVER" в nativealien48 шрифте, центр X
; (320 - W/2 = 320 - 66 = 254), Y = 72 (как было с cmd_text).
; ----------------------------------------------------------------------------
DrawGameOverText:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB                ; tint = white (gradient уже в bitmap)
                FT_BitmapHandle TEXT_GAMEOVER_HANDLE
                FT_BitmapSource TEXT_GAMEOVER_RAMG
                FT_BitmapLayout FT_ARGB4, TEXT_GAMEOVER_W * 2, TEXT_GAMEOVER_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, TEXT_GAMEOVER_W, TEXT_GAMEOVER_H
                XOR  A : CALL FT.Coprocessor.Cell           ; Cell 0
                LD   BC, (320 - TEXT_GAMEOVER_W / 2) * 16   ; X centered
                LD   DE, 72 * 16
                JP   FT.Coprocessor.Vertex2f

; ============================================================================
; UpdateDialog — диалог game-over обработка click anywhere → restart.
; Вызывается каждый кадр ДО Frog_Update (чтобы dialog click не триггерил bullet).
; ============================================================================
UpdateDialog:
                LD   A, (Core.VDC_DialogState)
                OR   A
                RET  Z                                  ; диалог не показан
                LD   A, 1
                LD   (Core.VDC_HudPointerBlock), A      ; dialog забирает LMB на этот кадр
                LD   A, (Core.VDC_DialogState)
                CP   3
                JP   Z, Core.UpdatePauseDialog
                CP   4
                JP   Z, Core.UpdatePauseFade            ; pause window fade-out -> PLAY
                CP   Core.DLG_WIN_FADE
                JP   Z, .udlg_win_fade                  ; LEVEL DONE → OK нажат → fade-out

                ; --- Клавиша огня (Space|Enter|Kempston) — минуя hit-test. ЛКМ ниже. ---
                CALL Core.Input_FireKey
                JR   NZ, .udlg_fire_check_edge         ; нажата
                ; Огонь отпущен — сброс debounce
                XOR  A
                LD   (DialogFirePrev), A
                JR   .udlg_check_lmb
.udlg_fire_check_edge:
                LD   A, (DialogFirePrev)
                OR   A
                JR   NZ, .udlg_check_lmb               ; уже было pressed → no edge
                LD   A, 1
                LD   (DialogFirePrev), A
                JP   .udlg_action                       ; rising edge → trigger

.udlg_check_lmb:
                ; --- Считать mouse LMB state, поймать falling edge (release = click) ---
                CALL Core.Input_MouseLMB                ; Z=released, NZ=pressed
                LD   A, 0
                JR   Z, .udlg_lmb_set
                INC  A
.udlg_lmb_set:  LD   C, A                               ; C = current LMB (0/1)
                LD   A, (Core.VDC_PrevMouseL)
                LD   B, A                               ; B = previous LMB
                LD   A, C
                LD   (Core.VDC_PrevMouseL), A           ; сохранить для next frame
                ; Falling edge: было pressed (B=1), стало released (C=0) → CLICK
                LD   A, B
                OR   A
                RET  Z                                  ; не было pressed → нет клика
                LD   A, C
                OR   A
                RET  NZ                                 ; ещё pressed → нет клика
                ; --- Hit-test: курсор должен быть в bounds OK button ---
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, DLG_OK_X
                AND  A
                SBC  HL, DE
                RET  C
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, DLG_OK_X + DIALOG_OK_DRAW_W
                AND  A
                SBC  HL, DE
                RET  NC
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, DLG_OK_Y
                AND  A
                SBC  HL, DE
                RET  C
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, DLG_OK_Y + DIALOG_OK_DRAW_H
                AND  A
                SBC  HL, DE
                RET  NC

.udlg_action:   ; mouse click в bounds OK или нажата Fire key
                LD   A, (Core.VDC_DialogState)
                CP   3
                JR   NC, .udlg_no_lose_sfx             ; только retry/game-over OK, не win/pause
                LD   A, (Core.GS_Present)
                OR   A
                JR   Z, .udlg_no_lose_sfx              ; не добавлять здесь No-GS/AY click
                LD   A, Core.SND_BUTTON1
                CALL Core.GS_PlaySfx
.udlg_no_lose_sfx:
                LD   A, (Core.VDC_DialogState)
                CP   Core.DLG_WIN_DONE
                JR   Z, .udlg_winnext                   ; LEVEL DONE → OK → начать fade
                CP   3
                JR   NZ, .udlg_restart
                XOR  A
                LD   (Core.VDC_DialogState), A          ; PAUSE → resume
                RET
.udlg_winnext:  LD   A, Core.DLG_WIN_FADE               ; OK на LEVEL DONE → fade-out фаза
                LD   (Core.VDC_DialogState), A
                RET
.udlg_restart:
                LD   A, (Core.VDC_DialogState)
                CP   2                                  ; GAME_OVER_FINAL (lives=0) -> main menu
                JR   Z, .udlg_final_game_over
                LD   A, (CurrentGameMode)
                OR   A
                JR   Z, RestartLevel
                LD   A, (CurrentLevel)
                CP   SPACE_LEVEL_INDEX
                JR   NZ, RestartLevel
                LD   A, LAST_NORMAL_LEVEL_INDEX         ; bonus 22-4 lose/retry -> 21-4
                LD   (CurrentLevel), A
                LD   A, 3
                LD   (CurrentDifficulty), A
                XOR  A
                LD   (Core.VDC_DialogState), A
                LD   (DialogFirePrev), A
                POP  HL                                 ; бросить MainLoop CALL UpdateDialog
                JP   FadeGameplayToCurrentLevel
.udlg_final_game_over:
                ASSERT Core.VDC_DialogState == Core.VDC_Lives + 1
                LD   HL, 3
                LD   (Core.VDC_Lives), HL               ; lives=3, dialog=0 (bytes are adjacent)
                CALL Score_Reset                        ; следующий run из меню стартует со score 0
                POP  HL                                 ; бросить MainLoop CALL UpdateDialog
                JP   FadeGameplayToMenu

; --- LEVEL DONE fade-out: рампим FadeAlpha до чёрного, потом грузим след. уровень.
; Сцена (поле + диалог) + DrawFadeOverlay рисуются в ZL_DrawFrame каждый кадр.
.udlg_win_fade: LD   A, (FadeAlpha)
                CP   255
                JR   Z, .uwf_done                       ; полностью чёрный → advance
                ADD  A, Core.VDC_WIN_FADE_STEP
                JR   NC, .uwf_store
                LD   A, 255                             ; ограничить до полного black
.uwf_store:     LD   (FadeAlpha), A
                RET
.uwf_done:      XOR  A
                LD   (Core.VDC_DialogState), A
                JP   Core.LoadNextLevelWithLoading      ; чёрный экран → LOADING LEVEL N-M... → загрузить assets

DialogFirePrev: DEFB 0                                  ; SPACE/Fire debounce для dialog OK
DialogFrameLoaded: DEFB 0                               ; 1 если DIALOG_FRAME_RAMG сейчас содержит окно диалога

RestartLevel:
                XOR  A
                LD   (Core.VDC_DialogState), A          ; скрыть диалог
                CALL Core.SetCurrentTrackPage           ; dialog lazy upload leaves slot 2 on DIALOG_FRAME pages
                CALL Core.VDC_Init                      ; chain reset, state=INTRO
                CALL Core.Frog_Init
                CALL Core.Bullet_Init
                RET

; ============================================================================
; DrawRetryDialog — рендер диалога: frame + title + 5 stat lines.
; ============================================================================
DrawRetryDialog:
                LD   A, (Core.VDC_DialogState)
                OR   A
                RET  Z
                CALL Core.EnsureDialogFrameUploaded
                OR   A
                RET  Z

                ; --- Dialog frame (400×327 PALETTED4444) ---
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   A, 255
                CALL Core.PauseColorA
                FT_PaletteSource DIALOG_PALETTE_RAMG
                FT_BitmapHandle DIALOG_FRAME_HANDLE
                FT_BitmapSource DIALOG_FRAME_RAMG
                FT_BitmapLayout FT_PALETTED4444, DIALOG_FRAME_W, DIALOG_FRAME_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, DIALOG_FRAME_DRAW_W, DIALOG_FRAME_DRAW_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, DIALOG_FRAME_X * 16
                LD   DE, DIALOG_FRAME_Y * 16
                CALL FT.Coprocessor.Vertex2f

                ; --- Title + 5 stat lines (native font glyph blit) ---
                ; Pick title string по VDC_Lives, центруется DrawStringCentered.
                CALL DrawDialogContent
                RET

; ----------------------------------------------------------------------------
; DrawIntroText — нижний правый угол: LEVEL N-M + название текущего уровня.
; Используется когда VDC_GameState == INTRO.
; Layout считается в 640-space и масштабируется ×8/5 в 1024×768:
;   LEVEL N-M: центрируется по 640-space, Y=382×1.6
;   Название уровня: 30px nativealien, отдельный draw path.
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; DrawPreviewSparkles — sparkle wave анимация по track (state=PREVIEW).
; Параметры:
;   PREVIEW_SPARKLE_COUNT sparkles, head_sample = elapsed * PREVIEW_SPARKLE_SPEED,
;   trail spacing = PREVIEW_SPARKLE_SPACING samples.
; Sparkle пропускается, если sample < 0 или sample >= NumSamples (head ещё не дошёл / уже прошёл).
; Tint: warm gold. Caller восстанавливает белый ColorRGB.
; Активные Track V2 pages выбирает SetCurrentTrackPage.
; ----------------------------------------------------------------------------
; Comet: 8 sparkles с шагом 16 samples = ~128 samples trail (короткая «очередь»),
; head проходит 15 samples/tick; VDC_PREVIEW_TICKS даёт проход всего трека.
PREVIEW_SPARKLE_COUNT   EQU 8
PREVIEW_SPARKLE_SPEED   EQU 15
PREVIEW_SPARKLE_SPACING EQU 16

DrawPreviewSparkles:
                LD   C, 255 : LD D, 220 : LD E, 80
                CALL FT.Coprocessor.ColorRGB
                CALL Core.ZL_EmitScale16Matrix         ; 1024×768: sparkle 24→38 (позиции с трека уже 1024)
                FT_BitmapHandle SPARKLE_HANDLE
                FT_BitmapSource SPARKLE_RAMG
                FT_BitmapLayout FT_ARGB4, SPARKLE_W * 2, SPARKLE_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, SPARKLE_DRAW, SPARKLE_DRAW
                XOR  A : CALL FT.Coprocessor.Cell

                ; head_sample = elapsed * PREVIEW_SPARKLE_SPEED
                ; где elapsed = PREVIEW_TICKS - VDC_PreviewTick
                LD   A, Core.VDC_PREVIEW_TICKS
                LD   HL, Core.VDC_PreviewTick
                SUB  (HL)                              ; A = elapsed
                LD   H, 0 : LD L, A
                LD   D, H : LD E, L                    ; DE = elapsed
                LD   HL, 0
                LD   B, PREVIEW_SPARKLE_SPEED
.dps_mul:       ADD  HL, DE
                DJNZ .dps_mul
                LD   (.dps_sample), HL

                LD   A, PREVIEW_SPARKLE_COUNT
                LD   (.dps_count), A
.dps_loop:      LD   HL, (.dps_sample)
                ; sample >= 0?
                BIT  7, H
                JR   NZ, .dps_advance
                ; sample < NumSamples?
                LD   DE, (Core.VDC_ActiveTrackSamples) ; NumSamples из Track V2 metadata
                AND  A
                SBC  HL, DE
                JR   NC, .dps_advance                  ; sample >= NumSamples
                ADD  HL, DE                            ; restore sample
                CALL Core.VDC_ReadSampleAtHL           ; BC=X, DE=Y из Track V2
                LD   (.dps_xword), BC
                LD   (.dps_yword), DE
                ; BC = (X-12) * 16
                LD   DE, (.dps_xword)
                LD   HL, -SPARKLE_HALF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                ; DE = (Y-12) * 16
                LD   DE, (.dps_yword)
                LD   HL, -SPARKLE_HALF
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                EX   DE, HL
                CALL FT.Coprocessor.Vertex2f
.dps_advance:
                LD   HL, (.dps_sample)
                LD   DE, -PREVIEW_SPARKLE_SPACING
                ADD  HL, DE
                LD   (.dps_sample), HL
                LD   A, (.dps_count)
                DEC  A
                LD   (.dps_count), A
                JR   NZ, .dps_loop
                RET
.dps_sample:    DW 0
.dps_count:     DB 0
.dps_xword:     DW 0
.dps_yword:     DW 0

DrawPreviewSparklesAll:
                CALL DrawPreviewSparkles
                LD   A, (Core.VDC_HasSecondChain)
                OR   A
                RET  Z
                CALL Core.SetSecondTrackPage
                CALL DrawPreviewSparkles
                JP   Core.SetCurrentTrackPage

; ----------------------------------------------------------------------------
; DrawFrameStrips — 4 PALETTED4444 strip'а вокруг прозрачного центра.
; 1024×768: frame strips хранятся в 640×480 layout и рисуются одной точной
; scale(1.6)-матрицей.
; ----------------------------------------------------------------------------
DrawFrameStrips:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                ; 1024×768: одна ТОЧНАЯ scale(1.6)-матрица (запечённый блок) на все 4
                ; рамки. Helper в #04 (Core), замаплен во время gameplay (зовёт MainLoop).
                CALL Core.ZL_EmitScale16Matrix
                FT_PaletteSource FRAME_PAL_RAMG
                XOR  A : CALL FT.Coprocessor.Cell
                ; --- TOP draw 1024×70 at (0, 0) ---
                FT_BitmapHandle FRAME_TOP_HANDLE
                FT_BitmapSource FRAME_TOP_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_TOP_W, FRAME_TOP_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_TOP_DRAW_W, FRAME_TOP_DRAW_H
                LD   BC, 0
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; --- BOTTOM draw 1024×38 at (0, 768-38) ---
                FT_BitmapHandle FRAME_BOT_HANDLE
                FT_BitmapSource FRAME_BOT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_BOT_W, FRAME_BOT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_BOT_DRAW_W, FRAME_BOT_DRAW_H
                LD   BC, 0
                LD   DE, (768 - FRAME_BOT_DRAW_H) * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- LEFT draw 38×659 at (0, 70) ---
                FT_BitmapHandle FRAME_LEFT_HANDLE
                FT_BitmapSource FRAME_LEFT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_LEFT_W, FRAME_LEFT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_LEFT_DRAW_W, FRAME_LEFT_DRAW_H
                LD   BC, 0
                LD   DE, FRAME_TOP_DRAW_H * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- RIGHT draw 38×659 at (1024-38, 70) ---
                FT_BitmapHandle FRAME_RIGHT_HANDLE
                FT_BitmapSource FRAME_RIGHT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_RIGHT_W, FRAME_RIGHT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_RIGHT_DRAW_W, FRAME_RIGHT_DRAW_H
                LD   BC, (1024 - FRAME_RIGHT_DRAW_W) * 16
                LD   DE, FRAME_TOP_DRAW_H * 16
                JP   FT.Coprocessor.Vertex2f

; ----------------------------------------------------------------------------
; DrawLivesCounter — рендерит N жаб-иконок (20×20 PALETTED4444) в life sock
; верхней рамки.  N = min(VDC_Lives, LIFE_MAX_DRAW).  Вызов каждый frame после
; DrawFrameStrips (поверх sock'а), но под cursor'ом.
; ----------------------------------------------------------------------------
DrawLivesCounter:
                LD   A, (Core.VDC_Lives)
                OR   A
                RET  Z                                  ; 0 жизней → ничего не рисуем
                CP   LIFE_MAX_DRAW + 1
                JR   C, .lc_count_ok
                LD   A, LIFE_MAX_DRAW                   ; ограничить displayed count
.lc_count_ok:   LD   (LifeDrawCnt), A

                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource HUD_PALETTE_RAMG
                FT_Begin FT_BITMAPS
                FT_BitmapHandle LIFE_FROG_HANDLE
                FT_BitmapSource LIFE_FROG_RAMG
                FT_BitmapLayout FT_PALETTED4444, LIFE_FROG_W, LIFE_FROG_W
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LIFE_FROG_DRAW, LIFE_FROG_DRAW
                XOR  A : CALL FT.Coprocessor.Cell

                LD   HL, LIFE_SOCK_X * 16               ; HL = текущий x в 1/16 px
                LD   A, (LifeDrawCnt)
                LD   B, A                               ; B = loop counter
.lc_loop:       PUSH HL
                PUSH BC
                LD   B, H : LD C, L                     ; BC = x*16
                LD   DE, LIFE_SOCK_Y * 16
                CALL FT.Coprocessor.Vertex2f
                POP  BC
                POP  HL
                LD   DE, LIFE_STEP * 16
                ADD  HL, DE                             ; продвинуть x на 20*16
                DJNZ .lc_loop
                RET

LifeDrawCnt:    DEFB 0                                  ; временный ограниченный lives count

; ----------------------------------------------------------------------------
; UpdateHudMenu — hover/press state для верхней правой MENU button.
; Также поднимает VDC_HudPointerBlock, пока pointer над button, чтобы frog
; не стрелял при клике по HUD.
; ----------------------------------------------------------------------------
UpdateHudMenu:
                JP   Core.UpdateHudMenuCore

; ----------------------------------------------------------------------------
; DrawHudProgress — original Zuma bar sprites в top HUD.
; Запечённый red socket пустой. Yellow заполняется по score; green означает gauge full.
; ----------------------------------------------------------------------------
DrawHudProgress:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource HUD_PALETTE_RAMG
                FT_Begin FT_BITMAPS
                FT_BitmapHandle 19
                FT_BitmapSource HUD_PROGRESS_RAMG
                FT_BitmapLayout FT_PALETTED4444, HUD_PROGRESS_W, HUD_PROGRESS_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, HUD_PROGRESS_DRAW_W, HUD_PROGRESS_DRAW_H
                LD   A, (Core.VDC_GaugeFull)
                OR   A
                JR   Z, .dhp_yellow
                FT_ScissorXY HUD_PROGRESS_X, HUD_PROGRESS_Y
                FT_ScissorSize HUD_PROGRESS_DRAW_W, HUD_PROGRESS_DRAW_H
                XOR  A                                 ; green fill
                JR   .dhp_draw
.dhp_yellow:
                LD   HL, (Core.VDC_GaugeShown)          ; animated value, smooth fill
                LD   A, H
                OR   L
                RET  Z                                  ; empty: baked red socket remains
                ; fill_px = GaugeShown * HUD_PROGRESS_W / target (РЕАЛЬНЫЙ per-level
                ; target, не фикс. 1000). Чтобы не делить на переменную (overflow +
                ; нет Div16x16): d = target/63, затем fill = GaugeShown/d — два 16/8.
                PUSH HL                                 ; save GaugeShown
                CALL Core.GetCurrentTargetScore         ; DE = per-level target
                EX   DE, HL                             ; HL = target
                LD   A, HUD_PROGRESS_DRAW_W             ; 101 (fill в экранных px)
                CALL Core.VDC_DivHLbyA                  ; HL = target / 101 = d
                LD   A, L
                OR   A
                JR   NZ, .dhp_dok
                INC  A                                  ; target < 63 → d = 1
.dhp_dok:       LD   C, A                               ; C = divisor d (≤63)
                POP  HL                                 ; HL = GaugeShown
                LD   A, C
                CALL Core.VDC_DivHLbyA                  ; HL = GaugeShown / d = fill_px
                LD   A, H
                OR   A
                JR   NZ, .dhp_clampmax                  ; quotient > 255 → ограничить
                LD   A, L
                OR   A
                JR   NZ, .dhp_clamp_check
                INC  A                                  ; min visible 1 px если score>0
.dhp_clamp_check:
                CP   HUD_PROGRESS_DRAW_W
                JR   C, .dhp_have_width_a
.dhp_clampmax:  LD   A, HUD_PROGRESS_DRAW_W
.dhp_have_width_a:
                LD   (DhpFillPx), A                     ; B/BC клобается FT_ScissorXY ниже,
                                                        ; поэтому fill_px храним в памяти
.dhp_have_width:
                FT_ScissorXY HUD_PROGRESS_X, HUD_PROGRESS_Y
                LD   A, (DhpFillPx)                     ; восстановить fill_px после FT_ScissorXY
                CALL EmitScissorSizeAProgress
                LD   A, 1                               ; yellow fill
.dhp_draw:
                CALL FT.Coprocessor.Cell
                LD   BC, HUD_PROGRESS_X * 16
                LD   DE, HUD_PROGRESS_Y * 16
                CALL FT.Coprocessor.Vertex2f
                FT_ScissorXY 0, 0
                FT_ScissorSize 1024, 768               ; 1024×768: иначе всё ниже Y=480 клипается (часы и низ экрана)
                RET

DhpFillPx:      DEFB 0                                  ; scratch для DrawHudProgress fill_px

EmitScissorSizeAProgress:
                AND  #7F
                LD   L, A
                AND  #0F
                RLCA
                RLCA
                RLCA
                RLCA
                LD   D, A
                LD   E, HUD_PROGRESS_DRAW_H
                LD   A, L
                SRL  A
                SRL  A
                SRL  A
                SRL  A
                LD   C, A
                LD   B, #1C
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; DrawHudMenu — правая верхняя кнопка MENU, cells: 0=idle/1=hover/2=pressed.
; Рисуем ВСЕГДА (и idle): запечённая в frame_top кнопка прокрашена ПАЛИТРОЙ
; РАМКИ (жёлтый текст сквантован в зелёный — «зелень» по краям ховера).
; Атлас с hud-палитрой кладётся точно поверх неё (та же позиция 539,3 ×1.6).
; ----------------------------------------------------------------------------
DrawHudMenu:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource HUD_PALETTE_RAMG
                FT_Begin FT_BITMAPS
                FT_BitmapHandle 20
                FT_BitmapSource HUD_MENU_RAMG
                FT_BitmapLayout FT_PALETTED4444, HUD_MENU_W, HUD_MENU_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, HUD_MENU_DRAW_W, HUD_MENU_DRAW_H
                LD   A, (Core.VDC_HudMenuState)
                OR   A
                JR   Z, .cell
                LD   B, A
                LD   A, 3
                SUB  B                                 ; в атласе hover/pressed лежат наоборот:
                                                       ; state 1(hover)→cell 2, state 2(pressed)→cell 1
.cell:          CALL FT.Coprocessor.Cell
                LD   BC, HUD_MENU_X16
                LD   DE, HUD_MENU_Y16
                JP   FT.Coprocessor.Vertex2f

DrawIntroText:
                ; --- Fade-out alpha: VDC_IntroTick 240→0; последние 60 ticks fade ---
                ; alpha = (tick<60) ? tick*4 : 255
                LD   A, (Core.VDC_IntroTick)
                CP   60
                JR   NC, .dit_full_alpha
                ADD  A, A
                ADD  A, A                              ; A = tick*4 (max 4*59=236)
                JR   .dit_alpha_set
.dit_full_alpha:
                LD   A, 255
.dit_alpha_set:
                LD   E, A
                CALL FT.Coprocessor.ColorA

                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB

                ; --- Собрать "LEVEL N-M" dynamically (N=CurrentLevel+1, M=CurrentDifficulty+1).
                ; Заменяет запечённую "LEVEL 1-1": теперь реальный номер уровня/сложности. ---
                LD   HL, .dit_level_prefix             ; "LEVEL "
                LD   DE, IntroLevelBuf
                LD   BC, 6
                LDIR                                    ; скопировать "LEVEL " → DE после него
                LD   A, (CurrentLevel)
                INC  A                                  ; N = 1..22
                LD   B, '0'
.dit_n_tens:    CP   10
                JR   C, .dit_n_units
                SUB  10
                INC  B
                JR   .dit_n_tens
.dit_n_units:   LD   C, A                               ; C = units (0..9)
                LD   A, B
                CP   '0'
                JR   Z, .dit_n_skip
                LD   (DE), A : INC DE                   ; tens (no leading zero)
.dit_n_skip:    LD   A, C : ADD A, '0'
                LD   (DE), A : INC DE                   ; units
                LD   A, '-'
                LD   (DE), A : INC DE
                LD   A, (CurrentDifficulty)
                INC  A                                  ; M = 1..4
                ADD  A, '0'
                LD   (DE), A : INC DE
                XOR  A
                LD   (DE), A                            ; null term

                ; --- LEVEL N-M: native-48 шрифт, рисуется 1:1 (БЕЗ cmd_scale upscale),
                ;     right-align к x=610. Раньше был 30px-атлас ×2 = мыльный upscale. ---
                CALL SetFontLevel48
                CALL Core.ZL_EmitScale16Matrix          ; 1024×768: глифы ×1.6
                LD   A, 3
                LD   (DrawStr_Scale), A                 ; 3 = ×1.6 advance (матрица выше)
                FT_Begin FT_BITMAPS
                LD   HL, IntroLevelBuf
                CALL StrWidth                            ; DE = native-48 width (атлас)
                LD   HL, 610
                AND  A
                SBC  HL, DE                              ; x в 640-space (право 610 ↔ экран 976)
                CALL HudScaleXTo16                       ; ×8/5 → screen, ×16
                LD   B, H : LD C, L
                LD   DE, ((480 - TEXT_SPIRALDOOM_H - 90) * 8 / 5) * 16   ; Y ×1.6
                LD   HL, IntroLevelBuf
                CALL DrawString
                CALL Core.SetCurrentTrackPage            ; SetFontLevel48 temporarily maps slot 2 to font metadata

                ; --- Selected level title (30px nativealien, строка ниже) ---
                CALL SetFontNative
                CALL Core.GetCurrentLevelTitlePtr
                LD   (LevelTitlePtrTmp), HL
                CALL StrWidth
                LD   HL, 610
                AND  A
                SBC  HL, DE                              ; x в 640-space
                CALL HudScaleXTo16                       ; ×8/5 → screen, ×16
                LD   B, H : LD C, L
                LD   DE, ((480 - TEXT_SPIRALDOOM_H - 30) * 8 / 5) * 16
                LD   HL, (LevelTitlePtrTmp)
                JP   DrawString
.dit_level_prefix: DB "LEVEL "

; ============================================================================
; DrawDialogContent — title + 5 stat lines, glyph blit через nativealien font.
; ============================================================================
; 1024×768: все позиции ×1.6 (экранные координаты; глифы/спрайты масштабирует
; активная scale(1.6)-матрица диалога).
DLG_TITLE_Y     EQU 256                                 ; 160×1.6
DLG_STATS_Y    EQU 333                                  ; 208×1.6
DLG_STATS_X_L  EQU 264                                 ; 165×1.6
DLG_STATS_X_R  EQU 570                                 ; 356×1.6
DLG_LINE_H     EQU 29                                  ; 18×1.6
DLG_OK_X       EQU 272                                 ; 170×1.6
DLG_OK_Y       EQU 504                                  ; 315×1.6
DLG_OK_W       EQU DIALOG_OK_DRAW_W
DLG_OK_H       EQU DIALOG_OK_DRAW_H
; pause-диалог: ×1.6 (экранные координаты при активной scale(1.6)-матрице)
PAUSE_TITLE_CENTER_X EQU 453                            ; 512 − W×0.3: pause-путь центрует по W/2
                                                        ; (атлас), а экранная полуширина = W×0.8;
                                                        ; компенсация для str_pause_exit (W≈190)
PAUSE_TITLE_Y   EQU 313
PAUSE_YES_X    EQU 359
PAUSE_NO_X     EQU 529
PAUSE_BTN_Y    EQU 435
PAUSE_BTN_W    EQU 136
PAUSE_BTN_H    EQU 61                                   ; 38×1.6
PAUSE_YES_TEXT_X EQU 401
PAUSE_NO_TEXT_X  EQU 574
PAUSE_BTN_TEXT_Y EQU 441

DrawDialogContent:
                ; --- Tint white ONCE ---
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA

                ; --- Setup native font (title) ---
                CALL SetFontNative
                LD   A, (Core.VDC_DialogState)
                CP   Core.DLG_WIN_DONE
                JP   NC, .dc_win_done                    ; 5/6 = LEVEL DONE
                CP   3
                JR   C, .dc_not_pause                    ; 1/2 = game-over content
                JP   Core.DrawPauseDialogContent         ; 3 = pause, 4 = pause fade-out
.dc_not_pause:

                ; --- Title по VDC_Lives ---
                LD   A, (Core.VDC_Lives)
                CP   2
                JR   Z, .dc_title_2
                CP   1
                JR   Z, .dc_title_1
                LD   HL, str_game_over
                JR   .dc_title_draw
.dc_title_2:    LD   HL, str_2_lives
                JR   .dc_title_draw
.dc_title_1:    LD   HL, str_1_lives
.dc_title_draw:
                ; Центруем по ширине. 1024: центр 512, глифы рисует активная
                ; scale(1.6)-матрица → экранная полуширина = W×1.6/2 = W×4/5.
                ; (Мёртвый дубль LD HL,320 удалён.)
                CALL StrWidth                            ; HL ptr → DE = W (атласные px)
                EX   DE, HL
                ADD  HL, HL : ADD HL, HL                 ; 4W
                LD   A, 5
                CALL Core.VDC_DivHLbyA                   ; HL = W×4/5
                EX   DE, HL                              ; DE = экранная полуширина
                LD   HL, 512
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL  ; x*16
                LD   B, H : LD C, L
                LD   DE, DLG_TITLE_Y * 16
                ; Reload string ptr (clobbered)
                LD   A, (Core.VDC_Lives)
                CP   2
                JR   Z, .dc_title_2b
                CP   1
                JR   Z, .dc_title_1b
                LD   HL, str_game_over
                JR   .dc_title_draw2
.dc_title_2b:   LD   HL, str_2_lives
                JR   .dc_title_draw2
.dc_title_1b:   LD   HL, str_1_lives
.dc_title_draw2:
                CALL DrawString

.dc_stats:      ; --- Stats используют отдельный cancun10 atlas. Не трогать
                ; pixel-tuned cancun8 menu/HUD font. (Win-диалог прыгает сюда после
                ; своего заголовка — те же статы, что в Game Over.)
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                LD   A, 1
                LD   (DrawStr_Scale), A                 ; 1024-native pre-rendered stats font
                CALL SetFontCancun10Stats

                ; --- Stats line 1: TIME M:SS ---
                LD   HL, str_time
                LD   BC, DLG_STATS_X_L * 16
                LD   DE, DLG_STATS_Y * 16
                CALL DrawString
                CALL DrawTimeValue

                ; --- Stats line 2: COMBOS N ---
                LD   HL, str_combos
                LD   BC, DLG_STATS_X_L * 16
                LD   DE, (DLG_STATS_Y + DLG_LINE_H) * 16
                CALL DrawString
                LD   A, (Core.VDC_StatCombos)
                CALL DrawByteValue

                ; --- Stats line 3: COINS N ---
                LD   HL, str_coins
                LD   BC, DLG_STATS_X_L * 16
                LD   DE, (DLG_STATS_Y + DLG_LINE_H * 2) * 16
                CALL DrawString
                LD   A, (Core.VDC_StatCoins)
                CALL DrawByteValue

                ; --- Stats line 4 (right col, top): SCORE N ---
                LD   HL, str_score_label
                LD   BC, DLG_STATS_X_R * 16
                LD   DE, DLG_STATS_Y * 16
                CALL DrawString
                CALL DrawScore24                       ; 24-bit cumulative score

                ; --- Stats line 5 (right col): MAX CHAIN N ---
                LD   HL, str_max_chain
                LD   BC, DLG_STATS_X_R * 16
                LD   DE, (DLG_STATS_Y + DLG_LINE_H) * 16
                CALL DrawString
                LD   A, (Core.VDC_StatMaxChain)
                CALL DrawByteValue

                ; --- Stats line 6 (right col): MAX COMBO N ---
                LD   HL, str_max_combo
                LD   BC, DLG_STATS_X_R * 16
                LD   DE, (DLG_STATS_Y + DLG_LINE_H * 2) * 16
                CALL DrawString
                LD   A, (Core.VDC_StatMaxCombo)
                CALL DrawByteValue
                LD   A, 3
                LD   (DrawStr_Scale), A                 ; восстановить legacy 1.6 text mode
                CALL Core.ZL_EmitScale16Matrix          ; OK button/frame assets всё ещё используют scale16
                ; OK button: state 1/2 (game over) И 5/6 (LEVEL DONE). НЕ для 3/4 (pause).
                LD   A, (Core.VDC_DialogState)
                CP   3
                CALL C, DrawDialogOkButton              ; 1/2 → OK
                LD   A, (Core.VDC_DialogState)          ; reload (CALL клобал A)
                CP   Core.DLG_WIN_DONE
                CALL NC, DrawDialogOkButton             ; 5/6 → OK
                RET

.dc_win_done:   ; LEVEL DONE — centered title + OK (та же кнопка/позиция, что Game Over)
                LD   HL, str_level_done
                CALL StrWidth                            ; DE = width (атлас)
                EX   DE, HL
                ADD  HL, HL : ADD HL, HL                 ; 4W
                LD   A, 5
                CALL Core.VDC_DivHLbyA                   ; W×4/5 = экранная полуширина
                EX   DE, HL
                LD   HL, 512
                AND  A
                SBC  HL, DE                              ; x = 512 − W×0.8 (центр экрана)
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, DLG_TITLE_Y * 16
                LD   HL, str_level_done
                CALL DrawString
                JP   .dc_stats                           ; статы (TIME/SCORE/...) + OK, как Game Over

DrawDialogOkButton:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource DIALOG_PALETTE_RAMG
                FT_Begin FT_BITMAPS
                FT_BitmapHandle DIALOG_OK_HANDLE
                FT_BitmapSource DIALOG_OK_RAMG
                FT_BitmapLayout FT_PALETTED4444, DIALOG_OK_W, DIALOG_OK_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, DIALOG_OK_DRAW_W, DIALOG_OK_DRAW_H
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, DLG_OK_X * 16
                LD   DE, DLG_OK_Y * 16
                JP   FT.Coprocessor.Vertex2f

; --- Title strings: lowercase т.к. nativealienextended18 lowercase = декоративный uppercase ---
str_level_done: DB "LEVEL DONE",0
str_game_over:  DB "GAME OVER",0
str_2_lives:    DB "2 LIVES LEFT",0
str_1_lives:    DB "1 LIFE LEFT",0
; --- Stats labels: UPPERCASE т.к. cancun8 содержит ТОЛЬКО uppercase A-Z + digits + symbols ---
str_time:       DB "TIME ",0
str_combos:     DB "COMBOS ",0
str_coins:      DB "COINS ",0
str_max_chain:  DB "MAX CHAIN ",0
str_max_combo:  DB "MAX COMBO ",0
str_score_label: DB "SCORE ",0
str_hud_score:  DB "SCORE",0

LevelTitlePtrTmp: DEFW 0
IntroLevelBuf:    DEFS 12                                ; "LEVEL NN-M" + null, dynamic intro line
LevelTitlePtrTable:
                DW str_level_title_01, str_level_title_02, str_level_title_03, str_level_title_04
                DW str_level_title_05, str_level_title_06, str_level_title_07, str_level_title_08
                DW str_level_title_09, str_level_title_10, str_level_title_11, str_level_title_12
                DW str_level_title_13, str_level_title_14, str_level_title_15, str_level_title_16
                DW str_level_title_17, str_level_title_18, str_level_title_19, str_level_title_20
                DW str_level_title_21, str_level_title_22
str_level_title_01: DB "SPIRAL OF DOOM",0
str_level_title_02: DB "OSPREY TALON",0
str_level_title_03: DB "RIVERBED MOSAIC",0
str_level_title_04: DB "BREATH OF EHECATL",0
str_level_title_05: DB "DARK VORTEX",0
str_level_title_06: DB "SWITCHBACK",0
str_level_title_07: DB "LONG RANGE",0
str_level_title_08: DB "WHEN SPIRALS ATTACK",0
str_level_title_09: DB "MUD SLIDE",0
str_level_title_10: DB "RORSCHACH",0
str_level_title_11: DB "MOUTH OF CENTEOTL",0
str_level_title_12: DB "SNAKE PIT",0
str_level_title_13: DB "SAND GARDEN",0
str_level_title_14: DB "LAIR OF THE MUD SNAKE",0
str_level_title_15: DB "LANDING PAD",0
str_level_title_16: DB "ALTAR OF TLALOC",0
str_level_title_17: DB "CODEX OF MIXTEC",0
str_level_title_18: DB "SHRINE OF QUETZALCOATL",0
str_level_title_19: DB "MIRROR SERPENT",0
str_level_title_20: DB "SUN STONE",0
str_level_title_21: DB "ZUMAIC EXODUS",0
str_level_title_22: DB "SPACE",0


; ============================================================================
; SetFontNative / SetFontCancun8 — переключение текущего шрифта.
;   Устанавливают FontPtr* state vars + emit BITMAP_HANDLE + BITMAP_LAYOUT.
;   Per-glyph DrawString потом эмитит BITMAP_SOURCE + SIZE.
; ============================================================================
SetFontNative:
                LD   HL, font_native_glyph_x
                LD   (FontPtrGlyphX), HL
                LD   HL, font_native_glyph_w
                LD   (FontPtrGlyphW), HL
                LD   HL, font_native_advance
                LD   (FontPtrAdvance), HL
                LD   HL, FONT_NATIVE_RAMG & 0xFFFF
                LD   (FontAtlasLo), HL
                LD   A, (FONT_NATIVE_RAMG >> 16) & 0xFF
                LD   (FontAtlasHi), A
                LD   A, FONT_NATIVE_H
                LD   (FontHeight), A
                FT_BitmapHandle FONT_NATIVE_HANDLE
                FT_BitmapLayout FT_ARGB4, FONT_NATIVE_STRIDE, FONT_NATIVE_H
                RET

; SetFontLevel48 — native-48 шрифт для интро «LEVEL N-M» (рисуется 1:1, без upscale).
SetFontLevel48:
                ; Таблицы глифов живут на отдельной page #23 и читаются через slot 2.
                LD   A, FONT_LEVEL48_META_PAGE
                SetPage2_A
                LD   HL, Core.font_level48_glyph_x
                LD   (FontPtrGlyphX), HL
                LD   HL, Core.font_level48_glyph_w
                LD   (FontPtrGlyphW), HL
                LD   HL, Core.font_level48_advance
                LD   (FontPtrAdvance), HL
                LD   HL, FONT_LEVEL48_RAMG & 0xFFFF
                LD   (FontAtlasLo), HL
                LD   A, (FONT_LEVEL48_RAMG >> 16) & 0xFF
                LD   (FontAtlasHi), A
                LD   A, Core.FONT_LEVEL48_H
                LD   (FontHeight), A
                FT_BitmapHandle FONT_LEVEL48_HANDLE
                FT_BitmapLayout FT_ARGB4, Core.FONT_LEVEL48_STRIDE, Core.FONT_LEVEL48_H
                RET

SetFontCancun8:
                LD   HL, font_cancun8_glyph_x
                LD   (FontPtrGlyphX), HL
                LD   HL, font_cancun8_glyph_w
                LD   (FontPtrGlyphW), HL
                LD   HL, font_cancun8_advance
                LD   (FontPtrAdvance), HL
                LD   HL, FONT_CANCUN8_RAMG & 0xFFFF
                LD   (FontAtlasLo), HL
                LD   A, (FONT_CANCUN8_RAMG >> 16) & 0xFF
                LD   (FontAtlasHi), A
                LD   A, FONT_CANCUN8_H
                LD   (FontHeight), A
                FT_BitmapHandle FONT_CANCUN8_HANDLE
                FT_BitmapLayout FT_ARGB4, FONT_CANCUN8_STRIDE, FONT_CANCUN8_H
                RET

SetFontCancun10Stats:
                LD   HL, font_cancun10_stats_glyph_x
                LD   (FontPtrGlyphX), HL
                LD   HL, font_cancun10_stats_glyph_w
                LD   (FontPtrGlyphW), HL
                LD   HL, font_cancun10_stats_advance
                LD   (FontPtrAdvance), HL
                LD   HL, FONT_CANCUN10_STATS_RAMG & 0xFFFF
                LD   (FontAtlasLo), HL
                LD   A, (FONT_CANCUN10_STATS_RAMG >> 16) & 0xFF
                LD   (FontAtlasHi), A
                LD   A, FONT_CANCUN10_STATS_H
                LD   (FontHeight), A
                FT_BitmapHandle FONT_CANCUN10_STATS_HANDLE
                FT_BitmapLayout FT_ARGB4, FONT_CANCUN10_STATS_STRIDE, FONT_CANCUN10_STATS_H
                RET

FontPtrGlyphX:  DEFW 0
FontPtrGlyphW:  DEFW 0
FontPtrAdvance: DEFW 0
FontAtlasLo:    DEFW 0
FontAtlasHi:    DEFB 0
FontHeight:     DEFB 0

; ============================================================================
; DrawString — glyph-blit zero-terminated string в текущем шрифте.
;   Вход:  HL = string ptr, BC = start x*16, DE = y*16. Font state из FontPtr*.
;   Выход: (DrawStr_CurX) = end x*16
;   Клобает всё.
; ============================================================================
DrawString:
                LD   (DrawStr_Ptr), HL
                LD   (DrawStr_CurX), BC
                LD   (DrawStr_Y), DE
.ds_loop:       LD   HL, (DrawStr_Ptr)
                LD   A, (HL)
                INC  HL
                LD   (DrawStr_Ptr), HL
                OR   A
                RET  Z                                  ; конец строки
                CP   128
                JR   NC, .ds_loop                       ; пропустить non-ASCII

                ; --- Найти glyph metadata: BC = char index (0..127) ---
                LD   C, A
                LD   B, 0

                ; advance := (FontPtrAdvance)[A]
                LD   HL, (FontPtrAdvance)
                ADD  HL, BC
                LD   A, (HL)
                OR   A
                JR   Z, .ds_loop                        ; advance=0 → неизвестный char, пропуск
                LD   (DrawStr_Adv), A

                ; glyph_w := (FontPtrGlyphW)[A]
                LD   HL, (FontPtrGlyphW)
                ADD  HL, BC
                LD   A, (HL)
                OR   A
                JR   Z, .ds_advance_only                ; w=0 (space) → только advance

                ; Emit BITMAP_SIZE. DrawStr_Scale=1 — настоящий native-size path для
                ; pre-rendered 1024 HUD/stats glyphs. Scale=3 оставлен для 1.6
                ; runtime-transform path у nativealien assets.
                LD   H, 0
                LD   L, A                               ; HL = w
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_size_ready                  ; 1: native
                JR   Z, .ds_size_2x                     ; 2: ×2
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; ×8
                LD   A, 5
                CALL Core.VDC_DivHLbyA                  ; w×8/5 (экранное окно)
                JR   .ds_size_ready
.ds_size_2x:     ADD  HL, HL
.ds_size_ready:
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<3
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<6
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<9 (w << 9)
                LD   A, (FontHeight)
                LD   B, A
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_height_ready
                SLA  B                                  ; FontHeight *= 2 (legacy safe window)
.ds_height_ready:
                LD   E, B : LD D, 0
                ADD  HL, DE                             ; HL = (w<<9)|H
                LD   B, #08
                LD   C, 0
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                ; --- Эмит BITMAP_SOURCE = atlas_base + glyph_x * 2 ---
                LD   HL, (DrawStr_Ptr)
                DEC  HL                                  ; назад к текущему char
                LD   A, (HL)
                LD   C, A : LD B, 0
                LD   HL, (FontPtrGlyphX)
                ADD  HL, BC : ADD HL, BC                ; *2 (word table)
                LD   E, (HL) : INC HL
                LD   D, (HL)                             ; DE = glyph_x (pixels)
                EX   DE, HL
                ADD  HL, HL                              ; HL = glyph_x_bytes
                LD   DE, (FontAtlasLo)
                ADD  HL, DE                              ; HL = low 16 of full addr
                LD   A, (FontAtlasHi)
                JR   NC, .ds_no_carry
                INC  A
.ds_no_carry:
                LD   B, #01
                LD   C, A
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                ; --- Emit Cell 0 + Vertex2f(CurX, Y) ---
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, (DrawStr_CurX)
                LD   DE, (DrawStr_Y)
                CALL FT.Coprocessor.Vertex2f

.ds_advance_only:
                ; CurX += advance × scale × 16. Scale: 1=native, 2=×2, 3=×8/5 (1024-режим,
                ; глифы рисует scale(1.6)-матрица → advance в экранных px = ×1.6).
                LD   A, (DrawStr_Adv)
                LD   H, 0 : LD L, A
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_adv1                        ; 1: native
                JR   Z, .ds_adv2x                       ; 2: ×2
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; 3: ×8
                LD   A, 5
                CALL Core.VDC_DivHLbyA                  ; /5 → ×1.6
                JR   .ds_adv1
.ds_adv2x:      ADD  HL, HL                             ; advance *= 2
.ds_adv1:       ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL   ; *16
                LD   DE, (DrawStr_CurX)
                ADD  HL, DE
                LD   (DrawStr_CurX), HL
                JP   .ds_loop

DrawStr_Ptr:    DEFW 0
DrawStr_CurX:   DEFW 0
DrawStr_Y:      DEFW 0
DrawStr_Adv:    DEFB 0
DrawStr_Scale:  DEFB 3                                  ; 1=native, 2=×2, 3=×1.6 (1024-режим, дефолт; caller ставит матрицу)

; ============================================================================
; DrawHudTopText — верхний HUD: clock + cumulative score.
; ============================================================================
DrawHudTopText:
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                CALL SetFontCancun8
                LD   A, 1
                LD   (DrawStr_Scale), A                 ; 1024-native compact HUD font
                LD   C, 255 : LD D, 242 : LD E, 168
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_BITMAPS

                ; Левый red socket: центрированные игровые часы HH:MM:SS.
                ;   Native 1024 font: StrWidth уже в экранных pixels.
                CALL FormatHudClock
                LD   HL, DrawNumBuf
                CALL StrWidth
                LD   HL, 310                            ; 194×1.6, центр left red socket
                LD   A, E
                SRL  A                                  ; half width (screen px)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE                             ; HL = x in screen px
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, 2 * 16                         ; Y=2 (1×1.6)
                LD   HL, DrawNumBuf
                CALL DrawString

                ; Black score socket: label закреплён слева, number закреплён справа.
                ;   Внутренность sock x=273..367 (w=95). Padding 2px с каждой стороны.
                LD   HL, str_hud_score
                LD   BC, 434 * 16                       ; SCORE label закреплён слева (271×1.6)
                LD   DE, 2 * 16                         ; Y=2 (1×1.6)
                CALL DrawString

                CALL FormatScore24ToBuf                 ; 24-bit cumulative score → DrawNumBuf
                LD   HL, DrawNumBuf
                CALL StrWidth
                LD   HL, 578                            ; 361×1.6, number right edge
                AND  A
                SBC  HL, DE                             ; HL = x in screen px
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, 2 * 16                         ; Y=2 (1×1.6)
                LD   HL, DrawNumBuf
                CALL DrawString

                LD   A, 3
                LD   (DrawStr_Scale), A                 ; восстановить legacy 1.6 text mode
                CALL Core.ZL_EmitScale16Matrix          ; progress/menu atlases всё ещё требуют scale16
                LD   C, 255 : LD D, 255 : LD E, 255
                JP   FT.Coprocessor.ColorRGB

; HudScaleXTo16 — перевод HL(640-space px) → HL = (HL×8/5)×16 (screen 1024, subpx 1/16).
HudScaleXTo16:  ADD  HL, HL : ADD HL, HL : ADD HL, HL  ; ×8
                LD   A, 5
                CALL Core.VDC_DivHLbyA
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                RET

; ============================================================================
; StrWidth — посчитать ширину строки в пикселях (sum of advances).
;   In:  HL = string ptr (zero-terminated)
;   Out: DE = width (pixels)
;   Клобает AF, BC, HL.
; ============================================================================
StrWidth:
                LD   DE, 0
.sw_loop:       LD   A, (HL)
                INC  HL
                OR   A
                RET  Z
                CP   128
                JR   NC, .sw_loop
                PUSH HL
                LD   C, A : LD B, 0
                LD   HL, (FontPtrAdvance)
                ADD  HL, BC
                LD   A, (HL)
                LD   H, 0 : LD L, A
                ADD  HL, DE
                EX   DE, HL
                POP  HL
                JR   .sw_loop

; ============================================================================
; DrawByteValue — нарисовать байт (0..255) как до-3-х цифр после строки.
;   In: A = byte value. Cursor берётся из DrawStr_CurX.
;   Клобает всё.
; ============================================================================
DrawByteValue:
                LD   (DrawNumBuf+3), A                  ; временно сохраним A
                LD   HL, DrawNumBuf
                ; convert: hundreds, tens, units
                LD   A, (DrawNumBuf+3)
                LD   B, '0' - 1
.dbv_h:         INC  B
                SUB  100
                JR   NC, .dbv_h
                ADD  A, 100
                LD   (HL), B : INC HL
                LD   B, '0' - 1
.dbv_t:         INC  B
                SUB  10
                JR   NC, .dbv_t
                ADD  A, 10
                LD   (HL), B : INC HL
                ADD  A, '0'
                LD   (HL), A : INC HL
                LD   (HL), 0                            ; null term
                ; Убрать leading zeros: заменить space, у которого w=0
                LD   HL, DrawNumBuf
                LD   A, (HL)
                CP   '0'
                JR   NZ, .dbv_draw
                LD   (HL), ' '
                INC  HL
                LD   A, (HL)
                CP   '0'
                JR   NZ, .dbv_draw
                LD   (HL), ' '
.dbv_draw:
                LD   HL, DrawNumBuf
                LD   BC, (DrawStr_CurX)
                LD   DE, (DrawStr_Y)
                JP   DrawString

; ============================================================================
; DrawWordValue — нарисовать 16-bit unsigned как 1..5 цифр после строки.
;   In: HL = value. Cursor берётся из DrawStr_CurX.
; ============================================================================
FormatWordToBuf:
                LD   (DrawWordTmp), HL
                LD   HL, DrawNumBuf
                LD   (DrawWordOut), HL
                LD   IX, DrawWordDivs
                LD   DE, DrawNumBuf
                LD   B, 5
.dwv_digit:
                LD   HL, (DrawWordTmp)
                LD   C, '0' - 1
                LD   A, (IX+0)
                LD   (DrawWordDiv), A
                LD   A, (IX+1)
                LD   (DrawWordDiv+1), A
.dwv_sub:
                INC  C
                LD   DE, (DrawWordDiv)
                AND  A
                SBC  HL, DE
                JR   NC, .dwv_sub
                ADD  HL, DE
                LD   (DrawWordTmp), HL
                LD   A, C
                LD   HL, (DrawWordOut)
                LD   (HL), A
                INC  HL
                LD   (DrawWordOut), HL
                INC  IX
                INC  IX
                DJNZ .dwv_digit
                XOR  A
                LD   HL, (DrawWordOut)
                LD   (HL), A
                RET

DrawWordValue:
                CALL FormatWordToBuf
                LD   HL, DrawNumBuf
                LD   BC, (DrawStr_CurX)
                LD   DE, (DrawStr_Y)
                JP   DrawString

DrawWordDivs:   DEFW 10000, 1000, 100, 10, 1
DrawWordTmp:    DEFW 0
DrawWordDiv:    DEFW 0
DrawWordOut:    DEFW DrawNumBuf

; ============================================================================
; 24-bit cumulative score (Core.VDC_PlayerScore, 3-byte LE) + extra-life
; каждые 50000 очков, но только пока жизней меньше 3.
; Resident (slot 0), поэтому вызывается из gameplay (#04) и resident win/HUD code.
; ----------------------------------------------------------------------------
; Score_Add24 — VDC_PlayerScore += HL (16-bit delta), затем выдача extra lives.
;   Вход: HL = points to add. Клобает AF, DE, HL (NOT BC).
; ----------------------------------------------------------------------------
Score_Add24:
                LD   DE, (Core.VDC_PlayerScore)        ; DE = low 16 bits
                ADD  HL, DE                            ; CF = carry из low 16
                LD   (Core.VDC_PlayerScore), HL        ; store low 16 (LD keeps CF)
                LD   A, (Core.VDC_PlayerScore + 2)
                ADC  A, 0                              ; += carry into byte 2
                LD   (Core.VDC_PlayerScore + 2), A
                ; дальше сразу проверка extra-life
; ----------------------------------------------------------------------------
; Score_CheckExtraLife — пока score >= NextLifeScore: если VDC_Lives < 3, добавить
; жизнь и звук; threshold += 50000 всегда, чтобы cap не давал отложенных жизней.
; ----------------------------------------------------------------------------
Score_CheckExtraLife:
.cel_loop:      LD   HL, (Core.VDC_PlayerScore)        ; low 16 of score
                LD   DE, (Core.NextLifeScore)
                AND  A
                SBC  HL, DE                            ; CF = borrow (low 16)
                LD   A, (Core.VDC_PlayerScore + 2)
                LD   HL, Core.NextLifeScore + 2
                SBC  A, (HL)                           ; full 24-bit borrow in CF
                RET  C                                 ; score < threshold → готово
                LD   A, (Core.VDC_Lives)
                CP   3
                JR   NC, .cel_advance_threshold
                INC  A
                LD   (Core.VDC_Lives), A
                LD   A, Core.SND_EXTRALIFE
                CALL Core.GS_PlaySfx
.cel_advance_threshold:
                LD   HL, (Core.NextLifeScore)
                LD   DE, 50000
                ADD  HL, DE
                LD   (Core.NextLifeScore), HL
                LD   A, (Core.NextLifeScore + 2)
                ADC  A, 0
                LD   (Core.NextLifeScore + 2), A
                JR   .cel_loop
; ----------------------------------------------------------------------------
; Score_Reset — lives=3, score=0, NextLifeScore=50000 (new run / выход final Game Over).
; ----------------------------------------------------------------------------
Score_Reset:
                LD   A, 3
                LD   (Core.VDC_Lives), A
                LD   HL, 0
                LD   (Core.VDC_PlayerScore), HL
                XOR  A
                LD   (Core.VDC_PlayerScore + 2), A
                LD   HL, 50000
                LD   (Core.NextLifeScore), HL
                XOR  A
                LD   (Core.NextLifeScore + 2), A
                RET
; ----------------------------------------------------------------------------
; FormatScore24ToBuf — DrawNumBuf = decimal от VDC_PlayerScore (до 8 digits,
; leading zeros заменяются пробелами, которые render at zero width). Портит всё.
; ----------------------------------------------------------------------------
FormatScore24ToBuf:
                LD   HL, (Core.VDC_PlayerScore)
                LD   (Score24Work), HL
                LD   A, (Core.VDC_PlayerScore + 2)
                LD   (Score24Work + 2), A
                LD   IX, Score24Divs
                LD   HL, DrawNumBuf
                LD   (Score24OutPtr), HL
                LD   B, 8                              ; 8 digit slots
.fs24_digit:    LD   C, '0' - 1
.fs24_sub:      INC  C
                LD   A, (Score24Work)     : SUB (IX+0) : LD (Score24Work), A
                LD   A, (Score24Work + 1) : SBC A, (IX+1) : LD (Score24Work + 1), A
                LD   A, (Score24Work + 2) : SBC A, (IX+2) : LD (Score24Work + 2), A
                JR   NC, .fs24_sub                     ; no borrow -> subtract again
                LD   A, (Score24Work)     : ADD A, (IX+0) : LD (Score24Work), A    ; add divisor back once
                LD   A, (Score24Work + 1) : ADC A, (IX+1) : LD (Score24Work + 1), A
                LD   A, (Score24Work + 2) : ADC A, (IX+2) : LD (Score24Work + 2), A
                LD   A, C
                LD   HL, (Score24OutPtr)
                LD   (HL), A
                INC  HL
                LD   (Score24OutPtr), HL
                INC  IX : INC IX : INC IX
                DJNZ .fs24_digit
                XOR  A
                LD   HL, (Score24OutPtr)
                LD   (HL), A                           ; null terminate
                ; blank leading zeros (все кроме последней digit) -> space (zero width)
                LD   HL, DrawNumBuf
                LD   B, 7
.fs24_strip:    LD   A, (HL)
                CP   '0'
                RET  NZ
                LD   (HL), ' '
                INC  HL
                DJNZ .fs24_strip
                RET
; ----------------------------------------------------------------------------
; DrawScore24 — format + draw VDC_PlayerScore в DrawStr_CurX / DrawStr_Y.
; ----------------------------------------------------------------------------
DrawScore24:
                CALL FormatScore24ToBuf
                LD   HL, DrawNumBuf
                LD   BC, (DrawStr_CurX)
                LD   DE, (DrawStr_Y)
                JP   DrawString

Score24Divs:    DB #80,#96,#98     ; 10000000
                DB #40,#42,#0F     ; 1000000
                DB #A0,#86,#01     ; 100000
                DB #10,#27,#00     ; 10000
                DB #E8,#03,#00     ; 1000
                DB #64,#00,#00     ; 100
                DB #0A,#00,#00     ; 10
                DB #01,#00,#00     ; 1
Score24Work:    DB 0,0,0
Score24OutPtr:  DW 0

; ============================================================================
; FormatHudClock — DrawNumBuf = "HH:MM:SS" из RTC-based VDC_GameSeconds.
; ============================================================================
FormatHudClock:
                LD   HL, (Core.VDC_GameSeconds)
                LD   B, 0                              ; hours
.fhc_hour:      LD   DE, 3600
                AND  A
                SBC  HL, DE
                JR   C, .fhc_hour_done
                INC  B
                JR   .fhc_hour
.fhc_hour_done: ADD  HL, DE
                LD   C, 0                              ; minutes
.fhc_min:       LD   DE, 60
                AND  A
                SBC  HL, DE
                JR   C, .fhc_min_done
                INC  C
                JR   .fhc_min
.fhc_min_done:  ADD  HL, DE                            ; L = seconds 0..59
                LD   A, B
                LD   (HudClockHour), A
                LD   A, C
                LD   (HudClockMin), A
                LD   A, L
                LD   (HudClockSec), A

                LD   HL, DrawNumBuf
                LD   A, (HudClockHour)
                CALL FormatTwoDigits
                LD   (HL), ':'
                INC  HL
                LD   A, (HudClockMin)
                CALL FormatTwoDigits
                LD   (HL), ':'
                INC  HL
                LD   A, (HudClockSec)
                CALL FormatTwoDigits
                LD   (HL), 0
                RET

FormatTwoDigits:
                LD   B, '0' - 1
.ftd_tens:      INC  B
                SUB  10
                JR   NC, .ftd_tens
                ADD  A, 10
                LD   (HL), B
                INC  HL
                ADD  A, '0'
                LD   (HL), A
                INC  HL
                RET

HudClockHour:   DEFB 0
HudClockMin:    DEFB 0
HudClockSec:    DEFB 0

; ============================================================================
; DrawTimeValue — нарисовать "M:SS" из VDC_GameSeconds (RTC-based).
;   Раньше делили StatTimeFrames/60, но frame counter нельзя считать секундомером
;   при non-60Hz видео и паузах. Теперь берём VDC_GameSeconds (уже в секундах).
; ============================================================================
DrawTimeValue:
                ; HL = VDC_GameSeconds (total seconds, RTC-based, pause excluded).
                ; Divide by 60: HL → BC=minutes, remainder=seconds.
                LD   HL, (Core.VDC_GameSeconds)
                LD   DE, 60
                LD   BC, 0
.dt_div2:       AND  A
                SBC  HL, DE
                JR   C, .dt_minutes_done
                INC  BC
                JR   .dt_div2
.dt_minutes_done:
                ADD  HL, DE                             ; восстановить HL = remainder = seconds (0..59)
                ; BC = minutes, HL_low = seconds. Формат "M:SS"
                LD   A, C
                ADD  A, '0'                             ; minute digit (0..9)
                LD   (DrawNumBuf), A
                LD   A, ':'                             ; cancun8 имеет colon
                LD   (DrawNumBuf+1), A
                LD   A, L                               ; seconds 0..59
                LD   B, '0' - 1
.dt_s10:        INC  B
                SUB  10
                JR   NC, .dt_s10
                ADD  A, 10
                LD   C, A                                ; save units
                LD   A, B
                LD   (DrawNumBuf+2), A                   ; tens digit
                LD   A, C
                ADD  A, '0'
                LD   (DrawNumBuf+3), A                   ; units digit
                XOR  A
                LD   (DrawNumBuf+4), A                   ; null terminator
                LD   HL, DrawNumBuf
                LD   BC, (DrawStr_CurX)
                LD   DE, (DrawStr_Y)
                JP   DrawString

DrawNumBuf:     DEFS 10

                include "font_native_meta.inc"
                ; font_level48_meta.inc — НЕ здесь: slot0 (#0000..#3FFF) почти полон.
                ; Таблицы вынесены в отдельную page #23 и читаются через slot 2.
                include "font_cancun10_stats_meta.inc"
                include "font_cancun8_meta.inc"

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
                ; HSA ограничен, HSub=0.  Визуально: tail-балы плавно скользят
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
                ; Wrap: HSub=0, удалить slot 0.  HSA остаётся ограниченным — head
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
                ; pop всасывания с растущим питчем (оригинал; HD выпилил) — на
                ; каждый ушедший в череп шар нота +1 полутон, кламп +24 (2 окт).
                LD   A, (Core.VDC_AbsorbPopNote)
                PUSH AF
                ADD  A, Core.GS_SFX_NOTE
                LD   C, A
                LD   A, Core.SND_POP
                CALL Core.GS_PlaySfxNote
                POP  AF
                CP   24
                JR   NC, .ua_pop_capped
                INC  A
                LD   (Core.VDC_AbsorbPopNote), A
.ua_pop_capped:
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                RET  NZ
.ua_done:       CALL Core.VDC_DualAbsorbWaitOther
                RET  C
                CALL Core.VDC_DualLoseDelayMaybe
                RET  C
                LD   A, 2
                LD   (Core.VDC_GameState), A
                XOR  A
                LD   (Core.VDC_KzFrame), A
                LD   (Core.VDC_GameOverTick), A
                LD   A, 255
                LD   (Core.VDC_HeadAbsorbAlpha), A
                ; --- Decrement lives once при переходе в GAMEOVER ---
                ; .ua_done вызывается ровно один раз (когда SlotsLen достигла 0).
                ; Clamp на 0 — отрицательных жизней не бывает.
                LD   A, (Core.VDC_Lives)
                OR   A
                JR   Z, .ua_set_final          ; уже 0 → final
                DEC  A
                LD   (Core.VDC_Lives), A
                OR   A
                JR   Z, .ua_set_final          ; стало 0 → final
                LD   A, Core.SND_CHANT14        ; чант потери жизни (рестарт уровня)
                CALL Core.GS_PlaySfx
                LD   A, 1                       ; SHOW_RETRY (есть ещё жизни)
                JR   .ua_set_dlg
.ua_set_final:  LD   A, Core.SND_CHANT8         ; чант поражения (game over)
                CALL Core.GS_PlaySfx
                LD   A, 2                       ; GAME_OVER_FINAL (lives=0)
.ua_set_dlg:    LD   (Core.VDC_DialogState), A
                XOR  A
                LD   (Core.VDC_PrevMouseL), A           ; sentinel: ждать пока пользователь
                                                        ; нажмёт+отпустит mouse (avoid auto-restart)
                RET
.ua_save_hsub:  LD   (Core.VDC_HSub), A
                RET

; ============================================================================
; VDC_CheckKillzone — анимация черепа по близости.
; Каждый кадр вычисляет remaining_samples = (TrackNumSlots-HSA)*CS + KzEndSub-HSub.
;   rem > 2*CS (=64)  → KzFrame=1 (closed skull, idle)
;   rem в [1..64]     → KzFrame = 2 + ((64-rem) >> 3) ∈ [2..9] (opening)
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
                JP   C, .ck_trigger                    ; HSA > TNS → past
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
.ck_eqcell:     ; HSA == TNS: rem = KzEndSub - HSub ∈ [1..CS-1], всегда opening range
                LD   A, (Core.VDC_KzEndSub)
                LD   D, A
                LD   A, (Core.VDC_HSub)
                CP   D
                JP   NC, .ck_trigger                   ; HSub >= KzEndSub → past
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
                CP   67
                JR   NC, .ck_closed                    ; rem >= 67: до окна KZ ещё есть запас
                ; При VDC_GLOBAL_SPEED_FACTOR=2 проверка в rem==1 уже поздняя:
                ; обычный кадр может войти в окно открытия/trigger до следующего
                ; VDC_CheckKillzone. Если gap/explode ещё активны, держим голову
                ; на rem=65, т.е. до kill-zone, как в HD-логике.
                PUSH HL
                CALL Core.VDC_LoseStartReady
                POP  HL
                JP   C, Core.VDC_LoseHoldBeforeKillzone
                XOR  A
                LD   (Core.VDC_LoseHoldCnt), A
                LD   A, L
                CP   65
                JR   NC, .ck_closed
                ; rem ∈ [1..64]: KzFrame = 2 + ((64 - rem) >> 3) ∈ [2..9]
                LD   A, 64
                SUB  L
                SRL  A : SRL A : SRL A
                ADD  A, 2
                LD   (Core.VDC_KzFrame), A
                DEC  L
                RET  NZ
                XOR  A
                LD   (Core.VDC_LoseHoldCnt), A
                RET
.ck_closed:     LD   A, 1
                LD   (Core.VDC_KzFrame), A
                RET
.ck_trigger:    CALL Core.VDC_LoseStartReady
                JP   C, Core.VDC_LoseHoldBeforeKillzone
                XOR  A
                LD   (Core.Bullet_Active), A
                LD   (Core.Frog_IsFire), A
                LD   (Core.Frog_RecoilTick), A
                LD   A, 38                             ; FROG_BALL_IDLE, константа из Frog.asm объявлена позже
                LD   (Core.Frog_BallExpand), A
                LD   A, 24
                LD   (Core.Frog_TongueExpand), A
                LD   A, 1
                LD   (Core.VDC_GameState), A
                LD   A, 11                             ; wide-open mouth absorb при старте всасывания
                LD   (Core.VDC_KzFrame), A
                XOR  A
                LD   (Core.VDC_GameOverTick), A
                LD   (Core.VDC_AbsorbPopNote), A        ; питч всасывания стартует с базы
                LD   A, 255
                LD   (Core.VDC_HeadAbsorbAlpha), A      ; head fade начинается с 255
                LD   A, Core.SND_EARTHQUAKE             ; тряска при достижении черепа (оригинал; HD выпилил)
                CALL Core.GS_PlaySfx
                RET

; ============================================================================
; Frog_FilteredRandomColor — RandomColor с фильтром цветов цепи.
; Выход: A = color (0..3), гарантированно есть в VDC_Slots, если chain не пустая.
; Fallback: unfiltered random AND 3 если chain пуста или все retry'ы промахнулись.
; Сохраняет: BC, DE, HL (стандартные slot-0 caller-saves).
; ============================================================================
Frog_FilteredRandomColor:                              ; вход A: 0xFF=force fresh; иначе проверить и оставить, если в mask
                PUSH BC
                PUSH DE
                PUSH HL
                LD   B, A                              ; B = входной color (0xFF=force fresh)
                ; --- Собрать mask в D из VDC_Slots[0..SlotsLen-1] ---
                LD   D, 0                              ; D = mask (bits 0..VDC_NUM_COLORS-1 = colors present)
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                JP   Z, .frc_fb_in                     ; empty chain → fallback (JP — JR диапазон превысился после exclude block)
                LD   C, A
                LD   HL, (Core.VDC_pSlots)
.frc_ml:        LD   A, (HL)
                INC  HL
                CP   Core.VDC_NUM_COLORS
                JR   NC, .frc_msk_skip                 ; маркер GAP (>=NUM_COLORS) → пропуск
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
                ; --- Проверить входной color B по mask D (пропуск при 0xFF) ---
                LD   A, B
                CP   Core.VDC_NUM_COLORS
                JR   NC, .frc_pick_new                 ; B >= NUM_COLORS (включая 0xFF) → force fresh
                LD   E, A                              ; проверить bit B в mask
                LD   A, 1
                INC  E
.frc_chsh:      DEC  E
                JR   Z, .frc_chsh_done
                ADD  A, A
                JR   .frc_chsh
.frc_chsh_done: AND  D
                JR   Z, .frc_pick_new                  ; B не в mask → fresh
                LD   A, B                              ; сохранить входной color
                JR   .frc_exit
.frc_pick_new:
                LD   A, D
                OR   A
                JP   Z, .frc_fb_in                     ; нет live colors, только markers → сохранить current valid color
                ; --- Popcount mask D → B (число цветов в цепи) ---
                LD   B, 0
                LD   E, Core.VDC_NUM_COLORS            ; параметрический лимит цветов
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
                JR   Z, .frc_excl_reset                ; bit не в mask → пропуск
                LD   A, E
                CPL
                AND  D
                LD   D, A                              ; mask -= bit
                DEC  B                                  ; popcount--
.frc_excl_reset:
                LD   A, #FF
                LD   (FROG_EXCLUDE_COLOR_ADDR), A      ; consume: следующие вызовы RefilterCurrent не должны влиять
.frc_no_excl:
                LD   A, B
                OR   A
                JR   Z, .frc_fb                        ; mask пустая → fallback
                ; --- выбрать index 0..B-1 через mul-then-shift: (rand8 * B) >> 8.
                ; Bias ≤ 1/(256/B) ≤ 1.6%. Старый `AND 3 + mod B` на 4-value
                ; источнике давал при popcount=3 LSB-цвету маски 50% vs 25% —
                ; визуально «слишком много <цвет-0-маски>» (purple bias).
                PUSH DE                                ; сохранить D = mask (E irrelevant)
                PUSH BC                                ; сохранить B = popcount
                CALL VDC_Random8                       ; A = 0..255 равномерный LFSR
                LD   D, A                              ; D = rand (preserve)
                ; --- Optional RTC mix в RAND BYTE (не seed!) каждый 128-й NewNextColor ---
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
                POP  BC                                 ; восстановить B = popcount
                LD   E, B                              ; E = popcount
                CALL Core.Frog_Mul8x8u                 ; HL = D*E (clobbers A,B,DE)
                POP  DE                                 ; восстановить D = mask
                LD   C, H                              ; C = (rand*B)>>8 = 0..B-1
                ; --- пройти mask D LSB→MSB, вернуть color C-th set bit ---
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
.frc_fb_in:     ; пустая chain: сохранить B, если валиден; иначе random unfiltered
                LD   A, B
                CP   Core.VDC_NUM_COLORS
                JR   C, .frc_exit                      ; B < NUM_COLORS → оставить
.frc_fb:        CALL Core.VDC_RandomColor              ; уже выдаёт 0..NUM_COLORS-1
                ; VDC_RandomColor сам маскирует под Core.VDC_NUM_COLORS.
.frc_exit:      POP  HL
                POP  DE
                POP  BC
                RET

; Frog_RefilterCurrent — кадровый sanitizer цветов лягушки.
; Валидные BallColor/NextBallColor уже видны игроку, поэтому их нельзя
; спонтанно менять без выстрела: ни на старте PLAY после intro, ни после
; cascade/match-3. Refilter по live chain mask разрешён только для мусорных
; значений памяти (>= VDC_NUM_COLORS); обычный выбор/перевыбор цвета делается
; в Frog_NewNextColor и при promote next -> current после реального выстрела.
Frog_RefilterCurrent:
                LD   A, (Core.Frog_BallColor)
                CP   Core.VDC_NUM_COLORS
                JR   C, .frc_check_next
                CALL Frog_FilteredRandomColor
                LD   (Core.Frog_BallColor), A
.frc_check_next:
                LD   A, (Core.Frog_NextBallColor)
                CP   Core.VDC_NUM_COLORS
                RET  C
                CALL Frog_FilteredRandomColor
                LD   (Core.Frog_NextBallColor), A
                RET

; Frog_NewNextColor — принудительно выбирает свежий NextBallColor после promote при start fire.
; Counter mod 128: каждый 128-й вызов взводит FLAG, и следующий pick в
; Frog_FilteredRandomColor XOR'ит RTC seconds в RAND BYTE (выход LFSR, не seed).
; Это сохраняет цикл LFSR неприкосновенным, но добавляет точечный
; перетряс распределения раз в ~128 выстрелов.
Frog_NewNextColor:
                LD   HL, FROG_RTC_MIX_CNT_ADDR
                LD   A, (HL)
                INC  A
                AND  #7F                              ; counter mod 128
                LD   (HL), A
                OR   A
                JR   NZ, .nnc_no_flag                 ; cnt != 0 → не boundary
                LD   A, 1
                LD   (FROG_RTC_MIX_FLAG_ADDR), A      ; отметить для picker
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
; VDC_Random8 — LFSR Galois 16-bit (poly 0xB400), 8-bit равномерно 0..255.
; Тот же шаг LFSR, что Core.VDC_RandomColor, но без AND-mask. Используется
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
                JR   NC, .r8_no_xor
                LD   D, #B4 : LD E, 0
                LD   A, H : XOR D : LD H, A
                LD   A, L : XOR E : LD L, A
.r8_no_xor:
                LD   (Core.VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; 8-bit равномерно
                RET

; ----------------------------------------------------------------------------
; ZX7 Turbo decompressor (Einar Saukas / Urusergi). HL = compressed src,
; DE = destination. Восстановлен из ~/Desktop/Zuma Deluxe (src/ASM,
; zuma_new_spg.asm:4466). Размер ~62 байта. Не корраптит I, IX, IY.
; Используется через UnpackZX7Page wrapper. На входе HL/DE должны указывать
; в WRITABLE области (исходник можно в slot 2 ROM-like, dest в RAM).
; ----------------------------------------------------------------------------
Dzx7Turbo:
                LD   A, #80
.zx7_copy_byte_loop:
                LDI
.zx7_main_loop:
                ADD  A, A
                CALL Z, .zx7_load_bits
                JR   NC, .zx7_copy_byte_loop
                PUSH DE
                LD   BC, 1
                LD   D, B
.zx7_len_size_loop:
                INC  D
                ADD  A, A
                CALL Z, .zx7_load_bits
                JR   NC, .zx7_len_size_loop
                JP   .zx7_len_value_start
.zx7_len_value_loop:
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   C
                RL   B
                JR   C, .zx7_exit
.zx7_len_value_start:
                DEC  D
                JR   NZ, .zx7_len_value_loop
                INC  BC
                LD   E, (HL)
                INC  HL
                DB   #CB, #33                          ; SLL E / SLS E (undoc)
                JR   NC, .zx7_offset_end
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                RL   D
                ADD  A, A
                CALL Z, .zx7_load_bits
                CCF
                JR   C, .zx7_offset_end
                INC  D
.zx7_offset_end:
                RR   E
                EX   (SP), HL
                PUSH HL
                SBC  HL, DE
                POP  DE
                LDIR
.zx7_exit:
                POP  HL
                JP   NC, .zx7_main_loop
                RET
.zx7_load_bits:
                LD   A, (HL)
                INC  HL
                RLA
                RET

; ----------------------------------------------------------------------------
; SCRATCH_PAGE — свободная SPG page для decomp output. Используется
; UnpackAndUploadPage в Initialize между bg/balls/frog uploads.
; Page #01 не задействован ни одним Block в spgbld_vdac2.ini — безопасно.
; ----------------------------------------------------------------------------
SCRATCH_PAGE    EQU #01

; ----------------------------------------------------------------------------
; UnpackAndUploadPage: расжать compressed src page A → SCRATCH_PAGE,
; залить 16K из SCRATCH_PAGE в FT_RAM_G по адресу (Core.BgRamH:BgRamL),
; продвинуть указатель FT_RAM_G на +#4000.
;
; Вход: A = compressed source SPG page; Core.BgRamH/L = FT_RAM_G dest 24-bit
; Выход: Core.BgRamH/L advanced by 16K
; Slots after RET: slot 2 = src (not restored), slot 3 = current scene overlay
; (Core.CurrentCodePage). Restore slot 3 здесь не даёт dumps и call-side code
; увидеть transient scratch page между compressed uploads.
; ----------------------------------------------------------------------------
; CurrentCodePage отслеживает, какой scene overlay mapped в slot 3: #41 (UI =
; menu/level-select) или #04 (gameplay). Shared slot0 decompressors ниже используют
; slot 3 как decomp scratch, затем restore именно эту page (а не hard-coded #04),
; поэтому корректны из любой scene. Поддерживается resident Fade* transitions;
; boot default = UI overlay (первая scene — menu). Resident (slot 0/TSLib region).
CurrentCodePage:  DB UI_OVL_PAGE
UnpackAndUploadPage:
                DI
                CALL Cache_C000_Off
                LD   (.uaup_src), A
                LD   (.uaup_saved_sp), SP
                LD   SP, .uaup_temp_stack_top

                ; slot 2 = compressed src
                LD   A, (.uaup_src) : LD BC, PAGE2 : OUT (C), A
                ; slot 3 = scratch (decomp dest)
                LD   A, SCRATCH_PAGE : LD BC, PAGE3 : OUT (C), A

                ; Dzx7Turbo: HL=src, DE=dst
                LD   HL, #8000
                LD   DE, #C000
                CALL Dzx7Turbo

                ; FT.WriteMem(HL=#C000 in slot 3, BC=16384, A:DE=FT_RAM_G addr)
                LD   HL, #C000
                LD   BC, 16384
                LD   A, (Core.BgRamH)
                LD   DE, (Core.BgRamL)
                CALL FT.WriteMem

                ; Сдвинуть Core.BgRamL/H на 16K
                LD   HL, (Core.BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (Core.BgRamL), HL
                JR   NC, .uaup_no_carry
                LD   A, (Core.BgRamH) : INC A : LD (Core.BgRamH), A
.uaup_no_carry:
                LD   A, (CurrentCodePage) : LD BC, PAGE3 : OUT (C), A   ; восстановить slot 3 = current scene overlay (#41 ui / #04 gameplay)
                LD   SP, (.uaup_saved_sp)
                EI
                RET
.uaup_src:        DB 0
.uaup_saved_sp:   DW 0
.uaup_temp_stack: DEFS 64
.uaup_temp_stack_top:

; ----------------------------------------------------------------------------
; UnpackZX7Page: расжать compressed page A → dest page B.
; Source = slot 2 (#8000), dest = slot 3 (#C000). После RET слоты восстановлены:
; slot 2 → first active Track V2 page, slot 3 → page #04 (main1_play).
; Stack пересажен на uzx7_temp_stack чтобы LDIR в slot 3 не зацепил наш стек.
; ----------------------------------------------------------------------------
UnpackZX7Page:
                DI
                CALL Cache_C000_Off
                LD   (.uzx7_src), A
                LD   A, B  : LD (.uzx7_dst), A
                LD   (.uzx7_saved_sp), SP
                LD   SP, .uzx7_temp_stack_top
                LD   A, (.uzx7_src) : LD BC, PAGE2 : OUT (C), A
                LD   A, (.uzx7_dst) : LD BC, PAGE3 : OUT (C), A
                LD   HL, #8000
                LD   DE, #C000
                CALL Dzx7Turbo
                CALL Core.SetCurrentTrackPage               ; восстановить slot 2 = active Track V2 page
                LD   A, (CurrentCodePage) : LD BC, PAGE3 : OUT (C), A   ; восстановить slot 3 = current scene overlay (#41 ui / #04 gameplay)
                LD   SP, (.uzx7_saved_sp)
                EI
                RET
.uzx7_src:        DB 0
.uzx7_dst:        DB 0
.uzx7_saved_sp:   DW 0
.uzx7_temp_stack: DEFS 64
.uzx7_temp_stack_top:

; ----------------------------------------------------------------------------
; SafeInflatePage2: FT812 CMD_INFLATE с compressed source, mapped in PAGE2.
;
; TSLib FT.Coprocessor.Inflate мапит source pages в PAGE3/#C000, а это наш
; main1_play code slot. Host dumps показывали CPU HALT, когда PAGE3 была zlib
; preview page (#F1). Этот вариант не трогает PAGE3 и стримит source из PAGE2/#8000.
;
; Вход: та же convention, что FT.Coprocessor.Inflate для текущих callers:
;   A:DE = RAM_G destination, BC = compressed byte count, HL = source offset,
;   A' = source SPG page. Текущие assets все <64K compressed.
; Выход: CF set только если coprocessor write сообщает fault.
; Slots after RET: PAGE2 restored to previous value; PAGE3 unchanged.
; ----------------------------------------------------------------------------
SafeInflatePage2:
                CALL FT.Coprocessor.WaitFlush
                RET  C

                PUSH HL
                PUSH DE
                FT_WR32_CMD FT_CMD_INFLATE
                POP  DE

                LD   H, #00
                LD   L, A
                CALL FT.Coprocessor.Write32
                JR   C, .drop_source_error

                GetPage2
                LD   (.sip2_saved_page2), A
                POP  HL

                ; Перенести source address из page-local #0000..#3FFF в slot2
                ; address space #8000..#BFFF.
                LD   A, H
                OR   %10000000
                LD   H, A
                EX   AF, AF'
                LD   (.sip2_src_page), A
                EX   AF, AF'

.loop:          LD   A, (.sip2_src_page)
                SetPage2_A

                PUSH HL                              ; source CPU address
                LD   A, H
                AND  %00111111
                LD   H, A
                EX   DE, HL                          ; DE = offset in page
                LD   HL, #4000
                OR   A
                SBC  HL, DE
                EX   DE, HL                          ; DE = bytes to page end

                LD   H, B
                LD   L, C                            ; HL = remaining total
                OR   A
                SBC  HL, DE
                JR   NC, .page_chunk

                ADD  HL, DE                          ; HL = final chunk bytes
                LD   B, H
                LD   C, L
                LD   HL, #0000                       ; no remainder
                SCF                                  ; align final packet
                JR   .write_chunk

.page_chunk:    LD   B, D
                LD   C, E                            ; BC = chunk bytes
                OR   A                               ; not final, no align

.write_chunk:   EX   (SP), HL                         ; HL=source, stack=remainder
                CALL FT.Coprocessor.Write
                POP  BC                              ; BC = remaining total
                JR   C, .restore_error
                LD   A, B
                OR   C
                JR   Z, .restore_ok

                LD   HL, #8000
                LD   A, (.sip2_src_page)
                INC  A
                LD   (.sip2_src_page), A
                JR   .loop

.restore_ok:    LD   A, (.sip2_saved_page2)
                SetPage2_A
                OR   A
                RET
.restore_error: LD   A, (.sip2_saved_page2)
                SetPage2_A
                SCF
                RET
.drop_source_error:
                POP  HL
                SCF
                RET
.sip2_saved_page2: DB 0
.sip2_src_page:    DB 0

                module Core
; Часть чтения Track V4 в Slot0: преобразование исходных Vx/Vy в центр и
; восстановление страницы трека. Основное тело распаковки живёт на игровой
; странице #04: все штатные вызовы идут из игрового кода при PAGE3=#04.
VDC_ReadSampleAtHL_Slot0:
                CALL VDC_ReadRenderSampleAtHL_Slot0    ; BC=Vx, DE=Vy
                PUSH DE                                ; raw Vy
                LD   H, B : LD L, C
                CALL VDC_V16ToCenter_Slot0
                LD   B, H : LD C, L                    ; BC = X
                POP  HL                                ; raw Vy
                PUSH BC
                CALL VDC_V16ToCenter_Slot0
                EX   DE, HL                            ; DE = Y
                POP  BC
                PUSH BC : PUSH DE
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A
                XOR  A
                LD   (VDC_RenderTrackPageIdx), A
                POP  DE : POP  BC
                AND  A
                RET

VDC_V16ToCenter_Slot0:
                SRA  H : RR L
                SRA  H : RR L
                SRA  H : RR L
                SRA  H : RR L
                LD   DE, 26
                ADD  HL, DE
                RET

                include "BulletTraj.asm"              ; slot0 resident ZBT1 bullet trajectory event reader

                endmodule

                include "LevelSelectPreviewSlot0.asm"

SLOT0_BLOCK_END:
                ; slot0-регион (#0000..#3FFF, всегда замаплен) ОБЯЗАН закончиться до
                ; #4000 — иначе хвост налезает на область slot1 (Core) в рантайме →
                ; тихая порча/зависание (sjasmplus сам на это НЕ ругается). Ловим тут.
                ; Если упало: вынеси крупные таблицы/данные в overlay (#04/#41), как
                ; сделано с font_level48_meta.inc.
                ASSERT SLOT0_BLOCK_END <= #4000

TSLIB_TOTAL_SIZE EQU SLOT0_BLOCK_END - TSLIB_Start
                display "Slot0:    \t", /A, TSLIB_Start, " end=", /A, SLOT0_BLOCK_END
                SAVEBIN "Build/TSLib.bin", TSLIB_Start, TSLIB_TOTAL_SIZE

; --- Core block (page 5) -------------------------------------------------
                ORG EntryPoint
                module Core
Start:
                ; ----- EntryPoint -----
                LD   SP, StackTop
                if RUNTIME_DIAGNOSTICS_ENABLED
                ; ----- BOOT CANARY -----
                ; Доказывает, что WC SPG-loader долистал до Core EntryPoint и
                ; передал управление НАМ — до любого Init. Пишем "BOOT" в
                ; резидентный RAM (#5044), не трогая стек/страницы. См. дамп 111:
                ; если этой метки нет в F2-дампе — hang в фазе загрузки WC.
                LD   HL, #4F42                          ; 'B','O' (LE → #42 #4F)
                LD   (BOOT_CANARY_ADDR), HL
                LD   HL, #544F                          ; 'O','T' (LE → #4F #54)
                LD   (BOOT_CANARY_ADDR + 2), HL
                endif
                CALL Initialize
                CALL UploadBootLoadingAssets
                CALL BootProgressReset
                LD   A, 5
                CALL BootProgressSetA
                ; ПОРЯДОК ФИКСИРОВАН (НЕ МЕНЯТЬ):
                ;   музыка (если есть GS) -> SFX (если ОЗУ GS >= 2МБ) -> тело игры.
                CALL GS_InitAndStartMenuMusic
                LD   A, 60
                CALL BootProgressSetA
                CALL GS_LoadGameplaySoundsMaybe
                LD   A, 95
                CALL BootProgressSetA
                CALL LoadMainPack
                LD   A, LOADING_BAR_W
                CALL BootProgressSetA
                CALL DrawBootBlackScreen
                JP   MenuMain                           ; RAM_G освобождается в самом MenuMain (ClearRamGForMenu)

                ; ----- Initialize -----
Initialize:     CALL Init_Core
                CALL Init_Int                         ; EI/HALT — ждём первого FRAME INT (HW stab)
                CALL Init_Video                       ; FT_BOOT_UP + 1024×768 + FT_INT_SWAP enable
                CALL Input.Mouse.Initialize           ; курсор в центр (W/2, H/2)
                CALL Input_Init                       ; взвести расширенную PC-клавиатуру (Mr.Gluk PS/2)
                CALL AY_Game.AY_Init                  ; No-GS AY fallback starts silent
                ; Init завершён — выключаем TS-Conf INT: FT812 pacing не должен
                ; получать лишние frame/line прерывания.
                DI
                INT_Setting 0
                RET

UploadBootLoadingAssets:
                if BOOT_LOADING_BG_ENABLED
                LD   HL, BOOT_LOADING_BG_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BOOT_LOADING_BG_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, BOOT_LOADING_BG_PAGE_BASE
                LD   B, BOOT_LOADING_BG_PAGES
                CALL .upload_raw_pages
                endif

                LD   HL, BOOT_LOADING_BAR_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BOOT_LOADING_BAR_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, BOOT_LOADING_BAR_PAGE_BASE
                LD   B, BOOT_LOADING_BAR_PAGES
                CALL .upload_pages

                LD   HL, BOOT_TS_ANIM_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BOOT_TS_ANIM_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, BOOT_TS_ANIM_PAGE_BASE
                LD   B, BOOT_TS_ANIM_PAGES
                CALL .upload_pages

                LD   HL, BOOT_SFX_AUTHORS_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BOOT_SFX_AUTHORS_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, BOOT_SFX_AUTHORS_PAGE_BASE
                LD   B, BOOT_SFX_AUTHORS_PAGES
                CALL .upload_pages

                LD   A, BOOT_POPCAP_PAGE_BASE
                EX   AF, AF'
                LD   HL, 0
                LD   DE, BOOT_POPCAP_RAMG & 0xFFFF
                LD   BC, BOOT_POPCAP_Z_SIZE
                LD   A, (BOOT_POPCAP_RAMG >> 16) & 0xFF
                CALL SafeInflatePage2
                RET

.upload_pages: PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage
                POP  AF
                INC  A
                POP  BC
                DJNZ .upload_pages
                RET
.upload_raw_pages:
                PUSH BC
                PUSH AF
                SetPage2_A
                LD   HL, #8000
                LD   BC, #4000
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .raw_no_carry
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.raw_no_carry: POP  AF
                INC  A
                POP  BC
                DJNZ .upload_raw_pages
                RET

LoadGameplayAssets:
.retry_level:   LD   B, 3
.retry_one:     PUSH BC
                CALL LoadGameplayLevelSpecificFromPack
                POP  BC
                JR   C, .LevelSpecificLoaded
                DJNZ .retry_one
                CALL DrawBlackLoadingFrame
                JR   .retry_level

.LevelSpecificLoaded:
                ; Залить единый balls atlas: PALETTED4444 50px-in-51px guarded cells.
                LD   A, BALLS_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BALLS_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BALLS_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BALLS_PAGE_COUNT
.UploadBalls:   PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem 16K, advance BgRamH/L
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBalls

                ; Balls palette ARGB4 СТРОГО 512 байт → FT_RAM_G #080000.
                LD   A, BALLS_PALETTE_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512                          ; ARGB4 = 256 × 2 bytes
                LD   A, (BALLS_PALETTE_RAMG >> 16) & 0xFF
                LD   D, C
                LD   E, C
                CALL FT.WriteMem
.BallsPaletteDone:

                ; Залить frog body / plate / tongue / face-overlay в RAM_G.
                ; FROG_ARGB4_ENABLED: 122×122×2 = 29768 bytes, 2 pages per sprite.
                LD   A, FROG_PAGE
                LD   (BgPg), A
                LD   HL, FROG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FROG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, FROG_TOTAL_PAGES
.UploadFrog:    PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadFrog
                if !FROG_ARGB4_ENABLED
                LD   A, FROG_PALETTE_PAGE
                LD   HL, FROG_PALETTE_RAMG & 0xFFFF
                CALL UploadFrogPalette
                LD   A, PLATE_PALETTE_PAGE
                LD   HL, PLATE_PALETTE_RAMG & 0xFFFF
                CALL UploadFrogPalette
                LD   A, TONGUE_PALETTE_PAGE
                LD   HL, TONGUE_PALETTE_RAMG & 0xFFFF
                CALL UploadFrogPalette
                LD   A, OVERLAY_PALETTE_PAGE
                LD   HL, OVERLAY_PALETTE_RAMG & 0xFFFF
                CALL UploadFrogPalette
                endif

                ; Залить killzone + match-3 explosion atlases contiguous в RAM_G.
                LD   A, KZ_PAGE
                LD   (BgPg), A
                LD   HL, KZ_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (KZ_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, KZ_PAGE_COUNT
.UploadKz:      PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage              ; decomp ZX7 page → SCRATCH, FT.WriteMem
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadKz

                ; WIN-взрыв НЕ грузится здесь: его атлас переиспользует регион
                ; шаров (#050000), который во время геймплея занят. Дозаливается по
                ; SPI на входе в WIN (VDC_WinOutroInit), когда шаров уже нет. См.
                ; WINEXP_RAMG_ADDR.

                LD   A, CURSOR_PAGE
                EX   AF, AF'
                LD   HL, 0
                LD   DE, CURSOR_RAMG_ADDR & 0xFFFF
                LD   BC, CURSOR_Z_SIZE
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                CALL SafeInflatePage2

                ; Залить GAME OVER atlas и intro glyph font в FT_RAM_G #0..#10000
                ; (свободная зона до bg).
                LD   HL, TEXT_GAMEOVER_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (TEXT_GAMEOVER_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, TEXT_GAMEOVER_PAGE
                CALL UnpackAndUploadPage

                ; --- LEVEL N-M native-48 шрифт: 2 ZX7-чанка → #004000..#00C000 ---
                ; (заменил мёртвые TEXT_LEVEL11 + TEXT_SPIRALDOOM, которые грузились,
                ;  но не рисовались — теперь это атлас глифов для интро-надписи.)
                LD   HL, FONT_LEVEL48_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FONT_LEVEL48_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FONT_LEVEL48_PAGE_BASE
                LD   B, FONT_LEVEL48_NUM_PAGES
.UploadLevelFont:
                PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage                ; auto-advances RAM_G +16K
                POP  AF
                INC  A                                  ; next SPG page
                POP  BC
                DJNZ .UploadLevelFont

                ; Sparkle (24×24 ARGB4) для intro track preview
                LD   HL, SPARKLE_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (SPARKLE_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, SPARKLE_PAGE
                CALL UnpackAndUploadPage

                ; --- Frame strips: palette raw + 5 strip pages ZX7 (16K-aligned blocks) ---
                ; Gameplay loading-DL читает баннер из LOADING_TEXT_GAME_RAMG
                ; (#0AC000), поэтому frame strips можно грузить в #084000 без
                ; раннего гашения надписи.
                ; Palette 512 байт raw → FRAME_PAL_RAMG.
                LD   A, FRAME_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (FRAME_PAL_RAMG >> 16) & 0xFF
                LD   D, B
                LD   E, C
                CALL FT.WriteMem
                ; 5 ZX7-compressed strips through UnpackAndUploadPage (each 16K block).
                ; Setup BgRamH/L to FRAME_TOP_RAMG, then loop через 5 страниц подряд.
                LD   HL, FRAME_TOP_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FRAME_TOP_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FRAME_TOP_P0_PAGE
                CALL UnpackAndUploadPage              ; #084000 ← top_p0 (16K)
                LD   A, FRAME_TOP_P1_PAGE
                CALL UnpackAndUploadPage              ; #088000 ← top_p1 (11.5K + junk)
                LD   A, FRAME_BOT_PAGE
                CALL UnpackAndUploadPage              ; #08C000 ← bot
                LD   A, FRAME_LEFT_PAGE
                CALL UnpackAndUploadPage              ; #090000 ← left
                LD   A, FRAME_RIGHT_PAGE
                CALL UnpackAndUploadPage              ; #094000 ← right

                ; --- HUD: life_frog 20×20 PALETTED4444 + shared HUD palette ---
                ; Raw upload (no ZX7): первые 400 байт страницы #5B → LIFE_FROG_RAMG.
                LD   A, LIFE_FROG_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, LIFE_FROG_BYTES
                LD   A, (LIFE_FROG_RAMG >> 16) & 0xFF
                LD   DE, LIFE_FROG_RAMG & 0xFFFF
                CALL FT.WriteMem
                ; HUD palette 512 байт raw → HUD_PALETTE_RAMG.
                LD   A, HUD_PALETTE_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (HUD_PALETTE_RAMG >> 16) & 0xFF
                LD   DE, HUD_PALETTE_RAMG & 0xFFFF
                CALL FT.WriteMem
                ; HUD menu button atlas (inactive/hover/pressed), raw PALETTED4444.
                LD   A, HUD_MENU_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, HUD_MENU_BYTES
                LD   A, (HUD_MENU_RAMG >> 16) & 0xFF
                LD   DE, HUD_MENU_RAMG & 0xFFFF
                CALL FT.WriteMem
                ; HUD progress bar atlas (green/yellow), raw PALETTED4444.
                LD   A, HUD_PROGRESS_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, HUD_PROGRESS_BYTES
                LD   A, (HUD_PROGRESS_RAMG >> 16) & 0xFF
                LD   DE, HUD_PROGRESS_RAMG & 0xFFFF
                CALL FT.WriteMem

                ; --- Dialog palette 512 байт raw → DIALOG_PALETTE_RAMG ---
                LD   A, DIALOG_PALETTE_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (DIALOG_PALETTE_RAMG >> 16) & 0xFF
                LD   DE, DIALOG_PALETTE_RAMG & 0xFFFF
                CALL FT.WriteMem
                ; Final dialog wide OK button, raw PALETTED4444.
                LD   A, DIALOG_OK_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, DIALOG_OK_BYTES
                LD   A, (DIALOG_OK_RAMG >> 16) & 0xFF
                LD   DE, DIALOG_OK_RAMG & 0xFFFF
                CALL FT.WriteMem

                ; DIALOG_FRAME #0AC000..#0CC000 — gameplay swap-окно.
                ; Не держим его resident: активный tunnel gameplay может занять
                ; эти 128 KB под top-cover. DrawRetryDialog лениво reload'ит
                ; frame; пока dialog видим, подтунельные шары в фоне просто
                ; не рисуются вместо отдельного tunnel top-cover.
                XOR  A
                LD   (DialogFrameLoaded), A

                ; --- Native font atlas: 3 ZX7 chunks → #098000..#0A4000 ---
                LD   HL, FONT_NATIVE_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FONT_NATIVE_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FONT_NATIVE_PAGE_BASE
                LD   B, FONT_NATIVE_NUM_PAGES
.UploadFont:    PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage                ; advances RAM_G +16K
                POP  AF
                INC  A
                POP  BC
                DJNZ .UploadFont

                ; --- Cancun10 stats font: 1 ZX7 chunk → #0A0000..#0A4000 ---
                LD   HL, FONT_CANCUN10_STATS_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FONT_CANCUN10_STATS_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FONT_CANCUN10_STATS_PAGE
                CALL UnpackAndUploadPage

                ; --- Cancun8 compact HUD font atlas: 2 ZX7 chunks → #0A4000..#0AC000 ---
                LD   HL, FONT_CANCUN8_RAMG & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FONT_CANCUN8_RAMG >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, FONT_CANCUN8_PAGE_BASE
                LD   B, FONT_CANCUN8_NUM_PAGES_VDAC
.UploadFontC:   PUSH BC
                PUSH AF
                CALL UnpackAndUploadPage
                POP  AF
                INC  A
                POP  BC
                DJNZ .UploadFontC

                ; Восстановить слоты после серии compressed uploads:
                ; slot 2 = selected Track V2 page, slot 3 = main1_play (page #04).
                CALL GS_StopMenuMusic
                CALL GS_LoadGameplaySoundsMaybeQuiet
                CALL SetCurrentTrackPage
                SetPage3 #04
                ; Дальше top-mask может занять #0AC000..#0CC000 — тот же
                ; временный буфер, откуда loading-DL читает буквы. Перед этим
                ; свопаем чистый чёрный кадр; следующий видимый кадр уже gameplay.
                CALL DrawBlackLoadingFrame
                CALL ZL_UploadTopMasksMaybe
                CALL SetCurrentTrackPage

                ; --- VDC physics init (Track V2 metadata/pages уже доступны) ---
                CALL VDC_Init
                CALL SetCurrentTrackPage               ; VDC_Init на двух цепочках трогает track-2: вход в gameplay всегда с chain-1
                CALL Frog_Init
                CALL Bullet_Init
                if RUNTIME_DIAGNOSTICS_ENABLED
                CALL Log_Init
                endif
                RET

GetCurrentLevelRecord:
                LD   A, (CurrentLevel)
                CP   LEVEL_RUNTIME_COUNT
                JR   C, .idx_ok
                XOR  A
.idx_ok:        LD   L, A
                LD   H, 0
                LD   E, L
                LD   D, H                              ; DE = index
                ADD  HL, HL                            ; *2
                ADD  HL, HL                            ; *4
                ADD  HL, HL                            ; *8
                ADD  HL, HL                            ; *16
                AND  A
                SBC  HL, DE                            ; *15
                LD   DE, LevelRuntimeTable
                ADD  HL, DE
                RET

GetCurrentLevelTitlePtr:
                LD   A, (CurrentLevel)
                CP   LEVEL_RUNTIME_COUNT
                JR   C, .idx_ok
                XOR  A
.idx_ok:        LD   L, A
                LD   H, 0
                ADD  HL, HL
                LD   DE, LevelTitlePtrTable
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

GetCurrentBgFirstPage:
                CALL GetCurrentLevelRecord
                LD   A, (HL)
                RET

GetCurrentBgPalettePage:
                CALL GetCurrentLevelRecord
                INC  HL
                LD   A, (HL)
                RET

GetCurrentTrackPage:
                CALL GetCurrentLevelRecord
                INC  HL
                INC  HL
                LD   A, (HL)
                RET

SetCurrentTrackPage:
                LD   HL, VDC_TrackPages1
                LD   (VDC_pTrackPages), HL
                LD   HL, (VDC_TrackSamples1)
                LD   (VDC_ActiveTrackSamples), HL
                LD   A, (VDC_TrackPages1)
                LD   (VDC_ActiveTrackPage1), A
                LD   A, #FF
                LD   (VDC_RenderTrackPageIdx), A
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A
                RET

SetSecondTrackPage:
                LD   HL, VDC_TrackPages2
                LD   (VDC_pTrackPages), HL
                LD   HL, (VDC_TrackSamples2)
                LD   (VDC_ActiveTrackSamples), HL
                LD   A, (VDC_TrackPages2)
                LD   (VDC_ActiveTrackPage1), A
                LD   A, #FF
                LD   (VDC_RenderTrackPageIdx), A
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A
                RET

; frog/kz X/Y хранятся в таблице УЖЕ в 1024-координатах (×1.6 запечено в
; level_runtime_table.inc генератором). Аксессоры возвращают как есть.
GetCurrentFrogX:
                CALL GetCurrentLevelRecord
                LD   DE, LEVEL_RT_FROG_X
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

GetCurrentFrogY:
                CALL GetCurrentLevelRecord
                LD   DE, LEVEL_RT_FROG_Y
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

GetCurrentKzX:
                CALL GetCurrentLevelRecord
                LD   DE, LEVEL_RT_KZ_X
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

GetCurrentKzY:
                CALL GetCurrentLevelRecord
                LD   DE, LEVEL_RT_KZ_Y
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                EX   DE, HL
                RET

GetCurrentLevelSettingIndex:
                LD   A, (CurrentSettingIndex)
                RET

GetCurrentLevelSettingRecord:
                CALL GetCurrentLevelSettingIndex
                LD   L, A
                LD   H, 0
                LD   E, L
                LD   D, H
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, DE                              ; setting index * 9
                LD   DE, LevelSettingsTable
                ADD  HL, DE
                RET

GetCurrentTargetScore:
                CALL GetCurrentLevelSettingRecord
                INC  HL
                INC  HL
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                ; Target score — per-level значение Zuma bar из level settings.
                ; Dual-chain progression — отдельные данные; bar не масштабировать.
                RET

; GetCurrentColors — ball-color count для текущего level/difficulty (settings field
; colors, offset +4). Ограничить к 1..VDC_NUM_COLORS; 0/absent → VDC_NUM_COLORS.
GetCurrentColors:
                CALL GetCurrentLevelSettingRecord
                LD   DE, 4
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .gcc_def                        ; 0 / absent → по умолчанию
                CP   Core.VDC_NUM_COLORS + 1
                RET  C                                  ; 1..NUM_COLORS → ok
.gcc_def:       LD   A, Core.VDC_NUM_COLORS
                RET

; GetCurrentSpeed — chain speed_x100 (settings +0). 0/absent → 50. Выход: A.
GetCurrentSpeed:
                CALL GetCurrentLevelSettingRecord
                LD   A, (HL)
                OR   A
                RET  NZ
                LD   A, 50
                RET

; GetCurrentStart — lead-in ball count (settings +1). 0/absent → 35. Выход: A.
GetCurrentStart:
                CALL GetCurrentLevelSettingRecord
                INC  HL
                LD   A, (HL)
                OR   A
                RET  NZ
                LD   A, 35
                RET

; VDC_LoadLevelSettings — заполнить per-level runtime-параметры из таблицы
; (colors/speed/start) + сброс speed-аккумулятора. Core-resident (зовётся из
; VDC_Init в Main1, который почти полон). Клобает AF, HL, DE.
VDC_LoadLevelSettings:
                CALL GetCurrentColors
                LD   (Core.VDC_LevelColors), A
                CALL GetCurrentSpeed
                LD   (Core.VDC_LevelSpeed), A
                CALL GetCurrentStart
                LD   (Core.VDC_LevelStart), A
                XOR  A
                LD   (Core.VDC_SpeedAccum), A
                RET

; VDC_SpeedAdvance — advance цепи в normal-phase с per-level speed. accum +=
; speed_x100; когда ≥100 → один VDC_MoveChain.
; Core-resident (Main1 почти полон). Портит AF, HL.
VDC_SpeedAdvance:
                LD   A, (Core.VDC_SpeedAccum)
                LD   HL, Core.VDC_LevelSpeed
                ADD  A, (HL)
                CP   100
                JR   C, .vsa_no
                SUB  100
                LD   (Core.VDC_SpeedAccum), A
                JP   Core.VDC_MoveChain                  ; tail: один advance, RET к caller
.vsa_no:        LD   (Core.VDC_SpeedAccum), A
                RET

GetCurrentPartime:
                CALL GetCurrentLevelSettingRecord
                LD   DE, 8
                ADD  HL, DE
                LD   A, (HL)
                RET

; Выход: CF=1 если в цепи есть хотя бы один живой цвет (< VDC_NUM_COLORS),
;      CF=0 если цепь пуста или состоит только из gap/explode markers.
VDC_ChainHasLiveBall:
                OR   A
                JR   Z, .cw_no_live
                LD   B, A
.cw_live_loop:  LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  C
                INC  HL
                DJNZ .cw_live_loop
.cw_no_live:    AND  A
                RET

VDC_CheckWinMaybe:
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ                                  ; trigger win только из PLAY; не re-arm WIN каждый frame
                LD   A, (VDC_GaugeFull)
                OR   A
                RET  Z
                LD   A, (VDC_SlotsLen)
                LD   HL, VDC_Slots
                CALL VDC_ChainHasLiveBall
                RET  C
                ; Dual-level gate: runtime flag ИЛИ identity уровня. Если
                ; VDC_HasSecondChain временно неверен, L05/L12/L19 всё равно
                ; не войдут в WIN, пока у VDC2 есть шары.
                LD   A, (VDC_HasSecondChain)
                OR   A
                JR   NZ, .win_check_second
                LD   A, (CurrentLevel)
                CP   4                                ; L05 blackswirley
                JR   Z, .win_check_second
                CP   11                               ; L12 snakepit
                JR   Z, .win_check_second
                CP   18                               ; L19 serpents
                JR   NZ, .win_all_clear
.win_check_second:
                LD   A, (VDC2_SlotsLen)
                LD   HL, VDC2_Slots
                CALL VDC_ChainHasLiveBall
                RET  C
.win_all_clear:
                XOR  A
                LD   (Bullet_Active), A
                LD   (Frog_IsFire), A
                LD   A, FROG_BALL_IDLE
                LD   (Frog_BallExpand), A
                LD   A, 24
                LD   (Frog_TongueExpand), A
                LD   A, VDC_STATE_WIN
                LD   (VDC_GameState), A
                LD   A, VDC_WIN_TICKS
                LD   (VDC_WinTick), A
                LD   A, VDC_PREVIEW_TICKS
                LD   (VDC_PreviewTick), A
                LD   A, 11
                LD   (VDC_KzFrame), A
                CALL WinAwardTimeBonus
                CALL VDC_WinOutroInit                    ; запустить «бикфорд» взрывов
                RET

; ============================================================================
; WIN-аутро (точно по оригиналу Zuma, Game_UpdateOutro/FX.c): эмиттер бежит по
; треку ОТ головного шара (ближайшего к килл-зоне) ДО конца трека (килл-зоны),
; скорость WINEXP_MOVE сэмплов/кадр; каждые WINEXP_PAD сэмплов роняет НЕЗАВИСИМУЮ
; частицу-взрыв (играет кадры 0..16, frame += 0.5/кадр) + 100 очков. Чем дальше
; голова была от КЗ — тем длиннее путь — тем больше +100 (бонус за дистанцию).
; ============================================================================
VDC_UpdateWin:
                LD   A, (VDC_WinOutroActive)
                OR   A
                JR   Z, .legacy                          ; нет аутро → fallback-таймер
                CALL VDC_WinOutroUpdate                   ; двигать эмиттеры + стареть частицы
                CALL VDC_WinOutroDone
                OR   A
                RET  Z                                    ; аутро ещё играет → ждём (таймер не нужен)
                JR   .win_show_done                       ; дорожка доиграла → диалог
.legacy:        LD   A, (VDC_PreviewTick)
                OR   A
                JR   Z, .pv_done
                DEC  A
                LD   (VDC_PreviewTick), A
.pv_done:       LD   A, (VDC_WinTick)
                OR   A
                JR   Z, .win_show_done
                DEC  A
                LD   (VDC_WinTick), A
                RET
.win_show_done: ; win-анимация закончилась → показать диалог LEVEL DONE (один раз).
                LD   A, (VDC_DialogState)
                CP   DLG_WIN_DONE
                RET  NC                                  ; уже win-done/fade → не пере-триггерить
                LD   A, SND_CHANT2                       ; победный чант по окончании аутро
                CALL GS_PlaySfx
                LD   A, DLG_WIN_DONE
                LD   (VDC_DialogState), A
                XOR  A
                LD   (FadeAlpha), A
                RET

; --- VDC_WinOutroInit — на входе в WIN: эмиттеры из head-сэмплов, пул пуст. ---
VDC_WinOutroInit:
                ; Дозалить атлас WIN-взрыва в регион шаров (#050000) — шаров на
                ; экране уже нет (нет live slots < VDC_NUM_COLORS; проверено в
                ; VDC_CheckWinMaybe), так
                ; что регион свободен. UnpackAndUploadPage резидентна (slot0),
                ; использует slot3 как scratch и восстанавливает его в
                ; CurrentCodePage (#04) — безопасно из gameplay-контекста.
                LD   HL, WINEXP_RAMG_ADDR & #FFFF
                LD   (BgRamL), HL
                LD   A, (WINEXP_RAMG_ADDR >> 16) & #FF
                LD   (BgRamH), A
                LD   A, WINEXP_PAGE
                LD   (BgPg), A
                LD   B, WINEXP_PAGE_COUNT
.winexp_up:     PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .winexp_up

                XOR  A
                LD   (VDC_WinOutroActive), A
                ; пул частиц → все мёртвые (f2=255 на смещении +4)
                LD   IX, VDC_WinPrtcl
                LD   B, WIN_PRTCL_MAX
.oi_clr:        LD   (IX+4), 255
                LD   DE, 5 : ADD IX, DE
                DJNZ .oi_clr
                ; chain1 эмиттер из VDC_WinHeadS1
                LD   HL, (VDC_WinHeadS1)
                LD   A, H : AND L : INC A                ; #FFFF?
                JR   Z, .oi_no1
                LD   (VDC_WinEmitPos1), HL
                LD   DE, WINEXP_PAD
                AND  A : SBC HL, DE                      ; spawn = head - PAD (первый спавн сразу)
                LD   (VDC_WinEmitSpawn1), HL
                LD   A, 1 : LD (VDC_WinOutroActive), A
                JR   .oi_c2
.oi_no1:        LD   HL, #FFFF : LD (VDC_WinEmitPos1), HL
.oi_c2:         LD   A, (VDC_HasSecondChain)
                OR   A
                JR   Z, .oi_no2set
                LD   HL, (VDC_WinHeadS2)
                LD   A, H : AND L : INC A
                JR   Z, .oi_no2
                LD   (VDC_WinEmitPos2), HL
                LD   DE, WINEXP_PAD
                AND  A : SBC HL, DE
                LD   (VDC_WinEmitSpawn2), HL
                LD   A, 1 : LD (VDC_WinOutroActive), A
                RET
.oi_no2:
.oi_no2set:     LD   HL, #FFFF : LD (VDC_WinEmitPos2), HL
                RET

; --- VDC_WinSpawnParticle — BC=X, DE=Y: занять мёртвый слот (f2=0). Пул полон → скип. ---
VDC_WinSpawnParticle:
                LD   (VDC_WinSpawnX), BC
                LD   (VDC_WinSpawnY), DE
                LD   IX, VDC_WinPrtcl
                LD   B, WIN_PRTCL_MAX
.sp_find:       LD   A, (IX+4)
                CP   255
                JR   Z, .sp_use
                LD   DE, 5 : ADD IX, DE
                DJNZ .sp_find
                RET                                      ; пул полон
.sp_use:        LD   HL, (VDC_WinSpawnX)
                LD   (IX+0), L : LD (IX+1), H
                LD   HL, (VDC_WinSpawnY)
                LD   (IX+2), L : LD (IX+3), H
                LD   (IX+4), 0
                RET

; --- VDC_WinEmitStep — шаг одного эмиттера. Вход: VDC_WinStepPos/Spawn заданы,
;     слот2 = трек этой цепочки. Выход: те же vars обновлены (#FFFF=дошёл до КЗ). ---
VDC_WinEmitStep:
                LD   HL, (VDC_WinStepPos)
                LD   A, H : AND L : INC A
                RET  Z                                   ; #FFFF → неактивен
                ; S_kz = NumSamples-1; если pos > S_kz → done
                LD   DE, (VDC_ActiveTrackSamples)
                DEC  DE                                  ; DE = S_kz
                EX   DE, HL                              ; HL=S_kz, DE=pos
                AND  A : SBC HL, DE                      ; S_kz - pos
                JP   M, .es_done                         ; pos > S_kz
                ; спавн? (pos - spawn) >= PAD
                LD   HL, (VDC_WinStepPos)
                LD   DE, (VDC_WinStepSpawn)
                AND  A : SBC HL, DE                      ; pos - spawn
                LD   DE, WINEXP_PAD
                AND  A : SBC HL, DE                      ; (pos-spawn) - PAD
                JP   M, .es_advance                      ; < PAD → без спавна
                LD   HL, (VDC_WinStepPos)
                CALL VDC_ReadSampleAtHL                  ; BC=X, DE=Y по сэмплу pos
                CALL VDC_WinSpawnParticle
                LD   A, SND_ENDOFLEVELPOP1
                CALL GS_PlaySfx
                LD   HL, 100
                CALL Score_Add24                         ; +100 за взрыв (бонус за дистанцию)
                LD   HL, (VDC_WinStepPos)
                LD   (VDC_WinStepSpawn), HL              ; spawn = pos
.es_advance:    LD   HL, (VDC_WinStepPos)
                LD   DE, WINEXP_MOVE
                ADD  HL, DE
                LD   (VDC_WinStepPos), HL
                RET
.es_done_kz:    LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL                                  ; HL = S_kz
                LD   DE, (VDC_WinStepSpawn)
                AND  A : SBC HL, DE                      ; уже спавнили ровно в KZ?
                JR   Z, .es_done
                LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL
                CALL VDC_ReadSampleAtHL                  ; финальная точка kill-zone
                CALL VDC_WinSpawnParticle
                LD   A, SND_ENDOFLEVELPOP1
                CALL GS_PlaySfx
                LD   HL, 100
                CALL Score_Add24
.es_done:       
                ; pos > S_kz
                ; Check if we already spawned exactly at S_kz
                LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL                                  ; HL = S_kz
                LD   DE, (VDC_WinStepSpawn)
                AND  A : SBC HL, DE                      ; S_kz - spawn
                JR   Z, .es_done_skip
                
                ; Spawn final KZ particle exactly at S_kz
                LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL
                CALL VDC_ReadSampleAtHL
                CALL VDC_WinSpawnParticle
                LD   A, SND_ENDOFLEVELPOP1
                CALL GS_PlaySfx
                LD   HL, 100
                CALL Score_Add24

.es_done_skip:
                LD   HL, #FFFF
                LD   (VDC_WinStepPos), HL
                RET

; --- VDC_WinOutroUpdate — старит частицы и двигает оба эмиттера (по своим трекам). ---
VDC_WinOutroUpdate:
                ; старение частиц: f2 += 1; >32 → мертва (frame 0..16 = f2/2)
                LD   IX, VDC_WinPrtcl
                LD   B, WIN_PRTCL_MAX
.ou_age:        LD   A, (IX+4)
                CP   255
                JR   Z, .ou_next
                INC  A
                CP   WINEXP_F2_MAX + 1
                JR   C, .ou_store
                LD   A, 255
.ou_store:      LD   (IX+4), A
.ou_next:       LD   DE, 5 : ADD IX, DE
                DJNZ .ou_age
                ; эмиттер chain1 (текущий трек)
                CALL SetCurrentTrackPage
                LD   HL, (VDC_WinEmitPos1)   : LD (VDC_WinStepPos), HL
                LD   HL, (VDC_WinEmitSpawn1) : LD (VDC_WinStepSpawn), HL
                CALL VDC_WinEmitStep
                LD   HL, (VDC_WinStepPos)    : LD (VDC_WinEmitPos1), HL
                LD   HL, (VDC_WinStepSpawn)  : LD (VDC_WinEmitSpawn1), HL
                ; эмиттер chain2 (второй трек), если дубль
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                CALL SetSecondTrackPage
                LD   HL, (VDC_WinEmitPos2)   : LD (VDC_WinStepPos), HL
                LD   HL, (VDC_WinEmitSpawn2) : LD (VDC_WinStepSpawn), HL
                CALL VDC_WinEmitStep
                LD   HL, (VDC_WinStepPos)    : LD (VDC_WinEmitPos2), HL
                LD   HL, (VDC_WinStepSpawn)  : LD (VDC_WinEmitSpawn2), HL
                JP   SetCurrentTrackPage

; --- VDC_WinOutroDone — A=1 если оба эмиттера дошли И нет живых частиц. ---
VDC_WinOutroDone:
                LD   HL, (VDC_WinEmitPos1)
                LD   A, H : AND L : INC A
                JR   Z, .od_e1
                XOR  A : RET                             ; эмиттер1 активен → не готово
.od_e1:         LD   HL, (VDC_WinEmitPos2)
                LD   A, H : AND L : INC A
                JR   Z, .od_e2
                XOR  A : RET
.od_e2:         LD   IX, VDC_WinPrtcl
                LD   B, WIN_PRTCL_MAX
.od_chk:        LD   A, (IX+4)
                CP   255
                JR   NZ, .od_alive
                LD   DE, 5 : ADD IX, DE
                DJNZ .od_chk
                LD   A, 1 : RET                          ; всё доиграло
.od_alive:      XOR  A : RET

VDC_WinStepPos:    DEFW 0
VDC_WinStepSpawn:  DEFW 0
VDC_WinSpawnX:     DEFW 0
VDC_WinSpawnY:     DEFW 0

; AdvanceToNextLevel удалён 2026-05-30: это была МЁРТВАЯ вторая копия win-перехода
; (RET-вариант без SetPage3/JP MainLoop), нигде не вызывалась и плодила
; расхождение путей. Единый вход теперь — EnterGameplayForCurrentLevel (ниже).

; Win flow handoff: экран уже полностью чёрный после DLG_WIN_FADE.
; Продвигаем текущую цепочку и проваливаемся в ЕДИНЫЙ вход геймплея —
; тот же код, что и заход из меню.
LoadNextLevelWithLoading:
                LD   A, (CurrentGameMode)
                OR   A
                JR   NZ, .gauntlet_next
                LD   A, (CurrentLevel)
                CP   LAST_NORMAL_LEVEL_INDEX
                JR   NZ, .adv_inc
                LD   A, (CurrentDifficulty)
                OR   A
                JR   Z, .adv_to_rank2
                CP   1
                JR   Z, .adv_to_rank3
                CP   2
                JR   Z, .adv_to_rank4
                LD   A, ADVENTURE_SPACE_POS             ; 21-4 -> Space WIN-state
                JR   .adv_store
.adv_to_rank2:  LD   A, ADVENTURE_RANK2_POS              ; 21-1 -> 1-2
                JR   .adv_store
.adv_to_rank3:  LD   A, ADVENTURE_RANK3_POS              ; 21-2 -> 1-3
                JR   .adv_store
.adv_to_rank4:  LD   A, ADVENTURE_RANK4_POS              ; 21-3 -> 1-4
                JR   .adv_store
.adv_inc:
                LD   A, (AdventurePos)
                INC  A
                CP   ADVENTURE_CHAIN_COUNT
                JR   C, .adv_store
                XOR  A
.adv_store:     LD   (AdventurePos), A
                JR   EnterGameplayForCurrentLevel

.gauntlet_next:
                LD   A, (CurrentLevel)
                CP   SPACE_LEVEL_INDEX
                JR   Z, .gauntlet_restart
                CP   LAST_NORMAL_LEVEL_INDEX
                JR   NZ, .gauntlet_inc
                LD   A, (CurrentDifficulty)
                CP   3
                JR   NC, .gauntlet_space                 ; 21-4 -> Space WIN-state
                INC  A
                LD   (CurrentDifficulty), A              ; 21-N -> 1-(N+1), N=1..3
                XOR  A
                JR   .lnl_store
.gauntlet_space:
                LD   A, SPACE_LEVEL_INDEX
                JR   .lnl_store
.gauntlet_inc:
                LD   A, (CurrentLevel)
                INC  A
                CP   LEVEL_SELECT_COUNT
                JR   C, .lnl_store
.gauntlet_restart:
                XOR  A
                LD   (CurrentDifficulty), A
.lnl_store:     LD   (CurrentLevel), A
                ; дальше сразу EnterGameplayForCurrentLevel

; ----------------------------------------------------------------------------
; EnterGameplayForCurrentLevel — ЕДИНЫЙ вход в геймплей для текущего CurrentLevel.
; Используется обоими путями: из меню (FadeLevelSelectToGameplay → Score_Reset →
; сюда) и по победе (LoadNextLevelWithLoading → сюда). Раньше win-путь делал RET
; в середину кадрового цикла вместо чистого JP MainLoop и держал ОТДЕЛЬНУЮ копию
; page-setup → «не тот фон/трек» на части переходов лечили по одному уровню.
; Теперь ОДНА проверенная последовательность для обоих → один класс багов.
; Предусловие: экран уже чёрный (вызывающий сделал fade-out). Adventure-счёт НЕ
; трогаем — его сбрасывает только меню-вход (Score_Reset) перед заходом.
; LOADING_TEXT живёт в той же области, что frame strips, поэтому ShowCurrent...
; заново заливает его в RAM_G и рисует стабильный чёрный loading-кадр.
; Не возвращается: JP MainLoop = чистый перезапуск кадрового цикла.
EnterGameplayForCurrentLevel:
                CALL Cache_C000_Off
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_ResolveCurrentModeSelection
                XOR  A
                LD   (FadeAlpha), A                     ; сброс fade: иначе DrawFadeOverlay зальёт геймплей чёрным
                ; LOADING-экран рисуем ПОКА slot3=#40 (код перенесён в loader overlay,
                ; page 0 разгружена). ВАЖНО: CurrentCodePage=#40 ДО UploadLoadingText —
                ; shared-декомпрессор в конце восстанавливает slot3 из CurrentCodePage,
                ; а там ещё #41 от level-select → CALL в #40-код улетал в страницу #41
                ; (краш «Illegal port, PC=41:EB4E», репорт юзера 2026-06-11).
                LD   A, LOADER_OVL_PAGE
                LD   (CurrentCodePage), A
                CALL UploadGameplayLoadingText
                CALL OVL_DrawNextLevelLoadingScreen
                SetPage3 #04                            ; slot 3 → gameplay overlay ДО загрузки ассетов
                LD   A, #04
                LD   (CurrentCodePage), A               ; track scene page (shared-декомпрессоры восстанавливают сюда)
                CALL LoadGameplayAssets
                ; LoadGameplayAssets уже погасил loading-DL перед повторным
                ; использованием #0AC000 под top-mask/dialog swap-zone.
                JP   Cache_C000_OnMainLoop

DrawBlackLoadingFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_Display
                FT_CMD_Count
.dbl_wait_swap: FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .dbl_wait_swap
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

DrawLoadingLevelsScreen:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_CMD_BUF #04FFFFFF                    ; COLOR_RGB white
                FT_Begin FT_BITMAPS

                FT_BitmapHandle LOADING_TEXT_HANDLE
                FT_BitmapSource LOADING_TEXT_RAMG
                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LOADING_TEXT_PREFIX_W, LOADING_TEXT_H
                LD   BC, ((640 - LOADING_LEVELS_W) / 2) * 16
                LD   DE, ((480 - LOADING_TEXT_H) / 2) * 16
                CALL FT.Coprocessor.Vertex2f

                FT_BitmapHandle LOADING_TEXT_HANDLE
                FT_BitmapSource LOADING_TEXT_RAMG + (LOADING_TEXT_SUFFIX_LEVELS_X * 2)
                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LOADING_TEXT_SUFFIX_LEVELS_W, LOADING_TEXT_H
                LD   BC, (((640 - LOADING_LEVELS_W) / 2) + LOADING_TEXT_PREFIX_W) * 16
                LD   DE, ((480 - LOADING_TEXT_H) / 2) * 16
                CALL FT.Coprocessor.Vertex2f

                FT_End
                FT_Display
                FT_CMD_Count
.dlls_wait_swap:
                FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .dlls_wait_swap
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

; [DrawNextLevelLoadingScreen + helpers/данные перенесены в loader overlay #40
;  (loading_screen_ovl40.inc, метки OVL_*) — page 0 разгружена, 2026-06-11.]

WinAwardTimeBonus:
                CALL GetCurrentPartime
                LD   B, A                                ; B = par time seconds
                LD   HL, (VDC_GameSeconds)
                LD   A, H
                OR   A
                RET  NZ                                  ; over 255 sec: no byte-sized bonus
                LD   A, L
                CP   B
                RET  NC                                  ; elapsed >= par
                LD   A, B
                SUB  L                                   ; remaining seconds
                LD   B, A
                LD   HL, 0
                LD   DE, 100
.bonus_loop:    ADD  HL, DE
                DJNZ .bonus_loop
                CALL Score_Add24                       ; HL=ace-time bonus; 24-bit score += HL + extra-life
                RET

VDC_AwardGapBonusSlot0:
                LD   A, (VDC_BulletGapMinDist)
                CP   VDC_GAP_HIT_THR + 1
                JR   NC, .no_gap                         ; > THR -> matched, but not through a gap
                LD   HL, VDC_BulletGapCount
                INC  (HL)
                ; Форма перенесена из HD-ref:
                ; points = 500 * (GAP_MAX - distance) / GAP_MAX, ограничить >= 10.
                ; В этом port distance — Manhattan distance до nearest GAP slot.
                LD   B, A                                ; B = distance
                LD   A, VDC_GAP_MAX
                SUB  B                                   ; A = GAP_MAX - distance
                LD   B, A
                LD   HL, 0
                LD   DE, 500
.mul500:        ADD  HL, DE
                DJNZ .mul500
                LD   A, VDC_GAP_MAX
                CALL VDC_DivHLbyA
                LD   A, H
                OR   A
                JR   NZ, .have_bonus
                LD   A, L
                CP   10
                JR   NC, .have_bonus
                LD   HL, 10
.have_bonus:    LD   A, (VDC_BulletGapCount)
                CP   2
                JR   C, .have_final
                ADD  HL, HL                              ; consecutive gap bonus x2
.have_final:    PUSH HL
                LD   A, SND_GAPBONUS1
                CALL GS_PlaySfx
                POP  HL
                PUSH HL
                CALL Score_Add24                       ; HL=gap bonus; 24-bit score += HL + extra-life
                POP  HL
                LD   DE, (VDC_GaugeScore)
                ADD  HL, DE
                LD   (VDC_GaugeScore), HL
                CALL GetCurrentTargetScore             ; DE = per-level target (клобает HL)
                LD   HL, (VDC_GaugeScore)               ; reload score before compare
                AND  A
                SBC  HL, DE
                JR   C, .done
                LD   A, (VDC_GaugeFull)
                OR   A
                JR   NZ, .gap_set_full
                LD   A, SND_CHORAL1
                CALL GS_PlaySfx
.gap_set_full:
                LD   A, 1
                LD   (VDC_GaugeFull), A
.done:          RET
.no_gap:        XOR  A
                LD   (VDC_BulletGapCount), A
                RET

; LoadLevelSelectPreviewAssets реализован как OVL_LoadLevelSelectPreviewAssets
; в loader overlay (ts-dos.asm). Резидентный trampoline с тем же именем мапит
; overlay и вызывает OVL_*; вызывающий код в level-select не менялся.

LoadLevelSelectFontNative:
                LD   A, FONT_NATIVE_PAGE_BASE
                LD   (BgPg), A
                LD   HL, FONT_NATIVE_RAMG & #FFFF
                LD   (BgRamL), HL
                LD   A, (FONT_NATIVE_RAMG >> 16) & #FF
                LD   (BgRamH), A
                LD   B, FONT_NATIVE_NUM_PAGES
.upload_font:   PUSH BC
                LD   A, (BgPg)
                CALL UnpackAndUploadPage
                POP  BC
                LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .upload_font
                RET

                if !FROG_ARGB4_ENABLED
UploadFrogPalette:
                PUSH HL                                ; input HL = low 16 bits of RAM_G palette addr
                SetPage2_A
                POP  DE
                LD   HL, #8000
                LD   BC, 512
                LD   A, #0C                            ; all frog palettes live at #0C0000..#0C07FF
                JP   FT.WriteMem
                endif

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 8                               ; 400×300 PALETTED4444 = 120000 bytes, 8 × 16K pages
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BG_PALETTE_PAGE    EQU #11      ; #0F занят ZiFi SD driver (WDFCVBI2.COD)
BG_PALETTE_RAMG    EQU #02D500                         ; 4-byte aligned, после полезного 400×300 bitmap
BALLS_FIRST_PAGE   EQU #43                             ; global PALETTED4444 balls pages
BALLS_PAGE_COUNT   EQU 12                              ; 6×12×51×51 = 187272 bytes, padded to 192 KB
BALLS_PALETTE_PAGE EQU #4F                             ; 512-byte ARGB4 palette
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000)
BALLS_PALETTE_RAMG EQU #080000                         ; FT_RAM_G — после balls (192K=#080000), 4-byte aligned
FROG_PAGE          EQU #52                             ; body, plate, tongue, overlay pages
                if FROG_ARGB4_ENABLED
FROG_TOTAL_PAGES   EQU 8                               ; 4 × 122×122 ARGB4 blocks, 2 pages each
FROG_RAMG_ADDR     EQU #030000                         ; permanent ARGB4 frog block, before balls
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #8000
TONGUE_RAMG_ADDR   EQU FROG_RAMG_ADDR + #10000
OVERLAY_RAMG_ADDR  EQU FROG_RAMG_ADDR + #18000
                else
FROG_TOTAL_PAGES   EQU 4                               ; 4 × 122×122 PALETTED4444 blocks
FROG_RAMG_ADDR     EQU #0B0000                         ; after balls/frame reserved area
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #4000          ; #0B4000
TONGUE_RAMG_ADDR   EQU PLATE_RAMG_ADDR + #4000         ; #0B8000
OVERLAY_RAMG_ADDR  EQU TONGUE_RAMG_ADDR + #4000        ; #0BC000
                endif
FROG_PALETTE_PAGE  EQU #56                             ; 512-byte ARGB4 palette
FROG_PALETTE_RAMG  EQU #0C0000                         ; 4-byte aligned, before cursor/kz
PLATE_PALETTE_PAGE EQU #57
PLATE_PALETTE_RAMG EQU #0C0200
TONGUE_PALETTE_PAGE EQU #58
TONGUE_PALETTE_RAMG EQU #0C0400
OVERLAY_PALETTE_PAGE EQU #59
OVERLAY_PALETTE_RAMG EQU #0C0600
KZ_PAGE            EQU #16
KZ_PAGE_COUNT      EQU 10                              ; killzone 6 pages + destroy 4 pages
KZ_RAMG_ADDR       EQU #0D4000                         ; после cursor page, ниже RAM_G 1 MB limit
KZ_PALETTE_RAMG    EQU #0EAB00                         ; после 88×88×12 PALETTED4444 pixels, внутри page #1B padding
DESTROY_PAGE       EQU #1C                              ; match-3 серый animBallDestroy, 13 кадров, 4 стр.
DESTROY_RAMG_ADDR  EQU #0EC000                         ; после killzone atlas

; --- WIN explosion (оранжевый animExplosion, 17 кадров, 5 страниц) ---
; ВНИМАНИЕ: RAM_G у FT812 = ровно 1 МБ (FT_RAM_G_SIZE = 0x100000). Прошлая
; сессия ошибочно сочла «4 МБ» (на самом деле это системная RAM ZX Evolution, не
; графическая RAM_G чипа) и положила атлас на #100000 — это первый байт ЗА
; границей RAM_G → на железе запись уходит за пределы/аливасится в низ RAM_G и
; портит фон/текст/спрайты (на EVE-эмуляторе с бОльшим RAM_G не воспроизводилось).
; ФИКС: к моменту WIN шаров на экране уже нет → переиспользуем регион атласа шаров
; (#050000, 192 КБ). Атлас НЕ грузится при загрузке уровня, а дозаливается по SPI
; на входе в WIN (VDC_WinOutroInit). После WIN→след.уровень LoadGameplayAssets
; заново зальёт шары в #050000.
WINEXP_PAGE        EQU #28                              ; SPG #28..#2C (5 страниц)
WINEXP_PAGE_COUNT  EQU 5
WINEXP_RAMG_ADDR   EQU BALLS_RAMG_ADDR                  ; #050000: 17×48×48×2=78336 (80 КБ) влезает в 192 КБ региона шаров

; --- Global cursor 38×38 ARGB4, zlib source page shared by gameplay/menu/level-select ---
CURSOR_PAGE        EQU #5A
CURSOR_Z_SIZE      EQU 447
CURSOR_RAMG_ADDR   EQU #0D0000                         ; after frog overlay area
CURSOR_W           EQU 38                              ; atlas (layout) — матчится с make_cursor.py
CURSOR_H           EQU 38
CURSOR_DRAW        EQU 38                              ; native 1024×768 cursor, без апскейла
CURSOR_TIP_X       EQU 1                               ; острие sprite-coords (см. make_cursor.py)
CURSOR_TIP_Y       EQU 1

BgPg:           DEFB 0
BgRamL:         DEFW 0
BgRamH:         DEFB 0

Init_Core:      CALL SpiBusIdle                       ; warm reset does not clear Z-Controller SPI CS latch
                FMapAddrInit                          ; FT_EN, MEM_WO, page0=TSLibPage
                System_Setting SYS_ZCLK14 | SYS_CACHEEN
                Cache_Setting  EN_0000 | EN_4000
                SetPage1 5                            ; #4000 → страница кода Core (main0 resident)
                SetPage2 6                            ; #8000 → first Track V2 page после level load
                SetPage3 UI_OVL_PAGE                  ; #C000 → UI overlay (boot scene = menu); gameplay мапит #04 в FadeLevelSelectToGameplay
                if RUNTIME_DIAGNOSTICS_ENABLED
                LD   HL, BuildCanaryBytes
                LD   DE, BUILD_CANARY_ADDR
                LD   BC, BUILD_CANARY_LEN
                LDIR
                endif
                RET

; Как можно раньше привести общую FT812/SD SPI-шину в известный idle state.
; Z80 warm reset может оставить Z-Controller port #77 с выбранным FT или SD.
SpiBusIdle:     PUSH AF
                PUSH BC
                PUSH DE
                LD   BC, SPI_CTRL
                LD   A, SPI_FT_CS_OFF                 ; #03: deselect FT812 and SD
                OUT  (C), A
                LD   BC, SPI_DATA
                LD   A, #FF
                LD   D, 16
.sbi_clk:       OUT  (C), A
                DEC  D
                JR   NZ, .sbi_clk
                LD   BC, SPI_CTRL
                LD   A, SPI_FT_CS_OFF
                OUT  (C), A
                POP  DE
                POP  BC
                POP  AF
                RET

                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_CORE_DATA
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_CORE_DATA
                endif

TrackData       EQU #8000                             ; slot 2 window, now Track V2 sample page

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

; Pause/exit confirmation dialog. Dialog state 3 — настоящая pause: VDC_Update
; обновляет RTC baseline и возвращается, поэтому elapsed game time не включает меню.
UpdatePauseDialog:
                LD   A, 1
                LD   (VDC_HudPointerBlock), A

                ; --- Влево/Вправо переключают активную кнопку: Влево → Yes(0), Вправо → No(1) ---
                ; Через Input_Left/Input_Right (PS/2-стрелки ←/→ + Kempston). Мышь-ховер
                ; ниже всё ещё может переопределить, когда курсор над кнопкой.
                CALL Input_Left
                JR   Z, .upd_lr_right
                XOR  A
                LD   (PauseMenuChoice), A              ; Влево → Yes
                JR   .upd_lr_done
.upd_lr_right:  CALL Input_Right
                JR   Z, .upd_lr_done
                LD   A, 1
                LD   (PauseMenuChoice), A              ; Вправо → No («Отмена»)
.upd_lr_done:
                CALL PauseMouseInYes
                OR   A
                JR   Z, .upd_check_no_hover
                XOR  A
                LD   (PauseMenuChoice), A              ; 0 = Yes
                JR   .upd_fire
.upd_check_no_hover:
                CALL PauseMouseInNo
                OR   A
                JR   Z, .upd_fire
                LD   A, 1
                LD   (PauseMenuChoice), A              ; 1 = No

.upd_fire:      ; Клавиша огня (Space|Enter|Kempston) — минуя hit-test. ЛКМ ниже (.mouse).
                CALL Input_FireKey
                JR   NZ, .fire_edge                    ; нажата
                XOR  A
                LD   (PauseMenuFirePrev), A
                JR   .mouse
.fire_edge:     LD   A, (PauseMenuFirePrev)
                OR   A
                JR   NZ, .mouse
                LD   A, 1
                LD   (PauseMenuFirePrev), A
                JR   .action

.mouse:         CALL Core.Input_MouseLMB
                LD   A, 0
                JR   Z, .lmb_set
                INC  A
.lmb_set:       LD   C, A
                LD   A, (VDC_PrevMouseL)
                LD   B, A
                LD   A, C
                LD   (VDC_PrevMouseL), A
                LD   A, B
                OR   A
                RET  Z
                LD   A, C
                OR   A
                RET  NZ
                CALL PauseMouseInYes
                OR   A
                JR   Z, .click_no
                XOR  A
                LD   (PauseMenuChoice), A
                JR   .action
.click_no:      CALL PauseMouseInNo
                OR   A
                RET  Z
                LD   A, 1
                LD   (PauseMenuChoice), A

.action:        LD   A, (PauseMenuChoice)
                OR   A
                JR   NZ, .resume
                XOR  A
                LD   (VDC_DialogState), A
                LD   (VDC_PrevMouseL), A
                LD   (PauseMenuFirePrev), A
                POP  HL                                ; abandon MainLoop CALL UpdateDialog
                JP   FadeGameplayToMenu
.resume:        ; "No" -> начать 1 s window fade-out. Остаёмся not-Play
                ; (DialogState=4), чтобы frog не стрелял и game time был frozen;
                ; frog sprite начинает рисоваться с этого первого fade frame.
                LD   A, 4
                LD   (VDC_DialogState), A
                LD   A, PAUSE_FADE_FRAMES
                LD   (PauseFadeTimer), A
                LD   A, 255
                LD   (VDC_PauseAlpha), A
                XOR  A
                LD   (VDC_PrevMouseL), A                ; погасить click "No"
                LD   (PauseMenuFirePrev), A
                RET

; UpdatePauseFade — вызывается каждый frame при VDC_DialogState=4 (pause "No"
; fade-out). Board остаётся frozen (not-Play: no shot, no game-time). Alpha pause
; window падает за PAUSE_FADE_FRAMES; по окончании -> DialogState=0 (PLAY).
UpdatePauseFade:
                LD   A, 1
                LD   (VDC_HudPointerBlock), A           ; погасить fire edge во время fade
                LD   A, (PauseFadeTimer)
                DEC  A
                LD   (PauseFadeTimer), A
                JR   Z, .pf_done
                ; VDC_PauseAlpha = min(255, timer * 4)
                LD   L, A
                LD   H, 0
                ADD  HL, HL
                ADD  HL, HL                             ; HL = timer*4
                LD   A, H
                OR   A
                LD   A, 255
                JR   NZ, .pf_set                        ; >=256 -> clamp
                LD   A, L
.pf_set:        LD   (VDC_PauseAlpha), A
                RET
.pf_done:       XOR  A
                LD   (VDC_DialogState), A                ; -> PLAY
                LD   (VDC_PrevMouseL), A
                LD   (PauseMenuFirePrev), A
                LD   A, 255
                LD   (VDC_PauseAlpha), A
                LD   A, 1
                LD   (Frog_PrevMouseLeft), A             ; consume button edge: no shot on resume frame
                RET

UpdateHudMenuCore:
                LD   A, (VDC_DialogState)
                OR   A
                JR   Z, .check
                XOR  A
                LD   (VDC_HudMenuState), A
                INC  A
                LD   (VDC_HudPointerBlock), A
                RET
.check:         CALL HudMenuMouseInside
                OR   A
                JR   Z, .out
                LD   A, (VDC_GameState)
                OR   A
                JR   NZ, .out
                LD   A, 1
                LD   (VDC_HudPointerBlock), A
                CALL Core.Input_MouseLMB
                LD   A, 0
                JR   Z, .have_lmb
                LD   A, 1
.have_lmb:      LD   C, A                              ; C = now: 0=released, 1=pressed (HW active-low)
                LD   A, (VDC_PrevMouseL)
                LD   B, A                              ; B = prev
                LD   A, C
                LD   (VDC_PrevMouseL), A
                OR   A
                JR   NZ, .pressed                      ; ЛКМ удерживается → вдавленный вид
                LD   A, B
                OR   A
                JR   Z, .hover                         ; не было и нет → hover
                ; Отпускание НАД кнопкой → действие (как в оригинале: кнопка
                ; срабатывает по mouse-up; вдавленное состояние видно всё время
                ; удержания — раньше диалог открывался по нажатию и в том же
                ; кадре сбрасывал state=2 → pressed-вид не показывался никогда).
                LD   A, SND_SILENCE
                CALL GS_PlaySfx
                LD   A, 3
                LD   (VDC_DialogState), A
                LD   A, 1
                LD   (PauseMenuChoice), A
                XOR  A
                LD   (VDC_HudMenuState), A
                LD   (PauseMenuFirePrev), A
                RET
.pressed:       LD   A, 2
                LD   (VDC_HudMenuState), A             ; держим вдавленной до отпускания
                RET
.hover:         LD   A, 1
                LD   (VDC_HudMenuState), A
                RET
.out:           XOR  A
                LD   (VDC_HudMenuState), A
                LD   (VDC_HudPointerBlock), A
                LD   (VDC_PrevMouseL), A
                RET

; EscToMenu — ESC = нажатие кнопки MENU: открыть pause/exit-диалог в геймплее.
; Edge по ESC (только на нажатии). Открытый диалог по умолчанию имеет активную
; кнопку No («Отмена») — как при клике по MENU (см. UpdateHudMenuCore).
EscToMenu:
                CALL Input_Esc
                JR   Z, .esc_up
                LD   A, (EscPrev)
                OR   A
                RET  NZ                                ; ESC держится — не повторять
                LD   A, 1
                LD   (EscPrev), A
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ                                ; только в PLAY (state 0)
                LD   A, (VDC_DialogState)
                OR   A
                RET  NZ                                ; только если диалога ещё нет
                LD   A, SND_SILENCE
                CALL GS_PlaySfx
                LD   A, 3
                LD   (VDC_DialogState), A              ; открыть pause/exit-диалог
                LD   A, 1
                LD   (PauseMenuChoice), A              ; по умолчанию активна No («Отмена»)
                XOR  A
                LD   (VDC_HudMenuState), A
                LD   (PauseMenuFirePrev), A
                LD   (VDC_PrevMouseL), A
                RET
.esc_up:        XOR  A
                LD   (EscPrev), A
                RET
EscPrev:        DEFB 0

HudMenuMouseInside:
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, HUD_MENU_HIT_X
                AND  A
                SBC  HL, DE
                JR   C, .out
                LD   HL, (Input.Mouse.PositionX)
                LD   DE, HUD_MENU_HIT_X + HUD_MENU_HIT_W
                AND  A
                SBC  HL, DE
                JR   NC, .out
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, HUD_MENU_HIT_Y
                AND  A
                SBC  HL, DE
                JR   C, .out
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, HUD_MENU_HIT_Y + HUD_MENU_HIT_H
                AND  A
                SBC  HL, DE
                JR   NC, .out
                LD   A, 1
                RET
.out:           XOR  A
                RET

PauseMouseInYes:
                LD   DE, PAUSE_YES_X
                JR   PauseMouseInButton
PauseMouseInNo:
                LD   DE, PAUSE_NO_X
PauseMouseInButton:
                LD   HL, (Input.Mouse.PositionX)
                AND  A
                SBC  HL, DE
                JR   C, .out
                LD   HL, (Input.Mouse.PositionX)
                LD   BC, PAUSE_BTN_W
                EX   DE, HL
                ADD  HL, BC
                EX   DE, HL
                AND  A
                SBC  HL, DE
                JR   NC, .out
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, PAUSE_BTN_Y
                AND  A
                SBC  HL, DE
                JR   C, .out
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, PAUSE_BTN_Y + PAUSE_BTN_H
                AND  A
                SBC  HL, DE
                JR   NC, .out
                LD   A, 1
                RET
.out:           XOR  A
                RET

; PauseColorA — FT812 global alpha = (A * VDC_PauseAlpha) / 256. Даёт всему
; pause window fade во время "No" fade-out. VDC_PauseAlpha=255 (static
; pause/game-over dialogs) оставляет base alpha A без изменений.
PauseColorA:
                LD   D, A                                ; D = base alpha
                LD   A, (VDC_PauseAlpha)
                CP   255
                JR   Z, .pca_full
                LD   E, A                                ; E = fade alpha
                CALL Frog_Mul8x8u                        ; HL = base * fade
                LD   E, H                                ; E = product >> 8
                JP   FT.Coprocessor.ColorA
.pca_full:      LD   E, D
                JP   FT.Coprocessor.ColorA

DrawPauseDialogContent:
                CALL SetFontNative
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   A, 255
                CALL PauseColorA
                LD   HL, str_pause_exit
                CALL StrWidth
                EX   DE, HL
                SRL  H
                RR   L
                LD   DE, PAUSE_TITLE_CENTER_X
                EX   DE, HL
                AND  A
                SBC  HL, DE
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                LD   B, H
                LD   C, L
                LD   DE, PAUSE_TITLE_Y * 16
                LD   HL, str_pause_exit
                CALL DrawString

                FT_End
                CALL DrawPauseButtonRects
                FT_Begin FT_BITMAPS
                CALL SetFontNative
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   A, 255
                CALL PauseColorA
                LD   HL, str_yes
                LD   BC, PAUSE_YES_TEXT_X * 16
                LD   DE, PAUSE_BTN_TEXT_Y * 16
                CALL DrawString
                LD   HL, str_no
                LD   BC, PAUSE_NO_TEXT_X * 16
                LD   DE, PAUSE_BTN_TEXT_Y * 16
                JP   DrawString

DrawPauseButtonRects:
                LD   A, (PauseMenuChoice)
                OR   A
                JR   NZ, .yes_dim
                LD   C, 245 : LD D, 180 : LD E, 60
                JR   .yes_color
.yes_dim:       LD   C, 70 : LD D, 62 : LD E, 48
.yes_color:     CALL FT.Coprocessor.ColorRGB
                LD   A, 220
                CALL PauseColorA
                FT_Begin FT_RECTS
                LD   BC, PAUSE_YES_X * 16
                LD   DE, PAUSE_BTN_Y * 16
                CALL FT.Coprocessor.Vertex2f
                LD   BC, (PAUSE_YES_X + PAUSE_BTN_W) * 16
                LD   DE, (PAUSE_BTN_Y + PAUSE_BTN_H) * 16
                CALL FT.Coprocessor.Vertex2f
                FT_End

                LD   A, (PauseMenuChoice)
                OR   A
                JR   Z, .no_dim
                LD   C, 245 : LD D, 180 : LD E, 60
                JR   .no_color
.no_dim:        LD   C, 70 : LD D, 62 : LD E, 48
.no_color:      CALL FT.Coprocessor.ColorRGB
                LD   A, 220
                CALL PauseColorA
                FT_Begin FT_RECTS
                LD   BC, PAUSE_NO_X * 16
                LD   DE, PAUSE_BTN_Y * 16
                CALL FT.Coprocessor.Vertex2f
                LD   BC, (PAUSE_NO_X + PAUSE_BTN_W) * 16
                LD   DE, (PAUSE_BTN_Y + PAUSE_BTN_H) * 16
                CALL FT.Coprocessor.Vertex2f
                FT_End
                RET

PauseMenuChoice:   DEFB 1
PauseMenuFirePrev: DEFB 0
; Pause "No"/resume fade-out: VDC_DialogState=4 держит board frozen (not-Play:
; frog не стреляет, game time frozen), пока pause window гаснет за
; PAUSE_FADE_FRAMES ticks; затем → PLAY. VDC_PauseAlpha (255=opaque)
; масштабирует draw alpha всего окна во время fade.
PAUSE_FADE_FRAMES EQU 74        ; fixed 74-frame fade; ~1.25 s at current ~59 Hz video
PauseFadeTimer:    DEFB 0
VDC_PauseAlpha:    DEFB 255
str_pause_exit:    DB "REALLY WANT TO EXIT",0
str_yes:           DB "YES",0
str_no:            DB "NO",0

                include "loader_resident.asm"         ; resident части PAK loader (VDC_ReadSampleAtHL, cross-load vars, overlay trampolines)
                include "shared_render.asm"           ; DL-matrix + frog-render machinery для gameplay (#04) и level-select (#41); resident, без page-swap
                include "Input.asm"                   ; resident global input module (PS/2 keyboard via Mr.Gluk + Kempston + mouse); вызывается из любой scene
Main0_End:                                            ; MUST быть после ВСЕГО main0 code (Init_Core/Init_Int/INT_Handler/loader_resident/shared_render)
                ASSERT Core.Main0_End <= #8000

                ; ----- gameplay overlay (slot 3, page #04) — play-scene code -----
                ; Mapped в slot 3 только во время gameplay (ставится в FadeLevelSelectToGameplay).
                SLOT 3 : PAGE #04 : ORG #C000
Main1_Start:
                module AY_Game
                include "AYSfx.asm"
                endmodule
                include "top_mask_overlay_meta.inc"      ; runtime table, должна жить в mapped gameplay overlay
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"
                include "CacheBuilderFast.asm"        ; быстрый сборщик кеша стабильной цепочки L19

; Чтение упакованного Track V4. Контракт: PAGE3=#04; все штатные вызовы
; входят сюда из игровой накладки. Старое имя сохранено для постоянного ABI и тестов.
VDC_ReadRenderSampleAtHL_Main1:
VDC_ReadRenderSampleAtHL_Slot0:
                PUSH HL
                LD   A, H
                RRCA
                RRCA
                RRCA
                AND  #03                               ; индекс страницы = t >> 11
                LD   E, A
                LD   A, (VDC_RenderTrackPageIdx)
                CP   E
                JR   Z, .page_ready
                LD   A, E
                LD   (VDC_RenderTrackPageIdx), A
                LD   D, 0
                LD   HL, (VDC_pTrackPages)
                ADD  HL, DE
                LD   A, (HL)
                SetPage2_A
.page_ready:   POP  HL
                LD   A, H
                AND  #07
                LD   H, A                              ; местный номер образца = t & #07FF
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL                            ; местный номер * 8
                SET  7, H                              ; #8000 + местный номер * 8
                ; Track V4 +0..3 = VERTEX2F в порядке от младшего байта. Восстановить точные
                ; 16-разрядные Vx/Vy со знаком; их биты 15 хранятся в битах 7/6 поля +7.
                LD   E, (HL) : INC HL                  ; q0 = младший байт Vy
                LD   D, (HL) : INC HL                  ; q1: бит 0 Vx | биты 8..14 Vy
                LD   C, (HL) : INC HL                  ; q2 = биты 1..8 Vx
                LD   B, (HL) : INC HL                  ; q3 = код команды | биты 9..14 Vx
                LD   A, D
                SLA  D                                 ; CF=бит 0 Vx
                RL   C                                 ; C=младшая часть Vx, CF=бит 8 Vx
                RL   B                                 ; B=сдвинутый код команды | старшая часть Vx
                RES  7, B                              ; убрать сдвинутый бит 6 кода команды
                LD   D, A
                RES  7, D                              ; D=старшая часть Vy без исходного бита 15
                LD   A, (HL)
                INC  HL                                ; касательная уже запечена в кеше отрисовки; побочная запись больше не нужна
                LD   A, (HL)
                LD   (VDC_LastTrackFlags), A
                INC  HL                                ; +6 spin12
                INC  HL                                ; +7 метаданные
                LD   A, (HL)
                LD   L, A
                AND  #80                               ; исходный бит 15 Vx
                OR   B
                LD   B, A
                LD   A, L
                ADD  A, A                              ; бит 6 метаданных Vy -> бит 7
                AND  #80
                OR   D
                LD   D, A
                AND  A
                RET
Main1_End:

                ; ----- UI overlay (slot 3, page UI_OVL_PAGE) — menu/level-select +
                ; one-shot video init. Mapped в slot 3 для menu, level-select и boot
                ; (Init_Video). Делит окно #C000 с gameplay overlay (другая page),
                ; никогда не co-resident. Resident Fade* transitions свопают page
                ; в slot 3 перед JP в scene.
                SLOT 3 : PAGE UI_OVL_PAGE : ORG #C000
UiOvl_Start:
                module AY_UI
                include "AYSfx.asm"
                endmodule
                include "Init_Video.asm"
                include "MenuMain.asm"
                include "MoreGamesSlot0.asm"
                include "LevelSelect.asm"
UiOvl_End:

                ; ----- loader overlay (slot 3, page LOADER_OVL_PAGE) — RawPak FAT
                ; loader, mapped в slot 3 только во время level/preview load.
                ; Делит окно #C000 с другими overlays (другая page), никогда не
                ; co-resident. Вход через trampolines в loader_resident.asm.
                SLOT 3 : PAGE LOADER_OVL_PAGE : ORG #C000
LoaderOvl_Start:
                include "ts-dos.asm"
LoaderOvl_End:

                ; ----- level48 glyph metadata (slot 2, page #23) -----
                ; DrawIntroText maps this page only while measuring/drawing "LEVEL N-M".
                SLOT 2 : PAGE FONT_LEVEL48_META_PAGE : ORG #8000
FontLevel48Meta_Start:
                include "font_level48_meta.inc"
FontLevel48Meta_End:
                endmodule

Main0_Size       EQU Core.Main0_End - Core.Start
Main1_Size       EQU Core.Main1_End - Core.Main1_Start
UiOvl_Size       EQU Core.UiOvl_End - Core.UiOvl_Start
LoaderOvl_Size   EQU Core.LoaderOvl_End - Core.LoaderOvl_Start
FontLevel48Meta_Size EQU Core.FontLevel48Meta_End - Core.FontLevel48Meta_Start
                ASSERT FontLevel48Meta_Size <= #4000
                display "Main0:    \t", /A, Core.Start,        " size=", /D, Main0_Size,     " bytes (slot 1 page 5)"
                display "Main1:    \t", /A, Core.Main1_Start,  " size=", /D, Main1_Size,     " bytes (slot 3 page #04, gameplay)"
                display "UiOvl:    \t", /A, Core.UiOvl_Start,  " size=", /D, UiOvl_Size,     " bytes (slot 3 page #41, ui)"
                display "LoaderOvl:\t", /A, Core.LoaderOvl_Start, " size=", /D, LoaderOvl_Size, " bytes (slot 3 page #40)"
                display "Level48M:\t", /A, Core.FontLevel48Meta_Start, " size=", /D, FontLevel48Meta_Size, " bytes (slot 2 page #23)"
                ; main1_play (#04), UI overlay (#41) и loader overlay (#40)
                ; собираются по logical #C000 на разных physical pages. Перед КАЖДЫМ
                ; SAVEBIN нужно мапить нужную page, иначе SAVEBIN выгрузит последнюю
                ; mapped page не в тот .bin и испортит артефакт.
                SLOT 1 : PAGE #05
                SAVEBIN "Build/Core.bin",        Core.Start,       Main0_Size
                SLOT 3 : PAGE #04
                SAVEBIN "Build/main1_play.bin",  Core.Main1_Start, Main1_Size
                SLOT 3 : PAGE UI_OVL_PAGE
                SAVEBIN "Build/ui_ovl.bin",      Core.UiOvl_Start, UiOvl_Size
                SLOT 3 : PAGE Core.LOADER_OVL_PAGE
                SAVEBIN "Build/loader_ovl.bin",  Core.LoaderOvl_Start, LoaderOvl_Size
                SLOT 2 : PAGE FONT_LEVEL48_META_PAGE
                SAVEBIN "Build/font_level48_meta.bin", Core.FontLevel48Meta_Start, FontLevel48Meta_Size

                END EntryPoint
