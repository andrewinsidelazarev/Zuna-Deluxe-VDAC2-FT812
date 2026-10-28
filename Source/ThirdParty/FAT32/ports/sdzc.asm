; SD/MMC через Z-Controller: секторный обмен по портам #57/#77 без DMA.
; Используется тот же интерфейс, что в WC; зависимости от страниц WC нет.
; Все ожидания ограничены. Код работает при сохранённых приложением банках.
        DEVICE ZXSPECTRUM128
        ORG #3900
PORT_TABLE:
        DW SD_INIT,SD_READ,SD_WRITE,SD_SYNC
; #3908: 1 — проверять CRC16 прочитанных секторов (по умолчанию), 0 — нет
; (сверка — около 40 тысяч тактов на сектор; для приложений, которым скорость
; важнее).
SD_CRC_CHECK:
        DB 1
SD_DATA EQU #0057
SD_CONF EQU #0077
SD_ERROR_TIMEOUT EQU #E1
SD_ERROR_REPLY   EQU #E2
SD_ERROR_RANGE   EQU #E3
SD_ERROR_CRC     EQU #E4

SD_INIT:
        OR A
        LD A,1
        JR Z,.unit
        LD A,11
.unit:
        LD (SD_SELECT+1),A
        XOR A
        LD (SD_BLOCK_ADDRESS),A
        LD (SD_V2),A
        LD (SD_MMC),A
        CALL SD_DESELECT
        LD BC,SD_DATA,DE,80
.clock:
        LD A,#FF
        OUT (C),A
        DEC DE
        LD A,D:OR E
        JR NZ,.clock
        LD HL,256
        LD (SD_RETRIES),HL
.idle:
        LD A,0,DE,0,HL,0
        CALL SD_COMMAND
        CP 1
        JR Z,.version
        CALL SD_RETRY
        JR NZ,.idle
        JP SD_TIMEOUT
.version:
        LD A,8,DE,0,HL,#01AA
        CALL SD_COMMAND
        JP C,SD_FAILED
        BIT 2,A
        JR NZ,.old_card
        CP 1
        JP NZ,SD_BAD_REPLY
        LD BC,SD_DATA
        IN A,(C)
        IN A,(C)
        IN H,(C)
        IN L,(C)
        LD DE,#01AA
        OR A:SBC HL,DE
        JP NZ,SD_BAD_REPLY
        LD A,1
        LD (SD_V2),A
.old_card:
        LD HL,8000
        LD (SD_RETRIES),HL
.activate:
        LD A,(SD_MMC)
        OR A
        JR NZ,.mmc
        LD A,55,DE,0,HL,0
        CALL SD_COMMAND
        JP C,SD_FAILED
        BIT 2,A
        JR Z,.acmd
        LD A,1
        LD (SD_MMC),A
.mmc:
        LD A,1,DE,0,HL,0
        CALL SD_COMMAND
        JR .activation_reply
.acmd:
        LD A,(SD_V2)
        OR A
        LD DE,0
        JR Z,.argument
        LD D,#40
.argument:
        LD A,41,HL,0
        CALL SD_COMMAND
.activation_reply:
        JP C,SD_FAILED
        OR A
        JR Z,.active
        CP 1
        JP NZ,SD_BAD_REPLY
        CALL SD_RETRY
        JR NZ,.activate
        JP SD_TIMEOUT
.active:
        LD A,(SD_V2)
        OR A
        JR Z,.byte_mode
        LD A,58,DE,0,HL,0
        CALL SD_COMMAND
        JP C,SD_FAILED
        OR A
        JP NZ,SD_BAD_REPLY
        LD BC,SD_DATA
        IN A,(C)
        LD D,A
        IN A,(C)
        IN A,(C)
        IN A,(C)
        BIT 6,D
        JR Z,.byte_mode
        LD A,1
        LD (SD_BLOCK_ADDRESS),A
        JR SD_SUCCESS
.byte_mode:
        LD A,16,DE,0,HL,512
        CALL SD_COMMAND
        JP C,SD_FAILED
        OR A
        JP NZ,SD_BAD_REPLY
        JR SD_SUCCESS

SD_RETRY:
        LD HL,(SD_RETRIES)
        DEC HL
        LD (SD_RETRIES),HL
        LD A,H:OR L
        RET

; На входе DE:HL=LBA, BC=буфер. Для SDSC переводим LBA в байтовый адрес.
SD_ADDRESS:
        LD (SD_BUFFER),BC
        LD A,(SD_BLOCK_ADDRESS)
        OR A
        RET NZ
        LD B,9
.shift:
        ADD HL,HL
        RL E:RL D
        JR C,.range
        DJNZ .shift
        XOR A
        RET
.range:
        LD A,SD_ERROR_RANGE
        SCF
        RET
SD_READ:
        CALL SD_ADDRESS
        RET C
        LD A,17
        CALL SD_COMMAND
        JR C,SD_FAILED
        OR A
        JP NZ,SD_BAD_REPLY
        CALL SD_WAIT_TOKEN
        JR C,SD_FAILED
        CP #FE
        JP NZ,SD_BAD_REPLY
        LD HL,(SD_BUFFER)
        LD BC,SD_DATA
        INIR
        INIR
        IN D,(C)                        ; CRC16 блока от карты
        IN E,(C)
        ; Блок, чья CRC не совпала с данными, — отказ чтения: прежде искажённый
        ; при передаче сектор принимался, и дозапись или правка FAT записывали
        ; его обратно. #FFFF — CRC нет (так отвечает эмулятор Unreal); у
        ; настоящей карты такая CRC — один сектор из 65536.
        LD A,(SD_CRC_CHECK)
        OR A
        JR Z,SD_SUCCESS
        LD A,D:AND E:INC A
        JR Z,SD_SUCCESS
        PUSH DE
        LD HL,(SD_BUFFER)
        CALL SD_CRC
        POP HL
        OR A:SBC HL,DE
        JR Z,SD_SUCCESS
        LD A,SD_ERROR_CRC
        JR SD_FAILED
SD_SUCCESS:
        XOR A
SD_FAILED:
        PUSH AF
        CALL SD_DESELECT
        POP AF
        OR A
        RET
SD_WRITE:
        CALL SD_ADDRESS
        RET C
        LD A,24
        CALL SD_COMMAND
        JR C,SD_FAILED
        OR A
        JR NZ,SD_BAD_REPLY
        LD BC,SD_DATA,A,#FE
        OUT (C),A
        LD HL,(SD_BUFFER)
        OTIR
        OTIR
        LD A,#FF
        OUT (C),A
        OUT (C),A
        CALL SD_WAIT_TOKEN
        JR C,SD_FAILED
        AND #1F
        CP 5
        JR NZ,SD_BAD_REPLY
        CALL SD_WAIT_READY
        JR C,SD_FAILED
        ; «Принято» и конец занятости не подтверждают программирование
        ; сектора: его ошибку карта сообщает только в статусе (CMD13, R2).
        ; Прежде такая запись считалась удачной.
        LD A,13,DE,0,HL,0
        CALL SD_COMMAND
        JR C,SD_FAILED
        LD E,A
        IN A,(C)                        ; второй байт R2
        OR E
        JR NZ,SD_BAD_REPLY
        JR SD_SUCCESS
SD_SYNC:
        CALL SD_SELECT_CARD
        JR C,SD_FAILED
        JR SD_SUCCESS
SD_BAD_REPLY:
        LD A,SD_ERROR_REPLY
        JR SD_FAILED
SD_TIMEOUT:
        LD A,SD_ERROR_TIMEOUT
        JR SD_FAILED

SD_DESELECT:
        LD BC,SD_CONF,A,3
        OUT (C),A
        LD BC,SD_DATA,A,#FF
        OUT (C),A
        RET
SD_SELECT_CARD:
        LD BC,SD_CONF
SD_SELECT:
        LD A,1
        OUT (C),A
        LD BC,SD_DATA,A,#FF
        OUT (C),A
        JP SD_WAIT_READY

; Команда A, аргумент DE:HL. Ответ R1 в A, CF=1 только при тайм-ауте.
SD_COMMAND:
        LD (SD_COMMAND_BYTE),A
        PUSH DE,HL
        CALL SD_DESELECT
        CALL SD_SELECT_CARD
        POP HL,DE
        RET C
        LD BC,SD_DATA
        LD A,(SD_COMMAND_BYTE)
        OR #40
        OUT (C),A
        OUT (C),D
        OUT (C),E
        OUT (C),H
        OUT (C),L
        LD A,(SD_COMMAND_BYTE)
        LD D,#95
        OR A
        JR Z,.crc
        LD D,#87
        CP 8
        JR Z,.crc
        LD D,#FF
.crc:
        OUT (C),D
        LD D,16
.response:
        IN A,(C)
        BIT 7,A
        JR Z,.ready
        DEC D
        JR NZ,.response
        LD A,SD_ERROR_TIMEOUT
        SCF
        RET
.ready:
        OR A
        RET
SD_WAIT_READY:
        LD HL,0
        LD BC,SD_DATA
.loop:
        IN A,(C)
        CP #FF
        JR Z,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.loop
        LD A,SD_ERROR_TIMEOUT
        SCF
        RET
.ready:
        XOR A
        RET
SD_WAIT_TOKEN:
        LD HL,0
        LD BC,SD_DATA
.loop:
        IN A,(C)
        CP #FF
        JR NZ,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.loop
        LD A,SD_ERROR_TIMEOUT
        SCF
        RET
.ready:
        OR A
        RET
; CRC16-CCITT (x^16+x^12+x^5+1, начальное 0) 512 байт по HL — как у
; блока данных SD. Выход: DE. Разрушает AF, BC, HL. Конец буфера — по
; адресу (самоизменение сравнений): младший байт снова прежний, старший +2.
SD_CRC:
        LD A,L
        LD (.lo+1),A
        LD A,H
        ADD A,2
        LD (.hi+1),A
        LD DE,0
        LD B,high SD_CRC_HI
.byte:
        LD A,(HL)
        INC HL
        XOR D
        LD C,A
        LD A,(BC)                       ; старший байт T[i]
        XOR E
        LD D,A
        INC B
        LD A,(BC)                       ; младший байт T[i]
        LD E,A
        DEC B
        LD A,L
.lo:    CP 0
        JR NZ,.byte
        LD A,H
.hi:    CP 0
        JR NZ,.byte
        RET

SD_BUFFER: DS 2
SD_RETRIES: DS 2
SD_BLOCK_ADDRESS: DB 0
SD_V2: DB 0
SD_MMC: DB 0
SD_COMMAND_BYTE: DB 0

; Таблица CRC16 по старшему байту: T[i] = CRC от i<<8 (8 сдвигов), страницы
; старших и младших байтов подряд. Считается ассемблером.
        ALIGN 256
SD_CRC_HI:
CRC_I = 0
        DUP 256
CRC_C = CRC_I << 8
        DUP 8
CRC_C = ((CRC_C << 1) & #FFFF) ^ (((CRC_C >> 15) & 1) * #1021)
        EDUP
        DB CRC_C >> 8
CRC_I = CRC_I + 1
        EDUP
SD_CRC_LO:
CRC_I = 0
        DUP 256
CRC_C = CRC_I << 8
        DUP 8
CRC_C = ((CRC_C << 1) & #FFFF) ^ (((CRC_C >> 15) & 1) * #1021)
        EDUP
        DB CRC_C & #FF
CRC_I = CRC_I + 1
        EDUP
PORT_END:
        ASSERT PORT_END <= #3E00             ; далее отдельный кэш данных FILEX
        SAVEBIN "build/port_sdzc.bin",PORT_TABLE,PORT_END-PORT_TABLE
