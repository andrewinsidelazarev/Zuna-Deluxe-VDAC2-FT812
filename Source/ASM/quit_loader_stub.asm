; ============================================================================
; quit_loader_stub.asm — РЕЛОЦИРУЕМЫЙ загрузчик WC для кнопки Quit.
; Ассемблируется в main.asm внутри DISP #4000 (метки/переходы = адреса #40xx),
; но байты эмитятся в резиденте (Core). На Quit копируется в #4000 (bank5, ниже
; #6011 → переживает загрузку) и запускается в СТАНДАРТНОМ 128-режиме, где
; slot1=bank5 / slot2=bank2 / slot3=bank0 фиксированы → #6000..#DE00 непрерывны.
;
; Клод: BOOT.$C читает не стаб, а FAT32-драйвер игры (OVL_ProbeBoot) — целиком,
; в страницы QUIT_BOOT_PAGE0/1, пока игра ещё работает. Стаб, как прежде, сразу
; ставит состояние WC (qwc_restore_machine_state), затем вместо собственного
; чтения SD (CMD17 по LBA с режимом адресации карты, файл подряд — удалено)
; копирует RAWPAK_BOOT_SIZE байт из этих страниц в адресное окно WC портами
; страниц slot 2/3.
; Окно WC: #6000..#7FFF -> PAGE1=#05, #8000..#BFFF -> PAGE2=#03,
; #C000..#DFFF -> PAGE3=#41. 17-байтный HOBETA-заголовок ложится на
; #6000..#6010, данные WC — ровно на #6011. Затем стаб выставляет регистры как у
; живого WC и делает JP #6011.
; ============================================================================
QS_VCONFIG  EQU #00AF
QS_VPAGE    EQU #01AF
QS_XOFFSL   EQU #02AF
QS_XOFFSH   EQU #03AF
QS_YOFFSL   EQU #04AF
QS_YOFFSH   EQU #05AF
QS_TSCONFIG EQU #06AF
QS_PALSEL   EQU #07AF
QS_SUSCONF  EQU #20AF
QS_PAGE0    EQU #10AF
QS_PAGE1    EQU #11AF
QS_PAGE2    EQU #12AF
QS_PAGE3    EQU #13AF
QS_MEMCONF  EQU #21AF
QS_INTMASK  EQU #2AAF
QS_CACHECFG EQU #2BAF
                if RUNTIME_DIAGNOSTICS_ENABLED
QS_TRACE_STAGE EQU Core.QuitTraceStage
QS_TRACE_SECTS EQU Core.QuitTraceSectors
                endif

QuitStub_Run:                                   ; точка входа = #4000
                DI
                LD   SP, #5F00                   ; локальный стек в той же странице, что и стаб
                if RUNTIME_DIAGNOSTICS_ENABLED
                LD   A, #80
                LD   (QS_TRACE_STAGE), A
                XOR  A
                LD   (QS_TRACE_SECTS), A
                endif
                CALL qwc_map_load_window          ; окно WC: PAGE1=#05, PAGE2=#03, PAGE3=#41
                CALL qwc_restore_machine_state    ; как прежде: состояние WC уже на время загрузки BOOT.$C
                ; Клод: копирование только портами страниц slot 2/3 — без slot 0 и окна
                ; FM; источник (QUIT_BOOT_PAGE0/1) — в slot 3, не кэшируемом у WC.
                LD   BC, QS_PAGE3
                LD   A, QUIT_BOOT_PAGE0
                OUT  (C), A                       ; #C000 = file[#0000..#3FFF]
                LD   HL, #C000
                LD   DE, #6000
                LD   BC, #2000
                LDIR                              ; file[#0000..#1FFF] -> #6000..#7FFF (PAGE1=#05)
                LD   DE, #8000
                LD   BC, #2000
                LDIR                              ; file[#2000..#3FFF] -> #8000..#9FFF (PAGE2=#03)
                if RUNTIME_DIAGNOSTICS_ENABLED
                LD   A, 32
                LD   (QS_TRACE_SECTS), A
                LD   A, #81
                LD   (QS_TRACE_STAGE), A
                endif
                LD   BC, QS_PAGE3
                LD   A, QUIT_BOOT_PAGE1
                OUT  (C), A                       ; #C000 = file[#4000..]
                LD   HL, #C000
                LD   DE, #A000
                LD   BC, #2000
                LDIR                              ; file[#4000..#5FFF] -> #A000..#BFFF (PAGE2=#03)
                LD   BC, QS_PAGE2
                LD   A, #41
                OUT  (C), A                       ; страница окна WC #C000.. — через slot 2
                LD   DE, #8000
                LD   BC, RAWPAK_BOOT_SIZE - #6000
                LDIR                              ; file[#6000..] -> страница #41 (у WC — #C000..)
                ; Хвост последнего сектора (у WC #DC11..#DDFF) — нули: прежний стаб
                ; читал целые секторы и писал сюда остаток сектора с карты.
                LD   H, D
                LD   L, E
                LD   (HL), 0
                INC  DE
                LD   BC, RAWPAK_BOOT_SECTORS * 512 - RAWPAK_BOOT_SIZE - 1
                LDIR
                CALL qwc_map_load_window          ; окно WC снова: PAGE2=#03, PAGE3=#41
                if RUNTIME_DIAGNOSTICS_ENABLED
                LD   A, RAWPAK_BOOT_SECTORS
                LD   (QS_TRACE_SECTS), A
                LD   A, #8F
                LD   (QS_TRACE_STAGE), A
                endif
                LD   HL, #6000
                LD   B, 17
                XOR  A
.qclrHdr:       LD   (HL), A                     ; убрать HOBETA-заголовок из переменных WC
                INC  HL
                DJNZ .qclrHdr
                CALL qwc_prepare_launch          ; повторить состояние WC перед JP #6011
                JP   #6011                       ; запуск Wild Commander

; --- Раскладка загрузки совпадает с окном живого WC со скрина. ---
qwc_map_load_window:
                LD   BC, QS_PAGE1
                LD   A, #05
                OUT  (C), A
                LD   BC, QS_PAGE2
                LD   A, #03
                OUT  (C), A
                LD   BC, QS_PAGE3
                LD   A, #41
                OUT  (C), A
                RET


; --- Аппаратный хвост из штатного WC RUNHOB/HOBAT перед RET в HOBETA. ---
qwc_prepare_launch:
                DI
                LD   A, 63
                LD   I, A
                IM   1
                LD   IY, #5C3A
                LD   HL, #5800
                LD   DE, #5801
                LD   BC, #0300-1
                LD   (HL), L                     ; очистить атрибуты ZX-экрана нулями
                LDIR
                CALL qwc_restore_machine_state
                LD   BC, #7FFD
                LD   A, #10
                OUT  (C), A
                RET

qwc_seed_text_video:
                ; WC сам ставит эти значения в GED/VPRT, но первый кадр может висеть до IM2.
                XOR  A
                LD   BC, QS_VPAGE                 ; WC: текстовый экран в странице 0
                OUT  (C), A
                LD   BC, QS_PALSEL                ; палитры 0
                OUT  (C), A
                LD   BC, QS_XOFFSL                ; X/Y offsets = 0
                OUT  (C), A
                LD   BC, QS_XOFFSH
                OUT  (C), A
                LD   BC, QS_YOFFSL
                OUT  (C), A
                LD   BC, QS_YOFFSH
                OUT  (C), A
                LD   BC, QS_VCONFIG
                LD   A, #83                       ; WC default TXTmdCO: 320x240 text
                OUT  (C), A
                RET

qwc_restore_machine_state:
                ; Возвращаем железо к состоянию WC со скрина.
                ; Возвращаем железо к состоянию WC перед передачей управления BOOT.$C.
                LD   BC, QS_INTMASK
                XOR  A                           ; WC: INTMASK=0
                OUT  (C), A
                LD   BC, QS_TSCONFIG
                OUT  (C), A                      ; WC: TSConfig=0
                LD   BC, QS_SUSCONF
                LD   A, #06                      ; WC: SusConfig=#06
                OUT  (C), A
                LD   BC, QS_CACHECFG
                LD   A, #07                      ; WC: CacheConfig=#07
                OUT  (C), A
                LD   BC, QS_VCONFIG
                LD   A, #24                      ; WC: VConfig=#24
                OUT  (C), A
                LD   BC, QS_MEMCONF
                LD   A, %00000001                ; WC: MemConfig=#01
                OUT  (C), A
                LD   BC, QS_PAGE0
                LD   A, #03                      ; WC: Page0=#03
                OUT  (C), A
                LD   BC, QS_PAGE1
                LD   A, #05                      ; WC: Page1=#05
                OUT  (C), A
                LD   BC, QS_PAGE2
                LD   A, #03                      ; WC: Page2=#03
                OUT  (C), A
                LD   BC, QS_PAGE3
                LD   A, #41                      ; WC: Page3=#41
                OUT  (C), A
                RET

; Клод: удалены qwc_advance_load_page и qsd_* (собственное чтение SD) и QS_Lba/QS_Cnt/QS_Blkt.

QuitStub_End:
