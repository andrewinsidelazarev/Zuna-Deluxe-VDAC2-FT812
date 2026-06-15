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

; ----------------------------------------------------------------------------
; FT command buffer: TSLib дефолтит на #C000 (slot 3). После main0/main1 split
; main1_play код живёт в slot 3 → буфер перекрывает код → corruption за кадр.
; Keep it in slot 1 RAM before EntryPoint; #6000 is code now.
; ----------------------------------------------------------------------------
                define CMD_ADDRESS_PTR #5010

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #5C00                        ; slot 1 (page 5), keep Core below #8000
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
BUILD_CANARY_ADDR   EQU #5020
BUILD_CANARY_LEN    EQU 33
; Boot canary: написан ПЕРВОЙ инструкцией Start (#5C00), ДО любого Init.
; Дамп различает: канарейка ОТСУТСТВУЕТ → WC ещё грузит SPG / не дошёл до Core;
; "BOOT" есть, но BUILD_CANARY (#5020) пуст → Core стартовал, но Init_Core завис.
BOOT_CANARY_ADDR    EQU #5044
EVT_SHOT_FIRED      EQU 1
EVT_BBOX_HIT        EQU 2
EVT_HEMI            EQU 3
EVT_INSERT          EQU 4
EVT_CASCADE_TRIGGER EQU 5
EVT_MATCH3          EQU 6

; --- Text atlases (nativealien48 ARGB4, red-yellow gradient). Объявлены здесь
; (ДО TSLib block) чтобы EQU были доступны во всех slot 0/1/3 функциях через
; sjasmplus forward-resolve. FT_RAM_G #0000..#10000 = 64K free area (раньше
; не использовалась, bg начинается с #010000). Размеры см. text_*.info.
FROG_ARGB4_ENABLED    EQU 1
BALLS_ARGB4_ENABLED   EQU 1                         ; canary: native ARGB4 balls, 16 spin phases, no palette indirection
; Slot-3 overlay pages (logical #C000, distinct physical pages, never co-resident).
; Defined here (global, before module Core) so the resident Fade* transitions and
; Init_Core can reference UI_OVL_PAGE without a forward ref. LOADER_OVL_PAGE lives
; in loader_resident.asm (only used inside module Core). #04 = gameplay overlay.
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

TEXT_SPIRALDOOM_H      EQU 36                            ; опорная высота строки для Y-раскладки интро (исторический ориентир)

; «LOADING LEVELS...» — пред-рендеренный баннер nativealien48 48px (тот же шрифт/
; градиент, что и LEVEL N-M). Экран загрузки показывается ДО загрузки глифовых
; атласов, поэтому строка запечена в одну картинку. RAM_G #084000 — свободная зона
; в профиле level-select (#082658..#098000), поэтому баннер ПЕРЕЖИВАЕТ медленный
; поиск PAK (грузится в неё ассетами меню перед показом — меню уже погашено).
                include "loading_text_meta.inc"            ; LOADING_TEXT_W / _H / _NUM_PAGES (только EQU)
                include "boot_loading_assets.inc"          ; boot-only ARGB4 loading screen assets
LOADING_TEXT_PAGE_BASE EQU #25                             ; SPG pages #25,#26 (свободны)
LOADING_TEXT_RAMG      EQU #084000
LOADING_TEXT_HANDLE    EQU 12

BOOT_LOADING_BG_RAMG     EQU #000000
BOOT_LOADING_BAR_RAMG    EQU #03C000
BOOT_TS_ANIM_RAMG        EQU #044000
BOOT_SFX_AUTHORS_RAMG    EQU #06C000
BOOT_LOADING_BG_HANDLE   EQU 14
BOOT_LOADING_BAR_HANDLE  EQU 15
BOOT_TS_ANIM_HANDLE      EQU 16
BOOT_LOADING_BG_ENABLED  EQU 1                         ; DXT-L4 boot background, raw pages (no ZX7)
BOOT_LOADING_BG_MASK_HANDLE EQU 17
BOOT_SFX_AUTHORS_HANDLE  EQU 18
BOOT_LOADING_BG_X        EQU 0
BOOT_LOADING_BG_Y        EQU 0
BOOT_LOADING_BAR_X       EQU 122
BOOT_LOADING_BAR_Y       EQU 356
BOOT_TS_ANIM_X           EQU 226
BOOT_TS_ANIM_Y           EQU 272
BOOT_TS_SHADOW_DX        EQU 4
BOOT_TS_SHADOW_DY        EQU 5
BOOT_TS_SHADOW_A         EQU 96

TEXT_GAMEOVER_HANDLE   EQU 10

; Sparkle/diamond — 24×24 ARGB4 для track-preview анимации в intro state.
SPARKLE_PAGE           EQU #24
SPARKLE_RAMG           EQU #00C000                       ; free area между spiraldoom и bg
SPARKLE_W              EQU 24
SPARKLE_H              EQU 24
SPARKLE_HANDLE         EQU 13
SPARKLE_COUNT          EQU 22                            ; sparkles вдоль track
SPARKLE_HALF           EQU 12                            ; для центрирования Vertex2f

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
LIFE_FROG_HANDLE     EQU 18

; --- Tunnel top-cover: 400x300 ARGB4 tiles generated from HD image-top PNGs.

; --- HUD top bar lives counter ---
;   life_frog 20×20 PALETTED4444 (raw upload, 400 bytes).
;   Shared HUD palette 512 bytes ARGB4 LE (room for future menu/progress sprites).
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
DIALOG_FRAME_RAMG       EQU #0AC000                        ; after Cancun8 font, before HUD area
DIALOG_FRAME_W          EQU 400
DIALOG_FRAME_H          EQU 327
DIALOG_FRAME_HANDLE     EQU 21
DIALOG_FRAME_X          EQU (640 - DIALOG_FRAME_W) / 2     ; 120
DIALOG_FRAME_Y          EQU 60
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

; --- Cancun8 small font (HD-ref button text style) ---
;   689×21 = 28938 байт raw, 2 ZX7 чанка, RAM_G #0A4000.
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
LIFE_SOCK_X          EQU 35
LIFE_SOCK_Y          EQU 4
LIFE_STEP            EQU 20                            ; step между жабами (= sprite width)
LIFE_MAX_DRAW        EQU 3                             ; clamp displayed count (sock 78px fits 3×20)
HUD_MENU_X           EQU 539                           ; measured on frame_top.png MENU socket
HUD_MENU_Y           EQU 3                             ; -1px to align with baked socket
HUD_MENU_HIT_X       EQU 532
HUD_MENU_HIT_Y       EQU 0
HUD_MENU_HIT_W       EQU 96
HUD_MENU_HIT_H       EQU 34
HUD_PROGRESS_X       EQU 407                           ; measured on frame_top.png right red gauge socket
HUD_PROGRESS_Y       EQU 1
; HUD_GAUGE_TARGET: оригинальный lvl1 = 3000 (юзер 2026-05-20 проверил в оригинале:
; «при 3000 очков прогресс-бар в первом уровне становится зеленым»).
; HD-ref levels.xml имеет 1000 для lvl11/lvl12, но это другая нумерация (lvl11 = level 1-1).
; Пока оставлено 1000 для удобства тестирования; TODO поднять до 3000 (синхронизировать
; и /125 → /375 в DrawHudProgress, или сделать generic Div16x16).
HUD_GAUGE_TARGET     EQU 1000

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

LogMatch3:                                             ; MATCH3: ctx=color, d1=lb|rb, d2=count|marker
                PUSH HL
                PUSH AF
                LD   A, EVT_MATCH3
                LD   (LOG_TMP_TYPE_ADDR), A
                LD   A, (Core.VDC_TmpMC_Color)
                LD   (LOG_TMP_CTX_ADDR), A
                LD   A, (Core.VDC_TmpML)
                LD   (LOG_TMP_DATA_ADDR), A             ; lb
                LD   A, (Core.VDC_TmpMR)
                LD   (LOG_TMP_DATA_ADDR+1), A           ; rb
                LD   A, (Core.VDC_TmpMCount)
                LD   (LOG_TMP_DATA_ADDR+2), A           ; count
                LD   A, (Core.VDC_TmpInsIdx)
                LD   (LOG_TMP_DATA_ADDR+3), A           ; TmpInsIdx (откуда был triggered)
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
KZ_SPR_W           EQU 88
KZ_SPR_H           EQU 88
KZ_SPR_HALF        EQU 44
FROG_DEFAULT_X     EQU 327
FROG_DEFAULT_Y     EQU 231

; Room transitions keep the old DL visible until it is fully covered by a
; black overlay. RAM_G can then be reloaded without exposing half-written art.
FadeMenuToLevelSelect:
                LD   HL, Core.MenuBuildFrame
                CALL FadeOutRoom
                ; First time only: the PAK sector map isn't built yet, so the
                ; upcoming asset load runs the (slow) recursive search. Show
                ; "LOADING LEVELS..." over the faded-out menu while it works.
                ; Later transitions reuse the cached map -> near-instant, no message.
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
                JP   MoreGames

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
                SetPage3 UI_OVL_PAGE                     ; slot 3 -> UI overlay FIRST: DrawBlackTransitionFrame
                                                         ; tail-jumps to MenuSwapFrame (lives on the UI page)
                LD   A, UI_OVL_PAGE : LD (CurrentCodePage), A   ; track scene page
                CALL DrawBlackTransitionFrame
                JP   Core.MenuMain

FadeInMenu:
                LD   HL, Core.MenuBuildFrame
                JP   FadeInRoom

FadeInLevelSelect:
                LD   HL, Core.LevelSelectBuildFrame
                JP   FadeInRoom

FadeInMoreGames:
                LD   HL, MoreGamesBuildFrame
                JP   FadeInRoom

FadeMoreGamesToMenu:
                LD   HL, MoreGamesBuildFrame
                CALL FadeOutRoom
                SetPage3 UI_OVL_PAGE                     ; ensure slot 3 -> UI overlay before MenuMain
                LD   A, UI_OVL_PAGE : LD (CurrentCodePage), A   ; track scene page
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
                RET

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

DrawBlackTransitionFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_Display
                FT_CMD_Count
                JP   Core.MenuSwapFrame

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
                LD   BC, 640 * 16
                LD   DE, 480 * 16
                CALL FT.Coprocessor.Vertex2f
                FT_End
                FT_RestoreContext
                RET

; Adventure state vars are allocated inside ZiFi.asm (Core module); aliases
; here so bare references in TSLib-region code (FadeIn/Out etc) still resolve.
ADVENTURE_LEVEL_COUNT EQU 22
FadeAlpha          EQU Core.FadeAlpha
CurrentDifficulty  EQU Core.CurrentDifficulty
CurrentLevel       EQU Core.CurrentLevel

                include "level_runtime_table.inc"

; Level-select thumbnails are SPG-resident zlib ARGB4 streams. Keep the
; destination away from FONT_NATIVE_RAMG because titles are drawn as live text.
LS_PREVIEW_BG_RAMG       EQU #0D4000
LS_PREVIEW_BG_X          EQU 177
LS_PREVIEW_BG_Y          EQU 240
LS_PREVIEW_BG_DRAW_W     EQU 306
LS_PREVIEW_BG_DRAW_H     EQU 196
LS_PREVIEW_BG_W          EQU 306
LS_PREVIEW_BG_H          EQU 196
LS_PREVIEW_BG_HANDLE     EQU 6

                include "level_select_preview_markers.inc"
                include "level_select_preview_spg.inc"
                include "MoreGamesSlot0.asm"

DrawLevelSelectPreview:
                FT_End
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle LS_PREVIEW_BG_HANDLE
                FT_BitmapSource LS_PREVIEW_BG_RAMG
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_BG_W * 2, LS_PREVIEW_BG_H
                FT_BitmapSize FT_NEAREST, FT_BORDER, FT_BORDER, LS_PREVIEW_BG_DRAW_W, LS_PREVIEW_BG_DRAW_H
                FT_Begin FT_BITMAPS
                FT_Vertex2ii LS_PREVIEW_BG_X, LS_PREVIEW_BG_Y, LS_PREVIEW_BG_HANDLE, 0
                FT_End
                CALL LevelSelectDrawPreviewMarkers
                JP   DrawLevelSelectTitle

DrawLevelSelectTitle:
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
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
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                LD   B, H
                LD   C, L
                LD   DE, 382 * 16
                LD   HL, (LevelTitlePtrTmp)
                JP   DrawString

DrawKillzoneDual:
                ; Draw every frame. With 400x300 PALETTED4444 bg the baked
                ; kill-zone area is visibly degraded, so the overlay must also
                ; cover idle KzFrame=1.
                CALL UpdateKillzoneDrawXY
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle 3
                FT_PaletteSource Core.KZ_PALETTE_RAMG
                FT_BitmapSource Core.KZ_RAMG_ADDR
                FT_BitmapLayout FT_PALETTED4444, KZ_SPR_W, KZ_SPR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, KZ_SPR_W, KZ_SPR_H
                ; FT.Coprocessor.Cell корраптит BC/DE → загружаем coords ПОСЛЕ Cell.
                ; top-left = (KZ_DEFAULT_X/Y - half) in 1/16 px.
                ; --- pass 1: hole (Cell 0) ---
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (KzDrawX16)
                LD   DE, (KzDrawY16)
                CALL FT.Coprocessor.Vertex2f
                ; --- pass 2: skull frame (Cell = VDC_KzFrame) ---
                LD   A, (Core.VDC_KzFrame)
                CALL FT.Coprocessor.Cell
                LD   BC, (KzDrawX16)
                LD   DE, (KzDrawY16)
                CALL FT.Coprocessor.Vertex2f

                LD   A, (Core.VDC_HasSecondChain)
                OR   A
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
                LD   (Core.VDC_HudPointerBlock), A      ; dialog consumes LMB for this frame
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
                ; --- Read mouse LMB state, detect falling edge (release = click) ---
                LD   A, Input.Mouse.SVK_LBUTTON
                CALL Input.Mouse.KeyState               ; Z=released, NZ=pressed
                LD   A, 0
                JR   Z, .udlg_lmb_set
                INC  A
.udlg_lmb_set:  LD   C, A                               ; C = current LMB (0/1)
                LD   A, (Core.VDC_PrevMouseL)
                LD   B, A                               ; B = previous LMB
                LD   A, C
                LD   (Core.VDC_PrevMouseL), A           ; save for next frame
                ; Falling edge: was pressed (B=1) AND now released (C=0) → CLICK
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
                LD   DE, DLG_OK_X + DIALOG_OK_W
                AND  A
                SBC  HL, DE
                RET  NC
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, DLG_OK_Y
                AND  A
                SBC  HL, DE
                RET  C
                LD   HL, (Input.Mouse.PositionY)
                LD   DE, DLG_OK_Y + DIALOG_OK_H
                AND  A
                SBC  HL, DE
                RET  NC

.udlg_action:   ; Mouse click in OK bounds OR Fire key pressed
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
                JP   RestartLevel

; --- LEVEL DONE fade-out: рампим FadeAlpha до чёрного, потом грузим след. уровень.
; Сцена (поле + диалог) + DrawFadeOverlay рисуются в ZL_DrawFrame каждый кадр.
.udlg_win_fade: LD   A, (FadeAlpha)
                CP   255
                JR   Z, .uwf_done                       ; полностью чёрный → advance
                ADD  A, Core.VDC_WIN_FADE_STEP
                JR   NC, .uwf_store
                LD   A, 255                             ; clamp до full black
.uwf_store:     LD   (FadeAlpha), A
                RET
.uwf_done:      XOR  A
                LD   (Core.VDC_DialogState), A
                JP   Core.LoadNextLevelWithLoading      ; black screen → LOADING LEVEL N-M... → load assets

DialogFirePrev: DEFB 0                                  ; SPACE/Fire debounce для dialog OK
DialogFrameLoaded: DEFB 0                               ; 1 если DIALOG_FRAME_RAMG сейчас содержит окно диалога

RestartLevel:
                XOR  A
                LD   (Core.VDC_DialogState), A          ; скрыть диалог
                ; Если lives=0 → reset до 3 (full restart)
                LD   A, (Core.VDC_Lives)
                OR   A
                JR   NZ, .rl_keep_lives
                LD   A, 3
                LD   (Core.VDC_Lives), A
                CALL Score_Reset                        ; full restart (жизни кончились) → счёт=0, NextLifeScore=50000
.rl_keep_lives:
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
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, DIALOG_FRAME_W, DIALOG_FRAME_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, DIALOG_FRAME_X * 16
                LD   DE, DIALOG_FRAME_Y * 16
                CALL FT.Coprocessor.Vertex2f

                ; --- Title + 5 stat lines (native font glyph blit) ---
                ; Pick title string по VDC_Lives, центруется DrawStringCentered.
                CALL DrawDialogContent
                RET

; ----------------------------------------------------------------------------
; DrawIntroText — нижний правый угол: LEVEL 1-1 (большой, 64 px via cmd_scale)
; + SPIRAL OF DOOM (36 px native). Используется когда VDC_GameState == INTRO.
; Layout (640×480 screen, 30 px margin от правой/нижней рамки):
;   LEVEL 1-1: X=452, Y=320 (158×64 displayed, BILINEAR scale ×16/9 from 89×36)
;   SPIRAL OF DOOM: X=418, Y=414 (192×36 native)
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; DrawPreviewSparkles — sparkle wave анимация по track (state=PREVIEW).
; Параметры:
;   N=20 sparkles, head_sample = elapsed * SPEED, trail spacing 60 samples
;   SPEED = 24, PREVIEW_TICKS = 120 → head_sample reaches NumSamples (~2774)
; Sparkle skipped если sample < 0 или sample >= NumSamples (head ещё не дошёл / уже прошёл).
; Tint: warm gold. Caller восстановит белый ColorRGB.
; TrackData в slot 2 page 6 (default mapping).
; ----------------------------------------------------------------------------
; Comet: 8 sparkles spaced 16 samples = ~128 samples trail (короткая «очередь»),
; head advances 30 samples/tick → ~92 ticks для прохода 2774 samples (вместо 120).
PREVIEW_SPARKLE_COUNT   EQU 8
PREVIEW_SPARKLE_SPEED   EQU 15
PREVIEW_SPARKLE_SPACING EQU 16

DrawPreviewSparkles:
                LD   C, 255 : LD D, 220 : LD E, 80
                CALL FT.Coprocessor.ColorRGB
                FT_BitmapHandle SPARKLE_HANDLE
                FT_BitmapSource SPARKLE_RAMG
                FT_BitmapLayout FT_ARGB4, SPARKLE_W * 2, SPARKLE_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, SPARKLE_W, SPARKLE_H
                XOR  A : CALL FT.Coprocessor.Cell

                ; head_sample = elapsed * PREVIEW_SPARKLE_SPEED
                ; where elapsed = PREVIEW_TICKS - VDC_PreviewTick
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
                LD   DE, (Core.TrackData)              ; word at #8000 = NumSamples
                AND  A
                SBC  HL, DE
                JR   NC, .dps_advance                  ; sample >= NumSamples
                ADD  HL, DE                            ; restore sample
                CALL Core.VDC_ReadSampleAtHL           ; BC=X, DE=Y for 6-byte/split tracks
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
; DrawFrameStrips — 4 PALETTED4444 strip'а вокруг прозрачного centra.
; Каждая strip имеет свой handle и BITMAP_SOURCE; общая FT_PaletteSource.
; Z-order: рисуется поверх playfield, под курсором. Native 640×480 (no scale).
; ----------------------------------------------------------------------------
DrawFrameStrips:
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource FRAME_PAL_RAMG
                ; --- TOP 640×44 at (0, 0) ---
                FT_BitmapHandle FRAME_TOP_HANDLE
                FT_BitmapSource FRAME_TOP_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_TOP_W, FRAME_TOP_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_TOP_W, FRAME_TOP_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, 0
                CALL FT.Coprocessor.Vertex2f
                ; --- BOTTOM 640×24 at (0, 480-24) ---
                FT_BitmapHandle FRAME_BOT_HANDLE
                FT_BitmapSource FRAME_BOT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_BOT_W, FRAME_BOT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_BOT_W, FRAME_BOT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, (480 - FRAME_BOT_H) * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- LEFT 24×412 at (0, 44) ---
                FT_BitmapHandle FRAME_LEFT_HANDLE
                FT_BitmapSource FRAME_LEFT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_LEFT_W, FRAME_LEFT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_LEFT_W, FRAME_LEFT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, 0
                LD   DE, FRAME_TOP_H * 16
                CALL FT.Coprocessor.Vertex2f
                ; --- RIGHT 24×412 at (640-24, 44) ---
                FT_BitmapHandle FRAME_RIGHT_HANDLE
                FT_BitmapSource FRAME_RIGHT_RAMG
                FT_BitmapLayout FT_PALETTED4444, FRAME_RIGHT_W, FRAME_RIGHT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FRAME_RIGHT_W, FRAME_RIGHT_H
                XOR  A : CALL FT.Coprocessor.Cell
                LD   BC, (640 - FRAME_RIGHT_W) * 16
                LD   DE, FRAME_TOP_H * 16
                JP   FT.Coprocessor.Vertex2f

; ----------------------------------------------------------------------------
; DrawLivesCounter — рендерит N жаб-иконок (20×20 PALETTED4444) в life sock
; верхней рамки.  N = min(VDC_Lives, LIFE_MAX_DRAW).  Per-frame call after
; DrawFrameStrips (поверх sock'а), но под cursor'ом.
; ----------------------------------------------------------------------------
DrawLivesCounter:
                LD   A, (Core.VDC_Lives)
                OR   A
                RET  Z                                  ; 0 жизней → ничего не рисуем
                CP   LIFE_MAX_DRAW + 1
                JR   C, .lc_count_ok
                LD   A, LIFE_MAX_DRAW                   ; clamp displayed count
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
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LIFE_FROG_W, LIFE_FROG_H
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
                ADD  HL, DE                             ; advance x на 20*16
                DJNZ .lc_loop
                RET

LifeDrawCnt:    DEFB 0                                  ; temp clamped lives count

; ----------------------------------------------------------------------------
; UpdateHudMenu — hover/press state for top-right MENU button.
; Also raises VDC_HudPointerBlock while pointer is over the button, so the frog
; does not fire when the player clicks the HUD.
; ----------------------------------------------------------------------------
UpdateHudMenu:
                JP   Core.UpdateHudMenuCore

; ----------------------------------------------------------------------------
; DrawHudProgress — original Zuma bar sprites in top HUD.
; Baked red socket is empty. Yellow fills by score; green means gauge full.
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
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, HUD_PROGRESS_W, HUD_PROGRESS_H
                LD   A, (Core.VDC_GaugeFull)
                OR   A
                JR   Z, .dhp_yellow
                FT_ScissorXY HUD_PROGRESS_X, HUD_PROGRESS_Y
                FT_ScissorSize HUD_PROGRESS_W, HUD_PROGRESS_H
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
                LD   A, HUD_PROGRESS_W                  ; 63
                CALL Core.VDC_DivHLbyA                  ; HL = target / 63 = d
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
                JR   NZ, .dhp_clampmax                  ; quotient > 255 → clamp
                LD   A, L
                OR   A
                JR   NZ, .dhp_clamp_check
                INC  A                                  ; min visible 1 px если score>0
.dhp_clamp_check:
                CP   HUD_PROGRESS_W
                JR   C, .dhp_have_width_a
.dhp_clampmax:  LD   A, HUD_PROGRESS_W
.dhp_have_width_a:
                LD   (DhpFillPx), A                     ; B/BC клобается FT_ScissorXY ниже,
                                                        ; поэтому fill_px храним в памяти
.dhp_have_width:
                FT_ScissorXY HUD_PROGRESS_X, HUD_PROGRESS_Y
                LD   A, (DhpFillPx)                     ; restore fill_px после FT_ScissorXY
                CALL EmitScissorSizeAProgress
                LD   A, 1                               ; yellow fill
.dhp_draw:
                CALL FT.Coprocessor.Cell
                LD   BC, HUD_PROGRESS_X * 16
                LD   DE, HUD_PROGRESS_Y * 16
                CALL FT.Coprocessor.Vertex2f
                FT_ScissorXY 0, 0
                FT_ScissorSize 640, 480
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
                LD   E, HUD_PROGRESS_H
                LD   A, L
                SRL  A
                SRL  A
                SRL  A
                SRL  A
                LD   C, A
                LD   B, #1C
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; DrawHudMenu — top-right MENU button, cells: 1=hover/2=pressed.
; Idle state (=0) уже baked в frame_top.png — не рисуем чтобы не тратить
; FT812 pixel-clock + DL bytes впустую.
; ----------------------------------------------------------------------------
DrawHudMenu:
                LD   A, (Core.VDC_HudMenuState)
                OR   A
                RET  Z                                  ; idle — baked, skip draw
                LD   C, 255 : LD D, 255 : LD E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_PaletteSource HUD_PALETTE_RAMG
                FT_Begin FT_BITMAPS
                FT_BitmapHandle 20
                FT_BitmapSource HUD_MENU_RAMG
                FT_BitmapLayout FT_PALETTED4444, HUD_MENU_W, HUD_MENU_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, HUD_MENU_W, HUD_MENU_H
                LD   A, (Core.VDC_HudMenuState)
                CALL FT.Coprocessor.Cell
                LD   BC, HUD_MENU_X * 16
                LD   DE, HUD_MENU_Y * 16
                JP   FT.Coprocessor.Vertex2f

DrawIntroText:
                ; --- Fade-out alpha: VDC_IntroTick 240→0; last 60 ticks fade ---
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

                ; --- Build "LEVEL N-M" dynamically (N=CurrentLevel+1, M=CurrentDifficulty+1).
                ; Заменяет запечённую "LEVEL 1-1": теперь реальный номер уровня/сложности. ---
                LD   HL, .dit_level_prefix             ; "LEVEL "
                LD   DE, IntroLevelBuf
                LD   BC, 6
                LDIR                                    ; copy "LEVEL " → DE past it
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
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix              ; identity (без масштабирования)
                LD   A, 1
                LD   (DrawStr_Scale), A
                FT_Begin FT_BITMAPS
                LD   HL, IntroLevelBuf
                CALL StrWidth                            ; DE = native-48 width
                LD   HL, 610
                AND  A
                SBC  HL, DE                              ; x = 610 - width
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, (480 - TEXT_SPIRALDOOM_H - 90) * 16   ; над названием уровня
                LD   HL, IntroLevelBuf
                CALL DrawString

                ; --- Selected level title (30px nativealien, строка ниже) ---
                CALL SetFontNative
                CALL Core.GetCurrentLevelTitlePtr
                LD   (LevelTitlePtrTmp), HL
                CALL StrWidth
                LD   HL, 610
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, (480 - TEXT_SPIRALDOOM_H - 30) * 16
                LD   HL, (LevelTitlePtrTmp)
                JP   DrawString
.dit_level_prefix: DB "LEVEL "

; ============================================================================
; DrawDialogContent — title + 5 stat lines, glyph blit using nativealien font.
; ============================================================================
DLG_TITLE_Y     EQU 160                                 ; внутри felt'а (frame top=60, skull+border=80→140)
DLG_STATS_Y    EQU 208
DLG_STATS_X_L  EQU 165                                 ; левая колонка X (внутри felt'а)
DLG_STATS_X_R  EQU 356                                 ; правая колонка X (-3 cancun10 chars)
DLG_LINE_H     EQU 18                                  ; spacing между строками (native cancun10 11px tall)
DLG_OK_X       EQU 170
DLG_OK_Y       EQU 315                                  ; moved up 20px — felt area кончается ~Y=360, OK теперь 315..349
DLG_OK_W       EQU DIALOG_OK_W
DLG_OK_H       EQU DIALOG_OK_H
PAUSE_TITLE_CENTER_X EQU 320
PAUSE_TITLE_Y   EQU 154
PAUSE_YES_X    EQU 220
PAUSE_NO_X     EQU 336
PAUSE_BTN_Y    EQU 302
PAUSE_BTN_W    EQU 84
PAUSE_BTN_H    EQU 38
PAUSE_YES_TEXT_X EQU 246
PAUSE_NO_TEXT_X  EQU 364
PAUSE_BTN_TEXT_Y EQU 306

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
                ; Центруем по ширине — вычислим width строки сначала
                CALL StrWidth                            ; HL ptr → DE width
                LD   HL, 320
                AND  A
                SBC  HL, DE                              ; HL = 320 - W/2 ? нет, надо /2
                ; Actually: x = 320 - W/2. Compute via SRL on DE first.
                LD   A, D : SRL A : LD D, A
                LD   A, E : RRA : LD E, A                ; DE = W/2
                LD   HL, 320
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

.dc_stats:      ; --- Stats use a separate cancun10 atlas. Do not touch the
                ; pixel-tuned cancun8 menu/HUD font. (Win-диалог прыгает сюда после
                ; своего заголовка — те же статы, что в Game Over.)
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
                CALL DrawScore24                       ; 24-bit cumulative score (was 16-bit DrawWordValue)

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
                CALL StrWidth                            ; DE = width
                LD   A, D : SRL A : LD D, A
                LD   A, E : RRA : LD E, A                ; DE = W/2
                LD   HL, 320
                AND  A
                SBC  HL, DE                              ; x = 320 - W/2
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
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, DIALOG_OK_W, DIALOG_OK_H
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
                ; Таблицы глифов и W/H/STRIDE-EQU лежат в overlay #04 (внутри module
                ; Core) → ссылаемся с префиксом Core. (RAMG/HANDLE — глобальные, без него).
                ; Читаются только при slot3=#04 (интро), как и положено для #04-данных.
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
; DrawString — glyph-blit zero-terminated string в TEKUЩЕМ шрифте.
;   In:  HL = string ptr, BC = start x*16, DE = y*16. Font state из FontPtr*.
;   Out: (DrawStr_CurX) = end x*16
;   Clobbers all.
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
                JR   NC, .ds_loop                       ; non-ASCII skip

                ; --- Lookup glyph metadata: BC = char index (0..127) ---
                LD   C, A
                LD   B, 0

                ; advance := (FontPtrAdvance)[A]
                LD   HL, (FontPtrAdvance)
                ADD  HL, BC
                LD   A, (HL)
                OR   A
                JR   Z, .ds_loop                        ; advance=0 → неизвестный char, skip
                LD   (DrawStr_Adv), A

                ; glyph_w := (FontPtrGlyphW)[A]
                LD   HL, (FontPtrGlyphW)
                ADD  HL, BC
                LD   A, (HL)
                OR   A
                JR   Z, .ds_advance_only                ; w=0 (space) → только advance

                ; --- Emit BITMAP_SIZE (NEAREST/BORDER, w*scale, FontHeight*scale) ---
                LD   H, 0
                LD   L, A                               ; HL = w
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_sz_w1
                ADD  HL, HL                             ; w *= 2 (scale=2)
.ds_sz_w1:      ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<3
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<6
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; <<9 (w << 9)
                LD   A, (FontHeight)
                LD   B, A
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_sz_h1
                SLA  B                                  ; FontHeight *= 2 (scale=2)
.ds_sz_h1:      LD   E, B : LD D, 0
                ADD  HL, DE                             ; HL = (w<<9)|H
                LD   B, #08
                LD   C, 0
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                ; --- Emit BITMAP_SOURCE = atlas_base + glyph_x * 2 ---
                LD   HL, (DrawStr_Ptr)
                DEC  HL                                  ; back to current char
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
                ; CurX += advance * scale * 16
                LD   A, (DrawStr_Adv)
                LD   H, 0 : LD L, A
                LD   A, (DrawStr_Scale)
                CP   2
                JR   C, .ds_adv1
                ADD  HL, HL                             ; advance *= 2 (scale=2)
.ds_adv1:       ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL   ; *16
                LD   DE, (DrawStr_CurX)
                ADD  HL, DE
                LD   (DrawStr_CurX), HL
                JP   .ds_loop

DrawStr_Ptr:    DEFW 0
DrawStr_CurX:   DEFW 0
DrawStr_Y:      DEFW 0
DrawStr_Adv:    DEFB 0
DrawStr_Scale:  DEFB 1                                  ; 1 = native, 2 = ×2 (caller сам ставит scale-матрицу)

; ============================================================================
; DrawHudTopText — верхний HUD: clock + cumulative score.
; ============================================================================
DrawHudTopText:
                CALL SetFontCancun8
                LD   C, 255 : LD D, 242 : LD E, 168
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                FT_Begin FT_BITMAPS

                ; Left red socket: centered game clock HH:MM:SS.
                ;   Sock interior x=169..229 (cx=199, w=61), y=2..18 (h=17).
                ;   Cancun8 inked rows y=6..16 — при Y=0 центрируется в соке.
                CALL FormatHudClock
                LD   HL, DrawNumBuf
                CALL StrWidth
                LD   HL, 194                            ; center of left red socket (shifted -5)
                LD   A, E
                SRL  A                                  ; half width
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, 1 * 16                         ; Y=1 (shifted +1 down)
                LD   HL, DrawNumBuf
                CALL DrawString

                ; Black score socket: label pinned left, number pinned right.
                ;   Sock interior x=273..367 (w=95). Padding 2px each side.
                LD   HL, str_hud_score
                LD   BC, 271 * 16                       ; SCORE label pinned left (shifted -4)
                LD   DE, 1 * 16                         ; Y=1 (shifted +1 down)
                CALL DrawString

                CALL FormatScore24ToBuf                 ; 24-bit cumulative score -> DrawNumBuf (was 16-bit)
                LD   HL, DrawNumBuf
                CALL StrWidth
                LD   HL, 361                            ; number right edge (shifted -4)
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, 1 * 16                         ; Y=1 (shifted +1 down)
                LD   HL, DrawNumBuf
                CALL DrawString

                LD   C, 255 : LD D, 255 : LD E, 255
                JP   FT.Coprocessor.ColorRGB

; ============================================================================
; StrWidth — посчитать ширину строки в пикселях (sum of advances).
;   In:  HL = string ptr (zero-terminated)
;   Out: DE = width (pixels)
;   Clobbers AF, BC, HL.
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
;   Clobbers all.
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
                ; Strip leading zeros (replace with space which has w=0)
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
; 24-bit cumulative score (Core.VDC_PlayerScore, 3-byte LE) + 50000 extra-life.
; Resident (slot 0), so callable from gameplay (#04) and resident win/HUD code.
; ----------------------------------------------------------------------------
; Score_Add24 — VDC_PlayerScore += HL (16-bit delta), then award extra lives.
;   In: HL = points to add. Clobbers AF, DE, HL (NOT BC).
; ----------------------------------------------------------------------------
Score_Add24:
                LD   DE, (Core.VDC_PlayerScore)        ; DE = low 16 bits
                ADD  HL, DE                            ; CF = carry out of low 16
                LD   (Core.VDC_PlayerScore), HL        ; store low 16 (LD keeps CF)
                LD   A, (Core.VDC_PlayerScore + 2)
                ADC  A, 0                              ; += carry into byte 2
                LD   (Core.VDC_PlayerScore + 2), A
                ; fall through to extra-life check
; ----------------------------------------------------------------------------
; Score_CheckExtraLife — while score >= NextLifeScore: VDC_Lives++, threshold += 50000.
; ----------------------------------------------------------------------------
Score_CheckExtraLife:
.cel_loop:      LD   HL, (Core.VDC_PlayerScore)        ; low 16 of score
                LD   DE, (Core.NextLifeScore)
                AND  A
                SBC  HL, DE                            ; CF = borrow (low 16)
                LD   A, (Core.VDC_PlayerScore + 2)
                LD   HL, Core.NextLifeScore + 2
                SBC  A, (HL)                           ; full 24-bit borrow in CF
                RET  C                                 ; score < threshold -> done
                LD   A, (Core.VDC_Lives)
                INC  A
                LD   (Core.VDC_Lives), A
                LD   A, Core.SND_EXTRALIFE
                CALL Core.GS_PlaySfx
                LD   HL, (Core.NextLifeScore)
                LD   DE, 50000
                ADD  HL, DE
                LD   (Core.NextLifeScore), HL
                LD   A, (Core.NextLifeScore + 2)
                ADC  A, 0
                LD   (Core.NextLifeScore + 2), A
                JR   .cel_loop
; ----------------------------------------------------------------------------
; Score_Reset — score = 0, NextLifeScore = 50000 (new run / full restart).
; ----------------------------------------------------------------------------
Score_Reset:
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
; FormatScore24ToBuf — DrawNumBuf = decimal of VDC_PlayerScore (up to 8 digits,
; leading zeros blanked to spaces, which render at zero width). Clobbers all.
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
                ; blank leading zeros (all but the last digit) -> space (zero width)
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
; DrawScore24 — format + draw VDC_PlayerScore at DrawStr_CurX / DrawStr_Y.
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
; FormatHudClock — DrawNumBuf = "HH:MM:SS" from RTC-based VDC_GameSeconds.
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
;   Раньше делили StatTimeFrames/60, но при 74Hz видеорежиме это давало
;   неверное время. Теперь берём VDC_GameSeconds (уже в секундах).
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
                ; BC = minutes, HL_low = seconds. Format "M:SS"
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
                ; font_level48_meta.inc — НЕ здесь: slot0 (#0000..#3FFF) почти полон, его
                ; таблицы глифов (~512 б) переполняли бы секцию за #4000 → порча slot1.
                ; Вынесены в overlay #04 (см. ниже, после MainLoop.asm) — level48 нужен
                ; только в интро при slot3=#04.
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
                LD   A, 1                       ; SHOW_RETRY (есть ещё жизни)
                JR   .ua_set_dlg
.ua_set_final:  LD   A, 2                       ; GAME_OVER_FINAL (lives=0)
.ua_set_dlg:    LD   (Core.VDC_DialogState), A
                XOR  A
                LD   (Core.VDC_PrevMouseL), A           ; sentinel: ждать пока пользователь
                                                        ; нажмёт+отпустит mouse (avoid auto-restart)
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
                LD   D, 0                              ; D = mask (bits 0..VDC_NUM_COLORS-1 = colors present)
                LD   A, (Core.VDC_SlotsLen)
                OR   A
                JP   Z, .frc_fb_in                     ; empty chain → fallback (JP — JR диапазон превысился после exclude block)
                LD   C, A
                LD   HL, (Core.VDC_pSlots)
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
                JR   NC, .r8_no_xor
                LD   D, #B4 : LD E, 0
                LD   A, H : XOR D : LD H, A
                LD   A, L : XOR E : LD L, A
.r8_no_xor:
                LD   (Core.VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; 8-bit uniform
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
; In:  A = compressed source SPG page; Core.BgRamH/L = FT_RAM_G dest 24-bit
; Out: Core.BgRamH/L advanced by 16K
; Slots after RET: slot 2 = src (not restored), slot 3 = current scene overlay
; (Core.CurrentCodePage). Restoring slot 3 here keeps dumps and any call-side code
; from observing the transient scratch page between compressed uploads.
; ----------------------------------------------------------------------------
; CurrentCodePage tracks which scene overlay is mapped in slot 3: #41 (UI =
; menu/level-select) or #04 (gameplay). The shared slot0 decompressors below use
; slot 3 as decomp scratch, then restore it to THIS page (not a hard-coded #04),
; so they are correct from any scene. Maintained by the resident Fade* transitions;
; boot default = UI overlay (first scene is the menu). Resident (slot 0/TSLib region).
CurrentCodePage:  DB UI_OVL_PAGE
UnpackAndUploadPage:
                DI
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

                ; Advance Core.BgRamL/H by 16K
                LD   HL, (Core.BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (Core.BgRamL), HL
                JR   NC, .uaup_no_carry
                LD   A, (Core.BgRamH) : INC A : LD (Core.BgRamH), A
.uaup_no_carry:
                LD   A, (CurrentCodePage) : LD BC, PAGE3 : OUT (C), A   ; restore slot 3 = current scene overlay (#41 ui / #04 gameplay)
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
; slot 2 → page 6 (TrackData), slot 3 → page #04 (main1_play).
; Stack пересажен на uzx7_temp_stack чтобы LDIR в slot 3 не зацепил наш стек.
; ----------------------------------------------------------------------------
UnpackZX7Page:
                DI
                LD   (.uzx7_src), A
                LD   A, B  : LD (.uzx7_dst), A
                LD   (.uzx7_saved_sp), SP
                LD   SP, .uzx7_temp_stack_top
                LD   A, (.uzx7_src) : LD BC, PAGE2 : OUT (C), A
                LD   A, (.uzx7_dst) : LD BC, PAGE3 : OUT (C), A
                LD   HL, #8000
                LD   DE, #C000
                CALL Dzx7Turbo
                LD   A, 6   : LD BC, PAGE2 : OUT (C), A   ; restore slot 2 = TrackData page
                LD   A, (CurrentCodePage) : LD BC, PAGE3 : OUT (C), A   ; restore slot 3 = current scene overlay (#41 ui / #04 gameplay)
                LD   SP, (.uzx7_saved_sp)
                EI
                RET
.uzx7_src:        DB 0
.uzx7_dst:        DB 0
.uzx7_saved_sp:   DW 0
.uzx7_temp_stack: DEFS 64
.uzx7_temp_stack_top:

; ----------------------------------------------------------------------------
; SafeInflatePage2: FT812 CMD_INFLATE with compressed source mapped in PAGE2.
;
; TSLib FT.Coprocessor.Inflate maps source pages into PAGE3/#C000, which is also
; our main1_play code slot. Fresh host dumps showed CPU HALT while PAGE3 was a
; zlib preview page (#F1). This variant keeps PAGE3 untouched and streams the
; source from PAGE2/#8000 instead.
;
; In: same convention as FT.Coprocessor.Inflate for current callers:
;   A:DE = RAM_G destination, BC = compressed byte count, HL = source offset,
;   A' = source SPG page. Current assets are all <64K compressed.
; Out: CF set only if coprocessor write reports fault.
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
                RET  C

                GetPage2
                LD   (.sip2_saved_page2), A
                POP  HL

                ; Move source address from page-local #0000..#3FFF into slot2
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
.sip2_saved_page2: DB 0
.sip2_src_page:    DB 0

                include "LevelSelectPreviewSlot0.asm"

LOG_BLOCK_END:
                ; slot0-регион (#0000..#3FFF, всегда замаплен) ОБЯЗАН закончиться до
                ; #4000 — иначе хвост налезает на область slot1 (Core) в рантайме →
                ; тихая порча/зависание (sjasmplus сам на это НЕ ругается). Ловим тут.
                ; Если упало: вынеси крупные таблицы/данные в overlay (#04/#41), как
                ; сделано с font_level48_meta.inc.
                ASSERT LOG_BLOCK_END <= #4000

TSLIB_TOTAL_SIZE EQU LOG_BLOCK_END - TSLIB_Start
                display "Log:      \t", /A, Log_Init, " end=", /A, LOG_BLOCK_END
                SAVEBIN "Build/TSLib.bin", TSLIB_Start, TSLIB_TOTAL_SIZE

; --- Core block (page 5) -------------------------------------------------
                ORG EntryPoint
                module Core
Start:
                ; ----- EntryPoint -----
                LD   SP, StackTop
                ; ----- BOOT CANARY -----
                ; Доказывает, что WC SPG-loader долистал до Core EntryPoint и
                ; передал управление НАМ — до любого Init. Пишем "BOOT" в
                ; резидентный RAM (#5044), не трогая стек/страницы. См. дамп 111:
                ; если этой метки нет в F2-дампе — hang в фазе загрузки WC.
                LD   HL, #4F42                          ; 'B','O' (LE → #42 #4F)
                LD   (BOOT_CANARY_ADDR), HL
                LD   HL, #544F                          ; 'O','T' (LE → #4F #54)
                LD   (BOOT_CANARY_ADDR + 2), HL
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
                CALL Init_Video                       ; FT_BOOT_UP + 640×480 + FT_INT_SWAP enable
                CALL Input.Mouse.Initialize           ; курсор в центр (W/2, H/2)
                CALL Input_Init                       ; взвести расширенную PC-клавиатуру (Mr.Gluk PS/2)
                ; Init завершён — отключаем TS-Conf frame INT 50 Hz, чтобы он не бился
                ; с FT812 vsync 57.25 Hz. Синхронизация в MainLoop через FT_INT_SWAP.
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
                CALL LoadGameplayLevelSpecificFromPack
                JR   C, .LevelSpecificLoaded

                ; Залить bg_level01 400x300 PALETTED4444 (8 страниц #07..#0E)
                ; в RAM_G #010000, затем 512-байтную ARGB4 palette.
                CALL GetCurrentBgFirstPage
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
                CALL GetCurrentBgPalettePage
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (BG_PALETTE_RAMG >> 16) & 0xFF
                LD   DE, BG_PALETTE_RAMG & 0xFFFF
                CALL FT.WriteMem

.LevelSpecificLoaded:
                ; Залить balls_atlas PALETTED4444.
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

                ; Palette ARGB4 СТРОГО 512 байт → FT_RAM_G #080000 (PALETTED4444).
                ; Размер ровно 512: FT812 при больших значениях считывает мусор за
                ; концом палитры; при меньшем зависает (out-of-range index).
                if !BALLS_ARGB4_ENABLED
                LD   A, BALLS_PALETTE_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512                          ; ARGB4 = 256 × 2 bytes
                LD   A, (BALLS_PALETTE_RAMG >> 16) & 0xFF
                LD   DE, BALLS_PALETTE_RAMG & 0xFFFF
                CALL FT.WriteMem
                endif

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

                ; Залить cursor (page #5A, compressed ZX7) в RAM_G CURSOR_RAMG_ADDR.
                ; UnpackAndUploadPage заливает 16K — последние ~15K = zeros (padding),
                ; не страшно потому что #0D0000+1152..#0D4000 пустая зона
                ; (killzone начинается с #0D4000 и уже залит).
                LD   HL, CURSOR_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   A, CURSOR_PAGE
                CALL UnpackAndUploadPage

                ; Залить text atlases (GAME OVER + LEVEL 1-1 + SPIRAL OF DOOM)
                ; в FT_RAM_G #0..#10000 (свободная зона до bg).
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
                ; LOADING_TEXT_RAMG == FRAME_TOP_RAMG. Перед перезаписью #084000
                ; убрать с экрана DL, который читает loading bitmap, иначе буквы
                ; в конце загрузки затираются frame/level данными прямо на экране.
                CALL DrawBlackLoadingFrame

                ; Palette 512 байт raw → FRAME_PAL_RAMG.
                LD   A, FRAME_PAL_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (FRAME_PAL_RAMG >> 16) & 0xFF
                LD   DE, FRAME_PAL_RAMG & 0xFFFF
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

                ; --- Cancun8 font atlas: 2 ZX7 chunks → #0A4000..#0AC000 ---
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
                ; slot 2 = selected TrackData, slot 3 = main1_play (page #04).
                CALL GS_StopMenuMusic
                CALL GS_LoadGameplaySoundsMaybeQuiet
                CALL SetCurrentTrackPage
                SetPage3 #04

                ; --- VDC physics init (TrackData уже доступен в slot 2) ---
                CALL VDC_Init
                CALL Frog_Init
                CALL Bullet_Init
                CALL Log_Init                          ; circular RAM log для F12-dump
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
                CALL GetCurrentTrackPage
                LD   (VDC_ActiveTrackPage1), A
                LD   A, TRACK_PAGE2
                LD   (VDC_ActiveTrackPage2), A
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A
                RET

SetSecondTrackPage:
                LD   A, TRACK_PAGE2
                LD   (VDC_ActiveTrackPage1), A
                LD   (VDC_ActiveTrackPage2), A
                SetPage2_A
                RET

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
                CALL GetCurrentLevelRecord
                LD   DE, LEVEL_RT_TIER1
                ADD  HL, DE
                LD   A, (CurrentDifficulty)
                CP   4
                JR   C, .diff_ok
                XOR  A
.diff_ok:       LD   E, A
                LD   D, 0
                ADD  HL, DE
                LD   A, (HL)
                CP   #FF
                RET  NZ
                XOR  A                                  ; fallback to lvl11 setting if tier is absent
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
                ; Двойная цепочка: счёт сыплется в ОБЩИЙ gauge с обеих цепочек,
                ; а таблица даёт таргет на одну → удваиваем, иначе gauge полнится
                ; вдвое быстрее, спавн вырубается рано и отстающая цепочка мёрзнет
                ; короткой. Одиночные уровни: HasSecondChain=0 → RET Z (без изменений).
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                EX   DE, HL
                ADD  HL, HL                            ; таргет×2
                EX   DE, HL                            ; DE = таргет×2 (HL сохранён)
                RET

; GetCurrentColors — ball-color count for the current level/difficulty (settings
; field colors, offset +4). Clamped to 1..VDC_NUM_COLORS; 0/absent → VDC_NUM_COLORS.
GetCurrentColors:
                CALL GetCurrentLevelSettingRecord
                LD   DE, 4
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .gcc_def                        ; 0 / absent → default
                CP   Core.VDC_NUM_COLORS + 1
                RET  C                                  ; 1..NUM_COLORS → ok
.gcc_def:       LD   A, Core.VDC_NUM_COLORS
                RET

; GetCurrentSpeed — chain speed_x100 (settings +0). 0/absent → 50. Out: A.
GetCurrentSpeed:
                CALL GetCurrentLevelSettingRecord
                LD   A, (HL)
                OR   A
                RET  NZ
                LD   A, 50
                RET

; GetCurrentStart — lead-in ball count (settings +1). 0/absent → 35. Out: A.
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
; VDC_Init в Main1, который почти полон). Clobbers AF, HL, DE.
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

; VDC_SpeedAdvance — normal-phase chain advance at per-level speed. accum +=
; speed_x100; когда ≥100 → один VDC_MoveChain (speed/100 продвижений/кадр).
; Core-resident (Main1 почти полон). Clobbers AF, HL.
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

VDC_CheckWinMaybe:
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ                                  ; trigger win only from PLAY; do not re-arm WIN every frame
                LD   A, (VDC_GaugeFull)
                OR   A
                RET  Z
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  NZ
                LD   A, (VDC_HasSecondChain)
                OR   A
                JR   Z, .win_all_clear
                LD   A, (VDC2_SlotsLen)
                OR   A
                RET  NZ
.win_all_clear:
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
                LD   A, DLG_WIN_DONE
                LD   (VDC_DialogState), A
                XOR  A
                LD   (FadeAlpha), A
                RET

; --- VDC_WinOutroInit — на входе в WIN: эмиттеры из head-сэмплов, пул пуст. ---
VDC_WinOutroInit:
                ; Дозалить атлас WIN-взрыва в регион шаров (#050000) — шаров на
                ; экране уже нет (SlotsLen==0, проверено в VDC_CheckWinMaybe), так
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
                LD   DE, (TrackData)
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
.es_done:       LD   HL, #FFFF
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
; Инкрементим уровень (с wrap) и проваливаемся в ЕДИНЫЙ вход геймплея —
; тот же код, что и заход из меню.
LoadNextLevelWithLoading:
                LD   A, (CurrentLevel)
                INC  A
                CP   LEVEL_RUNTIME_COUNT
                JR   C, .lnl_store
                XOR  A
.lnl_store:     LD   (CurrentLevel), A
                ; fall through → EnterGameplayForCurrentLevel

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
                XOR  A
                LD   (FadeAlpha), A                     ; сброс fade: иначе DrawFadeOverlay зальёт геймплей чёрным
                SetPage3 #04                            ; slot 3 → gameplay overlay ДО загрузки ассетов
                LD   A, #04                             ; (LoadGameplayAssets гоняет VDC_Init/Frog_Init/Bullet_Init на #04)
                LD   (CurrentCodePage), A               ; track scene page (shared-декомпрессоры восстанавливают сюда)
                CALL ShowCurrentLevelLoadingScreen
                CALL LoadGameplayAssets
                JP   MainLoop

ShowCurrentLevelLoadingScreen:
                CALL UploadLoadingText
                CALL DrawNextLevelLoadingScreen
                RET

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

DrawNextLevelLoadingScreen:
                CALL BuildLoadingLevelBuf
                CALL LoadingLevelTextWidth               ; DE = level number width
                LD   (LoadingLevelNumW), DE
                LD   HL, LOADING_TEXT_PREFIX_W + LOADING_TEXT_SUFFIX_W
                ADD  HL, DE                              ; total width
                LD   D, H : LD E, L
                SRL  D : RR E                            ; DE = total / 2
                LD   HL, 320
                AND  A
                SBC  HL, DE
                LD   (LoadingLevelX), HL

                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_CMD_BUF #04FFFFFF                    ; COLOR_RGB white, как в DrawLoadingScreen
                FT_Begin FT_BITMAPS

                ; Prefix: "LOADING LEVEL "
                FT_BitmapHandle LOADING_TEXT_HANDLE
                FT_BitmapSource LOADING_TEXT_RAMG
                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LOADING_TEXT_PREFIX_W, LOADING_TEXT_H
                LD   HL, (LoadingLevelX)
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, ((480 - LOADING_TEXT_H) / 2) * 16
                CALL FT.Coprocessor.Vertex2f

                ; Dynamic level number: "X-X" / "XX-X", тем же bitmap-slice
                ; способом, что и рабочий "LOADING LEVELS...".
                LD   HL, (LoadingLevelX)
                LD   DE, LOADING_TEXT_PREFIX_W
                ADD  HL, DE
                LD   (LoadingLevelCurX), HL
                LD   HL, LoadingLevelBuf
.dnl_num_loop:  LD   A, (HL)
                OR   A
                JR   Z, .dnl_num_done
                INC  HL
                PUSH HL
                CALL DrawLoadingLevelCharSlice
                POP  HL
                JR   .dnl_num_loop
.dnl_num_done:

                ; Suffix: "..."
                FT_BitmapHandle LOADING_TEXT_HANDLE
                FT_BitmapSource LOADING_TEXT_RAMG + (LOADING_TEXT_SUFFIX_X * 2)
                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, LOADING_TEXT_SUFFIX_W, LOADING_TEXT_H
                LD   HL, (LoadingLevelX)
                LD   DE, LOADING_TEXT_PREFIX_W
                ADD  HL, DE
                LD   DE, (LoadingLevelNumW)
                ADD  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, ((480 - LOADING_TEXT_H) / 2) * 16
                CALL FT.Coprocessor.Vertex2f

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

LoadingLevelTextWidth:
                LD   HL, LoadingLevelBuf
                LD   DE, 0
.lltw_loop:    LD   A, (HL)
                OR   A
                RET  Z
                INC  HL
                PUSH HL
                CALL LoadingLevelCharWidth              ; A = slice width
                LD   H, 0 : LD L, A
                ADD  HL, DE
                LD   D, H : LD E, L
                POP  HL
                JR   .lltw_loop

LoadingLevelCharWidth:
                CP   '-'
                JR   Z, .llcw_dash
                CP   '0'
                JR   C, .llcw_zero
                CP   '9' + 1
                JR   NC, .llcw_zero
                SUB  '0'
                LD   C, A
                LD   B, 0
                LD   HL, LoadingDigitWTable
                ADD  HL, BC
                LD   A, (HL)
                RET
.llcw_dash:    LD   A, LOADING_TEXT_DASH_W
                RET
.llcw_zero:    XOR  A
                RET

DrawLoadingLevelCharSlice:
                CP   '-'
                JR   Z, .dllc_dash
                CP   '0'
                RET  C
                CP   '9' + 1
                RET  NC
                SUB  '0'
                LD   E, A
                LD   D, 0
                LD   HL, LoadingDigitXTable
                ADD  HL, DE
                ADD  HL, DE
                LD   E, (HL) : INC HL
                LD   D, (HL)                            ; DE = slice x
                PUSH DE
                LD   H, 0 : LD L, A
                LD   DE, LoadingDigitWTable
                ADD  HL, DE
                LD   A, (HL)                            ; A = width
                POP  DE
                JR   DrawLoadingSliceAtCurX
.dllc_dash:    LD   DE, LOADING_TEXT_DASH_X
                LD   A, LOADING_TEXT_DASH_W
                ; fallthrough

DrawLoadingSliceAtCurX:
                LD   (LoadingSliceW), A
                EX   DE, HL                             ; HL = slice x in pixels
                ADD  HL, HL                             ; bytes for ARGB4
                LD   DE, LOADING_TEXT_RAMG & #FFFF
                ADD  HL, DE
                LD   A, (LOADING_TEXT_RAMG >> 16) & #FF
                JR   NC, .dls_src_ok
                INC  A
.dls_src_ok:   LD   B, #01                              ; BITMAP_SOURCE
                LD   C, A
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                FT_BitmapLayout FT_ARGB4, LOADING_TEXT_W * 2, LOADING_TEXT_H
                LD   A, (LoadingSliceW)
                LD   H, 0 : LD L, A
                ADD  HL, HL : ADD HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL : ADD HL, HL
                ADD  HL, HL : ADD HL, HL : ADD HL, HL   ; width << 9
                LD   DE, LOADING_TEXT_H
                ADD  HL, DE
                LD   B, #08                              ; BITMAP_SIZE, nearest/border/border
                LD   C, 0
                LD   D, H : LD E, L
                CALL FT.Coprocessor.Command_BCDE

                LD   HL, (LoadingLevelCurX)
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   B, H : LD C, L
                LD   DE, ((480 - LOADING_TEXT_H) / 2) * 16
                CALL FT.Coprocessor.Vertex2f

                LD   A, (LoadingSliceW)
                LD   H, 0 : LD L, A
                LD   DE, (LoadingLevelCurX)
                ADD  HL, DE
                LD   (LoadingLevelCurX), HL
                RET

BuildLoadingLevelBuf:
                LD   DE, LoadingLevelBuf
                LD   A, (CurrentLevel)
                INC  A                                  ; N = 1..22
                LD   B, '0'
.bll_n_tens:   CP   10
                JR   C, .bll_n_units
                SUB  10
                INC  B
                JR   .bll_n_tens
.bll_n_units:  LD   C, A
                LD   A, B
                CP   '0'
                JR   Z, .bll_n_skip
                LD   (DE), A : INC DE
.bll_n_skip:   LD   A, C : ADD A, '0'
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

LoadingLevelBuf:  DEFS 6                                ; "NN-M" + 0
LoadingLevelX:    DEFW 0
LoadingLevelNumW: DEFW 0
LoadingLevelCurX: DEFW 0
LoadingSliceW:    DEFB 0
LoadingDigitXTable:
                DEFW LOADING_TEXT_DIGIT_0_X, LOADING_TEXT_DIGIT_1_X, LOADING_TEXT_DIGIT_2_X, LOADING_TEXT_DIGIT_3_X, LOADING_TEXT_DIGIT_4_X
                DEFW LOADING_TEXT_DIGIT_5_X, LOADING_TEXT_DIGIT_6_X, LOADING_TEXT_DIGIT_7_X, LOADING_TEXT_DIGIT_8_X, LOADING_TEXT_DIGIT_9_X
LoadingDigitWTable:
                DEFB LOADING_TEXT_DIGIT_0_W, LOADING_TEXT_DIGIT_1_W, LOADING_TEXT_DIGIT_2_W, LOADING_TEXT_DIGIT_3_W, LOADING_TEXT_DIGIT_4_W
                DEFB LOADING_TEXT_DIGIT_5_W, LOADING_TEXT_DIGIT_6_W, LOADING_TEXT_DIGIT_7_W, LOADING_TEXT_DIGIT_8_W, LOADING_TEXT_DIGIT_9_W

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
                ; Ported HD-ref shape:
                ; points = 500 * (GAP_MAX - distance) / GAP_MAX, clamp >= 10.
                ; In this port distance is Manhattan distance to the nearest GAP slot.
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
                CALL GetCurrentTargetScore             ; DE = per-level target (clobbers HL)
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

; LoadLevelSelectPreviewAssets — moved into the loader overlay as
; OVL_LoadLevelSelectPreviewAssets (ts-dos.asm). The same-named resident
; trampoline in loader_resident.asm maps the overlay and calls it. Callers
; (level-select) are unchanged.

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

UploadFrogPalette:
                PUSH HL                                ; input HL = low 16 bits of RAM_G palette addr
                SetPage2_A
                POP  DE
                LD   HL, #8000
                LD   BC, 512
                LD   A, #0C                            ; all frog palettes live at #0C0000..#0C07FF
                JP   FT.WriteMem

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 8                               ; 400×300 PALETTED4444 = 120000 bytes, 8 × 16K pages
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BG_PALETTE_PAGE    EQU #11      ; moved from #0F: ZiFi SD driver (WDFCVBI2.COD) lives there
BG_PALETTE_RAMG    EQU #02D500                         ; 4-byte aligned, after useful 400×300 bitmap
BALLS_FIRST_PAGE   EQU #2D                             ; balls atlas pages
                if BALLS_ARGB4_ENABLED
BALLS_PAGE_COUNT   EQU 12                              ; ARGB4 canary: 6×16×32×32×2 = 192 KB
                else
BALLS_PAGE_COUNT   EQU 12                              ; PALETTED4444: 6×32×32×32 1bpp = 192 KB
                endif
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000)
BALLS_PALETTE_PAGE EQU #39                             ; palette ARGB4 СТРОГО 512 байт (256 entries × 2 bytes)
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
KZ_RAMG_ADDR       EQU #0D4000                         ; after cursor page, below RAM_G 1 MB limit
KZ_PALETTE_RAMG    EQU #0EAB00                         ; after 88×88×12 PALETTED4444 pixels, inside page #1B padding
DESTROY_PAGE       EQU #1C                              ; match-3 серый animBallDestroy, 13 кадров, 4 стр.
DESTROY_RAMG_ADDR  EQU #0EC000                         ; after killzone atlas

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

; --- Cursor 24×24 ARGB4 (1 page) ---
CURSOR_PAGE        EQU #5A
CURSOR_RAMG_ADDR   EQU #0D0000                         ; after frog overlay area
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
                SetPage1 5                            ; #4000 → Core code page (main0 resident)
                SetPage2 6                            ; #8000 → TrackData (track_640.bin)
                SetPage3 UI_OVL_PAGE                  ; #C000 → UI overlay (boot scene = menu); gameplay maps #04 in FadeLevelSelectToGameplay
                LD   HL, BuildCanaryBytes
                LD   DE, BUILD_CANARY_ADDR
                LD   BC, BUILD_CANARY_LEN
                LDIR
                RET

BuildCanaryBytes:
                DB "ZVDAC2 2026-05-24 PAGE3GUARD",0
                DB #00, #05, #06, #04
BuildCanaryBytesEnd:

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

; Pause/exit confirmation dialog. Dialog state 3 is a real pause: VDC_Update
; refreshes RTC baseline and returns, so elapsed game time excludes this menu.
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

.mouse:         LD   A, Input.Mouse.SVK_LBUTTON
                CALL Input.Mouse.KeyState
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
.resume:        ; "No" -> begin 1 s window fade-out. Stay not-Play (DialogState=4)
                ; so the frog can't shoot and game time stays frozen; the frog
                ; sprite starts drawing from this first fade frame.
                LD   A, 4
                LD   (VDC_DialogState), A
                LD   A, PAUSE_FADE_FRAMES
                LD   (PauseFadeTimer), A
                LD   A, 255
                LD   (VDC_PauseAlpha), A
                XOR  A
                LD   (VDC_PrevMouseL), A                ; consume the "No" click
                LD   (PauseMenuFirePrev), A
                RET

; UpdatePauseFade — runs each frame while VDC_DialogState=4 (pause "No" fade-out).
; Board stays frozen (not-Play: no shot, no game-time). The pause window alpha
; ramps down over PAUSE_FADE_FRAMES; when it expires -> DialogState=0 (PLAY).
UpdatePauseFade:
                LD   A, 1
                LD   (VDC_HudPointerBlock), A           ; eat fire edge during fade
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
                LD   A, Input.Mouse.SVK_LBUTTON
                CALL Input.Mouse.KeyState
                LD   A, 0
                JR   NZ, .have_lmb
                LD   A, 1
.have_lmb:      LD   C, A                              ; C = now: 0=released, 1=pressed (HW active-low)
                LD   A, (VDC_PrevMouseL)
                LD   B, A                              ; B = prev
                LD   A, C
                LD   (VDC_PrevMouseL), A
                OR   A
                JR   Z, .hover                         ; no click, hover only
                LD   A, 2
                LD   (VDC_HudMenuState), A             ; pressed visual
                LD   A, B
                OR   A
                RET  NZ                                ; held: do not retrigger
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

; PauseColorA — FT812 global alpha = (A * VDC_PauseAlpha) / 256. Lets the whole
; pause window fade during the "No" fade-out. VDC_PauseAlpha=255 (the static
; pause/game-over dialogs) leaves the base alpha A unchanged.
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
; Pause "No"/resume fade-out: VDC_DialogState=4 holds the board frozen (not-Play,
; so frog can't shoot and game time stays frozen) while the pause window fades
; out over PAUSE_FADE_FRAMES ticks; then -> PLAY. VDC_PauseAlpha (255=opaque)
; scales the whole window's draw alpha during the fade.
PAUSE_FADE_FRAMES EQU 74        ; ~1 s at 74 Hz vsync
PauseFadeTimer:    DEFB 0
VDC_PauseAlpha:    DEFB 255
str_pause_exit:    DB "REALLY WANT TO EXIT",0
str_yes:           DB "YES",0
str_no:            DB "NO",0

                include "loader_resident.asm"         ; resident bits of the PAK loader (VDC_ReadSampleAtHL, cross-load vars, overlay trampolines)
                include "shared_render.asm"           ; DL-matrix + frog-render machinery used by gameplay (#04) AND level-select (#41); resident so neither needs to page-swap
                include "Input.asm"                   ; resident global input module (PS/2 keyboard via Mr.Gluk + Kempston + mouse); callable from any scene
Main0_End:                                            ; MUST be after ALL main0 code (Init_Core/Init_Int/INT_Handler/loader_resident/shared_render)

                ; ----- gameplay overlay (slot 3, page #04) — play-scene code -----
                ; Mapped into slot 3 only during gameplay (set in FadeLevelSelectToGameplay).
                SLOT 3 : PAGE #04 : ORG #C000
Main1_Start:
                include "top_mask_overlay_meta.inc"      ; runtime table, must live in mapped gameplay overlay
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"
                ; Таблицы глифов native-48 шрифта «LEVEL N-M» живут ЗДЕСЬ (overlay #04),
                ; а не в slot0 — там не хватило места. Читаются только DrawIntroText при
                ; slot3=#04; DrawString/SetFontLevel48 в slot0 (всегда замаплен) обращаются
                ; к ним через FontPtr, пока активна сцена геймплея.
                include "font_level48_meta.inc"
Main1_End:

                ; ----- UI overlay (slot 3, page UI_OVL_PAGE) — menu/level-select +
                ; one-shot video init. Mapped into slot 3 for menu, level-select and
                ; at boot (Init_Video). Shares the #C000 window with the gameplay
                ; overlay (different page), never co-resident. The resident Fade*
                ; transitions swap the page into slot 3 before JP'ing into the scene.
                SLOT 3 : PAGE UI_OVL_PAGE : ORG #C000
UiOvl_Start:
                include "Init_Video.asm"
                include "MenuMain.asm"
                include "LevelSelect.asm"
UiOvl_End:

                ; ----- loader overlay (slot 3, page LOADER_OVL_PAGE) — RawPak FAT
                ; loader, mapped into slot 3 only during a level/preview load.
                ; Shares the #C000 window with the other overlays (different page),
                ; never co-resident. Reached via the trampolines in loader_resident.asm.
                SLOT 3 : PAGE LOADER_OVL_PAGE : ORG #C000
LoaderOvl_Start:
                include "ts-dos.asm"
LoaderOvl_End:
                endmodule

Main0_Size       EQU Core.Main0_End - Core.Start
Main1_Size       EQU Core.Main1_End - Core.Main1_Start
UiOvl_Size       EQU Core.UiOvl_End - Core.UiOvl_Start
LoaderOvl_Size   EQU Core.LoaderOvl_End - Core.LoaderOvl_Start
                display "Main0:    \t", /A, Core.Start,        " size=", /D, Main0_Size,     " bytes (slot 1 page 5)"
                display "Main1:    \t", /A, Core.Main1_Start,  " size=", /D, Main1_Size,     " bytes (slot 3 page #04, gameplay)"
                display "UiOvl:    \t", /A, Core.UiOvl_Start,  " size=", /D, UiOvl_Size,     " bytes (slot 3 page #41, ui)"
                display "LoaderOvl:\t", /A, Core.LoaderOvl_Start, " size=", /D, LoaderOvl_Size, " bytes (slot 3 page #40)"
                ; main1_play (#04), the UI overlay (#41) and the loader overlay (#40)
                ; all assemble at logical #C000 on different physical pages. Map the
                ; right page into the slot before EACH SAVEBIN, else SAVEBIN dumps
                ; whichever page was mapped last into the wrong .bin — corrupting it.
                SLOT 1 : PAGE #05
                SAVEBIN "Build/Core.bin",        Core.Start,       Main0_Size
                SLOT 3 : PAGE #04
                SAVEBIN "Build/main1_play.bin",  Core.Main1_Start, Main1_Size
                SLOT 3 : PAGE UI_OVL_PAGE
                SAVEBIN "Build/ui_ovl.bin",      Core.UiOvl_Start, UiOvl_Size
                SLOT 3 : PAGE Core.LOADER_OVL_PAGE
                SAVEBIN "Build/loader_ovl.bin",  Core.LoaderOvl_Start, LoaderOvl_Size

                END EntryPoint
