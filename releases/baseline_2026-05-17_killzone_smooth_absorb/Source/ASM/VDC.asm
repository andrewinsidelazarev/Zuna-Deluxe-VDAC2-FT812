
                ifndef _ZUMA_VDC_
                define _ZUMA_VDC_

; ============================================================================
; VDC вЂ” Virtual Discrete Chain physics РґР»СЏ Zuma VDAC2 (640x480).
; ----------------------------------------------------------------------------
; РџРѕСЂС‚ vdc_visual_emulator.py 1:1. РћС‚Р»РёС‡РёСЏ РѕС‚ 360x288 asm-РІРµСЂСЃРёРё:
;   - CELL_SIZE = 64 (РІРјРµСЃС‚Рѕ 32), РІСЃРµ РїСЂРѕРёР·РІРѕРґРЅС‹Рµ РїРµСЂРµСЃС‡РёС‚Р°РЅС‹.
;   - HSA word (РІРјРµСЃС‚Рѕ byte) вЂ” track 640x480 РґР»РёРЅРЅРµРµ (~2762 sample / 64 = ~43 slot,
;     РїРѕРјРµС‰Р°РµС‚СЃСЏ РІ byte, РЅРѕ РґРµСЂР¶РёРј word РґР»СЏ Р·Р°РїР°СЃР° РїРѕРґ РґР»РёРЅРЅС‹Рµ СѓСЂРѕРІРЅРё).
;   - LastRenderPos РќР• С…СЂР°РЅРёС‚СЃСЏ: РїСЂРё t<0 СЂРµРЅРґРµСЂ skip. Trade-off: РїСЂРё cascade
;     rollback С€Р°СЂС‹ РЅР° СЃРїР°РІРЅРµ РЅР° 1-2 РєР°РґСЂР° СЃС‚Р°РЅРѕРІСЏС‚СЃСЏ РЅРµРІРёРґРёРјС‹РјРё. РњРѕР¶РЅРѕ РґРѕР±Р°РІРёС‚СЊ
;     РїРѕС‚РѕРј РєР°Рє РѕРїС†РёРѕРЅР°Р»СЊРЅС‹Р№ РјР°СЃСЃРёРІ.
;   - Р‘РµР· EXPLOSION_FRAMES Р°РЅРёРјР°С†РёРё (Slots[lb..rb] СЃСЂР°Р·Сѓ = GAP). Explosion
;     РѕС‚РґРµР»СЊРЅС‹Рј TSU-СЃР»РѕРµРј, РєР°Рє РІ v6/v7 360x288, РґРѕР±Р°РІРёС‚СЃСЏ РїРѕР·Р¶Рµ.
;
; API:
;   VDC_Init       вЂ” РѕР±РЅСѓР»РёС‚СЊ РІСЃРµ РјР°СЃСЃРёРІС‹, Slots[] = GAP_STOP, RNG seed.
;   VDC_Update     вЂ” TrySpawn + MoveChain + AnimateChain. РћРґРёРЅ РІС‹Р·РѕРІ = РѕРґРёРЅ РєР°РґСЂ.
;   VDC_SlotPos    вЂ” РґР»СЏ СЃР»РѕС‚Р° A СЃС‡РёС‚Р°РµС‚ (X,Y) С†РµРЅС‚СЂР° С€Р°СЂР°.
;                    Out: BC=X, DE=Y, CF=1 РµСЃР»Рё skip (gap РёР»Рё t<0).
;   VDC_InsertAt   вЂ” A=target_idx, B=color. Р’СЃС‚Р°РІРёС‚СЊ С€Р°СЂ, РїСЂРѕРІРµСЂРёС‚СЊ match.
;
; Р’СЃРµ С„СѓРЅРєС†РёРё РєРѕСЂСЂР°РїС‚СЏС‚ AF/BC/DE/HL.
; TrackData layout (page 6 РІ slot 2 #8000):
;   word LE NumSamples, Р·Р°С‚РµРј NumSamples * (sword X, sword Y).
; ============================================================================

VDC_LEVEL_START_BALLS  EQU 35                            ; Р±С‹СЃС‚СЂР°СЏ С„Р°Р·Р°: 35 С€Р°СЂРѕРІ В«РїРѕРµР·РґРѕРјВ»
VDC_FAST_ADVANCE       EQU 12                            ; MoveChain Г—12 Р·Р° tick РІ fast-С„Р°Р·Рµ
VDC_ABSORB_ADVANCE     EQU 8                             ; absorb chain advance: 8 px/tick (32/8=4 ticks/cell)
VDC_CELL_SIZE          EQU 32                            ; sample-units РЅР° slot.
VDC_DECAY_NEG          EQU 2                             ; insert head slide (negв†’0) Р±С‹СЃС‚СЂРѕ.
VDC_DECAY_POS          EQU 1                             ; cascade rollback (posв†’0) РїР»Р°РІРЅРѕ.
                                                          ; track chord 1.0815 px/sample: 32Г—1.08 в‰€ 34.6 px
                                                          ; centers, ball 32 px в†’ gap ~2.6 px РЅР° РїСЂСЏРјРѕР№.
                                                          ; РСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ РІ VDC_SlotT С‡РµСЂРµР· ZL_Mul16x8.
                                                         ; track 1.067 px/sample в†’ 42*1.067 в‰€ 45 px
                                                         ; РјРµР¶РґСѓ С†РµРЅС‚СЂР°РјРё РїСЂРё ball=40 в†’ 5 px gap
                                                         ; (= touching, РєР°Рє РІ РѕСЂРёРіРёРЅР°Р»Рµ Zuma).
VDC_MAX_SLOTS          EQU 240
VDC_GAP_STOP           EQU #FE
VDC_GAP_CASCADE        EQU #FD
VDC_NUM_COLORS         EQU 4                             ; classic Zuma level 1: colors="4"
VDC_GAP_STEP_FRAMES    EQU VDC_CELL_SIZE
VDC_DM3_OFFSET_GAP_MAX EQU 10                            ; ~CELL_SIZE/4
VDC_BALLS_TARGET       EQU 85                            ; classic level 1: start 35 + repeat 50 = 85 (РґР»СЏ РІРѕСЃРїСЂРѕРёР·РІРµРґРµРЅРёСЏ cap-glitch РІ Z80-СЃРёРјСѓР»СЏС‚РѕСЂРµ)
VDC_KZ_FRAMES          EQU 12

; ============================================================================
; VDC_Init вЂ” РѕР±РЅСѓР»РёС‚СЊ state, Slots[] = GAP_STOP. Р”РѕР»Р¶РµРЅ Р±С‹С‚СЊ РІС‹Р·РІР°РЅ 1 СЂР°Р·
; РґРѕ Р»СЋР±РѕРіРѕ VDC_Update / VDC_SlotPos / VDC_InsertAt.
; ============================================================================
VDC_Init:
                ; РЎР»РѕС‚С‹: 240 Р±Р°Р№С‚ = GAP_STOP
                LD   HL, VDC_Slots
                LD   DE, VDC_Slots + 1
                LD   BC, VDC_MAX_SLOTS - 1
                LD   (HL), VDC_GAP_STOP
                LDIR

                ; Offsets, Shot2 вЂ” РІСЃРµ 0
                LD   HL, VDC_Offsets
                LD   DE, VDC_Offsets + 1
                LD   BC, (VDC_MAX_SLOTS * 2) - 1
                LD   (HL), 0
                LDIR

                ; РЎРєР°Р»СЏСЂС‹ вЂ” РЅСѓР»РёРј РїСЂРѕСЃС‚С‹Рј LD
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

                ; Р—Р°РїРѕРјРЅРёС‚СЊ TRACK_NUM_SLOTS (= NumSamples / CELL_SIZE - 1) вЂ”
                ; РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ РєР°Рє cap РґР»СЏ HSA. NumSamples Р»РµР¶РёС‚ РІ TrackData word.
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

                ; LFSR seed: Р±Р°Р·РѕРІС‹Р№ #ACE1, scramble С‡РµСЂРµР· RTC СЃРµРєСѓРЅРґС‹ (low_byte Г—
                ; RTC_sec) вЂ” РєР°Р¶РґС‹Р№ Р·Р°РїСѓСЃРє РїРѕР»СѓС‡Р°РµС‚ СЂР°Р·РЅСѓСЋ starting sequence, РєР°Рє
                ; Сѓ РєРѕР»Р»РµРіРё РІ TS-Conf РІРµСЂСЃРёРё (RandomChainColor scramble).
                LD   HL, #ACE1
                LD   (VDC_LfsrSeed), HL
                CALL ReadRTCSeconds                    ; A = 0..59
                OR   A
                JR   NZ, .seed_have_sec
                LD   A, 17                             ; Р·Р°С‰РёС‚Р° РµСЃР»Рё RTC = 0
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
                ; HL = low_seed * RTC_sec. Р“Р°СЂР°РЅС‚РёСЂСѓРµРј non-zero.
                LD   A, H : OR L
                JR   NZ, .seed_ok
                LD   HL, #1234
.seed_ok:
                LD   (VDC_LfsrSeed), HL
                RET


; ============================================================================
; ReadRTCSeconds вЂ” TS-Conf GLUK CMOS RTC, СЂРµРіРёСЃС‚СЂ 0 (СЃРµРєСѓРЅРґС‹ BCD).
; РџРѕСЂС‚С‹ #DFF7 (Р°РґСЂРµСЃ) / #BFF7 (РґР°РЅРЅС‹Рµ). Out: A = 0..59 binary.
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
; VDC_Update вЂ” РѕРґРёРЅ С€Р°Рі С„РёР·РёРєРё (РІС‹Р·С‹РІР°С‚СЊ СЂР°Р· РІ РєР°РґСЂ).
; Phase 1 (BallsSpawned < LEVEL_START_BALLS): 12Г— MoveChain + 1Г— AnimateChain +
;   1Г— TrySpawn (TrySpawn РІРЅСѓС‚СЂРё loop'РёС‚). Р­С‚Рѕ В«РїРѕРµР·РґВ» РІР»С‘С‚Р° 35 С€Р°СЂРѕРІ Р·Р° ~90 С‚РёРєРѕРІ.
; Phase 2 (BallsSpawned в‰Ґ LEVEL_START_BALLS): 1Г— MoveChain РєР°Р¶РґС‹Р№ РєР°РґСЂ (norm-speed
;   РїРѕРґРѕР±СЂР°РЅ РїРѕРґ VDAC2 CELL_SIZE=42 вЂ” Р±РµР· subdivider /2 РєР°Рє Сѓ РєРѕР»Р»РµРіРё).
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
                ; Fast phase: Г—12 MoveChain (35 С€Р°СЂРѕРІ В«РїРѕРµР·РґРѕРјВ»).
                ; Р’ fast phase spawn Р±РµР· hsub-gate вЂ” РёРЅР°С‡Рµ РїСЂРё wrap-С‡Р°СЃС‚РѕС‚Рµ
                ; CELL_SIZE/12 в‰€ 3 ticks spawn'С‹ СЂРµРґРєРё в†’ fast phase Р»РѕРјР°РµС‚СЃСЏ.
                LD   B, VDC_FAST_ADVANCE
.upd_fast:      PUSH BC
                CALL VDC_MoveChain
                POP  BC
                DJNZ .upd_fast
                CALL VDC_AnimateChain
                JP   VDC_TrySpawn_NoHsubGate
.upd_normal:    ; Normal phase: subdivider /2 + spawn РєР°Р¶РґС‹Рµ 64 РєР°РґСЂР°.
                ; TrySpawn (СЃ hsub-gate) СЃРёРЅС…СЂРѕРЅРµРЅ СЃ Python: spawn С‚РѕР»СЊРєРѕ РєРѕРіРґР°
                ; chain РІС‹СЂРѕРІРЅРµРЅ РїРѕ cell-РіСЂР°РЅРёС†Рµ.
                LD   A, (ZL_FrameCounter)
                AND  1
                RET  NZ                                ; odd frame в†’ skip РІСЃС‘
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
; VDC_SlotT вЂ” РґР»СЏ A=i СЃС‡РёС‚Р°РµС‚ t = (HSA-i)*64 + HSub + sext(offsets[i]).
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
; VDC_SlotPos вЂ” РґР»СЏ A=i РІРѕР·РІСЂР°С‰Р°РµС‚ С†РµРЅС‚СЂ С€Р°СЂР° (X,Y) РёР· TrackData[t].
;   Out: BC = X (signed word), DE = Y (signed word), CF = 0 РµСЃР»Рё СЂРёСЃСѓРµРј,
;        CF = 1 РµСЃР»Рё skip (gap РёР»Рё t<0).
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
                ; t < 0 в†’ skip
                BIT  7, H
                JR   Z, .t_nonneg
                SCF
                RET
.t_nonneg:
                ; t >= NumSamples в†’ clamp to NumSamples-1
                PUSH HL
                LD   DE, (TrackData)                   ; NumSamples
                AND  A
                SBC  HL, DE
                POP  HL
                JR   C, .t_in
                LD   HL, (TrackData)
                DEC  HL
.t_in:
                ; expose t РґР»СЏ caller (РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ РґР»СЏ spin frame РїРѕ track-advance)
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
                LD   (VDC_LastTangent), A              ; expose РґР»СЏ caller
                EX   DE, HL                            ; HL = X (free up DE)
                LD   D, B : LD E, C                    ; DE = Y
                LD   B, H : LD C, L                    ; BC = X
                AND  A                                 ; CF = 0
                RET

; ============================================================================
; VDC_TrySpawn вЂ” СЃРїР°РІРЅ РЅРѕРІРѕРіРѕ С€Р°СЂР° РІ С…РІРѕСЃС‚ (РµСЃР»Рё СЂР°Р·СЂРµС€РµРЅРѕ).
;   РЈСЃР»РѕРІРёСЏ: SlotsLen<MAX, BallsSpawned<TARGET, HSA>=SlotsLen, HSub==0.
; ============================================================================
VDC_TrySpawn:
                ; Public entry: СЃ HSub==0 gate (sync СЃ Python try_spawn).
                ; Fast phase РѕР±С…РѕРґРёС‚ gate С‡РµСЂРµР· VDC_TrySpawn_NoHsubGate.
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

                ; HSA < SlotsLen в†’ РЅРµ СЃРїР°РІРЅРёРј (С…РІРѕСЃС‚ РЅРµ РґРѕСЃС‚РёРі СЃС‚Р°СЂС‚Р°)
                LD   A, (VDC_SlotsLen)
                LD   B, A                              ; B = SlotsLen
                LD   A, (VDC_HSA)
                CP   B
                RET  C

                ; SlotsLen > 0 AND offsets[tail-1] != 0 в†’ РЅРµ СЃРїР°РІРЅРёРј (С…РІРѕСЃС‚ РµС‰С‘ РґРІРёРіР°РµС‚СЃСЏ).
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
                ; Р•СЃР»Рё SlotsLen>=2 Рё Slots[len-1]==Slots[len-2]==candidate в†’ +1 mod NUM
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
                RET                                    ; single-shot per tick (= Python РєРѕР»Р»РµРіРё).
                                                       ; РњРЅРѕР¶РµСЃС‚РІРµРЅРЅС‹Р№ spawn РґР°С‘С‚ instant chain growth = РґС‘СЂРіР°РЅРѕСЃС‚СЊ.

; ============================================================================
; VDC_MoveChain вЂ” HSub++ РµСЃР»Рё chain РЅРµ frozen; wrap в†’ HSA++.
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
                ; HSA++ СЃ cap РїРѕ TrackNumSlots-1
                LD   HL, (VDC_TrackNumSlots)           ; max
                LD   A, (VDC_HSA)
                LD   E, A : LD D, 0
                AND  A
                SBC  HL, DE
                JR   Z, .mc_at_max                     ; HSA == max в†’ stop
                JR   C, .mc_at_max
                LD   HL, VDC_HSA
                INC  (HL)
.mc_at_max:
                RET
.mc_save_sub:
                LD   (VDC_HSub), A
                RET

; ============================================================================
; VDC_AnimateChain вЂ” decay offsets Рє 0 В±1, gap_step_counter, РїСЂРё wrap в†’ DoGapStep.
; РџРѕСЃР»Рµ вЂ” ScanForNewMatch + UpdateStall.
; ============================================================================
VDC_AnimateChain:
                ; --- 1. decay offsets (rollback_counter РЅРµ СЂРµР°Р»РёР·РѕРІР°РЅ вЂ” РЅРµС‚
                ; РєРѕРґР° РєРѕС‚РѕСЂС‹Р№ Р±С‹ РµРіРѕ РІС‹СЃС‚Р°РІР»СЏР»; РґРµРєР°Р№ РёРґС‘С‚ СЃСЂР°Р·Сѓ Рє 0).
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
                SUB  VDC_DECAY_POS                     ; pos (cascade rollback) в†’ 0 РїР»Р°РІРЅРѕ
                JR   NC, .ac_decay_store
                XOR  A                                 ; clamp 0
                JR   .ac_decay_store
.ac_decay_neg:  ADD  A, VDC_DECAY_NEG                  ; neg (insert head slide) в†’ 0 Р±С‹СЃС‚СЂРѕ
                JR   Z, .ac_decay_store
                BIT  7, A
                JR   NZ, .ac_decay_store               ; РµС‰С‘ РѕС‚СЂРёС†Р°С‚РµР»СЊРЅС‹Р№
                XOR  A                                 ; overshoot в†’ 0
.ac_decay_store:
                LD   (HL), A
.ac_decay_skip:
                INC  HL
                DJNZ .ac_decay
.ac_after_decay:
                ; --- 2. GapStepCnt++; РїСЂРё cnt>=GAP_STEP_FRAMES в†’ DoGapStep (Р±РµР·
                ; hsub==0 constraint, РёРЅР°С‡Рµ Р·Р°Р·РѕСЂ РјРµР¶РґСѓ decay-end Рё next gap_step
                ; в†’ head moves forward; СЃРј. Python emulator + С‡Р°С‚ 2026-05-12).
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
; VDC_DetectMatch3 вЂ” РґР»СЏ idx РІ (TmpInsIdx) РёС‰РµС‚ run >= 3 РѕРґРёРЅР°РєРѕРІС‹С… С†РІРµС‚РѕРІ
; РІРѕРєСЂСѓРі idx СЃ offset gap check'РѕРј. Out: A=1 РµСЃР»Рё РјР°С‚С‡ (TmpML/TmpMR/TmpMC Р·Р°РїРѕР»РЅРµРЅС‹),
; A=0 РёРЅР°С‡Рµ.
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
                JP   NC, .dm3_no                       ; gap в†’ РЅРµ С†РµРЅС‚СЂ
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

                ; offset gap РґР»СЏ right
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
; VDC_CheckMatch3 вЂ” DetectMatch3 + РµСЃР»Рё РјР°С‚С‡: GAP_STOP/GAP_CASCADE marker, Slots/Offsets,
; Shot2 РЅР° СЃРѕСЃРµРґСЏС…, ChainStalled, GapStepCnt=GAP_STEP_FRAMES, ChainFreezeCnt=CELL_SIZE.
; A=1 РµСЃР»Рё Р±С‹Р» РјР°С‚С‡, A=0 РёРЅР°С‡Рµ.
; ============================================================================
VDC_CheckMatch3:
                CALL VDC_DetectMatch3
                OR   A
                JP   Z, .m3_no

                ; default marker GAP_STOP
                LD   B, VDC_GAP_STOP

                ; CASCADE check: lb>0 & rb+1<len & Slots[lb-1] Рё Slots[rb+1] РѕР±e non-gap
                ; Рё РѕРґРЅРѕРіРѕ С†РІРµС‚Р°.
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_have_marker                ; lb=0 в†’ STOP
                LD   HL, VDC_SlotsLen
                LD   A, (VDC_TmpMR)
                INC  A
                CP   (HL)
                JR   NC, .m3_have_marker               ; rb+1>=len в†’ STOP

                LD   A, (VDC_TmpML)
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   C, (HL)                           ; C = Slots[lb-1]
                LD   A, C
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap в†’ STOP

                LD   A, (VDC_TmpMR)
                INC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Slots
                ADD  HL, DE
                LD   A, (HL)
                CP   VDC_NUM_COLORS
                JR   NC, .m3_have_marker               ; gap в†’ STOP
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

                ; Shot2[lb-1]=1 РµСЃР»Рё lb>0
                LD   A, (VDC_TmpML)
                OR   A
                JR   Z, .m3_no_left_shot2
                DEC  A
                LD   H, 0 : LD L, A
                LD   DE, VDC_Shot2
                ADD  HL, DE
                LD   (HL), 1
.m3_no_left_shot2:
                ; Shot2[rb+1]=1 РµСЃР»Рё rb+1<len
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
                ; Instant gap_step вЂ” РёРЅР°С‡Рµ chain motion РІ waiting period (РґРѕ hsub=0)
                ; РґРІРёРіР°РµС‚ head РІРїРµСЂС‘Рґ, Р° РґРѕР»Р¶РµРЅ СЃС‚РѕСЏС‚СЊ Рё Р¶РґР°С‚СЊ С…РІРѕСЃС‚. РЎ РїРµСЂРІС‹Рј
                ; instant gap_step head РїРѕР»СѓС‡Р°РµС‚ +CS offset compensation СЃСЂР°Р·Сѓ
                ; в†’ stationary РґРѕ РєРѕРЅС†Р° decay phase. РћСЃС‚Р°Р»СЊРЅС‹Рµ markers Р¶РґСѓС‚
                ; СЃР»РµРґСѓСЋС‰РµРіРѕ GAP_STEP_FRAMES (Р±РµР· hsub=0 constraint).
                XOR  A
                LD   (VDC_GapStepCnt), A
                CALL VDC_DoGapStep
                LD   A, 1
                RET
.m3_no:
                XOR  A
                RET

; ============================================================================
; VDC_DoGapStep вЂ” РѕР±СЂР°Р±Р°С‚С‹РІР°РµС‚ РћР”РРќ РјР°СЂРєРµСЂ Р·Р° РІС‹Р·РѕРІ. Pass 1: STOP from tail
; (rightв†’left), СѓРґР°Р»СЏРµС‚ slot, HSA--, head compensation. Pass 2 (РµСЃР»Рё STOP РЅРµ Р±С‹Р»Рѕ):
; CASCADE from head (leftв†’right), С‚Рѕ Р¶Рµ + ChainFreezeCnt = CELL_SIZE.
; ============================================================================
VDC_DoGapStep:
                ; --- Pass 1: РёС‰РµРј РїРѕСЃР»РµРґРЅРёР№ GAP_STOP СЃРїСЂР°РІР° РЅР°Р»РµРІРѕ ---
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .dgs_cascade_init
                DEC  A
                LD   C, A                              ; C = idx (РѕС‚ len-1)
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
                CALL VDC_RemoveSlotAt                  ; СѓРґР°Р»СЏРµС‚ slot C, len-=1
                CALL VDC_HsaDec                        ; HSA-- РµСЃР»Рё >0

                ; offsets[0..K-1] = min(off[j]+CS, CS) вЂ” head compensation
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
                ; MatchScanIdx = K (РґР»СЏ РёРЅС„РѕСЂРјР°С‚РёРІРЅРѕСЃС‚Рё; persistent scan РїРѕ Shot2 РІСЃС‘ СЂР°РІРЅРѕ Р»РѕРІРёС‚)
                LD   A, (VDC_TmpGapIdx)
                LD   (VDC_MatchScanIdx), A
                ; Shot2 РЅР° СЃРѕСЃРµРґСЏС… K-1 Рё K (РїРѕСЃР»Рµ shift), РµСЃР»Рё РѕРЅРё non-gap.
                CALL VDC_SetShot2OnNeighbors
                RET

.dgs_cascade_init:
                ; --- Pass 2: РёС‰РµРј РїРµСЂРІС‹Р№ GAP_CASCADE СЃР»РµРІР° ---
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
                ; Old asm: cap'РёР» positive offsets Рє CELL_SIZE INSTEAD ADD вЂ” СЌС‚Рѕ
                ; РґР°РІР°Р»Рѕ instant jump РЅР° +(CELL_SIZE-offset) РїСЂРё positive mid-decay.
                LD   A, (HL)
                ADD  A, VDC_CELL_SIZE                  ; offset + CELL_SIZE
                CP   VDC_CELL_SIZE + 1
                JR   C, .dgs_casc_off_save             ; A в‰¤ CELL_SIZE в†’ save
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
; VDC_RemoveSlotAt вЂ” СѓРґР°Р»СЏРµС‚ slot (VDC_TmpGapIdx). Shift_left +
; SlotsLen-=1. Р—Р°С‚СЂР°РіРёРІР°РµС‚ Slots, Offsets, Shot2, RollbackCnt.
; ----------------------------------------------------------------------------
VDC_RemoveSlotAt:
                LD   A, (VDC_SlotsLen)
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpGapIdx)
                LD   C, A                              ; C = idx
                LD   A, B
                SUB  C
                DEC  A                                 ; count = len - idx - 1
                JR   Z, .rsa_no_shift                  ; idx == len-1 в†’ РЅРёС‡РµРіРѕ РЅРµ РґРІРёРіР°С‚СЊ
                LD   E, A                              ; E = count

                ; Shift Slots[idx+1..len-1] в†’ Slots[idx..len-2]
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
                POP  HL                                ; (РІРѕСЃСЃС‚Р°РЅРѕРІРёР»Рё src=&Slots[idx+1])

                ; РђРЅР°Р»РѕРіРёС‡РЅРѕ РґР»СЏ Offsets, Shot2, RollbackCnt
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
; VDC_HsaDec вЂ” HSA-- РµСЃР»Рё HSA>0, РёРЅР°С‡Рµ nop.
; ----------------------------------------------------------------------------
VDC_HsaDec:
                LD   A, (VDC_HSA)
                OR   A
                RET  Z
                DEC  A
                LD   (VDC_HSA), A
                RET

; ----------------------------------------------------------------------------
; VDC_SetShot2OnNeighbors вЂ” РїРѕСЃР»Рµ СѓРґР°Р»РµРЅРёСЏ slot K (TmpGapIdx) РїРѕСЃС‚Р°РІРёС‚СЊ Shot2
; РЅР° K-1 Рё K (РµСЃР»Рё non-gap, РІ bounds).
; ----------------------------------------------------------------------------
VDC_SetShot2OnNeighbors:
                LD   A, (VDC_TmpGapIdx)
                OR   A
                JR   Z, .ssn_skip_left
                ; K-1: РїСЂРѕРІРµСЂРёС‚СЊ < SlotsLen Рё not gap
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
                ; K: РїСЂРѕРІРµСЂРёС‚СЊ < SlotsLen Рё not gap
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
; VDC_ScanForNewMatch вЂ” РїСЂРѕС…РѕРґРёС‚ Shot2[0..len-1], РїСЂРё is_gap С‡РёСЃС‚РёС‚, РёРЅР°С‡Рµ
; CheckMatch3, РёРЅР°С‡Рµ РµСЃР»Рё settled (РІСЃРµ offsets РІРѕРєСЂСѓРі 0) вЂ” С‡РёСЃС‚РёС‚ Shot2.
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

                ; Slots[C] is gap? в†’ clear Shot2
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
                RET  NZ                                ; match в†’ РІС‹С…РѕРґРёРј

                ; settled check: offset[C], [C-1], [C+1] all 0 в†’ clear Shot2
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
; VDC_InsertAt вЂ” РІСЃС‚Р°РІРёС‚СЊ С€Р°СЂ С†РІРµС‚Р° B РІ РїРѕР·РёС†РёСЋ A (=target_idx).
; Shift right Slots/Offsets/Shot2/RollbackCnt[A..len-1] в†’ A+1..len.
; new_off = -CS/2 + (head_off + tail_off)/2.
; HSA++ СЃ cap, offsets[0..A-1] -= CS СЃ cap -CS, ChainFreezeCnt = CS,
; СЃС‚Р°РІРёС‚ Shot2 РЅР° A, CheckMatch3.
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
                ; SlotsLen >= MAX в†’ fail (silent)
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
                ;   slots_len==0           в†’ head=tail=0
                ;   target_idx==0          в†’ head=tail=offsets[0]
                ;   target_idx==slots_len  в†’ head=tail=offsets[len-1]
                ;   else                   в†’ head=offsets[idx-1], tail=offsets[idx]
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
                ; new_off = -CS/2 + (head + tail) / 2 вЂ” РІСЃРµ signed Р±С‹С‚РѕРІРѕРµ СЃР»РѕР¶РµРЅРёРµ.
                ; РЎС‡РёС‚Р°РµРј РєР°Рє 16-bit signed РґР»СЏ Р±РµР·РѕРїР°СЃРЅРѕСЃС‚Рё РѕС‚ РїРµСЂРµРїРѕР»РЅРµРЅРёСЏ.
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

                ; --- shift right: Slots[idx..len-1] в†’ idx+1..len ---
                ; РСЃРїРѕР»СЊР·СѓРµРј LDDR (РѕС‚ С…РІРѕСЃС‚Р°), С‡С‚РѕР±С‹ РЅРµ Р·Р°С‚РёСЂР°С‚СЊ.
                LD   A, (VDC_SlotsLen)
                OR   A
                JR   Z, .ia_no_shift                   ; len==0 в†’ РЅРµС‡РµРіРѕ СЃРґРІРёРіР°С‚СЊ
                LD   B, A                              ; B = len
                LD   A, (VDC_TmpInsIdx)
                CP   B
                JR   NC, .ia_no_shift                  ; idx>=len в†’ РЅРµС‡РµРіРѕ СЃРґРІРёРіР°С‚СЊ
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

                ; HSA++ СЃ cap РїРѕ TrackNumSlots-1.
                ; Cap-fix (Z80-СЃРёРјСѓР»СЏС‚РѕСЂ verify 2026-05-14): РїСЂРё HSA == TrackNumSlots-1
                ; HSA++ skip в†’ РЅСѓР¶РЅР° РєРѕРјРїРµРЅСЃР°С†РёСЏ:
                ;   1) skip head_comp (offsets[0..idx-1] РѕСЃС‚Р°СЋС‚СЃСЏ РєР°Рє РїРѕСЃР»Рµ shift_right = 0)
                ;   2) new ball offset = +CS/2 РІРјРµСЃС‚Рѕ -CS/2
                ;   3) offsets[idx+1..SlotsLen-1] += CS
                ; РўРѕРіРґР° t(i) = (HSA - i)*CS + off СЃРѕРІРїР°РґР°РµС‚ СЃ РЅРѕСЂРјР°Р»СЊРЅС‹Рј flow РїСЂРё HSA=cap+1.
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
                ; --- Cap compensation: РїРµСЂРµРїРёСЃР°С‚СЊ offsets[idx] РЅР° +CS/2 (Р±С‹Р» -CS/2) ---
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
; VDC_ShiftRight_* вЂ” СЃРґРІРёРі РјР°СЃСЃРёРІР° Array[idx..len-1] в†’ Array[idx+1..len].
; РРґС‘Рј С‡РµСЂРµР· LDDR (HL = src=last, DE = dst=last+1, BC = count).
; РСЃРїРѕР»СЊР·СѓРµС‚ VDC_TmpInsIdx, VDC_SlotsLen.
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
; VDC_DivHLbyA вЂ” С†РµР»РѕС‡РёСЃР»РµРЅРЅРѕРµ РґРµР»РµРЅРёРµ 16-bit РЅР° 8-bit.
;   In:  HL = dividend (unsigned), A = divisor (unsigned, > 0)
;   Out: HL = quotient, A = remainder
;   Clobbers BC.
; Bit-by-bit Р°Р»РіРѕСЂРёС‚Рј. ~80 t-states, ~16 Р±Р°Р№С‚ РєРѕРґР°.
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
                INC  L                                 ; HL[0] Р±С‹Р» 0 РїРѕСЃР»Рµ ADD, С‚РµРїРµСЂСЊ 1
.dv_skip:
                DJNZ .dv_loop
                RET

; ============================================================================
; VDC_RandomColor вЂ” LFSR Galois 16-bit (poly 0xB400). Out: A = 0..NUM_COLORS-1.
; Р Р°СЃРїСЂРµРґРµР»РµРЅРёРµ: РёСЃРїРѕР»СЊР·СѓРµРј (rand8 * NUM_COLORS) >> 8 РІРјРµСЃС‚Рѕ AND 7 + clamp,
; РёРЅР°С‡Рµ РІ 6-С†РІРµС‚РѕРІРѕРј СЃР»СѓС‡Р°Рµ colors 0/1 РІСЃС‚СЂРµС‡Р°СЋС‚СЃСЏ 2Г— С‡Р°С‰Рµ РѕСЃС‚Р°Р»СЊРЅС‹С…
; (8 mod 6 = 2 в†’ РґСѓР±Р»Рё 6в†’0 Рё 7в†’1). Mul/shift РґР°С‘С‚ в‰¤1.4% bias.
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
; STATE вЂ” РјР°СЃСЃРёРІС‹ Рё СЃРєР°Р»СЏСЂС‹. SAVEBIN РёС… СЃРѕС…СЂР°РЅРёС‚ РєР°Рє РЅСѓР»Рё; VDC_Init
; СЏРІРЅРѕ РёРЅРёС†РёР°Р»РёР·РёСЂСѓРµС‚ РЅР° СЃС‚Р°СЂС‚Рµ (СЃРј. feedback_zuma_init_explicit.md).
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
VDC_LastTangent:  DEFB 0                                ; tangent Р±Р°Р№С‚ РїРѕСЃР»РµРґРЅРµРіРѕ VDC_SlotPos
VDC_LastT:        DEFW 0                                ; t (16-bit signed) РїРѕСЃР»РµРґРЅРµРіРѕ VDC_SlotPos вЂ” РґР»СЏ spin frame РїРѕ track-advance

                endif ; ~_ZUMA_VDC_
