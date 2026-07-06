
                ifndef _ZUMA_VDC_
                define _ZUMA_VDC_

; ============================================================================
; VDC — Virtual Discrete Chain physics для Zuma VDAC2 (1024×768 runtime).
; ----------------------------------------------------------------------------
; Порт vdc_visual_emulator.py 1:1. Отличия от 360x288 asm-версии:
;   - CELL_SIZE = 32 (как в 360x288). Track length зависит от board; L01 =
;     ~2774 samples, L22/Space сейчас 4354 samples (=136 track cells).
;     SlotsLen остаётся byte-sized; HSA — word для headroom.
;   - LastRenderPos НЕ хранится: при t<0 рендер skip. Компромисс: при cascade
;     rollback шары на спавне на 1-2 кадра становятся невидимыми. Можно добавить
;     потом как опциональный массив.
;   - У match-3 есть visual explosion phase. Slots сохраняют color, пока
;     VDC_ExplodeFrame > 0; после таймера сохраняется GAP marker, затем
;     продолжается обычное VDC gap closing.
;
; API:
;   VDC_Init       — обнулить все массивы, Slots[] = GAP_STOP, RNG seed.
;   VDC_Update     — TrySpawn + MoveChain + AnimateChain. Один вызов = один кадр.
;   VDC_SlotPos    — для слота A считает (X,Y) центра шара.
;                    Выход: BC=X, DE=Y, CF=1 если skip (gap или t<0).
;   VDC_InsertAt   — A=target_idx, B=color. Вставить шар, проверить match.
;
; Все функции корраптят AF/BC/DE/HL; VDC_InsertAt также портит IX через
; VDC_ShiftRight_*.
; Track V2 layout (active pages выбираются через VDC_pTrackPages):
;   чистые 16K pages из 8-byte samples: Vx, Vy, tangent, flags, padding.
;   NumSamples грузится из track metadata sector в VDC_ActiveTrackSamples.
; ============================================================================

VDC_LEVEL_START_BALLS  EQU 35                            ; быстрая фаза: 35 шаров «поездом»
VDC_FAST_ADVANCE       EQU 12                            ; MoveChain ×12 за tick в fast-фазе
VDC_ABSORB_ADVANCE     EQU 8                             ; advance absorb chain: 8 px/tick (32/8=4 ticks/cell)
VDC_CELL_SIZE          EQU 32                            ; sample-units на slot.
VDC_GLOBAL_SPEED_FACTOR EQU 2                            ; поддерживается 1 или 2; множитель fast-фазы и normal-вызовов SpeedAdvance.
                ASSERT VDC_GLOBAL_SPEED_FACTOR >= 1
                ASSERT VDC_GLOBAL_SPEED_FACTOR <= 2
VDC_DECAY_NEG          EQU 2                             ; insert head slide (neg→0) быстро.
VDC_DECAY_POS          EQU 1                             ; cascade rollback (pos→0) плавно.
                                                          ; длина хорды track 1.0815 px/sample: 32×1.08 ≈ 34.6 px
                                                          ; centers, ball 32 px → gap ~2.6 px на прямой.
                                                          ; Используется в VDC_SlotT через ZL_Mul16x8.
VDC_MAX_SLOTS          EQU 192                           ; physical slot buffer: самый длинный track L22=136 cells,
                                                         ; остаётся insert/gap headroom и всё ещё помещается Main1.
                                                         ; Было 240 — избыток; 128 стало тесно для текущих
                                                         ; pack-треков. Держать синхронно с ZL_BALL_CACHE layout.
VDC_GAP_STOP           EQU #FE
VDC_GAP_CASCADE        EQU #FD
VDC_NUM_COLORS         EQU 6                             ; 6 colors; текущий PALETTED atlas хранит 6×12 spin cells.
VDC_LEVEL_CHAIN_CHANCE EQU 50                            ; level setting: 50% random single, 50% random same-color chain
; --- Подтяжка сегментов по референсу Zuma HD (BallChain.c, см. Чат.txt
; 2026-06-12). PULL = цвета по краям стыка СОВПАДАЮТ: скорость подтяжки
; разгоняется +0.4 сэмпл/кадр² до 10 сэмпл/кадр (vp хранится ×10).
; CATCH-UP = цвета разные/нет фронта: фронт-сегмент СТОИТ, зазор закрывается
; темпом продвижения цепи (хвост догоняет). При слиянии PULL-стыка — отдача
; заднего сегмента v/2.5 (BALL_WEIGHT_RATIO) и клик SND_BALLCLICK1.
VDC_PULL_ACCEL_X10     EQU 4                              ; BALL_DECC = 0.4
VDC_PULL_MAX_X10       EQU 100                            ; BALL_MAX_BACK_SPEED = 10
VDC_PULL_BASE_X10      EQU 10                             ; старт = 1 сэмпл/кадр
VDC_GAP_ACCUM_STEP     EQU 256                            ; порог подтяжки: быстрее полного слота×10
VDC_DM3_OFFSET_GAP_MAX EQU (VDC_CELL_SIZE / 2) + 2        ; разрешить fresh insert half-cell overlap, но блокировать full gap
VDC_BALLS_TARGET       EQU VDC_MAX_SLOTS                 ; потолок ёмкости; runtime spawn gate =
                                                          ; VDC_GaugeFull (level target score) + GameOver.
VDC_KZ_FRAMES          EQU 12
VDC_EXPLOSION_FRAMES   EQU 15
VDC_DUAL_LOSE_MENU_DELAY EQU 12                          ; post-empty frames перед dual lose dialog

; Значения VDC_GameState
VDC_STATE_PLAY     EQU 0                                  ; обычный gameplay
VDC_STATE_ABSORB   EQU 1                                  ; balls движутся в killzone
VDC_STATE_GAMEOVER EQU 2                                  ; GAME OVER screen
VDC_STATE_INTRO    EQU 3                                  ; level intro (LEVEL N-M + title)
VDC_STATE_PREVIEW  EQU 4                                  ; sparkle wave вдоль track перед спавном
VDC_STATE_CLOSING  EQU 5                                  ; череп закрывается (frame 11→1)
VDC_STATE_WIN      EQU 6                                  ; level clear: sparkles, bonus, следующий level
VDC_INTRO_TICKS    EQU 240                                ; ~4 сек при текущем ~59Hz video
; VDC_DialogState values для win flow (после win-анимации):
DLG_WIN_DONE       EQU 5                                  ; «LEVEL DONE» диалог, ждём OK
DLG_WIN_FADE       EQU 6                                  ; OK нажат → fade-out в чёрное, потом AdvanceToNextLevel
VDC_WIN_FADE_STEP  EQU 16                                 ; FadeAlpha += step/кадр (255/16 ≈ 16 кадров ≈ 0.2с)
VDC_PREVIEW_TICKS  EQU 193                                ; (NumSamples+trail)/SPEED = (2774+112)/15 ≈ 192.4 → закрытие сразу после влёта последней звезды
VDC_CLOSING_TICKS  EQU 22                                 ; ~0.37 сек closing anim (2 ticks per frame)
VDC_WIN_TICKS      EQU VDC_PREVIEW_TICKS                  ; fallback-таймер (когда нет аутро); при активном аутро конец = VDC_WinOutroDone
VDC_AY_ROLLING_RETRIGGER_TICKS EQU 22                     ; чуть меньше 24 AY ticks у SND_ROLLING, чтобы fast-fill не замолкал

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
                ; Слоты: VDC_MAX_SLOTS байт = GAP_STOP
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
                LD   (VDC_LoseHoldCnt),        A
                LD   (VDC_GapAccum),           A
                LD   (VDC_GapAccum + 1),       A
                LD   (VDC_GapJunction),        A
                LD   (VDC_GapDecAcc),          A
                LD   (VDC_GapPosLeft),         A
                LD   (VDC_BallsSpawned),       A
                LD   (VDC_SpawnDue),           A
                ; Cluster RNG state: remaining=0 принудит первый roll на старте.
                ; Color sentinel #FF — пока remaining=0, color не используется.
                LD   (VDC_SpawnClusterRem),    A
                LD   A, VDC_PULL_BASE_X10
                LD   (VDC_GapPullVp),          A
                LD   (VDC_GapTempo),           A
                LD   A, #FF
                LD   (VDC_SpawnClusterColor),  A
                XOR  A
                LD   (VDC_MatchScanIdx),       A
                LD   (VDC_ScanGapBusy),        A
                LD   (VDC_BridgeScanActive),   A
                LD   (VDC_DetectIgnoreOffsets), A
                LD   (VDC_RequireGapBridge),   A
                LD   (VDC_GameOverTick),       A
                LD   (VDC_AbsorbPopNote),      A
                LD   (VDC_DualLoseMenuDelay),  A
                LD   (VDC_HudMenuState),       A
                LD   (VDC_HudPointerBlock),    A
                ; WIN head-сэмплы = нет данных на старте уровня; аутро выключено
                LD   HL, #FFFF
                LD   (VDC_WinHeadS1),          HL
                LD   (VDC_WinHeadS2),          HL
                LD   (VDC_WinEmitPos1),        HL
                LD   (VDC_WinEmitPos2),        HL
                XOR  A
                LD   (VDC_WinOutroActive),     A
                LD   (VDC_ExplodeActive),      A
                ; Сброс Gauge bar: без этого GaugeScore/Full
                ; тащились с прошлого уровня через Win→AdvanceToNextLevel→VDC_Init,
                ; и новый уровень стартовал с полным баром → спавн сразу отсекался.
                LD   (VDC_GaugeFull),          A      ; A=0
                LD   (VDC_GaugeScore),         A
                LD   (VDC_GaugeScore + 1),     A
                LD   (VDC_GaugeShown),         A
                LD   (VDC_GaugeShown + 1),     A
                if RUNTIME_DIAGNOSTICS_ENABLED
                LD   (VDC_AssertCode),         A
                LD   (VDC_AssertCtx),          A
                LD   (VDC_AssertLen),          A
                LD   (VDC_AssertHSA),          A
                LD   (VDC_AssertValue),        A
                LD   (VDC_AssertFrame),        A
                LD   (VDC_AssertFrame + 1),    A
                endif
                LD   (VDC_RollingActive),      A
                LD   (VDC_RollingLoopTimer),   A
                LD   (VDC_SfxStopTimer),       A
                ; Per-level/difficulty ball-color count из settings table
                ; (поле colors +4). Раньше цвет всегда катился 0..5 (фикс. NUM=6) —
                ; ранние уровни должны иметь 4. CurrentLevel/Difficulty уже выставлены.
                CALL VDC_LoadLevelSettings            ; per-level colors/speed/start + сброс accum (Core)
                LD   A, 11                            ; KzFrame=11 (skull mouth wide open) во время intro/preview
                LD   (VDC_KzFrame),            A
                ; --- Состояния: Intro (3) → Preview (4) → Closing (5) → Play (0) ---
                ; INTRO: LEVEL N-M + title с fade-out
                ; PREVIEW: sparkle wave вдоль track, череп OPEN
                ; PLAY: транзишн КзFrame=1 (closed), шары спавнятся
                LD   A, VDC_STATE_INTRO
                LD   (VDC_GameState),          A
                LD   A, VDC_INTRO_TICKS
                LD   (VDC_IntroTick),          A
                ; Сброс stats для нового запуска уровня
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
                ; прогона (FadeLevelSelectToGameplay).
                LD   (VDC_GameSeconds),        HL
                CALL ReadRTCSeconds
                LD   (VDC_RtcLastSecond),      A
                XOR  A
                LD   (VDC_RtcNoTickFrames),    A

                ; Запомнить TRACK_NUM_SLOTS (= NumSamples / CELL_SIZE - 1) —
                ; используется как cap для HSA. NumSamples берётся из Track V2 metadata.
                LD   HL, (VDC_ActiveTrackSamples)      ; HL = NumSamples
                LD   A, VDC_CELL_SIZE                 ; A = divisor; без него TrackNumSlots ломается.
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
                if RUNTIME_DIAGNOSTICS_ENABLED
                ; Snapshot для F12-dump диагностики. Не трогать #4C89..#4C8B:
                ; это Frog RTC mix/exclude state. Final seed хранится в свободном
                ; gap после build canary, до CMD-буфера.
                CALL ReadRTCSeconds
                LD   (#4C88), A                        ; #4C88 = raw RTC sec
                LD   A, R
                LD   (VDC_SEED_SNAPSHOT_ADDR + 2), A   ; raw R register
                LD   HL, (VDC_LfsrSeed)
                LD   (VDC_SEED_SNAPSHOT_ADDR), HL      ; final seed
                endif
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
                JR   Z, .has2
                RET
.has2:          LD   A, 1
                LD   (VDC_HasSecondChain), A

                ; Двухцепочечные уровни используют тот же lead-in из настроек уровня,
                ; что и одиночные. Делить его /2 нельзя: обе цепочки имеют собственный
                ; VDC_BallsSpawned и должны независимо пройти полную быструю фазу.

                ; Скопировать freshly reset chain state во второй backing store,
                ; затем заменить только TrackNumSlots из второго Track V2 path.
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
                LD   HL, (VDC_ActiveTrackSamples)
                LD   A, VDC_CELL_SIZE
                CALL VDC_DivHLbyA
                LD   DE, VDC2_ChainLocal + (VDC_TrackNumSlots - VDC_ChainLocalStart)
                LD   A, L
                LD   (DE), A
                INC  DE
                LD   A, H
                LD   (DE), A
                ; LevelStart цепочки 2 НЕ перетираем длиной её трека — она уже
                ; унаследовала исходный lead-in из клона ChainLocal выше.
                LD   HL, (VDC_ActiveTrackSamples)
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
                ; C-рефактор: вместо копирования массивов цепочки — переключаем 5
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
; ReadRTCRegister — универсальный, A = индекс register (0=sec, 2=min, 4=hour).
; Выход: A = BCD-parsed binary value.
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
; Фаза 1 (BallsSpawned < LEVEL_START_BALLS): 12× MoveChain + 1× AnimateChain +
;   1× TrySpawn (TrySpawn внутри loop'ит). Это «поезд» влёта 35 шаров за ~90 тиков.
; Фаза 2 (BallsSpawned ≥ LEVEL_START_BALLS): 1× MoveChain каждый кадр (norm-speed
;   подобран под VDAC2 CELL_SIZE=42 — без subdivider /2 как у коллеги).
; ============================================================================
VDC_Update:
                LD   A, (Core.GS_SfxSilenceTimer)
                OR   A
                JR   Z, .timer_zero
                DEC  A
                LD   (Core.GS_SfxSilenceTimer), A
.timer_zero:
                CALL VDC_UpdateSfxStopTimer
                LD   A, (VDC_DialogState)
                CP   3
                JR   C, .upd_not_pause       ; <3 (none/retry/gameover) → обычный путь
                ; >=3: pause (3) или pause fade-out (4) — freeze gameplay, refresh
                ; RTC baseline, чтобы paused/fading seconds не считались.
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
                JP   Z, VDC_UpdateAbsorbOrRush
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
                LD   A, (GS_Present)
                OR   A
                JR   Z, .intro_no_chant
                LD   A, SND_CHANT1
                CALL GS_PlaySfx
.intro_no_chant:
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
                LD   A, VDC_AY_ROLLING_RETRIGGER_TICKS
                LD   (VDC_RollingLoopTimer), A
                RET
.upd_play:
                CALL VDC_UpdateRtcElapsed
                ; Тик счётчика игрового времени (кадры). Используется для TIME M:SS в dialog.
                LD   HL, (VDC_StatTimeFrames)
                INC  HL
                LD   (VDC_StatTimeFrames), HL
                CALL VDC_CheckKillzone
                LD   A, (VDC_BallsSpawned)
                LD   HL, VDC_LevelStart                 ; lead-in count текущего уровня
                CP   (HL)
                JR   NC, .upd_normal
                ; Fast-фаза: VDC_FAST_ADVANCE × VDC_GLOBAL_SPEED_FACTOR MoveChain/тик.
                ; В fast-фазе spawn без hsub-gate — иначе при wrap-частоте
                ; редкие spawn'ы ломают fast-фазу.
                CALL VDC_UpdateRollingLoopMaybe
                LD   B, VDC_FAST_ADVANCE * VDC_GLOBAL_SPEED_FACTOR
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
                LD   (VDC_RollingLoopTimer), A
                LD   A, SND_SILENCE
                CALL GS_PlaySfx
.upd_normal_go: ; Нормальная фаза: VDC_GLOBAL_SPEED_FACTOR × SpeedAdvance тиков/кадр.
                ; accum += speed_x100 за тик; ≥100 → один MoveChain (шаг=1, плавно).
                ; Спавн привязан к переходу через границу клетки: при ×2 speed второй
                ; тик может сразу увести HSub с 0, поэтому одного финального HSub-гейта мало.
                XOR  A
                LD   (VDC_SpawnDue), A
                CALL VDC_SpeedAdvance
                IF VDC_GLOBAL_SPEED_FACTOR >= 2
                CALL VDC_SpeedAdvance                   ; дополнительный тик для ×2
                ENDIF
                CALL VDC_AnimateChain
                JP   VDC_TrySpawnBoundaryAware

VDC_UpdateAllChains:
                ; WIN-снимок позиций/цветов шаров ДО апдейта (только в PLAY), пока
                ; цепочка ещё видима. К моменту WIN (SlotsLen==0) шаров уже нет.
                ; Вся снимок-логика — в VDC_WinSnapAllChains (read-only, свопы цепочек
                ; парные → состояние восстановлено). Поток апдейта ниже = оригинал.
                LD   A, (VDC_GameState)
                OR   A
                CALL Z, VDC_WinSnapAllChains
                LD   A, (VDC_GameState)
                CP   VDC_STATE_ABSORB
                JR   NZ, .upd_primary_normal
                CALL VDC_UpdateAbsorbOrRush            ; симметрия: chain1 может быть не-triggering chain
                JR   .upd_primary_done
.upd_primary_normal:
                CALL VDC_Update
.upd_primary_done:
                LD   A, (VDC_HasSecondChain)
                OR   A
                JP   Z, VDC_CheckWinMaybe
                LD   A, (VDC_DialogState)
                CP   3
                RET  NC                                ; pause / pause-fade freeze both chains
                LD   A, (VDC_GameState)
                OR   A
                JP   NZ, VDC_UpdateSecondAbsorbMaybe   ; ABSORB: update swapped chain through rush/absorb path
                CALL VDC_SwapChains
                CALL SetSecondTrackPage
                CALL VDC_UpdateActiveChainPlayOnly
                CALL VDC_SwapChains
                CALL SetCurrentTrackPage
                JP   VDC_CheckWinMaybe

VDC_UpdateSecondAbsorbMaybe:
                CP   VDC_STATE_ABSORB
                RET  NZ
                CALL VDC_SwapChains
                CALL SetSecondTrackPage
                CALL VDC_UpdateAbsorbOrRush
                CALL VDC_SwapChains
                JP   SetCurrentTrackPage

VDC_UpdateAbsorbOrRush:
                CALL VDC_LoseStartReady                ; ABSORB may have started before match/gap settle
                JR   NC, .uar_settled
                CALL VDC_LoseHoldBeforeKillzone
                CALL VDC_AnimateChain
                RET
.uar_settled:
                LD   A, (VDC_KzFrame)
                CP   11
                JR   NZ, .uar_rush_start
                LD   A, (VDC_LoseHoldCnt)
                CP   255
                JR   Z, .uar_absorb_ready
                LD   A, (VDC_HSub)
                OR   A
                JR   NZ, .uar_rush_start
.uar_mark_ready:
                LD   A, 255
                LD   (VDC_LoseHoldCnt), A
.uar_absorb_ready:
                CALL VDC_DualLoseHoldLastMaybe
                RET  C
                JP   VDC_UpdateAbsorb
.uar_rush_start:
                CALL VDC_CheckKillzone
                XOR  A
                LD   (VDC_ChainFreezeCnt), A
                LD   B, VDC_ABSORB_ADVANCE
.uar_loop:      PUSH BC
                LD   A, (VDC_KzFrame)
                CP   11
                LD   E, 0
                JR   NZ, .uar_arm_done
                INC  E
.uar_arm_done:  LD   A, (VDC_HSub)
                LD   C, A
                PUSH DE                                ; E = armed flag across clobbering calls
                PUSH BC                                ; C = old HSub across clobbering calls
                CALL VDC_MoveChain
                CALL VDC_CheckKillzone
                POP  BC
                POP  DE
                LD   A, E
                OR   A
                JR   Z, .uar_no_hit
                LD   A, (VDC_HSub)
                CP   C
                JR   C, .uar_hit                      ; armed skull; HSub wrapped через kill-zone
.uar_no_hit:
                POP  BC
                DJNZ .uar_loop
                RET
.uar_hit:       XOR  A
                LD   (VDC_HSub), A
                LD   A, 11
                LD   (VDC_KzFrame), A
                LD   A, 255
                LD   (VDC_LoseHoldCnt), A
                POP  BC
                RET

VDC_DualLoseHoldLastMaybe:
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   A, (VDC2_SlotsLen)
                OR   A
                RET  NZ
                LD   A, (VDC_HSub)
                CP   24
                JR   NC, .dll_maybe_hold
                OR   A
                RET
.dll_maybe_hold:
                LD   A, (VDC_DualLoseMenuDelay)
                OR   A
                JR   NZ, .dll_count
                LD   A, 6
.dll_count:     DEC  A
                LD   (VDC_DualLoseMenuDelay), A
                RET  Z
                LD   A, VDC_CELL_SIZE - 1
                LD   (VDC_HSub), A
                LD   A, 255
                LD   (VDC_HeadAbsorbAlpha), A
                SCF
                RET

VDC_DualAbsorbWaitOther:
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                LD   A, (VDC2_SlotsLen)                ; inactive chain после VDC_SwapChains
                OR   A
                RET  Z
                ; Current chain уже пуста, но другая ещё absorbed. Держим global
                ; ABSORB; final dialog/lives обрабатывает последняя chain, дошедшая
                ; до нуля.
                LD   A, VDC_STATE_ABSORB
                LD   (VDC_GameState), A
                XOR  A
                LD   (VDC_KzFrame), A
                LD   A, 255
                LD   (VDC_HeadAbsorbAlpha), A
                SCF
                RET

VDC_DualLoseDelayMaybe:
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  NZ
                LD   A, (VDC2_SlotsLen)
                OR   A
                RET  NZ
                LD   A, (VDC_DualLoseMenuDelay)
                OR   A
                JR   NZ, .dld_count
                LD   A, VDC_DUAL_LOSE_MENU_DELAY
                LD   (VDC_DualLoseMenuDelay), A
                SCF
                RET
.dld_count:     DEC  A
                LD   (VDC_DualLoseMenuDelay), A
                RET  Z
                SCF
                RET

; ----------------------------------------------------------------------------
; VDC_LoseStartReady — CF=0, когда Lose/ABSORB можно запускать.
; Lose не должен обрывать pending match-3/cascade work: все chain elements должны
; быть connected, а каждая destroy animation — committed. На dual levels inactive
; chain проверяется временным swap через normal chain API.
; ----------------------------------------------------------------------------
VDC_LoseStartReady:
                CALL VDC_LoseChainBusy
                RET  C
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                CALL VDC_SwapChains
                CALL VDC_LoseChainBusy
                LD   A, 0
                JR   NC, .lsr_other_ready
                INC  A
.lsr_other_ready:
                PUSH AF
                CALL VDC_SwapChains
                POP  AF
                OR   A
                RET  Z
                SCF
                RET

; Удержать активную цепь перед окном kill-zone: rem=65, т.е. на один sample
; до открытия черепа (rem<=64). Это отдельно от ChainFreezeCnt: freeze
; относится к cascade settle и намеренно проверяется VDC_LoseStartReady,
; а этот hold только не даёт визуально въехать в KZ раньше времени.
VDC_LoseHoldBeforeKillzone:
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_KzEndSub)
                OR   A
                JR   Z, .lh_sub_zero
                LD   A, L
                CP   2
                JR   C, .lh_zero_track
                SUB  2
                LD   (VDC_HSA), A
                LD   A, (VDC_KzEndSub)
                DEC  A
                JR   .lh_save_hsub
.lh_sub_zero:   LD   A, L
                CP   3
                JR   C, .lh_zero_track
                SUB  3
                LD   (VDC_HSA), A
                LD   A, VDC_CELL_SIZE - 1
                JR   .lh_save_hsub
.lh_zero_track: XOR  A
                LD   (VDC_HSA), A
.lh_save_hsub:  LD   (VDC_HSub), A
                LD   A, 1                              ; busy settle: keep skull closed
                LD   (VDC_KzFrame), A
                LD   A, VDC_FAST_ADVANCE * VDC_GLOBAL_SPEED_FACTOR
                LD   (VDC_LoseHoldCnt), A
                SCF
                RET

; CF=1, пока current active chain ещё имеет gaps или pending explode frames.
; Offset settling и freeze (включая pShot2) больше не обрывают проезд в KZ.
VDC_LoseChainBusy:
                LD   A, (VDC_ExplodeActive)
                OR   A
                JR   NZ, .lcb_busy                    ; match-3 fade is still visible
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .lcb_ready
                LD   A, (VDC_GapJunction)
                OR   A
                JR   NZ, .lcb_busy
                LD   A, (VDC_GapPosLeft)
                OR   A
                JR   NZ, .lcb_busy

                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   HL, (VDC_pSlots)
                LD   DE, (VDC_pExplodeFrame)
.lcb_slot_loop:
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .lcb_busy
                LD   A, (DE)
                OR   A
                JR   NZ, .lcb_busy
                INC  HL
                INC  DE
                DJNZ .lcb_slot_loop

.lcb_ready:
                XOR  A
                RET
.lcb_busy:
                SCF
                RET

VDC_UpdateActiveChainPlayOnly:
                CALL VDC_CheckKillzone
                LD   A, (VDC_BallsSpawned)
                LD   HL, VDC_LevelStart
                CP   (HL)
                JR   NC, .upd2_normal
                LD   B, VDC_FAST_ADVANCE * VDC_GLOBAL_SPEED_FACTOR
.upd2_fast:     PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd2_fast
                CALL VDC_AnimateChain
                CALL VDC_TrySpawn_NoHsubGate
                RET
.upd2_normal:   XOR  A
                LD   (VDC_SpawnDue), A
                CALL VDC_SpeedAdvance
                IF VDC_GLOBAL_SPEED_FACTOR >= 2
                CALL VDC_SpeedAdvance                   ; дополнительный тик для ×2
                ENDIF
                CALL VDC_AnimateChain
                JP   VDC_TrySpawnBoundaryAware

; ============================================================================
; WIN-снимок: сэмпл ГОЛОВНОГО шара (ближайшего к килл-зоне) каждой цепочки.
; Снимается каждый PLAY-кадр ДО апдейта. keep-last-non-empty: обновляем только
; если в цепочке есть видимые шары (иначе храним прошлый кадр — к WIN цепочка
; пуста). Голова = максимальный track-сэмпл среди видимых шаров (фронт цепи).
; Свопы цепочек парные → read-only по отношению к состоянию цепочек.
; ============================================================================
VDC_WinSnapAllChains:
                CALL VDC_SnapshotWinChain              ; chain1 (текущий трек активен)
                JR   C, .c2                            ; нет видимых шаров → храним прошлый
                LD   (VDC_WinHeadS1), HL
.c2:            LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                CALL VDC_SwapChains
                CALL SetSecondTrackPage
                CALL VDC_SnapshotWinChain              ; chain2
                JR   C, .c2_keep
                LD   (VDC_WinHeadS2), HL               ; запись в резидент — до возврата цепочки
.c2_keep:       CALL VDC_SwapChains
                JP   SetCurrentTrackPage

; VDC_SnapshotWinChain — макс. track-сэмпл видимых шаров текущей активной цепочки.
; Выход: CF=0 + HL = head sample (фронт), если есть видимый шар; CF=1 если нет.
VDC_SnapshotWinChain:
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .none
                LD   B, A                              ; B = число слотов
                LD   C, 0                              ; C = индекс слота
                LD   HL, 0
                LD   (VDC_WinTmpMax), HL
                XOR  A
                LD   (VDC_WinTmpFound), A
.snap_loop:     PUSH BC
                ; 1. Проверяем маркер/gap
                LD   HL, (VDC_pSlots)
                LD   B, 0
                ADD  HL, BC
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .snap_skip                    ; пропускаем если это gap/маркер
                
                ; 2. Вычисляем t
                LD   A, C
                CALL VDC_SlotT                         ; HL = t
                
                ; 3. Пропускаем если t < 0
                BIT  7, H
                JR   NZ, .snap_skip
                
                ; 4. Ограничить t к NumSamples-1
                PUSH HL
                LD   DE, (VDC_ActiveTrackSamples)
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .t_in
                LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL
.t_in:
                ; 5. Обновляем максимум
                LD   A, 1
                LD   (VDC_WinTmpFound), A
                LD   DE, (VDC_WinTmpMax)
                AND  A
                SBC  HL, DE                            ; t - max
                JR   C, .snap_skip                     ; t < max → пропускаем
                ADD  HL, DE                            ; восстанавливаем t
                LD   (VDC_WinTmpMax), HL               ; новый максимум
.snap_skip:     POP  BC
                INC  C
                DJNZ .snap_loop
                LD   A, (VDC_WinTmpFound)
                OR   A
                JR   Z, .none
                LD   HL, (VDC_WinTmpMax)
                AND  A                                 ; CF=0
                RET
.none:          SCF
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

VDC_UpdateRollingLoopMaybe:
                LD   A, (GS_Present)
                OR   A
                RET  NZ
                LD   A, (VDC_RollingLoopTimer)
                OR   A
                JR   Z, .restart
                DEC  A
                LD   (VDC_RollingLoopTimer), A
                RET  NZ
.restart:       LD   A, VDC_AY_ROLLING_RETRIGGER_TICKS
                LD   (VDC_RollingLoopTimer), A
                LD   A, SND_ROLLING
                JP   GS_PlaySfx

; ============================================================================
; VDC_UpdateRtcElapsed — real-time game clock по RTC seconds.
;   Добавляет delta seconds с 0..59 wrap. Вызывается только во время PLAY; pause
;   обновляет VDC_RtcLastSecond без накопления, поэтому pause time не считается.
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
; VDC_SlotT — для A=i считает t = (HSA-i)*32 + HSub + sext(offsets[i]).
; Выход: HL = signed 16-bit t.  AF/DE клобает.
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
                ; после match-3/cascade с HsaDec).
                LD   HL, #8000
                RET
.delta_ok:
                LD   H, 0 : LD L, A                    ; HL = delta
                ; VDC_CELL_SIZE=32: избегаем generic ZL_Mul16x8 в hot path
                ; VDC_SlotPos. Выполняется один раз на rendered/collided ball.
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
; VDC_SlotPos — для A=i возвращает центр шара (X,Y) из active Track V2 sample[t].
;   Выход: BC = X (signed word), DE = Y (signed word), CF = 0 если рисуем,
;        CF = 1 если skip (gap или t<0).
;   AF, HL clobber.
;
; VDC_SlotPosAllowGap — тот же расчёт но БЕЗ gap-skip. Используется для
; gap-bonus tracking (нужна позиция самой gap-ячейки чтобы померить distance
; bullet'а до пустоты в цепи).
; ============================================================================
VDC_SlotPos:
                ; --- пропуск gap-ячейки ---
                LD   C, A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .not_gap
                SCF                                    ; CF=1, пропуск
                RET
.not_gap:
                LD   A, C
VDC_SlotPosAllowGap:
                ; вход без пропуска gap-ячейки. Вызывающий обязан передать A=i.
                CALL VDC_SlotT                         ; HL = t
                ; t < 0 → пропуск
                BIT  7, H
                JR   Z, .t_nonneg
                SCF
                RET
.t_nonneg:
                ; t >= NumSamples → прижать к NumSamples-1
                PUSH HL
                LD   DE, (VDC_ActiveTrackSamples)      ; NumSamples
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .t_in
                LD   HL, (VDC_ActiveTrackSamples)
                DEC  HL
.t_in:          ; HL = t (ограничено). Читать sample через Core-resident helper:
                ; там живёт Track V2 page lookup, а этот hot path остаётся маленьким —
                ; Main1/slot3 почти заполнен. Core всегда mapped в slot 1, поэтому
                ; tail-call resolves at runtime. Helper: выход BC=X, DE=Y, CF=0,
                ; sets VDC_LastT / VDC_LastTangent.
                JP   VDC_ReadSampleAtHL

; ============================================================================
; VDC_TrySpawn — спавн нового шара в хвост (если разрешено).
;   Условия: SlotsLen<MAX, BallsSpawned<TARGET, HSA>=SlotsLen, HSub==0.
; ============================================================================
VDC_TrySpawn:
                ; Публичный вход: с gate HSub==0 (синхронно с Python try_spawn).
                ; Fast-фаза обходит gate через VDC_TrySpawn_NoHsubGate.
                LD   A, (VDC_HSub)
                OR   A
                RET  NZ
                ; fallthrough
VDC_TrySpawn_NoHsubGate:
                ; Zuma bar full → spawn gate OFF (по wiki/manual).
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

                ; SlotsLen > 0 AND offsets[tail-1] > 0 → не спавним (хвост сдвинут
                ; вперёд head-comp'ом, ждём settle). ОТРИЦАТЕЛЬНЫЙ offset хвоста
                ; (rear-comp догона / отдача слияния) спавн НЕ блокирует: хвост
                ; скользит ВПЕРЁД, новый шар наследует offset и встаёт встык —
                ; иначе во время догона выдача обрывается на всю длину закрытия.
                LD   A, B
                OR   A
                JR   Z, .spawn_no_tail_check
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   Z, .spawn_no_tail_check
                RET  P                                 ; положительный → ждём settle
.spawn_no_tail_check:
                ; --- RNG уровня:
                ; RTC seconds seed используется только в VDC_Init.
                ; Runtime дальше идёт через детерминированный LFSR.
                ; Правило уровня: 50% одиночный случайный цвет ИЛИ 50% серия
                ; одного случайного цвета длиной 1..VDC_NUM_COLORS-1.
                LD   A, (VDC_SpawnClusterRem)
                OR   A
                JR   Z, .spawn_roll_new
                DEC  A
                LD   (VDC_SpawnClusterRem), A
                LD   A, (VDC_SpawnClusterColor)
                LD   B, A
                JR   .spawn_color_ready
.spawn_roll_new:
                CALL VDC_RandomColor                   ; A = бросок gate 0..NUM-1
                BIT  0, A                              ; нечёт/чёт ≈ 50/50 при NUM=6
                JR   Z, .spawn_single_random           ; 50% одиночный случайный шар
                ; путь cluster'а — переброс цвета, пока он == предыдущему cluster'у.
                ; (VDC_SpawnClusterColor) = предыдущий цвет (или сторожевое #FF на init).
.cluster_color_reroll:
                CALL VDC_RandomColor                   ; кандидат цвета серии
                LD   HL, VDC_SpawnClusterColor
                CP   (HL)                              ; == предыдущему?
                JR   Z, .cluster_color_reroll          ; → переброс
                LD   (HL), A                           ; принять цвет
                CALL VDC_RandomClusterLength           ; A = полная длина 1..NUM-1
                                                       ; (важно: ZL_Mul16x8 портит B/C —
                                                       ; читаем color из памяти ниже)
                DEC  A                                 ; текущий spawn — первый шар
                LD   (VDC_SpawnClusterRem), A
                JR   .spawn_color_ready
.spawn_single_random:
                ; одиночный путь — тоже переброс, чтобы два соседних cluster/single
                ; никогда не были одного цвета.
.single_color_reroll:
                CALL VDC_RandomColor
                LD   HL, VDC_SpawnClusterColor
                CP   (HL)
                JR   Z, .single_color_reroll
                LD   (HL), A                           ; принять цвет
                XOR  A
                LD   (VDC_SpawnClusterRem), A
.spawn_color_ready:
                LD   A, (VDC_SpawnClusterColor)        ; перечитать цвет из памяти
                                                       ; (B клобан RandomColor/Mul16x8)
                LD   B, A
                ; B = выбранный цвет. Не режем 3+ одинаковых на spawn: в оригинальной
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

                ; --- offsets[SlotsLen] = offsets[SlotsLen-1], если SlotsLen>0, иначе 0 ---
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
                ; 3+ одного цвета и моментально auto-match'ит → цепь не растёт.
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
                JR   NZ, .spawn_done
                DEC  (HL)                              ; насыщение на 255; без wrap в fast-фазе
.spawn_done:
                RET                                    ; один spawn на тик (= Python коллеги).
                                                       ; Множественный spawn даёт мгновенный рост цепи = дёрганость.

; Нормальная фаза: если в этом кадре уже был переход HSub 31→0, разрешаем
; spawn без повторной проверки текущего HSub. Иначе используем обычный gate.
VDC_TrySpawnBoundaryAware:
                LD   A, (VDC_SpawnDue)
                OR   A
                JP   Z, VDC_TrySpawn
                XOR  A
                LD   (VDC_SpawnDue), A
                JP   VDC_TrySpawn_NoHsubGate

; ============================================================================
; VDC_MoveChain — HSub += 1 (1 sample), если цепь не frozen; wrap → HSA++.
; Шаг всегда 1 — плавное движение. Скорость регулируется частотой вызовов
; (VDC_GLOBAL_SPEED_FACTOR × SpeedAdvance тиков/кадр + множитель fast-фазы).
; ============================================================================
VDC_MoveChain:
                LD   A, (VDC_LoseHoldCnt)
                OR   A
                JR   Z, .mc_no_lose_hold
                DEC  A
                LD   (VDC_LoseHoldCnt), A
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                RET  Z
                DEC  A
                LD   (VDC_ChainFreezeCnt), A
                RET
.mc_no_lose_hold:
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                JR   Z, .mc_check_gap_hold
                DEC  A
                LD   (VDC_ChainFreezeCnt), A
                RET
.mc_check_gap_hold:
                LD   A, (VDC_GameState)
                OR   A
                JR   NZ, .mc_no_freeze                  ; не стопорим lose/absorb
                ; Внутренняя дырка (шар -> GAP -> шар) не имеет права ехать
                ; к kill-zone обычным HSub++. VDC_GapJunction здесь ненадёжен:
                ; это тип текущего стыка, а не факт наличия живой дырки.
                CALL VDC_InternalGapExists
                RET  C
.mc_check_pos_hold:
                ; После удаления marker'а передний сегмент удерживается
                ; положительным offset. Пока он не дотаял, HSub тоже держим,
                ; иначе обычный ход снова сдвинет дырку вперёд.
                LD   A, (VDC_GapPosLeft)
                OR   A
                RET  NZ
.mc_no_freeze:
                LD   A, (VDC_HSub)
                INC  A
                CP   VDC_CELL_SIZE
                JR   C, .mc_save_sub
                XOR  A
                LD   (VDC_HSub), A
                INC  A
                LD   (VDC_SpawnDue), A
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
                XOR  A
                LD   (VDC_ExplodeActive), A
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
                ; Чистый offset для закрытия гэпа — слот стал маркером и больше
                ; не рендерится (обнулять раньше нельзя: прыжок взрыва).
                LD   A, (VDC_SlotsLen)
                SUB  B
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                LD   (HL), 0
                POP  BC
                POP  HL
                JR   .ac_explode_next
.ac_explode_save:
                LD   (HL), A
                LD   A, 1
                LD   (VDC_ExplodeActive), A
.ac_explode_next:
                INC  HL
                DJNZ .ac_explode
.ac_after_explode:
                ; --- 1. decay offsets — ДРОБНО-ТОЧНЫЙ темп GapTempo/10 px/кадр
                ; с накопителем остатка. Каденция шагов копит сэмплы точно (×10),
                ; а усечённый vp/10 терял до 0.9px/кадр на разгоне → к слиянию
                ; копился хвост ~13px, скорость рушилась 10→1 px/кадр = рывок на
                ; каждом стыке. PULL (junction=1): тают положительные (front-comp);
                ; CATCH-UP (junction=2): тают отрицательные (rear-comp) тем же
                ; точным темпом цепи; прочие — как раньше (1 / DECAY_NEG).
                LD   A, (VDC_GapDecAcc)
                LD   HL, VDC_GapTempo
                ADD  A, (HL)                           ; A = остаток + темп (≤109)
                LD   C, 0
.ac_dec_div:    CP   10
                JR   C, .ac_dec_rem
                SUB  10
                INC  C                                 ; C = px декея кадра (0..10)
                JR   .ac_dec_div
.ac_dec_rem:    LD   (VDC_GapDecAcc), A                ; новый остаток 0..9
                ; Положительные тают точным темпом ВСЕГДА, кроме догона: при
                ; PULL это скорость подтяжки; при junction=0 — последний темп
                ; (доезд хвоста компенсаций после слияния, см. .ac_gap_none);
                ; при каскадном матче — темп нового разгона (= свежий goBack
                ; референса). Иначе финальная клетка слияния ползла 1px/кадр.
                LD   D, C                              ; D = POS-декей = точный темп
                LD   E, VDC_DECAY_NEG                  ; E = NEG-декей по умолчанию
                LD   A, (VDC_GapJunction)
                CP   2
                JR   NZ, .ac_dec_rates_ok
                LD   D, 1                              ; догон: положительные «как раньше»
                LD   E, C                              ; CATCH-UP: точный темп для отрицательных
.ac_dec_rates_ok:
                LD   C, 0                              ; C = флаг «положительные остались»
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ac_dec_flag
                LD   B, A
                LD   HL, (VDC_pOffsets)
.ac_decay:
                LD   A, (HL)
                OR   A
                JR   Z, .ac_decay_skip
                BIT  7, A
                JR   NZ, .ac_decay_neg
                SUB  D                                 ; pos (front-comp подтяжки)
                JR   C, .ac_decay_zero                 ; clamp 0
                JR   Z, .ac_decay_store                ; дотаял ровно в 0
                LD   C, 1                              ; ещё положительный — доезд не закончен
                JR   .ac_decay_store
.ac_decay_zero: XOR  A
                JR   .ac_decay_store
.ac_decay_neg:  ADD  A, E                              ; neg (insert slide / rear-comp)
                JR   Z, .ac_decay_store
                BIT  7, A
                JR   NZ, .ac_decay_store               ; ещё отрицательный
                XOR  A                                 ; overshoot → 0
.ac_decay_store:
                LD   (HL), A
.ac_decay_skip:
                INC  HL
                DJNZ .ac_decay
.ac_dec_flag:   LD   A, C
                LD   (VDC_GapPosLeft), A
.ac_after_decay:
                ; --- 2. Подтяжка (референс Zuma HD): тип стыка → темп → аккумулятор;
                ; порог VDC_GAP_ACCUM_STEP → DoGapStep. PULL: vp разгоняется 1→10
                ; сэмпл/кадр (+0.4/кадр²); CATCH-UP: темп = скорость цепи (фронт
                ; «стоит», хвост догоняет); нет гэпов — сброс разгона.
                CALL VDC_GapJunctionUpdate
                LD   A, (VDC_GapJunction)
                OR   A
                JR   NZ, .ac_gap_have
.ac_gap_none:   LD   A, VDC_PULL_BASE_X10
                LD   (VDC_GapPullVp), A
                LD   HL, 0
                LD   (VDC_GapAccum), HL
                ; Темп НЕ сбрасываем, пока доезжают положительные комп-офсеты
                ; последнего PULL (финальная клетка слияния) — иначе хвост
                ; в 32px ползёт базовым 1px/кадр = «летит-замирает».
                LD   A, (VDC_GapPosLeft)
                OR   A
                JR   NZ, .ac_no_gap_step
                LD   A, VDC_PULL_BASE_X10
                LD   (VDC_GapTempo), A
                JR   .ac_no_gap_step
.ac_gap_have:   CP   1
                JR   NZ, .ac_gap_catchup
                LD   A, (VDC_GapPullVp)
                ADD  A, VDC_PULL_ACCEL_X10
                CP   VDC_PULL_MAX_X10 + 1
                JR   C, .ac_vp_ok
                LD   A, VDC_PULL_MAX_X10
.ac_vp_ok:      LD   (VDC_GapPullVp), A
                LD   (VDC_GapTempo), A                 ; декей = скорость подтяжки
                LD   E, A
                LD   D, 0
                JR   .ac_gap_accum
.ac_gap_catchup:
                LD   A, VDC_PULL_BASE_X10              ; разгон подтяжки не копится
                LD   (VDC_GapPullVp), A
                LD   A, (VDC_LevelSpeed)
                LD   L, A
                LD   H, 0
                LD   A, 5
                CALL VDC_DivHLbyA                      ; speed_x100/5 = сэмпл/кадр ×10
                                                       ; УЖЕ с глобальным ×2: темп цепи =
                                                       ; speed/100 × GLOBAL(2) → ×10 = speed/5.
                                                       ; Второй ×2 здесь давал догон вдвое
                                                       ; быстрее цепи → кламп rear-comp → рывки.
                EX   DE, HL                            ; DE = темп догона
                LD   A, E
                LD   (VDC_GapTempo), A                 ; декей хвоста = темп цепи (≤20)
.ac_gap_accum:  LD   HL, (VDC_GapAccum)
                ADD  HL, DE
                LD   DE, VDC_GAP_ACCUM_STEP
                AND  A
                SBC  HL, DE
                JR   C, .ac_gap_keep
                LD   (VDC_GapAccum), HL
                CALL VDC_DoGapStep
                JR   .ac_no_gap_step
.ac_gap_keep:   ADD  HL, DE
                LD   (VDC_GapAccum), HL
.ac_no_gap_step:
                ; --- 3. Persistent scan. ---
                CALL VDC_ScanForNewMatch
                ; --- 4. Ограничить offset invariant каждый кадр (покрывает InsertAt
                ; head_comp/cap_compensate, DoGapStep STOP/CASCADE +CS shifts,
                ; и любые другие пути модификации offsets) ---
                CALL ClampOffsetOrder
                ; --- 4.5. Очистить stale Shot2 если cascade chain завершён.
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
; VDC_ClearStaleShot2 — если cascade chain полностью завершён, очистить все Shot2.
; Cascade завершён ⇔ ChainFreezeCnt == 0 AND нет GAP_STOP/CASCADE markers в slots
; AND нет ExplodeFrame > 0 (никаких pending animations).
; ============================================================================
VDC_ClearStaleShot2:
                LD   A, (VDC_ChainFreezeCnt)
                OR   A
                RET  NZ                                ; freeze active → cascade в процессе
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z                                  ; пустая chain
                LD   B, A                              ; счётчик итераций
                LD   HL, (VDC_pSlots)
                LD   DE, (VDC_pExplodeFrame)
.css_check:     LD   A, (HL)
                CP   VDC_NUM_COLORS                    ; >= NUM_COLORS → маркер gap
                RET  NC                                ; chain имеет markers → cascade in progress
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
                ; Cascade complete — очистить все Shot2
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   HL, (VDC_pShot2)
.css_clear:     LD   (HL), 0
                INC  HL
                DJNZ .css_clear
                RET

; Вход: A=index. Выход: NZ если offset[index] или соседний offset ещё не 0.
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
                ; Shown < Score → +STEP, ограничить Score
                LD   HL, (VDC_GaugeShown)
                LD   BC, VDC_GAUGE_SHOWN_STEP
                ADD  HL, BC
                ; ограничение: если HL > Score → HL = Score
                LD   DE, (VDC_GaugeScore)
                PUSH HL
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .tg_save                        ; HL < Score → ок
                LD   HL, (VDC_GaugeScore)               ; ограничение
.tg_save:       LD   (VDC_GaugeShown), HL
                RET
.tg_decrement:  ; Restart / Game Over reset: GaugeScore < GaugeShown → быстрый откат
                LD   HL, (VDC_GaugeScore)
                LD   (VDC_GaugeShown), HL
                RET

; ============================================================================
; VDC_DetectMatch3 — для idx в (TmpInsIdx) ищет run >= 3 одинаковых цветов
; вокруг idx с offset gap check'ом. Выход: A=1 если матч (TmpML/TmpMR/TmpMC заполнены),
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
                JP   NZ, .dm3_no                       ; уже взрывается

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
                if RUNTIME_DIAGNOSTICS_ENABLED
                PUSH BC
                CALL LogMatch3
                POP  BC
                endif
                PUSH BC
                ; HD-ref BallChain.c использует combo для выбора ballsdestroyed1..5,
                ; затем overlay chime1 с pitch 0,+2,+4,+6,+8.
                LD   A, (VDC_TmpMC_Color)
                LD   HL, VDC_StatPrevMatchColor
                CP   (HL)
                JR   Z, .m3_sfx_same_color
                XOR  A                                  ; combo = 0
                JR   .m3_sfx_combo_ready
.m3_sfx_same_color:
                LD   A, (VDC_StatCombos)
                INC  A                                  ; combo после этого match
.m3_sfx_combo_ready:
                LD   C, A                               ; C = unclamped combo
                CP   4
                JR   C, .m3_sfx_idx_ok
                LD   A, 4
.m3_sfx_idx_ok:
                ADD  A, SND_BALLSDESTROYED1
                CALL GS_PlaySfx
                LD   A, C
                CP   4
                JR   C, .m3_sfx_pitch_ok
                LD   A, 4
.m3_sfx_pitch_ok:
                ADD  A, A                               ; semitone pitch = combo * 2
                ADD  A, GS_SFX_NOTE
                LD   C, A
                LD   A, SND_CHIME1
                CALL GS_PlaySfxNote
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
                LD   (HL), A                            ; сохранить current color
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
                PUSH HL
                LD   A, SND_CHAIN1
                CALL GS_PlaySfx
                POP  HL
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
                CALL Score_Add24                       ; HL=delta; 24-bit score += HL + extra-life
                POP  HL
                LD   DE, (VDC_GaugeScore)
                ADD  HL, DE
                LD   (VDC_GaugeScore), HL
                CALL GetCurrentTargetScore             ; DE = per-level target; портит HL
                LD   HL, (VDC_GaugeScore)               ; перечитать GaugeScore — CALL выше испортил HL
                AND  A
                SBC  HL, DE                             ; GaugeScore - target; CF=1 if still below
                JR   C, .m3_gauge_not_full
                LD   A, (VDC_GaugeFull)
                OR   A
                JR   NZ, .m3_gauge_set_full
                LD   A, SND_CHORAL1
                CALL GS_PlaySfx
.m3_gauge_set_full:
                LD   A, 1
                LD   (VDC_GaugeFull), A
.m3_gauge_not_full:
                POP  BC                                ; восстановить B = marker (GAP_STOP/CASCADE)

                ; ExplodeFrame[lb..rb] = 1, ExplodeMarker[lb..rb] = B.
                ; Slots stay as colors until VDC_AnimateChain finalizes them.
                LD   A, 1
                LD   (VDC_ExplodeActive), A
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

                ; Offsets матч-рана НЕ обнуляем здесь: шары/взрывы рендерятся ещё
                ; VDC_EXPLOSION_FRAMES кадров и обязаны доезжать своим decay'ем —
                ; мгновенное обнуление прыгало взрывом на недотаявшую компенсацию
                ; (до 32px). Чистый 0 ставится при финализации слот→маркер
                ; (.ac_explode), когда слот уже невидим.

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
                ; Свежий взрыв → подтяжка стартует «с нуля»: аккум и разгон сброс.
                ; ТЕМП НЕ ТРОГАЕМ: новый гэп появится только после финализации
                ; взрыва (EXPLOSION_FRAMES кадров junction=0) — недотаявшие
                ; компенсации прошлого PULL должны доехать прежним темпом,
                ; иначе они ползут 1px/кадр весь взрыв (рывок «летит-замирает»).
                XOR  A
                LD   (VDC_GapAccum), A
                LD   (VDC_GapAccum + 1), A
                LD   (VDC_GapDecAcc), A
                LD   A, VDC_PULL_BASE_X10
                LD   (VDC_GapPullVp), A
                ; Freeze до первого DoGapStep. Explosion завершается после
                ; VDC_EXPLOSION_FRAMES; если разморозить на 15-м кадре, пока gap
                ; ещё открыт, head-сегмент уедет вперёд через дыру.
                LD   A, VDC_CELL_SIZE
                LD   (VDC_ChainFreezeCnt), A
                LD   A, 1
                RET
VDC_CheckMatch3_No:
                XOR  A
                RET

; ============================================================================
; VDC_DoGapStep — обрабатывает ОДИН маркер за вызов. Pass 1: STOP от tail
; (right→left), удаляет slot, HSA--, компенсация head. Pass 2 (если STOP не было):
; CASCADE от head (left→right), то же + ChainFreezeCnt = CELL_SIZE.
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
                ; CATCH-UP стык (цвета разные / нет фронта): фронт-сегмент СТОИТ —
                ; без HsaDec и front-comp; задний сегмент компенсируется назад
                ; и доезжает decay'ем (хвост догоняет, референс Zuma HD).
                LD   A, (VDC_GapJunction)
                CP   2
                JR   Z, .dgs_stop_catchup
                CALL VDC_HsaDec                        ; HSA-- если >0

                ; offsets[0..K-1] = min(off[j]+CS, CS) — компенсация head
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_stop_no_off
                LD   B, A                              ; B = K
                LD   HL, (VDC_pOffsets)
.dgs_stop_off:
                ; Python: s.offsets[k] = min(s.offsets[k] + CELL_SIZE, 2*CELL_SIZE)
                ; Кап 2×CELL (не CELL): при разгоне PULL шаг приходит раньше, чем
                ; дотаял прошлый +CELL; кап в CELL срезал остаток → микро-рывок
                ; головы вперёд на каждом шаге. Перенос остатка = плавно; баланс
                ; притока (CELL за шаг) и декея (vp/10·период = CELL) держит
                ; offset в пределах второй клетки.
                ; off ∈ [-CELL..2*CELL] → сумма ∈ [0..96] без 8-бит wrap'а —
                ; хватает простого беззнакового сравнения. (Старый вариант
                ; PUSH AF/XOR/CP/POP AF был сломан: POP AF восстанавливал флаги
                ; ADD, затирая CP, и кламп срабатывал всегда.)
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE * 2 + 1
                JR   C, .dgs_stop_off_save             ; A ≤ 2*CELL_SIZE → save
                LD   A, VDC_CELL_SIZE * 2              ; cap
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
                JP   VDC_GapMergeCheckRecoil           ; PULL-слияние? → отдача + клик

.dgs_stop_catchup:
                CALL VDC_GapRearExists
                JR   NC, .dgs_stop_no_rear             ; гэп у хвоста: заднего сегмента
                                                       ; нет — чистая уборка маркера,
                                                       ; цепь НЕ замораживаем (иначе в
                                                       ; зелёной фазе без спавна каждый
                                                       ; концевой маркер стопит цепь = рывки)
                LD   A, VDC_CELL_SIZE
                CALL VDC_GapRearComp
                ; Фронт СТОИТ весь догон (референс: сегмент без толкача
                ; останавливается): freeze глушит hsub, задний сегмент доезжает
                ; чистым decay'ем (DECAY_NEG = скорость цепи на max speed).
                LD   A, VDC_CELL_SIZE
                LD   (VDC_ChainFreezeCnt), A
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                CALL VDC_SetShot2OnNeighbors
                JP   .dgs_backfill
.dgs_stop_no_rear:
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                JP   VDC_SetShot2OnNeighbors

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
                if RUNTIME_DIAGNOSTICS_ENABLED
                CALL LogCascadeTrigger
                endif
                CALL VDC_RemoveSlotAt
                LD   A, (VDC_GapJunction)
                CP   2
                JR   Z, .dgs_casc_catchup              ; разные цвета → хвост догоняет
                CALL VDC_HsaDec

                ; head comp
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_casc_no_off
                LD   B, A
                LD   HL, (VDC_pOffsets)
.dgs_casc_off:
                ; Python: s.offsets[k] = min(2*CELL_SIZE, s.offsets[k] + CELL_SIZE)
                ; Кап 2×CELL — перенос недотаявшего остатка (см. .dgs_stop_off),
                ; иначе разгон PULL рвёт движение головы микро-рывками.
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE * 2 + 1
                JR   C, .dgs_casc_off_save             ; A ≤ 2*CELL_SIZE → save
                LD   A, VDC_CELL_SIZE * 2              ; cap
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
                JP   VDC_GapMergeCheckRecoil           ; PULL-слияние? → отдача + клик

.dgs_casc_catchup:
                CALL VDC_GapRearExists
                JR   NC, .dgs_casc_no_rear             ; гэп у хвоста — без freeze/comp
                LD   A, VDC_CELL_SIZE
                CALL VDC_GapRearComp
                LD   A, VDC_CELL_SIZE                  ; freeze (как .dgs_casc_no_off)
                LD   (VDC_ChainFreezeCnt), A
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                CALL VDC_SetShot2OnNeighbors
                JR   .dgs_backfill
.dgs_casc_no_rear:
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                JP   VDC_SetShot2OnNeighbors
.dgs_backfill:
                ; CATCH-UP-шаг съел клетку: задний сегмент уехал на +CELL вперёд,
                ; а HSub-гейт выдаёт максимум 1 шар/клетку движения цепи — без
                ; немедленного доспавна выдача отстаёт на клетку за каждый шаг
                ; и цепь «рвётся» у жерла. ВАЖНО (2026-06-13): VDC_TrySpawn_NoHsubGate
                ; первым делом проверяет GaugeFull → при полной шкале (= путь к WIN)
                ; доспавн no-op, цепь штатно пустеет до SlotsLen=0. Доспавн win НЕ
                ; ломает — НЕ удалять (был ложно обвинён, см. Чат.txt).
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ                                ; только в PLAY (не в absorb/win)
                JP   VDC_TrySpawn_NoHsubGate

; ----------------------------------------------------------------------------
; VDC_GapJunctionUpdate — определить стык, который закроет VDC_DoGapStep
; (правила выбора цели = его же: последний GAP_STOP; иначе первый CASCADE),
; и ТИП закрытия по цветам краёв рана (референс Zuma HD, BallChain.c —
; магнетизм только ОДИНАКОВЫХ цветов):
;   VDC_GapJunction: 0=гэпов нет / 1=PULL (цвета равны) / 2=CATCH-UP.
; Зовётся раз в кадр из VDC_AnimateChain (до каденции подтяжки).
; ----------------------------------------------------------------------------
VDC_GapJunctionUpdate:
                XOR  A
                LD   (VDC_GapJunction), A
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                DEC  A
                LD   C, A                              ; C = idx (от len-1 вниз)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
.gju_stop:      LD   A, (HL)
                CP   VDC_GAP_STOP
                JR   Z, .gju_found
                LD   A, C
                OR   A
                JR   Z, .gju_casc
                DEC  C
                DEC  HL
                JR   .gju_stop
.gju_casc:      LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   C, 0
                LD   HL, (VDC_pSlots)
.gju_cscan:     LD   A, (HL)
                CP   VDC_GAP_CASCADE
                JR   Z, .gju_found
                INC  HL
                INC  C
                DJNZ .gju_cscan
                RET                                    ; гэпов нет (junction=0)
.gju_found:     ; C = индекс гэп-слота, HL = &Slots[C]. Левый край рана:
                LD   B, C
                PUSH HL
.gju_left:      LD   A, B
                OR   A
                JR   Z, .gju_left_end
                DEC  HL
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .gju_left_end                  ; A = цвет фронта
                DEC  B
                JR   .gju_left
.gju_left_end:  POP  HL                                ; HL = &Slots[C]
                LD   E, A                              ; E = цвет слева (мусор, если B=0)
                LD   A, B
                OR   A
                JR   Z, .gju_catchup                   ; фронт-сегмента нет → догон
                LD   D, C                              ; правый край рана: D = бегущий idx
.gju_right:     LD   A, (VDC_SlotsLen)
                DEC  A
                CP   D
                JR   Z, .gju_catchup                   ; ран до хвоста — справа никого
                INC  HL
                INC  D
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .gju_right                    ; ещё маркер
                CP   E                                 ; цвет тыла == цвету фронта?
                JR   NZ, .gju_catchup
                LD   A, 1                              ; PULL — магнетизм цвета
                LD   (VDC_GapJunction), A
                RET
.gju_catchup:   LD   A, 2
                LD   (VDC_GapJunction), A
                RET

; ----------------------------------------------------------------------------
; VDC_InternalGapExists — CF=1 если внутри цепи есть живая дырка:
;   живой шар -> один или больше GAP marker'ов -> живой шар.
; CF=0 для хвостовой уборки marker'ов и для дырки до первого живого шара.
; ----------------------------------------------------------------------------
VDC_InternalGapExists:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A
                LD   HL, (VDC_pSlots)
                LD   C, 0                              ; bit0=видели шар, bit1=после него был GAP
.ige_loop:
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .ige_live
                BIT  0, C
                JR   Z, .ige_next
                SET  1, C
                JR   .ige_next
.ige_live:
                BIT  1, C
                JR   NZ, .ige_yes
                SET  0, C
.ige_next:
                INC  HL
                DJNZ .ige_loop
                AND  A
                RET
.ige_yes:
                SCF
                RET

; ----------------------------------------------------------------------------
; VDC_GapRearExists — CF=1 если после удаления гэп-слота за стыком есть ХОТЬ
; ОДИН живой шар (Slots[j] < NUM_COLORS для j в [TmpGapIdx..len-1], маркеры
; пропускаются). CF=0 — за стыком только маркеры/пусто (хвостовая уборка).
; ----------------------------------------------------------------------------
VDC_GapRearExists:
                LD   A, (VDC_SlotsLen)
                LD   B, A
                LD   A, (VDC_TmpGapIdx)
                CP   B
                RET  NC                                ; idx >= len → CF=0
                LD   C, A                              ; C = j
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
.gre_loop:      LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  C                                 ; цвет → CF=1
                INC  HL
                INC  C
                LD   A, C
                CP   B
                JR   C, .gre_loop
                OR   A                                 ; дошли до конца → CF=0
                RET

; ----------------------------------------------------------------------------
; VDC_GapRearComp — off[j] -= A для ВСЕХ j от TmpGapIdx до КОНЦА цепи (включая
; маркеры — их offsets не рендерятся, но индексный сдвиг удаления телепортит
; t КАЖДОГО слота за стыком на +CELL, а не только ближний сегмент; ранний
; выход на первом гэпе оставлял сегменты за вторым гэпом без компенсации →
; телепорт +32 на каждом шаге догона при нескольких дырах — «рывки» в зелёной
; фазе). Кламп к -CELL_SIZE. CATCH-UP: A=CELL; отдача слияния: A=vp/2.5.
; ----------------------------------------------------------------------------
VDC_GapRearComp:
                LD   (.grc_amount), A
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpGapIdx)
                CP   B
                RET  NC                                ; ран был у хвоста — некого двигать
                LD   C, A                              ; C = j
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pOffsets)
                ADD  HL, DE
                EX   DE, HL                            ; DE = &Offsets[j]
.grc_loop:      LD   A, (DE)
.grc_amount EQU $+1
                SUB  0                                 ; self-mod: величина компенсации
                JR   Z, .grc_save
                CP   #E0
                JR   NC, .grc_save                     ; -32..-1 — в диапазоне
                BIT  7, A
                JR   Z, .grc_save                      ; положительный остаток — ок
                LD   A, -VDC_CELL_SIZE                 ; глубже -CELL → кламп
.grc_save:      LD   (DE), A
                INC  DE
                INC  C
                LD   A, C
                CP   B
                JR   C, .grc_loop
                RET

; ----------------------------------------------------------------------------
; VDC_GapMergeCheckRecoil — после PULL-удаления гэп-слота: если соседи стыка
; K-1/K оба шары (ран закрыт, сегменты слились) — отдача заднего сегмента
; vp/2.5 (референс BALL_WEIGHT_RATIO=2.5), клик SND_BALLCLICK1, сброс разгона.
; ----------------------------------------------------------------------------
VDC_GapMergeCheckRecoil:
                LD   A, (VDC_GapJunction)
                CP   1
                RET  NZ                                ; отдача — только у PULL
                LD   A, (VDC_TmpGapIdx)
                OR   A
                RET  Z                                 ; слева никого
                LD   B, A
                LD   A, (VDC_SlotsLen)
                CP   B
                RET  C
                RET  Z                                 ; K за хвостом — справа никого
                LD   A, B
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  NC                                ; слева ещё гэп — ран не закрыт
                INC  HL
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  NC
                ; --- слияние! отдача = vp/2.5 (x10 → /25 = 0..4 сэмпла) ---
                LD   A, (VDC_GapPullVp)
                LD   L, A
                LD   H, 0
                LD   A, 25
                CALL VDC_DivHLbyA
                LD   A, L
                OR   A
                JR   Z, .gmr_no_recoil
                CALL VDC_GapRearComp
.gmr_no_recoil: LD   A, VDC_PULL_BASE_X10              ; следующий стык разгоняется заново
                LD   (VDC_GapPullVp), A
                LD   A, SND_BALLCLICK1                 ; клик стыковки (референс)
                JP   GS_PlaySfx

; ----------------------------------------------------------------------------
; VDC_RemoveSlotAt — удаляет slot (VDC_TmpGapIdx). Shift_left +
; SlotsLen-=1. Затрагивает Slots, Offsets, Shot2, ExplodeFrame/Marker.
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

                ; Аналогично для Offsets, Shot2, ExplodeFrame/Marker
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
                RET  NC                                 ; K-1 вне bounds
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
                LD   E, A                              ; сохранить len; XOR ниже не должен превратить DJNZ в 256 iterations
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
; Shift right Slots/Offsets/Shot2/ExplodeFrame/Marker[A..len-1] → A+1..len.
; new_off = -CS/2 + (head_off + tail_off)/2.
; HSA++ с cap, offsets[0..A-1] -= CS с cap -CS, ChainFreezeCnt = CS,
; ставит Shot2 на A, CheckMatch3.
; ============================================================================
VDC_InsertAt:
                LD   (VDC_TmpInsIdx), A
                LD   A, B
                LD   (VDC_TmpInsColor), A

                if RUNTIME_DIAGNOSTICS_ENABLED
                CALL LogInsert
                endif

                ; ограничить target_idx <= SlotsLen
                LD   A, (VDC_TmpInsIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   C, .ia_idx_ok
                LD   A, (HL)
                LD   (VDC_TmpInsIdx), A
.ia_idx_ok:
                ; SlotsLen >= MAX → fail (тихо)
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; --- вычислить new_offset ---
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
                ; saturate до signed byte [-128..127]
                LD   A, L
                BIT  7, H
                JR   Z, .ia_off_sat_pos
                ; negative: ограничить до -128, если H < #FF
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

                ; Explosion state следует за владением slot.
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
                ; HSA++ пропущен → нужна компенсация:
                ;   1) пропуск head_comp (offsets[0..idx-1] остаются как после shift_right = 0)
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
                ; Смещённое сравнение: (A XOR #80) < (#80 - CELL_SIZE) → ограничить.
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
                ; с natural hsub advance, head освобождает место). Компромисс: короткая
                ; head_slide animation visible (~32 px за 16 frames) — принято вместо
                ; chain-stops-everything на CS frames (хуже визуально).

                ; Immediate CheckMatch3 на target_idx. Для свежей вставки не
                ; ждём decay offsets: если слоты одного цвета уже образуют
                ; тройку, она должна взрываться сразу. Строгий offset-gap
                ; остаётся для cascade/Shot2 через обычный VDC_CheckMatch3.
                CALL VDC_CheckMatch3_Insert
                OR   A
                RET  NZ                                ; match → chain продолжается
                ; No match (shot не сработал) → Statistics_BreakChain
                ; and reset consecutive gap-shot streak.
                XOR  A
                LD   (VDC_BulletGapCount), A
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
;   Вход:  HL = dividend (unsigned), A = divisor (unsigned, > 0)
;   Выход: HL = quotient, A = remainder
;   Клобает BC.
; Bit-by-bit алгоритм. ~80 t-states, ~16 байт кода.
; ============================================================================
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
                LD   A, (VDC_LevelColors)              ; per-level color count (ставится в VDC_Init)
                CALL ZL_Mul16x8                        ; HL = rand * N (max 6*255 = 1530)
                LD   A, H                              ; A = (rand * N) >> 8 = 0..N-1
                RET

; ============================================================================
; VDC_RandomClusterLength — случайная длина 1..(VDC_NUM_COLORS-1).
; Использует отбрасывание 0 из VDC_RandomColor. Для текущего NUM=6 это 1..5.
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
; VDC_UpdateBulletGapTracking — per-frame проверка каждой GAP-ячейки в Slots[],
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
                ; Также пропуск если ExplodeFrame > 0 (gap ещё не "финализирован",
                ; это не пустая ячейка а взрывающийся шар)
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .ugt_skip
                ; Посчитать slot position (allow gap)
                LD   A, C
                CALL VDC_SlotPosAllowGap               ; BC=X, DE=Y, CF=1 если t<0
                JR   C, .ugt_skip
                ; Manhattan distance = |bullet_X - X| + |bullet_Y - Y|, ограничение 255
                LD   HL, (Bullet_X)
                AND  A
                SBC  HL, BC
                CALL ZL_AbsHL
                LD   A, H
                OR   A
                JR   NZ, .ugt_skip                     ; |dx| > 255 → дальше 255
                PUSH AF                                ; сохранить заглушку
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
; VDC_AwardGapBonus — успешный shot уничтожил balls после прохода через visible
; GAP slot. Miss/offscreen shots никогда не дают этот bonus.
; Реализация вынесена в main0: main1_play сейчас почти заполнен.
; ============================================================================
VDC_GAP_HIT_THR    EQU 24                              ; ~ball radius
VDC_GAP_MAX        EQU 32

VDC_AwardGapBonus:
                JP   VDC_AwardGapBonusSlot0

; ============================================================================
; VDC_BreakShotStats — shot завершился без уничтожения balls. Это сбивает chain
; и consecutive gap-shot streak, но не выдаёт gap points.
; ============================================================================
VDC_BreakShotStats:
                XOR  A
                LD   (VDC_BulletGapCount), A
                LD   (VDC_StatChainCount), A
                RET

                if RUNTIME_DIAGNOSTICS_ENABLED
                define DIAG_SECTION_VDC
                include "DiagnosticsRuntime.asm"
                undefine DIAG_SECTION_VDC
                endif

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
VDC_LoseHoldCnt:   DEFB 0                  ; per-chain pause за два samples до KZ, пока settle завершается
VDC_GapPullVp:     DEFB VDC_PULL_BASE_X10  ; скорость подтяжки ×10 (per-chain, в swap-блоке)
VDC_GapAccum:      DEFW 0                  ; аккумулятор подтяжки ×10 (порог VDC_GAP_ACCUM_STEP)
VDC_GapJunction:   DEFB 0                  ; 0=нет гэпов / 1=PULL / 2=CATCH-UP
VDC_GapTempo:      DEFB VDC_PULL_BASE_X10  ; темп закрытия ×10 (vp у PULL / скорость цепи у догона)
VDC_GapDecAcc:     DEFB 0                  ; дробный накопитель декея (остаток 0..9)
VDC_GapPosLeft:    DEFB 0                  ; 1 = остались положительные комп-офсеты (доезд)
VDC_BallsSpawned:  DEFB 0
VDC_SpawnDue:      DEFB 0                  ; был переход HSub 31→0 во время normal speed-тиков
VDC_SpawnClusterColor: DEFB 0xFF  ; цвет текущего cluster'а (HD-ref стиль same-color серий)
VDC_SpawnClusterRem:   DEFB 0     ; оставшиеся same-color spawn'ы ПОСЛЕ текущего (0=новый roll)
VDC_MatchScanIdx:  DEFB 0
VDC_ScanGapBusy:   DEFB 0
VDC_BridgeScanActive: DEFB 0
VDC_TrackNumSlots: DEFW 0
; VDC_GameState -> вынесен в loader_resident.asm (resident Core)
VDC_GameOverTick:  DEFB 0
VDC_AbsorbPopNote: DEFB 0   ; lose-всасывание: растущий питч SND_POP (полутона от базы), reset на входе в absorb
VDC_IntroTick:     DEFB 0   ; intro countdown (frames до state→PREVIEW)
VDC_PreviewTick:   DEFB 0   ; preview countdown (frames до state→CLOSING)
VDC_KzCloseTick:   DEFB 0   ; closing countdown (skull 11→1 animation)
VDC_WinTick:       DEFB 0   ; win-state countdown перед загрузкой next level
VDC_KzEndSub:      DEFB 0
; VDC_KzFrame, VDC_HeadAbsorbAlpha, VDC_Lives, VDC_DialogState, VDC_PrevMouseL,
; VDC_HudMenuState и VDC_HudPointerBlock находятся в loader_resident.asm.
VDC_LevelColors:  DEFB VDC_NUM_COLORS ; число ball-color на уровень, берётся из settings table в VDC_Init; default 6
VDC_LevelSpeed:   DEFB 50              ; chain speed_x100 на уровень; normal-phase advance = speed/100 MoveChain/frame
VDC_LevelStart:   DEFB VDC_LEVEL_START_BALLS ; lead-in ball count на уровень, fast-fill threshold
VDC_SpeedAccum:   DEFB 0               ; sub-frame speed accumulator для VDC_LevelSpeed
VDC_RollingActive: DEFB 0              ; 1, пока SND_ROLLING нужно остановить на fast->normal
VDC_RollingLoopTimer: DEFB 0           ; No-GS AY retrigger timer для rolling fast-fill
VDC_ExplodeActive: DEFB 0              ; 1 если в активной цепочке есть ExplodeFrame > 0
VDC_ChainLocalEnd:
; --- Stats counters (показываются в game-over диалоге, reset на VDC_Init) ---
VDC_StatTimeFrames: DEFW 0  ; сколько frame'ов прошло в state=PLAY; wall time хранит VDC_GameSeconds
VDC_StatCombos:     DEFB 0  ; текущее combo (≥2 explosions одного цвета подряд)
VDC_StatMaxCombo:   DEFB 0  ; max combo за уровень
VDC_StatMaxChain:   DEFB 0  ; max chain bonus за уровень
VDC_StatCoins:      DEFB 0  ; coin pickups: механика монет не реализована, поэтому 0
VDC_StatPrevMatchColor: DEFB #FF  ; предыдущий match color, sentinel #FF (нет предыдущего)
VDC_StatChainCount: DEFB 0  ; consecutive explosions без miss-shot. ≥5 + combo=0 = chain bonus
VDC_BulletGapMinDist: DEFB 255  ; min Manhattan distance bullet → ближайший GAP-slot за полёт.
                                ; Init=255 на каждый Bullet_Spawn (VDC_ResetBulletGapTracking).
                                ; Per-frame update в VDC_UpdateBulletGapTracking, проверяется на expire.
VDC_BulletGapCount: DEFB 0  ; consecutive gap shots для ×2 multiplier (HD-ref Statistics_AddBulletGap)
; VDC_GaugeScore, VDC_GaugeFull, VDC_PlayerScore, VDC_GameSeconds -> вынесены в
; loader_resident.asm (resident Core). VDC_GaugeShown остаётся здесь (только gameplay).
VDC_GaugeShown:     DEFW 0  ; отображаемый/animated score (LERP'ит к GaugeScore)
VDC_RtcLastSecond:  DEFB 0  ; последний RTC seconds sample (0..59)
VDC_RtcNoTickFrames: DEFB 0 ; fallback counter, когда RTC статичен в emulator
VDC_SfxStopTimer:   DEFB 0  ; отложенный SND_SILENCE для хвостов GS one-shot

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

VDC_LfsrSeed:     DEFW 0
VDC_LastTangent:  DEFB 0                                ; tangent байт последнего VDC_SlotPos
VDC_LastTrackFlags: DEFB 0                              ; bit0=tunnel/no bullet hit, bit1=draw above top layer
VDC_LastT:        DEFW 0                                ; t (16-bit signed) последнего VDC_SlotPos — для spin frame по track-advance

; Backing store второй chain. Active labels выше остаются единственным VDC engine
; ABI; two-track levels swap this block вокруг update/render/collision.
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
VDC_DualLoseMenuDelay: DEFB 0
VDC_SwapTmp:       DEFB 0
VDC_SwapPtr1:      DEFW 0
VDC_SwapPtr2:      DEFW 0
VDC_SwapLen:       DEFW 0
; --- Указатели активной цепочки (C-рефактор): код массивов обращается через них,
; смена цепочки = установка 5 указателей (БЕЗ копирования массивов). Стартуют на
; блок цепочки 1; VDC_SelectChain1/2 переключают. ---
VDC_pSlots:         DEFW VDC_Slots
VDC_pOffsets:       DEFW VDC_Offsets
VDC_pShot2:         DEFW VDC_Shot2
VDC_pExplodeFrame:  DEFW VDC_ExplodeFrame
VDC_pExplodeMarker: DEFW VDC_ExplodeMarker
VDC_SecondActive:   DEFB 0               ; 0 = активна цепочка 1, 1 = цепочка 2
VDC_SwapBuf:       DS VDC_MAX_SLOTS * 5

                endif ; ~_ZUMA_VDC_
