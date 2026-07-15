;//////////////////////////////////////////////////////////////
;//  Самодостаточное чтение raw sector с SD (Z-Controller).
;//  Портировано из read path WC device driver DSDZC.ASM
;//  (через Desktop/WC/Chkdsk/src/sd_zc.a80 из ChkDsk session).
;//  Обычно карта уже initialized Wild Commander до запуска SPG, но это состояние
;//  не считается вечным: после оборванного чтения driver делает CMD12+CMD58, а
;//  при отсутствии настоящего R1 выполняет bounded CMD0/CMD8/ACMD41/CMD58 init.
;//
;//  Этот путь обходит bundled TS-DOS driver: его FAT chain walk в нашем SPG
;//  context сдвигался на -128 sectors на первой границе FAT-sector. Поэтому
;//  BPB/FAT walk выполняется нашим кодом поверх sd_read_sector.
;//
;//  Unreal/этот host использует BYTE addressing (sd_blkt = 0): CMD17 argument
;//  равен LBA*512. Реальная SDHC использовала бы block addressing.
;//////////////////////////////////////////////////////////////

SD_CONF         equ     #77             ; config / chip-select port
SD_DATA         equ     #57             ; data port
SD_CMD0         equ     %01000000+0     ; GO_IDLE_STATE: заново войти в SPI mode
SD_CMD8         equ     %01000000+8     ; SEND_IF_COND: SD v2 / echo #01AA
SD_CMD17        equ     %01000000+17    ; single-block read
SD_CMD12        equ     %01000000+12    ; остановить незавершённую передачу при recovery
SD_CMD16        equ     %01000000+16    ; SET_BLOCKLEN=512 для byte-addressed SDSC
SD_CMD55        equ     %01000000+55    ; префикс application command
SD_ACMD41       equ     %01000000+41    ; SD_SEND_OP_COND: вывести карту из idle
SD_CMD58        equ     %01000000+58    ; READ_OCR: command-presence + CCS addressing
SD_CS1          equ     %00000001       ; chip select, SD1

;--- sd_init: начать новую SD-session. sd_blkt сначала обнуляется только как
;    безопасный bootstrap для LBA0; sd_probe_command/full init затем получают
;    настоящий CCS из CMD58. RawPak_OpenRoot всё равно повторно подтверждает
;    MBR/SDHC перед ненулевыми LBA.
;    CF=0 — карта ответила реальной командой; CF=1 — recovery/full init failed.
sd_init:
                xor     a
                ld      (sd_blkt),a             ; LBA0 одинаков в byte/block mode; OpenRoot уточнит режим
                jp      sd_session_recover      ; outer session обязана оборвать и унаследованный CMD18

; --- Опциональная проверка CRC16 принятого сектора (по умолчанию ВЫКЛ). ---
; Карта всегда шлёт data-CRC16; sd_read_sector раньше его игнорировал. При
; SD_CRC_CHECK=1 считаем CRC16-CCITT над 512 байтами и сверяем; несовпадение →
; CF=1, и публичный sd_read_sector после recovery перечитывает тот же sector. Это
; ловит ТИХУЮ порчу данных (трек #0F на L18 и т.п.), а не только протокольный отказ.
; ВНИМАНИЕ: включать ТОЛЬКО после проверки в эмуляторе — если его SD-модель шлёт
; не настоящий CRC16, проверка завалит каждый сектор (3 ретрая → load error).
SD_CRC_CHECK    EQU 0

;--- sd_read_sector: прочитать один 512-byte sector с protocol retry/recovery.
;    Вход: HL = LBA (low 16), DE = LBA (high 16) [LBA 32-bit]
;          IX = destination buffer (512 bytes)
;    Выход: CF = 1 при error, CF = 0 при success
sd_read_sector:
                ld      (sd_lba+0),hl
                ld      (sd_lba+2),de
                call    sd_lba_in_range         ; защита: не слать CMD17 за пределы тома —
                jr      c,.range                ; битый LBA иначе кирпичит реальную SDHC до переткивания
                push    bc                      ; B caller'а не превращать в retry counter
                ld      b,3                     ; максимум три физических CMD17 одного LBA
.retry          push    bc                      ; single read клобает рабочие регистры драйвера
                call    sd_read_sector_once     ; CF=0 sector готов; CF=1 protocol/read error
                pop     bc                      ; вернуть число оставшихся физических попыток
                jr      nc,.retry_ok            ; успешный sector уже лежит по IX
                djnz    .recover                ; последняя ошибка: recovery уже не даст новой попытки
                pop     bc                      ; восстановить caller B перед окончательным CF=1
                scf
                ret
.recover        call    sd_recover              ; следующий CMD17 только после idle/ready
                jr      c,.retry_fail           ; карта не стала ready — не слать в неё ещё один CMD17
                jr      .retry                  ; mode подтверждён OCR; повторяется тот же sd_lba/IX
.retry_ok       pop     bc                      ; восстановить caller B после успешного чтения
                or      a                       ; публичный low-level контракт: CF=0 success
                ret
.retry_fail     pop     bc                      ; восстановить caller B после failed recovery
                scf
                ret
.range          scf                             ; LBA вне тома — карту не трогаем вообще
                ret

; Один физический CMD17 без retry. Публичный sd_read_sector хранит LBA в sd_lba,
; поэтому повтор использует тот же адрес и тот же IX.
sd_read_sector_once:
                push    ix
                pop     hl                      ; HL = buffer
                call    sd_cmd17                ; CF=1 transport/ready error; Z=1 только при R1=#00
                jr      c,.err
                jr      nz,.err                 ; любой ненулевой R1 — отказ команды, не ждать token
                call    sd_wait_token
                jr      c,.err
                call    sd_reads                ; прочитать 512 bytes -> (HL), HL += 512
                if SD_CRC_CHECK
                ; Карта шлёт data-CRC16 (старший байт первым). Захватить и сверить.
                in      a,(SD_DATA) : ld (sd_rx_crc_hi),a
                in      a,(SD_DATA) : ld (sd_rx_crc_lo),a
                push    ix : pop de             ; DE = начало 512-байтного буфера (IX не клобан)
                call    sd_crc16_512            ; HL = вычисленный CRC16-CCITT
                ld      a,(sd_rx_crc_hi) : cp h : jr nz,.crc_bad
                ld      a,(sd_rx_crc_lo) : cp l : jr nz,.crc_bad
                else
                in      a,(SD_DATA)             ; CRC16 lo (ignored)
                in      a,(SD_DATA)             ; CRC16 hi (ignored)
                endif
                call    sd_csh
                or      a                       ; CF=0
                ret
                if SD_CRC_CHECK
.crc_bad        ld      hl,(sd_crc_fail) : inc hl : ld (sd_crc_fail),hl  ; диагностика
                jr      .err                    ; csh + scf → ретрай перечитает тихо-битый сектор
                endif
.err            call    sd_csh
                scf
                ret

;--- CMD17 (single-block read). Address берётся из sd_lba.
;    byte addressing (sd_blkt==0): argument = LBA*512 (byte offset).
;    Сохраняет HL (caller buffer pointer). Порт DSDZC CMDz.
sd_cmd17:
                ld      a,SD_CMD17
                call    sd_csh
                call    sd_csl                  ; CF=1, если card не вышла из busy bounded
                jr      c,.not_ready            ; command bytes при busy/timeout вообще не посылать
                push    hl                      ; сохранить buffer pointer
                ld      de,(sd_lba+0)           ; DE = LBA low16
                ld      bc,(sd_lba+2)           ; BC = LBA high16
                ld      l,c
                ld      h,b                     ; HL = high16
                ld      c,a                     ; C = command
                ld      a,(sd_blkt)
                or      a
                jr      nz,.send                ; block addressing -> отправить LBA как есть
                ; byte addressing: [HL:DE] = LBA*512 (x2, затем x256 byte-shift)
                ex      de,hl : add hl,hl
                ex      de,hl : adc hl,hl
                ld      h,l : ld l,d : ld d,e : ld e,a  ; A=sd_blkt=0 here
.send
                ld      a,c                     ; A = command
                ld      bc,SD_DATA
                out     (c),a                   ; command byte
                out     (c),h
                out     (c),l
                out     (c),d
                out     (c),e
                ld      a,#FF
                out     (c),a                   ; CRC (ignored)
                pop     hl                      ; восстановить buffer pointer
                jp      sd_resp
.not_ready      scf                             ; единый transport-error контракт sd_cmd17
                ret

;--- прочитать 512 bytes из data port в (HL); HL продвигается на 512
sd_reads:
                push    bc
                ld      bc,SD_DATA              ; B=0 -> 256 per INIR
                inir
                inir
                pop     bc
                ret

;--- chip select high (deselect) + clock
sd_csh:
                push    bc : push af
                ld      bc,SD_CONF : ld a,%00000011 : out (c),a
                ld      bc,SD_DATA : ld a,#FF : out (c),a
                pop     af : pop bc
                ret

;--- sd_bus_idle: проверенная последовательность раннего SpiBusIdle.
;    Обе CS сняты, затем 16 байтов #FF именно через OUT (не пассивные IN).
;    Сохраняет все рабочие регистры/флаги.
sd_bus_idle:
                push    af : push bc : push de
                ld      bc,SD_CONF
                ld      a,%00000011
                out     (c),a
                ld      bc,SD_DATA
                ld      a,#FF
                ld      d,16
.clk            out     (c),a
                dec     d
                jr      nz,.clk
                ld      bc,SD_CONF
                ld      a,%00000011
                out     (c),a
                pop     de : pop bc : pop af
                ret

;--- sd_probe_ready: legacy primitive — проверить только окончание busy-tail.
;    ВАЖНО: один #FF НЕ доказывает присутствие карты: ровно #FF даёт и MISO,
;    оставшаяся в high-Z/pull-up, когда карта вообще не приняла CMD12. Поэтому
;    итоговый sd_recover использует sd_probe_command, а не этот primitive.
sd_probe_ready:
                call    sd_csl                  ; CF — результат bounded ready wait
                push    af                      ; sd_csh не должен заменить результат probe
                call    sd_csh                  ; снять SD CS и дать завершающий #FF при любом исходе
                pop     af                      ; вернуть caller'у исходный CF ready/timeout
                ret

;--- sd_abort_transfer: аварийный CMD12 без предварительного ожидания ready.
;    Это важно, если прежняя транзакция оборвалась в busy/data state: ожидание
;    перед stop-командой только повторило бы исходный dead state. После command
;    держим SD CS low, отдельно съедаем обязательный stuff byte, bounded R1 и
;    R1b busy tail; фиксированных dummy clocks для R1b недостаточно.
;    Ответ CMD12 advisory: authoritative результат задаёт sd_probe_ready после
;    повторной нормализации шины, поэтому локальные CF/Z здесь не выдаются наружу.
sd_abort_transfer:
                push    af : push bc : push de
                ld      bc,SD_CONF
                ld      a,SD_CS1
                out     (c),a
                ld      bc,SD_DATA
                ld      a,SD_CMD12
                out     (c),a                   ; command byte CMD12, не предваряя sd_wait
                xor     a
                out     (c),a                   ; argument[31:24] = 0
                out     (c),a                   ; argument[23:16] = 0
                out     (c),a                   ; argument[15:8]  = 0
                out     (c),a                   ; argument[7:0]   = 0
                ld      a,#FF
                out     (c),a                   ; CRC
                in      a,(SD_DATA)             ; CMD12 имеет один stuff byte перед R1
                call    sd_resp                 ; bounded синхронизация по R1; значение advisory
                call    sd_wait                 ; R1b: держать CS low до #FF либо bounded timeout
                call    sd_csh                  ; снять SD CS при success и при timeout одинаково
                pop     de : pop bc : pop af
                ret

;--- sd_send_packet_r1: послать готовый 6-byte SPI command packet из (HL).
;    CS опускается НАПРЯМУЮ, без sd_wait: этот helper используется именно тогда,
;    когда карта могла перестать отвечать обычному ready-poll. После передачи
;    sd_resp требует настоящий R1 (bit7=0). CS остаётся low, чтобы caller мог
;    дочитать R3/R7; снять его caller обязан через sd_csh и при success, и error.
;    Выход: CF=0, A=R1; CF=1, если за 10 response bytes карта не ответила.
sd_send_packet_r1:
                ld      bc,SD_CONF
                ld      a,SD_CS1
                out     (c),a
                ld      bc,SD_DATA
                ld      d,6
.packet         ld      a,(hl)
                out     (c),a
                inc     hl
                dec     d
                jr      nz,.packet
                jp      sd_resp

;--- sd_probe_command: command-level proof, что карта действительно жива.
;    CMD58 обязан вернуть R1=#00 и ещё четыре OCR bytes. В отличие от простого
;    busy-poll, плавающая шина #FF здесь даёт CF=1 в sd_resp. Заодно OCR.CCS
;    (bit30 = bit6 первого MSB-first byte) авторитетно восстанавливает sd_blkt:
;    1=SDHC/SDXC block addressing, 0=SDSC byte addressing.
sd_probe_command:
                ld      hl,sd_packet_cmd58
                call    sd_send_packet_r1
                jr      c,.fail
                or      a                       ; после recovery карта должна быть transfer-ready (R1=0)
                jr      nz,.fail
                ld      bc,SD_DATA
                in      a,(c)                   ; OCR[31:24], здесь CCS=bit6
                ld      e,a
                in      a,(c)                   ; OCR[23:16]
                in      a,(c)                   ; OCR[15:8]
                in      a,(c)                   ; OCR[7:0]
                bit     7,e                     ; OCR.POWER_UP_STATUS обязан быть 1 при R1=#00
                jr      z,.fail                 ; сплошные #00 — stuck-low MISO, а не живая ready-карта
                xor     a
                bit     6,e
                jr      z,.store_mode
                inc     a
.store_mode     ld      (sd_blkt),a
                call    sd_csh
                or      a                       ; CF=0: есть настоящий R1 и полный OCR
                ret
.fail           call    sd_csh
                scf
                ret

;--- sd_full_init: bounded SPI re-initialization после ignored CMD12/CMD58.
;    Это аварийный tier, а не обычный путь каждого сектора:
;      CMD0 -> CMD8 -> (CMD55,ACMD41)* -> CMD58 -> [CMD16 для SDSC].
;    Он нужен, когда карта вышла из command state: idle clocks/CMD12 могут быть
;    полностью проигнорированы, а pull-up всё равно показывает ложный #FF.
;    sd_init_left ограничивает и CMD0, и ACMD41 loops; бесконечно здесь не висим.
;    CF=0 success + sd_blkt из OCR.CCS, CF=1 no-response/timeout/bad echo.
sd_full_init:
                call    sd_bus_idle              ; >=128 clocks с CS high (spec требует >=74 перед CMD0)
                ld      hl,32
                ld      (sd_init_left),hl
.cmd0_try       ld      hl,sd_packet_cmd0
                call    sd_send_packet_r1
                jr      c,.cmd0_next
                cp      1                       ; R1_IDLE_STATE — карта вошла в SPI mode
                jr      z,.cmd0_ok
.cmd0_next      call    sd_csh
                call    sd_init_count_down
                jr      nz,.cmd0_try
                scf
                ret
.cmd0_ok        call    sd_csh

                ; SD v2 отвечает R7=#000001AA. Старые SDSC законно возвращают
                ; R1=#05 (IDLE|ILLEGAL_COMMAND); им ACMD41 посылается без HCS.
                ld      hl,sd_packet_cmd8
                call    sd_send_packet_r1
                jp      c,.fail_selected        ; полный init длиннее JR range; CS всё ещё low
                cp      1
                jr      z,.cmd8_v2
                bit     2,a                     ; ILLEGAL_COMMAND -> SD v1 legacy path
                jr      z,.fail_selected
                xor     a
                ld      (sd_init_hcs),a
                call    sd_csh
                jr      .acmd_begin
.cmd8_v2        ld      bc,SD_DATA
                in      a,(c)                   ; R7[31:24]
                in      a,(c)                   ; R7[23:16]
                in      a,(c)                   ; R7[15:8] должен быть #01
                ld      e,a
                in      a,(c)                   ; R7[7:0] должен быть #AA
                ld      d,a
                call    sd_csh
                ld      a,e
                cp      #01
                jr      nz,.fail
                ld      a,d
                cp      #AA
                jr      nz,.fail
                ld      a,#40                   ; HCS = argument bit30 для SDHC/SDXC
                ld      (sd_init_hcs),a

.acmd_begin     ld      hl,0                    ; 65536 bounded pairs ~= long emergency timeout
                ld      (sd_init_left),hl
.acmd_try       ld      hl,sd_packet_cmd55
                call    sd_send_packet_r1
                jr      c,.acmd_retry_selected
                cp      2                       ; допустимы R1=#01 idle и редкий #00 ready
                jr      nc,.acmd_retry_selected
                call    sd_csh

                ld      a,(sd_init_hcs)
                or      a
                ld      hl,sd_packet_acmd41_v1
                jr      z,.acmd_send
                ld      hl,sd_packet_acmd41_hcs
.acmd_send      call    sd_send_packet_r1
                jr      c,.acmd_retry_selected
                or      a
                jr      z,.acmd_ready            ; R1=#00: initialization finished
                cp      1
                jr      nz,.acmd_retry_selected  ; иной R1 — retry bounded, затем fail
.acmd_retry_selected:
                call    sd_csh
                call    sd_init_count_down
                jr      nz,.acmd_try
                scf
                ret

.acmd_ready     call    sd_csh
                call    sd_probe_command         ; CMD58 + OCR.CCS; также требует реальный R1
                ret     c
                ld      a,(sd_blkt)
                or      a
                ret     nz                       ; SDHC/SDXC: block length фиксирован 512

                ; SDSC использует byte addressing; явно зафиксировать 512-byte block.
                ld      hl,sd_packet_cmd16_512
                call    sd_send_packet_r1
                jr      c,.fail_selected
                or      a
                jr      nz,.fail_selected
                call    sd_csh
                or      a
                ret
.fail_selected  call    sd_csh
.fail           scf
                ret

; Уменьшить 16-bit emergency timeout. Z=1 только после исчерпания всех попыток.
sd_init_count_down:
                ld      hl,(sd_init_left)
                dec     hl
                ld      (sd_init_left),hl
                ld      a,h
                or      l
                ret

;--- sd_recover: восстановление ПОСЛЕ фактической ошибки CMD17/token/CRC.
;    CMD12 здесь безусловный: ответ #FF не доказывает, что старый transfer закрыт
;    (это может быть промежуток между data-token). CF задаёт финальный ready probe.
;    sd_probe_command/full init заново получают sd_blkt из OCR.CCS: после reset
;    старое значение нельзя просто сохранить, но та же карта вернёт тот же mode.
sd_recover:
                call    sd_bus_idle             ; снять FT/SD CS и выдать стандартные idle clocks
                call    sd_abort_transfer       ; оборвать transfer без ненадёжного pre-probe по #FF
                call    sd_bus_idle             ; после advisory CMD12 снова начать с чистой шины
                call    sd_probe_command        ; CF=0 только после реального R1+OCR, не pull-up #FF
                ret     nc
                jp      sd_full_init             ; ignored CMD12/probe -> один bounded полный re-init

;--- sd_session_recover: сильная граница новой PAK/SD-session.
;    В отличие от mid-sector sd_recover, CMD12 здесь обязателен даже при видимом
;    #FF: между data tokens незавершённого CMD18 карта тоже может вернуть #FF.
;    CMD12 безопасно посылается с argument=0, затем authoritative ready probe.
sd_session_recover:
                jp      sd_recover              ; тот же strong recovery; sd_init уже выставил bootstrap mode

;--- chip select low (select) + clock, затем wait ready
sd_csl:
                push    bc : push af
                ld      bc,SD_CONF : ld a,SD_CS1 : out (c),a
                ld      bc,SD_DATA : ld a,#FF : out (c),a
                pop     af : pop bc
                jp      sd_wait

;--- ждать, пока card вернёт #FF (ready), BOUNDED.
;    CF=0 ready, CF=1 timeout. A и остальные регистры сохранены, чтобы sd_cmd17
;    не потерял command byte через sd_csl.
sd_wait:
                push    bc : push de : push af
                ld      bc,SD_DATA
                ld      de,0                    ; 65536 polls then give up
.w              in      a,(c) : inc a : jr z,.ready  ; #FF -> ready
                dec     de : ld a,d : or e : jr nz,.w
.timeout        pop     af : pop de : pop bc
                scf
                ret
.ready          pop     af : pop de : pop bc
                or      a                       ; CF=0, исходный A сохранён
                ret

;--- ждать data token #FE с bounded timeout.
;    Выход: CF=0 token получен, CF=1 timeout/error token.
;    Старые 4*256 polls на 14 МГц давали лишь ~3-4 мс: нормальная SD могла
;    законно задержать read token дольше и сама запускала ложный recovery.
;    Полный 16-bit countdown даёт порядка сотен мс (только при медленной/error
;    карте); обычный token приходит сразу и цена штатного чтения не меняется.
sd_wait_token:
                push    bc
                ld      bc,SD_DATA
                ld      de,0                    ; 65536 polls, затем clean CF=1
.poll           in      a,(c)
                cp      #FE
                jr      z,.ok
                bit     7,a
                jr      z,.err                  ; data error token (0xxxxxxx)
                dec     de
                ld      a,d
                or      e
                jr      nz,.poll
.err            pop     bc
                scf
                ret
.ok             pop     bc
                or      a
                ret

;--- 16 idle clocks #FF через OUT. Оставлено как самостоятельный primitive для
;    совместимости со старым именем; основной recovery использует sd_bus_idle.
sd_snb:
                push    bc : push af
                ld      b,16
.s              ld      a,#FF : out (SD_DATA),a : djnz .s
                pop     af : pop bc
                ret

;--- прочитать R1 response (bit7=0), до 10 попыток.
;    CF=1 — response не пришёл; CF=0 — A=R1, Z=1 только для обязательного R1=#00.
sd_resp:
                push    de : push bc
                ld      bc,SD_DATA
                ld      d,10
.r              in      a,(c) : bit 7,a : jr z,.got
                dec     d : jr nz,.r
.timeout        pop     bc : pop de
                scf                             ; десять #FF/no-response: transport error
                ret
.got            pop     bc : pop de
                or      a                       ; CF=0; Z=1 только если R1 ровно #00
                ret

;--- sd_lba_in_range: проверка sd_lba против верхней границы тома sd_lba_max.
;    Выход: CF=1 — отвергнуть (sd_lba >= sd_lba_max); CF=0 — ок ИЛИ защита выключена.
;    sd_lba_max==0 => защита выключена (до парса BPB, для bootstrap-чтений).
;    Сохраняет HL/DE/BC; клобает A/флаги (результат — в CF).
sd_lba_in_range:
                push    hl : push de : push bc
                ld      a,(sd_lba_max+0)        ; sd_lba_max == 0 ?
                ld      b,a
                ld      a,(sd_lba_max+1) : or b : ld b,a
                ld      a,(sd_lba_max+2) : or b : ld b,a
                ld      a,(sd_lba_max+3) : or b
                jr      z,.disabled             ; все нули -> защита выключена
                ld      hl,sd_lba
                ld      de,sd_lba_max
                or      a                       ; CF=0 перед многобайтовым вычитанием
                ld      b,4
.cmp            ld      a,(de)                  ; sd_lba - sd_lba_max побайтно (LE)
                ld      c,a
                ld      a,(hl)
                sbc     a,c
                inc     hl
                inc     de
                djnz    .cmp                    ; INC/DJNZ не трогают CF -> заём проходит насквозь
                ccf                             ; заём(CF=1, sd_lba<max)->0 ок ; CF=0(>=max)->1 отвергнуть
                pop     bc : pop de : pop hl
                ret
.disabled       pop     bc : pop de : pop hl
                or      a                       ; CF=0 (в диапазоне)
                ret

;--- SD state ---
sd_lba          ds      4
sd_blkt         db      0
sd_lba_max      ds      4               ; верхняя граница LBA тома (PartLba+TotSec32); 0=выключено
sd_init_left    dw      0               ; bounded CMD0/ACMD41 emergency loops
sd_init_hcs     db      0               ; #40 для SD v2 HCS argument, 0 для legacy SDSC

; Готовые command packets: command, argument[31:0] big-endian, CRC7 byte.
; После CMD0 CRC отключён картой, но обязательные CMD0/CMD8 используют штатные
; #95/#87; остальным достаточно #FF. Пакеты исключают риск перепутать порядок
; аргументных bytes в редком recovery path.
sd_packet_cmd0:       db SD_CMD0,   #00,#00,#00,#00,#95
sd_packet_cmd8:       db SD_CMD8,   #00,#00,#01,#AA,#87
sd_packet_cmd55:      db SD_CMD55,  #00,#00,#00,#00,#FF
sd_packet_acmd41_v1:  db SD_ACMD41, #00,#00,#00,#00,#FF
sd_packet_acmd41_hcs: db SD_ACMD41, #40,#00,#00,#00,#FF
sd_packet_cmd58:      db SD_CMD58,  #00,#00,#00,#00,#FF
sd_packet_cmd16_512:  db SD_CMD16,  #00,#00,#02,#00,#FF

                if SD_CRC_CHECK
;--- CRC16-CCITT (poly #1021, init #0000) над 512 байтами [DE]. Выход: HL=CRC.
;    Битовый вариант; выполняется на ЗАГРУЗКЕ уровня (не покадрово) → цена приемлема.
;    Клобает AF,BC,DE,HL. (При нужде ускорить — заменить на табличный.)
sd_crc16_512:
                ld      hl,0
                ld      bc,512
.crcbyte        ld      a,(de)
                inc     de
                xor     h
                ld      h,a
                push    bc
                ld      b,8
.crcbit         add     hl,hl
                jr      nc,.crcnob
                ld      a,h : xor #10 : ld h,a
                ld      a,l : xor #21 : ld l,a
.crcnob         djnz    .crcbit
                pop     bc
                dec     bc
                ld      a,b : or c
                jr      nz,.crcbyte
                ret

sd_rx_crc_hi    db      0
sd_rx_crc_lo    db      0
sd_crc_fail     dw      0               ; диагностика: число CRC-несовпадений (для дампа)
                endif
