; loader_resident.asm — части PAK-loader, которые обязаны оставаться resident
; в Core (slot 1), потому что вызываются, когда loader overlay page НЕ mapped:
;   * VDC_ReadSampleAtHL — вызывается каждый frame из VDC_SlotPos (Main1) в PLAY;
;   * adventure cross-load vars (FadeAlpha / CurrentDifficulty / CurrentLevel),
;     читаются gameplay/menu/level-select кодом в любой момент;
;   * overlay trampolines — именованные entry points для callers; каждый мапит
;     loader page в slot 3, вызывает реальный OVL_* routine и восстанавливает #04.
;
; Основной loader (sd_zc + RawPak_* + ZiFi_* + OVL_LoadGameplay... +
; OVL_LoadLevelSelectPreviewAssets) живёт в ts-dos.asm и собирается в собственный
; SLOT 3 / PAGE #40 overlay region (см. main.asm). Вне загрузок он спит по схеме
; «загрузить уровень и уснуть», поэтому не расходует resident Core space.

LOADER_OVL_PAGE    EQU #40            ; SPG page с loader overlay; mapped в slot 3 во время загрузок
GS_PORT_DATA       EQU #00B3
GS_PORT_CMD        EQU #00BB
GS_CMD_PLAY_MODULE EQU #31
GS_CMD_STOP_MODULE EQU #32
GS_CMD_PLAY_FX     EQU #98
GS_SFX_NOTE        EQU 53            ; 11025 Hz payload на GS C-2-ish base (#30) требует примерно +5 semitones.
GS_WAIT_TIMEOUT    EQU #FFFF
                                      ; UI_OVL_PAGE (#41) глобально определён в main.asm (нужен Fade*
                                      ; transition до module Core); здесь используется trampoline.

; Track V2 runtime pages. Each page is a pure 16K array of 8-byte samples:
; Vx,Vy already baked for FT812 VERTEX2F, tangent, flags, 2 bytes padding.
; One page holds 2048 samples. Loader fills VDC_TrackPages1/2 from the V2
; metadata sector; render code selects the active table via VDC_pTrackPages.
TRACK_PAGE2        EQU #0F
TRACK_PAGE3        EQU #10
TRACK_PAGE4        EQU #12
TRACK_MAX_PAGES    EQU 4
TRACK_V2_REC       EQU 8
TRACK_V2_PAGE_SAMPLES EQU 2048
TRACK_V2_BALL_HALF EQU 26

; ----------------------------------------------------------------------------
; VDC_ReadSampleAtHL — читает track sample [HL] -> BC=X, DE=Y; выставляет
; VDC_LastT, VDC_LastTangent и VDC_LastTrackFlags; CF=0. Compatibility path для
; физики/пуль/эффектов: читает V2 Vx/Vy и восстанавливает центр X/Y = V/16+26.
; На выходе slot 2 снова VDC_ActiveTrackPage1.
; Клобает AF, HL.
; ----------------------------------------------------------------------------
VDC_ReadSampleAtHL:
                JP   VDC_ReadSampleAtHL_Slot0

; ----------------------------------------------------------------------------
; VDC_ReadRenderSampleAtHL — hot render helper. In: HL=t. Out: BC=Vx, DE=Vy,
; sets VDC_LastT/Tangent/Flags, CF=0. Keeps a tiny page-index cache so sequential
; balls only switch 16K page at 2048-sample boundaries.
; ----------------------------------------------------------------------------
VDC_ReadRenderSampleAtHL:
                JP   VDC_ReadRenderSampleAtHL_Slot0

; Adventure state vars (CurrentLevel etc) раньше лежали в TSLib region #1937,
; где их портил activity TSLib. Теперь resident в Core, чтобы gameplay/menu/
; level-select код видел их даже при unmapped loader overlay.
FadeAlpha:         DEFB 0
CurrentDifficulty: DEFB 0
CurrentLevel:      DEFB 0
CurrentSettingIndex: DEFB 0
CurrentGameMode:   DEFB 0   ; 0=Adventure, 1=Gauntlet
AdventurePos:      DEFB 0
VDC_TrackLoadPages:    DEFB TRACK_L01_PAGE, TRACK_PAGE2, TRACK_PAGE3, TRACK_PAGE4
VDC_TrackPages1:       DEFB TRACK_L01_PAGE, TRACK_PAGE2, TRACK_PAGE3, TRACK_PAGE4
VDC_TrackPages2:       DEFB TRACK_PAGE3, TRACK_PAGE4, 0, 0
VDC_pTrackPages:       DEFW VDC_TrackPages1
VDC_TrackSamples1:     DEFW 0
VDC_TrackSamples2:     DEFW 0
VDC_ActiveTrackSamples: DEFW 0
VDC_TrackPageCount1:   DEFB 0
VDC_TrackPageCount2:   DEFB 0
VDC_ActiveTrackPage1:  DEFB TRACK_L01_PAGE
VDC_RenderTrackPageIdx: DEFB #FF

; --- Hoisted gameplay/UI state (из VDC.asm / Frog.asm) -----------------------
; Перенесено в resident Core: transition + HUD/dialog/absorb/win logic из main.asm
; должны видеть эти байты, пока slot 3 держит другой scene overlay (UI page или
; gameplay page). Так FadeLevelSelectToGameplay может сбросить score ДО mapping
; gameplay page. Имена не менялись (module Core), поэтому Core.X и локальные X
; resolve как раньше. VDC_Init по-прежнему инициализирует их по именам.
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
; 24-bit cumulative adventure score (3-byte little-endian, max 16,777,215). DEFW
; переполнялся после 65535, а adventure total уходит в сотни тысяч и механика
; +1-life-per-50000 требует накопительный счёт шире 16 bit. NextLifeScore —
; следующий threshold 50000; Score_Add24 выдаёт жизнь и двигает его на 50000
; при каждом пересечении. Оба сбрасываются Score_Reset.
VDC_PlayerScore:     DB 0,0,0 ; накопительный adventure score (HUD draw + bonus в resident)
NextLifeScore:       DB #50,#C3,#00 ; следующий extra-life threshold = 50000 (0x00C350 LE)
VDC_GameSeconds:     DEFW 0   ; прошедшие gameplay seconds (HUD clock в resident)
Frog_BallColor:      DEFB 0   ; текущий loaded ball color (refiltered при смене level, resident)
Frog_NextBallColor:  DEFB 0   ; следующий ball color
                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_RESIDENT_VARS
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_RESIDENT_VARS
                endif
; LevelSelectPreviewFrogAngle: пишет/читает resident preview-frog renderer
; (LevelSelectPreviewSlot0). Renderer мапит gameplay overlay (#04) ради frog/DL
; emit code; этот байт должен оставаться доступным через swap, поэтому он resident,
; а не в UI overlay (#41), где раньше держал его LevelSelect.asm.
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

; ----------------------------------------------------------------------------
; Overlay trampolines (resident). Каждый мапит LOADER_OVL_PAGE в slot 3, вызывает
; реальный OVL_* routine в overlay и восстанавливает PAGE3=#04. Выполняется под DI,
; чтобы interrupt не увидел slot 3 с loader page. CF (load result) сохраняется через
; SetPage3 (трогает только HL) и финальный EI.
; ----------------------------------------------------------------------------
LoadGameplayLevelSpecificFromPack:
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadGameplayLevelSpecificFromPack
                DI                                     ; overlay (ZiFi_Done) включил IRQ; снова DI для атомарного restore slot 3
                SetPage3 #04
                EI
                RET

; Вызывается только из level-select (LevelSelect.asm + LevelSelectApplyLevelClick),
; который работает на UI overlay (#41), поэтому restore #41, а не #04; иначе scene
; code пропадает из slot 3 при возврате. Gameplay trampoline выше вызывается только
; из gameplay и корректно восстанавливает #04.
LoadLevelSelectPreviewAssets:
                LD   HL, (LevelSelectPreviewLoadRamL)
                LD   (BgRamL), HL
                LD   A, (LevelSelectPreviewLoadRamH)
                LD   (BgRamH), A
                DI
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_LoadLevelSelectPreviewAssets
                DI
                SetPage3 UI_OVL_PAGE                    ; restore UI overlay (level-select), не #04
                EI
                RET

GS_InitAndStartMenuMusic:
                DI
                LD   A, 1
                LD   (BootGsLabelEnabled), A
                SetPage3 LOADER_OVL_PAGE
                CALL OVL_GS_InitAndStartMenuMusic
                DI
                XOR  A
                LD   (BootGsLabelEnabled), A
                SetPage3 UI_OVL_PAGE
                EI
                RET

GS_LoadGameplaySoundsMaybe:
                DI
                LD   A, 1
                LD   (BootGsLabelEnabled), A
                LD   A, BOOT_TS_POST_GS_DELAY
                LD   (BootAnimDelay), A
                SetPage3 LOADER_OVL_PAGE
                LD   A, 1
                CALL OVL_GS_LoadGameplaySoundsMaybe
                DI
                ; Оставить loader overlay mapped, пока строка SFX authors уже latch.
                ; Следующий boot step — BootProgressSetA/LoadMainPack; оба redraw
                ; loading-screen вызывают OVL_DrawBootSfxAuthors.
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
                LD   A, (BootGsLabelEnabled)
                CP   2
                JR   Z, .keep_authors
                LD   A, 1
                LD   (BootGsLabelEnabled), A
.keep_authors:
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
                LD   A, 50
                LD   (GS_SfxSilenceTimer), A
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
                LD   A, (GS_SfxRequestId)
                CP   SND_FIREBALL1
                JR   Z, .done                         ; fireball короткий transient: не дублировать trigger
                LD   A, 2
                CALL GS_PlaySfxHandleOnChannel
                JR   NC, .done
                JR   .done

.done:         POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

; Воспроизвести preloaded SFX с явной GS note.
; Вход: A = sound id, C = note.
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
GS_SfxSilenceTimer: DEFB 0
GS_SfxHandles:      DEFS GS_SOUND_COUNT

; LevelsMapLoaded — 0, пока PAK не найден и его sector run-table не собрана
; один раз за session (ставится в RawPak_OpenRoot при успешном recursive search).
; Нужен, чтобы показать "LOADING LEVELS..." только на первом медленном переходе
; menu->level-select; поздние transitions используют cached map и почти мгновенны.
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
                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_QUIT_TRACE_VARS
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_QUIT_TRACE_VARS
                endif
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

; DrawLoadingScreen — boot-only ARGB4 loading artwork в FT RAM_G.
; UploadBootLoadingAssets загружает background, progress-bar sprite и TS anim atlas
; до BootProgressReset. Main/menu/game RAM_G uploads могут перезаписать эти адреса
; после boot.
LOADING_BAR_W EQU 255                         ; logical progress units, scaled до ширины sprite
BOOT_TS_ANIM_START_DELAY EQU 8                ; ticks DrawLoadingScreen до старта frame 0
BOOT_TS_ANIM_FRAME_DELAY EQU 5                ; extra ticks DrawLoadingScreen для удержания ZX Evolution frame
BOOT_TS_POST_GS_DELAY EQU 24                  ; обычные ZX ticks после старта GS music, перед fade-out
BOOT_TS_FADE_OUT_DELAY EQU 15                 ; hardware fade-out ticks перед SFX authors row
BOOT_SFX_AUTHORS_FRAME_DELAY EQU 90           ; extra ticks DrawLoadingScreen для удержания SFX authors reveal frame
BOOT_NOGS_MAIN_START EQU 95                   ; без GS анимации живут только на реальных тиках LoadMainPack
BOOT_NOGS_AUTHORS_AT EQU 192                  ; грубо 55:35 от GS music/SFX фаз, переложено на 95..255
BOOT_NOGS_ZX_FRAME_STEP EQU 9                 ; (192-95)/10 ~= 9.7 progress units per ZX frame
BOOT_NOGS_AUTHORS_FRAME_STEP EQU 16           ; (255-192)/4 ~= 15.8 progress units per authors reveal
BOOT_SFX_AUTHORS_LAST_FRAME EQU 4
BOOT_GS_LABEL_X EQU 624 * 8 / 5               ; 1024×768: (640−16)×1.6=998, right-aligned
BOOT_GS_LABEL_Y EQU 12 * 8 / 5                ; 19

; Логотип ZX Evolution: NEAREST ×2 (целый масштаб — чёткое пиксельное удвоение;
; ×1.6 рвал мелкий текст, BILINEAR мылил). Позиция — центр сохранён от
; пропорционального ×1.6-размещения: (226+94, 272+18)×1.6 − (W, H).
BOOT_TS_ANIM_X2 EQU (BOOT_TS_ANIM_X + BOOT_TS_ANIM_W / 2) * 8 / 5 - BOOT_TS_ANIM_W   ; 324
BOOT_TS_ANIM_Y2 EQU (BOOT_TS_ANIM_Y + BOOT_TS_ANIM_H / 2) * 8 / 5 - BOOT_TS_ANIM_H   ; 427
BootProgressPx: DEFB 0
BootAnimFrame:  DEFB 0
BootAnimDelay:  DEFB 0
BootBarFillW:   DEFW 0
BootBusOwner:   DEFB 0                       ; 0 free, 1 GS/SD stream, 2 FT812 render
BootGsLabelEnabled:  DEFB 0                   ; 0=off, 1=GS label, 2=SFX authors + GS label

BootProgressReset:
                XOR  A
                LD   (BootProgressPx), A
                LD   (BootAnimFrame), A
                LD   (BootGsLabelEnabled), A
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
                ; Shared SPI (#77/#57): снять все device и проклокать idle bus
                ; перед тем, как FT macros поднимут FT CS. То же поведение, что sd_csh.
                LD   A, #03
                LD   BC, #0077
                OUT  (C), A
                LD   A, #FF
                LD   BC, #0057
                OUT  (C), A
                RET

BootFtEnd:
                ; Оставить shared SPI bus deselected и один раз проклокать idle,
                ; чтобы следующий sd_csl стартовал с чистой границы.
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
                CALL DrawBootPopCapLogo

                FT_CMD_BUF #04FFFFFF            ; COLOR_RGB white
                ; Логотип ZX Evolution — NEAREST ×2 запечённым блоком (A=E=128/256)
                CALL BootEmitScale2xTransforms
                FT_Begin FT_BITMAPS
                LD   A, (BootGsLabelEnabled)
                CP   2
                JP   NC, .skip_ts_anim
                FT_BitmapHandle BOOT_TS_ANIM_HANDLE
                FT_BitmapSource BOOT_TS_ANIM_RAMG
                FT_BitmapLayout FT_ARGB4, BOOT_TS_ANIM_W * 2, BOOT_TS_ANIM_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_TS_ANIM_W * 2, BOOT_TS_ANIM_H * 2
                LD   A, (BootAnimFrame)
                CALL FT.Coprocessor.Cell
                LD   C, 0
                LD   D, 0
                LD   E, 0
                CALL FT.Coprocessor.ColorRGB
                LD   E, BOOT_TS_SHADOW_A
                CALL FT.Coprocessor.ColorA
                LD   BC, (BOOT_TS_ANIM_X2 + BOOT_TS_SHADOW_DX * 2) * 16
                LD   DE, (BOOT_TS_ANIM_Y2 + BOOT_TS_SHADOW_DY * 2) * 16
                CALL FT.Coprocessor.Vertex2f
                LD   C, 255
                LD   D, 255
                LD   E, 255
                CALL FT.Coprocessor.ColorRGB
                LD   E, 255
                CALL FT.Coprocessor.ColorA
                LD   BC, BOOT_TS_ANIM_X2 * 16
                LD   DE, BOOT_TS_ANIM_Y2 * 16
                CALL FT.Coprocessor.Vertex2f
.skip_ts_anim:
                ; бар (и всё после) — ×1.6 точным блоком
                CALL BootEmitScale16Transforms

                LD   A, (BootProgressPx)
                OR   A
                JP   Z, .no_fill
                CALL BootProgressToBarPixels
                LD   (BootBarFillW), HL
                FT_ScissorXY BOOT_LOADING_BAR_X * 8 / 5, BOOT_LOADING_BAR_Y * 8 / 5
                LD   HL, (BootBarFillW)
                CALL EmitScissorSizeHLBootBar
                FT_BitmapHandle BOOT_LOADING_BAR_HANDLE
                FT_BitmapSource BOOT_LOADING_BAR_RAMG
                FT_BitmapLayout FT_ARGB4, BOOT_LOADING_BAR_W * 2, BOOT_LOADING_BAR_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, (BOOT_LOADING_BAR_W * 8 + 4) / 5, (BOOT_LOADING_BAR_H * 8 + 4) / 5
                ; Vertex2ii не годится: Y=356×1.6=569 > 511 (9-битное поле) → Cell+Vertex2f
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (BOOT_LOADING_BAR_X * 8 / 5) * 16
                LD   DE, (BOOT_LOADING_BAR_Y * 8 / 5) * 16
                CALL FT.Coprocessor.Vertex2f
                FT_ScissorXY 0, 0
                FT_ScissorSize 1024, 768
.no_fill:      FT_End
                CALL BootDrawGsLabelHook
                CALL BootAnimAdvance
                FT_Display
                FT_CMD_Count
.wsw:           FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   NZ, .wsw
                FT_CMD_Write
                CALL FT.Coprocessor.WaitFlush
                FT_WR_REG8 FT_REG_DLSWAP, FT_DLSWAP_FRAME
                RET

BootDrawGsLabelHook:
                LD   A, (BootGsLabelEnabled)
                OR   A
                RET  Z
                CP   2
                CALL Z, OVL_DrawBootSfxAuthors
                JP   OVL_DrawBootGsLabel

DrawBootPopCapLogo:
                FT_SaveContext
                CALL BootEmitIdentityTransforms
                FT_CMD_BUF #04FFFFFF            ; COLOR_RGB white
                FT_ColorA 255
                FT_Begin FT_BITMAPS
                FT_BitmapHandle BOOT_POPCAP_HANDLE
                FT_BitmapSource BOOT_POPCAP_RAMG
                FT_BitmapLayout FT_ARGB4, BOOT_POPCAP_W * 2, BOOT_POPCAP_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_POPCAP_W, BOOT_POPCAP_H
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, BOOT_POPCAP_X * 16
                LD   DE, BOOT_POPCAP_Y * 16
                CALL FT.Coprocessor.Vertex2f
                FT_End
                FT_RestoreContext
                RET

DrawBootDxtBackground:
                FT_SaveContext
                ; 1024×768: матрицы ЗАПЕЧЁННЫМИ DL-словами BITMAP_TRANSFORM, БЕЗ
                ; CMD_SCALE! Копроцессор инвертирует 1.6 (#0001999A) с усечением →
                ; маска получает A=159/256, а цвета (CMD_SCALE 6.4) — ровно 40/256;
                ; пары «пиксель маски ↔ блок c0/c1» расползаются с ростом x/y →
                ; пиксельный шум по всему фону (подтверждено sim_boot_dxt_upscale.py:
                ; trunc159 = скрин юзера, точные 160/40 = чисто).
                ; Маска: A=E=160/256 = ровно 1/1.6.
                CALL BootEmitScale16Transforms

                ; color handle: cell 0 = c0 plane, cell 1 = c1 plane.
                FT_BitmapHandle BOOT_LOADING_BG_HANDLE
                FT_BitmapSource BOOT_LOADING_BG_RAMG + BOOT_LOADING_BG_C0_OFFSET
                FT_BitmapLayout FT_RGB565, BOOT_LOADING_BG_COLOR_STRIDE, BOOT_LOADING_BG_COLOR_H
                FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, BOOT_LOADING_BG_W * 8 / 5, BOOT_LOADING_BG_H * 8 / 5

                ; L4 mask хранит per-pixel blend alpha в полном 640x480 resolution.
                ; Гибрид (выбор юзера по boot_bg_1024_hybrid): маска BILINEAR — мягкие
                ; переходы блендинга; цвета остаются NEAREST — блоки c0/c1 не смазываются.
                FT_BitmapHandle BOOT_LOADING_BG_MASK_HANDLE
                FT_BitmapSource BOOT_LOADING_BG_RAMG + BOOT_LOADING_BG_MASK_OFFSET
                FT_BitmapLayout FT_L4, BOOT_LOADING_BG_MASK_STRIDE, BOOT_LOADING_BG_H
                FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, BOOT_LOADING_BG_W * 8 / 5, BOOT_LOADING_BG_H * 8 / 5

                FT_Begin FT_BITMAPS
                ; Pass 1: L4 mask -> только dst alpha.
                FT_ColorMask 0, 0, 0, 1
                FT_BlendFunc FT_ONE, FT_ZERO
                FT_ColorA 255
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_MASK_HANDLE, 0

                ; Passes 2/3: RGB565-плоскости 160×120 → экран ×6.4: A=E=40/256 =
                ; ровно 1/6.4 = (1/1.6)/4 — блок сходится с маской на КАЖДОМ x.
                ; B/C/D/F уже обнулены блоком маски выше.
                FT_ColorMask 1, 1, 1, 0
                FT_CMD_BUF #15000028            ; BITMAP_TRANSFORM_A = 40 (8.8)
                FT_CMD_BUF #19000028            ; BITMAP_TRANSFORM_E = 40 (8.8)

                FT_BlendFunc FT_DST_ALPHA, FT_ZERO
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_HANDLE, 1
                FT_BlendFunc FT_ONE_MINUS_DST_ALPHA, FT_ONE
                FT_Vertex2ii BOOT_LOADING_BG_X, BOOT_LOADING_BG_Y, BOOT_LOADING_BG_HANDLE, 0
                FT_End
                FT_RestoreContext
                RET

; BootEmitScale16Transforms — ×1.6 ЗАПЕЧЁННЫМИ DL-словами BITMAP_TRANSFORM
; (A=E=160/256 = ровно 1/1.6), LDIR-блок. Резидент Main0 — зовут boot-рисовалки
; (loader_resident) и #40-оверлей (fade-out, SFX-авторы). НЕ через CMD_SCALE:
; его инверсия в копроцессоре усечённая (159/256) — для DXT-пар это шум,
; для спрайтов — потеря правого края.
BootEmitIdentityTransforms:
                LD   HL, BootIdentityBlk
                JR   BootEmitTransformsHL
BootEmitScale2xTransforms:
                LD   HL, BootScale2xBlk
                JR   BootEmitTransformsHL
BootEmitScale16Transforms:
                LD   HL, BootScale16Blk
BootEmitTransformsHL:
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 24
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                RET
BootScale16Blk: DEFD #150000A0                  ; BITMAP_TRANSFORM_A = 160/256 = 1/1.6
                DEFD #16000000                  ; B = 0
                DEFD #17000000                  ; C = 0
                DEFD #18000000                  ; D = 0
                DEFD #190000A0                  ; BITMAP_TRANSFORM_E = 160/256
                DEFD #1A000000                  ; F = 0
BootScale2xBlk: DEFD #15000080                  ; BITMAP_TRANSFORM_A = 128/256 = 1/2
                DEFD #16000000                  ; B = 0
                DEFD #17000000                  ; C = 0
                DEFD #18000000                  ; D = 0
                DEFD #19000080                  ; BITMAP_TRANSFORM_E = 128/256
                DEFD #1A000000                  ; F = 0
BootIdentityBlk: DEFD #15000100                 ; BITMAP_TRANSFORM_A = 256/256 (native)
                DEFD #16000000                  ; B = 0
                DEFD #17000000                  ; C = 0
                DEFD #18000000                  ; D = 0
                DEFD #19000100                  ; BITMAP_TRANSFORM_E = 256/256
                DEFD #1A000000                  ; F = 0

DrawBootBlackScreen:
                XOR  A
                LD   (BootGsLabelEnabled), A
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ScissorXY 0, 0
                FT_ScissorSize 1024, 768       ; 1024×768: иначе CLEAR чистит только 640×480 (полосы мусора справа/снизу)
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
                ; 1024×768: HL ~= progress * 2.4 (640-коэфф. 1.5 × 1.6); финальный 255
                ; клампится в полную ширину спрайта ×8/5. Аппроксимация без деления:
                ; 2 + 1/4 + 1/8 + 1/32 = 2.40625 (+0.26%, max +0.7px — невидимо).
                LD   A, (BootProgressPx)
                CP   255
                JR   Z, .full
                LD   L, A
                LD   H, 0
                ADD  HL, HL                    ; 2·px
                LD   E, A
                LD   D, 0
                SRL  E
                SRL  E                         ; px/4
                ADD  HL, DE
                SRL  E                         ; px/8
                ADD  HL, DE
                SRL  E
                SRL  E                         ; px/32
                ADD  HL, DE
                RET
.full:         LD   HL, BOOT_LOADING_BAR_W * 8 / 5
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
                LD   E, (BOOT_LOADING_BAR_H * 8 + 4) / 5  ; 1024×768: высота клипа ×1.6 (ceil — как окно)
                LD   B, #1C
                JP   FT.Coprocessor.Command_BCDE

BootAnimAdvance:
                LD   A, (GS_Present)
                OR   A
                JR   Z, BootAnimAdvanceNoGs
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
                LD   A, (BootGsLabelEnabled)
                CP   2
                LD   A, BOOT_TS_ANIM_FRAME_DELAY
                JR   NZ, .setDelay
                LD   A, BOOT_SFX_AUTHORS_FRAME_DELAY
.setDelay:
                LD   (BootAnimDelay), A
                RET

BootAnimAdvanceNoGs:
                LD   A, (BootGsLabelEnabled)
                OR   A
                RET  Z
                LD   A, (BootProgressPx)
                CP   BOOT_NOGS_AUTHORS_AT
                JR   NC, .authors
                LD   A, 1
                LD   (BootGsLabelEnabled), A
                XOR  A
                LD   (BootAnimDelay), A
                LD   A, (BootProgressPx)
                SUB  BOOT_NOGS_MAIN_START
                JR   C, .zxZero
                LD   B, 0
.zxLoop:        CP   BOOT_NOGS_ZX_FRAME_STEP
                JR   C, .setB
                SUB  BOOT_NOGS_ZX_FRAME_STEP
                INC  B
                LD   C, A
                LD   A, B
                CP   BOOT_TS_ANIM_FRAMES - 1
                JR   NC, .zxLast
                LD   A, C
                JR   .zxLoop
.zxLast:        LD   A, BOOT_TS_ANIM_FRAMES - 1
                LD   (BootAnimFrame), A
                RET
.zxZero:        XOR  A
                LD   (BootAnimFrame), A
                RET
.authors:       LD   A, 2
                LD   (BootGsLabelEnabled), A
                XOR  A
                LD   (BootAnimDelay), A
                LD   A, (BootProgressPx)
                SUB  BOOT_NOGS_AUTHORS_AT
                LD   B, 1
.authorsLoop:   CP   BOOT_NOGS_AUTHORS_FRAME_STEP
                JR   C, .setB
                SUB  BOOT_NOGS_AUTHORS_FRAME_STEP
                INC  B
                LD   C, A
                LD   A, B
                CP   BOOT_SFX_AUTHORS_LAST_FRAME
                JR   NC, .authorsLast
                LD   A, C
                JR   .authorsLoop
.authorsLast:   LD   A, BOOT_SFX_AUTHORS_LAST_FRAME
                LD   (BootAnimFrame), A
                RET
.setB:          LD   A, B
                LD   (BootAnimFrame), A
                RET
