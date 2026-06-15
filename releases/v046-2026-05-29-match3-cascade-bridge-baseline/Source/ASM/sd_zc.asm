;//////////////////////////////////////////////////////////////
;//  Self-contained SD (Z-Controller) raw sector read.
;//  Ported from the WC device driver DSDZC.ASM read path
;//  (via Desktop/WC/Chkdsk/src/sd_zc.a80 by the ChkDsk session).
;//  The card is already initialised by WC before the SPG launches
;//  (hardware state persists), so we only issue CMD17 reads.
;//
;//  This BYPASSES the bundled TS-DOS driver, whose FAT chain walk
;//  drifts -128 sectors at the first FAT-sector boundary in our SPG
;//  context. We do our own BPB/FAT walk on top of sd_read_sector.
;//
;//  Unreal/this host uses BYTE addressing (sd_blkt = 0): the CMD17
;//  argument is LBA*512. (Real SDHC would use block addressing.)
;//////////////////////////////////////////////////////////////

SD_CONF         equ     #77             ; config / chip-select port
SD_DATA         equ     #57             ; data port
SD_CMD17        equ     %01000000+17    ; single-block read
SD_CS1          equ     %00000001       ; chip select, SD1

;--- sd_init: byte addressing (Unreal). sd_blkt = 0.
sd_init:
                xor     a
                ld      (sd_blkt),a
                call    sd_csh
                call    sd_snb
                ret

;--- sd_read_sector: read one 512-byte sector
;    in:  HL = LBA (low 16), DE = LBA (high 16)  [LBA is 32-bit]
;         IX = destination buffer (512 bytes)
;    out: CF = 1 on error, CF = 0 on success
sd_read_sector:
                ld      (sd_lba+0),hl
                ld      (sd_lba+2),de
                push    ix
                pop     hl                      ; HL = buffer
                call    sd_cmd17
                jr      nz,.err                 ; R1 must be #00
                call    sd_wait_token
                jr      c,.err
                call    sd_reads                ; read 512 bytes -> (HL), HL += 512
                in      a,(SD_DATA)             ; CRC16 lo (ignored)
                in      a,(SD_DATA)             ; CRC16 hi (ignored)
                call    sd_csh
                or      a                       ; CF=0
                ret
.err            call    sd_csh
                scf
                ret

;--- CMD17 (single-block read). Address from sd_lba.
;    byte addressing (sd_blkt==0): argument = LBA*512 (byte offset).
;    Preserves HL (caller's buffer pointer). Port of DSDZC CMDz.
sd_cmd17:
                ld      a,SD_CMD17
                call    sd_csh
                call    sd_csl
                push    hl                      ; preserve buffer pointer
                ld      de,(sd_lba+0)           ; DE = LBA low16
                ld      bc,(sd_lba+2)           ; BC = LBA high16
                ld      l,c
                ld      h,b                     ; HL = high16
                ld      c,a                     ; C = command
                ld      a,(sd_blkt)
                or      a
                jr      nz,.send                ; block addressing -> send LBA as-is
                ; byte addressing: [HL:DE] = LBA*512  (x2 then x256 byte-shift)
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
                pop     hl                      ; restore buffer pointer
                jp      sd_resp

;--- read 512 bytes from data port into (HL); HL advances by 512
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

;--- chip select low (select) + clock, then wait ready
sd_csl:
                push    bc : push af
                ld      bc,SD_CONF : ld a,SD_CS1 : out (c),a
                ld      bc,SD_DATA : ld a,#FF : out (c),a
                pop     af : pop bc
                jp      sd_wait

;--- wait until card returns #FF (ready), BOUNDED. Never spin forever: if the
;    card stays busy we give up so a read fails cleanly (-> CF=1 -> L1 fallback)
;    instead of hanging the SD/SPI bus, which would also wedge WC's next SPG load.
sd_wait:
                push    bc : push de : push af
                ld      bc,SD_DATA
                ld      de,0                    ; 65536 polls then give up
.w              in      a,(c) : inc a : jr z,.done   ; #FF -> ready
                dec     de : ld a,d : or e : jr nz,.w
.done           pop     af : pop de : pop bc
                ret

;--- wait for data token #FE with bounded timeout.
;    out: CF=0 token received, CF=1 timeout/error token.
sd_wait_token:
                push    bc
                ld      bc,SD_DATA
                ld      d,4
.outer          ld      e,0
.inner          in      a,(c)
                cp      #FE
                jr      z,.ok
                bit     7,a
                jr      z,.err                  ; data error token (0xxxxxxx)
                dec     e
                jr      nz,.inner
                dec     d
                jr      nz,.outer
.err            pop     bc
                scf
                ret
.ok             pop     bc
                or      a
                ret

;--- 16 dummy reads
sd_snb:
                push    bc : push af
                ld      b,16
.s              in      a,(SD_DATA) : djnz .s
                pop     af : pop bc
                ret

;--- read R1 response (bit7=0), up to 10 tries
sd_resp:
                push    de : push bc
                ld      bc,SD_DATA
                ld      d,10
.r              in      a,(c) : bit 7,a : jr z,.done
                dec     d : jr nz,.r
.done           pop     bc : pop de
                ret

;--- SD state ---
sd_lba          ds      4
sd_blkt         db      0
