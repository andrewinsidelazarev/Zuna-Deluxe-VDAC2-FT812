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

; --- Адреса/EQU ----------------------------------------------------------
EntryPoint           EQU #6000                        ; slot 1 (page 5)
StackTop             EQU #40F2
ResolutionWidthPtr   EQU #40F3                        ; куда FT_RESOLUTION пишет ширину (W word)
ResolutionHeightPtr  EQU #40F5                        ; высоту (H word)
MemoryPages          EQU #40F7                        ; page-numbers cache (для не-MAPPING_REGISTERS)
InterruptVA          EQU #4000                        ; IM2 vector area (page-aligned)

TSLib                EQU #1000                        ; адрес где живёт TSLib
TSLibPage            EQU #00                          ; страница TSLib

; --- TSLib block (page 0) ------------------------------------------------
                ORG TSLib
TSLIB_Start:
                include "Docs/TSLib/Include/TSConf.inc"
                include "Docs/TSLib/Include/Memory/Include.inc"
                include "Docs/TSLib/Include/Cache/Macro.inc"
                include "Docs/TSLib/Include/Video/Macro.inc"
                include "Docs/TSLib/Include/System/Macro.inc"
                include "Docs/TSLib/Include/INT/Macro.inc"
                include "Docs/TSLib/Include/FT/81x Const.inc"
                include "Docs/TSLib/Include/FT/DL  Macro.inc"
                include "Docs/TSLib/Include/FT/812 Macro.inc"
                module FT
                include "Docs/TSLib/Include/FT/812 Func.asm"
                include "Docs/TSLib/Include/FT/Coprocessor/Include.inc"
                endmodule
                include "Docs/TSLib/Include/Input/Include.inc"
TSLIB_End:
TSLIB_Size       EQU TSLIB_End - TSLIB_Start
                display "TSLib:    \t", /A, TSLIB_Start, " size=", /D, TSLIB_Size, " bytes"
                SAVEBIN "TSLib.bin", TSLIB_Start, TSLIB_Size

; --- Core block (page 5) -------------------------------------------------
                ORG EntryPoint
                module Core
Start:
                ; ----- EntryPoint -----
                LD   SP, StackTop
                CALL Initialize
                JP   MainLoop

                ; ----- Initialize -----
Initialize:     CALL Init_Core
                CALL Init_Int                         ; EI/HALT — ждём первого FRAME INT (HW stab)
                CALL Init_Video                       ; FT_BOOT_UP + 640×480 + FT_INT_SWAP enable
                CALL Input.Mouse.Initialize           ; курсор в центр (W/2, H/2)
                ; Init завершён — отключаем TS-Conf frame INT 50 Hz, чтобы он не бился
                ; с FT812 vsync 57.25 Hz. Синхронизация в MainLoop через FT_INT_SWAP.
                DI
                INT_Setting 0

                ; Залить bg_level01 (640x480 RGB565, 38 страниц 7..44) в RAM_G
                ; начиная с #010000. Каждая страница = 16384 байт по адресу #8000
                ; в slot 2.
                ; ВАЖНО: bg грузится ПЕРВЫМ. 38×16384=622592 байт реально пишется в
                ; #010000..#0A8000, тогда как реальный bg — 614400 байт (#010000..#0A0000),
                ; последние 8192 байт = padding zeros последней spgbld page. Если atlas
                ; (#0A6000..) залить до bg — bg-padding затрёт первые 8 КБ atlas
                ; = Cell 0 + начало Cell 1 → невидимый шар. Поэтому: bg первым,
                ; atlas вторым (atlas-padding потом уходит в свободную область после #0F2000).
                LD   A, BG_FIRST_PAGE
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

                ; Залить balls_atlas (6 colors × 8 frames × 56×56 ARGB4 = 301 056 байт)
                ; в RAM_G #0A6000. Atlas грузится ПОСЛЕ bg чтобы перезаписать
                ; bg-padding в #0A6000..#0A8000 реальными sprite-данными. Handle 0 в DL.
                LD   A, BALLS_FIRST_PAGE
                LD   (BgPg), A
                LD   HL, BALLS_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (BALLS_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, BALLS_PAGE_COUNT
.UploadBalls:   PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryB
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryB:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadBalls

                ; Залить frog body / plate / tongue / face-overlay в RAM_G.
                ; Layout (FROG_TOTAL_PAGES=7 pages подряд от FROG_PAGE):
                ;   pages 0x52..0x53 — body    (2 pages, 122×122 ARGB4)
                ;   pages 0x54..0x55 — plate   (2 pages)
                ;   page  0x56       — tongue  (1 page tight 32×80, padding 11 КБ
                ;                                перезаписывается next overlay
                ;                                upload, но overlay начинается at
                ;                                OVERLAY_RAMG_ADDR = #0F8000 — gap
                ;                                #0F5000..#0F8000 остаётся zeros)
                ;   pages 0x57..0x58 — overlay (2 pages, HD blink frame 0)
                ; Loop пишет 16 КБ на page и advance RAM_G на #4000 — для tongue
                ; padding zeros (11 КБ) ложится в gap до overlay (no harm).
                LD   A, FROG_PAGE
                LD   (BgPg), A
                LD   HL, FROG_RAMG_ADDR & 0xFFFF
                LD   (BgRamL), HL
                LD   A, (FROG_RAMG_ADDR >> 16) & 0xFF
                LD   (BgRamH), A
                LD   B, FROG_TOTAL_PAGES
.UploadFrog:    PUSH BC
                LD   A, (BgPg)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                POP  BC
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCarryF
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCarryF:      LD   A, (BgPg)
                INC  A
                LD   (BgPg), A
                DJNZ .UploadFrog

                ; Залить killzone 64×64 ARGB4 (8192 байт) в RAM_G KZ_RAMG_ADDR
                ; (#04C000 = bg padding zone). Page 0x16 в spgbld.
                LD   A, KZ_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 8192
                LD   A, (KZ_RAMG_ADDR >> 16) & 0xFF
                LD   DE, KZ_RAMG_ADDR & 0xFFFF
                CALL FT.WriteMem

                ; Залить cursor 48×48 ARGB4 (4608 байт) в RAM_G CURSOR_RAMG_ADDR.
                ; Single page 0x5A. Padding в page безопасен (RAM_G #0BC000+4608..
                ; #0C0000 = пустая зона, никто не читает).
                LD   A, CURSOR_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, CURSOR_W * CURSOR_H * 2
                LD   A, (CURSOR_RAMG_ADDR >> 16) & 0xFF
                LD   DE, CURSOR_RAMG_ADDR & 0xFFFF
                CALL FT.WriteMem

                ; Восстановить slot 2 на TrackData (page 6)
                SetPage2 6

                ; --- VDC physics init (TrackData уже доступен в slot 2) ---
                CALL VDC_Init
                CALL Frog_Init
                CALL Bullet_Init
                RET

BG_FIRST_PAGE      EQU 7
BG_PAGE_COUNT      EQU 15                                ; 400×300 RGB565 = 240000 bytes (~60% economy)
BG_RAMG_ADDR       EQU #010000                         ; bg в RAM_G FT812
BALLS_FIRST_PAGE   EQU #2D                             ; balls_atlas pages 0x2D..0x3F (19 pages)
BALLS_PAGE_COUNT   EQU 19                                ; 6 colors × 8 frames × 56×56 cells = ~294 KB
BALLS_RAMG_ADDR    EQU #050000                         ; сразу после bg+padding (#04C000) с 16 KB запасом
FROG_PAGE          EQU #52                             ; spgbld first page (frog body)
FROG_PAGE_COUNT    EQU 2                                ; 122×122 ARGB4 = 2 pages each
FROG_TOTAL_PAGES   EQU FROG_PAGE_COUNT * 4              ; body+plate+tongue+overlay = 8 pages
FROG_RAMG_ADDR     EQU #09C000                         ; после balls (19 pages = 0x4C000 от #050000)
PLATE_RAMG_ADDR    EQU FROG_RAMG_ADDR + #4000 * FROG_PAGE_COUNT     ; #0A4000
TONGUE_RAMG_ADDR   EQU PLATE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT    ; #0AC000
OVERLAY_RAMG_ADDR  EQU TONGUE_RAMG_ADDR + #4000 * FROG_PAGE_COUNT   ; #0B4000
KZ_PAGE            EQU #16                             ; killzone в bg padding zone
KZ_RAMG_ADDR       EQU #04C000                         ; bg padding (после реальных bg pages)

; --- Cursor 48×48 ARGB4 (1 page) ---
CURSOR_PAGE        EQU #5A
CURSOR_RAMG_ADDR   EQU #0BC000                         ; сразу после overlay area
CURSOR_W           EQU 24
CURSOR_H           EQU 24
CURSOR_TIP_X       EQU 0                               ; острие sprite-coords (см. make_cursor.py)
CURSOR_TIP_Y       EQU 0

BgPg:           DEFB 0
BgRamL:         DEFW 0
BgRamH:         DEFB 0

Init_Core:      FMapAddrInit                          ; FT_EN, MEM_WO, page0=TSLibPage
                System_Setting SYS_ZCLK14 | SYS_CACHEEN
                Cache_Setting  EN_0000 | EN_4000 | EN_8000
                SetPage1 5                            ; #4000 → Core code page
                SetPage2 6                            ; #8000 → TrackData (track_640.bin)
                SetPage3 8
                RET

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

                ; ----- Init_Video, VDC и MainLoop из отдельных файлов -----
                include "Init_Video.asm"
                include "VDC.asm"
                include "Frog.asm"
                include "Bullet.asm"
                include "MainLoop.asm"

End:
                endmodule

Core_Size        EQU Core.End - Core.Start
                display "Core:     \t", /A, Core.Start, " size=", /D, Core_Size, " bytes"
                SAVEBIN "Core.bin", Core.Start, Core_Size

                END EntryPoint
