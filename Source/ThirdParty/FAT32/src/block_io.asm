; Независимый от накопителя секторный адаптер. Таблица устройства содержит
; четыре 16-битных адреса: init, read512, write512, sync. Для init A=устройство;
; для обмена DE:HL=абсолютный LBA, BC=буфер 512 байт. A=0: успех, иначе ошибка.
; Обработчики сохраняют IX, IY и альтернативные регистры; банки здесь не меняются.
DRIVER_BIND:
        LD (BLOCK_UNIT),A
        LD DE,BLOCK_CALLBACKS,BC,8
        LDIR
        LD HL,WDOS.DRVR,DE,WDOS.DRVR+1,BC,WDOS.RECCAT+3-WDOS.DRVR
        LD (HL),0
        LDIR
        LD HL,BLOCK_JUMPS,DE,WDOS.DRVR,BC,24
        LDIR
        LD HL,2
        LD (WDOS.FSTFRC),HL
        XOR A
        LD (FAT_MOUNTED),A
        LD (BLOCK_READY),A
        CALL FAT_INVALIDATE
        LD A,1
        LD (BLOCK_BOUND),A
        XOR A
        RET

BLOCK_JUMPS:
        JP BLOCK_SELECT
        JP FAT_DEVICE_INIT
        JP BLOCK_SYNC
        JP BLOCK_POSITION
        JP BLOCK_POSITION_ONLY
        JP BLOCK_READ
        JP BLOCK_WRITE
        JP BLOCK_READ256
BLOCK_SELECT:
        CALL FILEX_MEDIA_CHANGED
        LD (BLOCK_UNIT),A
        XOR A
        RET
BLOCK_POSITION:
        LD (WDOS.LTHL),HL
        LD (WDOS.LTDE),DE
BLOCK_POSITION_ONLY:
        LD (BLOCK_LBA),HL
        LD (BLOCK_LBA+2),DE
        RET
BLOCK_INIT:
        LD HL,(BLOCK_CALLBACKS)
        LD A,(BLOCK_UNIT)
        JP (HL)
BLOCK_SYNC:
        LD HL,(BLOCK_CALLBACKS+6)
        CALL .invoke
        OR A
        CALL NZ,FILEX_MEDIA_CHANGED
        RET
.invoke:
        JP (HL)
BLOCK_READ:
        PUSH DE
        LD DE,(BLOCK_CALLBACKS+2)
        JR BLOCK_LINEAR
BLOCK_WRITE:
        PUSH DE
        LD DE,(BLOCK_CALLBACKS+4)
        PUSH AF
        LD A,2                          ; отдельный режим: сброс перед каждым сектором
        JR BLOCK_MODE
BLOCK_LINEAR:
        PUSH AF
        XOR A
        JR BLOCK_MODE
BLOCK_READ256:
        PUSH DE
        LD DE,(BLOCK_CALLBACKS+2)
        PUSH AF
        LD A,1
BLOCK_MODE:
        LD (BLOCK_VIDEO),A
        POP AF
BLOCK_TRANSFER:
        LD (BLOCK_CALL+1),DE
        POP DE
        ; Продвигается только временная позиция внутри обмена. Старое ядро
        ; читает и записывает один сектор без повторного PROZ, например FSInfo.
        EX DE,HL
        LD HL,(BLOCK_LBA+2)
        PUSH HL
        LD HL,(BLOCK_LBA)
        PUSH HL
        EX DE,HL
        LD B,A
.loop:
        PUSH BC
        PUSH HL
        LD B,H,C,L
        LD A,(BLOCK_VIDEO)
        CP 1
        JR NZ,.buffer_ready
        LD BC,WDOS.LOBU2
.buffer_ready:
        CALL FILEX_BUFFER_REUSED
        LD HL,(BLOCK_LBA)
        LD DE,(BLOCK_LBA+2)
BLOCK_CALL:
        CALL 0
        LD (WDOS.ABT),A
        OR A
        CALL NZ,FILEX_MEDIA_CHANGED
        POP HL
        POP BC
        OR A
        JR NZ,.failed
        LD A,(BLOCK_VIDEO)
        CP 1
        JR Z,.video
        INC H
        INC H
        JR .position
.video:
        ; Две строки по 256 байт на сектор, шаг строк в памяти — 512 байт.
        ; Это раскладка исходных видеопутей Nemo PIO и DMA TS-Conf.
        PUSH BC
        EX DE,HL
        LD HL,WDOS.LOBU2,BC,256
        LDIR
        INC D
        LD BC,256
        LDIR
        INC D
        EX DE,HL
        POP BC
.position:
        PUSH HL
        LD HL,(BLOCK_LBA)
        INC HL
        LD (BLOCK_LBA),HL
        LD A,H:OR L
        JR NZ,.next
        LD HL,(BLOCK_LBA+2)
        INC HL
        LD (BLOCK_LBA+2),HL
.next:
        POP HL
        DJNZ BLOCK_TRANSFER.loop
        XOR A
        JR BLOCK_RESTORE_POSITION
.failed:
        SCF
BLOCK_RESTORE_POSITION:
        EX DE,HL
        POP HL
        LD (BLOCK_LBA),HL
        POP HL
        LD (BLOCK_LBA+2),HL
        EX DE,HL
        RET
BLOCK_CALLBACKS: DS 8
BLOCK_LBA:      DS 4
BLOCK_UNIT:     DB 0
BLOCK_BOUND:    DB 0
BLOCK_READY:    DB 0
BLOCK_VIDEO:    DB 0
