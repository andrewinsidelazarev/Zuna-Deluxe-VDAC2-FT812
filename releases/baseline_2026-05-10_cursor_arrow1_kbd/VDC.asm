
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
; TrackData layout (page 6 в slot 2 #8000):
;   word LE NumSamples, затем NumSamples * (sword X, sword Y).
; ============================================================================

VDC_CELL_SIZE          EQU 42                            ; sample-units на slot. Эмпирически:
                                                         ; track 1.067 px/sample → 42*1.067 ≈ 45 px
                                                         ; между центрами при ball=40 → 5 px gap
                                                         ; (= touching, как в оригинале Zuma).
VDC_MAX_SLOTS          EQU 240
VDC_GAP_STOP           EQU #FE
VDC_GAP_CASCADE        EQU #FD
VDC_NUM_COLORS         EQU 6
VDC_GAP_STEP_FRAMES    EQU VDC_CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX EQU 10                            ; ~CELL_SIZE/4
VDC_BALLS_TARGET       EQU 60                            ; стоп-спавн после стольки шаров

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

                ; Offsets, Shot2, RollbackCounter — все 0
                LD   HL, VDC_Offsets
                LD   DE, VDC_Offsets + 1
                LD   BC, (VDC_MAX_SLOTS * 3) - 1
                LD   (HL), 0
                LDIR

                ; Скаляры — нулим простым LD
                XOR  A
                LD   (VDC_HSA),                A
                LD   (VDC_HSub),               A
                LD   (VDC_SlotsLen),           A
                LD   (VDC_ChainStalled),       A
                LD   (VDC_ChainFreezeCnt),     A
                LD   (VDC_GapStepCnt),         A
                LD   (VDC_BallsSpawned),       A
                LD   (VDC_MatchScanIdx),       A

                ; Запомнить TRACK_NUM_SLOTS (= NumSamples / CELL_SIZE - 1) —
                ; используется как cap для HSA. NumSamples лежит в TrackData word.
                LD   HL, (TrackData)                  ; HL = NumSamples
                LD   A, VDC_CELL_SIZE
                CALL VDC_DivHLbyA                     ; HL = NumSamples / CELL_SIZE
                DEC  HL
                LD   (VDC_TrackNumSlots), HL

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
; Порядок строго как в Python emulator: try_spawn → move_chain → animate_chain.
; ============================================================================
VDC_Update:
                CALL VDC_TrySpawn
                CALL VDC_MoveChain
                CALL VDC_AnimateChain
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
                XOR  A                                ; clamp 0 (i > HSA)
.delta_ok:
                ; HL = (HSA - i) * 42 = *32 + *8 + *2
                LD   H, 0 : LD L, A
                ADD  HL, HL                            ; *2
                LD   D, H : LD E, L                    ; DE = *2
                ADD  HL, HL : ADD HL, HL               ; *8
                LD   B, H : LD C, L                    ; BC = *8
                ADD  HL, HL : ADD HL, HL               ; *32
                ADD  HL, BC                            ; +*8 = *40
                ADD  HL, DE                            ; +*2 = *42

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
                LD   A, (VDC_BallsSpawned)
                CP   VDC_BALLS_TARGET
                RET  NC
                LD   A, (VDC_SlotsLen)
                CP   VDC_MAX_SLOTS
                RET  NC

                ; HSA < SlotsLen → не спавним (хвост не достиг старта)
                LD   B, A                              ; B = SlotsLen
                LD   A, (VDC_HSA)
                CP   B
                RET  C

                ; HSub != 0 → не спавним (не cell-aligned)
                LD   A, (VDC_HSub)
                OR   A
                RET  NZ

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

                ; --- RollbackCnt[SlotsLen] = 0 ---
                LD   A, (VDC_SlotsLen)
                LD   H, 0 : LD L, A
                LD   DE, VDC_RollbackCnt
                ADD  HL, DE
                LD   (HL), 0

                ; --- SlotsLen++, BallsSpawned++ ---
                LD   HL, VDC_SlotsLen
                INC  (HL)
                LD   HL, VDC_BallsSpawned
                INC  (HL)
                RET

; ============================================================================
; VDC_MoveChain — HSub++ если chain не stalled и не frozen; wrap → HSA++.
; ============================================================================
VDC_MoveChain:
                LD   A, (VDC_ChainStalled)
                OR   A
                RET  NZ

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
                DEC  A                                 ; pos -> 0
                JR   .ac_decay_store
.ac_decay_neg:  INC  A                                 ; neg -> 0
.ac_decay_store:
                LD   (HL), A
.ac_decay_skip:
                INC  HL
                DJNZ .ac_decay
.ac_after_decay:
                ; --- 2. GapStepCnt++; при HSub==0 и cnt>=GAP_STEP_FRAMES → DoGapStep.
                LD   A, (VDC_GapStepCnt)
                INC  A
                LD   (VDC_GapStepCnt), A
                CP   VDC_GAP_STEP_FRAMES
                JR   C, .ac_no_gap_step
                LD   A, (VDC_HSub)
                OR   A
                JR   NZ, .ac_no_gap_step
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
.ac_no_gap_step:
                ; --- 3. Persistent scan. ---
                CALL VDC_ScanForNewMatch
                CALL VDC_UpdateStall
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
                ; ChainStalled (=1 пока есть GAP), GapStepCnt = GAP_STEP_FRAMES,
                ; ChainStalled=1 transient (UpdateStall в конце AnimateChain
                ; сбросит обратно в 0 — Python: chain_stalled = 0 ВСЕГДА).
                ; ChainFreezeCnt НЕ ставим: match не должен freeze'ить chain motion,
                ; пауза приходит ТОЛЬКО от cascade-close (= DoGapStep CASCADE pass).
                LD   A, 1
                LD   (VDC_ChainStalled), A
                LD   A, VDC_GAP_STEP_FRAMES
                LD   (VDC_GapStepCnt), A
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
                JP   Z, .dgs_cascade_init
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
                JP   Z, .dgs_cascade_init
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
                LD   A, (HL)
                OR   A
                JP   P, .dgs_stop_off_cap              ; A>=0 (signed) → cap
                ADD  A, VDC_CELL_SIZE
                JR   .dgs_stop_off_save
.dgs_stop_off_cap:
                LD   A, VDC_CELL_SIZE
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
                CALL VDC_RemoveSlotAt
                CALL VDC_HsaDec

                ; head comp
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .dgs_casc_no_off
                LD   B, A
                LD   HL, VDC_Offsets
.dgs_casc_off:
                LD   A, (HL)
                OR   A
                JP   P, .dgs_casc_off_cap
                ADD  A, VDC_CELL_SIZE
                JR   .dgs_casc_off_save
.dgs_casc_off_cap:
                LD   A, VDC_CELL_SIZE
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

                LD   A, (VDC_TmpGapIdx)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_RollbackCnt
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
; VDC_UpdateStall — Python: chain_stalled = 0 ВСЕГДА.
; (Старая 360x288 asm-версия проверяла GAP/offsets и отдельно freeze'ила chain
; motion на N кадров декея offsets — VDC сосед сообщил что это БАГ:
; insert→stall=1 пока offsets!=0 (CELL_SIZE кадров) + ChainFreezeCnt=CELL_SIZE
; → пауза 2× длиннее задуманной (~1.1 сек). Pause приходит ТОЛЬКО от
; ChainFreezeCnt в move_chain. См. Чат.txt запись 2026-05-09 17:00.)
; ============================================================================
VDC_UpdateStall:
                XOR  A
                LD   (VDC_ChainStalled), A
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
                LD   H, 0 : LD L, 0
                LD   DE, VDC_Offsets
                ADD  HL, DE
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

                ; RollbackCnt
                CALL VDC_ShiftRight_Rollback
.ia_no_shift:
                ; --- Slots[idx] = color, Offsets[idx] = new_off, Shot2[idx]=1, RollbackCnt[idx]=0 ---
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

                LD   A, (VDC_TmpInsIdx)
                LD   H, 0 : LD L, A
                LD   DE, VDC_RollbackCnt
                ADD  HL, DE
                LD   (HL), 0

                ; SlotsLen++
                LD   HL, VDC_SlotsLen
                INC  (HL)

                ; HSA++ с cap по TrackNumSlots-1
                LD   HL, (VDC_TrackNumSlots)
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   C, .ia_no_hsa_inc
                JR   Z, .ia_no_hsa_inc
                LD   HL, VDC_HSA
                INC  (HL)
.ia_no_hsa_inc:
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
                ; Biased compare: (A XOR #80) < (#80 - CELL_SIZE) → clamp.
                PUSH AF
                XOR  #80
                CP   #80 - VDC_CELL_SIZE
                POP  AF
                JR   NC, .ia_head_comp_save            ; A >= -CELL → ОК
                LD   A, 256 - VDC_CELL_SIZE            ; -CELL
.ia_head_comp_save:
                LD   (HL), A
                INC  HL
                DJNZ .ia_head_comp
.ia_no_head_comp:
                ; ChainFreezeCnt НЕ ставим (VDC сосед нашёл: с freeze хвост стоит
                ; CELL_SIZE кадров — некрасиво. Без freeze head_offsets декаят
                ; параллельно с natural hsub advance → head ускоренно уезжает
                ; вперёд на 2 cells за CELL_SIZE кадров, освобождая место.
                ; Tail формально на месте (math: t=(HSA+1−(idx+1))*CS+sub = old t),
                ; spawn-таймер не сбивается. Cascade-close по-прежнему ставит
                ; freeze в DoGapStep. См. Чат.txt 2026-05-09 18:10.)

                ; CheckMatch3 на target_idx (TmpInsIdx уже стоит)
                CALL VDC_CheckMatch3
                RET

; ----------------------------------------------------------------------------
; VDC_ShiftRight_* — сдвиг массива Array[idx..len-1] → Array[idx+1..len].
; Идём через LDDR (HL = src=last, DE = dst=last+1, BC = count).
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
                JR   VDC_ShiftRight_Common
VDC_ShiftRight_Rollback:
                LD   IX, VDC_RollbackCnt
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
                LD   HL, (VDC_LfsrSeed)
                LD   A, L
                AND  1
                SRL  H : RR L
                JR   Z, .rc_no_xor
                LD   D, #B4 : LD E, 0
                LD   A, H : XOR D : LD H, A
                LD   A, L : XOR E : LD L, A
.rc_no_xor:
                LD   (VDC_LfsrSeed), HL
                ; A = L XOR H — смешать обе половины для большей энтропии
                LD   A, L
                XOR  H                                 ; A = 8-bit random 0..255
                ; result = (A * NUM_COLORS) >> 8
                LD   H, 0 : LD L, A
                LD   D, 0 : LD E, A
                ADD  HL, HL                            ; HL = A*2
                ADD  HL, DE                            ; HL = A*3
                ADD  HL, HL                            ; HL = A*6   (== A*NUM_COLORS)
                LD   A, H                              ; A = (A*6) >> 8 → 0..5
                RET

; ============================================================================
; STATE — массивы и скаляры. SAVEBIN их сохранит как нули; VDC_Init
; явно инициализирует на старте (см. feedback_zuma_init_explicit.md).
; ============================================================================
VDC_Slots:        DS VDC_MAX_SLOTS
VDC_Offsets:      DS VDC_MAX_SLOTS
VDC_Shot2:        DS VDC_MAX_SLOTS
VDC_RollbackCnt:  DS VDC_MAX_SLOTS

VDC_HSA:           DEFB 0
VDC_HSub:          DEFB 0
VDC_SlotsLen:      DEFB 0
VDC_ChainStalled:  DEFB 0
VDC_ChainFreezeCnt:DEFB 0
VDC_GapStepCnt:    DEFB 0
VDC_BallsSpawned:  DEFB 0
VDC_MatchScanIdx:  DEFB 0
VDC_TrackNumSlots: DEFW 0

VDC_TmpInsIdx:    DEFB 0
VDC_TmpInsColor:  DEFB 0
VDC_TmpInsNewOff: DEFB 0
VDC_TmpGapIdx:    DEFB 0
VDC_TmpML:        DEFB 0
VDC_TmpMR:        DEFB 0
VDC_TmpMCount:    DEFB 0
VDC_TmpMC_Color:  DEFB 0

VDC_LfsrSeed:     DEFW 0
VDC_LastTangent:  DEFB 0                                ; tangent байт последнего VDC_SlotPos
VDC_LastT:        DEFW 0                                ; t (16-bit signed) последнего VDC_SlotPos — для spin frame по track-advance

                endif ; ~_ZUMA_VDC_
