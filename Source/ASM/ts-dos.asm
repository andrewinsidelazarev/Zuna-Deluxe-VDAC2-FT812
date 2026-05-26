; ts-dos.asm — wrappers around the WC TS-DOS / WildDOS FAT32 file-I/O entry
; table at #2002 (FENTRY/LOAD512/SEEK0/...). This is the DOS file system, NOT
; the ZiFi radio feature (earlier code misnamed it "ZiFi" because the entry
; table was first documented from WC's zifi.asm).
;
; Provided by Wild Commander when SPG is launched via WC. At runtime
; page #0F holds the driver; we map it into slot 0 around each
; call, then restore TSLib (page #00).
;
; NOTE: gameplay now streams level assets from ZUMALVL.PAK through a
; self-contained reader (RawPak_* below) built on direct SD CMD17 single-sector
; reads (sd_zc.asm) plus our own BPB/FAT32 chain walk. This deliberately
; BYPASSES the bundled WC TS-DOS driver, whose stateful LOAD512 chain walk
; drifted -128 sectors at the first FAT-sector boundary in our SPG context.
; Because RawPak computes every FAT sector LBA itself (cluster>>7 + FatStart),
; there is no stale mount-state to drift. CMD17 is stable on the Unreal host
; (unlike the multi-block CMD18 we abandoned). The bundled-driver entry points
; (FENTRY/SETDIR/SETROOT/DOS_SWP/HDD) are no longer called.
;
; Entry table (from C:\Users\Администратор\Desktop\WC\ZiFi\zifi.asm:4403):
;   FENTRY   = #2050    HL = ptr to {flag:1, name:1..255, 0}
;                       Z = not found
;                       NZ = found, [DE:HL] = file length; SEEK0 auto-called
;   LOAD512  = #2017    CHL = dest (C = page, HL = #0000..#3FFF in slot-0 view)
;                       B = blocks (× 512 B)
;                       on return: CHL advanced, A = #0F if end-of-chain
;   LOADNON  = #2056    B = sectors to skip forward (our seek)
;   SEEK0    = #2063    rewind file
;   SETDIR   = #205D    chdir into directory just found by FENTRY
;   SETROOT  = #2060    chdir to /
;
; Filename format passed to FENTRY:
;   DB <flag>, "name", 0
;   flag: #00 = file, #10 = directory
;
; Calling convention (our wrappers):
;   - DI on entry (no IRQs during slot-0 swap and SD I/O)
;   - Save current slot-0 page (TSLibPage)
;   - Map slot 0 = ZIFI_PAGE
;   - CALL real entry
;   - Restore slot 0 = TSLibPage
;   - EI
;   - Return result regs (Z/NZ, AF, BC, DE, HL) as documented

ZIFI_PAGE       EQU #0F
; Track chunkB page: tracks longer than one 16K page (>3276 samples) are split
; on a sample boundary; chunkA -> #06 (TRACK_L01_PAGE), chunkB -> #0F. #0F is
; free in v039 (bundle driver removed). Runtime reads sample>=TRACK_SPLIT_SAMPLE
; from this page. See make_level_pack.py pagesplit_track + VDC_SlotPos.
TRACK_PAGE2        EQU #0F
TRACK_SPLIT_SAMPLE EQU 3276        ; (16384-2)/5, first sample stored in TRACK_PAGE2
ZIFI_CORE       EQU #2002
ZIFI_DEV_INI    EQU ZIFI_CORE + 3       ; #2005 — init SD device hardware
ZIFI_HDD        EQU ZIFI_CORE + 9       ; #200B — init FAT32 layer
ZIFI_LOAD512    EQU ZIFI_CORE + 21      ; #2017
ZIFI_DOS_SWP    EQU ZIFI_CORE + 27      ; #201D — toggle DOS swap mode
ZIFI_FENTRY     EQU ZIFI_CORE + 78      ; #2050
ZIFI_LOADNON    EQU ZIFI_CORE + 84      ; #2056
ZIFI_SETDIR     EQU ZIFI_CORE + 93      ; #205D
ZIFI_SETROOT    EQU ZIFI_CORE + 96      ; #2060
ZIFI_SEEK0      EQU ZIFI_CORE + 99      ; #2063

                include "sd_zc.asm"

; ---------------------------------------------------------------------
; ZiFi_Init — bring up SD driver for a session of file I/O calls.
;   DI, slot 0 = #0F (driver page), DOS_SWP, DEV_INI, HDD, SETROOT.
; After Init, ZiFi entries at #2002..#2070 are directly callable.
;   CF=1 on success, CF=0 on init error. ZiFi_Done must still be called
;   after a successful init.
ZiFi_Init:
                DI
                LD   A,  TSLibPage
                SetPage0_A
                CALL sd_init
                SCF
                RET
.Err:           OR   A
                RET

; ZiFi_Done — restore TSLib in slot 0, EI.
ZiFi_Done:
                LD   A,  TSLibPage
                SetPage0_A
                EI
                RET

; Backwards-compat aliases (older wrappers below assume per-call swap).
; Now that we call ZiFi_Init/ZiFi_Done at session boundary, these can
; just RET — the slot-0 mapping is already #0F.
ZiFi_Enter:     RET
ZiFi_Leave:     RET

; ---------------------------------------------------------------------
; ZiFi_FEntry — search current dir for filename.
;   In : HL → {flag, name, 0}
;   Out: Z=not found; NZ=found, [DE:HL]=size; SEEK0 auto-called
ZiFi_FEntry:
                CALL ZiFi_Enter
                CALL ZIFI_FENTRY
                ; preserve result flags + DE/HL across Leave
                PUSH AF
                PUSH HL
                PUSH DE
                CALL ZiFi_Leave
                POP  DE
                POP  HL
                POP  AF
                RET

; ZiFi_Load512 — read B 512-byte blocks from current file into (C:HL).
;   In : C=dest page, HL=offset (#0000..#3FFF slot-0 view), B=blocks
;   Out: CHL advanced; A=#0F if end-of-chain
ZiFi_Load512:
                JP   RawPak_ReadSectors

; ZiFi_LoadNon — skip B sectors (seek forward).
;   In : B=sectors
ZiFi_LoadNon:
                JP   RawPak_SkipB

; ZiFi_Seek0 — rewind current file to offset 0.
ZiFi_Seek0:
                JP   RawPak_Seek0

; ZiFi_SetDir — chdir into directory found by previous FEntry.
ZiFi_SetDir:
                CALL ZiFi_Enter
                CALL ZIFI_SETDIR
                CALL ZiFi_Leave
                RET

; ZiFi_SetRoot — chdir to /.
ZiFi_SetRoot:
                CALL ZiFi_Enter
                CALL ZIFI_SETROOT
                CALL ZiFi_Leave
                RET

; ---------------------------------------------------------------------
; Filename strings for our package layout in WC: /Games/Zuma Deluxe VDAC2/ZUMALVL.PAK
; flag #10 = directory, #00 = file.

ZiFi_DirGames:   DEFB #10
                 DEFB "Games", 0

ZiFi_DirZuma:    DEFB #10
                 DEFB "Zuma Deluxe VDAC2", 0

ZiFi_FileLvlPak: DEFB #00
                 DEFB "ZUMALVL.PAK", 0

; Diagnostic step counter for LoadGameplayLevelSpecificFromPack.
; Values: 0=not started, 1=after Init, 2=after PakOpen, 3=after PakReadToc,
;         4=after bg stream, 5=after palette stream, 6=after track read.
;         #FF=Init err, #FE=PakOpen err, #FD=PakReadToc err.
ZiFi_GpDbgStep:     DEFB 0
ZiFi_GpDbgBgOff:    DEFW 0
ZiFi_GpDbgBgSize:   DEFW 0

; Diagnostic counters — readable in F2 dump to see how far FENTRY chain got.
ZiFi_DbgGamesA:     DEFB 0
ZiFi_DbgGamesFound: DEFB 0
ZiFi_DbgZumaFound:  DEFB 0
ZiFi_DbgPakFound:   DEFB 0
ZiFi_DbgPakSizeL:   DEFW 0
ZiFi_DbgPakSizeH:   DEFW 0

; ---------------------------------------------------------------------
; Loader-level helpers.
;
; ZUMALVL.PAK layout:
;   sec 0       header  (magic ZLVP, version, count, sector_size)
;   sec 1       TOC[22] × 20 B   (bg/pal/track/title/preview off+size)
;   sec 2..N    data blob, per-level: bg → pal → track → title → preview

ZIFI_BUFFER_PAGE EQU #03               ; spgbld page reserved for ZiFi 512-B buffer

; ---------------------------------------------------------------------
; RawPak_* — self-contained FAT32 reader over direct SD CMD18.
;
; This path intentionally bypasses the bundled WC CORE32 LOAD512 state. It
; supports both contiguous and fragmented files by following the FAT chain
; between every cluster. Current host image is superfloppy FAT32 with
; 512-byte sectors and spc=1; we validate that in RawPak_OpenRoot.
;
; Directory/file lookup matches by NAME, case-insensitive: it reconstructs the
; LONG name (LFN) when present, else the 8.3 short name, and compares to these
; targets. This is robust to whatever short alias the injector assigns (the
; observed bug was injector writing GAMES~1 while we searched "GAMES      ").

RAWPAK_NAME_GAMES:
                DEFB "Games", 0
RAWPAK_NAME_ZUMA:
                DEFB "Zuma Deluxe VDAC2", 0
RAWPAK_NAME_PAK:
                DEFB "ZUMALVL.PAK", 0

; DBG instrumentation (read these in F2 dump to bisect a fallback):
;   ZiFi_DbgGamesA   (#621A) = RawPak open granular step:
;       #20 entry, #21 BPB read OK, #22 BPB valid, #23 GAMES, #24 ZUMA, #25 PAK
;       #A1 BPB CMD17 err, #A2 bytes/sec!=512, #A3 spc!=1,
;       #A4 GAMES not found, #A5 ZUMA not found, #A6 PAK not found
;   ZiFi_DbgGamesFound (#621B) = FindInCurrentDir call counter (1=root,2=GAMES,3=ZUMA)
RawPak_OpenRoot:
                LD   A, #20
                LD   (ZiFi_DbgGamesA), A
                XOR  A
                LD   (ZiFi_DbgGamesFound), A
                ; Read BPB sector 0.
                LD   HL, 0
                LD   DE, 0
                CALL RawPak_ReadSectorBuffer
                JP   C, .ErrBpbRead
                LD   A, #21
                LD   (ZiFi_DbgGamesA), A
                LD   IX, #8000
                ; Require 512-byte sectors and a non-zero sectors/cluster
                ; value. FAT32 uses power-of-two SPC values; the LBA helper
                ; below handles SPC > 1 for real cards/images.
                LD   A, (IX + 11)
                OR   A
                JP   NZ, .ErrBps
                LD   A, (IX + 12)
                CP   2
                JP   NZ, .ErrBps
                LD   A, (IX + 13)
                OR   A
                JP   Z, .ErrSpc
                LD   (RawPak_Spc), A
                LD   A, #22
                LD   (ZiFi_DbgGamesA), A
                ; fatstart = reserved sectors (16-bit in BPB)
                LD   A, (IX + 14) : LD (RawPak_FatStart + 0), A
                LD   A, (IX + 15) : LD (RawPak_FatStart + 1), A
                XOR  A
                LD   (RawPak_FatStart + 2), A
                LD   (RawPak_FatStart + 3), A
                ; datastart = reserved + numFATs * FATSz32
                LD   HL, RawPak_FatStart
                LD   DE, RawPak_DataStart
                CALL RawPak_Copy32
                LD   A, (IX + 16)
                LD   B, A
.fatLoop:      PUSH BC
                LD   A, (IX + 36) : LD (RawPak_Tmp + 0), A
                LD   A, (IX + 37) : LD (RawPak_Tmp + 1), A
                LD   A, (IX + 38) : LD (RawPak_Tmp + 2), A
                LD   A, (IX + 39) : LD (RawPak_Tmp + 3), A
                LD   HL, RawPak_Tmp
                LD   DE, RawPak_DataStart
                CALL RawPak_Add32
                POP  BC
                DJNZ .fatLoop
                ; root cluster
                LD   A, (IX + 44) : LD (RawPak_RootClus + 0), A
                LD   A, (IX + 45) : LD (RawPak_RootClus + 1), A
                LD   A, (IX + 46) : LD (RawPak_RootClus + 2), A
                LD   A, (IX + 47) : LD (RawPak_RootClus + 3), A
                LD   HL, RawPak_RootClus
                LD   DE, RawPak_CurClus
                CALL RawPak_Copy32
                LD   HL, RAWPAK_NAME_GAMES
                CALL RawPak_FindInCurrentDir
                JP   NC, .ErrGames
                LD   A, (RawPak_FoundAttr)
                AND  #10
                JP   Z, .ErrGames
                LD   HL, RawPak_FoundClus
                LD   DE, RawPak_CurClus
                CALL RawPak_Copy32
                LD   A, #23
                LD   (ZiFi_DbgGamesA), A
                LD   HL, RAWPAK_NAME_ZUMA
                CALL RawPak_FindInCurrentDir
                JP   NC, .ErrZuma
                LD   A, (RawPak_FoundAttr)
                AND  #10
                JP   Z, .ErrZuma
                LD   HL, RawPak_FoundClus
                LD   DE, RawPak_CurClus
                CALL RawPak_Copy32
                LD   A, #24
                LD   (ZiFi_DbgGamesA), A
                LD   HL, RAWPAK_NAME_PAK
                CALL RawPak_FindInCurrentDir
                JP   NC, .ErrPak
                LD   HL, RawPak_FoundClus
                LD   DE, RawPak_FileStartClus
                CALL RawPak_Copy32
                LD   A, #25
                LD   (ZiFi_DbgGamesA), A
                CALL RawPak_Seek0
                CALL RawPak_SetPakLba          ; cache LBA of file logical sector 0
                SCF
                RET
.ErrBpbRead:   LD   A, #A1
                JR   .ErrSet
.ErrBps:       LD   A, #A2
                JR   .ErrSet
.ErrSpc:       LD   A, #A3
                JR   .ErrSet
.ErrGames:     LD   A, #A4
                JR   .ErrSet
.ErrZuma:      LD   A, #A5
                JR   .ErrSet
.ErrPak:       LD   A, #A6
.ErrSet:       LD   (ZiFi_DbgGamesA), A
.Err:          OR   A
                RET

; In: HL -> target name (ASCII, zero-terminated; long name or 8.3 form).
;     RawPak_CurClus = directory start cluster.
; Out: CF=1 found (RawPak_FoundClus/RawPak_FoundAttr set), CF=0 not found.
; Matches case-insensitively: reconstructs the LFN if the entry has one, else
; the 8.3 short name, then compares to the target. Robust to short-alias choice.
RawPak_FindInCurrentDir:
                LD   DE, RawPak_TargetName     ; copy + uppercase target
.cpyt:         LD   A, (HL)
                CALL RawPak_Upcase
                LD   (DE), A
                INC  HL
                INC  DE
                OR   A
                JR   NZ, .cpyt
                LD   A, (ZiFi_DbgGamesFound)   ; diag: walk counter
                INC  A
                LD   (ZiFi_DbgGamesFound), A
                XOR  A
                LD   (RawPak_HaveLfn), A
.cluster:      CALL RawPak_CurrentLbaRegs
                CALL RawPak_ReadSectorBuffer
                JP   C, .Err
                LD   IX, #8000
                LD   B, 16
.entry:        LD   A, (IX + 0)
                OR   A
                JP   Z, .Err                   ; 0x00 = end of directory
                CP   #E5
                JR   Z, .skip                  ; deleted
                LD   A, (IX + 11)
                CP   #0F
                JR   Z, .lfn                   ; LFN fragment -> accumulate
                LD   A, (RawPak_HaveLfn)        ; short (8.3) entry
                OR   A
                JR   NZ, .haveName             ; long name already assembled
                CALL RawPak_Build83            ; else build 8.3 effective name
.haveName:     CALL RawPak_NameMatch          ; Z = EntName == TargetName
                JR   Z, .found
.skip:         XOR  A
                LD   (RawPak_HaveLfn), A
.next:         LD   DE, 32
                ADD  IX, DE
                DJNZ .entry
                CALL RawPak_FatNext
                JP   NC, .cluster
.Err:          OR   A
                RET
.lfn:          CALL RawPak_StoreLfn
                JR   .next
.found:        LD   A, (IX + 11) : LD (RawPak_FoundAttr), A
                LD   A, (IX + 26) : LD (RawPak_FoundClus + 0), A
                LD   A, (IX + 27) : LD (RawPak_FoundClus + 1), A
                LD   A, (IX + 20) : LD (RawPak_FoundClus + 2), A
                LD   A, (IX + 21) : LD (RawPak_FoundClus + 3), A
                SCF
                RET

; A = uppercase(A) for ASCII a-z; other bytes unchanged.
RawPak_Upcase:  CP   'a'
                RET  C
                CP   'z' + 1
                RET  NC
                SUB  #20
                RET

; Build 8.3 effective name from short entry (IX) into RawPak_EntName,
; uppercased, zero-terminated. "NAME.EXT" (dot+ext only if extension present).
RawPak_Build83:
                LD   DE, RawPak_EntName
                PUSH IX
                POP  HL                        ; HL = name field (entry+0)
                LD   B, 8
                CALL .copytrim
                PUSH IX
                POP  HL
                LD   BC, 8
                ADD  HL, BC                    ; HL = ext field (entry+8)
                LD   A, (HL)
                CP   ' '
                JR   Z, .noext
                LD   A, '.'
                LD   (DE), A
                INC  DE
                LD   B, 3
                CALL .copytrim
.noext:        XOR  A
                LD   (DE), A
                RET
.copytrim:     LD   A, (HL)                    ; copy <=B chars, stop at first space
                CP   ' '
                RET  Z
                CALL RawPak_Upcase
                LD   (DE), A
                INC  DE
                INC  HL
                DJNZ .copytrim
                RET

; Compare RawPak_EntName vs RawPak_TargetName (both uppercase, zero-term).
; Out: Z if equal, NZ otherwise.
RawPak_NameMatch:
                LD   HL, RawPak_EntName
                LD   DE, RawPak_TargetName
.nm:           LD   A, (DE)
                CP   (HL)
                RET  NZ
                OR   A
                RET  Z
                INC  HL
                INC  DE
                JR   .nm

; Store one LFN fragment (IX = LFN entry) into RawPak_EntName at (seq-1)*13.
; Sets RawPak_HaveLfn. Chars taken as UTF-16 low byte, uppercased.
RawPak_StoreLfn:
                LD   A, (IX + 0)
                AND  #1F
                DEC  A                          ; idx (0-based)
                LD   HL, RawPak_EntName
                OR   A
                JR   Z, .pos
                LD   DE, 13
.mul:          ADD  HL, DE
                DEC  A
                JR   NZ, .mul
.pos:          LD   A, (IX + 1)  : CALL .put
                LD   A, (IX + 3)  : CALL .put
                LD   A, (IX + 5)  : CALL .put
                LD   A, (IX + 7)  : CALL .put
                LD   A, (IX + 9)  : CALL .put
                LD   A, (IX + 14) : CALL .put
                LD   A, (IX + 16) : CALL .put
                LD   A, (IX + 18) : CALL .put
                LD   A, (IX + 20) : CALL .put
                LD   A, (IX + 22) : CALL .put
                LD   A, (IX + 24) : CALL .put
                LD   A, (IX + 28) : CALL .put
                LD   A, (IX + 30) : CALL .put
                LD   A, 1
                LD   (RawPak_HaveLfn), A
                RET
.put:          CALL RawPak_Upcase
                LD   (HL), A
                INC  HL
                RET

RawPak_Seek0:
                LD   HL, RawPak_FileStartClus
                LD   DE, RawPak_CurClus
                CALL RawPak_Copy32
                XOR  A
                LD   (RawPak_CurSecInClus), A
                RET

RawPak_SkipB:
                LD   A, B
                OR   A
                RET  Z
.loop:         CALL RawPak_AdvanceOne
                RET  C
                DJNZ .loop
                RET

; In: C=dest page, HL=dest offset inside page, B=sector count.
RawPak_ReadSectors:
                LD   A, B
                OR   A
                RET  Z
                LD   A, C
                LD   (RawPak_DstPage), A
                LD   (RawPak_DstOff), HL
                LD   A, B
                LD   (RawPak_ReadCount), A
.loop:         LD   A, (RawPak_DstPage)
                SetPage2_A
                LD   HL, (RawPak_DstOff)
                LD   DE, #8000
                ADD  HL, DE
                PUSH HL
                POP  IX
                CALL RawPak_CurrentLbaRegs
                CALL sd_read_sector
                JR   C, .Err
                CALL RawPak_AdvanceOne
                PUSH AF
                LD   HL, (RawPak_DstOff)
                LD   DE, #0200
                ADD  HL, DE
                BIT  6, H
                JR   Z, .dstSamePage
                RES  6, H
                LD   A, (RawPak_DstPage)
                INC  A
                LD   (RawPak_DstPage), A
.dstSamePage:
                LD   (RawPak_DstOff), HL
                LD   A, (RawPak_ReadCount)
                DEC  A
                LD   (RawPak_ReadCount), A
                POP  AF
                JR   Z, .Ok
                JR   C, .Err
                JR   .loop
.Ok:           OR   A
                RET
.Err:          SCF
                RET

RawPak_AdvanceOne:
                ; RawPak_FatNext clobbers BC (its 7x shift loop uses B; the entry
                ; copy/LDIR use BC). Preserve BC so callers that keep a DJNZ counter
                ; in B across the advance (RawPak_SkipB) are not corrupted — that bug
                ; made LoadNon(1) walk the whole chain to EOC, so the TOC sector was
                ; never read and ZiFi_LevelTOC came back all zeros.
                PUSH BC
                LD   A, (RawPak_CurSecInClus)
                INC  A
                LD   E, A
                LD   A, (RawPak_Spc)
                CP   E
                JR   Z, .nextCluster
                JR   C, .nextCluster
                LD   A, E
                LD   (RawPak_CurSecInClus), A
                POP  BC
                OR   A
                RET
.nextCluster:  XOR  A
                LD   (RawPak_CurSecInClus), A
                CALL RawPak_FatNext
                POP  BC
                RET

RawPak_FatNext:
                LD   HL, RawPak_CurClus
                LD   DE, RawPak_Tmp
                CALL RawPak_Copy32
                LD   B, 7
.shr:          CALL RawPak_ShrTmp1
                DJNZ .shr
                LD   HL, RawPak_FatStart
                LD   DE, RawPak_Tmp
                CALL RawPak_Add32
                LD   HL, (RawPak_Tmp)
                LD   DE, (RawPak_Tmp + 2)
                CALL RawPak_ReadFatSector       ; FAT -> own buffer (NOT slot-2 data buf)
                JR   C, .Err
                LD   A, (RawPak_CurClus)
                AND  127
                LD   L, A
                LD   H, 0
                ADD  HL, HL
                ADD  HL, HL
                LD   DE, RawPak_FatBuf
                ADD  HL, DE
                LD   DE, RawPak_CurClus
                LD   BC, 4
                LDIR
                LD   A, (RawPak_CurClus + 3)
                AND  #0F
                LD   (RawPak_CurClus + 3), A
                ; EOC if >= 0x0FFFFFF8.
                CP   #0F
                JR   NZ, .notEoc
                LD   A, (RawPak_CurClus + 2)
                CP   #FF
                JR   NZ, .notEoc
                LD   A, (RawPak_CurClus + 1)
                CP   #FF
                JR   NZ, .notEoc
                LD   A, (RawPak_CurClus + 0)
                CP   #F8
                JR   C, .notEoc
                SCF
                RET
.notEoc:       LD   A, (RawPak_CurClus + 3)
                OR   A
                JR   NZ, .Ok
                LD   A, (RawPak_CurClus + 2)
                OR   A
                JR   NZ, .Ok
                LD   A, (RawPak_CurClus + 1)
                OR   A
                JR   NZ, .Ok
                LD   A, (RawPak_CurClus + 0)
                CP   2
                JR   NC, .Ok
.Err:          SCF
                RET
.Ok:           OR   A
                RET

RawPak_CurrentLbaRegs:
                LD   HL, RawPak_CurClus
                LD   DE, RawPak_Tmp
                CALL RawPak_Copy32
                ; tmp = cluster - 2
                LD   HL, (RawPak_Tmp)
                LD   DE, 2
                OR   A
                SBC  HL, DE
                LD   (RawPak_Tmp), HL
                JR   NC, .noBorrow
                LD   HL, (RawPak_Tmp + 2)
                DEC  HL
                LD   (RawPak_Tmp + 2), HL
.noBorrow:     LD   HL, RawPak_DataStart
                ; tmp = (cluster - 2) * sectors_per_cluster + CurSecInClus.
                ; FAT32 SPC is power-of-two, so multiply by shifting.
                LD   A, (RawPak_Spc)
.spcShift:     CP   1
                JR   Z, .spcDone
                SRL  A
                PUSH AF
                LD   HL, (RawPak_Tmp)
                ADD  HL, HL
                LD   (RawPak_Tmp), HL
                LD   HL, (RawPak_Tmp + 2)
                ADC  HL, HL
                LD   (RawPak_Tmp + 2), HL
                POP  AF
                JR   .spcShift
.spcDone:      LD   A, (RawPak_CurSecInClus)
                LD   E, A
                LD   D, 0
                LD   HL, (RawPak_Tmp)
                ADD  HL, DE
                LD   (RawPak_Tmp), HL
                JR   NC, .addDataStart
                LD   HL, (RawPak_Tmp + 2)
                INC  HL
                LD   (RawPak_Tmp + 2), HL
.addDataStart: LD   HL, RawPak_DataStart
                LD   DE, RawPak_Tmp
                CALL RawPak_Add32
                LD   HL, (RawPak_Tmp)
                LD   DE, (RawPak_Tmp + 2)
                RET

RawPak_ReadSectorBuffer:
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   IX, #8000
                JP   sd_read_sector

; Read a FAT sector into RawPak_FatBuf (resident in Core / slot 1). Keeps the
; FAT-chain walk from clobbering the slot-2 data buffer (#8000) that callers
; fill with directory/file sectors. HL:DE = LBA on entry.
RawPak_ReadFatSector:
                LD   IX, RawPak_FatBuf
                JP   sd_read_sector

; --- Sector-table fast path -------------------------------------------------
; The PAK is a contiguous FAT32 file (the injector allocates it in one run).
; We cache the LBA of file logical sector 0 (RawPak_PakLba); any logical sector
; N is then LBA = PakLba + N (true for contiguous clusters regardless of spc).
; This removes the per-sector FAT walk and the seek-by-read entirely, and lets
; us read the whole bg/track in one SD burst (no FT.WriteMem interleaved on the
; shared SD/FT812 SPI bus, which was crashing the streaming path).

RawPak_SetPakLba:
                LD   HL, RawPak_FileStartClus
                LD   DE, RawPak_CurClus
                CALL RawPak_Copy32
                CALL RawPak_CurrentLbaRegs     ; HL = LBA lo16, DE = LBA hi16
                LD   (RawPak_PakLba), HL
                LD   (RawPak_PakLba + 2), DE
                RET

; Read file logical sector (RawPak_LogCur) into (IX). Advances RawPak_LogCur.
; IX is preserved by sd_read_sector; caller advances IX between sectors.
RawPak_ReadOneLogicalIX:
                LD   HL, RawPak_PakLba
                LD   DE, RawPak_Tmp
                CALL RawPak_Copy32             ; Tmp = PakLba
                LD   HL, (RawPak_LogCur)
                LD   DE, (RawPak_Tmp)
                ADD  HL, DE
                LD   (RawPak_Tmp), HL
                JR   NC, .nc
                LD   HL, (RawPak_Tmp + 2)
                INC  HL
                LD   (RawPak_Tmp + 2), HL
.nc:           LD   HL, (RawPak_Tmp)          ; HL = LBA lo16
                LD   DE, (RawPak_Tmp + 2)      ; DE = LBA hi16
                CALL sd_read_sector
                LD   HL, (RawPak_LogCur)
                INC  HL
                LD   (RawPak_LogCur), HL
                RET

; ----------------------------------------------------------------------------
; VDC_ReadSampleAtHL — read track sample [HL] -> BC=X, DE=Y; set VDC_LastT and
; VDC_LastTangent; CF=0. Core-resident (called as a tail-jump from VDC_SlotPos
; in Main1, which is nearly full). Handles the 2-page track split: samples below
; TRACK_SPLIT_SAMPLE sit on TRACK_L01_PAGE (#06) at #8000+2+t*5; samples at/above
; live on TRACK_PAGE2 (#0F) at #8000+(t-split)*5 (chunkB has no count header).
; Leaves slot 2 mapped to #06. Clobbers AF, HL.
; ----------------------------------------------------------------------------
VDC_ReadSampleAtHL:
                LD   (VDC_LastT), HL                   ; expose t
                LD   DE, TRACK_SPLIT_SAMPLE
                AND  A
                SBC  HL, DE                            ; HL = t - split; CF=1 if t<split
                JR   C, .p1
                ; --- page2 (#0F): HL = t2 = t - split ---
                LD   D, H : LD E, L
                ADD  HL, HL : ADD HL, HL
                ADD  HL, DE                            ; t2*5
                LD   DE, #8000
                ADD  HL, DE                            ; #8000 + t2*5
                LD   A, TRACK_PAGE2
                SetPage2_A                             ; map #0F (clobbers A, BC)
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   C, (HL) : INC HL
                LD   B, (HL) : INC HL                  ; BC = Y
                LD   A, (HL)
                LD   (VDC_LastTangent), A
                PUSH BC : PUSH DE                      ; save Y, X across page restore
                LD   A, TRACK_L01_PAGE
                SetPage2_A                             ; restore slot2 = #06 for callers
                POP  DE : POP  BC                      ; DE = X, BC = Y
                JR   .rearr
.p1:            ; --- page1 (#06, already mapped): addr = #8000 + 2 + t*5 ---
                LD   HL, (VDC_LastT)
                LD   D, H : LD E, L
                ADD  HL, HL : ADD HL, HL
                ADD  HL, DE                            ; t*5
                LD   DE, TrackData + 2
                ADD  HL, DE
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   C, (HL) : INC HL
                LD   B, (HL) : INC HL                  ; BC = Y
                LD   A, (HL)
                LD   (VDC_LastTangent), A
.rearr:         EX   DE, HL                            ; HL = X
                LD   D, B : LD E, C                    ; DE = Y
                LD   B, H : LD C, L                    ; BC = X
                AND  A                                 ; CF = 0
                RET

; Copy 4 bytes: HL=src, DE=dst.
RawPak_Copy32:
                PUSH BC
                LD   BC, 4
                LDIR
                POP  BC
                RET

; Add 4-byte little-endian integer at HL into integer at DE.
RawPak_Add32:
                PUSH BC
                LD   B, 4
                OR   A
.a:            LD   A, (DE)
                ADC  A, (HL)
                LD   (DE), A
                INC  HL
                INC  DE
                DJNZ .a
                POP  BC
                RET

RawPak_ShrTmp1:
                LD   HL, RawPak_Tmp + 3
                SRL  (HL)
                DEC  HL
                RR   (HL)
                DEC  HL
                RR   (HL)
                DEC  HL
                RR   (HL)
                RET

RawPak_Spc:            DEFB 0
RawPak_CurSecInClus:   DEFB 0
RawPak_ReadCount:      DEFB 0
RawPak_DstPage:        DEFB 0
RawPak_DstOff:         DEFW 0
RawPak_TargetName:     DEFS 64        ; target name (uppercased, zero-term)
RawPak_EntName:        DEFS 64        ; current entry effective name (LFN or 8.3)
RawPak_HaveLfn:        DEFB 0         ; 1 if LFN fragments assembled for this entry
RawPak_FoundAttr:      DEFB 0
RawPak_FoundClus:      DEFS 4
RawPak_FatStart:       DEFS 4
RawPak_DataStart:      DEFS 4
RawPak_RootClus:       DEFS 4
RawPak_FileStartClus:  DEFS 4
RawPak_CurClus:        DEFS 4
RawPak_Tmp:            DEFS 4
RawPak_FatBuf:         DEFS 512       ; dedicated FAT-sector buffer (Core/slot1)
RawPak_PakLba:         DEFS 4         ; LBA of PAK file logical sector 0 (contiguous)
RawPak_LogCur:         DEFW 0         ; current file logical sector for ReadOneLogicalIX
RawPak_StgPage:        DEFB 0         ; staging page cursor for SD/FT phases

; ZiFi_LevelTOC — 20-byte buffer holding the active level's TOC entry.
; Layout (little-endian words):
;   +0  bg_off       (sectors; 0xFFFF = absent)
;   +2  bg_size
;   +4  pal_off
;   +6  pal_size
;   +8  track_off
;   +10 track_size
;   +12 title_off
;   +14 title_size
;   +16 preview_off
;   +18 preview_size
ZiFi_LevelTOC:    DEFS 20

; ZiFi_PakOpen — chdir /Games/Zuma Deluxe VDAC2/ and FENTRY ZUMALVL.PAK.
; After return file is open, SEEK0 auto-called, ready for LoadNon/Load512.
; CF=1 on success, CF=0 on any not-found step.
ZiFi_PakOpen:
                JP   RawPak_OpenRoot

; ZiFi_PakReadToc — read TOC sector (sec 1), copy entry [A] to ZiFi_LevelTOC.
; In  : A = level index (0..21)
; Out : ZiFi_LevelTOC filled with 20 bytes; CF=1 ok, CF=0 absent slot.
;       Pak must already be open (ZiFi_PakOpen called first).
; Trashes: AF, BC, DE, HL
ZiFi_PakReadToc:
                PUSH AF
                ; read TOC = file logical sector 1, directly by LBA (no FAT walk).
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   IX, #8000
                LD   HL, 1
                LD   (RawPak_LogCur), HL
                CALL RawPak_ReadOneLogicalIX
                ; map buffer page into slot 2 so we can read it
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                ; HL = #8000 + (level_idx * 20)
                POP  AF
                LD   H, 0
                LD   L, A
                ; HL = level_idx
                ; multiply HL × 20:
                ADD  HL, HL              ; ×2
                ADD  HL, HL              ; ×4
                LD   D, H : LD E, L
                ADD  HL, HL              ; ×8
                ADD  HL, HL              ; ×16
                ADD  HL, DE              ; ×20
                LD   DE, #8000
                ADD  HL, DE              ; HL = entry source
                LD   DE, ZiFi_LevelTOC
                LD   BC, 20
                LDIR
                ; check bg_off (first word) — if 0xFFFF, slot absent
                LD   HL, (ZiFi_LevelTOC)
                LD   A, H
                CP   #FF
                JR   NZ, .Exists
                LD   A, L
                CP   #FF
                JR   Z, .Absent
.Exists:
                SCF
                RET
.Absent:        OR   A
                RET

; ZiFi_SkipSectors16 — skip HL (16-bit) sectors forward.
; Do not use LOADNON for large seeks here. Fresh host dump 111 showed the
; loader stuck immediately after TOC while seeking L02 bg_off=#01F0 through
; LOADNON. Reading and discarding through LOAD512 is slower but uses the same
; proven data path as TOC/background reads.
;   In  : HL = count
;   Out : position advanced
ZiFi_SkipSectors16:
.Loop:          LD   A, H
                OR   L
                RET  Z
                LD   A, H
                OR   A
                JR   NZ, .Full
                LD   A, L
                CP   32
                JR   NC, .Full
                LD   B, L
                LD   C, ZIFI_BUFFER_PAGE
                LD   HL, #0000
                JP   ZiFi_Load512
.Full:
                PUSH HL
                LD   B, 32
                LD   C, ZIFI_BUFFER_PAGE
                LD   HL, #0000
                CALL ZiFi_Load512
                POP  HL
                RET  C
                LD   DE, -32
                ADD  HL, DE
                JR   .Loop

; ZiFi_StreamSection — read N sectors from pack, write to FT812 RAM_G in
; 16384-byte chunks (32 sectors each).
;   In : DE = total sectors to read (must be multiple of 32 for our sections;
;             max one chunk = 32 if non-multiple)
;        BgRamH / BgRamL = destination RAM_G address (will be advanced)
;   Trashes: AF, BC, DE, HL, BgRamH, BgRamL
ZiFi_StreamSection:
.Loop:          LD   A, D
                OR   E
                RET  Z
                ; chunk size = min(32, DE)
                LD   A, D
                OR   A
                JR   NZ, .Full           ; DE >= 256 → use full 32
                LD   A, E
                CP   32
                JR   NC, .Full
                ; partial: B = E sectors, byte count = E * 512
                LD   B, E
                LD   H, E
                LD   L, 0
                ADD  HL, HL              ; HL = byte count = E * 512
                LD   (ZiFi_StreamByteCount), HL
                XOR  A
                LD   E, A                ; DE = 0 after this iteration
                JR   .Read
.Full:          LD   B, 32
                LD   HL, 16384
                LD   (ZiFi_StreamByteCount), HL
                LD   HL, -32
                ADD  HL, DE
                EX   DE, HL              ; DE = DE - 32
.Read:          LD   (ZiFi_StreamRemaining), DE
                ; read B sectors into buffer page #03 @ #0000 (slot-0 view)
                LD   C, ZIFI_BUFFER_PAGE
                LD   HL, #0000
                CALL ZiFi_Load512
                LD   A, TSLibPage
                SetPage0_A
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   BC, (ZiFi_StreamByteCount)
                LD   HL, #8000
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                ; advance BgRamL/H by byte count
                LD   HL, (ZiFi_StreamByteCount)
                LD   DE, (BgRamL)
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .NoCy
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.NoCy:          LD   DE, (ZiFi_StreamRemaining)
                JR   .Loop

; Allocate within Core module so the bytes are bundled in Core.bin and
; protected from MMU/TSLib runtime overwrites. EQU to addresses outside
; Core block left them at random/unmapped memory.
ZiFi_StreamByteCount: DEFW 0
ZiFi_StreamRemaining: DEFW 0
ZiFi_BgDstPage:       DEFB 0

; Adventure state vars (CurrentLevel etc) previously lived in TSLib region
; #1937 area where TSLib activity corrupted them. Placed here inside Core
; module to be safely bundled and never touched by TSLib.
FadeAlpha:         DEFB 0
CurrentDifficulty: DEFB 0
CurrentLevel:      DEFB 0

; LoadGameplayLevelSpecificFromPack — stream selected board bg/palette/track
; from ZUMALVL.PAK. Shared gameplay sprites/fonts remain loaded by the caller.
;   Out: CF=1 loaded, CF=0 error/fallback
LoadGameplayLevelSpecificFromPack:
                XOR  A
                LD   (ZiFi_GpDbgStep), A
                CALL ZiFi_Init
                JR   C, .initOk
                LD   A, #FF
                LD   (ZiFi_GpDbgStep), A
                JP   .InitErr
.initOk:        LD   A, 1
                LD   (ZiFi_GpDbgStep), A
                CALL ZiFi_PakOpen
                JR   C, .openOk
                LD   A, #FE
                LD   (ZiFi_GpDbgStep), A
                JP   .Err
.openOk:        LD   A, 2
                LD   (ZiFi_GpDbgStep), A
                LD   A, (CurrentLevel)
                CALL ZiFi_PakReadToc
                JR   C, .tocOk
                LD   A, #FD
                LD   (ZiFi_GpDbgStep), A
                JP   .Err
.tocOk:         LD   A, 3
                LD   (ZiFi_GpDbgStep), A
                LD   HL, (ZiFi_LevelTOC + 0)
                LD   (ZiFi_GpDbgBgOff), HL
                LD   HL, (ZiFi_LevelTOC + 2)
                LD   (ZiFi_GpDbgBgSize), HL

                ; --- validate the sections we know how to stage -------------
                ; bg must be exactly 256 sectors (8 x 16K pages #07..#0E).
                LD   HL, (ZiFi_LevelTOC + 2)
                LD   A, H : CP 1 : JP NZ, .Err
                LD   A, L : OR A : JP NZ, .Err
                ; track must fit two 16K pages (<= 64 sectors): chunkA #06 + chunkB #0F.
                LD   HL, (ZiFi_LevelTOC + 10)
                LD   A, H : OR A : JP NZ, .Err
                LD   A, L : CP 65 : JP NC, .Err

                ; ===== SD PHASE: read everything into RAM, NO FT812 access. ==
                ; (FT812 and the SD card share the Z-Controller SPI bus #57/#77;
                ;  interleaving SD reads with FT.WriteMem crashed the bus. So we
                ;  do all SD reads first, then all FT uploads — one transition.)
                ; bg: 256 sectors -> staging pages #07..#0E (16K each).
                LD   HL, (ZiFi_LevelTOC + 0)            ; bg_off (file logical)
                LD   (RawPak_LogCur), HL
                LD   A, #07
                LD   (RawPak_StgPage), A
                LD   B, 8
.sdBgPage:      PUSH BC
                LD   A, (RawPak_StgPage)
                SetPage2_A
                LD   IX, #8000
                LD   B, 32
.sdBgSec:       PUSH BC
                CALL RawPak_ReadOneLogicalIX
                LD   DE, 512
                ADD  IX, DE
                POP  BC
                DJNZ .sdBgSec
                LD   A, (RawPak_StgPage)
                INC  A
                LD   (RawPak_StgPage), A
                POP  BC
                DJNZ .sdBgPage
                LD   A, #34
                LD   (ZiFi_GpDbgStep), A

                ; palette: 1 sector -> staging page #03.
                LD   HL, (ZiFi_LevelTOC + 4)            ; pal_off
                LD   (RawPak_LogCur), HL
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   IX, #8000
                CALL RawPak_ReadOneLogicalIX

                ; track: chunkA (<=32 sec) -> page #06; chunkB (rest) -> page #0F.
                ; PAK pads chunkA to a full 16K page for split tracks, so logical
                ; sectors track_off..+31 = chunkA and +32.. = chunkB (contiguous in
                ; RawPak_LogCur). total recomputed from TOC (SetPage2_A clobbers BC).
                LD   HL, (ZiFi_LevelTOC + 8)            ; track_off (file logical)
                LD   (RawPak_LogCur), HL
                ; --- chunkA -> #06 ---
                LD   A, TRACK_L01_PAGE
                SetPage2_A
                LD   IX, #8000
                LD   A, (ZiFi_LevelTOC + 10)            ; total track sectors
                CP   33
                JR   C, .trkAcnt                        ; total<=32 -> chunkA = total
                LD   A, 32                              ; cap chunkA at one page
.trkAcnt:       LD   B, A
.sdTrkA:        PUSH BC
                CALL RawPak_ReadOneLogicalIX
                LD   DE, 512
                ADD  IX, DE
                POP  BC
                DJNZ .sdTrkA
                ; --- chunkB -> #0F (only if total > 32) ---
                LD   A, (ZiFi_LevelTOC + 10)
                CP   33
                JR   C, .sdTrkDone                      ; one page only
                SUB  32                                 ; remaining sectors
                LD   B, A
                LD   A, TRACK_PAGE2
                SetPage2_A
                LD   IX, #8000
.sdTrkB:        PUSH BC
                CALL RawPak_ReadOneLogicalIX
                LD   DE, 512
                ADD  IX, DE
                POP  BC
                DJNZ .sdTrkB
.sdTrkDone:
                LD   A, #35
                LD   (ZiFi_GpDbgStep), A

                ; ===== FT PHASE: upload from RAM, NO SD access. =============
                ; bg: pages #07..#0E -> BG_RAMG (16K each), same as the fallback.
                LD   HL, BG_RAMG_ADDR & #FFFF
                LD   (BgRamL), HL
                LD   A, (BG_RAMG_ADDR >> 16) & #FF
                LD   (BgRamH), A
                LD   A, #07
                LD   (RawPak_StgPage), A
                LD   B, 8
.ftBgPage:      PUSH BC
                LD   A, (RawPak_StgPage)
                SetPage2_A
                LD   HL, #8000
                LD   BC, 16384
                LD   A, (BgRamH)
                LD   DE, (BgRamL)
                CALL FT.WriteMem
                LD   HL, (BgRamL)
                LD   DE, #4000
                ADD  HL, DE
                LD   (BgRamL), HL
                JR   NC, .ftNoCy
                LD   A, (BgRamH)
                INC  A
                LD   (BgRamH), A
.ftNoCy:        LD   A, (RawPak_StgPage)
                INC  A
                LD   (RawPak_StgPage), A
                POP  BC
                DJNZ .ftBgPage
                LD   A, 4
                LD   (ZiFi_GpDbgStep), A

                ; palette: page #03 -> BG_PALETTE_RAMG (512 bytes).
                LD   A, ZIFI_BUFFER_PAGE
                SetPage2_A
                LD   HL, #8000
                LD   BC, 512
                LD   A, (BG_PALETTE_RAMG >> 16) & #FF
                LD   DE, BG_PALETTE_RAMG & #FFFF
                CALL FT.WriteMem
                LD   A, 6
                LD   (ZiFi_GpDbgStep), A

                ; bg/palette uploaded to RAM_G, track staged in page #06.
                SCF
.Err:           PUSH AF
                CALL ZiFi_Done
                POP  AF
                RET
.InitErr:       CALL ZiFi_Done
                OR   A
                RET

; LoadLevelFromPack — open ZUMALVL.PAK and load CurrentLevel's TOC entry
; into ZiFi_LevelTOC.
;   Out: CF=1 ok, CF=0 error
LoadLevelFromPack_Setup:
                CALL ZiFi_Init
                JR   NC, .InitErr
                CALL ZiFi_PakOpen
                JR   NC, .Err
                LD   A, (CurrentLevel)
                CALL ZiFi_PakReadToc
.Err:           PUSH AF
                CALL ZiFi_Done
                POP  AF
                RET
.InitErr:       CALL ZiFi_Done
                OR   A
                RET

; LoadLevelFromPack — original dead-code entry point for incremental verification.
; Doesn't yet stream assets to FT812 — only opens pack and reads TOC entry,
; so we can confirm ZiFi flow works without breaking compiled-slot path.
;   In : A = level index (0..21)
;   Out: CF=1 ok, ZiFi_LevelTOC filled
LoadLevelFromPack:
                PUSH AF
                CALL ZiFi_Init
                JR   NC, .InitErr
                POP  AF
                PUSH AF
                CALL ZiFi_PakOpen
                JR   NC, .Err
                POP  AF
                CALL ZiFi_PakReadToc
                PUSH AF
                CALL ZiFi_Done
                POP  AF
                RET
.Err:           POP  AF
                PUSH AF
                CALL ZiFi_Done
                POP  AF
                OR   A                   ; CF=0
                RET
.InitErr:       POP  AF
                CALL ZiFi_Done
                OR   A
                RET
