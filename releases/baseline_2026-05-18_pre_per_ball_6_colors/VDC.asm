
                ifndef _ZUMA_VDC_
                define _ZUMA_VDC_

; ============================================================================
; VDC — Virtual Discrete Chain physics для Zuma VDAC2 (640x480).
; ----------------------------------------------------------------------------
; Порт vdc_visual_emulator.py 1:1. Отличия от 360x288 asm-версии:
;   - CELL_SIZE = 64 (вместо 32), все производные пересчитаны.
;   - HSA word (вместо byte) — track 640x480 длиннее (~2762 sample / 64 = ~43 slot,
;     помещается в byte, но держим word для запаса под длинные уровни).
;   - LastRenderPos НЕ хранится: при t<0 рендер skip. Trade-off: при cascade
;     rollback шары на спавне на 1-2 кадра становятся невидимыми. Можно добавить
;     потом как опциональный массив.
;   - Без EXPLOSION_FRAMES анимации (Slots[lb..rb] сразу = GAP). Explosion
;     отдельным TSU-слоем, как в v6/v7 360x288, добавится позже.
;
; API:
;   VDC_Init       — обнулить все массивы, Slots[] = GAP_STOP, RNG seed.
;   VDC_Update     — TrySpawn + MoveChain + AnimateChain. Один вызов = один кадр.
;   VDC_SlotPos    — для слота A считает (X,Y) центра шара.
;                    Out: BC=X, DE=Y, CF=1 если skip (gap или t<0).
;   VDC_InsertAt   — A=target_idx, B=color. Вставить шар, проверить match.
;
; Все функции корраптят AF/BC/DE/HL.
; TrackData layout (page 6 РІ slot 2 #8000):
;   word LE NumSamples, затем NumSamples * (sword X, sword Y).
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
VDC_NUM_COLORS         EQU 4                             ; classic Zuma level 1: colors="4"
VDC_GAP_STEP_FRAMES    EQU VDC_CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX EQU 10                            ; ~CELL_SIZE/4
VDC_BALLS_TARGET       EQU 85                            ; classic level 1: start 35 + repeat 50 = 85 (для воспроизведения cap-glitch в Z80-симуляторе)
VDC_KZ_FRAMES          EQU 12

; ============================================================================
; VDC_Init — обнулить state, Slots[] = GAP_STOP. Должен быть вызван 1 раз
; до любого VDC_Update / VDC_SlotPos / VDC_InsertAt.
; ============================================================================
VDC_Init:
                ; Слоты: 240 байт = GAP_STOP
                LD   HL, VDC_Slots
                LD   DE, VDC_Slots + 1
                LD   BC, VDC_MAX_SLOTS - 1
                LD   (HL), VDC_GAP_STOP
                LDIR

                ; Offsets, Shot2 — все 0
                LD   HL, VDC_Offsets
                LD   DE, VDC_Offsets + 1
                LD   BC, (VDC_MAX_SLOTS * 2) - 1
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
                LD   (VDC_MatchScanIdx),       A
                LD   (VDC_GameState),          A
                LD   (VDC_GameOverTick),       A
                INC  A
                LD   (VDC_KzFrame),            A

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
                LD   (VDC_LfsrSeed), HL
                RET


; ============================================================================
; ReadRTCSeconds — TS-Conf GLUK CMOS RTC, регистр 0 (секунды BCD).
; Порты #DFF7 (адрес) / #BFF7 (данные). Out: A = 0..59 binary.
; ============================================================================
ReadRTCSeconds:
                LD   BC, #DFF7
                XOR  A
                OUT  (C), A                            ; reg 0 = seconds
                LD   BC, #BFF7
                IN   A, (C)                            ; A = BCD seconds
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
; VDC_Update — один шаг физики (вызывать раз в кадр).
; Phase 1 (BallsSpawned < LEVEL_START_BALLS): 12× MoveChain + 1× AnimateChain +
;   1× TrySpawn (TrySpawn внутри loop'ит). Это «поезд» влёта 35 шаров за ~90 тиков.
; Phase 2 (BallsSpawned ≥ LEVEL_START_BALLS): 1× MoveChain каждый кадр (norm-speed
;   подобран под VDAC2 CELL_SIZE=42 — без subdivider /2 как у коллеги).
; ============================================================================
VDC_Update:
                LD   A, (VDC_GameState)
                CP   1
                JP   Z, VDC_UpdateAbsorb
                CP   2
                RET  Z
                CALL VDC_CheckKillzone
                LD   A, (VDC_BallsSpawned)
                CP   VDC_LEVEL_START_BALLS
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
                JP   VDC_TrySpawn_NoHsubGate
.upd_normal:    ; Normal phase: subdivider /2 + spawn каждые 64 кадра.
                ; TrySpawn (с hsub-gate) синхронен с Python: spawn только когда
                ; chain выровнен по cell-границе.
                LD   A, (ZL_FrameCounter)
                AND  1
                RET  NZ                                ; odd frame → skip всё
                CALL VDC_MoveChain
                CALL VDC_AnimateChain
                LD   A, (VDC_BallsSpawned)
                CP   VDC_BALLS_TARGET
                RET  NC
                LD   A, (ZL_FrameCounter)
                AND  63
                RET  NZ
                JP   VDC_TrySpawn

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
                PUSH BC                                 ; save i
                LD   A, VDC_CELL_SIZE
                CALL ZL_Mul16x8                        ; HL = delta * CELL_SIZE
                POP  BC                                 ; restore i

                ; + HSub (0..63 unsigned)
                LD   A, (VDC_HSub)
                LD   E, A
                LD   D, 0
                ADD  HL, DE

                ; + sext(offsets[i])
                LD   A, C
                PUSH HL
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
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
; ============================================================================
VDC_SlotPos:
                ; --- skip if gap ---
                LD   C, A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   C, .not_gap
                SCF                                    ; CF=1, skip
                RET
.not_gap:
                LD   A, C
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
.t_in:
                ; expose t для caller (используется для spin frame по track-advance)
                LD   (VDC_LastT), HL
                ; HL_addr = TrackData + 2 + t*5  (stride 5 = X word + Y word + tangent byte)
                LD   D, H : LD E, L                    ; DE = t
                ADD  HL, HL : ADD HL, HL               ; *4
                ADD  HL, DE                            ; *5
                LD   DE, TrackData + 2
                ADD  HL, DE
                LD   E, (HL) : INC HL
                LD   D, (HL) : INC HL                  ; DE = X
                LD   C, (HL) : INC HL
                LD   B, (HL) : INC HL                  ; BC = Y
                LD   A, (HL)                           ; A = tangent byte 0..255
                LD   (VDC_LastTangent), A              ; expose для caller
                EX   DE, HL                            ; HL = X (free up DE)
                LD   D, B : LD E, C                    ; DE = Y
                LD   B, H : LD C, L                    ; BC = X
                AND  A                                 ; CF = 0
                RET

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
                LD   A, (VDC_BallsSpawned)
                CP   VDC_BALLS_TARGET
                RET  NC
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; Fix 2026-05-14: HSA at cap → no spawn (chain at end-of-track).
                ; Раньше TrackNumSlots был #FFFE → cap недостижим → bug не виден.
                ; С правильным TrackNumSlots=85 chain останавливается на HSA=85
                ; и каждый кадр spawn-check проходил → бесконечный spawn в хвост.
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                RET  Z                                  ; HSA == cap → stop
                RET  C                                  ; HSA > cap (paranoia)

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
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ
.spawn_no_tail_check:
                ; --- color = RandomColor() ---
                CALL VDC_RandomColor                   ; A = 0..NUM_COLORS-1

                ; --- anti-3-spawn-guard ---
                ; Если SlotsLen>=2 и Slots[len-1]==Slots[len-2]==candidate → +1 mod NUM
                LD   B, A                              ; B = candidate
                LD   A, (VDC_SlotsLen)
                CP   2
                JR   C, .spawn_no_guard
                DEC  A                                 ; len-1
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)                           ; Slots[len-1]
                CP   B
                JR   NZ, .spawn_no_guard
                DEC  HL
                LD   A, (HL)                           ; Slots[len-2]
                CP   B
                JR   NZ, .spawn_no_guard
                ; collision: candidate++ mod NUM_COLORS
                LD   A, B
                INC  A
                CP   VDC_NUM_COLORS
                JR   C, .guard_ok
                XOR  A
.guard_ok:
                LD   B, A
.spawn_no_guard:
                ; --- Slots[SlotsLen] = candidate ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   (HL), B

                ; --- offsets[SlotsLen] = (SlotsLen>0) ? offsets[SlotsLen-1] : 0 ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .spawn_off_zero
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   B, (HL)                           ; B = offsets[len-1]
                JR   .spawn_off_set
.spawn_off_zero:
                LD   B, 0
.spawn_off_set:
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   (HL), B

                ; --- Shot2[SlotsLen] = 0 ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 0

                ; --- SlotsLen++, BallsSpawned++ ---
                LD   HL, VDC_SlotsLen
                INC  (HL)
                LD   HL, VDC_BallsSpawned
                INC  (HL)
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
                ; --- 1. decay offsets (rollback_counter не реализован — нет
                ; кода который бы его выставлял; декай идёт сразу к 0).
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ac_after_decay
                LD   B, A
                LD   HL, VDC_Offsets
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

                ; color = Slots[idx]
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
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
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_l_done

                ; offset gap: -CS <= (off[B-1]-off[B]) < GAP_MAX (= [-CS..GAP_MAX-1])
                LD   A, B
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   C, A                              ; C = off[B-1]
                LD   A, B
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                SUB  C                                 ; off[B] - off[B-1]
                NEG                                    ; -> off[B-1] - off[B]
                ADD  A, VDC_CELL_SIZE                  ; +CS (shift to unsigned [0..2*CS])
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_l_done

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
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                LD   HL, VDC_TmpMC_Color
                CP   (HL)
                JR   NZ, .dm3_r_done

                ; offset gap для right
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A                              ; B = off[C]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                SUB  B                                 ; off[C+1] - off[C]
                NEG                                    ; -> off[C] - off[C+1]
                ADD  A, VDC_CELL_SIZE
                CP   VDC_CELL_SIZE + VDC_DM3_OFFSET_GAP_MAX
                JR   NC, .dm3_r_done

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
; A=1 если был матч, A=0 иначе.
; ============================================================================
VDC_CheckMatch3:
                CALL VDC_DetectMatch3
                OR   A
                JP   Z, .m3_no

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
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   C, (HL)                           ; C = Slots[lb-1]
                LD   A, C
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP

                LD   A, (VDC_TmpMR)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap → STOP
                CP   C
                JR   NZ, .m3_have_marker
                LD   B, VDC_GAP_CASCADE
.m3_have_marker:
                ; Slots[lb..rb] = B, Offsets[lb..rb] = 0, Shot2[lb..rb] = 0
                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_slots:
                LD   (HL), B
                INC  HL
                DEC  C
                JR   NZ, .m3_set_slots

                LD   A, (VDC_TmpML)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
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
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   A, (VDC_TmpMCount)
                LD   C, A
.m3_set_shot2_clr:
                LD   (HL), 0
                INC  HL
                DEC  C
                JR   NZ, .m3_set_shot2_clr

                ; Shot2[lb-1]=1 если lb>0
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_no_left_shot2
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.m3_no_left_shot2:
                ; Shot2[rb+1]=1 если rb+1<len
                LD   A, (VDC_TmpMR)
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .m3_no_right_shot2
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.m3_no_right_shot2:
                ; Instant gap_step — иначе chain motion в waiting period (до hsub=0)
                ; двигает head вперёд, а должен стоять и ждать хвост. С первым
                ; instant gap_step head получает +CS offset compensation сразу
                ; → stationary до конца decay phase. Остальные markers ждут
                ; следующего GAP_STEP_FRAMES (без hsub=0 constraint).
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
                LD   A, 1
                RET
.m3_no:
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
                LD   DE, VDC_Slots
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
                LD   HL, VDC_Offsets
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
                LD   HL, VDC_Slots
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
                LD   HL, VDC_Offsets
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
                JR   Z, .rsa_no_shift                  ; idx == len-1 → ничего не двигать
                LD   E, A                              ; E = count

                ; Shift Slots[idx+1..len-1] → Slots[idx..len-2]
                LD   A, C
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
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
                LD   DE, VDC_Offsets
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
                LD   DE, VDC_Shot2
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
; на K-1 и K (если non-gap, в bounds).
; ----------------------------------------------------------------------------
VDC_SetShot2OnNeighbors:
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .ssn_skip_left
                ; K-1: проверить < SlotsLen и not gap
                DEC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .ssn_skip_left
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .ssn_skip_left
                LD   A, (VDC_TmpGapIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.ssn_skip_left:
                ; K: проверить < SlotsLen и not gap
                LD   A, (VDC_TmpGapIdx)
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JR   NC, .ssn_skip_right
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .ssn_skip_right
                LD   A, (VDC_TmpGapIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.ssn_skip_right:
                RET

; ============================================================================
; VDC_ScanForNewMatch — проходит Shot2[0..len-1], при is_gap чистит, иначе
; CheckMatch3, иначе если settled (все offsets вокруг 0) — чистит Shot2.
; ============================================================================
VDC_ScanForNewMatch:
                LD   A, (VDC_SlotsLen)
                OR   A
                RET  Z
                LD   B, A                              ; B = iter
                LD   HL, VDC_Shot2
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
                LD   DE, VDC_Slots
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
                CALL VDC_CheckMatch3
                POP  HL
                POP  BC
                OR   A
                RET  NZ                                ; match → выходим

                ; settled check: offset[C], [C-1], [C+1] all 0 → clear Shot2
                PUSH BC
                PUSH HL
                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                JR   NZ, .snm_unsettled
                LD   A, C
                OR   A
                JR   Z, .snm_check_right
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
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
                LD   DE, VDC_Offsets
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
                DJNZ .snm_loop
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
                LD   A, (VDC_Offsets)
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
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (HL)
                LD   B, A : LD C, A
                JR   .ia_off_compute
.ia_off_middle:
                ; head = offsets[idx-1], tail = offsets[idx]
                LD   A, (VDC_TmpInsIdx)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   B, (HL)                           ; B = head_off
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
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
                ; positive: H must be 0
                OR   H
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
.ia_no_shift:
                ; --- Slots[idx] = color, Offsets[idx] = new_off, Shot2[idx]=1 ---
                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (VDC_TmpInsColor)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Offsets
                ADD  HL, DE
                LD   A, (VDC_TmpInsNewOff)
                LD   (HL), A

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1

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
                LD   DE, VDC_Offsets
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
                LD   DE, VDC_Offsets
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
                LD   HL, VDC_Offsets
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

                ; CheckMatch3 на target_idx — clamp invariant выполняется в
                ; конце VDC_AnimateChain каждый кадр (покрывает InsertAt тоже).
                CALL VDC_CheckMatch3
                RET

; ----------------------------------------------------------------------------
; VDC_ShiftRight_* — сдвиг массива Array[idx..len-1] → Array[idx+1..len].
; Идем через LDDR (HL = src=last, DE = dst=last+1, BC = count).
; Использует VDC_TmpInsIdx, VDC_SlotsLen.
; ----------------------------------------------------------------------------
VDC_ShiftRight_Slots:
                LD   IX, VDC_Slots
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Offsets:
                LD   IX, VDC_Offsets
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Shot2:
                LD   IX, VDC_Shot2
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
VDC_DivHLbyA:
                LD   C, A
                XOR  A
                LD   B, 16
.dv_loop:
                ADD  HL, HL
                RLA
                CP   C
                JR   C, .dv_skip
                SUB  C
                INC  L                                 ; HL[0] был 0 после ADD, теперь 1
.dv_skip:
                DJNZ .dv_loop
                RET

; ============================================================================
; VDC_RandomColor — LFSR Galois 16-bit (poly 0xB400). Out: A = 0..NUM_COLORS-1.
; Распределение: используем (rand8 * NUM_COLORS) >> 8 вместо AND 7 + clamp,
; иначе в 6-цветовом случае colors 0/1 встречаются 2× чаще остальных
; (8 mod 6 = 2 → дубли 6→0 и 7→1). Mul/shift даёт ≤1.4% bias.
; ============================================================================
VDC_RandomColor:
                ; Rejection sampling: AND 7 + reject if >= NUM. Корректен для
                ; любого NUM <= 8 (level 1=4, end-game filter может дропнуть
                ; до 3, hard levels до 5-6). Старый AND (NUM-1) работал ТОЛЬКО
                ; для степеней двойки (4,8); для NUM=6 давал 0,1,4,5 only
                ; (бит 1 жёстко обнулялся). Gemini-fix 2026-05-17.
.rc_loop:
                LD   HL, (VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   Z, .rc_no_xor
                LD   A, H : XOR #B4 : LD H, A          ; poly #B400 (low=0)
.rc_no_xor:
                LD   (VDC_LfsrSeed), HL
                LD   A, L
                XOR  H                                 ; 8-bit random
                AND  7                                 ; 0..7 (max NUM=8)
                CP   VDC_NUM_COLORS                    ; reject if >= NUM
                JR   NC, .rc_loop                      ; retry
                RET

; ============================================================================
; STATE — массивы и скаляры. SAVEBIN их сохранит как нули; VDC_Init
; явно инициализирует на старте (см. feedback_zuma_init_explicit.md).
; ============================================================================
VDC_Slots:        DS VDC_MAX_SLOTS
VDC_Offsets:      DS VDC_MAX_SLOTS
VDC_Shot2:        DS VDC_MAX_SLOTS

VDC_HSA:           DEFB 0
VDC_HSub:          DEFB 0
VDC_SlotsLen:      DEFB 0
VDC_ChainFreezeCnt:DEFB 0
VDC_GapStepCnt:    DEFB 0
VDC_BallsSpawned:  DEFB 0
VDC_MatchScanIdx:  DEFB 0
VDC_TrackNumSlots: DEFW 0
VDC_GameState:     DEFB 0   ; 0=play, 1=absorb into killzone, 2=game over
VDC_GameOverTick:  DEFB 0
VDC_KzFrame:       DEFB 0
VDC_KzEndSub:      DEFB 0
VDC_HeadAbsorbAlpha: DEFB 255 ; head-ball fade alpha во время state=1 (255→191→127→63→remove)

VDC_TmpInsIdx:    DEFB 0
VDC_TmpInsColor:  DEFB 0
VDC_TmpInsNewOff: DEFB 0
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

                endif ; ~_ZUMA_VDC_
