; loader_resident.asm — the parts of the PAK loader that MUST stay resident in
; Core (slot 1), because they are reached while the loader overlay page is NOT
; mapped:
;   * VDC_ReadSampleAtHL — called per-frame from VDC_SlotPos (Main1) during play;
;   * adventure cross-load vars (FadeAlpha / CurrentDifficulty / CurrentLevel),
;     read by gameplay/menu/level-select code at any time;
;   * the overlay trampolines — the named entry points callers use; each maps the
;     loader page into slot 3, calls the real OVL_* routine, then restores #04.
;
; The bulk of the loader (sd_zc + RawPak_* + ZiFi_* + OVL_LoadGameplay... +
; OVL_LoadLevelSelectPreviewAssets) lives in ts-dos.asm, assembled into its own
; SLOT 3 / PAGE #40 overlay region (see main.asm). It is dormant outside loads —
; "load a level, then sleep" — so it no longer costs resident Core space.

LOADER_OVL_PAGE    EQU #40            ; SPG page holding the loader overlay (mapped into slot 3 during loads)

; Track chunkB page: tracks longer than one 16K page (>3276 samples) are split on
; a sample boundary; chunkA -> #06 (TRACK_L01_PAGE), chunkB -> #0F. The runtime
; reads sample>=TRACK_SPLIT_SAMPLE from page #0F. (Defined here, not in the
; overlay, because VDC_ReadSampleAtHL below needs them resident.)
TRACK_PAGE2        EQU #0F
TRACK_SPLIT_SAMPLE EQU 3276        ; (16384-2)/5, first sample stored in TRACK_PAGE2

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

; Adventure state vars (CurrentLevel etc) previously lived in TSLib region
; #1937 area where TSLib activity corrupted them. Resident in Core so gameplay,
; menu and level-select code reach them while the loader overlay is unmapped.
FadeAlpha:         DEFB 0
CurrentDifficulty: DEFB 0
CurrentLevel:      DEFB 0

; Loader diagnostics — RESIDENT so an F12 dump (which captures slot 1 = Core, not
; the loader overlay page) shows how far a load got. The overlay loader writes
; them while slot 1 is mapped. Read these in a dump to bisect a failed load:
;   ZiFi_GpDbgStep : 0=not started, 1=Init, 2=PakOpen, 3=PakReadToc,
;                    #34=bg SD done, #35=track SD done, 6=success;
;                    #FF=Init err, #FE=PakOpen err, #FD=PakReadToc err.
;   ZiFi_DbgGamesA : RawPak_OpenRoot granular step —
;                    #20 entry, #21 BPB read OK, #22 BPB valid, #26 search start,
;                    #25 PAK found; #A1 BPB CMD17 err, #A2 bps!=512, #A3 spc=0,
;                    #A6 PAK not found anywhere, #A7 run-table overflow.
;   ZiFi_DbgGamesFound : directories visited during the recursive search.
ZiFi_GpDbgStep:     DEFB 0
ZiFi_GpDbgBgOff:    DEFW 0
ZiFi_GpDbgBgSize:   DEFW 0
ZiFi_DbgGamesA:     DEFB 0
ZiFi_DbgGamesFound: DEFB 0
ZiFi_DbgZumaFound:  DEFB 0
ZiFi_DbgPakFound:   DEFB 0
ZiFi_DbgPakSizeL:   DEFW 0
ZiFi_DbgPakSizeH:   DEFW 0

; ----------------------------------------------------------------------------
; Overlay trampolines (resident). Each maps LOADER_OVL_PAGE into slot 3, calls
; the real OVL_* routine in the overlay, then restores PAGE3=#04. Done under DI
; so an interrupt never sees slot 3 holding the loader page. CF (load result) is
; preserved across SetPage3 (it only touches HL) and the final EI.
; ----------------------------------------------------------------------------
LoadGameplayLevelSpecificFromPack:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadGameplayLevelSpecificFromPack
                DI                                     ; overlay (ZiFi_Done) re-enabled IRQs; re-disable to restore slot 3 atomically
                SetPage3 #04
                EI
                RET

LoadLevelSelectPreviewAssets:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadLevelSelectPreviewAssets
                DI
                SetPage3 #04
                EI
                RET

; LevelsMapLoaded — 0 until the PAK has been located + its sector run-table built
; once this session (set in RawPak_OpenRoot when the recursive search succeeds).
; Used to show "LOADING LEVELS..." only on the first (slow) menu->level-select
; transition; later transitions reuse the cached map and are near-instant.
LevelsMapLoaded:   DEFB 0

; DrawLoadingScreen — full black frame with centered "LOADING LEVELS..." using
; the FT812 built-in ROM font (no asset atlas needed, so it works before any
; level-select assets are loaded). Builds one coprocessor frame and swaps it;
; it then stays on screen during the (blocking, DI) PAK search. Resident in Core.
DrawLoadingScreen:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_CMD_BUF #04FFFFFF            ; COLOR_RGB white (text colour)
                FT_Text 320, 240, 31, FT_OPT_CENTER
                FT_CMD_BUF #44414F4C            ; "LOAD"
                FT_CMD_BUF #20474E49            ; "ING "
                FT_CMD_BUF #4556454C            ; "LEVE"
                FT_CMD_BUF #2E2E534C            ; "LS.."
                FT_CMD_BUF #0000002E            ; "." + NUL
                FT_End
                FT_Display
                FT_CMD_Count
.wsw:           FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .wsw
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET
