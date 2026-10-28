; Проверки сохранности данных, перенесённые из WC Improved (v1.11i-2026-10-01).
; Модуль живёт в рабочей странице драйвера (FAT32_LOW_CODE..FAT32_LOW_END): в
; окне кода #4000-#7FFF места под них нет. Ядро и расширение зовут эти
; процедуры напрямую, без шлюза: шлюз драйвера возвращает в HL' и BC' не то,
; что оставила функция, а DIR_GROW отдаёт продолжение поиска свободного
; кластера именно в HL'.
; Время записей по часам не перенесено. С 2026-10-27 сектор FAT общий для
; обхода цепочек и FILEX (FILEX_FAT_VALID). Цепочку корня WC держит в таблице на
; 3 КиБ; здесь таблица на 64 кластера, дальше — обход цепочки (ROOT_MEMBER).
; Сверх WC: цепочка выбранного файла проверяется до первой операции с данными
; (FILE_CHAIN_GUARD), поиск длинного имени проходит позапрошлый сектор целиком,
; том без области данных не монтируется (перепроверка 2026-10-06).

; ---------------------------------------------------------------- поток
; Переход потока LOAD512/SAVE512/LOADNON/LOAD256 к следующему кластеру.
; Вход: DE:HL — текущий кластер. Выход как у GIPAG: Z — следующий кластер
; установлен; NZ, CF=0 — конец цепочки (EOC=#0F); CF=1 — сектор FAT не
; прочитан или ссылка испорчена (ABT=#FE, EOC=#FF). Прежде отказ CURIT не
; проверялся, и GIPAG брал «ссылку» по мусорному указателю.
STREAM_NEXT_CLUSTER:
        CALL @WDOS.CURIT
        JP C,FAT_LINK_ERROR
; HL — запись FAT в SECBU. Ноль в ней — свободный кластер: GIPAG понял бы его
; как корень (0 — вход открытия корня), и чтение файла молча шло бы по
; корневому каталогу, а SAVE512 писал бы в корень. Ноль — порча ссылки. У
; потока файла (FILE_STREAM: READ, WRITE, LOAD256, LOADNON) порча — и ссылка на
; кластер корня (CLASSIFY_FILE_LINK): цепочку проверяют при выборе файла, а FAT
; могли изменить и после — WRITE затирал корень.
STREAM_LINK:
        PUSH HL
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL                                ; DE:HL — ссылка
        LD A,H:OR L:OR D:OR E
        SCF
        JR Z,.done                              ; свободный кластер
        LD A,(FILE_STREAM):OR A                 ; CF=0
        CALL NZ,CLASSIFY_FILE_LINK
.done:
        POP HL
        JP NC,@WDOS.GIPAG
        JP FAT_LINK_ERROR

; ---------------------------------------------------------------- ссылки FAT
; CLASSIFY_FAT_LINK с границей области данных тома (GIPAG и GIPP — через ID 8
; шлюза, DIR_CHAIN, CLASSIFY_DATA). Обычный кластер за концом области данных —
; тоже недопустимая ссылка: последний сектор FAT держит слоты за концом
; данных, и испорченная цепочка вела чтение и запись за границу тома. Граница
; не задана (не больше 2: том не смонтирован) — без проверки. Выход как у
; CLASSIFY_FAT_LINK: CF=1 — недопустимая; Z — EOC; NZ, CF=0 — обычный
; кластер. HL, DE сохраняются (старшая тетрада D сброшена).
CLASSIFY_IN_VOLUME:
        CALL CLASSIFY_FAT_LINK
        RET C                                   ; недопустимая
        RET Z                                   ; EOC
        PUSH HL
        PUSH DE
        LD BC,(FAT_DATA_CLUSTER_LIMIT):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FAT_DATA_CLUSTER_LIMIT+2):SBC HL,BC   ; CF — кластер ниже границы
        POP DE
        POP HL
        JR C,.inside
        PUSH HL                                 ; граница задана?
        LD HL,(FAT_DATA_CLUSTER_LIMIT+2):LD A,H:OR L
        LD HL,(FAT_DATA_CLUSTER_LIMIT):OR H
        JR NZ,.set
        LD A,L:CP 3                             ; CF — не задана
.set:
        POP HL
        JP NC,CLASSIFY_INVALID                  ; за областью данных
.inside:
        XOR A:INC A                             ; обычный: A=1, NZ, CF=0
        RET

; Ссылка освобождаемой цепочки (DLSG): CLASSIFY_IN_VOLUME, и кластер цепочки
; корня недопустим (таблицу корня строит NOTE_FREED_CHAIN в начале DLSG).
; Испорченная запись файла на кластере корня прежде проходила: удаление файла
; освобождало корень, и том терял имена.
CLASSIFY_DATA:
        CALL CLASSIFY_IN_VOLUME
        RET C
        RET Z
        CALL ROOT_MEMBER
        JP NZ,CLASSIFY_ORDINARY
        JP CLASSIFY_INVALID

; Ссылка при обходе цепочки файла (поток файла, APPEND_READ_FAT_LINK,
; FILEX_NEXT_CLUSTER): CLASSIFY_IN_VOLUME, и кластер цепочки корня недопустим.
; Цепочку проверяют при выборе файла (FILE_CHAIN_GUARD), а FAT могли изменить
; и после: дозапись, WRITE и WRITE_AT писали бы в корень. Корень не прочитался
; — тоже недопустима. Выход как у CLASSIFY_IN_VOLUME; HL, DE сохраняются.
CLASSIFY_FILE_LINK:
        CALL CLASSIFY_IN_VOLUME
        RET C
        RET Z
        PUSH HL
        PUSH DE
        CALL ROOT_SETUP
        POP DE
        POP HL
        CALL ROOT_MEMBER
        JP NZ,CLASSIFY_ORDINARY
        JP CLASSIFY_INVALID

; Z — DE:HL равен первому кластеру корня BROOTC. HL, DE сохраняются; портит
; A и BC.
IS_ROOT_START:
        PUSH HL
        LD BC,(@WDOS.BROOTC):OR A:SBC HL,BC
        JR NZ,.done
        LD HL,(@WDOS.BROOTC+2):SBC HL,DE         ; CF=0 после равенства выше
.done:
        POP HL
        RET

; ---------------------------------------------------------------- корень
; Цепочка корня строится один раз на том (ROOT_SETUP при ROOT_READY=0): битовый
; фильтр по младшим 11 битам номеров всех её кластеров (ROOT_FILTER, как в WC)
; и таблица первых ROOT_TABLE_MAX кластеров (ROOT_TABLE). ROOT_READY сбрасывают
; монтирование (LOAD_FREE_HINT) и продление каталога (DIR_GROW); иначе цепочка
; корня не меняется: DLSG её кластеров не освобождает. Сектор FAT для этого
; читается в LOBU2 со своей меткой (ROOT_FAT_VALUE), SECBU не трогается: DLSG
; держит там несохранённую правку. Корень длиннее таблицы проверяется дальше
; обходом цепочки — только для кластеров, чей бит в фильтре стоит.
ROOT_TABLE_MAX          EQU 64

; Выход: CF=0 — готово; CF=1 — цепочка корня не читается или испорчена
; (ROOT_FAILED: ROOT_MEMBER считает корнем любой кластер; следующая проверка
; строит заново). Разрушает AF, BC, DE, HL.
ROOT_SETUP:
        XOR A
        LD (ROOT_FAT_VALID),A                   ; LOBU2 мог занять чужой
        LD A,(ROOT_READY):OR A:RET NZ           ; уже построено: CF=0
        LD (ROOT_FAILED),A
        LD (ROOT_COUNT),A
        LD HL,ROOT_FILTER
        LD DE,ROOT_FILTER+1
        LD BC,255
        LD (HL),A
        LDIR
        LD BC,4096:LD (ROOT_LEFT),BC
        LD HL,(@WDOS.BROOTC),DE,(@WDOS.BROOTC+2)
        CALL CLASSIFY_IN_VOLUME
        JR C,.failed
        JR Z,.failed
.cluster:
        PUSH HL
        LD HL,(ROOT_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        LD (ROOT_LEFT),HL
        POP HL
        JR C,.failed                            ; длиннее 4096 секторов — цикл
        PUSH HL
        CALL ROOT_BIT
        LD A,(HL):OR B:LD (HL),A                ; бит фильтра
        POP HL
        LD A,(ROOT_COUNT):CP ROOT_TABLE_MAX+1
        JR NC,.next                             ; таблица полна: счёт — «больше»
        INC A:LD (ROOT_COUNT),A
        CP ROOT_TABLE_MAX+1
        JR Z,.next
        DEC A                                   ; место в таблице
        PUSH HL
        LD L,A:LD H,0
        ADD HL,HL:ADD HL,HL
        LD BC,ROOT_TABLE:ADD HL,BC
        LD B,H:LD C,L
        POP HL
        LD A,L:LD (BC),A:INC BC
        LD A,H:LD (BC),A:INC BC
        LD A,E:LD (BC),A:INC BC
        LD A,D:LD (BC),A
.next:
        CALL ROOT_FAT_VALUE                     ; DE:HL — ссылка
        JR C,.failed
        CALL CLASSIFY_IN_VOLUME
        JR C,.failed
        JR NZ,.cluster
        LD A,1:LD (ROOT_READY),A                ; конец цепочки
        OR A                                    ; CF=0
        RET
.failed:
        LD A,1:LD (ROOT_FAILED),A
        XOR A:LD (ROOT_READY),A
        SCF
        RET

; Бит фильтра корня для кластера HL (младшие 11 бит): HL — байт ROOT_FILTER,
; B — маска. DE сохраняется; разрушает AF.
ROOT_BIT:
        LD A,L:AND 7:LD B,A
        LD A,H:AND 7:LD H,A
        SRL H:RR L
        SRL H:RR L
        SRL H:RR L                              ; (кластер & 2047) / 8
        PUSH DE
        LD DE,ROOT_FILTER:ADD HL,DE
        POP DE
        LD A,B
        LD B,1
        OR A:RET Z
.shift:
        SLA B
        DEC A:JR NZ,.shift
        RET

; Z — кластер DE:HL (старшая тетрада D снята) — кластер корня; цепочка корня не
; прочиталась — тоже Z. HL, DE сохраняются; разрушает AF, BC.
ROOT_MEMBER:
        LD A,(ROOT_FAILED):OR A
        JR Z,.filter
        XOR A
        RET
.filter:
        PUSH HL
        CALL ROOT_BIT
        LD A,(HL):AND B
        POP HL
        JR Z,.no                                ; бита нет — не корень
        LD A,(ROOT_COUNT):CP ROOT_TABLE_MAX+1
        JR C,.count
        LD A,ROOT_TABLE_MAX
.count:
        OR A:JR Z,.no
        LD B,A
        PUSH IX
        LD IX,ROOT_TABLE
.next:
        LD A,(IX+0):CP L:JR NZ,.skip
        LD A,(IX+1):CP H:JR NZ,.skip
        LD A,(IX+2):CP E:JR NZ,.skip
        LD A,(IX+3):CP D:JR Z,.found
.skip:
        INC IX:INC IX:INC IX:INC IX
        DJNZ .next
        POP IX
        LD A,(ROOT_COUNT):CP ROOT_TABLE_MAX+1
        JR NC,.walk                             ; корень длиннее таблицы
.no:
        OR 1
        RET
.found:
        POP IX
        RET
; Корень длиннее таблицы: обход его хвоста от последнего кластера таблицы, не
; дальше 4096 секторов. Отказ чтения или порча хвоста — Z (как корень).
.walk:
        LD (ROOT_TARGET),HL
        LD (ROOT_TARGET+2),DE
        PUSH HL
        PUSH DE
        LD HL,4096:LD (ROOT_WALK_LEFT),HL
        LD HL,(ROOT_TABLE+(ROOT_TABLE_MAX-1)*4)
        LD DE,(ROOT_TABLE+(ROOT_TABLE_MAX-1)*4+2)
.step:
        CALL ROOT_FAT_VALUE
        JR C,.walk_yes
        CALL CLASSIFY_IN_VOLUME
        JR C,.walk_yes
        JR Z,.walk_no                           ; конец корня: не нашёлся
        PUSH HL
        LD HL,(ROOT_WALK_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        LD (ROOT_WALK_LEFT),HL
        POP HL
        JR C,.walk_yes                          ; длиннее 4096 секторов — порча
        LD BC,(ROOT_TARGET)
        LD A,L:CP C:JR NZ,.step
        LD A,H:CP B:JR NZ,.step
        LD BC,(ROOT_TARGET+2)
        LD A,E:CP C:JR NZ,.step
        LD A,D:CP B:JR NZ,.step
.walk_yes:
        POP DE
        POP HL
        XOR A
        RET
.walk_no:
        POP DE
        POP HL
        OR 1
        RET

; Значение записи FAT кластера DE:HL через LOBU2 (ROOT_FAT_SECTOR — какой
; сектор там лежит). Выход: DE:HL — значение, CF=0; CF=1 — отказ чтения или
; сектор за FAT. Разрушает AF, BC.
ROOT_FAT_VALUE:
        CALL @WDOS.DEL128                       ; DE:HL — сектор FAT, A — запись
        PUSH AF
        LD A,(ROOT_FAT_VALID):OR A:JR Z,.read
        LD BC,(ROOT_FAT_SECTOR)
        LD A,L:CP C:JR NZ,.read
        LD A,H:CP B:JR NZ,.read
        LD BC,(ROOT_FAT_SECTOR+2)
        LD A,E:CP C:JR NZ,.read
        LD A,D:CP B:JR Z,.cached
.read:
        XOR A:LD (ROOT_FAT_VALID),A
        LD (ROOT_FAT_SECTOR),HL
        LD (ROOT_FAT_SECTOR+2),DE
        CALL FAT_SECTOR_IN_RANGE                ; CF=1 — сектор в FAT
        JR NC,.fail
        CALL POSITION_FAT_READ
        LD HL,@WDOS.LOBU2,A,1
        CALL READ_SECTORS
        JR C,.fail
        LD A,1:LD (ROOT_FAT_VALID),A
.cached:
        POP AF
        LD L,A:LD H,@WDOS.LOBU2/1024
        ADD HL,HL:ADD HL,HL                     ; адрес записи в LOBU2
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL
        OR A
        RET
.fail:
        POP AF
        SCF
        RET

; ---------------------------------------------------------------- файлы
; FILE_CHAIN_CHECK: цепочка файла DE:HL (не 0) до конца: каждый кластер —
; обычный и в томе, не кластер корня, без повторов (алгоритм Брента: «черепаха»
; переносится на кластер с номером шага — степенью двойки, «заяц» идёт по
; цепочке; совпадение — цикл). Z — цела, CHAIN_LAST — её последний кластер;
; NZ — нет, в том числе при отказе чтения FAT. Прежде чтение и запись файла,
; указывающего на кластер корня, шли по корню (SAVE512 затирал его сектор), а
; цикл в цепочке уводил APPEND и FILEX в начало файла и освобождал при усечении
; оставляемые кластеры. Разрушает AF, BC, DE, HL, SECBU, LSTSE и LOBU2.
FILE_CHAIN_CHECK:
        LD (CHAIN_TORTOISE),HL
        LD (CHAIN_TORTOISE+2),DE
        PUSH HL
        PUSH DE
        CALL ROOT_SETUP                         ; отказ — ROOT_MEMBER строг
        LD HL,CHAIN_POWER
        LD B,8
.zero:
        LD (HL),0:INC HL                        ; CHAIN_POWER и CHAIN_LAM
        DJNZ .zero
        LD A,1:LD (CHAIN_POWER),A
        POP DE
        POP HL
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad
        JR Z,.bad                               ; EOC вместо первого кластера
.cluster:                                       ; DE:HL — кластер цепочки
        CALL ROOT_MEMBER
        JR Z,.bad                               ; кластер корня
        LD (CHAIN_LAST),HL
        LD (CHAIN_LAST+2),DE
        CALL CHAIN_VALUE
        JR C,.bad
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad                               ; 0, недопустимая, за томом
        RET Z                                   ; конец цепочки: Z — цела
        PUSH HL
        LD HL,CHAIN_LAM:CALL @WDOS.INC4b
        POP HL
        LD BC,(CHAIN_TORTOISE)
        LD A,L:CP C:JR NZ,.differ
        LD A,H:CP B:JR NZ,.differ
        LD BC,(CHAIN_TORTOISE+2)
        LD A,E:CP C:JR NZ,.differ
        LD A,D:CP B:JR NZ,.differ
.bad:                                           ; цикл или порча
        OR 1
        RET
.differ:
        PUSH HL
        PUSH DE
        LD HL,CHAIN_LAM,DE,CHAIN_POWER,B,4
.same:
        LD A,(DE):CP (HL):JR NZ,.keep
        INC HL:INC DE
        DJNZ .same
        POP DE
        POP HL
        LD (CHAIN_TORTOISE),HL                  ; шаг — степень двойки
        LD (CHAIN_TORTOISE+2),DE
        PUSH HL
        LD HL,CHAIN_POWER
        SLA (HL):INC HL:RL (HL):INC HL:RL (HL):INC HL:RL (HL)
        INC HL                                  ; CHAIN_LAM
        XOR A
        LD (HL),A:INC HL:LD (HL),A:INC HL:LD (HL),A:INC HL:LD (HL),A
        POP HL
        JR .cluster
.keep:
        POP DE
        POP HL
        JR .cluster

; Цепочка выбранного файла (APPEND_ENTRY) — FILE_CHAIN_CHECK один раз на
; выбор. FILE_CHAIN_OK: бит 0 — цепочка проверена, бит 1 — позиция файлового
; потока сохранена (FAT_SEEK_START, public.asm); байт обнуляется при каждом
; новом контексте (TENTRY, мост FILEX, FAT_INVALIDATE, неизвестный исход
; APPEND). Зовут FAT_SEEK_START (FIND, CREATE, возврат к началу файла),
; APPEND_PREPARE и FILEX_LOAD_CONTEXT. Каталог и пустой файл без кластера не
; проверяются: цепочку каталога проверяет DIR_CHAIN, а запись в каталог через
; файловый поток запрещена. Выход: CF=0 — можно; CF=1 — цепочка испорчена
; (ABT=#FE, EOC=#FF). Разрушает AF, BC, DE, HL.
FILE_CHAIN_GUARD:
        LD A,(FILE_CHAIN_OK):AND 1:RET NZ        ; уже проверена: CF=0
        LD A,(APPEND_ENTRY+11):AND #10:JR NZ,.ok
        LD HL,(APPEND_ENTRY+26),DE,(APPEND_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:JR Z,.ok
        CALL FILE_CHAIN_CHECK
        JP NZ,FAT_LINK_ERROR
.ok:
        LD A,(FILE_CHAIN_OK):OR 1:LD (FILE_CHAIN_OK),A
        RET                                     ; OR сбросил CF

; Цепочки двух записей каталога не пересекаются (FILEX MOVE с заменой): HL, DE
; — 32-байтовые записи. Две конечные цепочки FAT с общим кластером дальше идут
; вместе до конца, поэтому пересекаются ровно тогда, когда у них общий
; последний кластер. Прежде замена сравнивала только первые кластеры и
; освобождала общий хвост живого источника. Z — не пересекаются; NZ —
; пересекаются или цепочка испорчена. Разрушает AF, BC, DE, HL.
CHAINS_DISJOINT:
        PUSH DE
        CALL CHAIN_TAIL
        POP BC
        RET NZ
        LD (CHAIN_OTHER),HL
        LD (CHAIN_OTHER+2),DE
        LD A,H:OR L:OR D:OR E:RET Z             ; у первой цепочки нет
        LD H,B:LD L,C
        CALL CHAIN_TAIL
        RET NZ
        LD A,H:OR L:OR D:OR E:RET Z             ; у второй цепочки нет
        LD BC,(CHAIN_OTHER)
        LD A,L:CP C:JR NZ,.differ
        LD A,H:CP B:JR NZ,.differ
        LD BC,(CHAIN_OTHER+2)
        LD A,E:CP C:JR NZ,.differ
        LD A,D:CP B:JR NZ,.differ
        OR 1                                    ; общий хвост
        RET
.differ:
        XOR A
        RET

; Последний кластер цепочки записи каталога HL (FILE_CHAIN_CHECK). Выход: Z,
; DE:HL — последний кластер (0 — цепочки нет); NZ — цепочка испорчена.
CHAIN_TAIL:
        PUSH HL
        LD BC,20:ADD HL,BC
        LD E,(HL):INC HL:LD D,(HL)              ; старшее слово кластера (+20)
        POP HL
        LD BC,26:ADD HL,BC
        LD A,(HL):INC HL:LD H,(HL):LD L,A       ; младшее слово (+26)
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:RET Z
        CALL FILE_CHAIN_CHECK
        RET NZ
        LD HL,(CHAIN_LAST),DE,(CHAIN_LAST+2)
        XOR A
        RET

; ---------------------------------------------------------------- каталоги
; DIR_CHAIN: цепочка каталога DE:HL (0 — корень, BROOTC) конечна и в томе:
; первый кластер — обычный, ссылки допустимы (0 — свободный кластер,
; недопустимые, за областью данных — порча), конец — не дальше 4096 секторов
; (каталог FAT32 — не больше 65536 записей; больше — цикл). В цепочке
; подкаталога нет первого кластера корня. Z — цела; NZ — нет, в том числе
; при отказе чтения FAT. Остаток предела — в DIR_CHAIN_LEFT (для DIR_GROW).
; Замкнутая цепочка каталога вешала перечисление, поиск и создание записи.
; Разрушает AF, BC, DE, HL, SECBU и LSTSE.
DIR_CHAIN:
        LD A,H:OR L:OR D:OR E
        JR NZ,.first
        LD HL,(@WDOS.BROOTC),DE,(@WDOS.BROOTC+2)
.first:
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad
        JR Z,.bad                               ; маркер конца вместо кластера
        LD BC,4096
        LD (DIR_CHAIN_LEFT),BC
        CALL IS_ROOT_START                      ; Z — сам корень
        LD A,0:JR Z,.kind
        PUSH HL
        PUSH DE
        CALL ROOT_SETUP                         ; отказ — ROOT_MEMBER строг
        POP DE
        POP HL
        LD A,1
.kind:
        LD (DIR_CHAIN_SUB),A
.link:
        LD A,(DIR_CHAIN_SUB):OR A
        JR Z,.own
        CALL ROOT_MEMBER
        JR Z,.bad                               ; кластер корня в цепочке подкаталога
.own:
        PUSH HL
        LD HL,(DIR_CHAIN_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        LD (DIR_CHAIN_LEFT),HL
        POP HL
        JR C,.bad                               ; длиннее 4096 секторов — цикл
        CALL CHAIN_VALUE                        ; DE:HL — ссылка
        JR C,.bad
        CALL CLASSIFY_IN_VOLUME
        JR C,.bad                               ; свободный, недопустимый, за томом
        JR NZ,.link
        RET                                     ; конец цепочки: Z
.bad:
        OR 1
        RET

; Значение записи FAT кластера DE:HL. CURIT устанавливает FILEX_FAT_VALID
; после успешного чтения; адаптер снимает метку перед чужим чтением в SECBU,
; любой записью и при ошибке. Сектор сохраняется между вызовами FILEX и
; проверками цепочки. Выход: DE:HL — значение, CF=0; CF=1 — отказ чтения.
; Разрушает AF, AF', BC (DEL128 пользуется альтернативным аккумулятором).
CHAIN_VALUE:
        LD A,(@FILEX_FAT_VALID):OR A
        JR Z,.read
        PUSH DE
        PUSH HL
        CALL @WDOS.DEL128                       ; DE:HL — сектор FAT, A — запись, CF=0
        LD BC,(@WDOS.LSTSE)
        SBC HL,BC
        JR NZ,.other
        EX DE,HL
        LD BC,(@WDOS.LSTSE+2)
        SBC HL,BC
.other:
        POP HL
        POP DE
        JR NZ,.read
        LD L,A:LD H,@WDOS.SECBU/1024
        ADD HL,HL:ADD HL,HL                     ; адрес записи в SECBU
        JR .value
.read:
        CALL @WDOS.CURIT                        ; HL — запись FAT кластера
        RET C
.value:
        LD E,(HL):INC HL:LD D,(HL):INC HL
        LD A,(HL):INC HL:LD H,(HL):LD L,A
        EX DE,HL
        OR A                                    ; CF=0
        RET

; Каталог LSTCAT перед выделением кластеров (MKFILE, MKDIR): испорчен — Z
; не будет, A=#FF, ABT=#FE, ничего не выделено. Иначе запись в каталог всё
; равно отказала бы, а выделенная цепочка осталась бы потерянной.
DIR_CHECK:
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL DIR_CHAIN
        RET Z
        JP RECORD_FAT_LINK_ERROR                ; A=#FF, NZ

; Перечисление каталога LSTCAT (NXTINI): DIR_CHAIN, затем GIPAG, как прежде.
; Испорчен — как отказ GIPAG: ABT=#FE, EOC=#FF, CF=1, и NXTINI не читает.
DIR_LIST_OPEN:
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL DIR_CHAIN
        JP NZ,FAT_LINK_ERROR
        LD HL,@WDOS.LSTCAT
        JP @WDOS.GIPAG

; Поиск (FNDSN) и создание записи (SVHDFL): DIR_CHAIN, затем поток на начало
; каталога: LSTCAT → CUHL/CUDE, TOS; выход CF=0. Испорчен — ABT=#FE, EOC=#FF,
; CF=1: поиск — FIND_IO_ERROR, создание — отказ носителя до любой записи.
DIR_STREAM_OPEN:
        LD HL,(@WDOS.LSTCAT),DE,(@WDOS.LSTCAT+2)
        CALL DIR_CHAIN
        JP NZ,FAT_LINK_ERROR
        LD HL,@WDOS.LSTCAT,DE,@WDOS.CUHL,BC,4:LDIR
        JP @WDOS.TOS

; DIR_GROW (FIIL в SVHDFL): свободного места в каталоге нет. Z — цепочка ещё
; не кончилась (EOC=0): читать дальше. Кончилась — продлить: каталог не
; больше 4096 секторов (запас — DIR_CHAIN_LEFT от проверки в начале SVHDFL,
; каждое продление тратит BSECPC); прежде каталог рос дальше, и после записи
; DIR_CHAIN отвергал его целиком. Затем SRHFCL: кластер найден — NZ, CF=0 и
; регистры SRHFCL, в том числе HL' (продолжение поиска; поэтому без шлюза).
; Полон или нет места — A=16; отказ чтения FAT при поиске — A=#FF; NZ, CF=1.
DIR_GROW:
        LD A,(@WDOS.EOC):OR A:RET Z
        LD HL,(DIR_CHAIN_LEFT)
        LD A,(@WDOS.BSECPC):LD C,A:LD B,0
        OR A:SBC HL,BC
        JR C,.full                              ; каталог уже 4096 секторов
        LD (DIR_CHAIN_LEFT),HL
        CALL @WDOS.SRHFCL
        JR C,.none
        XOR A:LD (ROOT_READY),A                 ; каталог растёт: корень — заново
        OR 1                                    ; NZ, CF=0
        RET
.none:
        LD A,(FREE_SCAN_IO_FAILED):OR A
        LD A,#FF
        JR NZ,.fail
.full:
        LD A,16
.fail:
        OR A
        SCF
        RET

; ---------------------------------------------------------------- выделение
; MKSG с различением отказа: код 16 при отказе чтения FAT во время поиска
; свободного кластера — #FF (отказ носителя, не «нет места»). .result —
; разбор уже полученного итога MKSG (ALLOCATE_FILE).
MKSG_CHECKED:
        CALL @WDOS.MKSG
        RET Z                                   ; цепочка записана
.result:
        PUSH AF
        CP 16:JR NZ,.keep                       ; иной отказ — как есть
        LD A,(FREE_SCAN_IO_FAILED)
        OR A:JR Z,.keep                         ; нехватка места — как есть
        POP AF
        LD A,#FF:OR A                           ; отказ носителя
        SCF
        RET
.keep:
        POP AF
        RET

; CURIT для BUtoFAT (GENFC). При CF=1 — сектор FAT не прочитан либо кластер
; за FAT — прежде указатель HL был мусорным: LDIR правил устаревший SECBU, и
; SAVE_FAT_SECTOR записывал его на место другого сектора FAT, по чужим
; цепочкам. Теперь BUtoFAT сразу выходит с ошибкой (CF=1, NZ, A=#FF).
CURIT_CHECKED:
        CALL @WDOS.CURIT
        RET NC
        POP HL                                  ; возврат в GENFC
        POP HL                                  ; указатель GENBU (PUSH HL в GENFC)
        LD A,#FF
        OR A
        SCF
        RET                                     ; из BUtoFAT

; ---------------------------------------------------------------- имена
; UCHN — принять B знаков UTF-16 записи LFN подряд (LNPARS). HL — младший байт
; очередного знака, DE — выход. CF=1 — все B знаков приняты; CF=0 — отказ UCH
; с его Z/NZ (Z — недопустимый знак, NZ — конец имени), как ждёт SNMX. B=0 на
; обоих выходах: LNPARS берёт BC смещением при B=0.
UCHN:
        CALL UCH_BOUNDED:JR NC,.stop
        DJNZ UCHN
        SCF
        RET
.stop:
        LD B,0
        RET

; UCH с пределом длины: имя собирается в поле вызывающего с CGDE, и в нём 255
; знаков и ноль. Повреждённый каталог с 20 записями LFN по 13 знаков давал
; 260 и писал за это поле; теперь на 255-м знаке имя кончается, как на
; терминаторе UCH (NZ, CF=0).
UCH_BOUNDED:
        PUSH HL
        PUSH DE
        LD HL,(@WDOS.CGDE)
        EX DE,HL
        OR A
        SBC HL,DE                               ; знаков уже в поле
        LD DE,255
        SBC HL,DE                               ; CF=1 — меньше 255
        POP DE
        POP HL
        JP C,@WDOS.UCH
        XOR A:INC A
        RET

; Знак расширения короткого имени для длинного (LONG в ENTREZ). Выход: Z —
; расширение кончается (конец имени, управляющий или недопустимый в 8.3
; знак); NZ — A прописной и годен. Прежде конец имени (0) и управляющие знаки
; проходили в расширение 8.3 — недопустимые в DIR_Name байты.
SFN_EXT_CHAR:
        CALL @WDOS.ACS
        CALL @WDOS.ENCEN:RET Z
        JP @WDOS.SNCEN

; ---------------------------------------------------------------- записи
; Смещение короткой записи в её секторе. Вход: BC — запись в LOBU/LOBU2
; (после SRHDRN). Выход: CF=0, HL — смещение 0..511; CF=1 — BC не указывает
; на начало записи в этих буферах. Портит A.
ENTRY_OFFSET:
        LD A,C:AND #1F:JR NZ,.no
        LD A,B:SUB high @WDOS.LOBU:CP 4:JR NC,.no
        AND 1:LD H,A,L,C                        ; AND сбросил CF
        RET
.no:
        SCF
        RET

; После отказа носителя в SVHDFL — легла ли всё же новая запись. Ищется NXTBU
; — [тип, имя, 0] в том виде, в каком его записал SVHDFL; поиск, не прочитавший
; каталог, повторяется (до трёх попыток: прежде второй отказ подряд сразу давал
; «неизвестно»). Выход: CF=1 — неизвестно (поиск не прочитал каталог либо имя
; с чужим кластером); иначе NZ — запись есть и указывает на FCTS (её короткая
; запись — LANDED_LBA, LANDED_OFFSET; #FFFF — место неизвестно), Z — записи
; нет. FCTS сохраняется.
ENTRY_LANDED:
        LD HL,@WDOS.FCTS,DE,LANDED_CLUSTER,BC,4:LDIR
        LD A,3
.search:
        LD (LANDED_LEFT),A
        LD HL,@WDOS.NXTBU
        CALL @WDOS.SRHDRN
        JR NC,.searched
        LD A,(LANDED_LEFT):DEC A
        JR NZ,.search                           ; CF=1 остаётся
.searched:
        PUSH AF,HL,DE
        JR C,.restore
        JR Z,.restore
        LD HL,(@WDOS.LLHL):LD (LANDED_LBA),HL
        LD HL,(@WDOS.LLHL+2):LD (LANDED_LBA+2),HL
        CALL ENTRY_OFFSET                       ; BC — запись после SRHDRN
        JR NC,.offset
        LD HL,#FFFF
.offset:
        LD (LANDED_OFFSET),HL
.restore:
        LD HL,LANDED_CLUSTER,DE,@WDOS.FCTS,BC,4:LDIR
        POP DE,HL,AF
        RET C                                   ; ошибка чтения
        RET Z                                   ; записи нет
        LD BC,(LANDED_CLUSTER):OR A:SBC HL,BC:JR NZ,.foreign
        LD HL,(LANDED_CLUSTER+2):SBC HL,DE:JR NZ,.foreign
        LD A,1:OR A                             ; наша запись: NZ, CF=0
        RET
.foreign:
        SCF
        RET

; Хвост MKFILE: запись в каталог — сразу с атрибутом из запроса CREATE (EFLG;
; прежде ENTREZ оставлял от него только бит каталога, и файл «только для
; чтения» создавался без защиты). Успех — Z, A=0, DE:HL — первый кластер.
; SVHDFL отказал, A — код. Без ошибки носителя (ABT=0) — имя или место, в
; родителе не писали: освободить цепочку (DELCHA). При ошибке носителя сектор
; с записью мог лечь: запись есть с нашим кластером — успех; записи нет —
; освободить (A=#FF); неизвестно — цепочку не трогать (потерянные кластеры
; лучше записи на свободный кластер). Прежде при любом отказе цепочка
; освобождалась и под записью, которая всё же легла.
MKFILE_TAIL:
        LD A,(@WDOS.EFLG)
        LD HL,(@WDOS.CGHL)
        CALL SVHDFL_KEEP_ATTR
        JR Z,.ok
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,B
        JR Z,.drop
        CALL ENTRY_LANDED
        LD A,#FF
        JR C,.keep
        JR Z,.drop
        LD HL,(@WDOS.FCTS),DE,(@WDOS.FCTS+2)
.ok:
        XOR A
        RET
.drop:
        OR A
        JP @WDOS.DELCHA
.keep:
        OR A
        RET

; MKDIR: создать каталог. Вход: HL — имя с нулём. Выход: Z — создан; NZ —
; ошибка, A — код (16 — нет места, 1–4 — имя; #FF — отказ носителя). Прежде
; запись каталога публиковалась в родителе до записи его первого сектора и
; обнуления хвоста кластера: отказ записи тела оставлял каталог, чьё тело —
; старые данные свободного кластера (обрывки записей удалённых файлов), и
; обход или удаление могли освободить по ним чужие цепочки. Теперь тело
; пишется первым; при отказе тела цепочка освобождается.
MKDIR_ENTRY:
        LD (@WDOS.CGHL),HL
        CALL NAME_PRECHECK
        RET NZ
        CALL DIR_CHECK
        RET NZ
        LD HL,0
        LD (@WDOS.SIZIK),HL
        LD (@WDOS.SIZIK+2),HL
        LD A,#10
        LD (@WDOS.EFLG),A
        LD DE,0
        LD HL,512
        CALL MKSG_CHECKED                       ; отказ чтения FAT — #FF, не 16
        RET NZ
        LD HL,@WDOS.FCTS
        CALL @WDOS.GIPAG                        ; поток — на первый сектор каталога
        LD HL,@WDOS.ENTRY                       ; «.»: сам каталог
        LD (HL),"."
        INC HL
        LD (HL),#20
        INC HL
        LD A,32
        LD B,9
        CALL @WDOS.NOPING+1
        LD HL,(@WDOS.CUHL)
        LD (@WDOS.CLSHL),HL
        LD HL,(@WDOS.CUDE)
        LD (@WDOS.CLSDE),HL
        LD HL,@WDOS.ENTRY
        LD DE,@WDOS.LOBU
        LD BC,32
        LDIR
        LD HL,@WDOS.ENTRY+1                     ; «..»: родитель
        LD (HL),"."
        LD HL,(@WDOS.LSTCAT)
        LD (@WDOS.CLSHL),HL
        LD HL,(@WDOS.LSTCAT+2)
        LD (@WDOS.CLSDE),HL
        LD HL,@WDOS.ENTRY
        LD BC,32
        LDIR
        ; Обнуляются 513 байт от LOBU+64: 65 из них заходят в LOBU2, чтобы
        ; ZERO_CLUSTER_TAIL получил непрерывный нулевой сектор от LOBU+64.
        LD H,D
        LD L,E
        INC DE
        LD BC,512
        LD (HL),0
        LDIR
        LD HL,@WDOS.LOBU
        LD A,1
        CALL @WDOS.SAFE_SDDSE
        JR NZ,.io
        LD A,(@WDOS.BSECPC)
        LD HL,@WDOS.LOBU+64
        CALL ZERO_CLUSTER_TAIL
        JR NZ,.io
        LD HL,(@WDOS.CGHL)                      ; тело на месте — теперь запись
        CALL @WDOS.SVHDFL                       ; в родителе (шаблон — ENTRY)
        JR NZ,.parent
.made:
        XOR A
        RET
.io:
        LD A,#FF                                ; отказ носителя, не имя
.drop:
        OR A
        JP @WDOS.DELCHA                         ; DELCHA хранит AF
; SVHDFL отказал. Без ошибки носителя — это имя или место: в родителе ничего
; не писали, цепочку освободить. При ошибке носителя сектор с записью мог
; лечь: есть с нашим кластером — каталог создан; поиск прошёл и не нашёл —
; освободить; иначе — цепочка остаётся, отказ.
.parent:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,B
        JR Z,.drop
        CALL ENTRY_LANDED
        JR NC,.known
        LD A,#FF:OR A                           ; неизвестно: цепочку не трогаем
        RET
.known:
        JR NZ,.made                             ; запись легла — каталог создан
        JR .io                                  ; записи нет — освободить

; Имя (CGHL) годно для новой записи — проверка до выделения кластеров и
; записи тела (MKFILE, MKDIR): копия в NXTBU+1 и VALIDATE_NAME, как в ENTREZ.
; Прежде недопустимое имя отвергалось только в SVHDFL: MKDIR успевал записать
; тело каталога в свободный кластер, CREATE — выделить и освободить цепочку.
; Выход: Z — годно; NZ, A=1 — недопустимо.
NAME_PRECHECK:
        LD HL,(@WDOS.CGHL)
        LD DE,@WDOS.NXTBU+1
        LD BC,256
        LDIR
        LD HL,@WDOS.NXTBU+1
        CALL VALIDATE_NAME
        RET Z
        LD A,1
        OR A
        RET

; RENAME: создать запись с новым именем и удалить прежнюю. Вход: HL — [тип,
; старое имя, 0], DE — новое имя с нулём. Выход: NZ — переименовано; Z — нет,
; A — код: 8 — прежней записи нет (либо её поиск не прочитал каталог, CF=1);
; код SVHDFL без отказа носителя (1–4 — имя, 16 — нет места) — новую не
; писали; при отказе носителя — 0 (откат выполнен) либо #FF (исход неизвестен).
; Прежняя не удалилась по имени — переименование доводится: её короткая
; запись помечается #E5 по месту (ENTRY_KILL_AT, с перечитыванием). Не вышло
; и это — удаляется только что созданная (по имени и затем по месту),
; цепочка не освобождается: иначе две записи смотрели бы на одну цепочку, и
; удаление любой из них освободило бы данные другой. Прежде доведения не
; было, а откат делался одной попыткой: второй отказ подряд оставлял обе
; записи. Новая остаётся, только если короткая запись прежней на носителе
; помечена удалённой, либо если после отказа носителя в SVHDFL новая всё же
; легла на цепочку прежней — тогда прежняя удаляется как обычно.
RENAME_ENTRY:
        PUSH HL
        PUSH DE
        CALL @WDOS.SRHDRN
        LD A,8
        LD (@WDOS.FCTS+0),HL
        LD (@WDOS.FCTS+2),DE
        POP HL                                  ; новое имя
        POP DE                                  ; прежний запрос
        RET Z                                   ; прежней записи нет
        CALL RENAME_MARK_OLD                    ; где лежит прежняя SFN (BC — она)
        LD A,(@WDOS.ENTRY+11)                   ; атрибут целиком — ENTREZ его урежет
        PUSH DE
        CALL SVHDFL_KEEP_ATTR                   ; запись с новым именем из ENTRY
        POP HL                                  ; прежний запрос
        JR NZ,.not_created
; Дальше новое имя — только NXTBU: [тип, имя, 0], нормализованный SVHDFL.
.created:
        CALL @WDOS.DELEN
        JR Z,.recheck
.done:
        XOR A
        INC A
        RET                                     ; NZ — переименовано
; DELEN сообщил отказ. Удалять новую запись можно, только если прежняя на
; месте: DELETE_ENTRY_WITH_LFN пишет секторы с LFN раньше сектора SFN, и при
; отказе последнего длинное имя уже стёрто, а короткая запись жива — поиск её
; не находит. Поэтому сектор прежней SFN читается заново: новая запись
; остаётся, только если на месте прежней лежит #E5.
.recheck:
        CALL RENAME_OLD_GONE
        JR Z,.done
        LD HL,(RENAME_OLD_LBA),DE,(RENAME_OLD_LBA+2),BC,(RENAME_OLD_OFFSET)
        CALL ENTRY_KILL_AT                      ; довести: прежняя — #E5 по месту
        JR Z,.done
; Убрать новую: найти (место — LANDED_*), удалить по имени (с длинным именем)
; и убедиться по месту. Цепочку не освобождать.
.undo:
        CALL ENTRY_LANDED
        JR C,.lost                              ; неизвестно, есть ли новая
        JR Z,.rolled                            ; новой нет
        LD HL,@WDOS.NXTBU
        CALL @WDOS.DELEN
        LD HL,(LANDED_LBA),DE,(LANDED_LBA+2),BC,(LANDED_OFFSET)
        CALL ENTRY_KILL_AT
        JR NZ,.lost
.rolled:
        XOR A                                   ; Z, A=0 — не переименовано
        RET
.lost:
        LD A,#FF                                ; исход неизвестен: могут остаться обе
.failed:
        CP A                                    ; Z — не переименовано
        RET
; SVHDFL отказал. Без ошибки носителя — имя занято или недопустимо, места
; нет: новую запись не писали. При ошибке носителя она могла лечь: поиск
; NXTBU; есть с цепочкой прежней — довести переименование; нет — не
; переименовано; неизвестно или чужой кластер — A=#FF.
.not_created:
        LD B,A
        LD A,(@WDOS.ABT):OR A
        LD A,B
        JR Z,.failed
        PUSH HL
        CALL ENTRY_LANDED                       ; FCTS — цепочка прежней
        POP HL
        JR C,.lost
        JR NZ,.created
        JR .failed

; Запомнить место короткой записи прежнего имени: сектор (LLHL) и смещение в
; нём (BC — запись после SRHDRN). Неясный BC — место неизвестно. HL и DE
; сохраняются.
RENAME_MARK_OLD:
        PUSH HL
        CALL .mark
        POP HL
        RET
.mark:
        LD HL,(@WDOS.LLHL)
        LD (RENAME_OLD_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (RENAME_OLD_LBA+2),HL
        CALL ENTRY_OFFSET
        JR NC,.keep
        LD HL,#FFFF                             ; место неизвестно
.keep:
        LD (RENAME_OLD_OFFSET),HL
        RET

; ENTREZ пишет в байт атрибута новой записи только бит каталога: «только
; чтение», «скрытый», «системный» и «архив» переименованного файла терялись, а
; с «только чтением» снималась и защита от FAT_WRITE. RENAME_ENTRY ставит
; RENAME_KEEP, и SVHDFL сразу после ENTREZ возвращает полный атрибут прежней
; записи в короткую запись NXTBM (её FELD и переносит в каталог). Прежде (как в
; WC) атрибут правился отдельной записью уже после удаления прежнего имени, и
; её отказ оставлял файл без «только чтения». Портит A.
SFN_KEEP_ATTR:
        LD A,(RENAME_KEEP):OR A:RET Z
        LD A,(RENAME_ATTR)
        LD (@WDOS.NXTBM+11),A
        LD (@WDOS.ENTRY+11),A
        RET

; SVHDFL с полным атрибутом A в новой короткой записи (CREATE, RENAME, MOVE):
; SFN_KEEP_ATTR вписывает его сразу после ENTREZ, так что запись публикуется с
; ним с первой же записи сектора. Остаются «только чтение», «скрытый»,
; «системный», «каталог», «архив». Выход — флаги и A от SVHDFL.
SVHDFL_KEEP_ATTR:
        AND #37
        LD (RENAME_ATTR),A
        LD A,1:LD (RENAME_KEEP),A
        CALL @WDOS.SVHDFL
        PUSH AF
        XOR A:LD (RENAME_KEEP),A
        POP AF
        RET

; Z — короткая запись прежнего имени на носителе помечена удалённой (#E5).
; NZ — она на месте, её сектор не читается или место неизвестно.
RENAME_OLD_GONE:
        LD A,(RENAME_OLD_OFFSET+1):CP 2:RET NC  ; #FF — место неизвестно, NZ
        LD C,3                                  ; попытки чтения
.read:
        PUSH BC
        LD HL,(RENAME_OLD_LBA),DE,(RENAME_OLD_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        POP BC
        JR Z,.got
        DEC C
        JR NZ,.read
        OR 1                                    ; не читается: NZ
        RET
.got:
        LD HL,@WDOS.LOBU,DE,(RENAME_OLD_OFFSET)
        ADD HL,DE
        LD A,(HL):CP #E5
        RET

; ---------------------------------------------------------------- контекст
; Контекст выбранного файла больше не описывает носитель (исход записи
; неизвестен, откат не удался): снять выбор файла, контекст APPEND и поток
; READ/WRITE — до нового FIND. AF сохраняется.
CONTEXT_FORGET:
        CALL @FILEX_NEW_GENERATION
        PUSH AF
        LD A,(@FAT_SELECTED):LD (FORGOT_SELECTED),A
        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        LD (FILE_CHAIN_OK),A
        LD (@FAT_SELECTED),A
        POP AF
        RET
; Отказ записи оказался легшей записью (усечение в FILEX, перечитано): на
; носителе новая запись, контекст по ней уже взят (FILEX_COMMIT_CONTEXT_DONE) —
; вернуть выбор файла, снятый CONTEXT_FORGET. Поток READ/WRITE закрыт до OPEN,
; как после обычного усечения. Прежде OPEN и APPEND отвечали #F1, а FILEX
; работал: два уровня API расходились.
CONTEXT_RESELECT:
        LD A,(FORGOT_SELECTED):LD (@FAT_SELECTED),A
        RET

; ---------------------------------------------------------------- поток файла
; Позиция открытого файла (FAT_POS: CUHL, CUDE, LTHL, LTDE, NSDC, EOC). Поток
; ядра общий: поиск, создание, дозапись, FILEX и любое чтение FAT (CURIT ставит
; LTHL на сектор FAT) его сдвигают. Прежде READ/WRITE после такой операции
; продолжали чужой поток: SAVE512 писал в каталог или в FAT. Теперь позиция
; ставится перед каждым READ/WRITE/LOAD256/LOADNON (public.asm) и сохраняется
; после; поток открывает FAT_SEEK_START (бит 1 FILE_CHAIN_OK), любой новый
; контекст файла его закрывает.

; Сохранить позицию, не трогая AF и HL результата (выход READ/WRITE).
FAT_STREAM_KEEP:
        PUSH AF
        PUSH HL
        CALL FAT_STREAM_SAVE
        POP HL
        POP AF
; Обмен файла кончился: переходы потока — снова как у каталога. AF сохраняется.
FAT_STREAM_END:
        PUSH AF
        XOR A:LD (FILE_STREAM),A
        POP AF
        RET
; Поток пустого файла: конец цепочки, кластера ещё нет (0).
FAT_STREAM_OPEN_EMPTY:
        LD A,#0F:LD (@WDOS.EOC),A
        LD HL,0
        LD (@WDOS.CUHL),HL
        LD (@WDOS.CUDE),HL
FAT_STREAM_SAVE:
        LD HL,(@WDOS.CUHL):LD (FAT_POS),HL
        LD HL,(@WDOS.CUDE):LD (FAT_POS+2),HL
        LD HL,(@WDOS.LTHL):LD (FAT_POS+4),HL
        LD HL,(@WDOS.LTDE):LD (FAT_POS+6),HL
        LD A,(@WDOS.NSDC):LD (FAT_POS+8),A
        LD A,(@WDOS.EOC):LD (FAT_POS+9),A
        LD A,(FILE_CHAIN_OK):OR 2
        LD (FILE_CHAIN_OK),A
        RET
; Поставить позицию; переходы потока до FAT_STREAM_KEEP — по цепочке файла
; (FILE_STREAM). HL и BC сохраняются (буфер и число секторов). Поток, стоявший
; на конце цепочки (EOC=#0F), продолжается, если файл с тех пор дописали: со
; следующего кластера, а у файла, пустого при открытии (кластер 0), — с его
; нового первого кластера. Прежде READ после дозаписи сразу отвечал «конец»,
; хотя данные уже были. Выход: CF=0 — можно начинать обмен; CF=1 — отказ
; (A=#FF, ABT=#FE), обмена не будет: сектор FAT не прочитан или ссылка
; испорчена (сохранённая позиция остаётся на конце цепочки — повтор возможен),
; либо поток уже остановлен отказом (EOC=#FF). Прежде такой отказ доходил до
; LOAD512, который обнулял ABT, и вызов кончался с A=#FF, но CF=0.
FAT_STREAM_RESTORE:
        LD A,1:LD (FILE_STREAM),A
        LD DE,(FAT_POS):LD (@WDOS.CUHL),DE
        LD DE,(FAT_POS+2):LD (@WDOS.CUDE),DE
        LD DE,(FAT_POS+4):LD (@WDOS.LTHL),DE
        LD DE,(FAT_POS+6):LD (@WDOS.LTDE),DE
        LD A,(FAT_POS+8):LD (@WDOS.NSDC),A
        LD A,(FAT_POS+9):LD (@WDOS.EOC),A
        CP #FF:JR Z,.stopped
        CP #0F:JR Z,.resume
        OR A                                    ; CF=0: поток идёт
        RET
.stopped:
        CALL FAT_LINK_ERROR
        JP FAT_STREAM_END
.resume:
        PUSH HL
        PUSH BC
        LD HL,(FAT_POS),DE,(FAT_POS+2)
        LD A,H:OR L:OR D:OR E:JR NZ,.next
        LD HL,(APPEND_ENTRY+26),DE,(APPEND_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD A,H:OR L:OR D:OR E:JR Z,.done        ; всё ещё пуст
        LD (FAT_POS),HL
        LD (FAT_POS+2),DE
        LD HL,FAT_POS
        CALL @WDOS.GIPAG                        ; начало нового первого кластера
        JR .done
.next:
        CALL STREAM_NEXT_CLUSTER                ; цепочку продлили — следующий
.done:
        POP BC
        POP HL
        RET NC
        JP FAT_STREAM_END                       ; отказ: CF=1
; Выбран файл и открыт его поток (FAT_SEEK_START после выбора).
FAT_REQUIRE_OPEN:
        CALL @FAT_REQUIRE_FILE
        RET C
        LD A,(FILE_CHAIN_OK):AND 2
        RET NZ                                  ; CF=0
        LD A,FAT32_NO_FILE
        JP @FAT_ERROR
; LOAD256 (видеораскладка): каждый сектор — две строки по 256 байт с шагом 512,
; то есть 1024 байта адресов; последняя строка кончается за 256 байт до конца
; размаха. Буфер — от #8000, размах не дальше #10000 (отсюда B ≤ 32). Прежде
; проверялся линейный размер B×512, и данные заходили за #FFFF — в рабочую
; страницу, на код драйвера.
FAT_VIDEO_CHECK:
        CALL FAT_REQUIRE_OPEN
        RET C
        LD A,B:OR A:JP Z,@FAT_BAD_ARGUMENT
        CP 33:JP NC,@FAT_BAD_BUFFER
        LD A,H:CP #80:JP C,@FAT_BAD_BUFFER
        PUSH HL
        LD A,B:ADD A,A:ADD A,A:DEC A
        LD D,A:LD E,0                           ; 1024×B − 256
        ADD HL,DE
        JR NC,.fits
        LD A,H:OR L                             ; ровно до #10000 — можно
        POP HL
        JP NZ,@FAT_BAD_BUFFER
        XOR A
        RET
.fits:
        POP HL
        XOR A
        RET

; ---------------------------------------------------------------- APPEND
; Исход отказа фиксации APPEND. Если отказала запись сектора каталога, он мог
; всё же лечь на носитель: тогда откат отцепил бы и освободил новую цепочку,
; а запись уже показывала бы новый размер (у файла, пустого до дозаписи,
; первый кластер — свободный). Сектор перечитывается. Выход: Z — на носителе
; новая запись, фиксация состоялась; NZ, CF=0 — прежняя запись либо отказ был
; до записи каталога: обычный откат; NZ, CF=1 — не прочитать или ни та ни
; другая: цепочку не трогать (хвост цепочки длиннее размера лучше ссылки на
; свободный кластер).
APPEND_DIR_OUTCOME:
        LD A,(APPEND_DIR_ATTEMPTED):OR A:JR Z,.old
        XOR A:LD (APPEND_DIR_ATTEMPTED),A
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JR NZ,.unknown
        LD HL,@WDOS.LOBU,DE,(APPEND_DIRECTORY_OFFSET)
        ADD HL,DE
        PUSH HL
        LD DE,APPEND_NEW_ENTRY
        CALL .same
        POP HL
        JP Z,APPEND_ENTRY_COMMITTED             ; легла новая запись
        LD DE,APPEND_ENTRY
        CALL .same
        JR Z,.old                               ; на носителе прежняя
.unknown:
        LD A,1:OR A
        SCF
        RET
.old:
        LD A,1:OR A                             ; NZ, CF=0 — откат
        RET
.same:                                          ; Z — 32 байта HL и DE равны
        LD B,32
.byte:
        LD A,(DE):CP (HL):RET NZ
        INC HL:INC DE
        DJNZ .byte
        RET

; ---------------------------------------------------------------- данные
DIR_CHAIN_LEFT:         DS 2
DIR_CHAIN_SUB:          DS 1
FREE_SCAN_IO_FAILED:    DS 1
RENAME_OLD_LBA:         DS 4
RENAME_OLD_OFFSET:      DS 2
LANDED_CLUSTER:         DS 4
LANDED_LEFT:            DS 1
LANDED_LBA:             DS 4
LANDED_OFFSET:          DS 2
APPEND_DIR_ATTEMPTED:   DS 1
APPEND_NEW_ENTRY:       DS 32
RENAME_ATTR:            DS 1
RENAME_KEEP:            DS 1
ROOT_READY:             DS 1
CHAIN_LAST:             DS 4
CHAIN_OTHER:            DS 4
ROOT_FILTER:            DS 256
FAT_POS:                DS 10
GEO_TOTAL:              DS 4
ROOT_FAILED:            DS 1
ROOT_COUNT:             DS 1
ROOT_LEFT:              DS 2
ROOT_WALK_LEFT:         DS 2
ROOT_TARGET:            DS 4
ROOT_FAT_VALID:         DS 1
ROOT_FAT_SECTOR:        DS 4
FILE_CHAIN_OK:          DS 1
CHAIN_TORTOISE:         DS 4
CHAIN_POWER:            DS 4                    ; CHAIN_LAM — сразу за ним
CHAIN_LAM:              DS 4
FILE_STREAM:            DS 1
FORGOT_SELECTED:        DS 1
ROOT_TABLE:             DS ROOT_TABLE_MAX*4
