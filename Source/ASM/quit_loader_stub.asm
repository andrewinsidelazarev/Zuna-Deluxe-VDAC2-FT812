; ============================================================================
; quit_loader_stub.asm — РЕЛОЦИРУЕМЫЙ загрузчик WC для кнопки Quit.
; Ассемблируется в main.asm внутри DISP #4000 (метки/переходы = адреса #40xx),
; но байты эмитятся в резиденте (Core). На Quit копируется в #4000 (bank5, ниже
; #6011 → переживает загрузку) и запускается в СТАНДАРТНОМ 128-режиме, где
; slot1=bank5 / slot2=bank2 / slot3=bank0 фиксированы → #6000..#DE00 непрерывны.
;
; Читает QS_Cnt последовательных секторов с QS_Lba в адресное окно WC:
; #6000..#7FFF -> PAGE1=#05, #8000..#BFFF -> PAGE2=#03, #C000..#DFFF -> PAGE3=#41.
; 17-байтный HOBETA-заголовок ложится на #6000..#6010, данные WC — ровно на #6011.
; Затем выставляет регистры как у живого WC и JP #6011.
; Параметры (QS_Lba/Cnt/Blkt) пишет оркестратор Quit ПОСЛЕ копирования стаба.
; ============================================================================
QS_SD_CONF  EQU #77
QS_SD_DATA  EQU #57
QS_SD_CMD17 EQU %01000000+17
QS_SD_CS1   EQU %00000001
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
QS_DBG_STAGE EQU Core.Quit_DbgStage
QS_DBG_SECTS EQU Core.Quit_DbgSectors

QuitStub_Run:                                   ; точка входа = #4000
                DI
                LD   SP, #5F00                   ; локальный стек в той же странице, что и стаб
                LD   A, #80
                LD   (QS_DBG_STAGE), A
                XOR  A
                LD   (QS_DBG_SECTS), A
                LD   A, (QS_Cnt)
                LD   B, A                        ; B = число секторов (63)
                LD   IX, #6000                   ; dest: file[0]→#6000, file[17]→#6011
                CALL qwc_map_load_window          ; грузим сразу в страницы живого WC
                CALL qwc_restore_machine_state    ; состояние WC уже во время чтения BOOT.$C
.qsloop:        PUSH BC
                CALL qsd_read_sector             ; [QS_Lba] → (IX), 512 байт (IX сохраняется)
                LD   A, (QS_DBG_SECTS)
                INC  A
                LD   (QS_DBG_SECTS), A
                CP   1
                JR   NZ, .qsnoFirst
                LD   A, #81
                LD   (QS_DBG_STAGE), A
.qsnoFirst:
                LD   BC, 512
                ADD  IX, BC                      ; dest += 512
                CALL qwc_advance_load_page
                LD   HL, (QS_Lba)                ; QS_Lba += 1 (32-бит)
                INC  HL
                LD   (QS_Lba), HL
                LD   A, H : OR L
                JR   NZ, .qsnc
                LD   HL, (QS_Lba + 2)
                INC  HL
                LD   (QS_Lba + 2), HL
.qsnc:          POP  BC
                DJNZ .qsloop
                LD   A, #8F
                LD   (QS_DBG_STAGE), A
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

qwc_advance_load_page:
                LD   A, IXH
                CP   #80
                JR   NZ, .not8000
                LD   BC, QS_PAGE2
                LD   A, #03
                OUT  (C), A
                RET
.not8000:       CP   #C0
                RET  NZ
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

; --- qsd_read_sector: 512 байт [QS_Lba] → (IX). Копия sd_zc (qs_ префикс). ---
qsd_read_sector:
                PUSH IX : POP HL                 ; HL = буфер
                CALL qsd_cmd17
                JR   NZ, .qerr
                CALL qsd_wait_token
                JR   C, .qerr
                CALL qsd_reads                   ; 512 байт → (HL)
                IN   A, (QS_SD_DATA)             ; CRC lo (игнор)
                IN   A, (QS_SD_DATA)             ; CRC hi (игнор)
                JP   qsd_csh
.qerr:          JP   qsd_csh

qsd_cmd17:      LD   A, QS_SD_CMD17
                CALL qsd_csh
                CALL qsd_csl
                PUSH HL
                LD   DE, (QS_Lba)                ; DE = LBA low16
                LD   BC, (QS_Lba + 2)            ; BC = LBA high16
                LD   L, C : LD H, B              ; HL = high16
                LD   C, A                        ; C = команда
                LD   A, (QS_Blkt)
                OR   A
                JR   NZ, .qsend                  ; block addressing → LBA как есть
                EX   DE, HL : ADD HL, HL         ; byte addressing: [HL:DE] = LBA*512
                EX   DE, HL : ADC HL, HL
                LD   H, L : LD L, D : LD D, E : LD E, A   ; A = QS_Blkt = 0
.qsend:         LD   A, C
                LD   BC, QS_SD_DATA
                OUT  (C), A
                OUT  (C), H
                OUT  (C), L
                OUT  (C), D
                OUT  (C), E
                LD   A, #FF
                OUT  (C), A                      ; CRC (игнор)
                POP  HL
                JP   qsd_resp

qsd_reads:      PUSH BC : LD BC, QS_SD_DATA : INIR : INIR : POP BC : RET

qsd_csh:        PUSH BC : PUSH AF
                LD   BC, QS_SD_CONF : LD A, %00000011 : OUT (C), A
                LD   BC, QS_SD_DATA : LD A, #FF : OUT (C), A
                POP  AF : POP BC : RET

qsd_csl:        PUSH BC : PUSH AF
                LD   BC, QS_SD_CONF : LD A, QS_SD_CS1 : OUT (C), A
                LD   BC, QS_SD_DATA : LD A, #FF : OUT (C), A
                POP  AF : POP BC
                ; дальше сразу qsd_wait
qsd_wait:       PUSH BC : PUSH DE : PUSH AF
                LD   BC, QS_SD_DATA : LD DE, 0
.qw:            IN   A, (C) : INC A : JR Z, .qwd
                DEC  DE : LD A, D : OR E : JR NZ, .qw
.qwd:           POP  AF : POP DE : POP BC : RET

qsd_wait_token: PUSH BC : LD BC, QS_SD_DATA : LD D, 4
.qto:           LD   E, 0
.qti:           IN   A, (C) : CP #FE : JR Z, .qtok
                BIT  7, A : JR Z, .qterr
                DEC  E : JR NZ, .qti
                DEC  D : JR NZ, .qto
.qterr:         POP  BC : SCF : RET
.qtok:          POP  BC : OR A : RET

qsd_resp:       PUSH DE : PUSH BC : LD BC, QS_SD_DATA : LD D, 10
.qr:            IN   A, (C) : BIT 7, A : JR Z, .qrd
                DEC  D : JR NZ, .qr
.qrd:           POP  BC : POP DE : RET           ; Z = (последний R1 bit7==0) — как в sd_zc

QS_Lba:         DEFS 4                           ; стартовый LBA (LE), пишет оркестратор
QS_Cnt:         DEFB 0                           ; число секторов
QS_Blkt:        DEFB 0                           ; 0=byte addressing, 1=block
QuitStub_End:
