        MACRO CALL_WDOS_EXTENSION extension_id
        CALL EXTENSION_GATE
        DB extension_id
        ENDM
RMFL2   LD A,L:AND #F0:LD L,A
        LD C,32:ADD HL,BC
        JP NXFL2
NXTETY2

        LD C,A
        XOR A:BIT 7,C:JR Z,$+3:INC A
        LD (BT7+1),A
        XOR A:BIT 4,C:JR Z,$+3:INC A
        LD (BT4+1),A
        XOR A:BIT 3,C:JR Z,$+3:INC A
        LD (BT3+1),A
        XOR A:BIT 2,C:JR Z,$+3:INC A
        LD (BT2+1),A
        LD A,C:AND %00000011
        LD (BT0+1),A

        PUSH DE
        LD A,(CGFL):OR A:CALL Z,NXTINI
        POP DE

        LD HL,NXFF2,(NxMR+1),HL
NXFF2   LD HL,(CGPZ),B,0
NXFL2   LD A,H:CP high NXTBE:JR NC,NXMR
        LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,RMFL2

        LD C,11:ADD HL,BC
        LD A,(HL):BIT 3,A:JR NZ,RMFL2
        EXA
BT0     LD A,0
        OR A:JR Z,BT1
        DEC A:JR NZ,BT01
        EXA:BIT 4,A:JR NZ,RMFL2,Bt1
BT01    EXA:BIT 4,A
DIR_FILTER_REJECT_BRANCH:
        JR Z,RMFL2

Bt1     EXA
BT1     LD C,16-11:ADD HL,BC
BT2     LD A,0:OR A:JR Z,BT3
        LD C,28-16:ADD HL,BC
 DUP 4
         LDI
 EDUP
        LD C,16:SBC HL,BC

BT3     LD A,0:OR A:JR Z,BT4
 DUP 2
         LDI
 EDUP
 DUP 2
         DEC L
 EDUP

BT4     LD A,0:OR A:JR Z,BT8
 DUP 2
         DEC L
 EDUP
 DUP 2
         LDI
 EDUP

BT8     RES 4,L:CALL LNCRC

        EXA:LD (DE),A:INC DE
BT7     LD A,0:OR A:JP Z,NXTE2
        LD A,L:AND #F0:LD L,A
        JP Snm

; Буфер NXTBU пройден: конец цепочки (EOC=#0F) или отказ чтения (#FF) — конец
; перечисления: Z, A=0, как у нулевой записи. Прежде «OR A:RET NZ» отдавал NZ
; без новой записи, и полный каталог от 8 КиБ перечислялся без конца.
NXMR    LD A,(EOC):CP 1:SBC A,A:RET Z

        PUSH DE
        LD HL,NXTBE-#0300
        LD DE,NXTBM-#0300
        LD BC,#0300:LDIR

        LD HL,DE,(CGPZ),HL
        LD B,NXTBZ/2:CALL LOAD512
        LD (HL),0
        POP DE
NxMR    JP 0

RMFL    LD C,32-11:ADD HL,BC:JP NXFL
RMFL1   LD C,32:ADD HL,BC:JP NXFL
NXTETY

        PUSH DE
        LD A,(CGFL):OR A:CALL Z,NXTINI
        POP DE

        LD HL,NXFF,(NxMR+1),HL
NXFF    LD HL,(CGPZ),B,0
NXFL    LD A,H:CP high NXTBE:JR NC,NXMR
        LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,RMFL1

        LD C,11:ADD HL,BC
        LD A,(HL):BIT 3,A:JR NZ,RMFL
        EXA
        LD C,15:ADD HL,BC
 DUP 2
         LDI
 EDUP
        LD C,8:SBC HL,BC
 DUP 2
         LDI
 EDUP
        ADD HL,BC
 DUP 4
         LDI
 EDUP
        LD C,16:SBC HL,BC

 DUP 2
         LDI
 EDUP
 DUP 2
         DEC L
 EDUP

 DUP 2
         DEC L
 EDUP
 DUP 2
         LDI
 EDUP

        RES 4,L:CALL LNCRC

        EXA
        AND #10
        XOR #10:LD (DE),A:INC DE

NXTE2   OR A:LD C,32:SBC HL,BC:JP C,SNM
        LD A,(HL):CP #0F:JP NZ,SNM
        EXA

 DUP 2
         INC L
 EDUP
        CP (HL):JP NZ,SNM2

        LD C,1
        LD (CGHL),HL,(CGDE),DE
        LD A,L:AND #F0:LD L,A

LNPARS  LD A,(HL)
        BIT 6,A:JR Z,$+4:SET 6,C
        CP C:JR NZ,SNM3:INC C

        INC L
        ; 13 знаков записи LFN: 5, пропуск атрибута/типа/суммы, 6, пропуск
        ; кластера, 2. UCHN принимает их через UCH_BOUNDED: имя длиннее 255
        ; знаков (повреждённый каталог) прежде писало за поле вызывающего.
        LD B,5:CALL WDOS_EXT.UCHN:JR NC,SNMX
        INC L:INC L:INC L
        LD B,6:CALL WDOS_EXT.UCHN:JR NC,SNMX
        INC L:INC L
        LD B,2:CALL WDOS_EXT.UCHN:JR NC,SNMX
        DEC L

        LD A,C:CP #40:JR NC,NXLEXI

        OR A:LD C,64-1:SBC HL,BC
        LD C,A:JR C,SNM3
        JR LNPARS

NXLEXI  XOR A:LD (DE),A:INC DE
        LD HL,(CGHL)
        LD C,32+16+3:ADD HL,BC
        LD (CGPZ),HL
Nhdd    XOR A:INC A
        RET

SNMX    JR NZ,NXLEXI
SNM3    LD HL,(CGHL),DE,(CGDE)
SNM2    LD A,L:AND #F0:LD L,A
        LD C,32:JR SNM+2
SNM     LD C,21:ADD HL,BC

Snm     LD B,8
SNA     LD A,(HL)
        CALL Acs:LD (DE),A:INC DE,L
        DJNZ SNA

        LD B,8
SNM_    DEC DE:LD A,(DE)
        CP " ":JR NZ,$+4:DJNZ SNM_
        INC DE

        LD A,L:AND #F0:OR 8:LD L,A
        PUSH DE
        LD A,".",(DE),A:INC DE
SFN_EXTENSION_START:
        LD B,3
SFN_EXTENSION_CHAR:
        LD A,(HL):CALL Acs:LD (DE),A:INC DE,L
        DJNZ SFN_EXTENSION_CHAR
        POP BC
        JR SFN_EXTENSION_TRIM
FIND_IO_ERROR:
        LD A,(FIND_TYPE_MASK+1)
        CP #10
        LD A,#FF
        SCF
        RET
        DS SFN_EXTENSION_START+26-$,0

SFN_EXTENSION_TRIM:
 DUP 3
         DEC DE:LD A,(DE):CP 32:JR NZ,SNm
 EDUP
        LD DE,BC
        JR SNMD
SNm     INC DE

SNMD    XOR A:LD (DE),A:INC DE
        LD BC,21:ADD HL,BC

        LD (CGPZ),HL
        XOR A:INC A
        RET
UCH     INC L
        LD A,(HL):OR A:JR NZ,UCHX
        DEC L:LD A,(HL):INC L,L
        OR A:JR Z,UCHE
        LD (DE),A:INC DE
        CP #80:RET C
UCH_    XOR A:RET
UCh_    INC L:XOR A:RET
UCHE    XOR A:INC A:RET

UCHX    CP 4:JR NZ,UCh_
        DEC L:LD A,(HL):INC L,L
        CP #01:JR Z,HYO
        CP #10:JR C,UCH_
        CP #3F+1:JR C,DGG
        CP #4F+1:JR C,DEE
        CP #51:JR Z,LYO
        XOR A
        RET
DGG     ADD A,#70:LD (DE),A:INC DE
        SCF:RET
DEE     ADD A,#A0:LD (DE),A:INC DE
        SCF:RET
HYO     LD A,#F0,(DE),A:INC DE:SCF:RET
LYO     LD A,#F1,(DE),A:INC DE:SCF:RET
Acs     CP #80:JR NC,RU3
        CP #40+1:RET C
        CP #5B:RET NC
        SET 5,A
        RET
RU3     CP #F0:JR NZ,$+3:INC A
        CP #F1:RET Z
        CP #A0:RET NC
        CP #90:JR NC,RU4
        SET 5,A:RET
RU4     ADD A,#50:RET
LNCRC   XOR A
 DUP 11
         RRCA:ADD A,(HL):INC L
 EDUP
        RET
NXTINI  CALL @FILEX_NEW_GENERATION
        LD HL,1
        LD (CGFL),HL

        ; Цепочка каталога проверяется до перечисления (DIR_LIST_OPEN):
        ; замкнутая или уходящая за том вешала перечисление; испорчена — как
        ; отказ GIPAG (CF=1, ABT=#FE).
        CALL WDOS_EXT.DIR_LIST_OPEN

        LD HL,NXTBU,(CGPZ),HL,B,NXTBZ
        ; Недопустимый первый кластер — не читать: LOAD512 обнулил бы ABT, и
        ; отказ выглядел бы пустым каталогом. Команда LD флагов не меняет.
        CALL NC,LOAD512
        LD (HL),0
        RET

GENTRY
        CALL_WDOS_EXTENSION WDOS_EXT.ID_COPY_TO_ENTRY
        RET
TENTRY
        CALL_WDOS_EXTENSION WDOS_EXT.ID_COPY_ENTRY_AND_CAPTURE
        RET
APPEND  CALL_WDOS_EXTENSION WDOS_EXT.ID_APPEND_BYTES
        RET
        NOP
        NOP
Z0      RET

GLSTCAT
        CALL @FILEX_NEW_GENERATION
        LD DE,LSTCAT,BC,4:LDIR
        LD (CGFL),BC
        RET

TLSTCAT
        LD HL,LSTCAT,BC,4:LDIR
        RET

RDD
        PUSH BC
        CALL XPOZI
        POP HL
        JP SAFE_RDDSE

SDD
        PUSH BC
        CALL XPOZI
        POP HL
        JP SAFE_SDDSE

LOADNON LD DE,Z0
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_WITH_HANDLER
        RET

LOAD256 LD DE,RDD256
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_WITH_HANDLER
        RET

SAVE512 PUSH HL
        LD HL,SAFE_SDDSE
        LD (NW0+1),HL
        POP HL
        JP LOAD512

LOAD512

        XOR A:LD (ABT),A
        CALL LPREX:JR NZ,RH

        LD A,B:CALL NEWCLA

RH      LD HL,(LDHL)
        LD A,(EOC)
        JR C,LOAD512_RESTORE_HANDLER
        OR A
LOAD512_RESTORE_HANDLER:
        JP STREAM_RESTORE_READ_HANDLER

LPREX   LD (LDHL),HL
        LD A,(EOC):OR A:RET NZ
        LD A,(NSDC):OR A:JR NZ,RX

        PUSH BC:LD HL,CUHL:CALL GIPAG
        POP BC
        RET
RX      XOR A
        RET
NEWCLA  LD (BZN),A

NXTC    LD HL,(LTHL),DE,(LTDE):CALL PROZ

        LD HL,BZN
        LD A,(BSECPC),BC,(NSDC)
        SUB C:LD B,A
        LD A,(HL):OR A:RET Z
        SUB B:JR NC,KN
        ADD A,B:LD B,A:XOR A
KN      LD (HL),A

        LD A,B,(NR0),A
        LD HL,(LDHL)
NW0     CALL SAFE_RDDSE
        LD A,(ABT):OR A
        JR Z,LOAD512_IO_OK
        CALL_WDOS_EXTENSION WDOS_EXT.ID_STREAM_IO_ERROR
        RET
LOAD512_IO_OK:
        LD (LDHL),HL

        LD HL,LTHL,DE,LLHL,BC,4:LDIR

        LD HL,(LTHL),DE,(LTDE)
        LD BC,(NR0):ADD HL,BC:JR NC,$+3:INC DE
        LD (LTHL),HL,(LTDE),DE

        LD HL,NSDC,A,C:ADD A,(HL)
        LD (HL),A

        LD BC,(BSECPC)
        CP C:JR C,NXTC

        LD HL,(CUHL),DE,(CUDE)
        ; Отказ CURIT и нулевая ссылка (свободный кластер) — ошибка потока, а
        ; не переход по мусорному указателю или в корневой каталог.
        CALL WDOS_EXT.STREAM_NEXT_CLUSTER:JR Z,NXTC
        RET

SRHFCL  LD HL,FSTFRC,DE,CAHL,BC,4:LDIR
        CALL_WDOS_EXTENSION WDOS_EXT.ID_INIT_FREE_SCAN
SRHFC
        ; Сектор FAT курсора CAHL — через NEXT_FREE_FAT_SECTOR: курсор за
        ; областью данных (испорченная подсказка) — переход к кластеру 2,
        ; отказ чтения FAT запоминается (FREE_SCAN_IO_FAILED).
        CALL WDOS_EXT.NEXT_FREE_FAT_SECTOR
        RET C

; Каждый слот — CHECK_FREE_SCAN_LIMIT: кластер за областью данных тома не
; выдаётся (последний сектор FAT держит слоты за концом данных).
FC      CALL WDOS_EXT.CHECK_FREE_SCAN_LIMIT
        RET C
        LD A,(HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL:JR Z,GETZE

        EX DE,HL
        LD HL,CAHL
        INC (HL):JR NZ,AGA:INC HL
        INC (HL):JR NZ,AGA:INC HL
        INC (HL):JR NZ,AGA:INC HL
        INC (HL)
AGA     EX DE,HL
        LD A,H:CP high SECBE:JR C,FC
        JR SRHFC                        ; следующий сектор FAT
GETZE   EXX
        LD HL,(CAHL),DE,(CADE)
        PUSH HL:LD HL,CAHL:CALL INC4b
        POP HL
        XOR A
        RET

CURIT
        XOR A:LD (@FILEX_FAT_VALID),A
        CALL DEL128
 DUP 2
         SLA C:RL B
 EDUP

        PUSH BC
        LD (LSTSE+2),DE,(LSTSE),HL

        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_SECTOR_IN_RANGE
        JR NC,FATEND
JK      CALL_WDOS_EXTENSION WDOS_EXT.ID_POSITION_FAT_READ
        LD HL,SECBU,A,1
        CALL_WDOS_EXTENSION WDOS_EXT.ID_READ_SECTORS
        JR C,FATEND
        POP BC
        LD HL,SECBU:ADD HL,BC
        LD A,1:LD (@FILEX_FAT_VALID),A
        XOR A
        RET
FATEND  POP BC
        SCF
        RET

GIPAG
        CALL TOS

        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:OR H,E,D:JR Z,RDIR

        EX DE,HL
        CALL WDOS_EXT.CLASSIFY_IN_VOLUME ; кластер за областью данных — порча
        JR NC,GIPAG_LINK_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
GIPAG_LINK_VALID:
        JR Z,MDC
POM     LD (CUHL),HL,(CUDE),DE

        LD BC,2:OR A:SBC HL,BC:JR NC,$+3:DEC DE

        LD A,(BSECPC):CALL UMNOX2
        LD BC,(SDFAT):CALL ADD4B
        EX DE,HL
        LD BC,(SDFAT+2):ADD HL,BC
        EX DE,HL
        CALL XSPOZ
        CALL XPOZI
        XOR A
        RET

RDIR    LD HL,(BROOTC),DE,(BROOTC+2)
        JR POM

MDC     LD A,#0F
        LD (EOC),A
        OR A
        RET

XSPOZ   LD BC,(ADDTOP),(CLHL),BC
        LD BC,(ADDTOP+2),(CLDE),BC
        JP ADD4BF

SVHDFL

        LD A,(EFLG):AND #10
        CALL ENTREZ_ANY_TYPE:RET NZ
        LD (CGDE),HL
        CALL WDOS_EXT.SFN_KEEP_ATTR     ; RENAME: полный атрибут прежней записи

        ; Цепочка каталога проверяется до поиска места (DIR_STREAM_OPEN):
        ; замкнутая вешала создание записи; испорчена — отказ носителя до
        ; любой записи.
SHDFL   CALL WDOS_EXT.DIR_STREAM_OPEN
        JP C,SVHDFL_READ_ERROR
; Отказ чтения сектора каталога прежде не проверялся: свободное место искалось
; в прежнем содержимом LOBU, а EOC=#FF принимался за конец цепочки, и каталог
; продлевался за текущим кластером — ссылка FAT на остаток каталога
; затиралась, записи чужих файлов пропадали. Теперь — выход с ошибкой
; носителя (A=#FF) до любой записи.
NXDCL   LD HL,LOBU,B,1:CALL LOAD512
        JP C,SVHDFL_READ_ERROR
        LD HL,LOBU,DE,32,B,16
        XOR A
FIEL    CP (HL):JP Z,FELD
        ADD HL,DE
        DJNZ FIEL
; Свободного места нет: не конец цепочки — читать дальше; конец — продлить
; каталог (DIR_GROW): не дальше 4096 секторов. Полон или нет места — A=16,
; отказ чтения FAT при поиске — A=#FF. DIR_GROW зовётся без шлюза: шлюз
; разрушил бы HL' — продолжение поиска с записью нового кластера.
FIIL    CALL WDOS_EXT.DIR_GROW
        JR Z,NXDCL
        RET C
        LD (BUTS),HL,(BUTS+2),DE
        EXX
        LD A,#FF
        DEC HL:LD (HL),#0F
        DEC HL:LD (HL),A
        DEC HL:LD (HL),A
        DEC HL:LD (HL),A
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        JR NZ,IEL

; Новый кластер уже занят (EOC), но ещё не в цепочке каталога. Прежде он
; вписывался в цепочку до обнуления: отказ записи нулей оставлял в каталоге
; прежнее содержимое свободного кластера — обрывки записей удалённых файлов
; становились живыми, и удаление по такой записи освобождало цепочку чужого
; файла. Теперь сначала обнуление, потом ссылка: отказ до ссылки — каталог
; прежний, кластер потерян; ссылка легла или нет — кластер пустой. Нули
; пишутся из LOBU (его всё равно перечитывает NXDCL): сектор FAT в SECBU
; затирать незачем. GIPAG меняет CUHL/CUDE — последний кластер каталога в стек.
        LD HL,(CUHL),DE,(CUDE)
        PUSH HL,DE
        LD HL,BUTS
        CALL GIPAG
        JR NZ,SVHDFL_ZERO_IO_ERROR

        LD HL,LOBU,B,0
 DUP 2
         CALL NOPING
 EDUP
        LD HL,LOBU,A,1:CALL SAFE_SDDSE
        JR NZ,SVHDFL_ZERO_IO_ERROR

        LD A,(BSECPC)
        LD HL,LOBU
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ZERO_CLUSTER_TAIL
        JR NZ,SVHDFL_ZERO_IO_ERROR

        POP DE,HL                       ; последний кластер каталога
        CALL CURIT:JR C,IEL
        EX DE,HL
        LD HL,BUTS,BC,4:LDIR
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        JR NZ,IEL

        ; Поток — на начало нового кластера (тот же GIPAG уже прошёл выше).
        LD HL,BUTS
        CALL GIPAG
        JP NXDCL

SVHDFL_ZERO_IO_ERROR:
        POP DE,HL
SVHDFL_READ_ERROR:
        LD A,#FF:OR A:RET               ; отказ носителя

IEL     LD A,16:OR A:RET

FELD    EX DE,HL
        LD HL,(CGDE)
VYG     LD BC,32:LDIR
        LD BC,0-64:ADD HL,BC
        LD A,H:CP high NXTBM:JR C,FFLD

        LD A,E:OR A:JR NZ,VYG
        BIT 0,D:JR NZ,VYG
        LD (CGDE),HL
        CALL FFld
        RET NZ
        JP FIIL

FFLD    XOR A:LD (DE),A
FFld    LD HL,(LLHL),DE,(LLHL+2)
        CALL PROZ
        LD HL,LOBU
        LD A,1:CALL SAFE_SDDSE
        RET NZ

        LD HL,(FCTS),DE,(FCTS+2)
        XOR A
        RET

ENTREZ

        LD DE,NXTBU
        LD BC,255+1
        PUSH DE
        LD (DE),A,(ENTRY+11),A:INC DE
        LDIR
        POP HL
        LD (CGDE),HL
        INC HL:CALL ENVAL:LD A,1:RET NZ

        LD HL,(FCTS),(CLSHL),HL
        LD HL,(FCTS+2),(CLSDE),HL

        LD HL,(CGDE):CALL LNLNGcs
        JP Z,ENnvl
        CALL_WDOS_EXTENSION WDOS_EXT.ID_REFINE_NAME_CLASSIFICATION

        LD B,11,HL,ENTRY
SNCC    LD A,(HL):OR A:JR Z,LONG
        CALL SNCEN:JR Z,LONG
        CALL CAPS_SV:JR Z,LONG
        CALL ACS:LD (HL),A
        INC HL:DJNZ SNCC

        LD HL,ENTRY
        LD DE,NXTBM
        PUSH DE:LD BC,33:LDIR
        LD HL,NXTBU:CALL SRHDRN:LD A,4
        POP HL:RET NZ
        XOR A
        RET
LONG    LD DE,ENTRY

        LD B,8,HL,NXTBU
FO      INC HL:LD A,(HL)
KO      CALL ACS
        CALL ENCEN:JR Z,KZ
        CALL SNCEN:JR NZ,KC
KZ      LD A,R:AND %01111111:JR KO
KC      CP " ":JR NZ,$+4:LD A,"_"
        LD (DE),A:INC DE:DJNZ FO
        PUSH DE:LD B,3:CALL NOP32
        POP DE

        LD HL,NXTBU:BIT 4,(HL):JR NZ,NN
        INC HL
        XOR A:LD BC,256:CPIR:DEC HL

        LD B,4
UR      DEC HL:LD A,(HL)
        OR A:JR Z,NN
        CP ".":JR Z,NB
        DJNZ UR:JR NN

NB      LD B,3
Nb      INC HL:LD A,(HL)
        CALL WDOS_EXT.SFN_EXT_CHAR:JR Z,NN
        LD (DE),A:INC DE:DJNZ Nb
NN      LD HL,ENTRY,DE,NXTBM,BC,32:LDIR
        LD DE,NXTBM+11,(CGDE),DE

        LD HL,NXTBM-32,A,#30
        LD B,5,(HL),A:INC HL:DJNZ $-2

BURA    LD HL,NXTBM-32+3
        PUSH HL:CALL INDEX:LD A,2
        POP HL:RET NZ

        LD DE,NXTBM+7
        LD BC,#03FF,A,#30
ZZBZ    LDD:CP (HL):JR NZ,SUFFIX_MORE
        DEC HL:CP (HL):INC HL
        JR Z,SUFFIX_DONE
SUFFIX_MORE:
        DJNZ ZZBZ
SUFFIX_DONE:
        LD A,#7E,(DE),A

        LD HL,NXTBM,DE,ENTRY,BC,12:LDIR
        CALL FIND_ALIAS:RET C:JR NZ,BURA

        LD HL,NXTBM
        CALL LNCRC:LD (CRC+1),A

        LD HL,NXTBM+32
        LD DE,NXTBU+1
        LD BC,#0001
DNB     LD (HL),C:INC C,HL
        CALL OEM5UC
        LD (HL),#0F:INC HL
        LD (HL),#00:INC HL
CRC     LD (HL),0:INC HL
        CALL OEM6UC
        LD (HL),#00:INC HL
        LD (HL),#00:INC HL
        CALL OEM2UC_PAIR
        LD A,(DE):OR A:JR NZ,DNB

        LD (HL),0
        LD BC,0-32:ADD HL,BC:SET 6,(HL)

        PUSH HL
        LD HL,NXTBU
        CALL SRHDRN:LD A,3
        POP HL:RET NZ
        XOR A
        RET
INDEX   LD B,3
XED     LD A,(HL):CP #39:JR C,DEX
        LD (HL),#30:DEC HL:DJNZ XED
        XOR A:INC A
        RET
DEX     INC (HL):XOR A:RET
FNLZ    LD (HL),B:INC HL
        LD (HL),B:INC HL
        LD B,#FF
        RET
OEM6UC  CALL OEM2UC
OEM5UC  CALL OEM2UC
        CALL OEM2UC
        CALL OEM2UC
OEM2UC_PAIR:
        CALL OEM2UC
OEM2UC  LD A,(DE):OR A:JR Z,FNLZ:INC DE
        PUSH BC
        LD C,A,B,0:CP #80:CALL NC,ORU
        LD (HL),C:INC HL
        LD (HL),B:INC HL
        POP BC
        RET
ORU     LD B,4
        CP #F0:LD C,#01:RET Z
        CP #F1:LD C,#51:RET Z
        CP #B0:JR NC,OR2
        SUB #70:LD C,A:RET
OR2     CP #F0:RET NC
        CP #E0:RET C
        SUB #A0:LD C,A:RET
ENVAL   CALL_WDOS_EXTENSION WDOS_EXT.ID_VALIDATE_NAME
        RET
ENnvl   LD A,1:OR A:RET
ENTREZ_ANY_TYPE:
        PUSH AF
        XOR A:LD (FIND_TYPE_MASK+1),A
        POP AF
        CALL ENTREZ
        PUSH AF
        LD A,#10:LD (FIND_TYPE_MASK+1),A
        POP AF
        RET
FIND_ALIAS:
        LD HL,NXTBM,DE,NXTBM-16+1
        CALL Snm
        LD HL,NXTBM-16
        LD (HL),0
        LD (CGDE),HL
        JP FNDSN

SNCEN   CP #2B:RET Z
        CP #2C:RET Z
        CP #2E:RET Z
        CP #3B:RET Z
        CP #3D:RET Z
        CP #5B:RET Z
        CP #5D:RET Z
        RET

ENCEN   CP #20:JR C,MU

        CP #22:RET Z
        CP #2A:RET Z
        CP #2F:RET Z
        CP #3A:RET Z
        CP #3C:RET Z
        CP #3E:RET Z
        CP #3F:RET Z
        CP #5C:RET Z
        CP #7C
        RET
MU      CP A
        RET

CAPS_SV CP "A":RET C
        CP "Z"+1:JR NC,CAPS_sv
        XOR A
        RET
CAPS_sv CP #80:RET C
        CP #9F+1:JR NC,CAPS_YO
        XOR A
        RET
CAPS_YO CP #F0:RET

ERG2    LD HL,FCTS:CALL DLSG
        LD HL,FCTS,DE,FSTFRC,BC,4:LDIR
ERG1    LD A,16:OR A
        RET
MKSG

        CALL DEL512
        LD A,(BSECPC):CALL DELITX2

        LD (CLCNT+2),DE
        LD (CLCNT+0),HL

        CALL SGENBU:JR C,ERG1
ROSTIK  CALL PREPFC:JR C,ERG2
        CALL BUtoFAT:RET C
        ; GENBU сброшен, последний кластер перенесён в его начало (LSTsr).
        ; Поиск продолжается с курсора CAHL заново: в SECBU уже сектор FAT
        ; последней записанной ссылки, а HL' разрушен шлюзом в BUtoFAT.
        ; Прежде здесь SGENB2 добавлял кластер мимо счётчика PREPFC, и
        ; цепочка выходила длиннее на кластер на каждый сброс GENBU.
        CALL WDOS_EXT.NEXT_FREE_FAT_SECTOR:JR C,ERG2
        EXX
        JR ROSTIK
SGENBU  LD HL,GENBU,(GARY),HL

        CALL SRHFCL:RET C
        LD (FCTS),HL,(FCTS+2),DE
GENB    LD (FSTFRC),HL,(FSTFRC+2),DE

        LD A,H,C,L
        LD HL,(GARY)
        LD (HL),C:INC HL
        LD (HL),A:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (GARY),HL
        XOR A
        RET
; Остаток — 32 бита: заём в старшее слово только при переходе 0000 -> FFFF.
; Прежде при нулевом младшем слове уменьшалось старшее, а младшее шло по
; кругу: цепочка от 65536 кластеров выходила намного длиннее нужной.
PREPFC  LD HL,(CLCNT),DE,(CLCNT+2)
        LD A,H:OR L:JR NZ,.low_ready
        DEC DE
.low_ready:
        DEC HL
        LD (CLCNT),HL,(CLCNT+2),DE
        LD A,H:OR L,D,E:JR Z,EOFG

AMM     EXX
        LD A,H:CP high SECBE
        JR C,ARM
        CALL SRHFC:RET C
        JR AR2
ARM     CALL FC:RET C                   ; нет места: прежде в цепочку шёл мусор
AR2     LD (FSTFRC),HL,(FSTFRC+2),DE
        LD A,H,C,L
        LD HL,(GARY)
        LD (HL),C:INC HL
        LD (HL),A:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD A,H:CP high GENBE:RET NC
        LD (GARY),HL
        JP PREPFC
EOFG    LD DE,#0FFF
        LD HL,(GARY)
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (GARY),HL
        RET
BUtoFAT LD HL,GENBU
GENFC   LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        PUSH HL
        LD HL,BC:CALL WDOS_EXT.CURIT_CHECKED:EX DE,HL
        POP HL

GNFC    LD (UUHL),HL
        LD BC,4:LDIR

        CALL_WDOS_EXTENSION WDOS_EXT.ID_IS_EOC_BEFORE_HL
        JR Z,LSTSR
        LD A,H:CP high GENBE:JR NC,LSTsr

        LD HL,(UUHL)
        LD C,(HL):INC HL
        LD B,(HL):INC HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD (BUHL),HL

        LD HL,BC:CALL DEL128
        LD BC,(LSTSE)
        OR A:SBC HL,BC:JR NZ,GGC
        EX DE,HL:LD BC,(LSTSE+2)
        OR A:SBC HL,BC:JR Z,GFC

GGC     CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
        LD HL,(UUHL)
        JP GENFC

GFC     LD H,0,L,A
 DUP 2
         SLA L:RL H
 EDUP
        LD BC,SECBU:ADD HL,BC
        EX DE,HL
        LD HL,(BUHL)
        JR GNFC
LSTSR   CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        SCF
        RET
LSTsr   CALL LSTSR
        RET NZ                          ; ошибка промежуточного сброса GENBU
        LD HL,(UUHL),DE,GENBU,BC,4:LDIR
        LD (GARY),DE

        XOR A:INC A
        RET

DLSG

        LD DE,LOBU,BC,4:LDIR
        CALL_WDOS_EXTENSION WDOS_EXT.ID_NOTE_FREED_CHAIN
        DS 5,0
LWT     LD HL,(LOBU),DE,(LOBU+2)
        LD A,D:OR E,H,L:RET Z
        CALL WDOS_EXT.CLASSIFY_DATA     ; за томом или корень — порча
        RET Z
        JR NC,DLSG_LINK_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
DLSG_LINK_VALID:

        CALL CURIT
        JR NC,DLSG_ENTRY_VALID
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET
DLSG_ENTRY_VALID:
GOCE    LD DE,LOBU,C,0
 DUP 3
         LD A,(HL),(HL),C,(DE),A:INC L,E
 EDUP
        LD A,(HL),(HL),C,(DE),A

        LD HL,(LOBU),DE,(LOBU+2)
        CALL WDOS_EXT.CLASSIFY_DATA
        JR Z,Ne
        JR C,DLSG_BAD_LINK
        CALL DEL128
        LD BC,(LSTSE)
        OR A:SBC HL,BC:JR NZ,NE:EX DE,HL
        LD BC,(LSTSE+2)
        OR A:SBC HL,BC:JR NZ,NE

        LD H,0,L,A
 DUP 2
         SLA L:RL H
 EDUP
        LD BC,SECBU:ADD HL,BC
        JP GOCE

NE      CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
        JP LWT
Ne      CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET
DLSG_BAD_LINK:
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_FAT_SECTOR
        RET NZ
        CALL_WDOS_EXTENSION WDOS_EXT.ID_FAT_LINK_ERROR
        RET

SRHDRN

        LD (CGDE),HL:CALL LNLNG:RET Z
        CALL_WDOS_EXTENSION WDOS_EXT.ID_REFINE_NAME_CLASSIFICATION
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RESET_DIR_HISTORY

; Цепочка каталога проверяется до поиска (DIR_STREAM_OPEN): замкнутая вешала
; поиск; испорчена — отказ чтения.
FNDSN   CALL WDOS_EXT.DIR_STREAM_OPEN
        JP C,FIND_IO_ERROR

        LD HL,LOBU,B,1:CALL LOAD512
        JP C,FIND_IO_ERROR

        LD H,high LOBU
ANNA    CALL ENTCH:JR Z,FND
        LD BC,32:ADD HL,BC
        LD A,H:CP high LOBU2:JR C,ANNA

HDR     LD A,(EOC):CP #0F:RET Z
HDR_CONTINUE:
        CALL_WDOS_EXTENSION WDOS_EXT.ID_SAVE_PREVIOUS_DIR_LBA
        PUSH HL
        LD HL,LOBU2,B,1:CALL LOAD512
        POP HL
        JP C,FIND_IO_ERROR
AnnA    CALL ENTCH:JR Z,FND
        LD BC,32:ADD HL,BC
        LD A,H:CP high LOBE2:JR C,AnnA

        CALL_WDOS_EXTENSION WDOS_EXT.ID_PRESERVE_OLDER_DIR_SECTOR
        EXX
        LD HL,LOBU2,DE,LOBU,BC,512:LDIR
        EXX:LD BC,0-512:ADD HL,BC
        JR HDR

FND     OR A:RET Z
        LD HL,(CLSHL)
        LD DE,(CLSDE)
        RET
NOP32   LD A," ",(DE),A:INC DE:DJNZ $-2
        RET
LNe     XOR A:RET
LNLNGcs LD A,#C9,(ACS),A
        CALL LNLNG
        EXA:XOR A:LD (ACS),A
        EXA
        RET
LNLNG   LD A,(HL):INC HL
        AND %11101111:JR NZ,LNe

        LD BC,256:XOR A:CPIR:JR NZ,LNe
        LD A,256-1:SUB C:JR Z,LNe

        LD HL,(CGDE)
        BIT 4,(HL):JR NZ,KAT

MURMUR  LD C,12+1:SUB C:JR NC,NESN
        ADD A,C
        LD C,A:ADD HL,BC

        EXA
        LD B,4,DE,ENTRY+8
FEL     LD A,(HL):DEC C:JR Z,FEL4
        CP ".":JR Z,FELE
        DEC HL:DJNZ FEL
FEL4    EXA
        LD C,A
        LD B,3
FEL3    CALL NOP32
FEL2    LD DE,ENTRY
        LD A,C:CP 8+1:JR NC,NESN

        LD B,A,A,8:SUB B:LD C,A
        LD HL,(CGDE)
FEEL    INC HL:LD A,(HL):CALL ACS
        LD (DE),A:INC DE:DJNZ FEEL

        LD B,C,A,B:OR A:CALL NZ,NOP32
        JR ENTch

FELE    LD B,3
FEL5    INC HL:LD A,(HL):OR A:JR Z,FEL3
        CALL ACS
        LD (DE),A:INC DE
        DJNZ FEL5
        JR FEL2
KAT     CP 3+1:JR NC,MURMUR
        LD C,A
        INC HL:LD A,(HL):CP "."
        DEC HL:LD A,C:JR NZ,MURMUR
        INC HL,HL:LD A,(HL):CP "."
        DEC HL,HL:LD A,C:JR NZ,MURMUR

        LD DE,ENTRY
        LD B,A,A,11:SUB B:LD C,A
KaT     INC HL:LD A,(HL):CALL ACS
        LD (DE),A:INC DE:DJNZ KaT

        LD B,C:CALL NOP32
        JR ENTch

NESN    XOR A:LD (ENTRY),A
ENTch   XOR A:INC A:RET
ENTCH   LD A,(HL)
        OR A:RET Z
        CP #E5:JR Z,ENTch

        LD A,L:ADD A,11:LD L,A
        BIT 3,(HL):JP NZ,ENTCHe

        LD DE,(CGDE)
        LD A,(DE):XOR (HL)
FIND_TYPE_MASK:
        AND #10
        JP NZ,ENTCHe

        LD A,(ENTRY):OR A:JR Z,LNEB
        LD A,L:AND #F0:LD L,A
        LD B,11,DE,ENTRY
SNCH    LD A,(DE):CP (HL):JR NZ,LNEB
        INC DE,L:DJNZ SNCH
        JP ENTFND

LNEB    LD A,L:AND #F0:LD L,A
        CALL LNCRC
        LD (CGHL),HL

        LD BC,0-30:ADD HL,BC
        CP (HL):JP NZ,ENTCHE
        LD A,H:CP high LOBU:JP C,ENTCHE
 DUP 2
         DEC L
 EDUP
        LD A,(HL):CP #0F:JP NZ,ENTCHE

        LD DE,(CGDE):INC DE
        LD A,L:AND #F0:LD L,A

        LD B,1
LNPARZ  LD A,(HL)
        BIT 6,A:JR Z,$+4:SET 6,B
        CP B:JR NZ,ENTCHE:INC B

        INC L
 DUP 5
         CALL ULNP:JR NC,ENTST
 EDUP
 DUP 3
         INC L
 EDUP
 DUP 6
         CALL ULNP:JR NC,ENTST
 EDUP
 DUP 2
         INC L
 EDUP
 DUP 2
         CALL ULNP:JR NC,ENTST
 EDUP
        DEC L

        LD A,B:CP #40:JP NC,ENTFNDx

        LD BC,0-(64-1):ADD HL,BC:LD B,A
        CALL_WDOS_EXTENSION WDOS_EXT.ID_MAP_OLDER_LFN_POINTER
        JR C,ENTCHE
        JR LNPARZ
ENTST   JR NZ,ENTFNDL
ENTCHE  LD HL,(CGHL)
ENTCHe  LD A,L:AND #F0:LD L,A
        XOR A:INC A
        RET

ENTFNDx LD A,(DE):OR A:JR NZ,ENTCHE
ENTFNDL LD HL,(CGHL)
ENTFND  LD A,L:AND #F0:LD L,A
        PUSH HL:LD DE,ENTRY,BC,32:LDIR
        POP BC
        XOR A:LD A,1
        RET
ULNP    CALL_WDOS_EXTENSION WDOS_EXT.ID_COMPARE_LFN_CHAR
        RET
ACS     NOP
        CP #80:JR NC,RUS
        CP #60+1:RET C
        CP #7B:RET NC
        RES 5,A
        RET
RUS     CP #A0:RET C
        CP #B0:JR NC,RU2
        RES 5,A
        RET
RU2     CP #E0:RET C
        CP #F2:RET NC
        CP #F1:JR NZ,$+3:DEC A
        CP #F0:RET Z
        SUB #50
        RET
UCS     INC L
        LD A,(HL):OR A:JR NZ,UCSX
        DEC L:LD A,(HL):INC L,L
        OR A:JR Z,UCSE
        CP #80:RET C
UCS_    XOR A:RET
UCSE    LD A,#FF:RET

UCSX    CP 4:JR NZ,UCS_
        DEC L:LD A,(HL):INC L,L
        CP #01:JR Z,Hyo
        CP #10:JR C,UCS_
        CP #3F+1:JR C,Dgg
        CP #4F+1:JR C,Dee
        CP #51:JR Z,Lyo
        JR UCS_
Dgg     ADD A,#70:RET
Dee     ADD A,#A0:RET
Hyo     LD A,#F0:RET
Lyo     LD A,#F1:RET

; Запись удалена (DELEN, NZ), но цепочку освободить не удалось (DLSG вернул
; NZ) — прежде возвращался «успех», и сбой FAT скрывался. Теперь неудача: Z,
; A=0, как у отказа записи каталога в DELEN.
DELFL

        CALL DELEN:RET Z
        LD HL,FCTS:CALL DLSG
        LD A,1:JR Z,$+3:DEC A
        OR A
        RET
DELCHA  PUSH AF:LD HL,FCTS:CALL DLSG
        POP AF
        RET

DELEN   CALL SRHDRN:LD A,8:RET Z

        LD (FCTS+0),HL
        LD (FCTS+2),DE

        CALL_WDOS_EXTENSION WDOS_EXT.ID_DELETE_ENTRY_WITH_LFN
        JR NZ,DELEN_WRITE_ERROR
        XOR A:INC A
        RET
DELEN_WRITE_ERROR:
        XOR A
        RET
STAMP   PUSH HL
        LD HL,(LLHL),DE,(LLHL+2)
        CALL PROZ
        POP HL

        LD A,1:JP SAFE_SDDSE
; Последовательность и откат — RENAME_ENTRY (safety.asm): если прежнюю запись
; удалить не удалось, новая удаляется, чтобы две записи не делили одну
; цепочку. Вход и выход прежние.
RENAME  JP WDOS_EXT.RENAME_ENTRY
MKFILE

        LD A,(HL),(EFLG),A:INC HL
        LD DE,SIZIK,BC,4:LDIR
        LD (CGHL),HL
        CALL WDOS_EXT.NAME_PRECHECK     ; недопустимое имя — до выделения
        RET NZ
        CALL WDOS_EXT.DIR_CHECK         ; испорченный каталог — до выделения
        RET NZ

        LD HL,(SIZIK),DE,(SIZIK+2)
        CALL_WDOS_EXTENSION WDOS_EXT.ID_ALLOCATE_FILE
        RET NZ
        JP WDOS_EXT.MKFILE_TAIL         ; запись в каталог (safety.asm)

; Тело каталога («.», «..», обнулённый хвост кластера) пишется до записи в
; родителе — MKDIR_ENTRY (safety.asm). Вход и выход прежние.
MKDIR   JP WDOS_EXT.MKDIR_ENTRY

RFRH    CALL_WDOS_EXTENSION WDOS_EXT.ID_RFRH_SAFE
        RET
CHTOSE

        LD (DABC),BC
        LD (DADE),DE
CKAGO   LD (DAHL),HL

        CALL GIPP:RET Z
        CALL CLUSSEC
        LD DE,(DABC)
        OR A:SBC HL,DE:RET NC

        LD HL,(DAHL)
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:EX DE,HL

        CALL CURIT:JP C,GIPP_BAD_LINK   ; HL — мусор: дальше не идти
        JR CKAGO

CLUSSEC

        LD BC,HL
        LD A,(BSECPC)
        LD HL,(DADE)
USS     LD (HL),C:INC HL
        LD (HL),B:INC HL
        LD (HL),E:INC HL
        LD (HL),D:INC HL
        LD (DADE),HL:DEC A:RET Z

        INC BC
        EXA:LD A,B:OR C:JR NZ,$+3:INC DE
        EXA
        JR USS

GIPP

        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A:OR H,E,D:RET Z
        EX DE,HL
        CALL WDOS_EXT.CLASSIFY_IN_VOLUME
        JR C,GIPP_BAD_LINK
        RET Z

        LD BC,2:OR A:SBC HL,BC:JR NC,$+3:DEC DE

        LD A,(BSECPC):CALL UMNOX2
        LD BC,(SDFAT):CALL ADD4B
        EX DE,HL
        LD BC,(SDFAT+2):ADD HL,BC
        EX DE,HL
        CALL XSPOZ

        XOR A:INC A
        RET
GIPP_BAD_LINK:
        CALL_WDOS_EXTENSION WDOS_EXT.ID_RECORD_FAT_LINK_ERROR
        XOR A
        RET

HDD

        LD HL,0,DE,HL
        LD (CUHL),HL,(CUDE),HL
        LD (DAHL),HL,(DADE),HL
        LD (DUHL),HL,(DUDE),HL
        LD (EXTBAS),HL,(EXTBAS+2),HL
        LD (EXTCUR),HL,(EXTCUR+2),HL
        LD (PARTSZ),HL,(PARTSZ+2),HL
        LD (EXTVOL),HL
        CALL XPOZI
        LD HL,LOBU,A,1:CALL SAFE_RDDSE
        RET NZ

        LD A,3,(COUNT),A,(ZES),A

        LD HL,LOBU+446+4,DE,16,B,4
KKO     LD A,(HL)
        CP #05:JP Z,OKK
        CP #0B:JP Z,OKK
        CP #0C:JP Z,OKK
        CP #0F:JP Z,OKK
        ADD HL,DE
        DJNZ KKO

FHDD    LD A,(ZES):OR A:JP NZ,FHDD_EXTENDED
        INC A
        RET
FHDD_EXTENDED:
        LD HL,(EXTCUR),DE,(EXTCUR+2)
        LD A,H:OR L:OR D:OR E
        JP Z,NHDD                       ; цепочка кончилась
        CALL XPOZI

        LD HL,LOBU:LD A,1:CALL SAFE_RDDSE
        RET NZ

        LD HL,COUNT:DEC (HL):JP Z,NHDD  ; ограничение глубины обхода

        ; Логический том этого EBR: его смещение отсчитывается от EBR, длина —
        ; граница тома (PARTSZ). Ссылка на следующий EBR отсчитывается от
        ; первого EBR, а не от текущего; нулевая — последний EBR в цепочке.
        ; Начало тома за 2**32 — EBR испорчен, обход кончается (EBR_ENTRY).
        CALL WDOS_EXT.EBR_ENTRY
        JP C,NHDD
        JP LDBPB

OKK     INC HL,HL,HL,HL
        PUSH AF                         ; тип раздела
        PUSH HL                         ; запись+8: начало раздела, +12: длина
        LD BC,4:ADD HL,BC
        LD DE,PARTSZ,BC,4:LDIR
        POP HL
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        POP AF

        ; Начало найденного раздела. Для типов #05/#0F здесь лежит первый
        ; EBR: запоминаем его как базу и как текущий шаг обхода. Без этого
        ; обход стартовал с LBA 0 и логический том не находился никогда.
        ; У тома FAT32 (#0B/#0C) обхода нет: прежде его неудачный BPB читался
        ; как EBR.
        LD BC,0
        CP #05:JR Z,OKK_EXTENDED
        CP #0F:JR Z,OKK_EXTENDED
        LD (EXTCUR),BC
        LD (EXTCUR+2),BC
        JR LDBPB
OKK_EXTENDED:
        LD BC,(PARTSZ):LD (EXTSZ),BC
        LD BC,(PARTSZ+2):LD (EXTSZ+2),BC
        LD (EXTBAS),HL
        LD (EXTBAS+2),DE
        LD (EXTCUR),HL
        LD (EXTCUR+2),DE

LDBPB   LD (ADDTOP),HL,(ADDTOP+2),DE
        CALL XPOZI

        LD HL,LOBU
        LD A,1:CALL SAFE_RDDSE
        RET NZ

        LD HL,(LOBU+11)
        LD A,H:DEC A,A:OR L:JP NZ,FHDD
        LD A,(LOBU+13):OR A:JP Z,FHDD
        LD HL,(LOBU+14):LD A,H:OR L:JP Z,FHDD  ; резерв — 16 бит, не младший байт
        LD A,(LOBU+16):OR A:JP Z,FHDD

        LD HL,(LOBU+17),A,H:OR L
        LD HL,(LOBU+22):OR H,L
        JP NZ,FHDD
        LD HL,(LOBU+36):OR H,L
        LD HL,(LOBU+36+2):OR H,L
        JP Z,FHDD

        LD A,(LOBU+13),(BSECPC),A
        LD B,8:SRL A:JR C,NER:DJNZ $-4:LD A,1
NER     OR A:JP NZ,FHDD
        LD HL,(LOBU+14),(BREZS),HL
        LD HL,(LOBU+48),DE,0
        CALL XSPOZ
        LD (FSINF),HL,(FSINF+2),DE

        CALL_WDOS_EXTENSION WDOS_EXT.ID_LOAD_FAT_CONFIG
        JP NZ,FHDD

        LD HL,(BFTSZ),DE,(BFTSZ+2)
        LD BC,(BFATS),B,0
        CALL UMN4B
        PUSH HL,DE
        LD HL,(BREZS)
        LD (SFAT),HL
        POP DE,BC
        CALL ADD4B
        LD (SDFAT),HL,(SDFAT+2),DE

        LD HL,0
        LD (CUHL),HL
        LD (CUDE),HL
        LD (LSTCAT),HL
        LD (LSTCAT+2),HL
        LD (CGFL),HL

        CALL_WDOS_EXTENSION WDOS_EXT.ID_LOAD_FREE_HINT
        JP NZ,FHDD                      ; в томе нет области данных — неверный BPB
        DS 1,0

        CALL TOS
        RET

NHDD    LD HL,0
        LD (EXTVOL),HL
        DEC HL                          ; том с LBA 0: границы раздела нет —
        LD (PARTSZ),HL,(PARTSZ+2),HL    ; #FFFFFFFF (ноль — пустой раздел)
        LD HL,(DUHL),DE,(DUDE)
        XOR A:LD (ZES),A
        JP LDBPB

DOS_SWP JP @DRIVER_BIND

DEL128

        LD A,L:EXA
        LD A,L,L,H,H,E,E,D,D,0
        RLA
        RL L,H,E,D
        EXA
        AND 127
        LD B,0,C,A
        RET

DEL512
        LD A,L,L,H,H,E,E,D,D,0
        LD BC,1:OR A:CALL NZ,ADD4B
        LD A,2

DELITX2

        CP 2:RET C
        LD C,0
        SRL A
L33T    SRL D:RR E,H,L,C
        SRL A:JR NC,L33T

        LD A,C:OR A:RET Z
        LD BC,1

ADD4B   ADD HL,BC:RET NC:INC DE
        RET

UMNOX2

        CP 2:RET C
        SRL A
L33t    SLA L:RL H,E,D
        SRL A:JR NC,L33t
        RET

UMNOG
        LD DE,HL
        LD A,B,B,C,C,A:INC C
        XOR A:DEC B:JR Z,ODN
BSR     ADD HL,DE
        DJNZ BSR
ODN     LD B,A
        DEC C
        JR NZ,BSR
        RET

INC4b   LD B,4
EkE     INC (HL):RET NZ:INC HL:DJNZ EkE
        RET

ADD4BF
        EX DE,HL
        LD BC,(CLDE)
        ADD HL,BC
        EX DE,HL
        LD BC,(CLHL)
        ADD HL,BC:JR NC,KNH
        INC DE
KNH     LD (CLHL),HL
        LD (CLDE),DE
        RET

UMN4B
        LD A,B,B,C,C,A:INC C
        OR A:JR NZ,TEKNO
        DEC B:JR Z,UMN1
        INC B
TEKNO   XOR A
        CP B:JR NZ,TYS
        DEC C
TYS     DEC B
        PUSH HL,BC
        LD HL,DE
        CP B:JR Z,NEGRY
EFRO    ADD HL,DE
        DJNZ EFRO
        LD B,A
NEGRY   DEC C:JR NZ,EFRO
        LD (REZDE),HL
        POP BC,HL
        LD DE,HL
        CP B:JR Z,NEGRA
OFER    ADD HL,DE
        JR C,INCDE
ENJO    DJNZ OFER
        LD B,A
NEGRA   DEC C:JR NZ,OFER
        LD DE,(REZDE)
UMN1    RET
INCDE   EXX
        LD HL,(REZDE)
        INC HL
        LD (REZDE),HL
        EXX
        JR ENJO
TOS     XOR A:LD (NSDC),A,(EOC),A
        RET

NOPING  XOR A:LD (HL),A:INC HL:DJNZ $-2
        RET
SAFE_RDDSE:
        OR A
        JR SAFE_IO_PREPARE
SAFE_SDDSE:
        SCF
SAFE_IO_PREPARE:
        PUSH AF
        XOR A
        LD (ABT),A
        POP AF
        JP SAFE_IO_DISPATCH

EXT_DIR_PREVIOUS_LBA       DS 4
EXT_DIR_OLDER_LBA          DS 4
EXT_DIR_OLDER_VALID        DS 1
EXT_DIR_PREVIOUS_DIRTY     DS 1
EXT_DIR_OLDER_DIRTY        DS 1
EXT_DIR_EXPECTED_SEQUENCE  DS 1
EXT_DIR_LFN_CHECKSUM       DS 1

EXTENSION_GATE:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL
        PUSH IX
        EX AF,AF'
        EXX
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL
        EXX
        EX AF,AF'

        LD IX,0
        ADD IX,SP
        LD L,(IX+18)
        LD H,(IX+19)
        LD A,(HL)
        INC HL
        LD (IX+18),L
        LD (IX+19),H
        LD L,A

        JP WDOS_EXT.GATE_CONTINUE

SAFE_IO_DISPATCH:
        JR NC,SAFE_IO_READ
        CALL SDDSE
        JR SAFE_IO_RESULT
SAFE_IO_READ:
        CALL RDDSE
SAFE_IO_RESULT:
        LD A,(ABT)
        OR A
        RET

        DB #FF

GARY    DS 2

DABC    DS 2
DAHL    DS 2
DADE    DS 2
ZES     NOP

; Обход расширенных разделов: EXTBAS — начало первого EBR, от него
; отсчитываются ссылки на следующий EBR; EXTCUR — текущий шаг обхода,
; ноль означает, что цепочка кончилась. Отдельные ячейки, а не DAHL/DADE,
; потому что те же DAHL/DADE служат временными значениями CHTOSE.
EXTBAS  DS 4
EXTCUR  DS 4
; Длина раздела, на котором ищется том (запись MBR или EBR); 0 — не задана
; (том с LBA 0, MOUNT_AT). LOAD_FREE_HINT не монтирует том длиннее раздела.
PARTSZ  DS 4
; Расширенный раздел из MBR (EXTBAS — его начало, EXTSZ — длина) и признак
; того, что том ищется по цепочке EBR (EXTVOL≠0): тогда логический том обязан
; лежать внутри расширенного раздела (GEOMETRY_CHECK).
EXTSZ   DS 4
EXTVOL  DS 2


EXTENSION_GATE_AFTER:
        EX AF,AF'
        EXX
        PUSH AF
        POP HL
        DUP 9
        POP BC
        EDUP
        PUSH HL
        POP AF
        EXX
        EX AF,AF'
        RET

STREAM_RESTORE_READ_HANDLER:
        PUSH HL
        LD HL,SAFE_RDDSE
        LD (NW0+1),HL
        POP HL
        RET

