; ============================================================================
; fat32_adapter.asm — Клод: переходник между загрузчиком игры и самостоятельным
; FAT32-драйвером (Source/ThirdParty/FAT32, github.com/andrewinsidelazarev/
; FAT32-Driver-ZX-Evolution). Заменяет прежний собственный путь — SD-ZC (sd_zc.asm)
; и разбор MBR/BPB/FAT/каталогов/LFN: карта, том, каталоги и цепочки кластеров
; теперь забота драйвера, игра пользуется только его публичным API
; (include/fat32.inc, include/filex.inc). Данные читаются FILEX READ_AT по
; смещению в файле: драйвер сам держит вехи цепочки и кэш сектора FAT.
;
; Собирается внутри оверлея загрузчика (slot 3, LOADER_OVL_PAGE, ORG #C000).
; Страницы драйвера грузит spgbld из загрузочного SPG; игра их больше не трогает,
; поэтому том, выбранный файл и кэши FILEX живут между сеансами загрузки:
;   FAT_CODE_PAGE — Build/fat32.bin, код драйвера, входы #4000+N*3;
;   FAT_WORK_PAGE — Build/fat32-work.bin, рабочая RAM драйвера, порт SD-ZC с #3900.
;
; На время вызова драйвера (Fat_Api):
;   slot 0 = FAT_WORK_PAGE, slot 1 = FAT_CODE_PAGE;
;   slot 2 = LOADER_OVL_PAGE — второе отображение этого оверлея. Здесь исполняется
;            внутренняя часть переходника, здесь его стек и все буферы, адреса
;            которых получает драйвер: блок FILEX обязан лежать в #8000..#BFFF;
;   slot 3 = страница-приёмник (READ_AT пишет в #C000..#FFFF, NXTETY — запись
;            каталога) или сам оверлей.
; FMADDR на время вызова выключен: окно FM игры (#0000..#0FFF, регистры с #0400)
; пересекается с буферами драйвера (#0000..#1FFF). Прерывания запрещены: вектора
; IM2 и стек игры лежат в Core (slot 1). Порядок тот же, что в HMM2
; (Source/ASM/fat32_pak.asm), но чтение — штатным FILEX READ_AT.
;
; Метки внутренней части (DISP) имеют адреса второго отображения (#8000..#BFFF).
; Внешний код обращается к тем же байтам по адресу + FAT_ALIAS.
; ============================================================================

                include "../ThirdParty/FAT32/include/fat32.inc"
                include "../ThirdParty/FAT32/include/filex.inc"

FAT_CODE_PAGE    EQU #14               ; spgbld: Block = #0000, #14, Build/fat32.bin
FAT_WORK_PAGE    EQU #15               ; spgbld: Block = #0000, #15, Build/fat32-work.bin
FAT_CORE_PAGE    EQU #05               ; Core игры в slot 1 (spgbld: Block = #5C00, #05)
FAT_ALIAS        EQU #4000             ; адрес в окне #C000 = адрес в окне #8000 + #4000
FAT_PORT_TABLE   EQU #3900             ; таблица обработчиков SD-ZC в рабочей странице
FAT_PORT_CRC     EQU #3908             ; байт порта SD-ZC: 1 — сверять CRC16 сектора
; Сверка CRC16 каждого прочитанного сектора стоит около 40 тысяч тактов (чтение в
; 2–3 раза медленнее). Игра карту только читает; прежний загрузчик CRC тоже не
; сверял (SD_CRC_CHECK EQU 0). 1 — включить сверку.
FAT_SD_CRC_CHECK EQU 0
FAT_STACK_SIZE   EQU 512               ; стек драйвера во втором отображении
FAT_NAME_MAX     EQU 64                ; имя для FIND вместе с завершающим нулём

; Какой файл сейчас выбран в драйвере (Fat_OpenId).
FAT_ID_NONE      EQU 0
FAT_ID_LVL       EQU 1
FAT_ID_AUDIO     EQU 2
FAT_ID_SOUND     EQU 3
FAT_ID_MAIN      EQU 4
FAT_ID_BOOT      EQU 5

; FATCALL entry — вызвать вход драйвера entry (адрес из fat32.inc) или внутреннюю
; процедуру переходника. Регистры A, BC, DE, HL уходят драйверу как есть.
                MACRO FATCALL entry
                CALL Fat_Api
                DW   entry
                ENDM

; ----------------------------------------------------------------------------
; Fat_Api — вызвать драйвер; адрес входа — слово сразу после CALL (макрос FATCALL).
; Вход: A, BC, DE, HL — аргументы входа; (Fat_Slot3Page+FAT_ALIAS) — страница для
;       slot 3 на время вызова (после вызова снова LOADER_OVL_PAGE).
;       Slot 0 = TSLibPage, slot 3 = LOADER_OVL_PAGE, FM включён (сеанс ZiFi_Init).
; Выход: AF, BC, DE, HL — как вернул драйвер. IX, IY, альтернативные регистры и
;       slot 2 сохраняются, состояние прерываний восстанавливается.
; ----------------------------------------------------------------------------
Fat_Api:
                LD   (Fat_RegHL + FAT_ALIAS), HL
                LD   (Fat_RegDE + FAT_ALIAS), DE
                LD   (Fat_RegBC + FAT_ALIAS), BC
                LD   (Fat_RegA + FAT_ALIAS), A
                POP  HL                         ; HL -> слово с адресом входа
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                INC  HL
                LD   (Fat_Entry + 1 + FAT_ALIAS), DE
                PUSH HL                         ; возврат — за словом
                PUSH IX
                PUSH IY
                EXX
                PUSH BC
                PUSH DE
                PUSH HL
                EXX
                EX   AF, AF'
                PUSH AF
                EX   AF, AF'
                LD   A, I                       ; P/V = IFF2: были ли разрешены прерывания
                DI
                PUSH AF
                GetPage2
                LD   (Fat_SavedPage2), A
                LD   (Fat_SavedSP), SP
                LD   A, LOADER_OVL_PAGE
                SetPage2_A                      ; второе отображение оверлея в #8000
                JP   Fat_Inner                  ; дальше — код во втором отображении

; Обратный путь из Fat_Inner: страницы 0/1/3 и FMADDR уже игры, исполнение снова
; в окне #C000.
Fat_Return:
                LD   SP, (Fat_SavedSP)
                LD   A, (Fat_SavedPage2)
                SetPage2_A
                POP  AF
                JP   PO, .keepDi                ; прерывания были запрещены
                EI
.keepDi:        EX   AF, AF'
                POP  AF
                EX   AF, AF'
                EXX
                POP  HL
                POP  DE
                POP  BC
                EXX
                POP  IY
                POP  IX
                LD   HL, (Fat_RegAF + FAT_ALIAS)
                PUSH HL
                LD   BC, (Fat_RegBC + FAT_ALIAS)
                LD   DE, (Fat_RegDE + FAT_ALIAS)
                LD   HL, (Fat_RegHL + FAT_ALIAS)
                POP  AF
                RET

Fat_SavedSP:     DEFW 0
Fat_SavedPage2:  DEFB 0
Fat_Ready:       DEFB 0                 ; 1 — порт подключён, карта и том готовы
Fat_OpenId:      DEFB FAT_ID_NONE       ; файл, выбранный сейчас в драйвере
Fat_GameDirValid: DEFB 0                ; 1 — Fat_GameDir найден
Fat_Count:       DEFB 0
Fat_WantId:      DEFB 0
Fat_WantName:    DEFW 0
Fat_ZeroCluster: DEFB 0, 0, 0, 0        ; кластер 0 — корень тома для SET_DIR_CLUSTER

; ----------------------------------------------------------------------------
; Fat_EnsureMounted — подключить порт SD-ZC, инициализировать карту и смонтировать
; FAT32 (MBR/EBR или том от LBA 0). Один раз за запуск игры и заново после любой
; ошибки драйвера (Fat_Fail). Выход: CF=0 — том готов; CF=1 — нет.
; ----------------------------------------------------------------------------
Fat_EnsureMounted:
                LD   A, (Fat_Ready)
                OR   A
                RET  NZ                         ; CF=0: том уже смонтирован
                LD   (Fat_OpenId), A
                LD   HL, FAT_PORT_TABLE
                FATCALL FAT32_BIND              ; A=0: устройство 0, SD1 Z-Controller
                FATCALL Fat_InnerSetCrc
                FATCALL FAT32_DEVICE_INIT
                OR   A
                JR   NZ, Fat_Fail
                FATCALL FAT32_MOUNT
                OR   A
                JR   NZ, Fat_Fail
                LD   A, 1
                LD   (Fat_Ready), A
                XOR  A                          ; CF=0
                RET

; Fat_Fail — ошибка драйвера: следующий сеанс начнёт с полной инициализации карты
; и монтирования, выбранного файла больше нет. Выход: CF=1.
Fat_Fail:
                XOR  A
                LD   (Fat_Ready), A
                LD   (Fat_OpenId), A
                SCF
                RET

; ----------------------------------------------------------------------------
; Fat_FindName — найти запись в текущем каталоге драйвера и выбрать её (FIND).
; Вход: A = #00 — файл, #10 — каталог; HL -> имя (ASCIIZ, CP866, без учёта
; регистра, LFN или 8.3). Выход: CF=1 — ошибка драйвера (Fat_Fail уже вызван);
; CF=0, Z — нет такой записи; CF=0, NZ — найдена, DE:HL = размер.
; ----------------------------------------------------------------------------
Fat_FindName:
                LD   DE, Fat_NameSpec + FAT_ALIAS
                LD   (DE), A
                INC  DE
                LD   B, FAT_NAME_MAX
.copy:          LD   A, (HL)
                LD   (DE), A
                INC  HL
                INC  DE
                OR   A
                JR   Z, .find
                DJNZ .copy
                XOR  A                          ; имя длиннее буфера: «нет такой записи»
                RET
.find:          LD   HL, Fat_NameSpec           ; адрес во втором отображении
                FATCALL FAT32_FIND
                RET  NC
                JP   Fat_Fail

; Z, если DE:HL == EXPECTED_PAK_SIZE (точный размер ZUMALVL.PAK). Разрушает BC.
Fat_CheckPakSize:
                LD   BC, EXPECTED_PAK_SIZE & #FFFF
                OR   A
                SBC  HL, BC
                RET  NZ
                EX   DE, HL
                LD   BC, EXPECTED_PAK_SIZE >> 16
                OR   A
                SBC  HL, BC
                RET

; ----------------------------------------------------------------------------
; Fat_FindGameDir — найти каталог игры: тот, где лежит ZUMALVL.PAK точного размера
; EXPECTED_PAK_SIZE, — как прежде: сначала путь активной панели WC (страница #F7),
; затем обход всего дерева. Один раз за запуск. Выход: CF=0 — Fat_GameDir задан;
; CF=1 — нет.
; ----------------------------------------------------------------------------
Fat_FindGameDir:
                LD   A, (Fat_GameDirValid)
                OR   A
                RET  NZ                         ; CF=0
                CALL Fat_TryWcPath
                JR   NC, .found
                LD   A, (Fat_Ready)
                OR   A
                SCF
                RET  Z                          ; путь WC сорвался ошибкой драйвера
                LD   HL, RAWPAK_NAME_PAK
                LD   A, 1                       ; имя и точный размер
                CALL Fat_DfsFind
                RET  C
                LD   HL, Fat_DfsDir + FAT_ALIAS
                LD   DE, Fat_GameDir + FAT_ALIAS
                LD   BC, 4
                LDIR
.found:         LD   A, 1
                LD   (Fat_GameDirValid), A
                LD   (LevelsMapLoaded), A       ; «LOADING LEVELS...» — только до первого поиска
                OR   A                          ; CF=0
                RET

; Fat_TryWcPath — пройти путь активной панели WC (RawPak_ReadWcPath) от корня
; (FIND каталога + SET_DIR) и проверить в нём ZUMALVL.PAK точного размера.
; Выход: CF=0 — Fat_GameDir задан, ZUMALVL.PAK выбран; CF=1 — пути нет, он
; устарел или файл другой (при ошибке драйвера ещё и Fat_Ready=0).
Fat_TryWcPath:
                CALL RawPak_ReadWcPath          ; CF=1 — путь скопирован в RawPak_WcPathBuf
                CCF
                RET  C
                FATCALL FAT32_SET_ROOT
                OR   A
                JP   NZ, Fat_Fail
                LD   HL, RawPak_WcPathBuf
.next:          LD   A, (HL)
                CP   #FF
                JR   Z, .inDir
                CALL RawPak_CopyWcComponent     ; -> RawPak_TargetName, CF=1 — компонент годен
                CCF
                RET  C
                PUSH HL
                LD   A, #10
                LD   HL, RawPak_TargetName
                CALL Fat_FindName
                JR   C, .popFail
                JR   Z, .popFail                ; каталога нет: путь WC устарел
                FATCALL FAT32_SET_DIR
                POP  HL
                OR   A
                JP   NZ, Fat_Fail
                JR   .next
.popFail:       POP  HL
                SCF
                RET
.inDir:         XOR  A
                LD   HL, RAWPAK_NAME_PAK
                CALL Fat_FindName
                RET  C
                SCF
                RET  Z
                CALL Fat_CheckPakSize
                SCF
                RET  NZ                         ; там другой ZUMALVL.PAK — искать по дереву
                LD   A, FAT_ID_LVL
                LD   (Fat_OpenId), A
                LD   DE, Fat_GameDir            ; TLSTCAT пишет 4 байта по DE
                FATCALL FAT32_GET_DIR_CLUSTER
                OR   A                          ; CF=0
                RET

; ----------------------------------------------------------------------------
; Fat_DfsFind — обход в глубину всего дерева каталогов (стек RawPak_DirStack, как у
; прежнего RawPak_FindByName) в поисках файла. Вход: HL -> имя (ASCIIZ); A = 1 —
; сверять размер с EXPECTED_PAK_SIZE, 0 — только имя. Выход: CF=0 — найден,
; Fat_DfsDir = кластер его каталога (0 — корень); CF=1 — нет или ошибка.
; Записи каталога драйвер (NXTETY) кладёт в ZIFI_BUFFER_PAGE: кластер (4), размер
; (4), дата и время (4), #00 — каталог / #10 — файл, имя (ASCIIZ). Короткие имена
; приходят строчными, сравнение — без учёта регистра латиницы.
; ----------------------------------------------------------------------------
Fat_DfsFind:
                LD   (RawPak_CheckSize), A
                LD   DE, RawPak_TargetName
.cpyt:          LD   A, (HL)
                CALL RawPak_Upcase
                LD   (DE), A
                INC  HL
                INC  DE
                OR   A
                JR   NZ, .cpyt
                LD   (Fat_OpenId), A            ; перечисление снимает выбор файла
                LD   (RawPak_DirStackCnt), A
                LD   HL, Fat_ZeroCluster
                CALL RawPak_DirStackPush
.pop:           CALL RawPak_DirStackPop         ; RawPak_CurClus = каталог; CF=1 — стек пуст
                RET  C
                LD   HL, RawPak_CurClus
                LD   DE, Fat_DfsDir + FAT_ALIAS
                LD   BC, 4
                LDIR
                LD   HL, Fat_DfsDir
                FATCALL FAT32_SET_DIR_CLUSTER   ; GLSTCAT: перечисление с начала каталога
.entry:         LD   A, ZIFI_BUFFER_PAGE
                LD   (Fat_Slot3Page + FAT_ALIAS), A
                LD   DE, #C000                  ; запись — в ZIFI_BUFFER_PAGE через slot 3
                FATCALL FAT32_NEXT_ENTRY
                JR   Z, .pop                    ; каталог кончился (или не прочитан)
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   A, (#8000 + 13)
                CP   '.'
                JR   Z, .entry                  ; «.» и «..»
                LD   A, (#8000 + 12)
                OR   A
                JR   NZ, .file
                LD   HL, #8000                  ; кластер подкаталога
                CALL RawPak_DirStackPush        ; полный стек тихо отбрасывает глубже
                JR   .entry
.file:          LD   HL, #8000 + 13
                LD   DE, RawPak_TargetName
.cmp:           LD   A, (HL)
                CALL RawPak_Upcase
                LD   C, A
                LD   A, (DE)
                CP   C
                JR   NZ, .entry
                OR   A
                JR   Z, .nameOk
                INC  HL
                INC  DE
                JR   .cmp
.nameOk:        LD   A, (RawPak_CheckSize)
                OR   A
                RET  Z                          ; CF=0: совпало имя
                LD   HL, (#8000 + 4)
                LD   DE, (#8000 + 6)
                CALL Fat_CheckPakSize
                JR   NZ, .entry
                RET                             ; CF=0 после SBC с равными

; ----------------------------------------------------------------------------
; Fat_OpenPak — выбрать в драйвере пак игры (FIND), дальше его читает
; Fat_ReadSectors. Поиск как прежде: в каталоге игры (Fat_FindGameDir), иначе по
; имени на всей карте. Тот же файл повторно не ищется: выбор и кэши READ_AT
; (вехи цепочки, сектор FAT) остаются тёплыми между сеансами.
; Вход: A = FAT_ID_*, HL -> имя (ASCIIZ). Выход: CF=0 — выбран; CF=1 — нет/ошибка.
; ----------------------------------------------------------------------------
Fat_OpenPak:
                LD   C, A
                LD   A, (Fat_OpenId)
                CP   C
                RET  Z                          ; CF=0: уже выбран
                LD   A, C
                LD   (Fat_WantId), A
                LD   (Fat_WantName), HL
                CALL Fat_FindGameDir            ; как прежде: без ZUMALVL.PAK паков нет
                RET  C
                LD   HL, Fat_GameDir
                FATCALL FAT32_SET_DIR_CLUSTER
                LD   HL, (Fat_WantName)
                XOR  A
                CALL Fat_FindName
                RET  C
                JR   NZ, .selected
                LD   HL, (Fat_WantName)         ; нет в каталоге игры — по имени на всей карте
                XOR  A
                CALL Fat_DfsFind
                RET  C
                LD   HL, Fat_DfsDir
                FATCALL FAT32_SET_DIR_CLUSTER
                LD   HL, (Fat_WantName)
                XOR  A
                CALL Fat_FindName
                RET  C
                SCF
                RET  Z                          ; перечисление видело файл, FIND — нет
.selected:      LD   A, (Fat_WantId)
                LD   (Fat_OpenId), A
                OR   A                          ; CF=0
                RET

; ----------------------------------------------------------------------------
; Fat_ReadSectors — прочитать B секторов выбранного файла с логического сектора
; RawPak_LogCur (FILEX READ_AT по смещению RawPak_LogCur*512) в страницу C со
; смещения HL. Вход: B = 1..32, HL + B*512 <= #4000.
; Выход: CF=0 — прочитано, RawPak_LogCur += B; CF=1 — ошибка (запрос целиком за
; концом файла, отказ носителя). Последний неполный сектор файла принимается:
; байты за концом файла в буфере не меняются. IX, IY сохраняются.
; ----------------------------------------------------------------------------
Fat_ReadSectors:
                LD   A, B
                LD   (Fat_Count), A
                ADD  A, A                       ; длина = B*512
                LD   (Fat_FxBlock + FILEX_P_LENGTH + 1 + FAT_ALIAS), A
                XOR  A
                LD   (Fat_FxBlock + FILEX_P_LENGTH + FAT_ALIAS), A
                LD   A, C
                LD   (Fat_Slot3Page + FAT_ALIAS), A
                LD   DE, #C000                  ; приёмник на время вызова — slot 3
                ADD  HL, DE
                LD   (Fat_FxBlock + FILEX_P_BUFFER + FAT_ALIAS), HL
                LD   HL, (RawPak_LogCur)        ; смещение = сектор*512
                XOR  A
                LD   (Fat_FxBlock + FILEX_P_OFFSET + FAT_ALIAS), A
                ADD  HL, HL
                LD   (Fat_FxBlock + FILEX_P_OFFSET + 1 + FAT_ALIAS), HL
                RLA                             ; бит 15 сектора -> старший байт смещения
                LD   (Fat_FxBlock + FILEX_P_OFFSET + 3 + FAT_ALIAS), A
                LD   HL, Fat_FxBlock            ; адрес блока во втором отображении
                FATCALL FAT32_FILEX
                OR   A
                JR   Z, .ok
                CP   FILEX_STATUS_EOF
                JP   NZ, Fat_Fail
                LD   HL, (Fat_FxBlock + FILEX_P_RESULT_COUNT + FAT_ALIAS)
                LD   A, H
                OR   L
                JP   Z, Fat_Fail                ; запрос целиком за концом файла
.ok:            LD   A, (Fat_Count)
                LD   E, A
                LD   D, 0
                LD   HL, (RawPak_LogCur)
                ADD  HL, DE
                LD   (RawPak_LogCur), HL
                OR   A                          ; CF=0
                RET

; ============================================================================
; Внутренняя часть: исполняется во втором отображении оверлея (slot 2).
; ============================================================================
                DISP $ - FAT_ALIAS
Fat_Inner:
                LD   SP, Fat_StackTop
                XOR  A
                LD   BC, FMADDR
                OUT  (C), A                     ; FM выкл.: #0000..#1FFF — буферы драйвера
                LD   A, FAT_WORK_PAGE
                LD   B, HIGH PAGE0
                OUT  (C), A
                LD   A, FAT_CODE_PAGE
                LD   B, HIGH PAGE1
                OUT  (C), A
                LD   A, (Fat_Slot3Page)
                LD   B, HIGH PAGE3
                OUT  (C), A
                LD   HL, (Fat_RegHL)
                LD   DE, (Fat_RegDE)
                LD   BC, (Fat_RegBC)
                LD   A, (Fat_RegA)
                CALL Fat_Entry
                LD   (Fat_RegHL), HL
                LD   (Fat_RegDE), DE
                LD   (Fat_RegBC), BC
                PUSH AF
                POP  HL
                LD   (Fat_RegAF), HL
                LD   A, TSLibPage
                LD   BC, PAGE0
                OUT  (C), A
                LD   A, FAT_CORE_PAGE
                LD   B, HIGH PAGE1
                OUT  (C), A
                LD   A, LOADER_OVL_PAGE
                LD   (Fat_Slot3Page), A         ; следующий вызов — без приёмника
                LD   B, HIGH PAGE3
                OUT  (C), A
                LD   A, FM_EN
                LD   B, HIGH FMADDR
                OUT  (C), A                     ; FM игры: окно #0000, регистры #0400
                JP   Fat_Return
Fat_Entry:      JP   0                          ; адрес входа ставит Fat_Api

; Внутренний вход (FATCALL): сверка CRC16 порта SD-ZC по FAT_SD_CRC_CHECK.
; Рабочая страница драйвера в этот момент — slot 0.
Fat_InnerSetCrc:
                LD   A, FAT_SD_CRC_CHECK
                LD   (FAT_PORT_CRC), A
                XOR  A
                RET

Fat_RegAF:       DEFW 0
Fat_RegBC:       DEFW 0
Fat_RegDE:       DEFW 0
Fat_RegHL:       DEFW 0
Fat_RegA:        DEFB 0
Fat_Slot3Page:   DEFB LOADER_OVL_PAGE
Fat_GameDir:     DEFS 4                 ; кластер каталога игры (0 — корень)
Fat_DfsDir:      DEFS 4                 ; кластер каталога, найденного обходом
Fat_NameSpec:    DEFS 1 + FAT_NAME_MAX  ; [#00 файл / #10 каталог, имя, 0] для FIND
; Блок FILEX READ_AT (32 байта, include/filex.inc): смещение, буфер и длину пишет
; Fat_ReadSectors, итог и статус — драйвер.
Fat_FxBlock:     DEFB FILEX_BLOCK_SIZE, FILEX_API_VERSION, FILEX_OP_READ_AT, 0
                 DEFS FILEX_BLOCK_SIZE - 4, 0
Fat_Stack:       DEFS FAT_STACK_SIZE
Fat_StackTop:
                ENT
