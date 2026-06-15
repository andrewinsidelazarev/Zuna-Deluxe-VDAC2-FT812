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
GS_PORT_DATA       EQU #00B3
GS_PORT_CMD        EQU #00BB
GS_CMD_PLAY_MODULE EQU #31
GS_CMD_STOP_MODULE EQU #32
GS_CMD_PLAY_FX     EQU #98
GS_SFX_NOTE        EQU 53            ; 11025 Hz payload at GS C-2-ish base (#30) needs about +5 semitones.
GS_WAIT_TIMEOUT    EQU #FFFF
                                      ; UI_OVL_PAGE (#41) is defined globally in main.asm (needed before
                                      ; module Core by the Fade* transitions); referenced here for the trampoline.

; Track chunkB page: tracks longer than one 16K page (>3276 samples) are split on
; a sample boundary. The active track pages are resident variables because the
; two-curve boards reuse the same reader for the second path.
TRACK_PAGE2        EQU #0F
TRACK_SPLIT_SAMPLE EQU 3276        ; (16384-2)/5, first sample stored in TRACK_PAGE2

; ----------------------------------------------------------------------------
; VDC_ReadSampleAtHL — read track sample [HL] -> BC=X, DE=Y; set VDC_LastT and
; VDC_LastTangent; CF=0. Core-resident (called as a tail-jump from VDC_SlotPos
; in Main1, which is nearly full). Handles the 2-page track split: samples below
; TRACK_SPLIT_SAMPLE sit on VDC_ActiveTrackPage1 at #8000+2+t*5; samples at/above
; live on VDC_ActiveTrackPage2 at #8000+(t-split)*5 (chunkB has no count header).
; Leaves slot 2 mapped to VDC_ActiveTrackPage1. Clobbers AF, HL.
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
                LD   A, (VDC_ActiveTrackPage2)
                SetPage2_A                             ; map #0F (clobbers A, BC)
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   C, (HL) : INC HL
                LD   B, (HL) : INC HL                  ; BC = Y
                LD   A, (HL)
                LD   (VDC_LastTangent), A
                PUSH BC : PUSH DE                      ; save Y, X across page restore
                LD   A, (VDC_ActiveTrackPage1)
                SetPage2_A                             ; restore active track page for callers
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
VDC_ActiveTrackPage1: DEFB TRACK_L01_PAGE
VDC_ActiveTrackPage2: DEFB TRACK_PAGE2

; --- Hoisted gameplay/UI state (originally in VDC.asm / Frog.asm) -----------
; Moved to resident Core so the resident transition + HUD/dialog/absorb/win
; logic in main.asm reaches them while slot 3 holds a DIFFERENT scene overlay
; (UI page vs gameplay page) — and so FadeLevelSelectToGameplay can reset the
; score BEFORE the gameplay page is mapped. Names unchanged (module Core) → all
; existing references (qualified Core.X and in-module X) resolve untouched.
; VDC_Init still initialises these by name. See typed-launching-sunset plan.
VDC_GameState:       DEFB 0   ; 0=play,1=absorb,2=gameover,3=intro,4=preview,5=closing
VDC_HSub:            DEFB 0   ; head sub-position (absorb physics, resident UpdateAbsorbState)
VDC_SlotsLen:        DEFB 0   ; chain length (win/absorb logic in resident)
VDC_KzFrame:         DEFB 0   ; skull-mouth frame (DrawKillzone resident)
VDC_HeadAbsorbAlpha: DEFB 255 ; head-ball fade alpha during state=1 absorb
VDC_Lives:           DEFB 3   ; lives (start 3, +1/50k, carried across levels)
VDC_DialogState:     DEFB 0   ; 0=NONE,1=RETRY,2=GAMEOVER,3=pause,4=pause-fade,5=WIN_DONE,6=WIN_FADE
VDC_PrevMouseL:      DEFB 0   ; previous LMB state for dialog edge detection
VDC_HudMenuState:    DEFB 0   ; 0=inactive,1=hover,2=pressed (HUD MENU button)
VDC_HudPointerBlock: DEFB 0   ; pointer over HUD button: suppress frog fire edge
VDC_GaugeScore:      DEFW 0   ; Zuma bar score this level (win condition in resident)
VDC_GaugeFull:       DEFB 0   ; 0=yellow filling, 1=green full
; 24-bit cumulative adventure score (3-byte little-endian, max 16,777,215). Was
; DEFW (16-bit) which overflowed past 65535 — but adventure totals reach hundreds
; of thousands and the +1-life-per-50000 mechanic needs cumulative beyond 16 bits.
; NextLifeScore is the next 50000 threshold; Score_Add24 grants a life and advances
; it by 50000 each time the score crosses it. Both reset by Score_Reset.
VDC_PlayerScore:     DB 0,0,0 ; cumulative adventure score (HUD draw + bonus in resident)
NextLifeScore:       DB #50,#C3,#00 ; next extra-life threshold = 50000 (0x00C350 LE)
VDC_GameSeconds:     DEFW 0   ; elapsed gameplay seconds (HUD clock in resident)
Frog_BallColor:      DEFB 0   ; current loaded ball color (refiltered on level change, resident)
Frog_NextBallColor:  DEFB 0   ; next ball color
; VDC invariant diagnostics for F12 dumps. First failure is latched until VDC_Init:
;   code 1: SlotsLen > VDC_MAX_SLOTS
;   code 2: HSA > TrackNumSlots
;   code 3: Slots[i] is neither color nor GAP marker
;   code 4: Offsets[i] outside [-CELL_SIZE..CELL_SIZE]
;   code 5: ExplodeFrame[i] has invalid ExplodeMarker
;   code 6: Shot2[i] is not 0/1
VDC_AssertCode:      DEFB 0
VDC_AssertCtx:       DEFB 0
VDC_AssertLen:       DEFB 0
VDC_AssertHSA:       DEFB 0
VDC_AssertValue:     DEFB 0
VDC_AssertFrame:     DEFW 0
; LevelSelectPreviewFrogAngle: written/read by the resident preview-frog renderer
; (LevelSelectPreviewSlot0). The renderer maps the gameplay overlay (#04) for the
; frog/DL emit code; this one byte must stay reachable across that swap, so it is
; resident rather than on the UI overlay (#41) where LevelSelect.asm used to keep it.
LevelSelectPreviewFrogAngle: DEFB 64

; ----------------------------------------------------------------------------
; WIN-взрыв: «бегущая дорожка» взрывов ОТ головного шара (ближайшего к килл-зоне)
; ДО килл-зоны (конца трека). Чем дальше голова была от КЗ — тем длиннее дорожка
; (= больше бонус). Снимаем track-сэмпл ГОЛОВНОГО шара (макс. сэмпл = фронт цепи)
; каждый PLAY-кадр, ДО очистки (keep-last-non-empty: храним последний кадр, где
; шары были видимы). К WIN цепочка пуста, но трек ещё загружен → дорожку рисуем
; по live-треку от сохранённого head-сэмпла. #FFFF = нет данных (не рисуем).
; Резидент Core: пишется кодом VDC (slot1), читается WIN-рендером в оверлее #04.
; ----------------------------------------------------------------------------
VDC_WinHeadS1:     DEFW #FFFF           ; chain1: сэмпл головного шара (фронт)
VDC_WinHeadS2:     DEFW #FFFF           ; chain2 (дубль-уровни)
VDC_WinTmpMax:     DEFW 0               ; scratch: макс. сэмпл за проход цепочки
VDC_WinTmpFound:   DEFB 0               ; scratch: найден ли видимый шар

; --- WIN-аутро «бикфорд» (точно по оригиналу Zuma Game_UpdateOutro/FX.c):
; эмиттер бежит по треку head→килл-зона, роняя НЕЗАВИСИМЫЕ частицы-взрывы. ---
WIN_PRTCL_MAX      EQU 32
WINEXP_MOVE        EQU 12               ; сэмплов/кадр (скорость бегущей точки)
WINEXP_PAD         EQU 30               ; сэмплов между взрывами (+100 за каждый)
WINEXP_F2_MAX      EQU 32               ; f2 = 2×frame; >32 → частица мертва (frame 0..16)
VDC_WinOutroActive: DEFB 0              ; 1 = аутро запущено (есть head-данные)
VDC_WinEmitPos1:   DEFW #FFFF           ; chain1 эмиттер: текущий сэмпл (#FFFF=дошёл)
VDC_WinEmitSpawn1: DEFW 0               ; сэмпл последнего спавна chain1
VDC_WinEmitPos2:   DEFW #FFFF           ; chain2
VDC_WinEmitSpawn2: DEFW 0
VDC_WinPrtcl:      DEFS WIN_PRTCL_MAX * 5  ; на частицу: X(w),Y(w),f2(b); f2=255 мёртвая

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

; Called only from level-select (LevelSelect.asm + LevelSelectApplyLevelClick),
; which runs on the UI overlay (#41) — so restore #41, not #04, else the scene
; code vanishes from slot 3 on return. (The gameplay trampoline above is only
; reached from gameplay, so it correctly restores #04.)
LoadLevelSelectPreviewAssets:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadLevelSelectPreviewAssets
                DI
                SetPage3 UI_OVL_PAGE                    ; restore UI overlay (level-select), not #04
                EI
                RET

GS_InitAndStartMenuMusic:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_GS_InitAndStartMenuMusic
                DI
                SetPage3 UI_OVL_PAGE
                EI
                RET

GS_LoadGameplaySoundsMaybe:
                DI
                SetPage3 LOADER_OVL_PAGE
                LD   A, 1
                CALL OVL_GS_LoadGameplaySoundsMaybe
                DI
                SetPage3 #04
                EI
                RET

GS_LoadGameplaySoundsMaybeQuiet:
                DI
                SetPage3 LOADER_OVL_PAGE
                XOR  A
                CALL OVL_GS_LoadGameplaySoundsMaybe
                DI
                SetPage3 #04
                EI
                RET

LoadMainPack:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadMainPack
                DI
                SetPage3 UI_OVL_PAGE
                EI
                RET

GS_PlayMenuMusic:
                LD   A, (GS_Present)
                OR   A
                RET  Z
                LD   A, (GS_MenuMusicLoaded)
                OR   A
                RET  Z
                LD   A, (GS_MenuMusicPlaying)
                OR   A
                RET  NZ
                LD   A, (GS_MenuMusicHandle)
                OR   A
                RET  Z
                CALL GS_SendDataResident
                RET  NC
                LD   A, GS_CMD_PLAY_MODULE
                CALL GS_SendCommandResident
                RET  NC
                LD   A, 1
                LD   (GS_MenuMusicPlaying), A
                SCF
                RET

GS_StopMenuMusic:
                LD   A, (GS_Present)
                OR   A
                RET  Z
                LD   A, (GS_MenuMusicLoaded)
                OR   A
                RET  Z
                LD   A, GS_CMD_STOP_MODULE
                CALL GS_SendCommandResident
                RET  NC
                XOR  A
                LD   (GS_MenuMusicPlaying), A
                SCF
                RET

GS_PlaySfx:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                LD   (GS_SfxRequestId), A
                LD   A, GS_SFX_NOTE
                LD   (GS_SfxRequestNote), A
GS_PlaySfxCommon:
                LD   A, (GS_Present)
                OR   A
                JR   Z, .done
                LD   A, (GS_SfxLoaded)
                OR   A
                JR   Z, .done
                LD   A, (GS_SfxRequestId)
                CP   GS_SOUND_COUNT
                JR   NC, .done
                LD   H, 0
                LD   L, A
                LD   DE, GS_SfxHandles
                ADD  HL, DE
                LD   A, (HL)
                CP   #FF
                JR   Z, .done
                XOR  A
                CALL GS_PlaySfxHandleOnChannel
                JR   NC, .done
                LD   A, 2
                CALL GS_PlaySfxHandleOnChannel
                JR   NC, .done
                JR   .done

.done:         POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

; Play preloaded SFX with explicit GS note.
; In: A = sound id, C = note.
GS_PlaySfxNote:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                LD   (GS_SfxRequestId), A
                LD   A, C
                LD   (GS_SfxRequestNote), A
                JR   GS_PlaySfxCommon

GS_PlaySfxHandleOnChannel:
                PUSH AF
                LD   A, (GS_SfxRequestId)
                LD   H, 0
                LD   L, A
                LD   DE, GS_SfxHandles
                ADD  HL, DE
                LD   A, (HL)
                CALL GS_SendDataResident
                JR   C, .handleOk
                POP  AF
                OR   A
                RET
.handleOk:      POP  AF
                ADD  A, GS_CMD_PLAY_FX
                CALL GS_SendCommandResident
                RET  NC
                LD   A, (GS_SfxRequestNote)
                CALL GS_SendDataResident
                RET  NC
                LD   A, #40
                CALL GS_SendDataResident
                RET

GS_UpdateSfxMuteMaybe:
                RET

GS_SendCommandResident:
                LD   BC, GS_PORT_CMD
                OUT  (C), A
                LD   HL, GS_WAIT_TIMEOUT
.wcmd:         IN   A, (C)
                RRCA
                JR   NC, .cmdOk
                DEC  HL
                LD   A, H
                OR   L
                JR   NZ, .wcmd
                OR   A
                RET
.cmdOk:        SCF
                RET

; Как в WC: СНАЧАЛА ждём место в FIFO (bit7=0), ПОТОМ пишем байт. См. подробный
; комментарий у GS_SendDataOverlay. Байт сохраняем в E на время ожидания.
GS_SendDataResident:
                PUSH HL
                PUSH DE
                LD   E, A                       ; сохранить байт данных
                LD   BC, GS_PORT_CMD            ; #BB — статус
                LD   HL, GS_WAIT_TIMEOUT
.wdat:         IN   A, (C)
                RLCA                            ; bit7 -> CF (1 = FIFO полон)
                JR   NC, .datOk                 ; bit7=0 -> есть место
                DEC  HL
                LD   A, H
                OR   L
                JR   NZ, .wdat
                POP  DE
                POP  HL
                OR   A                          ; таймаут -> CF=0
                RET
.datOk:        LD   A, E
                LD   BC, GS_PORT_DATA           ; #B3 — данные
                OUT  (C), A                     ; место есть -> пишем
                POP  DE
                POP  HL
                SCF
                RET

GS_Present:         DEFB 0
GS_MenuMusicLoaded: DEFB 0
GS_MenuMusicHandle: DEFB 0
GS_MenuMusicPlaying: DEFB 0
GS_SfxLoaded:       DEFB 0
GS_RamPages:        DEFB 0
GS_SfxRequestId:    DEFB 0
GS_SfxRequestNote:  DEFB 0
GS_SfxHandles:      DEFS GS_SOUND_COUNT

; LevelsMapLoaded — 0 until the PAK has been located + its sector run-table built
; once this session (set in RawPak_OpenRoot when the recursive search succeeds).
; Used to show "LOADING LEVELS..." only on the first (slow) menu->level-select
; transition; later transitions reuse the cached map and are near-instant.
LevelsMapLoaded:   DEFB 0

; --- Quit HOBETA loader, Этап 1: проба BOOT.$C. Результаты резидентны (slot1/Core),
; читаются в F12-дампе независимо от того, что в slot3. ProbeBootHobeta — трамплин:
; мапит loader overlay в slot3, зовёт OVL_ProbeBoot, восстанавливает UI overlay.
Boot_Found:        DEFB 0         ; 1 = BOOT.$C найден и 1-й сектор прочитан
Boot_Clus:         DEFS 4         ; стартовый кластер (LE)
Boot_Size:         DEFS 4         ; размер файла в байтах (LE)
Boot_Hdr:          DEFS 32        ; первые 32 байта файла (HOBETA-заголовок)
Boot_StartLba:     DEFS 4         ; LBA первого сектора файла (абсолютный, LE)
Boot_SecCount:     DEFB 0         ; число секторов = ceil(size/512)
Boot_Blkt:         DEFB 0         ; sd_blkt (0=byte addressing, 1=block)
Quit_DbgStage:     DEFB 0         ; стадия Quit: #10 probe, #20 copy, #30 params, #40 jump, #80+ стаб
Quit_DbgSectors:   DEFB 0         ; сколько секторов успел прочитать стаб
ProbeBootHobeta:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_ProbeBoot
                DI
                SetPage3 UI_OVL_PAGE
                EI
                RET

; QuitStub_Image — байты релоцируемого загрузчика WC (Этап 2). Ассемблируются как
; будто по #4000 (DISP), но лежат в резиденте; на Quit копируются в #4000 (bank5).
; QuitStub_Run/QS_Lba/QS_Cnt/QS_Blkt — это адреса #40xx (disp), оркестратор пишет
; параметры по ним ПОСЛЕ копирования образа.
QuitStub_Image:
                DISP #4000
                include "quit_loader_stub.asm"
                ENT
QuitStub_Len   EQU $ - QuitStub_Image

; DrawLoadingScreen — boot-only ARGB4 loading artwork in FT RAM_G.
; UploadBootLoadingAssets loads the background, progress-bar sprite and TS anim
; atlas before BootProgressReset. Main/menu/game RAM_G uploads may overwrite
; those addresses after boot.
LOADING_BAR_W EQU 255                         ; logical progress units, scaled to sprite width
BOOT_TS_ANIM_START_DELAY EQU 8                ; DrawLoadingScreen ticks before frame 0 starts advancing
BOOT_TS_ANIM_FRAME_DELAY EQU 5                ; extra DrawLoadingScreen ticks to hold each anim frame
BootProgressPx: DEFB 0
BootAnimFrame:  DEFB 0
BootAnimDelay:  DEFB 0
BootBarFillW:   DEFW 0
BootBusOwner:   DEFB 0                       ; 0 free, 1 GS/SD stream, 2 FT812 render

BootProgressReset:
                XOR  A
                LD   (BootProgressPx), A
                LD   (BootAnimFrame), A
                LD   A, BOOT_TS_ANIM_START_DELAY
                LD   (BootAnimDelay), A
                JP   BootLoadingTickSafe

BootProgressSetA:
                CP   LOADING_BAR_W
                JR   C, .ok
                LD   A, LOADING_BAR_W
.ok:            LD   C, A
                LD   A, (BootProgressPx)
                CP   C
                RET  NC
                LD   A, C
                LD   (BootProgressPx), A
                JP   BootLoadingTickSafe

BootProgressInc:
                LD   A, (BootProgressPx)
                CP   LOADING_BAR_W
                RET  NC
                INC  A
                LD   (BootProgressPx), A
                JP   BootLoadingTickSafe

BootProgressIncNoDraw:
                LD   A, (BootProgressPx)
                CP   LOADING_BAR_W
                RET  NC
                INC  A
                LD   (BootProgressPx), A
                RET

BootProgressAddA:
                LD   C, A
                LD   A, (BootProgressPx)
                ADD  A, C
                JR   C, .max
                CP   LOADING_BAR_W
                JR   C, .ok
.max:           LD   A, LOADING_BAR_W
.ok:            LD   (BootProgressPx), A
                JP   BootLoadingTickSafe

BootProgressAddNoDraw:
                LD   C, A
                LD   A, (BootProgressPx)
                ADD  A, C
                JR   C, .max
                CP   LOADING_BAR_W
                JR   C, .ok
.max:           LD   A, LOADING_BAR_W
.ok:            LD   (BootProgressPx), A
                RET

BootLoadingTick:
                JP   BootLoadingTickSafe

BootLoadingTickSafe:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                PUSH IX
                PUSH IY
                CALL BootFtBegin
                CALL DrawLoadingScreen
                CALL BootFtEnd
                POP  IY
                POP  IX
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

BootFtBegin:
.wait:          LD   A, (BootBusOwner)
                OR   A
                JR   Z, .go
                JR   .wait
.go:            LD   A, 2
                LD   (BootBusOwner), A
                ; Shared SPI (#77/#57): release every device and clock the idle
                ; bus before FT macros assert FT CS. This mirrors sd_csh.
                LD   A, #03
                LD   BC, #0077
                OUT  (C), A
                LD   A, #FF
                LD   BC, #0057
                OUT  (C), A
                RET

BootFtEnd:
                ; Leave the shared SPI bus deselected and clock idle once so the
                ; next sd_csl starts from a clean boundary.
                LD   A, #03
                LD   BC, #0077
                OUT  (C), A
                LD   A, #FF
                LD   BC, #0057
                OUT  (C), A
                XOR  A
                LD   (BootBusOwner), A
                RET

BootProgressIncSafe:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                PUSH IX
                PUSH IY
                CALL BootProgressIncNoDraw
                CALL BootLoadingTickSafe
                POP  IY
                POP  IX
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

DrawLoadingScreen:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_CMD_BUF #04FFFFFF            ; COLOR_RGB white

                if BOOT_LOADING_BG_ENABLED
                CALL DrawBootDxtBackground
                endif

                FT_CMD_BUF #04FFFFFF            ; COLOR_RGB white
                FT_Begin FT_BITMAPS
                FT_BitmapHandle BOOT_TS_ANIM_HANDLE
                FT_BitmapSource BOOT_TS_ANIM_RAMG
                FT_BitmapLayout FT_ARGB4, BOOT_TS_ANIM_W * 2, BOOT_TS_ANIM_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_TS_ANIM_W, BOOT_TS_ANIM_H
                LD   A, (BootAnimFrame)
                CALL FT.Coprocessor.Cell
                LD   C, 0
                LD   D, 0
                LD   E, 0
                CALL FT.Coprocessor.ColorRGB
                LD   E, BOOT_TS_SHADOW_A
                CALL FT.Coprocessor.ColorA
                LD   BC, (BOOT_TS_ANIM_X + BOOT_TS_SHADOW_DX) * 16
                LD   DE, (BOOT_TS_ANIM_Y + BOOT_TS_SHADOW_DY) * 16
                CALL FT.Coprocessor.Vertex2f
                LD   C, 255
                LD   D, 255
                LD   E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                LD   BC, BOOT_TS_ANIM_X * 16
                LD   DE, BOOT_TS_ANIM_Y * 16
                CALL FT.Coprocessor.Vertex2f

                LD   A, (BootProgressPx)
                OR   A
                JP   Z, .no_fill
                CALL BootProgressToBarPixels
                LD   (BootBarFillW), HL
                FT_ScissorXY BOOT_LOADING_BAR_X, BOOT_LOADING_BAR_Y
                LD   HL, (BootBarFillW)
                CALL EmitScissorSizeHLBootBar
                FT_BitmapHandle BOOT_LOADING_BAR_HANDLE
                FT_BitmapSource BOOT_LOADING_BAR_RAMG
                FT_BitmapLayout FT_ARGB4, BOOT_LOADING_BAR_W * 2, BOOT_LOADING_BAR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_LOADING_BAR_W, BOOT_LOADING_BAR_H
                FT_Vertex2ii BOOT_LOADING_BAR_X, BOOT_LOADING_BAR_Y, BOOT_LOADING_BAR_HANDLE, 0
                FT_ScissorXY 0, 0
                FT_ScissorSize 640, 480
.no_fill:      CALL BootAnimAdvance
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

DrawBootDxtBackground:
                FT_SaveContext
                FT_LoadIdentity
                FT_SetMatrix

                ; color handle: cell 0 = c0 plane, cell 1 = c1 plane.
                FT_BitmapHandle BOOT_LOADING_BG_HANDLE
                FT_BitmapSource BOOT_LOADING_BG_RAMG + BOOT_LOADING_BG_C0_OFFSET
                FT_BitmapLayout FT_RGB565, BOOT_LOADING_BG_COLOR_STRIDE, BOOT_LOADING_BG_COLOR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_LOADING_BG_W, BOOT_LOADING_BG_H

                ; L4 mask stores per-pixel blend alpha at full 640x480 resolution.
                FT_BitmapHandle BOOT_LOADING_BG_MASK_HANDLE
                FT_BitmapSource BOOT_LOADING_BG_RAMG + BOOT_LOADING_BG_MASK_OFFSET
                FT_BitmapLayout FT_L4, BOOT_LOADING_BG_MASK_STRIDE, BOOT_LOADING_BG_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_LOADING_BG_W, BOOT_LOADING_BG_H

                FT_Begin FT_BITMAPS
                ; Pass 1: L4 mask -> dst alpha only.
                FT_ColorMask 0, 0, 0, 1
                FT_BlendFunc FT_ONE, FT_ZERO
                FT_ColorA 255
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_MASK_HANDLE, 0

                ; Passes 2/3: draw RGB565 endpoint cells scaled from 160x120 to 640x480.
                FT_ColorMask 1, 1, 1, 0
                FT_LoadIdentity
                FT_CMD_BUF FT_CMD_SCALE
                FT_CMD_BUF #00040000
                FT_CMD_BUF #00040000
                FT_SetMatrix

                FT_BlendFunc FT_DST_ALPHA, FT_ZERO
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_HANDLE, 1
                FT_BlendFunc FT_ONE_MINUS_DST_ALPHA, FT_ONE
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_HANDLE, 0
                FT_End
                FT_RestoreContext
                RET

DrawBootBlackScreen:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ScissorXY 0, 0
                FT_ScissorSize 640, 480
                FT_ColorMask 1, 1, 1, 1
                FT_BlendFunc FT_SRC_ALPHA, FT_ONE_MINUS_SRC_ALPHA
                FT_ColorA 255
                FT_CMD_BUF #04FFFFFF
                FT_LoadIdentity
                FT_SetMatrix
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_Display
                FT_CMD_Count
.wsw:           FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .wsw
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

; ----------------------------------------------------------------------------
; ClearRamGForMenu — явно стереть грязный хвост boot RAM_G перед главным меню.
;   Вызывается в начале MenuMain (на КАЖДОМ входе в меню — после загрузки и при
;   возврате из игры/level-select/more-games), ДО заливки ассетов меню.
;   Зачем: реальный FT812 показал, что CMD_MEMZERO не является надёжным барьером
;   для этого перехода. Поэтому для A/B-теста не используем копроцессор вообще:
;   прямой SPI-записью затираем область boot progress/logo #0C8000..#0F8000.
; ----------------------------------------------------------------------------
CLEAR_RAMG_TAIL_ADDR   EQU #0C8000
CLEAR_RAMG_TAIL_SIZE   EQU #030000
CLEAR_RAMG_CHUNK_SIZE  EQU #000400
CLEAR_RAMG_CHUNKS      EQU CLEAR_RAMG_TAIL_SIZE / CLEAR_RAMG_CHUNK_SIZE

ClearRamGForMenu:
                LD   A, (CLEAR_RAMG_TAIL_ADDR >> 16) & #FF
                LD   DE, CLEAR_RAMG_TAIL_ADDR & #FFFF
                LD   B, CLEAR_RAMG_CHUNKS
.wipe_loop:    PUSH BC
                LD   HL, ClearRamGZeroBuf
                LD   BC, CLEAR_RAMG_CHUNK_SIZE
                CALL FT.WriteMem                         ; advances A:DE by BC
                POP  BC
                DJNZ .wipe_loop
                RET

ClearRamGZeroBuf:
                DEFS CLEAR_RAMG_CHUNK_SIZE

BootProgressToBarPixels:
                ; HL ~= progress * 1.5; final 255 clamps to full sprite width.
                LD   A, (BootProgressPx)
                CP   255
                JR   Z, .full
                LD   L, A
                LD   H, 0
                LD   E, A
                LD   D, 0
                SRL  E
                ADD  HL, DE
                RET
.full:         LD   HL, BOOT_LOADING_BAR_W
                RET

EmitScissorSizeHLBootBar:
                ; SCISSOR_SIZE(width=HL, height=BOOT_LOADING_BAR_H).
                LD   A, H
                RLCA
                RLCA
                RLCA
                RLCA
                LD   C, A
                LD   A, L
                SRL  A
                SRL  A
                SRL  A
                SRL  A
                OR   C
                LD   C, A
                LD   A, L
                AND  #0F
                RLCA
                RLCA
                RLCA
                RLCA
                LD   D, A
                LD   E, BOOT_LOADING_BAR_H
                LD   B, #1C
                JP   FT.Coprocessor.Command_BCDE

BootAnimAdvance:
                LD   A, (BootAnimDelay)
                OR   A
                JR   Z, .canAdvance
                DEC  A
                LD   (BootAnimDelay), A
                RET
.canAdvance:
                LD   A, (BootAnimFrame)
                CP   BOOT_TS_ANIM_FRAMES - 1
                RET  NC
                INC  A
                LD   (BootAnimFrame), A
                LD   A, BOOT_TS_ANIM_FRAME_DELAY
                LD   (BootAnimDelay), A
                RET
