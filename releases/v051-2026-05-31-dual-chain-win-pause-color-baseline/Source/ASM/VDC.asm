
                ifndef _ZUMA_VDC_
                define _ZUMA_VDC_

; ============================================================================
; VDC — Virtual Discrete Chain physics для Zuma VDAC2 (640x480).
; ----------------------------------------------------------------------------
; Порт vdc_visual_emulator.py 1:1. Отличия от 360x288 asm-версии:
;   - CELL_SIZE = 32 (как в 360x288). Track 640x480 = 2774 samples,
;     2774/32 ≈ 87 slots — помещается в byte, но HSA word для запаса.
;   - LastRenderPos НЕ хранится: при t<0 рендер skip. Trade-off: при cascade
;     rollback шары на спавне на 1-2 кадра становятся невидимыми. Можно добавить
;     потом как опциональный массив.
;   - Match-3 has a visual explosion phase. Slots keep their color while
;     VDC_ExplodeFrame > 0; after the timer expires the saved GAP marker is
;     committed and normal VDC gap closing continues.
;
; API:
;   VDC_Init       — обнулить все массивы, Slots[] = GAP_STOP, RNG seed.
;   VDC_Update     — TrySpawn + MoveChain + AnimateChain. Один вызов = один кадр.
;   VDC_SlotPos    — для слота A считает (X,Y) центра шара.
;                    Out: BC=X, DE=Y, CF=1 если skip (gap или t<0).
;   VDC_InsertAt   — A=target_idx, B=color. Вставить шар, проверить match.
;
; Все функции корраптят AF/BC/DE/HL.
; TrackData layout (page 6 в slot 2 #8000):
;   word LE NumSamples, затем NumSamples * (sword X, sword Y, byte tangent),
;   stride = 5 bytes per sample.
; ============================================================================

VDC_LEVEL_START_BALLS  EQU 35                            ; быстрая фаза: 35 шаров «поездом»
VDC_FAST_ADVANCE       EQU 12                            ; MoveChain ×12 за tick в fast-фазе
VDC_ABSORB_ADVANCE     EQU 8                             ; absorb chain advance: 8 px/tick (32/8=4 ticks/cell)
VDC_CELL_SIZE          EQU 32                            ; sample-units на slot.
VDC_DECAY_NEG          EQU 2                             ; insert head slide (neg→0) быстро.
VDC_DECAY_POS          EQU 1                             ; cascade rollback (pos→0) плавно.
                                                          ; track chord 1.0815 px/sample: 32×1.08 ≈ 34.6 px
                                                          ; centers, ball 32 px → gap ~2.6 px на прямой.
                                                          ; Используется в VDC_SlotT через ZL_Mul16x8.
                                                         ; track 1.067 px/sample → 42*1.067 ≈ 45 px
                                                         ; между центрами при ball=40 → 5 px gap
                                                         ; (= touching, как в оригинале Zuma).
VDC_MAX_SLOTS          EQU 240
VDC_GAP_STOP           EQU #FE
VDC_GAP_CASCADE        EQU #FD
VDC_NUM_COLORS         EQU 6                             ; 6 colors (atlas already supports 6×32 cells). Pre 2026-05-18: 4.
VDC_LEVEL_CHAIN_CHANCE EQU 50                            ; level setting: 50% random single, 50% random same-color chain
VDC_GAP_STEP_FRAMES    EQU VDC_CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX EQU (VDC_CELL_SIZE / 2) + 2        ; allow fresh insert half-cell overlap, still block full gap
VDC_BALLS_TARGET       EQU VDC_MAX_SLOTS                 ; legacy/debug only. Runtime spawn gate is
                                                          ; VDC_GaugeFull (level target score) + GameOver.
VDC_KZ_FRAMES          EQU 12
VDC_EXPLOSION_FRAMES   EQU 15

; VDC_GameState values
VDC_STATE_PLAY     EQU 0                                  ; обычный gameplay
VDC_STATE_ABSORB   EQU 1                                  ; balls движутся в killzone
VDC_STATE_GAMEOVER EQU 2                                  ; GAME OVER screen
VDC_STATE_INTRO    EQU 3                                  ; level intro (LEVEL 1-1 + dispname)
VDC_STATE_PREVIEW  EQU 4                                  ; sparkle wave вдоль track перед спавном
VDC_STATE_CLOSING  EQU 5                                  ; череп закрывается (frame 11→1)
VDC_STATE_WIN      EQU 6                                  ; level clear: sparkles, bonus, next level
VDC_INTRO_TICKS    EQU 240                                ; ~4 сек @ 60Hz
; VDC_DialogState values for the win flow (после win-анимации):
DLG_WIN_DONE       EQU 5                                  ; «LEVEL DONE» диалог, ждём OK
DLG_WIN_FADE       EQU 6                                  ; OK нажат → fade-out в чёрное, потом AdvanceToNextLevel
VDC_WIN_FADE_STEP  EQU 16                                 ; FadeAlpha += step/кадр (255/16 ≈ 16 кадров ≈ 0.2с)
VDC_PREVIEW_TICKS  EQU 193                                ; (NumSamples+trail)/SPEED = (2774+112)/15 ≈ 192.4 → закрытие сразу после влёта последней звезды
VDC_CLOSING_TICKS  EQU 22                                 ; ~0.37 сек closing anim (2 ticks per frame)
VDC_WIN_TICKS      EQU VDC_PREVIEW_TICKS                  ; sparkle pass, then load next level

; ============================================================================
; VDC_Init — обнулить state, Slots[] = GAP_STOP. Должен быть вызван 1 раз
; до любого VDC_Update / VDC_SlotPos / VDC_InsertAt.
; ============================================================================
VDC_Init:
                ; C-рефактор: указатели массивов -> цепочка 1 ДО любого доступа
                ; (clear/clone ниже идут через (VDC_pXxx) — должны указывать на блок
                ; цепочки 1). SecondActive=0.
                XOR  A
                LD   (VDC_SecondActive), A
                CALL VDC_SelectChain1
                ; Слоты: 240 байт = GAP_STOP
                LD   HL, (VDC_pSlots)
                LD   DE, VDC_Slots + 1
                LD   BC, VDC_MAX_SLOTS - 1
                LD   (HL), VDC_GAP_STOP
                LDIR

                ; Offsets, Shot2, ExplodeFrame, ExplodeMarker — все 0
                LD   HL, (VDC_pOffsets)
                LD   DE, VDC_Offsets + 1
                LD   BC, (VDC_MAX_SLOTS * 4) - 1
                LD   (HL), 0
                LDIR

                ; Скаляры — нулим простым LD
                XOR  A
                LD   (VDC_HSA),                A
                LD   (VDC_HSub),               A
                LD   (VDC_SlotsLen),           A
                LD   (VDC_ChainFreezeCnt),     A
                LD   (VDC_GapStepCnt),         A
                LD   (VDC_BallsSpawned),       A
                ; Cluster RNG state: remaining=0 принудит первый roll на старте.
                ; Color sentinel #FF — пока remaining=0, color не используется.
                LD   (VDC_SpawnClusterRem),    A
                LD   A, #FF
                LD   (VDC_SpawnClusterColor),  A
                XOR  A
                LD   (VDC_MatchScanIdx),       A
                LD   (VDC_ScanGapBusy),        A
                LD   (VDC_BridgeScanActive),   A
                LD   (VDC_DetectIgnoreOffsets), A
                LD   (VDC_RequireGapBridge),   A
                LD   (VDC_GameOverTick),       A
                LD   (VDC_HudMenuState),       A
                LD   (VDC_HudPointerBlock),    A
                ; Gauge bar reset (BUG fix 2026-05-26): без этого GaugeScore/Full
                ; тащились с прошлого уровня через Win→AdvanceToNextLevel→VDC_Init,
                ; и новый уровень стартовал с полным баром → спавн сразу отсекался.
                LD   (VDC_GaugeFull),          A      ; A=0
                LD   (VDC_GaugeScore),         A
                LD   (VDC_GaugeScore + 1),     A
                LD   (VDC_GaugeShown),         A
                LD   (VDC_GaugeShown + 1),     A
                LD   (VDC_AssertCode),         A
                LD   (VDC_AssertCtx),          A
                LD   (VDC_AssertLen),          A
                LD   (VDC_AssertHSA),          A
                LD   (VDC_AssertValue),        A
                LD   (VDC_AssertFrame),        A
                LD   (VDC_AssertFrame + 1),    A
                LD   (VDC_RollingActive),      A
                LD   (VDC_SfxStopTimer),       A
                ; Per-level/difficulty ball-color count from the settings table
                ; (поле colors +4). Раньше цвет всегда катился 0..5 (фикс. NUM=6) —
                ; ранние уровни должны иметь 4. CurrentLevel/Difficulty уже выставлены.
                CALL VDC_LoadLevelSettings            ; per-level colors/speed/start + accum reset (Core)
                LD   A, 11                            ; KzFrame=11 (skull mouth wide open) during intro/preview
                LD   (VDC_KzFrame),            A
                ; --- Intro state (3) → Preview (4) → Closing (5) → Play (0) ---
                ; INTRO: LEVEL 1-1 + SPIRAL OF DOOM с fade-out
                ; PREVIEW: sparkle wave вдоль track, череп OPEN
                ; PLAY: транзишн КзFrame=1 (closed), шары спавнятся
                LD   A, VDC_STATE_INTRO
                LD   (VDC_GameState),          A
                LD   A, VDC_INTRO_TICKS
                LD   (VDC_IntroTick),          A
                ; Reset stats для нового запуска уровня
                XOR  A
                LD   (VDC_StatCombos),         A
                LD   (VDC_StatMaxCombo),       A
                LD   (VDC_StatMaxChain),       A
                LD   (VDC_StatChainCount),     A
                LD   (VDC_StatCoins),          A
                LD   (VDC_GaugeFull),          A
                LD   (VDC_BulletGapCount),     A
                LD   A, 255
                LD   (VDC_BulletGapMinDist),   A
                XOR  A
                LD   A, #FF
                LD   (VDC_StatPrevMatchColor), A
                LD   HL, 0
                LD   (VDC_StatTimeFrames),     HL
                LD   (VDC_GaugeScore),         HL
                LD   (VDC_GaugeShown),         HL
                ; VDC_PlayerScore НЕ сбрасываем здесь — счёт adventure накопительный,
                ; переносится между уровнями (Win→next). Обнуление только на старте
                ; прогона (FadeLevelSelectToGameplay) и full-restart (RestartLevel lives=0).
                LD   (VDC_GameSeconds),        HL
                CALL ReadRTCSeconds
                LD   (VDC_RtcLastSecond),      A
                XOR  A
                LD   (VDC_RtcNoTickFrames),    A

                ; Запомнить TRACK_NUM_SLOTS (= NumSamples / CELL_SIZE - 1) —
                ; используется как cap для HSA. NumSamples лежит в TrackData word.
                LD   HL, (TrackData)                  ; HL = NumSamples
                LD   A, VDC_CELL_SIZE                 ; A = divisor (BUG fix 2026-05-14:
                                                       ; раньше отсутствовал и был лишний `ADD HL,HL`
                                                       ; → деление на 0 → TrackNumSlots = #FFFE).
                CALL VDC_DivHLbyA                     ; HL = NumSamples / CELL_SIZE
                LD   (VDC_TrackNumSlots), HL
                OR   A
                JR   NZ, .kz_rem_ok
                LD   A, VDC_CELL_SIZE
.kz_rem_ok:     DEC  A
                LD   (VDC_KzEndSub), A

                ; LFSR seed: базовый #ACE1, scramble через RTC секунды (low_byte ×
                ; RTC_sec) — каждый запуск получает разную starting sequence, как
                ; у коллеги в TS-Conf версии (RandomChainColor scramble).
                LD   HL, #ACE1
                LD   (VDC_LfsrSeed), HL
                CALL ReadRTCSeconds                    ; A = 0..59
                OR   A
                JR   NZ, .seed_have_sec
                LD   A, 17                             ; защита если RTC = 0
.seed_have_sec:
                LD   D, A : LD E, A                    ; DE = RTC sec (multiplier)
                LD   HL, (VDC_LfsrSeed)
                LD   A, L                              ; A = low seed byte
                LD   HL, 0
                LD   B, 8
.seed_mul:
                ADD  HL, HL
                SLA  A
                JR   NC, .seed_no_add
                ADD  HL, DE
.seed_no_add:
                DJNZ .seed_mul
                ; HL = low_seed * RTC_sec. Гарантируем non-zero.
                LD   A, H : OR L
                JR   NZ, .seed_ok
                LD   HL, #1234
.seed_ok:
                ; XOR в seed FrameCounter (restart entropy) + R register
                ; (COLD BOOT entropy: async с HALT/interrupt edge — между
                ; запусками R при VDC_Init ~всегда разный).
                LD   A, (ZL_FrameCounter)
                XOR  L
                LD   L, A
                LD   A, (ZL_FrameCounter+1)
                XOR  H
                LD   H, A
                LD   A, R                              ; 7-bit refresh counter
                XOR  L
                LD   L, A
                LD   (VDC_LfsrSeed), HL
                ; --- DEBUG snapshot (для F12-dump диагностики) ---
                ; #5008..#500E: RAW значения трёх entropy-источников.
                CALL ReadRTCSeconds
                LD   (#5008), A                        ; #5008 = raw RTC sec
                LD   A, R
                LD   (#5009), A                        ; #5009 = R register
                LD   HL, (ZL_FrameCounter)
                LD   (#500A), HL                       ; #500A-B = FrameCounter
                LD   HL, (VDC_LfsrSeed)
                LD   (#500C), HL                       ; #500C-D = final seed
                ; Phase advance: прокрутить LFSR ((RTC_sec+1) * 16) шагов.
                ; У близких RTC-секунд после короткого scramble стартовые
                ; sequences оказывались похожи (color 0/blue появлялся редко
                ; в первые 60 спавнов для некоторых секунд). Advance растягивает
                ; разные секунды в разные фазы 65535-шаговой LFSR.
                CALL ReadRTCSeconds                    ; A = 0..59
                INC  A                                 ; A = 1..60 (никогда 0)
                LD   B, A                              ; B = outer counter
.seed_advance_outer:
                LD   C, 16                             ; 16 inner steps per outer
.seed_advance_inner:
                LD   HL, (VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   NC, .sa_no_xor
                LD   A, H : XOR #B4 : LD H, A
.sa_no_xor:     LD   (VDC_LfsrSeed), HL
                DEC  C
                JR   NZ, .seed_advance_inner
                DJNZ .seed_advance_outer
                JP   VDC_InitSecondChainMaybe

VDC_InitSecondChainMaybe:
                XOR  A
                LD   (VDC_HasSecondChain), A
                LD   A, (CurrentLevel)
                CP   4                                ; L05 blackswirley
                JR   Z, .has2
                CP   11                               ; L12 snakepit
                JR   Z, .has2
                CP   18                               ; L19 serpents
                RET  NZ
.has2:          LD   A, 1
                LD   (VDC_HasSecondChain), A

                ; Двухцепочечные уровни: lead-in (сколько шаров выезжает на БЫСТРОЙ
                ; фазе, из настроек уровня) делим на 2 — на каждую цепочку. Раньше тут
                ; стоял full fast-fill (LevelStart = TrackNumSlots), из-за чего ВСЯ
                ; цепочка уезжала на fast-фазе прямо в килл-зону. min 1, чтобы
                ; fast-фаза не выродилась в ноль.
                LD   A, (VDC_LevelStart)               ; lead-in из настроек уровня
                SRL  A                                 ; /2
                OR   A
                JR   NZ, .ls_ok
                INC  A
.ls_ok:         LD   (VDC_LevelStart), A

                ; Clone the freshly reset chain state into the second backing
                ; store, then replace only TrackNumSlots from track page #0F.
                LD   HL, (VDC_pSlots)
                LD   DE, VDC2_Slots
                LD   BC, VDC_MAX_SLOTS * 5
                LDIR
                LD   A, (VDC_HSub)
                LD   (VDC2_HSub), A
                LD   A, (VDC_SlotsLen)
                LD   (VDC2_SlotsLen), A
                LD   A, (VDC_KzFrame)
                LD   (VDC2_KzFrame), A
                LD   HL, VDC_ChainLocalStart
                LD   DE, VDC2_ChainLocal
                LD   BC, VDC_ChainLocalEnd - VDC_ChainLocalStart
                LDIR

                CALL SetSecondTrackPage
                LD   HL, (TrackData)
                LD   A, VDC_CELL_SIZE
                CALL VDC_DivHLbyA
                LD   DE, VDC2_ChainLocal + (VDC_TrackNumSlots - VDC_ChainLocalStart)
                LD   A, L
                LD   (DE), A
                INC  DE
                LD   A, H
                LD   (DE), A
                ; LevelStart цепочки 2 НЕ перетираем длиной её трека — она уже
                ; унаследовала делённый-на-2 lead-in из клона ChainLocal выше.
                LD   HL, (TrackData)
                DEC  HL
                CALL VDC_ReadSampleAtHL               ; BC=X, DE=Y on second track
                PUSH DE
                LD   H, B : LD L, C
                LD   DE, KZ_SPR_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   (VDC2_KzDrawX16), HL
                POP  HL
                LD   DE, KZ_SPR_HALF
                AND  A
                SBC  HL, DE
                ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                LD   (VDC2_KzDrawY16), HL

                ; (C-рефактор: своп цепочек теперь через 5 указателей VDC_pXxx,
                ; копирования массивов нет — прежний расчёт размера частичного свопа
                ; VDC_ChainSwapN удалён как мёртвый код.)
                JP   SetCurrentTrackPage

VDC_SwapChains:
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                ; C-рефактор: вместо копирования ~1200 байт массивов — переключаем 5
                ; указателей на блок другой цепочки (см. VDC_pSlots..). Скаляры дёшево
                ; свопаем как раньше. Вызывается парами (вход в цепочку 2 / выход).
                LD   A, (VDC_SecondActive)
                XOR  1
                LD   (VDC_SecondActive), A
                OR   A
                JR   NZ, .toChain2
                CALL VDC_SelectChain1
                JR   .scalars
.toChain2:      CALL VDC_SelectChain2
.scalars:
                LD   HL, VDC_HSub
                LD   DE, VDC2_HSub
                CALL VDC_SwapByte
                LD   HL, VDC_SlotsLen
                LD   DE, VDC2_SlotsLen
                CALL VDC_SwapByte
                LD   HL, VDC_KzFrame
                LD   DE, VDC2_KzFrame
                CALL VDC_SwapByte

                LD   HL, VDC_ChainLocalStart
                LD   DE, VDC2_ChainLocal
                LD   BC, VDC_ChainLocalEnd - VDC_ChainLocalStart
                JP   VDC_SwapBlock

VDC_SwapBlock:
                LD   A, B
                OR   C
                RET  Z
                LD   (VDC_SwapPtr1), HL
                LD   (VDC_SwapPtr2), DE
                LD   (VDC_SwapLen), BC

                LD   DE, VDC_SwapBuf
                LDIR

                LD   HL, (VDC_SwapPtr2)
                LD   DE, (VDC_SwapPtr1)
                LD   BC, (VDC_SwapLen)
                LDIR

                LD   HL, VDC_SwapBuf
                LD   DE, (VDC_SwapPtr2)
                LD   BC, (VDC_SwapLen)
                LDIR
                RET

VDC_SwapByte:
                LD   A, (HL)
                LD   (VDC_SwapTmp), A
                LD   A, (DE)
                LD   (HL), A
                LD   A, (VDC_SwapTmp)
                LD   (DE), A
                RET

; Указатели массивов активной цепочки -> блок цепочки 1 / цепочки 2.
; C-рефактор: смена цепочки без копирования (весь код массивов читает (VDC_pXxx)).
VDC_SelectChain1:
                LD   HL, VDC_Slots         : LD (VDC_pSlots), HL
                LD   HL, VDC_Offsets       : LD (VDC_pOffsets), HL
                LD   HL, VDC_Shot2         : LD (VDC_pShot2), HL
                LD   HL, VDC_ExplodeFrame  : LD (VDC_pExplodeFrame), HL
                LD   HL, VDC_ExplodeMarker : LD (VDC_pExplodeMarker), HL
                RET
VDC_SelectChain2:
                LD   HL, VDC2_Slots        : LD (VDC_pSlots), HL
                LD   HL, VDC2_Offsets      : LD (VDC_pOffsets), HL
                LD   HL, VDC2_Shot2        : LD (VDC_pShot2), HL
                LD   HL, VDC2_ExplodeFrame : LD (VDC_pExplodeFrame), HL
                LD   HL, VDC2_ExplodeMarker: LD (VDC_pExplodeMarker), HL
                RET


; ============================================================================
; ReadRTCSeconds — TS-Conf GLUK CMOS RTC, регистр 0 (секунды BCD).
; Порты #DFF7 (адрес) / #BFF7 (данные). Out: A = 0..59 binary.
; ============================================================================
ReadRTCSeconds:
                ; Mr.Gluk activation на порт #EFF7 (за ZiFi/WC: zifi.asm:4207).
                ; OUT #EFF7, #80 — enable; #00 — disable.
                LD   BC, #EFF7
                LD   A, #80
                OUT  (C), A
                LD   BC, #DFF7
                XOR  A
                OUT  (C), A                            ; reg 0 = seconds
                LD   BC, #BFF7
                IN   A, (C)                            ; A = BCD seconds
                LD   (#500E), A                        ; DEBUG: raw byte
                PUSH AF
                LD   BC, #EFF7
                XOR  A
                OUT  (C), A                            ; deactivate Mr.Gluk
                POP  AF
                LD   B, A
                AND  $0F                               ; low nibble
                LD   C, A
                LD   A, B
                AND  $F0
                SRL  A : SRL A : SRL A : SRL A         ; high nibble (0..5)
                LD   B, A
                ; A = high*10 + low
                ADD  A, A : ADD A, A : ADD A, B        ; *5
                ADD  A, A                              ; *10
                ADD  A, C
                RET

; ============================================================================
; ReadRTCRegister — generic, A = register index (0=sec, 2=min, 4=hour).
; Out: A = BCD-parsed binary value.
; ============================================================================
ReadRTCRegister:
                LD   E, A                              ; E = reg index
                LD   BC, #EFF7
                LD   A, #80
                OUT  (C), A                            ; activate Mr.Gluk
                LD   BC, #DFF7
                LD   A, E
                OUT  (C), A                            ; select register
                LD   BC, #BFF7
                IN   A, (C)                            ; read BCD
                PUSH AF
                LD   BC, #EFF7
                XOR  A
                OUT  (C), A                            ; deactivate
                POP  AF
                LD   B, A
                AND  $0F
                LD   C, A
                LD   A, B
                AND  $F0
                SRL  A : SRL A : SRL A : SRL A
                LD   B, A
                ADD  A, A : ADD A, A : ADD A, B        ; *5
                ADD  A, A                              ; *10
                ADD  A, C
                RET

; ============================================================================
; VDC_Update — один шаг физики (вызывать раз в кадр).
; Phase 1 (BallsSpawned < LEVEL_START_BALLS): 12× MoveChain + 1× AnimateChain +
;   1× TrySpawn (TrySpawn внутри loop'ит). Это «поезд» влёта 35 шаров за ~90 тиков.
; Phase 2 (BallsSpawned ≥ LEVEL_START_BALLS): 1× MoveChain каждый кадр (norm-speed
;   подобран под VDAC2 CELL_SIZE=42 — без subdivider /2 как у коллеги).
; ============================================================================
VDC_Update:
                CALL VDC_UpdateSfxStopTimer
                LD   A, (VDC_DialogState)
                CP   3
                JR   C, .upd_not_pause       ; <3 (none/retry/gameover) → normal path
                ; >=3: pause (3) or pause fade-out (4) — freeze gameplay, refresh
                ; the RTC baseline so the paused/fading seconds are not counted.
                CALL ReadRTCSeconds
                LD   (VDC_RtcLastSecond), A
                XOR  A
                LD   (VDC_RtcNoTickFrames), A
                RET
.upd_not_pause:
                LD   A, (VDC_GameState)
                CP   VDC_STATE_INTRO
                JR   Z, .upd_intro
                CP   VDC_STATE_PREVIEW
                JR   Z, .upd_preview
                CP   VDC_STATE_CLOSING
                JR   Z, .upd_closing
                CP   VDC_STATE_ABSORB
                JP   Z, VDC_UpdateAbsorb
                CP   VDC_STATE_GAMEOVER
                RET  Z
                CP   VDC_STATE_WIN
                JP   Z, VDC_UpdateWin
                JR   .upd_play
.upd_intro:     ; tick countdown, на 0 → PREVIEW
                LD   A, (VDC_IntroTick)
                DEC  A
                LD   (VDC_IntroTick), A
                RET  NZ
                LD   A, SND_CHANT1
                CALL GS_PlaySfx
                LD   A, VDC_STATE_PREVIEW
                LD   (VDC_GameState), A
                LD   A, VDC_PREVIEW_TICKS
                LD   (VDC_PreviewTick), A
                RET
.upd_preview:   ; tick countdown, на 0 → CLOSING
                LD   A, (VDC_PreviewTick)
                DEC  A
                LD   (VDC_PreviewTick), A
                RET  NZ
                LD   A, VDC_STATE_CLOSING
                LD   (VDC_GameState), A
                LD   A, VDC_CLOSING_TICKS
                LD   (VDC_KzCloseTick), A
                RET
.upd_closing:   ; анимация KzFrame 11→1 за 22 ticks (2 tick/frame), затем PLAY.
                LD   A, (VDC_KzCloseTick)
                SRL  A                                ; A = tick / 2 (0..11)
                INC  A                                ; A = 1 + tick/2 (1..12)
                CP   12
                JR   C, .upd_closing_set
                LD   A, 11
.upd_closing_set:
                LD   (VDC_KzFrame), A
                LD   A, (VDC_KzCloseTick)
                DEC  A
                LD   (VDC_KzCloseTick), A
                RET  NZ
                XOR  A                                ; state = PLAY
                LD   (VDC_GameState), A
                INC  A                                ; KzFrame = 1 (closed default)
                LD   (VDC_KzFrame), A
                CALL ReadRTCSeconds
                LD   (VDC_RtcLastSecond), A
                LD   HL, 0
                LD   (VDC_GameSeconds), HL
                XOR  A
                LD   (VDC_RtcNoTickFrames), A
                LD   A, SND_ROLLING
                CALL GS_PlaySfx
                LD   A, 1
                LD   (VDC_RollingActive), A
                RET
.upd_play:
                CALL VDC_UpdateRtcElapsed
                ; Tick game-time counter (frames). Используется для TIME M:SS в dialog.
                LD   HL, (VDC_StatTimeFrames)
                INC  HL
                LD   (VDC_StatTimeFrames), HL
                CALL VDC_CheckKillzone
                LD   A, (VDC_BallsSpawned)
                LD   HL, VDC_LevelStart                 ; per-level lead-in count
                CP   (HL)
                JR   NC, .upd_normal
                ; Fast phase: ×12 MoveChain (35 шаров «поездом»).
                ; В fast phase spawn без hsub-gate — иначе при wrap-частоте
                ; CELL_SIZE/12 ≈ 3 ticks spawn'ы редки → fast phase ломается.
                LD   B, VDC_FAST_ADVANCE
.upd_fast:      PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd_fast
                CALL VDC_AnimateChain
                CALL VDC_TrySpawn_NoHsubGate
                RET
.upd_normal:    LD   A, (VDC_RollingActive)
                OR   A
                JR   Z, .upd_normal_go
                XOR  A
                LD   (VDC_RollingActive), A
                LD   A, SND_SILENCE
                CALL GS_PlaySfx
.upd_normal_go: ; Normal phase: per-level chain speed via Core helper (accum +=
                ; speed_x100; ≥100 → один MoveChain = speed/100 продвижений/кадр).
                ; Вынесено в Core — Main1/slot3 почти полон. VDC_TrySpawn gate'ится HSub==0.
                CALL VDC_SpeedAdvance
                CALL VDC_AnimateChain
                CALL VDC_TrySpawn
                RET

VDC_UpdateAllChains:
                CALL VDC_Update
                LD   A, (VDC_HasSecondChain)
                OR   A
                JP   Z, VDC_CheckWinMaybe
                LD   A, (VDC_DialogState)
                CP   3
                RET  NC                                ; pause / pause-fade freeze both chains
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ                                ; second chain advances only in PLAY
                CALL VDC_SwapChains
                CALL SetSecondTrackPage
                CALL VDC_UpdateActiveChainPlayOnly
                CALL VDC_SwapChains
                CALL SetCurrentTrackPage
                JP   VDC_CheckWinMaybe

VDC_UpdateActiveChainPlayOnly:
                CALL VDC_CheckKillzone
                LD   A, (VDC_BallsSpawned)
                LD   HL, VDC_LevelStart
                CP   (HL)
                JR   NC, .upd2_normal
                LD   B, VDC_FAST_ADVANCE
.upd2_fast:     PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd2_fast
                CALL VDC_AnimateChain
                CALL VDC_TrySpawn_NoHsubGate
                RET
.upd2_normal:   CALL VDC_SpeedAdvance
                CALL VDC_AnimateChain
                CALL VDC_TrySpawn
                RET

VDC_UpdateSfxStopTimer:
                LD   A, (VDC_SfxStopTimer)
                OR   A
                RET  Z
                DEC  A
                LD   (VDC_SfxStopTimer), A
                RET  NZ
                LD   A, SND_SILENCE
                JP   GS_PlaySfx

; ============================================================================
; VDC_UpdateRtcElapsed — real-time game clock from RTC seconds.
;   Adds delta seconds with 0..59 wrap. Called only during PLAY; pause refreshes
;   VDC_RtcLastSecond without accumulating, so pause time is not counted.
; ============================================================================
VDC_UpdateRtcElapsed:
                ; ТОЛЬКО RTC. Если sec не поменялся — RET, ничего не добавляем.
                ; Frame-fallback убран (был для эмуляторов с мёртвым RTC, но
                ; после #EFF7 fix RTC всегда работает).
                CALL ReadRTCSeconds                    ; A = current 0..59
                LD   B, A                              ; B = current
                LD   A, (VDC_RtcLastSecond)            ; A = old
                CP   B
                RET  Z                                 ; не поменялось → выходим
                LD   C, A                              ; C = old
                LD   A, B                              ; A = current
                CP   C
                JR   NC, .rte_no_wrap
                ADD  A, 60                             ; wrap 59→0
.rte_no_wrap:   SUB  C                                 ; A = delta 1..59
                LD   E, A : LD D, 0
                LD   HL, (VDC_GameSeconds)
                ADD  HL, DE
                LD   (VDC_GameSeconds), HL
                LD   A, B
                LD   (VDC_RtcLastSecond), A
                RET

; ============================================================================
; VDC_SlotT — для A=i считает t = (HSA-i)*64 + HSub + sext(offsets[i]).
; Out: HL = signed 16-bit t.  AF/DE clobber.
; ============================================================================
VDC_SlotT:
                LD   C, A                             ; C = i
                LD   A, (VDC_HSA)
                SUB  C
                JR   NC, .delta_ok
                ; i > HSA — слот логически до начала цепи. В рабочей Zuma
                ; (BcsPreClassify) это PRESERVE/skip. Возвращаем signed-negative HL
                ; чтобы VDC_SlotPos через `BIT 7, H` сделал SCF/RET (skip render +
                ; skip bullet collision). Раньше тут был `XOR A` → clamp 0 →
                ; шар рисовался у спавна и зацеплялся коллизией («застрявший шар»
                ; после match-3/cascade с HsaDec). Codex 2026-05-14 diagnose, Claude fix.
                LD   HL, #8000
                RET
.delta_ok:
                LD   H, 0 : LD L, A                    ; HL = delta
                ; VDC_CELL_SIZE=32: avoid generic ZL_Mul16x8 in the hot
                ; VDC_SlotPos path. This is hit once per rendered/collided ball.
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL                            ; HL = delta * VDC_CELL_SIZE

                ; + HSub (0..63 unsigned)
                LD   A, (VDC_HSub)
                LD   E, A
                LD   D, 0
                ADD  HL, DE

                ; + sext(offsets[i])
                LD   A, C
                PUSH HL
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .off_pos
                DEC  D                                ; sign-extend
.off_pos:
                POP  HL
                ADD  HL, DE
                RET

; ============================================================================
; VDC_SlotPos — для A=i возвращает центр шара (X,Y) из TrackData[t].
;   Out: BC = X (signed word), DE = Y (signed word), CF = 0 если рисуем,
;        CF = 1 если skip (gap или t<0).
;   AF, HL clobber.
;
; VDC_SlotPosAllowGap — тот же расчёт но БЕЗ gap-skip. Используется для
; gap-bonus tracking (нужна позиция самой gap-ячейки чтобы померить distance
; bullet'а до пустоты в цепи).
; ============================================================================
VDC_SlotPos:
                ; --- skip if gap ---
                LD   C, A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .not_gap
                SCF                                    ; CF=1, skip
                RET
.not_gap:
                LD   A, C
VDC_SlotPosAllowGap:
                ; entry без gap-skip. Caller обязан передать A=i.
                CALL VDC_SlotT                         ; HL = t
                ; t < 0 → skip
                BIT  7, H
                JR   Z, .t_nonneg
                SCF
                RET
.t_nonneg:
                ; t >= NumSamples → clamp to NumSamples-1
                PUSH HL
                LD   DE, (TrackData)                   ; NumSamples
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .t_in
                LD   HL, (TrackData)
                DEC  HL
.t_in:          ; HL = t (clamped). Read the sample via a Core-resident helper
                ; (2-page track split lives there) so this hot path stays tiny —
                ; Main1/slot3 is nearly full. Core is always mapped in slot 1, so
                ; the tail-call resolves at runtime. Helper: out BC=X, DE=Y, CF=0,
                ; sets VDC_LastT / VDC_LastTangent.
                JP   VDC_ReadSampleAtHL

; ============================================================================
; VDC_TrySpawn — спавн нового шара в хвост (если разрешено).
;   Условия: SlotsLen<MAX, BallsSpawned<TARGET, HSA>=SlotsLen, HSub==0.
; ============================================================================
VDC_TrySpawn:
                ; Public entry: с HSub==0 gate (sync с Python try_spawn).
                ; Fast phase обходит gate через VDC_TrySpawn_NoHsubGate.
                LD   A, (VDC_HSub)
                OR   A
                RET  NZ
                ; fallthrough
VDC_TrySpawn_NoHsubGate:
                ; Zuma bar full → spawn gate OFF (per wiki/manual).
                ; Хвост перестаёт прирастать, остаётся доедать уже спавненные шары.
                LD   A, (VDC_GaugeFull)
                OR   A
                RET  NZ
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; HSA < SlotsLen → не спавним (хвост не достиг старта)
                LD   A, (VDC_SlotsLen)
                LD   B, A                              ; B = SlotsLen
                LD   A, (VDC_HSA)
                CP   B
                RET  C

                ; SlotsLen > 0 AND offsets[tail-1] != 0 → не спавним (хвост ещё двигается).
                LD   A, B
                OR   A
                JR   Z, .spawn_no_tail_check
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ
.spawn_no_tail_check:
                ; --- Level RNG:
                ; RTC seconds seed only at VDC_Init. Runtime uses deterministic LFSR.
                ; Per level setting: 50% single random color OR 50% same-color
                ; chain of random color and random length 1..VDC_NUM_COLORS-1.
                LD   A, (VDC_SpawnClusterRem)
                OR   A
                JR   Z, .spawn_roll_new
                DEC  A
                LD   (VDC_SpawnClusterRem), A
                LD   A, (VDC_SpawnClusterColor)
                LD   B, A
                JR   .spawn_color_ready
.spawn_roll_new:
                CALL VDC_RandomColor                   ; A = gate roll 0..NUM-1
                BIT  0, A                              ; odd/even ≈ 50/50 for NUM=6
                JR   Z, .spawn_single_random           ; 50% single random ball
                ; cluster path — reroll color until != предыдущий cluster.
                ; (VDC_SpawnClusterColor) = previous color (or sentinel #FF на init).
.cluster_color_reroll:
                CALL VDC_RandomColor                   ; chain color candidate
                LD   HL, VDC_SpawnClusterColor
                CP   (HL)                              ; == previous?
                JR   Z, .cluster_color_reroll          ; → reroll
                LD   (HL), A                           ; commit color
                CALL VDC_RandomClusterLength           ; A = total length 1..NUM-1
                                                       ; (NB: ZL_Mul16x8 clobs B/C —
                                                       ; читаем color из памяти ниже)
                DEC  A                                 ; current spawn is first ball
                LD   (VDC_SpawnClusterRem), A
                JR   .spawn_color_ready
.spawn_single_random:
                ; single path — тоже reroll, чтобы два соседних кластера/single
                ; никогда не были одного цвета.
.single_color_reroll:
                CALL VDC_RandomColor
                LD   HL, VDC_SpawnClusterColor
                CP   (HL)
                JR   Z, .single_color_reroll
                LD   (HL), A                           ; commit color
                XOR  A
                LD   (VDC_SpawnClusterRem), A
.spawn_color_ready:
                LD   A, (VDC_SpawnClusterColor)        ; re-read color from memory
                                                       ; (B клобан RandomColor/Mul16x8)
                LD   B, A
                ; B = chosen color. Не режем 3+ одинаковых на spawn: в оригинальной
                ; Zuma цепь может иметь длинные серии, а match запускается только
                ; от выстрела или физического закрытия gap через Shot2/cascade.
                LD   A, B
                LD   (VDC_SpawnClusterColor), A
                ; --- Slots[SlotsLen] = candidate ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   (HL), B

                ; --- offsets[SlotsLen] = (SlotsLen>0) ? offsets[SlotsLen-1] : 0 ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .spawn_off_zero
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   B, (HL)                           ; B = offsets[len-1]
                JR   .spawn_off_set
.spawn_off_zero:
                LD   B, 0
.spawn_off_set:
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   (HL), B

                ; --- Shot2[SlotsLen] = 0 ---
                ; Не ставим Shot2 на spawn — иначе cluster RNG с 50% repeat создаёт
                ; 3+ same color и моментально auto-match'ит → chain не растёт.
                ; В оригинальной Zuma spawn НЕ триггерит match — match только на
                ; player insert или DoGapStep adjacency.
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   (HL), 0

                ; --- SlotsLen++, BallsSpawned++ ---
                LD   HL, VDC_SlotsLen
                INC  (HL)
                LD   HL, VDC_BallsSpawned
                INC  (HL)
                JR   NZ, .spawn_dbg_count
                DEC  (HL)                              ; saturate at 255; never wrap into fast phase
.spawn_dbg_count:
                LD   HL, VDC_DbgSpawnCnt               ; debug 2026-05-16: source-of-truth source
                INC  (HL)
                RET                                    ; single-shot per tick (= Python коллеги).
                                                       ; Множественный spawn даёт instant chain growth = дёрганость.

; ============================================================================
; VDC_MoveChain — HSub++ если chain не frozen; wrap → HSA++.
; ============================================================================
VDC_MoveChain:
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                JR   Z, .mc_no_freeze
                DEC  A
                LD   (VDC_ChainFreezeCnt), A
                RET
.mc_no_freeze:
                LD   A, (VDC_HSub)
                INC  A
                CP   VDC_CELL_SIZE
                JR   C, .mc_save_sub
                XOR  A
                LD   (VDC_HSub), A
                ; HSA++ с cap по TrackNumSlots-1
                LD   HL, (VDC_TrackNumSlots)           ; max
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   Z, .mc_at_max                     ; HSA == max → stop
                JR   C, .mc_at_max
                LD   HL, VDC_HSA
                INC  (HL)
.mc_at_max:
                RET
.mc_save_sub:
                LD   (VDC_HSub), A
                RET

; ============================================================================
; VDC_AnimateChain — decay offsets к 0 ±1, gap_step_counter, при wrap → DoGapStep.
; После — ScanForNewMatch + UpdateStall.
; ============================================================================
VDC_AnimateChain:
                ; --- 0. Match-3 explosion animation.
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ac_after_explode
                LD   B, A
                LD   HL, (VDC_pExplodeFrame)
.ac_explode:
                LD   A, (HL)
                OR   A
                JR   Z, .ac_explode_next
                INC  A
                CP   VDC_EXPLOSION_FRAMES + 1
                JR   C, .ac_explode_save
                XOR  A
                LD   (HL), A
                PUSH HL
                PUSH BC
                LD   A, (VDC_SlotsLen)
                SUB  B
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   C, (HL)
                LD   A, (VDC_SlotsLen)
                SUB  B
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   (HL), C
                POP  BC
                POP  HL
                JR   .ac_explode_next
.ac_explode_save:
                LD   (HL), A
.ac_explode_next:
                INC  HL
                DJNZ .ac_explode
.ac_after_explode:
                ; --- 1. decay offsets (rollback_counter не реализован — нет
                ; кода который бы его выставлял; декай идёт сразу к 0).
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ac_after_decay
                LD   B, A
                LD   HL, (VDC_pOffsets)
.ac_decay:
                LD   A, (HL)
                OR   A
                JR   Z, .ac_decay_skip
                BIT  7, A
                JR   NZ, .ac_decay_neg
                SUB  VDC_DECAY_POS                     ; pos (cascade rollback) → 0 плавно
                JR   NC, .ac_decay_store
                XOR  A                                 ; clamp 0
                JR   .ac_decay_store
.ac_decay_neg:  ADD  A, VDC_DECAY_NEG                  ; neg (insert head slide) → 0 быстро
                JR   Z, .ac_decay_store
                BIT  7, A
                JR   NZ, .ac_decay_store               ; ещё отрицательный
                XOR  A                                 ; overshoot → 0
.ac_decay_store:
                LD   (HL), A
.ac_decay_skip:
                INC  HL
                DJNZ .ac_decay
.ac_after_decay:
                ; --- 2. GapStepCnt++; при cnt>=GAP_STEP_FRAMES → DoGapStep (без
                ; hsub==0 constraint, иначе зазор между decay-end и next gap_step
                ; → head moves forward; см. Python emulator + чат 2026-05-12).
                LD   A, (VDC_GapStepCnt)
                INC  A
                LD   (VDC_GapStepCnt), A
                CP   VDC_GAP_STEP_FRAMES
                JR   C, .ac_no_gap_step
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
.ac_no_gap_step:
                ; --- 3. Persistent scan. ---
                CALL VDC_ScanForNewMatch
                ; --- 4. Clamp offset invariant каждый кадр (покрывает InsertAt
                ; head_comp/cap_compensate, DoGapStep STOP/CASCADE +CS shifts,
                ; и любые другие пути модификации offsets) ---
                CALL ClampOffsetOrder
                ; --- 4.5. Clear stale Shot2 если cascade chain завершён.
                ; Внутри есть guard: pending Shot2 с невыровненными offsets
                ; не чистится, чтобы свежая вставка могла стать match после decay.
                CALL VDC_ClearStaleShot2
                ; --- 5. Animate gauge bar — VDC_GaugeShown ползёт к VDC_GaugeScore
                ; ±N очков за кадр, чтобы chain/combo бонусы не выглядели прыжком ---
                CALL VDC_TickGaugeShown
                RET

; ============================================================================
; VDC_ClearAllShot2 — очистить Shot2[0..SlotsLen-1].
; Используется при успешном MATCH3: дальнейшие cascade-триггеры должны идти
; только от VDC_DoGapStep после реального закрытия gap, а не от старых меток.
; ============================================================================
VDC_ClearAllShot2:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A
                LD   HL, (VDC_pShot2)
.cas2_loop:     LD   (HL), 0
                INC  HL
                DJNZ .cas2_loop
                RET

; ============================================================================
; VDC_ClearSettledShot2 — очистить только settled Shot2.
; Pending Shot2 с ненулевыми offsets у себя или соседей оставляем: это
; легальная отложенная проверка после закрытия gap. Если стереть её новым
; match'ем, готовая тройка может выровняться и остаться без триггера.
; ============================================================================
VDC_ClearSettledShot2:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A
                LD   C, 0
                LD   HL, (VDC_pShot2)
.css2_loop:     LD   A, (HL)
                OR   A
                JR   Z, .css2_next
                PUSH HL
                PUSH BC
                LD   A, C
                CALL VDC_Shot2OffsetsBusy
                POP  BC
                POP  HL
                JR   NZ, .css2_next
                LD   (HL), 0
.css2_next:     INC  HL
                INC  C
                DJNZ .css2_loop
                RET

; ============================================================================
; VDC_ClearStaleShot2 — если cascade chain полностью завершён, очистить ALL Shot2.
; Cascade завершён ⇔ ChainFreezeCnt == 0 AND нет GAP_STOP/CASCADE markers в slots
; AND нет ExplodeFrame > 0 (никаких pending animations).
; ============================================================================
VDC_ClearStaleShot2:
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                RET  NZ                                ; freeze active → cascade в процессе
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z                                  ; empty chain
                LD   B, A                              ; iter count
                LD   HL, (VDC_pSlots)
                LD   DE, (VDC_pExplodeFrame)
.css_check:     LD   A, (HL)
                CP   VDC_NUM_COLORS                    ; >= NUM_COLORS → gap marker
                RET  NC                                ; chain has markers → cascade in progress
                LD   A, (DE)
                OR   A
                RET  NZ                                ; ExplodeFrame > 0 → animation pending
                INC  HL
                INC  DE
                DJNZ .css_check
                ; Если есть Shot2, у которого ещё не выровнялся offset у него
                ; или у соседей, это pending-проверка после вставки. Её нельзя
                ; стирать глобально: match может стать легальным после decay.
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   C, 0
                LD   HL, (VDC_pShot2)
.css_pending:   LD   A, (HL)
                OR   A
                JR   Z, .css_pending_next
                PUSH HL
                PUSH BC
                LD   A, C
                CALL VDC_Shot2OffsetsBusy
                POP  BC
                POP  HL
                RET  NZ
.css_pending_next:
                INC  HL
                INC  C
                DJNZ .css_pending
                ; Cascade complete — clear all Shot2
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   HL, (VDC_pShot2)
.css_clear:     LD   (HL), 0
                INC  HL
                DJNZ .css_clear
                RET

; In: A=index. Out: NZ если offset[index] или соседний offset ещё не 0.
VDC_Shot2OffsetsBusy:
                LD   C, A
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ
                LD   A, C
                OR   A
                JR   Z, .sob_right
                DEC  A
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ
.sob_right:     LD   A, C
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                RET  NC
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET

VDC_GAUGE_SHOWN_STEP EQU 8                              ; очков/кадр в анимации бара
VDC_TickGaugeShown:
                LD   HL, (VDC_GaugeShown)
                LD   DE, (VDC_GaugeScore)
                AND  A
                SBC  HL, DE
                RET  Z                                  ; Shown == Score → ничего
                JR   NC, .tg_decrement                  ; Shown > Score → откатить
                ; Shown < Score → +STEP, capped at Score
                LD   HL, (VDC_GaugeShown)
                LD   BC, VDC_GAUGE_SHOWN_STEP
                ADD  HL, BC
                ; clamp: if HL > Score → HL = Score
                LD   DE, (VDC_GaugeScore)
                PUSH HL
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .tg_save                        ; HL < Score → ок
                LD   HL, (VDC_GaugeScore)               ; clamp
.tg_save:       LD   (VDC_GaugeShown), HL
                RET
.tg_decrement:  ; Restart / Game Over reset: GaugeScore < GaugeShown → быстрый откат
                LD   HL, (VDC_GaugeScore)
                LD   (VDC_GaugeShown), HL
                RET

; ============================================================================
; VDC_DetectMatch3 — для idx в (TmpInsIdx) ищет run >= 3 одинаковых цветов
; вокруг idx с offset gap check'ом. Out: A=1 если матч (TmpML/TmpMR/TmpMC заполнены),
; A=0 иначе.
; ============================================================================
VDC_DetectMatch3:
                LD   A, (VDC_SlotsLen)
                OR   A
                JP   Z, .dm3_no
                LD   A, (VDC_TmpInsIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JP   NC, .dm3_no                       ; idx>=len

                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JP   NZ, .dm3_no                       ; already exploding

                ; color = Slots[idx]
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JP   NC, .dm3_no                       ; gap → не центр
                LD   (VDC_TmpMC_Color), A

                ; --- left scan ---
                LD   A, (VDC_TmpInsIdx)
                LD   B, A                              ; B = idx
.dm3_l:
                LD   A, B
                OR   A
                JR   Z, .dm3_l_done
                DEC  A                                 ; A = B-1
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .dm3_l_done
                LD   A, B
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_l_done

                LD   A, (VDC_DetectIgnoreOffsets)
                OR   A
                JR   NZ, .dm3_l_accept
                ; offset gap: -CS <= (off[B-1]-off[B]) < GAP_MAX (= [-CS..GAP_MAX-1])
                LD   A, B
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   C, A                              ; C = off[B-1]
                LD   A, B
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                SUB  C                                 ; off[B] - off[B-1]
                NEG                                    ; -> off[B-1] - off[B]
                ADD  A, VDC_CELL_SIZE                  ; +CS (shift to unsigned [0..2*CS])
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_l_done

.dm3_l_accept:
                DEC  B
                JR   .dm3_l
.dm3_l_done:
                LD   A, B
                LD   (VDC_TmpML), A

                ; --- right scan ---
                LD   A, (VDC_TmpInsIdx)
                LD   C, A                              ; C = idx
.dm3_r:
                LD   A, C
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .dm3_r_done
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .dm3_r_done
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_r_done

                LD   A, (VDC_DetectIgnoreOffsets)
                OR   A
                JR   NZ, .dm3_r_accept
                ; offset gap для right
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A                              ; B = off[C]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                SUB  B                                 ; off[C+1] - off[C]
                NEG                                    ; -> off[C] - off[C+1]
                ADD  A, VDC_CELL_SIZE
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_r_done

.dm3_r_accept:
                INC  C
                JR   .dm3_r
.dm3_r_done:
                LD   A, C
                LD   (VDC_TmpMR), A

                ; count = right - left + 1
                LD   A, (VDC_TmpML)
                LD   B, A
                LD   A, C
                SUB  B
                INC  A
                CP   3
                JR   C, .dm3_no
                LD   (VDC_TmpMCount), A
                LD   A, 1
                RET
.dm3_no:
                XOR  A
                RET

; ============================================================================
; VDC_CheckMatch3 — DetectMatch3 + если матч: GAP_STOP/GAP_CASCADE marker, Slots/Offsets,
; Shot2 на соседях, ChainStalled, GapStepCnt=GAP_STEP_FRAMES, ChainFreezeCnt=CELL_SIZE.
; Match считается по всей непрерывной группе одинакового цвета. Offsets не режут
; группу: они описывают анимацию съезда/rollback, а не границу правила match-3.
; A=1 если был матч, A=0 иначе.
; ============================================================================
VDC_CheckMatch3:
                LD   A, 1
                LD   (VDC_DetectIgnoreOffsets), A
                CALL VDC_DetectMatch3
                LD   B, A
                XOR  A
                LD   (VDC_DetectIgnoreOffsets), A
                LD   A, B
                OR   A
                JP   Z, VDC_CheckMatch3_No
                LD   A, (VDC_RequireGapBridge)
                OR   A
                JR   Z, .cm3_apply
                CALL VDC_CheckGapBridge
                OR   A
                JP   Z, VDC_CheckMatch3_No
.cm3_apply:
                JR   VDC_ApplyMatch3

VDC_CheckMatch3_Insert:
                JR   VDC_CheckMatch3

; ----------------------------------------------------------------------------
; VDC_CheckGapBridge — для cascade/Shot2 после удаления gap проверяет, что
; найденный run реально пересекает закрытую границу K-1/K.
; Если gap был только рядом с уже готовой группой, run будет целиком слева
; или справа от K, и такой match нелегален.
; Out: A=1 если TmpML <= K-1 и TmpMR >= K, иначе A=0.
; ----------------------------------------------------------------------------
VDC_CheckGapBridge:
                LD   A, (VDC_MatchScanIdx)             ; K = правая сторона закрытого gap
                OR   A
                JR   Z, .cgb_no                        ; нет левого берега
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .cgb_no                       ; нет правого берега
                LD   B, A                              ; B = K
                LD   A, (VDC_TmpML)
                CP   B
                JR   NC, .cgb_no                       ; left >= K → run справа от gap
                LD   A, (VDC_TmpMR)
                CP   B
                JR   C, .cgb_no                        ; right < K → run слева от gap
                LD   A, 1
                RET
.cgb_no:       XOR  A
                RET

VDC_ApplyMatch3:
                ; default marker GAP_STOP
                LD   B, VDC_GAP_STOP

                ; CASCADE check: lb>0 & rb+1<len & Slots[lb-1] и Slots[rb+1] обe non-gap
                ; и одного цвета.
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_have_marker                ; lb=0 → STOP
                LD   HL, VDC_SlotsLen
                LD   A, (VDC_TmpMR)
                INC  A
                CP   (HL)
                JR   NC, .m3_have_marker               ; rb+1>=len → STOP

                LD   A, (VDC_TmpML)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .m3_have_marker
                LD   A, (VDC_TmpML)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   C, (HL)                           ; C = Slots[lb-1]
                LD   A, C
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP

                LD   A, (VDC_TmpMR)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .m3_have_marker
                LD   A, (VDC_TmpMR)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP
                CP   C
                JR   NZ, .m3_have_marker
                LD   B, VDC_GAP_CASCADE
.m3_have_marker:
                PUSH BC
                CALL LogMatch3                          ; диагностика: ctx=color, d1=lb, d2=rb, d3=count, d4=TmpInsIdx
                POP  BC
                PUSH BC
                LD   A, SND_CHIME1
                CALL GS_PlaySfx
                LD   A, 8
                LD   (VDC_SfxStopTimer), A
                POP  BC
                ; B = marker (GAP_STOP / GAP_CASCADE). Stats блок ниже клобает B
                ; в gauge-loop'е (LD B,A + DJNZ → B=0), поэтому сохраняем и
                ; восстанавливаем перед записью в ExplodeMarker.
                ; Bug 2026-05-20: без push/pop в Slots после анимации попадали
                ; шары color 0 (синие) вместо gap.
                PUSH BC
                ; Новый match не должен стирать pending Shot2 от уже закрытого
                ; gap: offsets ещё могут выравниваться, и легальная тройка
                ; должна сработать позже. Settled-метки без pending-движения
                ; можно убрать как устаревшие; сам matched run очищается ниже.
                CALL VDC_ClearSettledShot2
                ; Chain count++ (Statistics_IncrementChain): consecutive explosions
                ; включая cascade. Break — в VDC_InsertAt на shot без match.
                LD   HL, VDC_StatChainCount
                INC  (HL)
                ; --- Stats tracking: max chain + combo (same-color streak) ---
                LD   A, (VDC_TmpMCount)
                LD   HL, VDC_StatMaxChain
                CP   (HL)
                JR   C, .m3_no_maxchain
                JR   Z, .m3_no_maxchain
                LD   (HL), A
.m3_no_maxchain:
                ; Combo: если тот же color что прошлая match → ++; иначе = 0
                LD   A, (VDC_TmpMC_Color)
                LD   HL, VDC_StatPrevMatchColor
                CP   (HL)
                JR   Z, .m3_combo_inc
                ; Разный color → combo = 0
                LD   (HL), A                            ; save current color
                XOR  A
                LD   (VDC_StatCombos), A
                JR   .m3_combo_done
.m3_combo_inc:
                LD   A, (VDC_StatCombos)
                INC  A
                LD   (VDC_StatCombos), A
                LD   HL, VDC_StatMaxCombo
                CP   (HL)
                JR   C, .m3_combo_done
                JR   Z, .m3_combo_done
                LD   (HL), A
.m3_combo_done:
                ; Score формула 1:1 c HD-ref Statistics.c:37:
                ;   points = ballsCount*10 + comboCount*100
                ; + если chain>=5 AND combo==0:
                ;     points += 100 + 10*(chain-5)
                LD   A, (VDC_TmpMCount)
                LD   B, A
                XOR  A
                LD   HL, 0
.m3_gauge_base:
                LD   DE, 10
                ADD  HL, DE
                DJNZ .m3_gauge_base
                LD   A, (VDC_StatCombos)
                OR   A
                JR   NZ, .m3_gauge_apply_combo
                ; combo == 0 → проверяем chain bonus
                LD   A, (VDC_StatChainCount)
                CP   5
                JR   C, .m3_gauge_add                  ; chain < 5 → нет бонуса
                ; chain >= 5 → +100 + 10*(chain-5)
                LD   DE, 100
                ADD  HL, DE
                SUB  5                                  ; A = chain - 5
                JR   Z, .m3_gauge_add                   ; chain == 5 → just base 100
                LD   B, A
.m3_gauge_chain:
                LD   DE, 10
                ADD  HL, DE
                DJNZ .m3_gauge_chain
                JR   .m3_gauge_add
.m3_gauge_apply_combo:
                LD   B, A
.m3_gauge_combo:
                LD   DE, 100
                ADD  HL, DE
                DJNZ .m3_gauge_combo
.m3_gauge_add:
                PUSH HL
                CALL Score_Add24                       ; HL=delta; 24-bit score += HL + extra-life (was 16-bit add)
                POP  HL
                LD   DE, (VDC_GaugeScore)
                ADD  HL, DE
                LD   (VDC_GaugeScore), HL
                CALL GetCurrentTargetScore             ; DE = per-level target (BUG fix: clobbers HL!)
                LD   HL, (VDC_GaugeScore)               ; reload GaugeScore — CALL above trashed HL
                AND  A
                SBC  HL, DE                             ; GaugeScore - target; CF=1 if still below
                JR   C, .m3_gauge_not_full
                LD   A, 1
                LD   (VDC_GaugeFull), A
.m3_gauge_not_full:
                POP  BC                                ; restore B = marker (GAP_STOP/CASCADE)

                ; ExplodeFrame[lb..rb] = 1, ExplodeMarker[lb..rb] = B.
                ; Slots stay as colors until VDC_AnimateChain finalizes them.
                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_expl_frames:
                LD   (HL), 1
                INC  HL
                DEC  C
                JR   NZ, .m3_set_expl_frames

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_expl_markers:
                LD   (HL), B
                INC  HL
                DEC  C
                JR   NZ, .m3_set_expl_markers

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_offs:
                LD   (HL), 0
                INC  HL
                DEC  C
                JR   NZ, .m3_set_offs

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_shot2_clr:
                LD   (HL), 0
                INC  HL
                DEC  C
                JR   NZ, .m3_set_shot2_clr

                ; Не ставим Shot2 на соседей сразу. При длинных spawn-сериях это
                ; даёт ложный match-3 до физического закрытия gap. Соседи получают
                ; Shot2 только в VDC_DoGapStep после удаления marker-slot'а.
                XOR  A
                LD   (VDC_GapStepCnt), A
                ; Freeze until the first DoGapStep. Explosion finalizes after
                ; VDC_EXPLOSION_FRAMES, but GapStepCnt fires at CELL_SIZE.
                ; If we unfreeze at frame 15 while the gap marker waits until
                ; frame 32, the head segment moves forward across an open gap.
                LD   A, VDC_GAP_STEP_FRAMES
                LD   (VDC_ChainFreezeCnt), A
                LD   A, 1
                RET
VDC_CheckMatch3_No:
                XOR  A
                RET

; ============================================================================
; VDC_DoGapStep — обрабатывает ОДИН маркер за вызов. Pass 1: STOP from tail
; (right→left), удаляет slot, HSA--, head compensation. Pass 2 (если STOP не было):
; CASCADE from head (left→right), то же + ChainFreezeCnt = CELL_SIZE.
; ============================================================================
VDC_DoGapStep:
                ; --- Pass 1: ищем последний GAP_STOP справа налево ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .dgs_cascade_init
                DEC  A
                LD   C, A                              ; C = idx (от len-1)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE                            ; HL = &Slots[len-1]
.dgs_stop_scan:
                LD   A, (HL)
                CP   VDC_GAP_STOP
                JR   Z, .dgs_stop_found
                LD   A, C
                OR   A
                JR   Z, .dgs_cascade_init
                DEC  C
                DEC  HL
                JR   .dgs_stop_scan

.dgs_stop_found:
                LD   A, C
                LD   (VDC_TmpGapIdx), A
                CALL VDC_RemoveSlotAt                  ; удаляет slot C, len-=1
                CALL VDC_HsaDec                        ; HSA-- если >0

                ; offsets[0..K-1] = min(off[j]+CS, CS) — head compensation
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_stop_no_off
                LD   B, A                              ; B = K
                LD   HL, (VDC_pOffsets)
.dgs_stop_off:
                ; Python: s.offsets[k] = min(s.offsets[k] + CELL_SIZE, CELL_SIZE)
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                JP   PE, .dgs_stop_off_clamp
                PUSH AF
                XOR  #80
                CP   #80 + VDC_CELL_SIZE + 1
                POP  AF
                JR   C, .dgs_stop_off_save             ; A <= CELL_SIZE → save
.dgs_stop_off_clamp:
                LD   A, VDC_CELL_SIZE                  ; cap
.dgs_stop_off_save:
                LD   (HL), A
                INC  HL
                DJNZ .dgs_stop_off
.dgs_stop_no_off:
                ; MatchScanIdx = K (для информативности; persistent scan по Shot2 всё равно ловит)
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                ; Shot2 на соседях K-1 и K (после shift), если они non-gap.
                CALL VDC_SetShot2OnNeighbors
                RET

.dgs_cascade_init:
                ; --- Pass 2: ищем первый GAP_CASCADE слева ---
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = len
                LD   C, 0                              ; C = idx
                LD   HL, (VDC_pSlots)
.dgs_casc_scan:
                LD   A, (HL)
                CP   VDC_GAP_CASCADE
                JR   Z, .dgs_casc_found
                INC  HL
                INC  C
                DEC  B
                JR   NZ, .dgs_casc_scan
                RET

.dgs_casc_found:
                LD   A, C
                LD   (VDC_TmpGapIdx), A
                CALL LogCascadeTrigger
                CALL VDC_RemoveSlotAt
                CALL VDC_HsaDec

                ; head comp
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_casc_no_off
                LD   B, A
                LD   HL, (VDC_pOffsets)
.dgs_casc_off:
                ; Python: s.offsets[k] = min(CELL_SIZE, s.offsets[k] + CELL_SIZE)
                ; Old asm: cap'ил positive offsets к CELL_SIZE INSTEAD ADD — это
                ; давало instant jump на +(CELL_SIZE-offset) при positive mid-decay.
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE + 1
                JR   C, .dgs_casc_off_save             ; A ≤ CELL_SIZE → save
                LD   A, VDC_CELL_SIZE                  ; cap
.dgs_casc_off_save:
                LD   (HL), A
                INC  HL
                DJNZ .dgs_casc_off
.dgs_casc_no_off:
                LD   A, VDC_CELL_SIZE
                LD   (VDC_ChainFreezeCnt), A
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                CALL VDC_SetShot2OnNeighbors
                RET

; ----------------------------------------------------------------------------
; VDC_RemoveSlotAt — удаляет slot (VDC_TmpGapIdx). Shift_left +
; SlotsLen-=1. Затрагивает Slots, Offsets, Shot2, RollbackCnt.
; ----------------------------------------------------------------------------
VDC_RemoveSlotAt:
                LD   A, (VDC_SlotsLen)
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpGapIdx)
                LD   C, A                              ; C = idx
                LD   A, B
                SUB  C
                DEC  A                                 ; count = len - idx - 1
                JP   Z, .rsa_no_shift                  ; idx == len-1 -> nothing to shift
                LD   E, A                              ; E = count

                ; Shift Slots[idx+1..len-1] → Slots[idx..len-2]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE                            ; HL = src = &Slots[idx+1]
                PUSH HL
                LD   D, H : LD E, L
                DEC  DE                                ; DE = dst = &Slots[idx]
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0                    ; BC = count
                LDIR
                POP  HL                                ; (восстановили src=&Slots[idx+1])

                ; Аналогично для Offsets, Shot2, RollbackCnt
                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   D, H : LD E, L
                DEC  DE
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                LD   C, A
                LD   A, B
                SUB  C
                DEC  A
                LD   C, A : LD B, 0
                LDIR

.rsa_no_shift:
                LD   HL, VDC_SlotsLen
                DEC  (HL)
                RET

; ----------------------------------------------------------------------------
; VDC_HsaDec — HSA-- если HSA>0, иначе nop.
; ----------------------------------------------------------------------------
VDC_HsaDec:
                LD   A, (VDC_HSA)
                OR   A
                RET  Z
                DEC  A
                LD   (VDC_HSA), A
                RET

; ----------------------------------------------------------------------------
; VDC_SetShot2OnNeighbors — после удаления slot K (TmpGapIdx) поставить Shot2
; на K-1 и K только если gap closure реально сомкнул два шара одного цвета.
; Иначе pre-existing same-color run на одной стороне gap может дать ложный match-3.
; ----------------------------------------------------------------------------
VDC_SetShot2OnNeighbors:
                LD   A, (VDC_TmpGapIdx)
                OR   A
                RET  Z                                  ; нет left side
                DEC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                RET  NC                                 ; K-1 out of bounds
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  NC                                 ; left is gap
                LD   B, A                               ; B = left color

                ; K: проверить < SlotsLen и not gap
                LD   A, (VDC_TmpGapIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                RET  NC                                 ; нет right side
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  NC                                 ; right is gap
                CP   B
                RET  NZ                                 ; closure не соединил одинаковые цвета

                ; Same-color closure: trigger both sides.
                LD   A, (VDC_TmpGapIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   (HL), 1

                LD   A, (VDC_TmpGapIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   (HL), 1
                LD   A, 1
                LD   (VDC_BridgeScanActive), A
                RET

; ============================================================================
; VDC_ScanForNewMatch — проходит Shot2[0..len-1], при is_gap чистит, иначе
; CheckMatch3, иначе если settled (все offsets вокруг 0) — чистит Shot2.
; ============================================================================
VDC_ScanForNewMatch:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   E, A                              ; save len; XOR below must not turn DJNZ into 256 iterations
                XOR  A
                LD   (VDC_ScanGapBusy), A
                ; Если в цепочке ещё есть GAP/CASCADE markers, нельзя сканировать
                ; дальние Shot2: они видят неполную цепь. Но активную границу K-1/K
                ; надо оставить проверяемой, иначе легальный bridge может быть
                ; потерян, если следующий gap успеет перезаписать MatchScanIdx.
                PUSH BC
                PUSH HL
                LD   B, E
                LD   HL, (VDC_pSlots)
.snm_gap_wait:
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .snm_gap_busy
                INC  HL
                DJNZ .snm_gap_wait
                POP  HL
                POP  BC
                JR   .snm_no_gap_markers
.snm_gap_busy:
                LD   A, 1
                LD   (VDC_ScanGapBusy), A
                POP  HL
                POP  BC
                JR   .snm_no_gap_markers
.snm_no_gap_markers:
                LD   B, E                              ; B = iter
                LD   HL, (VDC_pShot2)
                LD   C, 0                              ; C = idx
.snm_loop:
                LD   A, (HL)
                OR   A
                JP   Z, .snm_next

                ; Slots[C] is gap? → clear Shot2
                PUSH BC
                PUSH HL
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                POP  HL
                POP  BC
                CP   VDC_NUM_COLORS
                JR   C, .snm_check
                LD   (HL), 0
                JP   .snm_next

.snm_check:
                PUSH BC
                PUSH HL
                LD   A, C
                LD   (VDC_TmpInsIdx), A
                XOR  A
                LD   (VDC_RequireGapBridge), A
                LD   A, C
                LD   B, A
                LD   A, (VDC_MatchScanIdx)
                CP   B
                JR   Z, .snm_bridge_on                 ; C == K
                LD   A, B
                INC  A
                LD   B, A
                LD   A, (VDC_MatchScanIdx)
                CP   B
                JR   Z, .snm_bridge_on                 ; C+1 == K
                LD   A, (VDC_ScanGapBusy)
                OR   A
                JR   NZ, .snm_skip_cascade_far
                LD   A, (VDC_BridgeScanActive)
                OR   A
                JR   Z, .snm_bridge_ready
                ; Пока закрывается cascade-gap K, дальние старые Shot2 не имеют
                ; права запускать обычный match-3 раньше легальной границы K-1/K.
.snm_skip_cascade_far:
                POP  HL
                POP  BC
                JP   .snm_next
.snm_bridge_on:
                LD   A, 1
                LD   (VDC_RequireGapBridge), A
.snm_bridge_ready:
                CALL VDC_CheckMatch3
                PUSH AF
                XOR  A
                LD   (VDC_RequireGapBridge), A
                LD   (VDC_BridgeScanActive), A
                POP  AF
                POP  HL
                POP  BC
                OR   A
                RET  NZ                                ; match → выходим
                ; Если offsets ещё не выровнялись, держим Shot2 pending:
                ; свежий insert на half-cell может стать match'ем через несколько
                ; кадров decay. Если уже settled и match нет — триггер устарел.
                PUSH BC
                PUSH HL
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
                LD   A, C
                OR   A
                JR   Z, .snm_check_right
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
.snm_check_right:
                LD   A, C
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .snm_settled
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
.snm_settled:
                POP  HL
                POP  BC
                LD   (HL), 0
                JR   .snm_next
.snm_unsettled:
                POP  HL
                POP  BC
.snm_next:
                INC  HL
                INC  C
                DEC  B
                JP   NZ, .snm_loop
                RET

; ============================================================================
; VDC_InsertAt — вставить шар цвета B в позицию A (=target_idx).
; Shift right Slots/Offsets/Shot2/RollbackCnt[A..len-1] → A+1..len.
; new_off = -CS/2 + (head_off + tail_off)/2.
; HSA++ с cap, offsets[0..A-1] -= CS с cap -CS, ChainFreezeCnt = CS,
; ставит Shot2 на A, CheckMatch3.
; ============================================================================
VDC_InsertAt:
                LD   (VDC_TmpInsIdx), A
                LD   A, B
                LD   (VDC_TmpInsColor), A

                CALL LogInsert                         ; INSERT event (reads VDC_* directly)

                ; clamp target_idx <= SlotsLen
                LD   A, (VDC_TmpInsIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   C, .ia_idx_ok
                LD   A, (HL)
                LD   (VDC_TmpInsIdx), A
.ia_idx_ok:
                ; SlotsLen >= MAX → fail (silent)
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; --- Debug 2026-05-16: считать tail vs mid insertions ---
                LD   A, (VDC_TmpInsIdx)
                LD   B, A
                LD   A, (VDC_SlotsLen)
                CP   B
                JR   NZ, .ia_dbg_mid                   ; TmpInsIdx < SlotsLen → mid
                LD   HL, VDC_DbgInsTail
                INC  (HL)
                JR   .ia_dbg_done
.ia_dbg_mid:    LD   HL, VDC_DbgInsMid
                INC  (HL)
.ia_dbg_done:

                ; --- compute new_offset ---
                ; head_off, tail_off:
                ;   slots_len==0           → head=tail=0
                ;   target_idx==0          → head=tail=offsets[0]
                ;   target_idx==slots_len  → head=tail=offsets[len-1]
                ;   else                   → head=offsets[idx-1], tail=offsets[idx]
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   NZ, .ia_off_nonempty
                LD   B, 0 : LD C, 0                    ; head=0, tail=0
                JR   .ia_off_compute
.ia_off_nonempty:
                LD   A, (VDC_TmpInsIdx)
                OR   A
                JR   NZ, .ia_off_not_zero
                ; idx==0
                LD   HL, (VDC_pOffsets)
                LD   A, (HL)
                LD   B, A : LD C, A
                JR   .ia_off_compute
.ia_off_not_zero:
                LD   HL, VDC_SlotsLen
                LD   A, (VDC_TmpInsIdx)
                CP   (HL)
                JR   NZ, .ia_off_middle
                ; idx == slots_len
                LD   A, (HL)                           ; A = len
                DEC  A                                 ; A = len-1
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A : LD C, A
                JR   .ia_off_compute
.ia_off_middle:
                ; head = offsets[idx-1], tail = offsets[idx]
                LD   A, (VDC_TmpInsIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   B, (HL)                           ; B = head_off
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   C, (HL)                           ; C = tail_off
.ia_off_compute:
                ; new_off = -CS/2 + (head + tail) / 2 — все signed бытовое сложение.
                ; Считаем как 16-bit signed для безопасности от переполнения.
                ; head_ext, tail_ext:
                LD   A, B
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .ia_head_ext_pos
                DEC  D
.ia_head_ext_pos:
                PUSH DE                                ; head_ext on stack
                LD   A, C
                LD   E, A
                LD   D, 0
                BIT  7, A
                JR   Z, .ia_tail_ext_pos
                DEC  D
.ia_tail_ext_pos:
                POP  HL                                ; HL = head_ext
                ADD  HL, DE                            ; HL = head + tail (signed 16)
                ; /2 (signed): SRA H, RR L
                SRA  H : RR L
                LD   DE, -(VDC_CELL_SIZE/2)
                ADD  HL, DE                            ; HL = -CS/2 + (h+t)/2
                ; saturate to signed byte [-128..127]
                LD   A, L
                BIT  7, H
                JR   Z, .ia_off_sat_pos
                ; negative: clamp to -128 if H < #FF
                LD   A, H
                CP   #FF
                JR   Z, .ia_off_neg_byte
                LD   A, #80                            ; -128
                JR   .ia_off_save
.ia_off_neg_byte:
                LD   A, L
                CP   #80
                JR   NC, .ia_off_save                  ; A in [#80..#FF] OK
                LD   A, #80
                JR   .ia_off_save
.ia_off_sat_pos:
                ; positive: сохраняем L только если старший байт H равен 0.
                ; Старый код проверял A=L через OR H и превращал любой L>0 в #7F.
                LD   A, H
                OR   A
                LD   A, L
                JR   Z, .ia_off_save
                LD   A, #7F                            ; +127
.ia_off_save:
                LD   (VDC_TmpInsNewOff), A

                ; --- shift right: Slots[idx..len-1] → idx+1..len ---
                ; Используем LDDR (от хвоста), чтобы не затирать.
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ia_no_shift                   ; len==0 → нечего сдвигать
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpInsIdx)
                CP   B
                JR   NC, .ia_no_shift                  ; idx>=len → нечего сдвигать
                ; count = len - idx
                SUB  B
                NEG                                    ; A = len - idx
                LD   E, A                              ; E = count

                ; Slots: src = &Slots[len-1], dst = &Slots[len], count
                CALL VDC_ShiftRight_Slots

                ; Offsets
                CALL VDC_ShiftRight_Offsets

                ; Shot2
                CALL VDC_ShiftRight_Shot2

                ; Explosion state follows slot ownership.
                CALL VDC_ShiftRight_ExplodeFrame
                CALL VDC_ShiftRight_ExplodeMarker
.ia_no_shift:
                ; --- Slots[idx] = color, Offsets[idx] = new_off, Shot2[idx]=1 ---
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (VDC_TmpInsColor)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (VDC_TmpInsNewOff)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   (HL), 1

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   (HL), 0

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   (HL), 0

                ; SlotsLen++
                LD   HL, VDC_SlotsLen
                INC  (HL)

                ; HSA++ с cap по TrackNumSlots-1.
                ; Cap-fix (Z80-симулятор verify 2026-05-14): при HSA == TrackNumSlots-1
                ; HSA++ skip → нужна компенсация:
                ;   1) skip head_comp (offsets[0..idx-1] остаются как после shift_right = 0)
                ;   2) new ball offset = +CS/2 вместо -CS/2
                ;   3) offsets[idx+1..SlotsLen-1] += CS
                ; Тогда t(i) = (HSA - i)*CS + off совпадает с нормальным flow при HSA=cap+1.
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   C, .ia_cap_branch
                JR   Z, .ia_cap_branch
                LD   HL, VDC_HSA
                INC  (HL)
                JP   .ia_head_comp_entry
.ia_cap_branch:
                ; --- Cap compensation: переписать offsets[idx] на +CS/2 (был -CS/2) ---
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   (HL), VDC_CELL_SIZE / 2
                ; --- offsets[idx+1 .. SlotsLen-1] += CS ---
                LD   A, (VDC_TmpInsIdx)
                INC  A                                  ; A = idx+1
                LD   B, A
                LD   A, (VDC_SlotsLen)
                SUB  B                                  ; A = SlotsLen - (idx+1) = count
                JR   Z, .ia_no_head_comp
                JR   C, .ia_no_head_comp                ; paranoia
                LD   H, 0 : LD L, B
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   B, A
.ia_cap_compensate_loop:
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE
                JP   PE, .ia_cap_compensate_clamp
                PUSH AF
                XOR  #80
                CP   #80 + VDC_CELL_SIZE + 1
                POP  AF
                JR   C, .ia_cap_compensate_save
.ia_cap_compensate_clamp:
                LD   A, VDC_CELL_SIZE
.ia_cap_compensate_save:
                LD   (HL), A
                INC  HL
                DJNZ .ia_cap_compensate_loop
                JP   .ia_no_head_comp
.ia_head_comp_entry:
                ; offsets[0..idx-1] -= CS, cap to -CS (= -64)
                LD   A, (VDC_TmpInsIdx)
                OR   A
                JR   Z, .ia_no_head_comp
                LD   B, A
                LD   HL, (VDC_pOffsets)
.ia_head_comp:
                LD   A, (HL)
                SUB  VDC_CELL_SIZE                     ; off -= CS
                ; cap к -CS (signed): если A < -CELL (signed) → A = -CELL.
                ; Используем JP PE для отлова wrap-around ниже -128.
                JP   PE, .ia_head_comp_clamp
                ; Biased compare: (A XOR #80) < (#80 - CELL_SIZE) → clamp.
                PUSH AF
                XOR  #80
                CP   #80 - VDC_CELL_SIZE
                POP  AF
                JR   NC, .ia_head_comp_save            ; A >= -CELL → ОК
.ia_head_comp_clamp:
                LD   A, 256 - VDC_CELL_SIZE            ; -CELL
.ia_head_comp_save:
                LD   (HL), A
                INC  HL
                DJNZ .ia_head_comp
.ia_no_head_comp:
                ; ChainFreezeCnt НЕ ставим (без freeze head_offsets декают параллельно
                ; с natural hsub advance, head освобождает место). Trade-off: short
                ; head_slide animation visible (~32 px over 16 frames) — accepted vs
                ; chain-stops-everything на CS frames (хуже визуально).

                ; Immediate CheckMatch3 на target_idx. Для свежей вставки не
                ; ждём decay offsets: если слоты одного цвета уже образуют
                ; тройку, она должна взрываться сразу. Строгий offset-gap
                ; остаётся для cascade/Shot2 через обычный VDC_CheckMatch3.
                CALL VDC_CheckMatch3_Insert
                OR   A
                RET  NZ                                ; match → chain продолжается
                ; No match (shot не сработал) → Statistics_BreakChain.
                XOR  A
                LD   (VDC_StatChainCount), A
                RET

; ----------------------------------------------------------------------------
; VDC_ShiftRight_* — сдвиг массива Array[idx..len-1] → Array[idx+1..len].
; Идем через LDDR (HL = src=last, DE = dst=last+1, BC = count).
; Использует VDC_TmpInsIdx, VDC_SlotsLen.
; ----------------------------------------------------------------------------
VDC_ShiftRight_Slots:
                LD   IX, (VDC_pSlots)
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Offsets:
                LD   IX, (VDC_pOffsets)
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Shot2:
                LD   IX, (VDC_pShot2)
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_ExplodeFrame:
                LD   IX, (VDC_pExplodeFrame)
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_ExplodeMarker:
                LD   IX, (VDC_pExplodeMarker)
                ; fallthrough
VDC_ShiftRight_Common:
                ; src = Array + (len-1), dst = src+1, count = len - idx
                LD   A, (VDC_SlotsLen)
                DEC  A
                LD   H, 0 : LD L, A
                PUSH IX
                POP  DE                                ; DE = Array
                ADD  HL, DE
                ; HL = src
                LD   D, H : LD E, L
                INC  DE                                ; DE = dst = src+1

                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpInsIdx)
                LD   C, A
                LD   A, B
                SUB  C
                LD   C, A : LD B, 0                    ; BC = count
                LDDR
                RET

; ============================================================================
; VDC_DivHLbyA — целочисленное деление 16-bit на 8-bit.
;   In:  HL = dividend (unsigned), A = divisor (unsigned, > 0)
;   Out: HL = quotient, A = remainder
;   Clobbers BC.
; Bit-by-bit алгоритм. ~80 t-states, ~16 байт кода.
; ============================================================================
; [VDC_DivHLbyA -> moved to shared_render.asm (resident; shared by gameplay #04 + level-select #41)]
VDC_RandomColor:
                ; Mul-then-shift: A = ((L XOR H) * NUM_COLORS) >> 8 = 0..NUM-1.
                ; Старый AND 7 + reject имел LFSR-bias для poly 0xB400: (L XOR H) & 7
                ; почти не выдавал значения 2 и 5 (биты коррелированы) → цвета 2 и 5
                ; не появлялись в цепи. Mul-then-shift bias ≤ 1.4% при NUM=6.
                ; Fix 2026-05-18.
                LD   HL, (VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   NC, .rc_no_xor
                LD   A, H : XOR #B4 : LD H, A          ; poly #B400 (low=0)
.rc_no_xor:
                LD   (VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; A = 8-bit random
                LD   L, A
                LD   H, 0                              ; HL = rand byte (0..255)
                LD   A, (VDC_LevelColors)              ; per-level color count (set in VDC_Init)
                CALL ZL_Mul16x8                        ; HL = rand * N (max 6*255 = 1530)
                LD   A, H                              ; A = (rand * N) >> 8 = 0..N-1
                RET

; ============================================================================
; VDC_RandomClusterLength — random length 1..(VDC_NUM_COLORS-1).
; Uses rejection of 0 from VDC_RandomColor. For current NUM=6 this is 1..5.
; ============================================================================
VDC_RandomClusterLength:
.rcl_loop:      CALL VDC_RandomColor
                OR   A
                JR   Z, .rcl_loop
                RET


; ============================================================================
; VDC_ResetBulletGapTracking — вызывается на каждый Bullet_Spawn. Обнуляет
; min-distance для нового полёта.
; ============================================================================
VDC_ResetBulletGapTracking:
                LD   A, 255
                LD   (VDC_BulletGapMinDist), A
                RET

; ============================================================================
; VDC_UpdateBulletGapTracking — per-frame check каждой GAP-ячейки в Slots[],
; обновляет VDC_BulletGapMinDist (Manhattan dist) если найдена ближе.
; Bullet (X, Y) читается напрямую из Bullet.asm state vars.
; ============================================================================
VDC_UpdateBulletGapTracking:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = loop count
                LD   C, 0                              ; C = i
.ugt_loop:      PUSH BC
                ; Slots[i] >= NUM_COLORS → gap, иначе non-gap пропускаем
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .ugt_skip                      ; non-gap → пропустить
                ; Также skip если ExplodeFrame > 0 (gap ещё не "финализирован",
                ; это не пустая ячейка а взрывающийся шар)
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .ugt_skip
                ; Compute slot position (allow gap)
                LD   A, C
                CALL VDC_SlotPosAllowGap               ; BC=X, DE=Y, CF=1 если t<0
                JR   C, .ugt_skip
                ; Manhattan distance = |bullet_X - X| + |bullet_Y - Y|, clamp 255
                LD   HL, (Bullet_X)
                AND  A
                SBC  HL, BC
                CALL ZL_AbsHL
                LD   A, H
                OR   A
                JR   NZ, .ugt_skip                     ; |dx| > 255 → дальше 255
                PUSH AF                                ; save dummy
                LD   B, L                              ; B = |dx|
                LD   HL, (Bullet_Y)
                AND  A
                SBC  HL, DE
                CALL ZL_AbsHL
                LD   A, H
                OR   A
                JR   NZ, .ugt_skip_pop
                LD   A, B
                ADD  A, L                              ; A = |dx| + |dy|
                JR   C, .ugt_skip_pop                  ; overflow 255 → пропуск
                ; Compare с текущим минимумом
                LD   HL, VDC_BulletGapMinDist
                CP   (HL)
                JR   NC, .ugt_skip_pop
                LD   (HL), A
.ugt_skip_pop:  POP  AF                                ; balance PUSH AF выше
.ugt_skip:      POP  BC
                INC  C
                DJNZ .ugt_loop
                RET

; ============================================================================
; VDC_AwardGapBonus — bullet expired без hit'а. Если был gap-pass — начислить
; очки по формуле HD-ref Statistics.c::Statistics_AddBulletGap.
; Реализация вынесена в main0: main1_play сейчас почти заполнен.
; ============================================================================
VDC_GAP_HIT_THR    EQU 24                              ; ~ball radius
VDC_GAP_MAX        EQU 32

VDC_AwardGapBonus:
                JP   VDC_AwardGapBonusSlot0

; ============================================================================
; VDC_CheckInvariants — пассивная проверка правил состояния после кадра.
; Ничего не исправляет и не меняет игровой процесс: только защёлкивает первое
; нарушение в VDC_Assert* для F12 dump.
; ============================================================================
VDC_CheckInvariants:
                PUSH AF
                PUSH BC
                PUSH DE
                PUSH HL
                LD   A, (VDC_AssertCode)
                OR   A
                JP   NZ, .vci_done

                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS + 1
                JR   C, .vci_len_ok
                LD   C, 1
                LD   E, A
                XOR  A
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_len_ok:
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A
                LD   D, 0
                AND  A
                SBC  HL, DE
                JR   NC, .vci_hsa_ok
                LD   C, 2
                LD   A, (VDC_HSA)
                LD   E, A
                XOR  A
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_hsa_ok:
                LD   A, (VDC_SlotsLen)
                OR   A
                JP   Z, .vci_done
                LD   B, A
                LD   C, 0
.vci_loop:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_NUM_COLORS
                JR   C, .vci_slot_ok
                CP   VDC_GAP_STOP
                JR   Z, .vci_slot_ok
                CP   VDC_GAP_CASCADE
                JR   Z, .vci_slot_ok
                LD   A, C
                LD   C, 3
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_slot_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_CELL_SIZE + 1
                JR   C, .vci_offset_ok
                CP   256 - VDC_CELL_SIZE
                JR   NC, .vci_offset_ok
                LD   A, C
                LD   C, 4
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_offset_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .vci_explode_ok
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pExplodeMarker)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   VDC_GAP_STOP
                JR   Z, .vci_explode_ok
                CP   VDC_GAP_CASCADE
                JR   Z, .vci_explode_ok
                LD   A, C
                LD   C, 5
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_explode_ok:
                LD   A, C
                LD   H, 0
                LD   L, A
                LD   DE, (VDC_pShot2)
                ADD  HL, DE
                LD   A, (HL)
                LD   E, A
                CP   2
                JR   C, .vci_next
                LD   A, C
                LD   C, 6
                CALL VDC_LatchAssert
                JP   .vci_done
.vci_next:
                INC  C
                DJNZ .vci_loop
.vci_done:
                POP  HL
                POP  DE
                POP  BC
                POP  AF
                RET

; In: C=код, A=индекс/контекст, E=значение.
VDC_LatchAssert:
                LD   (VDC_AssertCtx), A
                LD   A, C
                LD   (VDC_AssertCode), A
                LD   A, (VDC_SlotsLen)
                LD   (VDC_AssertLen), A
                LD   A, (VDC_HSA)
                LD   (VDC_AssertHSA), A
                LD   A, E
                LD   (VDC_AssertValue), A
                LD   HL, (ZL_FrameCounter)
                LD   (VDC_AssertFrame), HL
                RET


; ============================================================================
; STATE — массивы и скаляры. SAVEBIN их сохранит как нули; VDC_Init
; явно инициализирует на старте (см. feedback_zuma_init_explicit.md).
; ============================================================================
VDC_Slots:        DS VDC_MAX_SLOTS
VDC_Offsets:      DS VDC_MAX_SLOTS
VDC_Shot2:        DS VDC_MAX_SLOTS
VDC_ExplodeFrame: DS VDC_MAX_SLOTS
VDC_ExplodeMarker: DS VDC_MAX_SLOTS

VDC_ChainLocalStart:

VDC_HSA:           DEFB 0
; VDC_HSub, VDC_SlotsLen -> hoisted to loader_resident.asm (resident Core)
VDC_ChainFreezeCnt:DEFB 0
VDC_GapStepCnt:    DEFB 0
VDC_BallsSpawned:  DEFB 0
VDC_SpawnClusterColor: DEFB 0xFF  ; current cluster color (HD-ref style same-color runs)
VDC_SpawnClusterRem:   DEFB 0     ; remaining same-color spawns ПОСЛЕ текущего (0=roll new)
VDC_MatchScanIdx:  DEFB 0
VDC_ScanGapBusy:   DEFB 0
VDC_BridgeScanActive: DEFB 0
VDC_TrackNumSlots: DEFW 0
; VDC_GameState -> hoisted to loader_resident.asm (resident Core)
VDC_GameOverTick:  DEFB 0
VDC_IntroTick:     DEFB 0   ; intro countdown (frames until state→PREVIEW)
VDC_PreviewTick:   DEFB 0   ; preview countdown (frames until state→CLOSING)
VDC_KzCloseTick:   DEFB 0   ; closing countdown (skull 11→1 animation)
VDC_WinTick:       DEFB 0   ; win-state countdown before next level load
VDC_KzEndSub:      DEFB 0
; VDC_KzFrame, VDC_HeadAbsorbAlpha, VDC_Lives, VDC_DialogState, VDC_PrevMouseL,
; VDC_HudMenuState, VDC_HudPointerBlock -> hoisted to loader_resident.asm
VDC_LevelColors:  DEFB VDC_NUM_COLORS ; per-level ball-color count (set from settings table in VDC_Init; default 6)
VDC_LevelSpeed:   DEFB 50              ; per-level chain speed_x100 (set in VDC_Init); normal-phase advance = speed/100 MoveChain/frame
VDC_LevelStart:   DEFB VDC_LEVEL_START_BALLS ; per-level lead-in ball count (fast-fill threshold)
VDC_SpeedAccum:   DEFB 0               ; sub-frame speed accumulator for VDC_LevelSpeed
VDC_RollingActive: DEFB 0              ; 1 while SND_ROLLING should be stopped on fast->normal
VDC_ChainLocalEnd:
; --- Stats counters (показываются в game-over диалоге, reset на VDC_Init) ---
VDC_StatTimeFrames: DEFW 0  ; сколько frame'ов прошло в state=PLAY (60Hz tick)
VDC_StatCombos:     DEFB 0  ; текущее combo (≥2 explosions одного цвета подряд)
VDC_StatMaxCombo:   DEFB 0  ; max combo за уровень
VDC_StatMaxChain:   DEFB 0  ; max chain bonus за уровень
VDC_StatCoins:      DEFB 0  ; coin pickups (TODO: coin mech не реализован → 0)
VDC_StatPrevMatchColor: DEFB #FF  ; previous match color, sentinel #FF (нет предыдущего)
VDC_StatChainCount: DEFB 0  ; consecutive explosions без miss-shot. ≥5 + combo=0 = chain bonus
VDC_BulletGapMinDist: DEFB 255  ; min Manhattan distance bullet → ближайший GAP-slot за полёт.
                                ; Init=255 на каждый Bullet_Spawn (VDC_ResetBulletGapTracking).
                                ; Per-frame update в VDC_UpdateBulletGapTracking, проверяется на expire.
VDC_BulletGapCount: DEFB 0  ; consecutive gap shots для ×2 multiplier (HD-ref Statistics_AddBulletGap)
; VDC_GaugeScore, VDC_GaugeFull, VDC_PlayerScore, VDC_GameSeconds -> hoisted to
; loader_resident.asm (resident Core). VDC_GaugeShown stays here (gameplay-only).
VDC_GaugeShown:     DEFW 0  ; displayed/animated score (LERP'ит к GaugeScore)
VDC_RtcLastSecond:  DEFB 0  ; last RTC seconds sample (0..59)
VDC_RtcNoTickFrames: DEFB 0 ; fallback counter when RTC is static in emulator
VDC_SfxStopTimer:   DEFB 0  ; delayed SND_SILENCE for GS one-shot tails

VDC_TmpInsIdx:    DEFB 0
VDC_TmpInsColor:  DEFB 0
VDC_TmpInsNewOff: DEFB 0
VDC_DetectIgnoreOffsets: DEFB 0
VDC_RequireGapBridge: DEFB 0
VDC_TmpGapIdx:    DEFB 0
VDC_TmpML:        DEFB 0
VDC_TmpMR:        DEFB 0
VDC_TmpMCount:    DEFB 0
VDC_TmpMC_Color:  DEFB 0

; --- Debug counters (2026-05-16): источник SlotsLen-инкрементов ---
VDC_DbgSpawnCnt:  DEFB 0   ; +=1 каждый раз когда VDC_TrySpawn реально добавил шар (хвостовой spawn)
VDC_DbgInsTail:   DEFB 0   ; +=1 каждый InsertAt с target == SlotsLen (вставка в самый конец)
VDC_DbgInsMid:    DEFB 0   ; +=1 каждый InsertAt с target < SlotsLen (mid-chain insertion от bullet)

VDC_LfsrSeed:     DEFW 0
VDC_LastTangent:  DEFB 0                                ; tangent байт последнего VDC_SlotPos
VDC_LastT:        DEFW 0                                ; t (16-bit signed) последнего VDC_SlotPos — для spin frame по track-advance

; Second chain backing store. The active labels above remain the only VDC engine
; ABI; two-track levels swap this block in around update/render/collision.
VDC_HasSecondChain: DEFB 0
VDC_MAIN1_PAGE   EQU #04
VDC2_Slots:        DS VDC_MAX_SLOTS
VDC2_Offsets:      DS VDC_MAX_SLOTS
VDC2_Shot2:        DS VDC_MAX_SLOTS
VDC2_ExplodeFrame: DS VDC_MAX_SLOTS
VDC2_ExplodeMarker: DS VDC_MAX_SLOTS
VDC2_HSub:         DEFB 0
VDC2_SlotsLen:     DEFB 0
VDC2_KzFrame:      DEFB 0
VDC2_KzDrawX16:    DEFW 0
VDC2_KzDrawY16:    DEFW 0
VDC2_ChainLocal:   DS VDC_ChainLocalEnd - VDC_ChainLocalStart
VDC_SwapTmp:       DEFB 0
VDC_SwapPtr1:      DEFW 0
VDC_SwapPtr2:      DEFW 0
VDC_SwapLen:       DEFW 0
; --- Указатели активной цепочки (C-рефактор): код массивов обращается через них,
; смена цепочки = установка 5 указателей (БЕЗ копирования 1200 байт). Стартуют на
; блок цепочки 1; VDC_SelectChain1/2 переключают. ---
VDC_pSlots:         DEFW VDC_Slots
VDC_pOffsets:       DEFW VDC_Offsets
VDC_pShot2:         DEFW VDC_Shot2
VDC_pExplodeFrame:  DEFW VDC_ExplodeFrame
VDC_pExplodeMarker: DEFW VDC_ExplodeMarker
VDC_SecondActive:   DEFB 0               ; 0 = активна цепочка 1, 1 = цепочка 2
VDC_SwapBuf:       DS VDC_MAX_SLOTS * 5

                endif ; ~_ZUMA_VDC_
