; Публичные операции самостоятельного драйвера. Адреса обработчиков внутренние.
FAT_NOT_SUPPORTED:
        LD A,FAT32_UNSUPPORTED
FAT_ERROR:
        OR A
        SCF
        RET
FAT_INFO:
        LD A,FAT32_API_VERSION
        LD BC,FAT32_COMMAND_COUNT
        LD DE,CODE_END-FAT32_BASE
        LD HL,FAT_INFORMATION
        OR A
        RET
FAT_INFORMATION:
        DB "FAT32",0,FAT32_API_VERSION
        DW FAT32_BASE,FAT32_COMMAND_COUNT,FAT32_RESERVED_FIRST
FAT_INVALIDATE:
        CALL FILEX_NEW_GENERATION
        XOR A
        LD (FAT_SELECTED),A
        LD (WDOS_EXT.FILE_CHAIN_OK),A
        LD (WDOS_EXT.APPEND_VALID),A
        LD (WDOS_EXT.APPEND_READY),A
        LD (WDOS_EXT.APPEND_LBA_VALID),A
        RET
FAT_REQUIRE_MOUNT:
        LD A,(FAT_MOUNTED)
        OR A
        RET NZ
        LD A,FAT32_NOT_MOUNTED
        JP FAT_ERROR
FAT_REQUIRE_FILE:
        CALL FAT_REQUIRE_MOUNT
        RET C
        LD A,(FAT_SELECTED)
        OR A
        RET NZ
        LD A,FAT32_NO_FILE
        JP FAT_ERROR
FAT_DEVICE_INIT:
        XOR A
        LD (FAT_MOUNTED),A
        LD (BLOCK_READY),A
        CALL FAT_INVALIDATE
        LD A,(BLOCK_BOUND)
        OR A
        JR Z,.unbound
        CALL BLOCK_INIT
        OR A
        JP NZ,FAT_ERROR
        INC A
        LD (BLOCK_READY),A
        XOR A
        RET
.unbound:
        LD A,FAT32_BAD_ARGUMENT
        JP FAT_ERROR
FAT_MOUNT_PREPARE:
        CALL FAT_INVALIDATE
        LD (FAT_MOUNTED),A
        LD (WDOS.ABT),A
        LD A,(BLOCK_READY)
        OR A
        RET NZ
        LD A,FAT32_NOT_MOUNTED
        JP FAT_ERROR
FAT_MOUNT:
        CALL FAT_MOUNT_PREPARE
        RET C
        CALL WDOS.HDD
        JR FAT_MOUNT_FINISH
FAT_MOUNT_AT:
        CALL FAT_MOUNT_PREPARE
        RET C
        PUSH HL
        LD HL,0
        LD (WDOS.EXTVOL),HL
        DEC HL                          ; раздел не задан: границу даёт сам BPB
        LD (WDOS.PARTSZ),HL             ; (#FFFFFFFF)
        LD (WDOS.PARTSZ+2),HL
        POP HL
        XOR A
        LD (WDOS.ZES),A
        CALL WDOS.LDBPB
FAT_MOUNT_FINISH:
        OR A
        JP NZ,FAT_ERROR
        LD A,1
        LD (FAT_MOUNTED),A
        JP FAT_SET_ROOT
FAT_SET_ROOT:
        CALL FAT_REQUIRE_MOUNT
        RET C
        LD HL,0
        LD (WDOS.LSTCAT),HL
        LD (WDOS.LSTCAT+2),HL
        LD (WDOS.CGFL),HL
        JP FAT_INVALIDATE
FAT_SET_DIR:
        CALL FAT_REQUIRE_FILE
        RET C
        LD A,(WDOS_EXT.APPEND_ENTRY+11)
        AND #10
        JR Z,FAT_BAD_ARGUMENT
        LD HL,(WDOS_EXT.APPEND_ENTRY+26)
        LD (WDOS.LSTCAT),HL
        LD HL,(WDOS_EXT.APPEND_ENTRY+20)
        LD (WDOS.LSTCAT+2),HL
        LD HL,0
        LD (WDOS.CGFL),HL
        JP FAT_INVALIDATE
FAT_BAD_ARGUMENT:
        LD A,FAT32_BAD_ARGUMENT
        JP FAT_ERROR
FAT_FIND:
        CALL FAT_REQUIRE_MOUNT
        RET C
        CALL FAT_INVALIDATE
        CALL WDOS.SRHDRN
        JR NZ,.found
        LD A,(WDOS.ABT)
        OR A
        JP NZ,FAT_ERROR
        RET
.found:
        CALL FAT_CAPTURE
        RET C
        LD HL,(WDOS_EXT.APPEND_ENTRY+28)
        LD DE,(WDOS_EXT.APPEND_ENTRY+30)
        LD A,1
        OR A
        RET
FAT_CAPTURE:
        ; SRHDRN возвращает указатель записи каталога в основной паре BC.
        ; Расширение TENTRY ожидает этот указатель в альтернативной паре BC.
        EXX
        LD DE,WDOS.ENTRY
        CALL WDOS.TENTRY
        LD A,(WDOS_EXT.APPEND_VALID)
        LD (FAT_SELECTED),A
        OR A
        JR Z,FAT_BAD_ARGUMENT
FAT_SEEK_START:
        CALL FAT_REQUIRE_FILE
        RET C
        LD A,(WDOS_EXT.FILE_CHAIN_OK):AND #FD     ; поток ещё не открыт
        LD (WDOS_EXT.FILE_CHAIN_OK),A
        LD HL,(WDOS_EXT.APPEND_ENTRY+26)
        LD (FAT_CLUSTER),HL
        LD DE,(WDOS_EXT.APPEND_ENTRY+20)
        LD (FAT_CLUSTER+2),DE
        LD A,D:OR E:OR H:OR L
        JR NZ,.seek
        LD A,(WDOS_EXT.APPEND_ENTRY+11)
        AND #10
        JR NZ,.seek
        ; У пустого файла кластер равен нулю. Старое ядро считает это корнем
        ; каталога; для обычного файла такое толкование недопустимо.
        CALL WDOS_EXT.FAT_STREAM_OPEN_EMPTY
        XOR A
        RET
.seek:
        ; Цепочка файла проверяется до первого чтения или записи: цикл,
        ; кластер корня или выход за том — файл не выбирается (#FE). Прежде
        ; файл на кластере корня читался как корень, а SAVE512 затирал корень.
        CALL WDOS_EXT.FILE_CHAIN_GUARD
        JR C,.corrupt
        LD HL,FAT_CLUSTER
        CALL WDOS.GIPAG
        RET C
        CALL WDOS_EXT.FAT_STREAM_SAVE
        XOR A
        RET
.corrupt:
        CALL FAT_INVALIDATE
        LD A,#FE
        JP FAT_ERROR
FAT_PREPARE_CREATE:
        CALL FAT_INVALIDATE
        PUSH HL
        LD HL,WDOS.ENTRY,DE,WDOS.ENTRY+1,BC,31
        LD (HL),0
        LDIR
        POP HL
        RET
FAT_CREATE:
        CALL FAT_REQUIRE_MOUNT
        RET C
        ; Атрибут файла — «только чтение», «скрытый», «системный», «архив»
        ; (#27). Каталог создаёт MKDIR: прежде бит каталога давал «каталог»,
        ; чьё тело — старые данные свободных кластеров.
        LD A,(HL):AND ~#27:JP NZ,FAT_BAD_ARGUMENT
        CALL FAT_PREPARE_CREATE
        CALL WDOS.MKFILE
        OR A
        JP NZ,FAT_ERROR
        ; Создание не оставляет указатель записи, необходимый APPEND/FILEX.
        ; ENTREZ хранит [тип,имя,0] в NXTBU; найдём зафиксированную запись.
        LD HL,WDOS.NXTBU
        CALL WDOS.SRHDRN
        JP NZ,FAT_CAPTURE
        ; Файл уже создан, а поиск его записи не прочитал каталог: код отказа
        ; носителя (прежде — «неверный аргумент», #F3).
        LD A,(WDOS.ABT)
        OR A
        JP NZ,FAT_ERROR
        JP FAT_BAD_ARGUMENT
FAT_MKDIR:
        CALL FAT_REQUIRE_MOUNT
        RET C
        CALL FAT_PREPARE_CREATE
        CALL WDOS.MKDIR
        OR A
        JP NZ,FAT_ERROR
        JP FAT_INVALIDATE
FAT_DELETE:
        CALL FAT_DOT_GUARD
        RET C
        CALL FAT_INVALIDATE
        CALL WDOS.DELFL
        JR FAT_MUTATION_FINISH
FAT_RENAME:
        CALL FAT_DOT_GUARD
        RET C
        CALL FAT_INVALIDATE
        CALL WDOS.RENAME
FAT_MUTATION_FINISH:
        ; DELEN при ошибке записи возвращает A=0/Z и хранит код в ABT.
        ; Проверяем ABT прежде флагов старого API, иначе получится ложный Z.
        PUSH AF
        LD A,(WDOS.ABT)
        OR A
        JR NZ,.media_error
        POP AF
        JP NZ,FAT_INVALIDATE
        OR A
        JP NZ,FAT_ERROR
        ; A=0 без кода в ABT: RENAME откатил новую запись после отказа
        ; носителя (последующие чтения обнулили ABT) — это отказ носителя.
        LD A,#FF
        JP FAT_ERROR
.media_error:
        POP BC
        JP FAT_ERROR
; Том смонтирован, и имя запроса HL ([флаг, имя, 0]) — не «.» и не «..»:
; служебные записи каталога не удаляются и не переименовываются. Прежде DELETE
; «..» освобождал цепочку родительского каталога, а RENAME ломал ссылку на
; него. CF=1 — отказ (#F0 — не смонтирован, #F3 — служебное имя). HL, DE
; сохраняются.
FAT_DOT_GUARD:
        CALL FAT_REQUIRE_MOUNT
        RET C
        PUSH HL
        INC HL
        LD A,(HL):CP ".":JR NZ,.name
        INC HL
        LD A,(HL):OR A:JR Z,.dot
        CP ".":JR NZ,.name
        INC HL
        LD A,(HL):OR A:JR NZ,.name
.dot:
        POP HL
        JP FAT_BAD_ARGUMENT
.name:
        POP HL
        OR A                            ; CF=0
        RET
FAT_VALIDATE_STREAM:
        CALL WDOS_EXT.FAT_REQUIRE_OPEN
        RET C
        LD A,B:OR A:JP Z,FAT_BAD_ARGUMENT
        LD A,H:CP #80:JR C,FAT_BAD_BUFFER
        PUSH HL
        LD A,B
        LD D,A,E,0
        SLA E:RL D
        JR C,.bad_pop
        ADD HL,DE
        JR NC,.ok_pop
        LD A,H:OR L
        JR NZ,.bad_pop
.ok_pop:
        POP HL
        XOR A
        RET
.bad_pop:
        POP HL
FAT_BAD_BUFFER:
        LD A,FAT32_BAD_BUFFER
        JP FAT_ERROR
FAT_READ:
        CALL FAT_VALIDATE_STREAM
        RET C
        CALL WDOS_EXT.FAT_STREAM_RESTORE
        RET C                           ; отказ продолжения потока: CF=1
        CALL WDOS.LOAD512
        JP WDOS_EXT.FAT_STREAM_KEEP
FAT_WRITE:
        CALL FAT_VALIDATE_STREAM
        RET C
        LD A,(WDOS_EXT.APPEND_ENTRY+11)
        AND #11
        JP NZ,FAT_BAD_ARGUMENT
        CALL WDOS_EXT.FAT_STREAM_RESTORE
        RET C
        CALL WDOS.SAVE512
        JP WDOS_EXT.FAT_STREAM_KEEP
FAT_READ_VIDEO:
        CALL WDOS_EXT.FAT_VIDEO_CHECK   ; 1024 байта адресов на сектор
        RET C
        CALL WDOS_EXT.FAT_STREAM_RESTORE
        RET C
        CALL WDOS.LOAD256
        JP WDOS_EXT.FAT_STREAM_KEEP
FAT_SKIP:
        CALL WDOS_EXT.FAT_REQUIRE_OPEN
        RET C
        LD A,B:OR A:JP Z,FAT_BAD_ARGUMENT
        CALL WDOS_EXT.FAT_STREAM_RESTORE
        RET C
        CALL WDOS.LOADNON
        JP WDOS_EXT.FAT_STREAM_KEEP
FAT_APPEND:
        CALL FAT_REQUIRE_FILE
        RET C
        LD A,H:CP #80
        JP C,FAT_BAD_BUFFER
        JP WDOS.APPEND
FAT_FILEX:
        ; QUERY_CAPS доступен до подключения устройства и монтирования тома.
        LD A,H:CP #80:JP C,FAT_BAD_BUFFER
        CP #C0:JP NC,FAT_BAD_BUFFER
        PUSH HL
        INC HL:INC HL
        LD A,(HL)
        POP HL
        OR A
        JP Z,FILEX_ENTRY
        CALL FAT_REQUIRE_MOUNT
        RET C
        JP FILEX_ENTRY
FAT_SYNC:
        CALL FAT_REQUIRE_MOUNT
        RET C
        CALL BLOCK_SYNC
        OR A
        JP NZ,FAT_ERROR
        RET
FAT_CLOSE:
        CALL FAT_SYNC
        RET C
        JP FAT_INVALIDATE
FAT_MOUNTED: DB 0
FAT_SELECTED: DB 0
FAT_CLUSTER: DS 4
