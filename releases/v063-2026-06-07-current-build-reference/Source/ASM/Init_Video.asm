
                ifndef _ZUMA_INIT_VIDEO_
                define _ZUMA_INIT_VIDEO_

; ============================================================================
; Init_Video — инициализация видеорежима 640×480 через VDAC2 / FT812
; ----------------------------------------------------------------------------
; Использует TSLib (DeadlyKom). Зависимости подключи в основном файле проекта:
;
;   include "Docs/TSLib/Include/TSConf.inc"            ; STATUS, VCONFIG, VID_*
;   include "Docs/TSLib/Include/Video/Macro.inc"       ; Video_Setting
;   include "Docs/TSLib/Include/FT/81x Const.inc"      ; FT_REG_*, VM_*, FT_INT_*
;   include "Docs/TSLib/Include/FT/812 Macro.inc"      ; FT_BOOT_UP, FT_RESOLUTION, FT_WR_REG8, FT_CMD_RESET
;   include "Docs/TSLib/Include/FT/812 Func.asm"       ; FT.WriteMem, FT.WriteDL, FT.SendCommand.Param
;   include "Docs/TSLib/Include/FT/DL  Macro.inc"      ; FT_CLEAR_COLOR_RGB, FT_CLEAR, FT_DISPLAY (DEFD-форма)
;
; Пользовательские константы (определи в Configuration.inc или Include.inc):
;   ResolutionWidthPtr   EQU <addr_word_in_RAM>   ; куда FT_RESOLUTION пишет ширину
;   ResolutionHeightPtr  EQU ResolutionWidthPtr+2 ; высоту
;
; Out:
;   A=0, Z=1   — успех (640×480 включён через FT812)
;   A=1, Z=0   — VDAC2 на этой плате не обнаружен (вызывающий выбирает fallback)
; Corrupts: AF, BC, DE, HL
; ============================================================================

Init_Video:     ; --- 1. Sanity-check: VDAC2 присутствует на плате? --------
                ; TS-Conf STATUS [2:0] = 111 ⇒ FT812-VDAC2. Иначе плата с
                ; обычным VDAC (5/4/3/2-bit) — на ней этот код работать не
                ; будет, надо отдать управление обратно в TS-Config рендер.
                IN   A, (STATUS)
                AND  %00000111
                CP   %00000111
                JP   NZ, .no_vdac2                    ; JP, не JR — FT_BOOT_UP большой

                ; --- 2. Полная boot-up последовательность FT812 ----------
                ; FT_BOOT_UP (TSLib 812 Macro.inc:104):
                ;   PWRDOWN_ → CLKEXT → CLKSEL #C0 → ACTIVE
                ;   ждать REG_ID == 0x7C
                ;   ждать REG_CPURESET == 0
                ;   записать default тайминги, SWIZZLE/PCLK_POL/CSPREAD/DITHER/OUTBITS
                ;   GPIOX_DIR=0xFFFF, GPIOX=0xFFFF (включить DISP)
                ;   REG_PCLK = 2 (включает развёртку 60/2 = 30 МГц)
                FT_BOOT_UP

                ; --- 3. Сброс co-processor буфера ------------------------
                ; FT_CMD_RESET = REG_CPURESET=1, DELAY 5, REG_CMD_READ/WRITE=0,
                ; REG_CPURESET=0. Гарантирует что после старта co-processor
                ; не имеет «висящих» команд из предыдущих сессий.
                FT_CMD_RESET

                ; --- 4. Переключить таймминги на 640×480 @ 74 Hz ---------
                ; VM_640_480_74Hz: PCLK 32 МГц (F_MUL=4), H 24/40/128/640,
                ;                  V 9/3/28/480 → HCYCLE 832, VCYCLE 520.
                ; 832×520 = 432 640 pclk/frame vs 800×524=419 200 на 57Hz
                ; (+3.2% bandwidth для bg-rendera, помогает с tearing на реале).
                ; Макрос пишет HCYCLE, HOFFSET, HSYNC0/1, HSIZE, VCYCLE,
                ; VOFFSET, VSYNC0/1, VSIZE и REG_PCLK = F_MUL.
                FT_RESOLUTION VM_640_480_74Hz, ResolutionWidthPtr

                ; --- 5. Залить минимальный пустой DL: чёрный экран -------
                ; До первого FT_CMD_Write из MainLoop'а на экране может быть
                ; garbage (RAM_DL после reset не определена). Заливаем 12 байт:
                ; CLEAR_COLOR_RGB(0,0,0); CLEAR(1,1,1); DISPLAY().
                LD   HL, .EmptyDL
                LD   BC, .EmptyDL_Size
                LD   DE, 0                             ; offset 0 от FT_RAM_DL
                CALL FT.WriteDL                        ; HL→RAM_DL+DE, OTIR блок
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME

                ; --- 6. Разрешить SWAP-interrupt -------------------------
                ; MainLoop ждёт этот INT_FLAG чтобы синхронизироваться
                ; с vsync (см. Examples\2.HelloWorld\Core\MainLoop.asm).
                FT_WR_REG8 FT_REG_INT_MASK, FT_INT_SWAP
                FT_WR_REG8 FT_REG_INT_EN,   1

                ; --- 7. Переключить видеовыход TS-Conf → FT812 -----------
                ; VID_FT812 (#04) = bit 2 FT_EN — выход через VDAC2.
                ; VID_NOGFX (#20) = bit 5 NO_GFX — отключить TS-Conf gfx
                ; (освобождает 448 DMA-циклов/строку для FT-передач).
                Video_Setting VID_FT812 | VID_NOGFX

                ; Успех
                XOR  A                                ; A=0, Z=1
                RET

.no_vdac2:      ; VDAC2 не обнаружен. Возвращаем NZ — пусть caller решает
                ; (fallback на оригинальный TS-Conf рендер 360×288 или Halt).
                LD   A, 1
                OR   A                                ; Z=0
                RET

; ----------------------------------------------------------------------------
; Минимальный пустой Display List — три 32-битные команды, всего 12 байт.
; Хранится в коде, заливается один раз при init для гарантии чистого экрана
; до первого живого DL из MainLoop'а.
; ----------------------------------------------------------------------------
.EmptyDL:       FT_CLEAR_COLOR_RGB 0, 0, 0            ; opcode 0x02 — фон чёрный
                FT_CLEAR 1, 1, 1                       ; opcode 0x26 — color+stencil+tag
                FT_DISPLAY                             ; opcode 0x00 — конец DL
.EmptyDL_End:
.EmptyDL_Size   EQU .EmptyDL_End - .EmptyDL

                endif ; ~_ZUMA_INIT_VIDEO_
