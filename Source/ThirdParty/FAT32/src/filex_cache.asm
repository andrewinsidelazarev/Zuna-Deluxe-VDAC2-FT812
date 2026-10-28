; Кэши FILEX живут до следующего поколения тома. Сброс выполняется ДО любой
; записи (включая API 5 и ошибку с неизвестным исходом), при смене устройства,
; монтировании, выборе записи, начале перечисления и отказе носителя.
; Биты годности сбрасываются явно: переполнение поколения не оживляет кэш.
; Все регистры сохраняются: точки вызова включают секторный адаптер и шлюз.
FILEX_NEW_GENERATION:
        PUSH AF: PUSH BC: PUSH HL
        LD HL,FILEX_GENERATION:CALL WDOS.INC4b
        XOR A
        LD (FILEX_CONTEXT_VALID),A
        LD (FILEX_FAT_VALID),A
        LD (FILEX_DATA_VALID),A
        LD (FILEX_POINT_COUNT),A
        LD A,(WDOS_EXT.FILE_CHAIN_OK):AND #FE
        LD (WDOS_EXT.FILE_CHAIN_OK),A           ; позиция потока сохраняется
        POP HL:POP BC:POP AF
        RET

; Запись/отказ может затронуть и цепочку корня. Обычный выбор файла её не
; меняет: таблица корня по-прежнему строится один раз до изменения носителя.
FILEX_MEDIA_CHANGED:
        PUSH AF
        XOR A:LD (WDOS_EXT.ROOT_READY),A
        POP AF
        JP FILEX_NEW_GENERATION

; Общий буфер FAT может занять сырое чтение. Проверка на каждый сектор,
; в том числе при нечётном адресе и многосекторном обмене. Кэш данных тоже
; снимается, если низкоуровневый клиент использовал его RAM как буфер.
FILEX_BUFFER_REUSED:
        PUSH AF: PUSH HL: PUSH DE
        LD A,(BLOCK_VIDEO):CP 2:CALL Z,FILEX_MEDIA_CHANGED
        LD H,B:LD L,C
        LD DE,#2E00:OR A:SBC HL,DE
        LD A,H:CP 4:JR NC,.data
        XOR A:LD (FILEX_FAT_VALID),A
.data:
        LD H,B:LD L,C
        LD DE,#3C00:OR A:SBC HL,DE
        LD A,H:CP 4:JR NC,.done
        XOR A:LD (FILEX_DATA_VALID),A
.done:
        POP DE:POP HL:POP AF
        RET

; Ключ — все 38 байт экспортированного контекста; поколение задаёт срок
; годности. Совпадение позволяет READ_AT не читать каталог. Для операций
; записи FILEX_VERIFY_CONTEXT всегда загружает LOBU: COMMIT меняет этот сектор.
FILEX_VERIFY_CACHED:
        LD A,(FILEX_CONTEXT_VALID):OR A:JR Z,.read
        LD HL,FILEX_CONTEXT,DE,FILEX_CONTEXT_KEY,B,FILEX_CONTEXT_SIZE
        CALL FILEX_CACHE_COMPARE
        JR NZ,.changed
        LD A,(IY+FILEX_P_OPERATION):CP FILEX_OP_READ_AT
        JR NZ,.read
        XOR A:RET
.changed:
        XOR A:LD (FILEX_POINT_COUNT),A
        LD (FILEX_DATA_VALID),A
.read:
        XOR A:LD (FILEX_CONTEXT_VALID),A
        ; Повторная проверка каталога (всегда перед изменением файла) также
        ; требует свежей ссылки FAT: сохраняем прежнюю защиту WRITE_AT от
        ; подмены ссылки после FIND. Тёплый READ_AT сюда не заходит.
        LD (FILEX_FAT_VALID),A
        CALL FILEX_VERIFY_CONTEXT
        RET NZ
        LD HL,FILEX_CONTEXT,DE,FILEX_CONTEXT_KEY,BC,FILEX_CONTEXT_SIZE
        LDIR
        LD A,1:LD (FILEX_CONTEXT_VALID),A
        XOR A:RET

FILEX_CACHE_COMPARE:
        LD A,(DE):CP (HL):RET NZ
        INC HL:INC DE:DJNZ FILEX_CACHE_COMPARE
        RET

; 64 вехи: кластер с порядковым номером 0,64,...,4032. Номер — в файле,
; значения FAT могут быть несмежными. Большие файлы корректны: после таблицы
; обход от последней вехи/позиции. Последняя позиция — 32-битная, без усечения.
; FILEX_POINT_COUNT=0 также снимает последнюю позицию. Ключ задаётся выше.
FILEX_LOCATE_CACHED:
        LD (FILEX_POS_TARGET),HL
        LD (FILEX_POS_TARGET+2),DE
        LD A,(FILEX_POINT_COUNT):OR A:JR NZ,.known
        LD HL,0:LD (FILEX_POS_INDEX),HL:LD (FILEX_POS_INDEX+2),HL
        LD HL,(FILEX_FIRST_CLUSTER),DE,(FILEX_FIRST_CLUSTER+2)
        CALL FILEX_CLASSIFY_LINK
        JP C,.bad:JP Z,.bad
        LD (FILEX_CURRENT_CLUSTER),HL:LD (FILEX_CURRENT_CLUSTER+2),DE
        CALL FILEX_SAVE_POINT
.known:
        ; Последняя позиция подходит только если она не дальше цели.
        CALL FILEX_POS_DISTANCE
        JR NC,.landmark
        LD HL,0:LD (FILEX_POS_INDEX),HL:LD (FILEX_POS_INDEX+2),HL
        LD HL,FILEX_POINTS,DE,FILEX_POS_CLUSTER,BC,4:LDIR
.landmark:
        ; floor(target/64), ограниченное заполненной частью таблицы.
        LD A,(FILEX_POINT_COUNT):DEC A:LD C,A
        LD HL,(FILEX_POS_TARGET+2):LD A,H:OR L:JR NZ,.slot
        LD HL,(FILEX_POS_TARGET)
        DUP 6
        SRL H:RR L
        EDUP
        LD A,H:OR A:JR NZ,.slot
        LD A,L:CP C:JR NC,.slot
        LD C,A
.slot:
        LD L,C:LD H,0
        DUP 6
        ADD HL,HL
        EDUP
        LD DE,(FILEX_POS_INDEX+2):LD A,D:OR E:JR NZ,.start
        LD DE,(FILEX_POS_INDEX):OR A:SBC HL,DE:JR C,.start:JR Z,.start
        ADD HL,DE:LD (FILEX_POS_INDEX),HL
        LD L,C:LD H,0:ADD HL,HL:ADD HL,HL
        LD DE,FILEX_POINTS:ADD HL,DE
        LD DE,FILEX_POS_CLUSTER,BC,4:LDIR
.start:
        LD HL,FILEX_POS_CLUSTER,DE,FILEX_CURRENT_CLUSTER,BC,4:LDIR
.walk:
        CALL FILEX_POS_DISTANCE
        LD HL,(FILEX_CLUSTER_SKIP),DE,(FILEX_CLUSTER_SKIP+2)
        LD A,D:OR E:OR H:OR L:RET Z
        CALL FILEX_NEXT_CLUSTER
        RET NZ
        LD HL,FILEX_POS_INDEX:CALL WDOS.INC4b
        CALL FILEX_SAVE_POINT
        JR .walk
.bad:
        LD A,FILEX_STATUS_FAT:OR A:RET

; Цель минус текущая позиция (CF — цель раньше); сохраняет результат поиска.
FILEX_POS_DISTANCE:
        LD HL,(FILEX_POS_TARGET),DE,(FILEX_POS_INDEX)
        OR A:SBC HL,DE:LD (FILEX_CLUSTER_SKIP),HL
        LD HL,(FILEX_POS_TARGET+2),DE,(FILEX_POS_INDEX+2)
        SBC HL,DE:LD (FILEX_CLUSTER_SKIP+2),HL
        RET

FILEX_SAVE_POINT:
        LD HL,FILEX_CURRENT_CLUSTER,DE,FILEX_POS_CLUSTER,BC,4:LDIR
        LD HL,(FILEX_POS_INDEX+2):LD A,H:OR L:RET NZ
        LD HL,(FILEX_POS_INDEX)
        LD A,L:AND 63:RET NZ
        LD A,H:CP 16:RET NC
        ; Адрес = база + index/16, число заполненных вех = index/64+1.
        DUP 4
        SRL H:RR L
        EDUP
        LD A,L:RRCA:RRCA:INC A
        LD DE,FILEX_POINT_COUNT
        EX DE,HL:CP (HL):JR C,.keep
        LD (HL),A
.keep:
        EX DE,HL
        LD DE,FILEX_POINTS:ADD HL,DE:EX DE,HL
        LD HL,FILEX_CURRENT_CLUSTER,BC,4:LDIR
        RET

; Целый сектор — сразу вызывающему; частичный — через отдельный сектор RAM.
; Попадание проверяется прежде прямого пути, поэтому повторное чтение целого
; уже кэшированного сектора тоже обходится без устройства.
FILEX_READ_CHUNK:
        LD A,(FILEX_DATA_VALID):OR A:JR Z,.miss
        LD HL,FILEX_CURRENT_LBA,DE,FILEX_DATA_LBA,B,4
        CALL FILEX_CACHE_COMPARE
        JR Z,.copy
.miss:
        LD HL,(FILEX_CHUNK):LD DE,512:OR A:SBC HL,DE
        JR NZ,.partial
        ; Последний сектор остаётся в кэше, даже если запрос кончился ровно
        ; на его границе; прямой путь предназначен для середины запроса.
        LD HL,(FILEX_REMAINING):OR A:SBC HL,DE:JR Z,.partial
        LD HL,(FILEX_BUFFER_POINTER)
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,(FILEX_BUFFER_POINTER),DE,512:ADD HL,DE
        LD (FILEX_BUFFER_POINTER),HL
        XOR A:RET
.partial:
        XOR A:LD (FILEX_DATA_VALID),A
        LD HL,FILEX_DATA_BUFFER
        CALL FILEX_READ_ONE
        RET NZ
        LD HL,FILEX_CURRENT_LBA,DE,FILEX_DATA_LBA,BC,4:LDIR
        LD A,1:LD (FILEX_DATA_VALID),A
.copy:
        LD HL,FILEX_DATA_BUFFER,BC,(FILEX_BYTE_OFFSET):ADD HL,BC
        LD DE,(FILEX_BUFFER_POINTER),BC,(FILEX_CHUNK):LDIR
        LD (FILEX_BUFFER_POINTER),DE
        XOR A:RET

FILEX_GENERATION:     DS 4
FILEX_CONTEXT_VALID:  DB 0
FILEX_FAT_VALID:      DB 0
FILEX_DATA_VALID:     DB 0
FILEX_POINT_COUNT:    DB 0
FILEX_CONTEXT_KEY:    DS FILEX_CONTEXT_SIZE
FILEX_DATA_LBA:       DS 4
FILEX_POS_INDEX:      DS 4
FILEX_POS_CLUSTER:    DS 4
FILEX_POS_TARGET:     DS 4

; LOBU2 кончается на #3600, курсоры каталога начинаются с #37F8.
FILEX_POINTS         EQU #3600
FILEX_DATA_BUFFER    EQU #3E00
        ASSERT FILEX_POINTS >= WDOS.LOBE2
        ASSERT FILEX_POINTS+64*4 <= WDOS.CGDE
        ASSERT WDOS.RECCAT+4 <= #3900
        ASSERT FILEX_DATA_BUFFER+512 == #4000

