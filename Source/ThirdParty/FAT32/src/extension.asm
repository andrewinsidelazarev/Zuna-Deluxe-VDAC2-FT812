
RUNTIME_START:
        INCLUDE "extension_ids.inc"

ENTRY_TABLE:
        JP STREAM_WITH_HANDLER
        JP READ_SECTORS
        JP STREAM_IO_ERROR
        JP INIT_FREE_SCAN
        JP CHECK_FREE_SCAN_LIMIT
        JP NEXT_FREE_FAT_SECTOR
        JP FAT_SECTOR_IN_RANGE
        JP POSITION_FAT_READ
        JP CLASSIFY_IN_VOLUME           ; ссылка за областью данных — порча
        JP FAT_LINK_ERROR
        JP SAVE_FAT_SECTOR
        JP REFINE_NAME_CLASSIFICATION
        JP IS_EOC_BEFORE_HL
        JP RESET_DIR_HISTORY
        JP SAVE_PREVIOUS_DIR_LBA
        JP PRESERVE_OLDER_DIR_SECTOR
        JP BEGIN_LFN_COMPARE
        JP COMPARE_LFN_CHAR
        JP DELETE_ENTRY_WITH_LFN
        JP ALLOCATE_FILE
        JP RFRH_SAFE
        JP RECORD_FAT_LINK_ERROR
        JP LOAD_FAT_CONFIG
        JP VALIDATE_NAME
        JP MAP_OLDER_LFN_POINTER
        JP UNPACK_DRIVER
        IFDEF WDOS_EXPERIMENTAL_ZC_RUNTIME
        JP ZC_WAIT_READY
        JP ZC_WAIT_TOKEN
        JP ZC_WAIT_BUSY
        JP ZC_DATA_RESPONSE
        JP ZC_DMA_WAIT
        JP ZC_START_READ
        JP ZC_READ_BLOCK
        JP ZC_WRITE_READY
        JP ZC_START_WRITE
        JP ZC_CHECK_TOKEN
        ENDIF
        JP ZERO_CLUSTER_TAIL
        JP COPY_ENTRY_AND_CAPTURE
        JP APPEND_BYTES
        JP COPY_TO_ENTRY
        JP FILEX_CONTEXT_BRIDGE
        JP LOAD_FREE_HINT
        JP NOTE_FREED_CHAIN
        JP SAVE_NEXT_FREE_HINT
        JP GET_DATA_CLUSTER_LIMIT
ENTRY_TABLE_END:
        ASSERT ENTRY_TABLE_END-ENTRY_TABLE == ID_COUNT*3, нарушена таблица шлюза

GATE_CONTINUE:
        LD H,0
        LD C,L
        LD B,H
        ADD HL,HL
        ADD HL,BC
        LD BC,ENTRY_TABLE
        ADD HL,BC
        LD BC,@WDOS.EXTENSION_GATE_AFTER
        PUSH BC
        PUSH HL

        EXX
        LD L,(IX+0)
        LD H,(IX+1)
        LD E,(IX+2)
        LD D,(IX+3)
        LD C,(IX+4)
        LD B,(IX+5)
        EXX

        LD L,(IX+6)
        LD H,(IX+7)
        PUSH HL
        EX AF,AF'
        POP AF
        EX AF,AF'

        LD C,(IX+14)
        LD B,(IX+15)
        LD E,(IX+12)
        LD D,(IX+13)

        LD L,(IX+16)
        LD H,(IX+17)
        PUSH HL
        POP AF

        LD L,(IX+10)
        LD H,(IX+11)
        PUSH HL
        LD L,(IX+8)
        LD H,(IX+9)
        PUSH HL
        POP IX
        POP HL
        RET

STREAM_WITH_HANDLER:
        ; B содержит число секторов: нельзя занимать BC адресом обработчика.
        PUSH HL
        LD HL,(@WDOS.NW0+1)
        EX (SP),HL
        LD (@WDOS.NW0+1),DE
        CALL @WDOS.LOAD512
        POP DE
        LD (@WDOS.NW0+1),DE
        RET

COPY_ENTRY_AND_CAPTURE:
        CALL @FILEX_NEW_GENERATION
        PUSH AF
        PUSH DE
        EXX
        LD (APPEND_FOUND_POINTER),BC
        EXX
        LD HL,(@WDOS.LLHL)
        LD (APPEND_DIRECTORY_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (APPEND_DIRECTORY_LBA+2),HL

        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        LD (FILE_CHAIN_OK),A
        LD BC,(APPEND_FOUND_POINTER)
        LD A,C:AND #1F:JR NZ,.copy_saved_entry
        LD A,B:SUB high @WDOS.LOBU:CP 4:JR NC,.copy_saved_entry
        AND 1
        LD H,A,L,C
        LD (APPEND_DIRECTORY_OFFSET),HL
        LD A,1
        LD (APPEND_VALID),A

.copy_saved_entry:
        LD HL,@WDOS.ENTRY,DE,APPEND_ENTRY,BC,32
        LDIR
        POP DE
        LD HL,@WDOS.ENTRY,BC,32
        POP AF
        LDIR
        RET

COPY_TO_ENTRY:
        LD DE,@WDOS.ENTRY,BC,32
        LDIR
        RET

FILEX_CONTEXT_BRIDGE:
        OR A:JR Z,.export
        CP 2:JR Z,.import
.export:
        JR C,.invalidate
        LD A,(APPEND_VALID):OR A:RET Z
        LD HL,APPEND_DIRECTORY_LBA,BC,38
        LDIR
        LD A,1:OR A
        RET
.invalidate:
        CALL @FILEX_NEW_GENERATION
        XOR A
        LD (APPEND_VALID),A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        LD (FILE_CHAIN_OK),A
        RET
.import:
        CALL @FILEX_NEW_GENERATION
        LD DE,APPEND_DIRECTORY_LBA,BC,38
        LDIR
        XOR A
        LD (APPEND_READY),A
        LD (APPEND_LBA_VALID),A
        LD (FILE_CHAIN_OK),A
        INC A
        LD (APPEND_VALID),A
        OR A
        RET

APPEND_ERROR_CONTEXT       EQU #20
APPEND_ERROR_BUFFER        EQU #21
APPEND_ERROR_LENGTH        EQU #22
APPEND_ERROR_ENTRY_CHANGED EQU #23
APPEND_ERROR_SIZE_OVERFLOW EQU #24
APPEND_ERROR_BAD_CHAIN     EQU #25
APPEND_ERROR_IS_DIRECTORY  EQU #26
APPEND_ERROR_INTERNAL      EQU #27
APPEND_ERROR_READ_ONLY     EQU #28
APPEND_ERROR_ROLLBACK      EQU #2A

APPEND_BYTES:
        PUSH DE
        LD A,B:OR C:JR NZ,.nonempty
        XOR A
        POP DE
        RET

.nonempty:
        LD (APPEND_SOURCE),HL
        LD A,B:CP #40:JR C,.length_ok
        JP NZ,.bad_length
        LD A,C:OR A:JP NZ,.bad_length
.length_ok:
        LD A,H:CP high FAT32_ZERO_SCRATCH:JP C,.bad_buffer
        CP high FAT32_LOW_CODE:JR C,.scratch_buffer
        CP #80:JP C,.bad_buffer
        PUSH HL
        ADD HL,BC
        JR NC,.buffer_end_ok
        LD A,H:OR L:JP NZ,.bad_buffer_pop
        JR .buffer_end_ok
.scratch_buffer:
        ; FILEX использует внутренний нулевой буфер FAT32_ZERO_SCRATCH при
        ; увеличении файла; за ним в рабочей странице — код safety.asm.
        PUSH HL
        ADD HL,BC
        LD A,H:CP high FAT32_LOW_CODE:JR C,.buffer_end_ok
        JP NZ,.bad_buffer_pop
        LD A,L:OR A:JP NZ,.bad_buffer_pop
.buffer_end_ok:
        POP HL

        LD A,(APPEND_VALID):OR A:JP Z,.bad_context
        LD (APPEND_REMAINING),BC
        LD A,(APPEND_READY):OR A:JR NZ,.context_ready
        CALL APPEND_PREPARE
        JP NZ,.failed_without_rollback
.context_ready:

        LD HL,APPEND_CONTEXT,DE,APPEND_WORK_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD BC,(APPEND_REMAINING)
        ADD HL,BC:JR NC,.size_ready
        INC DE
        LD A,D:OR E:JP Z,.size_overflow
.size_ready:
        LD (APPEND_WORK_SIZE),HL
        LD (APPEND_WORK_SIZE+2),DE
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A

        CALL APPEND_PREALLOCATE
        JP NZ,.failed_with_rollback

.write_loop:
        LD HL,(APPEND_REMAINING)
        LD A,H:OR L:JP Z,.commit
        LD A,(APPEND_WORK_NEEDS_CLUSTER):OR A
        CALL NZ,APPEND_ENSURE_CLUSTER
        JP NZ,.failed_with_rollback

        LD HL,(APPEND_WORK_OFFSET)
        LD A,H:OR L:JR NZ,.single_sector
        LD HL,(APPEND_REMAINING)
        LD A,H:CP 2:JR C,.single_sector

        SRL A
        LD B,A
        LD A,(APPEND_WORK_SECTOR)
        LD C,A
        LD A,(@WDOS.BSECPC)
        SUB C
        CP B
        JR C,.run_ready
        LD A,B
.run_ready:
        LD (APPEND_RUN),A
        CALL APPEND_POSITION_SECTOR
        JP NZ,.failed_with_rollback
        LD HL,(APPEND_SOURCE)
        LD A,(APPEND_RUN)
        CALL WRITE_SECTORS
        JP NZ,.failed_with_rollback
        LD (APPEND_SOURCE),HL

        LD A,(APPEND_RUN)
        ADD A,A
        LD D,A
        LD E,0
        LD HL,(APPEND_REMAINING)
        OR A:SBC HL,DE
        LD (APPEND_REMAINING),HL

        LD A,(APPEND_WORK_SECTOR)
        LD B,A
        LD A,(APPEND_RUN)
        ADD A,B
        LD (APPEND_WORK_SECTOR),A
        LD B,A
        LD A,(@WDOS.BSECPC)
        CP B
        JP NZ,.write_loop
        XOR A
        LD (APPEND_WORK_SECTOR),A
        INC A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        JP .write_loop

.single_sector:
        CALL APPEND_POSITION_SECTOR
        JP NZ,.failed_with_rollback
        LD HL,(APPEND_WORK_OFFSET)
        LD A,H:OR L:JR Z,.clear_sector
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JP NZ,.failed_with_rollback
        JR .sector_ready
.clear_sector:
        CALL APPEND_CLEAR_SECTOR
.sector_ready:
        LD HL,512
        LD DE,(APPEND_WORK_OFFSET)
        OR A:SBC HL,DE
        EX DE,HL
        LD HL,(APPEND_REMAINING)
        PUSH HL
        OR A:SBC HL,DE
        POP HL
        JR C,.chunk_ready
        LD H,D,L,E
.chunk_ready:
        LD (APPEND_CHUNK),HL

        LD DE,@WDOS.LOBU
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        EX DE,HL
        LD HL,(APPEND_SOURCE)
        LD BC,(APPEND_CHUNK)
        LDIR
        LD (APPEND_SOURCE),HL

        CALL APPEND_POSITION_SECTOR
        JR NZ,.failed_with_rollback
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        JR NZ,.failed_with_rollback

        LD HL,(APPEND_REMAINING),DE,(APPEND_CHUNK)
        OR A:SBC HL,DE
        LD (APPEND_REMAINING),HL
        LD HL,(APPEND_WORK_OFFSET)
        ADD HL,DE
        LD (APPEND_WORK_OFFSET),HL
        LD DE,512
        OR A:SBC HL,DE
        JP NZ,.write_loop
        LD (APPEND_WORK_OFFSET),HL
        LD A,(APPEND_WORK_SECTOR):INC A
        LD B,A
        LD A,(@WDOS.BSECPC):CP B
        LD A,B
        JR NZ,.store_sector
        XOR A
        LD (APPEND_WORK_SECTOR),A
        INC A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        JP .write_loop
.store_sector:
        LD (APPEND_WORK_SECTOR),A
        JP .write_loop

.commit:
        CALL APPEND_COMMIT
        JR NZ,.failed_with_rollback
.committed:
        LD HL,APPEND_WORK_CONTEXT,DE,APPEND_CONTEXT,BC,APPEND_CONTEXT_SIZE
        LDIR
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.failed_with_rollback:
        LD (APPEND_LAST_ERROR),A
        ; Отказ записи сектора каталога неоднозначен: сектор мог лечь. Тогда
        ; фиксация состоялась (Z), и откат освободил бы живую цепочку; исход
        ; неизвестен (CF=1) — цепочку не трогать.
        CALL APPEND_DIR_OUTCOME
        JR Z,.committed
        JR C,.unknown
        CALL APPEND_ROLLBACK
        JR Z,.restore_original_error
        LD A,APPEND_ERROR_ROLLBACK
        JR .forget
; Исход неизвестен (сектор каталога не перечитался) или откат не удался:
; контекст APPEND больше не описывает носитель. Прежде он оставался, и
; повторный APPEND без FIND писал данные по старому размеру поверх уже легших.
.unknown:
        LD A,(APPEND_LAST_ERROR)
.forget:
        CALL CONTEXT_FORGET                     ; и выбор файла, и поток READ/WRITE
        JR .return_error
.restore_original_error:
        LD A,(APPEND_LAST_ERROR)
        JR .return_error

.size_overflow:
        LD A,APPEND_ERROR_SIZE_OVERFLOW
.failed_without_rollback:
.return_error:
        OR A
        LD HL,(APPEND_SOURCE)
        POP DE
        RET

.bad_buffer_pop:
        POP HL
.bad_buffer:
        LD A,APPEND_ERROR_BUFFER
        JR .return_error
.bad_length:
        LD A,APPEND_ERROR_LENGTH
        JR .return_error
.bad_context:
        LD A,APPEND_ERROR_CONTEXT
        JR .return_error

APPEND_PREPARE:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD A,(APPEND_ENTRY+11):BIT 4,A
        LD A,APPEND_ERROR_IS_DIRECTORY
        RET NZ
        LD A,(APPEND_ENTRY+11):BIT 0,A
        LD A,APPEND_ERROR_READ_ONLY             ; прежде APPEND писал и в него
        RET NZ
        CALL FILE_CHAIN_GUARD                   ; цикл, корень, за томом
        LD A,APPEND_ERROR_BAD_CHAIN
        RET C

        LD HL,(APPEND_ENTRY+28),DE,(APPEND_ENTRY+30)
        LD (APPEND_SIZE),HL
        LD (APPEND_SIZE+2),DE
        LD HL,(APPEND_ENTRY+26),DE,(APPEND_ENTRY+20)
        LD A,D:AND #0F:LD D,A
        LD (APPEND_FIRST_CLUSTER),HL
        LD (APPEND_FIRST_CLUSTER+2),DE

        LD BC,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        LD A,B:OR C:OR D:OR E:JR NZ,.nonzero_size
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        LD A,D:OR E:OR H:OR L:JR Z,.empty_without_cluster
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        XOR A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready
.empty_without_cluster:
        XOR A
        LD (APPEND_CURRENT_CLUSTER),A
        LD (APPEND_CURRENT_CLUSTER+1),A
        LD (APPEND_CURRENT_CLUSTER+2),A
        LD (APPEND_CURRENT_CLUSTER+3),A
        LD (APPEND_SECTOR),A
        LD (APPEND_OFFSET),A
        LD (APPEND_OFFSET+1),A
        INC A
        LD (APPEND_NEEDS_CLUSTER),A
        JP .ready

.nonzero_size:
        LD HL,(APPEND_FIRST_CLUSTER),DE,(APPEND_FIRST_CLUSTER+2)
        CALL CLASSIFY_FAT_LINK
        JP C,.bad_chain
        JP Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE

        LD HL,(APPEND_SIZE)
        LD A,H:AND 1:LD H,A
        LD (APPEND_OFFSET),HL
        LD HL,(APPEND_SIZE),DE,(APPEND_SIZE+2)
        DUP 9
        SRL D:RR E:RR H:RR L
        EDUP
        LD A,(@WDOS.BSECPC):DEC A:AND L
        LD (APPEND_SECTOR),A
        LD A,(@WDOS.BSECPC)
.divide_cluster:
        CP 1:JR Z,.cluster_index_ready
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide_cluster
.cluster_index_ready:
        XOR A
        LD (APPEND_NEEDS_CLUSTER),A
        LD A,(APPEND_OFFSET):LD B,A
        LD A,(APPEND_OFFSET+1):OR B:JR NZ,.store_skip
        LD A,(APPEND_SECTOR):OR A:JR NZ,.store_skip
        LD A,1
        LD (APPEND_NEEDS_CLUSTER),A
        DEC HL
        LD A,H:AND L:CP #FF:JR NZ,.store_skip  ; прежде заём и при FF01..FFFF
        DEC DE
.store_skip:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE

.walk_chain:
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.ready
        LD HL,(APPEND_CURRENT_CLUSTER),DE,(APPEND_CURRENT_CLUSTER+2)
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.bad_chain
        LD (APPEND_CURRENT_CLUSTER),HL
        LD (APPEND_CURRENT_CLUSTER+2),DE
        LD HL,(APPEND_SKIP_COUNT),DE,(APPEND_SKIP_COUNT+2)
        DEC HL
        LD A,H:AND L:CP #FF:JR NZ,.skip_stored
        DEC DE
.skip_stored:
        LD (APPEND_SKIP_COUNT),HL
        LD (APPEND_SKIP_COUNT+2),DE
        JR .walk_chain

.ready:
        XOR A
        LD (APPEND_LBA_VALID),A
        INC A
        LD (APPEND_READY),A
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

APPEND_READ_FAT_LINK:
        CALL @WDOS.CURIT
        RET C
        LD E,(HL):INC HL
        LD D,(HL):INC HL
        LD A,(HL):INC HL
        LD H,(HL),L,A
        EX DE,HL
        JP CLASSIFY_FILE_LINK           ; в томе и не кластер корня

APPEND_PREALLOCATE:
        LD A,(APPEND_WORK_NEEDS_CLUSTER):OR A:JR NZ,.allocate_all
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD A,D:OR E:OR H:OR L:JR Z,.allocate_all

        LD A,(APPEND_WORK_SECTOR)
        LD C,A
        LD A,(@WDOS.BSECPC)
        SUB C
        CP 33
        JR NC,.nothing
        ADD A,A
        LD H,A
        LD L,0
        LD DE,(APPEND_WORK_OFFSET)
        OR A:SBC HL,DE
        EX DE,HL
        LD HL,(APPEND_REMAINING)
        OR A:SBC HL,DE
        JR C,.nothing
        JR Z,.nothing
        JR .allocate

.allocate_all:
        LD HL,(APPEND_REMAINING)
.allocate:
        PUSH HL
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (APPEND_PENDING_OLD_TAIL),HL
        LD (APPEND_PENDING_OLD_TAIL+2),DE
        POP HL
        LD DE,0
        CALL MKSG_CHECKED               ; отказ чтения FAT — #FF, не 16
        RET NZ

        LD HL,(@WDOS.FCTS),DE,(@WDOS.FCTS+2)
        LD (APPEND_NEW_CLUSTER),HL
        LD (APPEND_NEW_CLUSTER+2),DE
        LD A,1
        LD (APPEND_PENDING_NEW),A

        LD HL,(APPEND_WORK_FIRST),DE,(APPEND_WORK_FIRST+2)
        LD A,D:OR E:OR H:OR L:JR NZ,.nothing
        LD HL,(APPEND_NEW_CLUSTER),DE,(APPEND_NEW_CLUSTER+2)
        LD (APPEND_WORK_FIRST),HL
        LD (APPEND_WORK_FIRST+2),DE
.nothing:
        XOR A
        RET

APPEND_ENSURE_CLUSTER:
        LD A,(APPEND_PENDING_NEW):OR A:JR Z,.bad_chain
        LD A,(APPEND_NEW_ACTIVE):OR A:JR NZ,.next_cluster
        LD HL,(APPEND_NEW_CLUSTER),DE,(APPEND_NEW_CLUSTER+2)
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        LD A,1
        LD (APPEND_NEW_ACTIVE),A
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        LD (APPEND_WORK_LBA_VALID),A
        RET

.next_cluster:
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        CALL APPEND_READ_FAT_LINK
        JR C,.bad_chain
        JR Z,.bad_chain
        LD (APPEND_WORK_CURRENT),HL
        LD (APPEND_WORK_CURRENT+2),DE
        XOR A
        LD (APPEND_WORK_NEEDS_CLUSTER),A
        LD (APPEND_WORK_LBA_VALID),A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

APPEND_POSITION_SECTOR:
        CALL APPEND_LBA_CACHE_MATCH
        JR Z,.recompute
        LD HL,(APPEND_WORK_LBA),DE,(APPEND_WORK_LBA+2)
        CALL APPEND_LBA_CACHE_RESTORE_STATE
        JR .add_sector
.recompute:
        LD HL,APPEND_WORK_CURRENT
        CALL @WDOS.GIPAG
        RET NZ
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        LD (APPEND_WORK_LBA),HL
        LD (APPEND_WORK_LBA+2),DE
        CALL APPEND_LBA_CACHE_TAG
        LD A,1
        LD (APPEND_WORK_LBA_VALID),A
.add_sector:
        LD A,(APPEND_WORK_SECTOR)
        ADD A,L:LD L,A:JR NC,.position
        INC H:JR NZ,.position
        INC DE
.position:
        CALL @WDOS.PROZ
        XOR A
        RET

APPEND_LBA_CACHE_MATCH:
        LD A,(APPEND_WORK_LBA_VALID):OR A:JR Z,.miss

        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_LBA_CLUSTER)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(APPEND_WORK_CURRENT+2),DE,(APPEND_WORK_LBA_CLUSTER+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD A,(@WDOS.BSECPC)
        LD B,A
        LD A,(APPEND_WORK_LBA_BSECPC)
        CP B:JR NZ,.miss

        LD HL,(@WDOS.SDFAT),DE,(APPEND_WORK_LBA_SDFAT)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(@WDOS.SDFAT+2),DE,(APPEND_WORK_LBA_SDFAT+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD HL,(@WDOS.ADDTOP),DE,(APPEND_WORK_LBA_ADDTOP)
        OR A:SBC HL,DE:JR NZ,.miss
        LD HL,(@WDOS.ADDTOP+2),DE,(APPEND_WORK_LBA_ADDTOP+2)
        OR A:SBC HL,DE:JR NZ,.miss

        LD A,1
        OR A
        RET
.miss:
        XOR A
        RET

APPEND_LBA_CACHE_TAG:
        PUSH HL,DE
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (APPEND_WORK_LBA_CLUSTER),HL
        LD (APPEND_WORK_LBA_CLUSTER+2),DE
        LD A,(@WDOS.BSECPC)
        LD (APPEND_WORK_LBA_BSECPC),A
        LD HL,(@WDOS.SDFAT),DE,(@WDOS.SDFAT+2)
        LD (APPEND_WORK_LBA_SDFAT),HL
        LD (APPEND_WORK_LBA_SDFAT+2),DE
        LD HL,(@WDOS.ADDTOP),DE,(@WDOS.ADDTOP+2)
        LD (APPEND_WORK_LBA_ADDTOP),HL
        LD (APPEND_WORK_LBA_ADDTOP+2),DE
        POP DE,HL
        RET

APPEND_LBA_CACHE_RESTORE_STATE:
        LD (@WDOS.LTHL),HL
        LD (@WDOS.LTDE),DE
        LD (@WDOS.CLHL),HL
        LD (@WDOS.CLDE),DE
        LD HL,(APPEND_WORK_CURRENT),DE,(APPEND_WORK_CURRENT+2)
        LD (@WDOS.CUHL),HL
        LD (@WDOS.CUDE),DE
        XOR A
        LD (@WDOS.NSDC),A
        LD (@WDOS.EOC),A
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        RET

APPEND_CLEAR_SECTOR:
        LD HL,@WDOS.LOBU,DE,@WDOS.LOBU+1,BC,511
        XOR A
        LD (HL),A
        LDIR
        RET

APPEND_COMMIT:
        XOR A:LD (APPEND_DIR_ATTEMPTED),A
        LD A,(APPEND_PENDING_NEW):OR A:JR Z,.directory
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        LD A,D:OR E:OR H:OR L:JR Z,.fsinfo
        CALL APPEND_LINK_NEW_CLUSTER
        RET NZ
.fsinfo:
        CALL RFRH_SAFE
        RET NZ
.directory:
        JP APPEND_UPDATE_DIRECTORY

APPEND_LINK_NEW_CLUSTER:
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        JR C,.bad_chain
        LD (APPEND_FAT_POINTER),HL
        LD DE,APPEND_OLD_LINK,BC,4
        LDIR
        LD HL,(APPEND_OLD_LINK),DE,(APPEND_OLD_LINK+2)
        CALL CLASSIFY_FAT_LINK
        JR C,.bad_chain
        JR NZ,.bad_chain

        LD HL,(APPEND_FAT_POINTER)
        LD DE,APPEND_NEW_CLUSTER
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(DE):LD (HL),A:INC DE,HL
        LD A,(HL):AND #F0:LD B,A
        LD A,(DE):AND #0F:OR B:LD (HL),A
        LD A,1
        LD (APPEND_LINKED_NEW),A
        CALL SAVE_FAT_SECTOR
        RET NZ
        XOR A
        RET
.bad_chain:
        LD A,APPEND_ERROR_BAD_CHAIN
        OR A
        RET

APPEND_VERIFY_DIRECTORY:
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ
        LD HL,@WDOS.LOBU,DE,(APPEND_DIRECTORY_OFFSET)
        ADD HL,DE
        LD (APPEND_SLOT_POINTER),HL
        LD DE,APPEND_ENTRY,BC,32
.compare:
        LD A,(DE):CP (HL):JR NZ,.changed
        INC DE,HL
        DEC BC
        LD A,B:OR C:JR NZ,.compare
        LD HL,(APPEND_SLOT_POINTER)
        XOR A
        RET
.changed:
        LD A,APPEND_ERROR_ENTRY_CHANGED
        OR A
        RET

APPEND_UPDATE_DIRECTORY:
        CALL APPEND_VERIFY_DIRECTORY
        RET NZ
        LD (APPEND_SLOT_POINTER),HL
        LD DE,20:ADD HL,DE
        LD DE,(APPEND_WORK_FIRST+2)
        LD (HL),E:INC HL:LD A,D:AND #0F:LD (HL),A
        LD HL,(APPEND_SLOT_POINTER),DE,26
        ADD HL,DE
        LD DE,(APPEND_WORK_FIRST)
        LD (HL),E:INC HL:LD (HL),D
        LD HL,(APPEND_SLOT_POINTER),DE,28
        ADD HL,DE
        LD DE,(APPEND_WORK_SIZE)
        LD (HL),E:INC HL:LD (HL),D:INC HL
        LD DE,(APPEND_WORK_SIZE+2)
        LD (HL),E:INC HL:LD (HL),D

        ; Новая запись — на случай неоднозначного отказа записи (APPEND_DIR_OUTCOME).
        LD HL,(APPEND_SLOT_POINTER),DE,APPEND_NEW_ENTRY,BC,32
        LDIR
        LD A,1:LD (APPEND_DIR_ATTEMPTED),A
        LD HL,(APPEND_DIRECTORY_LBA),DE,(APPEND_DIRECTORY_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ
APPEND_ENTRY_COMMITTED:
        XOR A:LD (APPEND_DIR_ATTEMPTED),A
        LD HL,APPEND_NEW_ENTRY,DE,APPEND_ENTRY,BC,32
        LDIR
        LD HL,APPEND_ENTRY,DE,@WDOS.ENTRY,BC,32
        LDIR
        XOR A
        RET

APPEND_ROLLBACK:
        LD A,(APPEND_PENDING_NEW):OR A:RET Z
        LD A,(APPEND_LINKED_NEW):OR A:JR Z,.release_new
        LD HL,(APPEND_PENDING_OLD_TAIL),DE,(APPEND_PENDING_OLD_TAIL+2)
        CALL @WDOS.CURIT
        RET C
        EX DE,HL
        LD HL,APPEND_OLD_LINK,BC,4
        LDIR
        CALL SAVE_FAT_SECTOR
        RET NZ
.release_new:
        XOR A
        LD (@WDOS.ABT),A
        LD HL,APPEND_NEW_CLUSTER
        CALL @WDOS.DLSG
        LD A,(@WDOS.ABT):OR A:RET NZ
        CALL RFRH_SAFE
        RET NZ
        XOR A
        LD (APPEND_PENDING_NEW),A
        LD (APPEND_LINKED_NEW),A
        LD (APPEND_NEW_ACTIVE),A
        RET

READ_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.RDDSE
        JR IO_RESULT

WRITE_SECTORS:
        PUSH AF
        XOR A:LD (@WDOS.ABT),A
        POP AF
        CALL @WDOS.SDDSE

IO_RESULT:
        LD A,(@WDOS.ABT)
        OR A:RET Z
        SCF
        RET

ZERO_CLUSTER_TAIL:
        LD (ZERO_CLUSTER_BUFFER_LOAD+1),HL
ZERO_CLUSTER_TAIL_NEXT:
        DEC A
        RET Z
        PUSH AF
        LD HL,(@WDOS.LTHL),DE,(@WDOS.LTDE)
        INC HL
        LD A,H:OR L:JR NZ,.lba_ready
        INC DE
.lba_ready:
        CALL @WDOS.XPOZI
ZERO_CLUSTER_BUFFER_LOAD:
        LD HL,0
        LD A,1
        CALL WRITE_SECTORS
        POP BC
        RET NZ
        LD A,B
        JR ZERO_CLUSTER_TAIL_NEXT

CLASSIFY_FAT_LINK:
        LD A,D:AND #0F:LD D,A
        OR E:OR H
        JR NZ,CLASSIFY_HIGH

CLASSIFY_LOW:
        LD A,L:CP 2:JR C,CLASSIFY_INVALID
        JR CLASSIFY_ORDINARY
CLASSIFY_HIGH:
        LD A,D:CP #0F:JR NZ,CLASSIFY_ORDINARY
        LD A,E:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,H:CP #FF:JR NZ,CLASSIFY_ORDINARY
        LD A,L:CP #F0:JR C,CLASSIFY_ORDINARY
        CP #F8:JR C,CLASSIFY_INVALID
        XOR A
        RET
CLASSIFY_ORDINARY:
        XOR A:INC A
        RET
CLASSIFY_INVALID:
        LD A,1:OR A
        SCF
        RET

IS_EOC_BEFORE_HL:
        PUSH HL
        DEC HL
        LD A,(HL):AND #0F:CP #0F:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #FF:JR NZ,.no
        DEC HL
        LD A,(HL):CP #F8:JR C,.no
        POP HL
        XOR A
        RET
.no:
        POP HL
        LD A,1:OR A
        RET

RECORD_FAT_LINK_ERROR:
        LD A,#FE
        LD (@WDOS.ABT),A
        INC A
        LD (@WDOS.EOC),A
        OR A
        RET

FAT_LINK_ERROR:
        CALL RECORD_FAT_LINK_ERROR
        SCF
        RET

; Короткое имя 8.3 запроса (ENTRY) годно, только если оно и есть весь запрос:
; пробел в имени и точка в конце (кроме служебных «.» и «..») переводят поиск
; на длинное имя. Прежде точка в конце терялась: «foo.» давало ту же форму 8.3,
; что и «foo», и FIND, DELETE, RENAME отсутствующего «foo.» брали файл FOO (а
; «алиас.» — файл с этим коротким алиасом).
REFINE_NAME_CLASSIFICATION:
        PUSH HL
        LD HL,(@WDOS.CGDE)
        INC HL
.scan:
        LD A,(HL):OR A:JR Z,.end
        CP " ":JR Z,.force_lfn
        INC HL
        JR .scan
.end:
        DEC HL
        LD A,(HL):CP ".":JR NZ,.done
        LD HL,(@WDOS.CGDE)
        INC HL
        CP (HL):JR NZ,.force_lfn                ; не с точки — не служебное
        INC HL
        LD A,(HL):OR A:JR Z,.done               ; «.»
        CP ".":JR NZ,.force_lfn
        INC HL
        LD A,(HL):OR A:JR Z,.done               ; «..»
.force_lfn:
        XOR A:LD (@WDOS.ENTRY),A
.done:
        POP HL
        LD A,1:OR A
        RET

; Имя новой записи. Знаки CP866 #B0..#DF (псевдографика) и #F2..#FF в длинное
; имя не переводятся (OEM2UC знает латиницу и русские буквы, Ё/ё) — имя
; недопустимо. Прежде они становились «ё»: RENAME сообщал успех под чужим
; именем, а MOVE не находил созданную ссылку и оставлял вторую запись на
; цепочке, которую следующий DELETE освобождал.
VALIDATE_NAME:
        LD B,255
        LD DE,0
.scan:
        LD A,(HL):OR A:JR Z,.terminated
        CALL @WDOS.ENCEN:JR Z,.bad
        CP #B0:JR C,.known
        CP #E0:JR C,.bad
        CP #F2:JR NC,.bad
.known:
        CP " ":JR Z,.next
        CP ".":JR Z,.next
        LD DE,HL
        INC DE
.next:
        INC HL
        DJNZ .scan
        LD A,(HL):OR A:JR NZ,.bad
.terminated:
        LD A,D:OR E:JR Z,.bad
        XOR A
        LD (DE),A
; Имя — копия в NXTBU (зовёт только ENTREZ): ENTREZ копирует 256 байт, и за
; концом имени лежал хвост буфера вызывающего — остатки прежнего имени.
; Основа короткого имени (LONG) читает 8 знаков подряд и брала их. Хвост до
; конца страницы NXTBU (#0000-#00FF) — нули.
        EX DE,HL
.zero:
        INC HL
        LD A,H:OR A
        JR NZ,.zeroed
        LD (HL),A
        JR .zero
.zeroed:
        XOR A                                   ; Z — имя годно
        RET
.bad:
        JP CLASSIFY_ORDINARY

; Слот шлюза оставлен ради нумерации входов; ядро его больше не зовёт.
BEGIN_LFN_COMPARE:
        RET

; Сравнение длинного имени со знаком запроса (DE) — замена ULNP. Знак за знаком
; без учёта регистра; начальные пробелы значимы, как в самом имени (CREATE их
; сохраняет). Прежде (как в WC) они пропускались и в запросе, и в имени на
; диске: « name» и «name» считались одним файлом — FIND, WRITE_AT, DELETE и
; RENAME попадали в соседний файл, а MOVE из одного такого имени в другое
; сообщал успех, ничего не сделав. Конец имени на диске (#0000, UCS даёт #FF)
; не совпадает ни с каким знаком: прежде знак запроса #FF совпадал с ним, и
; запрос на знак длиннее находил имя, если его конец приходился на последний
; знак записи LFN.
; CF=1 — знак совпал, сравнение продолжить; CF=0, Z — несовпадение; CF=0, NZ —
; оба имени кончились вместе.
COMPARE_LFN_CHAR:
        LD A,(DE):INC DE:OR A:JR Z,.query_end
        CALL @WDOS.ACS:LD C,A
        CALL @WDOS.UCS:OR A:JR Z,.mismatch
        CP #FF:JR Z,.mismatch                   ; имя на диске кончилось
        CALL @WDOS.ACS:CP C:JR Z,.continue
.mismatch:
        XOR A
        RET
.continue:
        SCF
        RET
.query_end:
        CALL @WDOS.UCS:INC A:JR NZ,.mismatch
        XOR A:INC A
        RET

ALLOCATE_FILE:
        LD A,D:OR E,H,L
        JR Z,.empty
        JP MKSG_CHECKED
.empty:
        LD (@WDOS.FCTS),HL
        LD (@WDOS.FCTS+2),HL
        RET

LOAD_FAT_CONFIG:
        LD A,(@WDOS.LOBU+16)
        LD (@WDOS.BFATS),A
        OR A:JR Z,.bad

        LD A,(@WDOS.LOBU+40)
        LD (@WDOS.FATFLAGS),A
        BIT 7,A:JR Z,.flags_ok
        AND #0F
        LD B,A
        LD A,(@WDOS.BFATS)
        CP B:JR Z,.bad:JR C,.bad
.flags_ok:
        LD HL,(@WDOS.LOBU+36)
        LD (@WDOS.BFTSZ),HL
        LD HL,(@WDOS.LOBU+38)
        LD (@WDOS.BFTSZ+2),HL

        LD HL,(@WDOS.LOBU+44)
        LD (@WDOS.BROOTC),HL
        LD HL,(@WDOS.LOBU+46)
        LD A,H:AND #0F:LD H,A
        LD (@WDOS.BROOTC+2),HL

        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

VALIDATE_FREE_HINT:
        PUSH HL,DE
        LD A,D:OR E:OR H:JR NZ,.minimum_ok
        LD A,L:CP 2:JR C,.bad_restore
.minimum_ok:
        LD BC,(FAT_DATA_CLUSTER_LIMIT)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(FAT_DATA_CLUSTER_LIMIT+2)
        SBC HL,BC
        EX DE,HL
        JR NC,.bad_restore
        POP DE,HL

        PUSH HL,DE
        CALL @WDOS.DEL128
        CALL FAT_SECTOR_IN_RANGE
        POP DE,HL
        JR NC,.bad
        XOR A
        RET
.bad_restore:
        POP DE,HL
.bad:
        LD A,1:OR A
        RET

; ---------------------------------------------------------------- геометрия
; (только при монтировании — в окне кода, не в рабочей странице)

; ---------------------------------------------------------------- записи по месту
; Короткую запись в секторе DE:HL по смещению BC (0..511, кратно 32) —
; удалённой (#E5) вместе с записями её длинного имени в том же секторе (они
; идут подряд перед ней) — и убедиться: до трёх попыток «прочитать — пометить
; — записать», затем перечитать. Удаление по имени для повтора не годится:
; стерев длинное имя и не записав короткую, при повторе оно её уже не находит.
; Выход: Z — на носителе #E5; NZ — не удалось либо смещение неизвестно (#FFFF).
; Разрушает AF, BC, DE, HL и LOBU.
ENTRY_KILL_AT:
        LD A,B:CP 2:JR NC,.fail
        LD A,C:AND #1F:JR NZ,.fail
        LD (KILL_LBA),HL
        LD (KILL_LBA+2),DE
        LD (KILL_OFFSET),BC
        LD A,4                                  ; три записи и проверка
.try:
        LD (KILL_LEFT),A
        CALL .position
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JR NZ,.next                             ; не прочитан — ещё раз
        LD HL,@WDOS.LOBU,DE,(KILL_OFFSET)
        ADD HL,DE
        LD A,(HL):CP #E5:RET Z                  ; на носителе удалена
        LD A,(KILL_LEFT):DEC A:JR Z,.fail       ; записей больше не будет
        LD (HL),#E5
        LD BC,(KILL_OFFSET)
.lfn:                                           ; её длинное имя в этом секторе
        LD A,B:OR C:JR Z,.write
        LD A,C:SUB 32:LD C,A
        LD A,B:SBC A,0:LD B,A
        LD HL,@WDOS.LOBU:ADD HL,BC
        LD A,(HL):CP #E5:JR Z,.write
        PUSH HL
        LD DE,11:ADD HL,DE
        LD A,(HL)
        POP HL
        CP #0F:JR NZ,.write
        LD (HL),#E5
        JR .lfn
.write:
        CALL .position
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET Z                                   ; легла
.next:
        LD A,(KILL_LEFT):DEC A
        JR NZ,.try
.fail:
        OR 1
        RET
.position:
        LD HL,(KILL_LBA),DE,(KILL_LBA+2)
        JP @WDOS.PROZ
; Геометрия тома из BPB (LOAD_FREE_HINT). Вход: DE:HL — всего секторов. Без
; переносов проверяются: конец тома (начало + всего; ровно 2**32 допустимо) в
; 32-битном LBA; том не длиннее своего раздела MBR/EBR (PARTSZ; без раздела —
; #FFFFFFFF, нулевая длина в таблице разделов — пустой раздел) и, у логического
; тома, лежит внутри расширенного раздела (EXTBAS, EXTSZ) — прежде сложение
; адреса в EBR заворачивалось, и том «находился» на чужом месте; область FAT
; (резерв + число FAT × размер) совпадает с SDFAT; за ней есть хотя бы кластер;
; номера кластеров — не больше #0FFFFFEF: прежде выданный номер #10000003 после
; маски становился номером 3 чужого файла, а номера #0FFFFFF0…#0FFFFFF6 ссылки
; FAT драйвер (как и WC) считает зарезервированными — созданный на них файл
; потом не открывался; одной FAT хватает записей на все номера. Выход: Z,
; DE:HL — исключающая граница номеров кластеров данных; NZ — BPB испорчен.
GEOMETRY_CHECK:
        LD (GEO_TOTAL),HL
        LD (GEO_TOTAL+2),DE
        LD BC,(@WDOS.ADDTOP):ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.ADDTOP+2):ADC HL,BC
        JR NC,.end_ok
        LD A,H:OR L:OR D:OR E:JP NZ,.bad        ; дальше 2**32
.end_ok:
        LD HL,(@WDOS.PARTSZ),DE,(@WDOS.PARTSZ+2)
        LD BC,(GEO_TOTAL):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(GEO_TOTAL+2):SBC HL,BC
        JP C,.bad                               ; том длиннее раздела
        LD A,(@WDOS.EXTVOL):OR A:JR Z,.contained
        LD HL,(@WDOS.ADDTOP),DE,(@WDOS.ADDTOP+2)
        LD BC,(@WDOS.EXTBAS):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.EXTBAS+2):SBC HL,BC
        EX DE,HL
        JP C,.bad                               ; до начала расширенного раздела
        LD BC,(GEO_TOTAL):ADD HL,BC
        EX DE,HL
        LD BC,(GEO_TOTAL+2):ADC HL,BC
        EX DE,HL
        JP C,.bad
        PUSH DE                                 ; конец тома от начала раздела
        PUSH HL
        LD HL,(@WDOS.EXTSZ):POP BC:OR A:SBC HL,BC
        LD HL,(@WDOS.EXTSZ+2):POP BC:SBC HL,BC
        JP C,.bad                               ; за концом расширенного раздела
.contained:
        LD HL,(@WDOS.BREZS):LD DE,0
        LD A,(@WDOS.BFATS):LD B,A
.fat_area:
        PUSH BC
        LD BC,(@WDOS.BFTSZ):ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2):ADC HL,BC
        EX DE,HL
        POP BC
        JP C,.bad
        DJNZ .fat_area
        LD BC,(@WDOS.SDFAT):OR A:SBC HL,BC
        JP NZ,.bad                              ; SDFAT посчитан с переносом
        EX DE,HL
        LD BC,(@WDOS.SDFAT+2):SBC HL,BC
        JP NZ,.bad
        LD HL,(GEO_TOTAL),DE,(GEO_TOTAL+2)
        LD BC,(@WDOS.SDFAT):OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.SDFAT+2):SBC HL,BC
        EX DE,HL
        JP C,.bad                               ; том кончается до области данных
        LD A,(@WDOS.BSECPC)
.divide:
        CP 1:JR Z,.clusters
        SRL D:RR E:RR H:RR L
        SRL A
        JR .divide
.clusters:
        LD A,D:OR E:OR H:OR L:JP Z,.bad         ; ни одного кластера
        LD BC,2:CALL @WDOS.ADD4B                ; граница: кластеров + 2
        LD A,D:CP #10:JP NC,.bad                ; 28 бит FAT32
        CP #0F:JR NZ,.fat_size
        LD A,E:CP #FF:JR NZ,.fat_size
        LD A,H:CP #FF:JR NZ,.fat_size
        LD A,L:CP #F1:JP NC,.bad                ; граница не дальше #0FFFFFF0
; Одна FAT держит по записи на каждый номер ниже границы (128 на сектор).
; Прежде том с короткой FAT монтировался, и номера без записи в FAT
; считались годными.
.fat_size:
        PUSH HL
        PUSH DE
        LD BC,127:CALL @WDOS.ADD4B
        LD B,7
.need:
        SRL D:RR E:RR H:RR L
        DJNZ .need                              ; секторов FAT на все номера
        PUSH DE
        PUSH HL
        LD HL,(@WDOS.BFTSZ):POP BC:OR A:SBC HL,BC
        LD HL,(@WDOS.BFTSZ+2):POP BC:SBC HL,BC
        POP DE
        POP HL
        JP C,.bad                               ; FAT короче
        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

; Логический том текущего EBR (FHDD_EXTENDED, EBR — в LOBU): PARTSZ — длина
; из его записи, DE:HL — начало тома (смещение от этого EBR), EXTCUR —
; следующий EBR (ссылка от первого EBR; 0 — последний), EXTVOL=1. CF=1 —
; начало тома за 2**32: EBR испорчен, обход кончается. Прежде перенос терялся,
; и завёрнутый адрес указывал на другой том внутри расширенного раздела.
; Ссылка на следующий EBR за 2**32 — конец цепочки.
EBR_ENTRY:
        LD HL,@WDOS.LOBU+446+12,DE,@WDOS.PARTSZ,BC,4:LDIR
        LD HL,(@WDOS.LOBU+446+8),DE,(@WDOS.LOBU+446+8+2)
        LD BC,(@WDOS.EXTCUR):ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.EXTCUR+2):ADC HL,BC
        EX DE,HL
        RET C                                   ; начало тома за 2**32
        PUSH DE
        PUSH HL
        LD HL,(@WDOS.LOBU+446+16+8),DE,(@WDOS.LOBU+446+16+8+2)
        LD A,H:OR L:OR D:OR E
        JR Z,.store                             ; последний EBR
        LD BC,(@WDOS.EXTBAS):ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.EXTBAS+2):ADC HL,BC
        EX DE,HL
        JR NC,.store
        LD HL,0:LD D,H:LD E,L                   ; за 2**32 — цепочка кончается
.store:
        LD (@WDOS.EXTCUR),HL
        LD (@WDOS.EXTCUR+2),DE
        LD A,1:LD (@WDOS.EXTVOL),A
        POP HL
        POP DE
        OR A                                    ; CF=0
        RET

LOAD_FREE_HINT:
        XOR A:LD (ROOT_READY),A                 ; новый том — цепочку корня заново
        LD HL,2:LD (@WDOS.FSTFRC),HL
        LD (FAT_DATA_CLUSTER_LIMIT),HL
        LD HL,0:LD (@WDOS.FSTFRC+2),HL
        LD (FAT_DATA_CLUSTER_LIMIT+2),HL

        LD HL,(@WDOS.LOBU+19)
        LD A,H:OR L:JR Z,.total32
        LD DE,0
        JR .total_ready
.total32:
        LD HL,(@WDOS.LOBU+32),DE,(@WDOS.LOBU+34)
.total_ready:
        CALL GEOMETRY_CHECK                     ; DE:HL — граница кластеров данных
        JP NZ,.bad_geometry
        LD (FAT_DATA_CLUSTER_LIMIT),HL
        LD (FAT_DATA_CLUSTER_LIMIT+2),DE
        CALL SET_COLD_FREE_HINT

        CALL FSINFO_POSITION
        JR C,.done
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        JR NZ,.done
        CALL VALIDATE_FSINFO_SECTOR
        JR NZ,.done
        LD HL,(@WDOS.LOBU+492),DE,(@WDOS.LOBU+494)
        CALL VALIDATE_FREE_HINT
        JR NZ,.done
        LD (@WDOS.CAHL),HL
        LD (@WDOS.CADE),DE
        CALL @WDOS.CURIT
        JR C,.done
        LD A,(HL):INC HL
        OR (HL):INC HL
        OR (HL):INC HL
        OR (HL):JR NZ,.done
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
.done:
        XOR A
        LD (@WDOS.ABT),A
        RET
.bad_geometry:
        LD A,1:OR A                             ; NZ: LDBPB — как неверный BPB
        RET

SET_COLD_FREE_HINT:
        LD HL,(FAT_DATA_CLUSTER_LIMIT),DE,(FAT_DATA_CLUSTER_LIMIT+2)
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
        LD B,4
.divide:
        SRL D:RR E:RR H:RR L
        DJNZ .divide
        LD (@WDOS.CAHL),HL
        LD (@WDOS.CADE),DE
        LD HL,(@WDOS.FSTFRC),BC,(@WDOS.CAHL)
        OR A:SBC HL,BC
        LD (@WDOS.FSTFRC),HL
        LD HL,(@WDOS.FSTFRC+2),BC,(@WDOS.CADE)
        SBC HL,BC
        LD (@WDOS.FSTFRC+2),HL
        RET

GET_DATA_CLUSTER_LIMIT:
        LD HL,(FAT_DATA_CLUSTER_LIMIT),DE,(FAT_DATA_CLUSTER_LIMIT+2)
        XOR A
        RET

SAVE_NEXT_FREE_HINT:
        PUSH AF,BC,DE,HL
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR Z,.store
        LD HL,2:LD DE,0
.store:
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
        POP HL,DE,BC,AF
        RET

; Начало DLSG: голова освобождаемой цепочки — подсказка поиска, только если это
; допустимый кластер данных (прежде сюда попадал и отвергнутый затем кластер 1,
; и поиск места сразу заявлял «места нет»); затем таблица цепочки корня для
; CLASSIFY_DATA — до первой правки SECBU.
NOTE_FREED_CHAIN:
        LD HL,(@WDOS.LOBU),DE,(@WDOS.LOBU+2)
        LD A,D:OR E:OR H:OR L:RET Z
        CALL VALIDATE_FREE_HINT
        JR NZ,.root
        LD (@WDOS.FSTFRC),HL
        LD (@WDOS.FSTFRC+2),DE
.root:
        JP ROOT_SETUP

POSITION_FAT_INDEX:
        OR A:JR Z,.base
.next:
        LD BC,(@WDOS.BFTSZ)
        ADD HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        ADC HL,BC
        EX DE,HL
        DEC A:JR NZ,.next
.base:
        LD BC,(@WDOS.SFAT)
        CALL @WDOS.ADD4B
        CALL @WDOS.XSPOZ
        JP @WDOS.XPOZI

POSITION_FAT_READ:
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.fat0
        AND #0F
        JP POSITION_FAT_INDEX
.fat0:
        XOR A
        JP POSITION_FAT_INDEX

FAT_SECTOR_IN_RANGE:
        PUSH HL,DE
        LD BC,(@WDOS.BFTSZ)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.BFTSZ+2)
        SBC HL,BC
        POP DE,HL
        RET

SAVE_FAT_SECTOR:
        LD A,(@WDOS.FATFLAGS)
        BIT 7,A:JR Z,.mirrored
        AND #0F
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        JP WRITE_SECTORS

.mirrored:
        LD A,(@WDOS.BFATS)
        OR A:JR Z,.failed
        LD B,A
        XOR A
.copy:
        PUSH BC,AF
        LD HL,(@WDOS.LSTSE),DE,(@WDOS.LSTSE+2)
        CALL POSITION_FAT_INDEX
        LD HL,@WDOS.SECBU,A,1
        CALL WRITE_SECTORS
        POP DE,BC
        RET NZ
        LD A,D
        INC A
        DJNZ .copy
        XOR A
        RET
.failed:
        JP CLASSIFY_ORDINARY

INIT_FREE_SCAN:
        LD HL,(@WDOS.CAHL)
        LD (@WDOS.DABC),HL
        LD HL,(@WDOS.CADE)
        LD (@WDOS.DAHL),HL
        XOR A:LD (@WDOS.DUBA),A
        LD (FREE_SCAN_IO_FAILED),A               ; отказов чтения FAT ещё не было
        RET

; Слот курсора CAHL перед проверкой (FC ядра). Кластер вне области данных
; тома (последний сектор FAT держит слоты за её концом, испорченная подсказка)
; не выдаётся: переход к кластеру 2 (NEXT_FREE_FAT_SECTOR.wrap) — тогда HL —
; его слот. Обход замкнулся (после перехода курсор дошёл до начала поиска) —
; CF=1, места нет. HL — слот, сохраняется; портит A, BC, DE.
CHECK_FREE_SCAN_LIMIT:
        PUSH HL
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR Z,.valid
        POP HL
        JP NEXT_FREE_FAT_SECTOR.wrap
.valid:
        LD A,(@WDOS.DUBA):OR A:JR Z,.more
        LD DE,(@WDOS.DABC)
        OR A:SBC HL,DE:JR NZ,.more
        LD HL,(@WDOS.CADE),DE,(@WDOS.DAHL)
        OR A:SBC HL,DE:JR NZ,.more
        POP HL
        SCF
        RET
.more:
        POP HL
        OR A
        RET

; Сектор FAT курсора CAHL (SRHFC ядра): HL — слот курсора, CF=0. Курсор вне
; области данных — переход к кластеру 2 (один раз за поиск); второй раз или
; поиск начат с 2 — CF=1, места нет. Отказ чтения FAT — CF=1 и код в
; FREE_SCAN_IO_FAILED (MKSG_CHECKED, DIR_GROW: отказ носителя, не «нет места»).
; Прежде следующий сектор брался по LSTSE без проверки курсора.
NEXT_FREE_FAT_SECTOR:
        LD HL,(@WDOS.CAHL),DE,(@WDOS.CADE)
        CALL VALIDATE_FREE_HINT
        JR NZ,.wrap
.read:
        CALL @WDOS.CURIT
        RET NC
        LD A,(@WDOS.ABT)
        LD (FREE_SCAN_IO_FAILED),A
        SCF
        RET

.wrap:
        LD A,(@WDOS.DUBA):OR A:JR NZ,.full
        LD HL,(@WDOS.DAHL)
        LD A,H:OR L:JR NZ,.do_wrap
        LD HL,(@WDOS.DABC)
        LD A,H:OR A:JR NZ,.do_wrap
        ; Поиск начат ровно с 2 — пройдено всё. С 0 или 1 (недопустимая
        ; подсказка) от 2 ещё не искали: прежде это тоже считалось полным обходом.
        LD A,L:CP 2:JR Z,.full
.do_wrap:
        LD A,1:LD (@WDOS.DUBA),A
        LD HL,2:LD (@WDOS.CAHL),HL
        LD HL,0:LD (@WDOS.CADE),HL
        LD DE,0:LD HL,2
        JR .read
.full:
        SCF
        RET

RESET_DIR_HISTORY:
        XOR A
        LD (DIR_OLDER_VALID),A
        RET

SAVE_PREVIOUS_DIR_LBA:
        PUSH HL
        LD HL,(@WDOS.LLHL)
        LD (DIR_PREVIOUS_LBA),HL
        LD HL,(@WDOS.LLHL+2)
        LD (DIR_PREVIOUS_LBA+2),HL
        POP HL
        RET

PRESERVE_OLDER_DIR_SECTOR:
        PUSH AF,BC,DE,HL
        LD HL,@WDOS.LOBU,DE,DIR_OLDER_BUFFER,BC,512
        LDIR
        LD HL,(DIR_PREVIOUS_LBA)
        LD (DIR_OLDER_LBA),HL
        LD HL,(DIR_PREVIOUS_LBA+2)
        LD (DIR_OLDER_LBA+2),HL
        LD A,1:LD (DIR_OLDER_VALID),A
        POP HL,DE,BC,AF
        RET

; Указатель записи LFN при обратном проходе (LNPARZ). LOBU и LOBU2 идут
; подряд; ниже LOBU — позапрошлый сектор, его копия в DIR_OLDER_BUFFER: адрес
; #31xx переводится в #21xx. Прежде допускался только этот первый перевод, и
; следующая запись (#21C0 и ниже) отвергалась: имя, чьи записи LFN занимали
; три сектора, не находилось, и ENTRY_LANDED принимал легшую запись за
; отсутствующую — цепочку освобождали под живой записью.
MAP_OLDER_LFN_POINTER:
        LD A,H:CP high @WDOS.LOBU:JR NC,.ok
        CP high @WDOS.LOBU-1:JR Z,.enter
        CP high DIR_OLDER_BUFFER:JR C,.bad      ; уже в DIR_OLDER_BUFFER?
        CP high (DIR_OLDER_BUFFER+512):JR NC,.bad
        LD A,(DIR_OLDER_VALID):OR A:JR Z,.bad
        JR .ok
.enter:
        LD A,(DIR_OLDER_VALID):OR A:JR Z,.bad
        LD A,H:SUB #10:LD H,A
.ok:
        OR A
        RET
.bad:
        SCF
        RET

DELETE_ENTRY_WITH_LFN:
        LD H,B,L,C
        PUSH HL
        CALL @WDOS.LNCRC
        LD (DIR_LFN_CHECKSUM),A
        POP HL
        LD (HL),#E5
        LD A,B:AND #FE
        LD (@WDOS.COUNT),A
        LD D,A
        LD A,1:LD (DIR_EXPECTED_SEQUENCE),A
        XOR A
        LD (DIR_PREVIOUS_DIRTY),A
        LD (DIR_OLDER_DIRTY),A

.current:
        LD BC,0-32:ADD HL,BC
        LD A,H:CP D:JR C,.previous
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        JR C,.write
        JR .current

.previous:
        LD A,D:CP high @WDOS.LOBU2:JR NZ,.write
        LD HL,@WDOS.LOBE-32
.prev_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_PREVIOUS_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high @WDOS.LOBU:JR NC,.prev_loop

        LD A,(DIR_OLDER_VALID):OR A:JR Z,.write
        LD HL,DIR_OLDER_BUFFER+512-32
.older_loop:
        CALL .match_lfn:JR NZ,.write
        LD (HL),#E5
        LD A,1:LD (DIR_OLDER_DIRTY),A
        JR C,.write
        LD BC,0-32:ADD HL,BC
        LD A,H:CP high DIR_OLDER_BUFFER:JR NC,.older_loop

.write:
        LD A,(DIR_OLDER_DIRTY):OR A:JR Z,.write_previous
        LD HL,(DIR_OLDER_LBA),DE,(DIR_OLDER_LBA+2)
        CALL @WDOS.PROZ
        LD HL,DIR_OLDER_BUFFER,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_previous:
        LD A,(DIR_PREVIOUS_DIRTY):OR A:JR Z,.write_current
        LD HL,(DIR_PREVIOUS_LBA),DE,(DIR_PREVIOUS_LBA+2)
        CALL @WDOS.PROZ
        LD HL,@WDOS.LOBU,A,1
        CALL WRITE_SECTORS
        RET NZ

.write_current:
        LD HL,(@WDOS.LLHL),DE,(@WDOS.LLHL+2)
        CALL @WDOS.PROZ
        LD A,(@WDOS.COUNT)
        LD H,A,L,0
        LD A,1
        JP WRITE_SECTORS

.match_lfn:
        PUSH HL,DE
        LD A,(HL):LD D,A
        AND #1F:LD E,A
        LD A,(DIR_EXPECTED_SEQUENCE):CP E:JR NZ,.not_lfn
        LD BC,11:ADD HL,BC
        LD A,(HL):CP #0F:JR NZ,.not_lfn
        INC HL,HL
        LD A,(DIR_LFN_CHECKSUM):CP (HL):JR NZ,.not_lfn
        LD A,(DIR_EXPECTED_SEQUENCE):INC A
        LD (DIR_EXPECTED_SEQUENCE),A
        BIT 6,D:JR NZ,.last_lfn
        POP DE,HL
        XOR A
        RET
.last_lfn:
        POP DE,HL
        XOR A
        SCF
        RET
.not_lfn:
        POP DE,HL
        LD A,1:OR A
        RET

RFRH_SAFE:
        CALL FSINFO_POSITION
        JR C,.skip
        LD HL,@WDOS.LOBU,A,1
        CALL READ_SECTORS
        RET NZ

        CALL VALIDATE_FSINFO_SECTOR
        JR NZ,.skip

        LD HL,#FFFF
        LD (@WDOS.LOBU+488),HL
        LD (@WDOS.LOBU+490),HL
        LD HL,(@WDOS.FSTFRC),DE,(@WDOS.FSTFRC+2)
        CALL VALIDATE_FREE_HINT
        JR Z,.have_hint
        LD HL,#FFFF,DE,HL
.have_hint:
        LD (@WDOS.LOBU+492),HL
        LD (@WDOS.LOBU+494),DE
        LD HL,@WDOS.LOBU,A,1
        JP WRITE_SECTORS
.skip:
        ; FSInfo — подсказка. Неверную сигнатуру не исправляем и не записываем;
        ; выделение кластеров продолжает опираться на саму FAT.
        XOR A
        RET

FSINFO_POSITION:
        ; Допустим только ненулевой сектор внутри зарезервированной области.
        LD HL,(@WDOS.FSINF),DE,(@WDOS.FSINF+2)
        PUSH DE,HL
        LD BC,(@WDOS.ADDTOP)
        OR A:SBC HL,BC
        EX DE,HL
        LD BC,(@WDOS.ADDTOP+2)
        SBC HL,BC
        LD A,H:OR L:JR NZ,.invalid
        LD A,D:OR E:JR Z,.invalid
        LD HL,(@WDOS.BREZS)
        OR A:SBC HL,DE
        JR C,.invalid
        JR Z,.invalid
        POP HL,DE
        XOR A
        JP @WDOS.XPOZI
.invalid:
        POP HL,DE
        SCF
        RET

VALIDATE_FSINFO_SECTOR:
        LD HL,(@WDOS.LOBU+0),DE,#5252
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+2),DE,#4161
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+484),DE,#7272
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+486),DE,#6141
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+508),DE,0
        OR A:SBC HL,DE:JR NZ,.bad
        LD HL,(@WDOS.LOBU+510),DE,#AA55
        OR A:SBC HL,DE:JR NZ,.bad
        XOR A
        RET
.bad:
        LD A,1:OR A
        RET

STREAM_IO_ERROR:
        LD A,#FF
        LD (@WDOS.ABT),A
        LD (@WDOS.EOC),A
        SCF
        RET

DSDZC_RUNTIME_READS EQU #393F
DSDZC_RUNTIME_CSH   EQU #3B17
DSDZC_RUNTIME_CMD18 EQU #3BB5
DSDZC_RUNTIME_CMD25 EQU #3BEA
DSDZC_RUNTIME_WAIT  EQU #3C6D

UNPACK_DRIVER:
        XOR A
        RET

        IFDEF WDOS_EXPERIMENTAL_ZC_RUNTIME

ZC_MARK_ERROR:
        LD A,1
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

ZC_WAIT_READY:
        PUSH AF,BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        INC A
        JR Z,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
.ready:
        POP HL,DE,BC,AF
        RET

ZC_WAIT_TOKEN:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        CP #FF
        JR NZ,.received
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,#FF
        OR A
        RET
.received:
        POP HL,DE,BC
        RET

ZC_WAIT_BUSY:
        PUSH BC,DE,HL
        LD E,8
.outer:
        LD HL,0
        LD BC,#0057
.poll:
        IN A,(C)
        OR A
        JR NZ,.ready
        DEC HL
        LD A,H:OR L
        JR NZ,.poll
        DEC E
        JR NZ,.outer
        CALL ZC_MARK_ERROR
        POP HL,DE,BC
        LD A,1
        OR A
        RET
.ready:
        POP HL,DE,BC
        XOR A
        RET

ZC_DATA_RESPONSE:
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        CALL ZC_WAIT_TOKEN
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:AND #1F:CP 5:JR NZ,.mark
        CALL ZC_WAIT_BUSY
        JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

ZC_DMA_WAIT:
        PUSH AF,DE
        LD BC,#27AF
        LD DE,0
.poll:
        INF
        JP P,.ready
        DEC DE
        LD A,D:OR E
        JR NZ,.poll
        CALL ZC_MARK_ERROR
        POP DE,AF
        SCF
        RET
.ready:
        POP DE,AF
        OR A
        RET

ZC_START_READ:
        XOR A
        LD (@WDOS.ABT),A
        CALL DSDZC_RUNTIME_CMD18
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        XOR A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

ZC_READ_BLOCK:
        CALL DSDZC_RUNTIME_READS
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.failed:
        CALL DSDZC_RUNTIME_CSH
        LD A,1
        OR A
        RET

ZC_WRITE_READY:
        XOR A
        LD (@WDOS.ABT),A
        IN A,(#77)
        AND 2
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR

ZC_START_WRITE:
        CALL DSDZC_RUNTIME_CMD25
        LD C,A
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        LD A,C:OR A:JR NZ,.mark
        CALL DSDZC_RUNTIME_WAIT
        LD A,(@WDOS.ABT):OR A:JR NZ,.failed
        EX AF,AF'
        CP A
        RET
.mark:
        CALL ZC_MARK_ERROR
.failed:
        LD A,1
        OR A
        RET

ZC_CHECK_TOKEN:
        CP #FE
        JR NZ,.failed
        XOR A
        RET
.failed:
        JP ZC_MARK_ERROR

        ENDIF

FAT_DATA_CLUSTER_LIMIT:       DS 4

APPEND_VALID:                 DS 1
APPEND_READY:                 DS 1
APPEND_FOUND_POINTER:         DS 2
APPEND_DIRECTORY_LBA:         DS 4
APPEND_DIRECTORY_OFFSET:      DS 2
APPEND_ENTRY:                 DS 32

APPEND_CONTEXT:
APPEND_SIZE:                  DS 4
APPEND_FIRST_CLUSTER:         DS 4
APPEND_CURRENT_CLUSTER:       DS 4
APPEND_SECTOR:                DS 1
APPEND_OFFSET:                DS 2
APPEND_NEEDS_CLUSTER:         DS 1
APPEND_LBA_VALID:             DS 1
APPEND_LBA_CLUSTER:           DS 4
APPEND_LBA_BSECPC:            DS 1
APPEND_LBA_SDFAT:             DS 4
APPEND_LBA_ADDTOP:            DS 4
APPEND_LBA:                   DS 4
APPEND_CONTEXT_END:
APPEND_CONTEXT_SIZE           EQU APPEND_CONTEXT_END-APPEND_CONTEXT

APPEND_WORK_CONTEXT:
APPEND_WORK_SIZE:             DS 4
APPEND_WORK_FIRST:            DS 4
APPEND_WORK_CURRENT:          DS 4
APPEND_WORK_SECTOR:           DS 1
APPEND_WORK_OFFSET:           DS 2
APPEND_WORK_NEEDS_CLUSTER:    DS 1
APPEND_WORK_LBA_VALID:        DS 1
APPEND_WORK_LBA_CLUSTER:      DS 4
APPEND_WORK_LBA_BSECPC:       DS 1
APPEND_WORK_LBA_SDFAT:        DS 4
APPEND_WORK_LBA_ADDTOP:       DS 4
APPEND_WORK_LBA:              DS 4
        ASSERT $-APPEND_WORK_CONTEXT == APPEND_CONTEXT_SIZE, различается контекст APPEND

APPEND_SOURCE:                DS 2
APPEND_REMAINING:             DS 2
APPEND_CHUNK:                 DS 2
APPEND_RUN:                   DS 1
APPEND_SKIP_COUNT:            DS 4
APPEND_PENDING_NEW:           DS 1
APPEND_LINKED_NEW:            DS 1
APPEND_NEW_ACTIVE:            DS 1
APPEND_PENDING_OLD_TAIL:      DS 4
APPEND_NEW_CLUSTER:           DS 4
APPEND_OLD_LINK:              DS 4
APPEND_FAT_POINTER:           DS 2
APPEND_SLOT_POINTER:          DS 2
APPEND_LAST_ERROR:            DS 1
KILL_LBA:                     DS 4
KILL_OFFSET:                  DS 2
KILL_LEFT:                    DS 1

DIR_PREVIOUS_LBA       EQU @WDOS.EXT_DIR_PREVIOUS_LBA
DIR_OLDER_LBA          EQU @WDOS.EXT_DIR_OLDER_LBA
DIR_OLDER_VALID        EQU @WDOS.EXT_DIR_OLDER_VALID
DIR_PREVIOUS_DIRTY     EQU @WDOS.EXT_DIR_PREVIOUS_DIRTY
DIR_OLDER_DIRTY        EQU @WDOS.EXT_DIR_OLDER_DIRTY
DIR_EXPECTED_SEQUENCE  EQU @WDOS.EXT_DIR_EXPECTED_SEQUENCE
DIR_LFN_CHECKSUM       EQU @WDOS.EXT_DIR_LFN_CHECKSUM
DIR_OLDER_BUFFER       EQU #2000

RUNTIME_END:
        ASSERT RUNTIME_END <= #10000, расширение вышло за пределы физической страницы
