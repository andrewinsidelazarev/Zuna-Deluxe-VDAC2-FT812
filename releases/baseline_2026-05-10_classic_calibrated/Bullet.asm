; ============================================================================
; Bullet.asm — летящий шар (одиночный выстрел из лягушки).
;
; State: Active flag + позиция (X,Y signed 16-bit) + velocity (VX,VY signed 8-bit)
; + color (0..5).  Spawn в start-fire (Frog_HandleMouse / Frog_FireKeyboard).
; Update каждый кадр (X += VX, Y += VY).  Out-of-screen → deactivate.
; Render — handle 0 chain atlas, тот же что ball-now/next-ball/chain.
;
; Этап 1 (текущий): только полёт + render. Без collision/insert в chain.
; ============================================================================

BULLET_SPEED        EQU 12                            ; px/frame, ~684 px/sec @57Hz
BULLET_SPRITE_HALF  EQU 16                            ; chain atlas 32×32 native classic
BULLET_HIT_THR      EQU 16                            ; bbox half-side: |dx|<THR && |dy|<THR


; ----------------------------------------------------------------------------
; Bullet_Init — обнулить state.
; ----------------------------------------------------------------------------
Bullet_Init:        XOR  A
                    LD   (Bullet_Active), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Spawn — вызывается из Frog start-fire (LMB или SPACE).
; Berёт цвет из Frog_BallColor (= уже промотировано из NextBallColor),
; angle из Frog_Angle, spawn position из Frog_PosStartX/Y (центр лягушки).
; Velocity = BULLET_SPEED * (cos(angle), sin(angle)) / 128.
; ----------------------------------------------------------------------------
Bullet_Spawn:       LD   A, (Bullet_Active)
                    OR   A
                    RET  NZ                           ; уже в полёте — single bullet MVP
                    LD   A, 1
                    LD   (Bullet_Active), A
                    LD   A, (Frog_BallColor)
                    LD   (Bullet_Color), A

                    LD   HL, (Frog_PosStartX)
                    LD   (Bullet_X), HL
                    LD   HL, (Frog_PosStartY)
                    LD   (Bullet_Y), HL

                    ; VX = (cos(angle) * BULLET_SPEED) / 128 (signed)
                    LD   A, (Frog_Angle)
                    ADD  A, 64                        ; cos = sin(angle + 64)
                    CALL Frog_LookupSin
                    LD   B, A
                    LD   A, BULLET_SPEED
                    LD   C, A
                    CALL Frog_SignedScale_div128
                    LD   (Bullet_VX), A

                    ; VY = (sin(angle) * BULLET_SPEED) / 128 (signed)
                    LD   A, (Frog_Angle)
                    CALL Frog_LookupSin
                    LD   B, A
                    LD   A, BULLET_SPEED
                    LD   C, A
                    CALL Frog_SignedScale_div128
                    LD   (Bullet_VY), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Update — X += VX, Y += VY каждый кадр. Deactivate если за экран.
; ----------------------------------------------------------------------------
Bullet_Update:      LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    LD   A, (Bullet_VX)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_X)
                    ADD  HL, DE
                    LD   (Bullet_X), HL
                    ; out-of-screen X check (signed)
                    BIT  7, H
                    JR   NZ, .deactivate              ; X < 0
                    LD   DE, 640
                    AND  A
                    SBC  HL, DE
                    JR   NC, .deactivate              ; X ≥ 640

                    LD   A, (Bullet_VY)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_Y)
                    ADD  HL, DE
                    LD   (Bullet_Y), HL
                    BIT  7, H
                    JR   NZ, .deactivate
                    LD   DE, 480
                    AND  A
                    SBC  HL, DE
                    RET  C                            ; Y < 480 → ОК
.deactivate:        XOR  A
                    LD   (Bullet_Active), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_CheckCollision — итерация по chain slots.  При Manhattan(bullet, slot)
; < BULLET_HIT_THR → VDC_InsertAt(slot_idx, color), Active=0.
; ----------------------------------------------------------------------------
Bullet_CheckCollision:
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z
                    LD   A, (VDC_SlotsLen)
                    OR   A
                    RET  Z
                    LD   B, A                          ; B = loop count
                    LD   C, 0                          ; C = i
.bcc_loop:          PUSH BC
                    LD   A, C
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=skip
                    JR   C, .bcc_skip
                    ; bbox check: |Bullet_X - X| < THR
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   NZ, .bcc_skip                 ; |dx| > 255 → too far
                    LD   A, L
                    CP   BULLET_HIT_THR
                    JR   NC, .bcc_skip                 ; |dx| ≥ thr → too far
                    ; bbox check: |Bullet_Y - Y| < THR
                    LD   HL, (Bullet_Y)
                    AND  A
                    SBC  HL, DE
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   NZ, .bcc_skip
                    LD   A, L
                    CP   BULLET_HIT_THR
                    JR   NC, .bcc_skip
                    ; HIT — hemisphere insert: target = i или i+1 по ближайшему neighbour.
                    POP  BC                            ; B=count, C=hit_idx
                    LD   A, C
                    CALL Bullet_HemisphereTarget       ; A = target_idx (i или i+1)
                    LD   C, A                          ; save target
                    LD   A, (Bullet_Color)
                    LD   B, A
                    LD   A, C
                    CALL VDC_InsertAt
                    XOR  A
                    LD   (Bullet_Active), A
                    RET
.bcc_skip:          POP  BC
                    INC  C
                    DEC  B
                    JP   NZ, .bcc_loop
                    RET


; ----------------------------------------------------------------------------
; Bullet_HemisphereTarget — A = hit_idx (slot куда попал bullet).
; Возвращает A = target_idx (i или i+1) — куда вставить.
; Логика: считаем Manhattan dist до prev (i-1) и next (i+1) non-gap соседей,
; вставляем со стороны более близкого соседа.
; Out: A = i или i+1.  Corrupts BC, DE, HL.
; ----------------------------------------------------------------------------
Bullet_HemisphereTarget:
                    LD   (Bullet_TmpHit), A
                    ; default target = hit
                    ; --- find prev non-gap (k < hit) ---
                    LD   (Bullet_TmpDistP+1), A        ; init prev_dist = 255 (= нет prev)
                    LD   A, 255
                    LD   (Bullet_TmpDistP), A
                    LD   (Bullet_TmpDistN), A          ; default next_dist = 255
                    LD   A, (Bullet_TmpHit)
                    OR   A
                    JR   Z, .ht_skip_prev              ; hit=0 → нет prev
                    DEC  A
.ht_prev_loop:      LD   (Bullet_TmpScan), A
                    LD   H, 0 : LD L, A
                    LD   DE, VDC_Slots
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_prev_found             ; non-gap
                    LD   A, (Bullet_TmpScan)
                    OR   A
                    JR   Z, .ht_skip_prev
                    DEC  A
                    JR   .ht_prev_loop
.ht_prev_found:     LD   A, (Bullet_TmpScan)
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=skip
                    JR   C, .ht_skip_prev
                    CALL Bullet_ManhattanToBC_DE       ; A = |bx-X|+|by-Y| (clamped 255)
                    LD   (Bullet_TmpDistP), A
.ht_skip_prev:
                    ; --- find next non-gap (k > hit) ---
                    LD   A, (Bullet_TmpHit)
                    INC  A
                    LD   (Bullet_TmpScan), A
                    LD   B, A
                    LD   A, (VDC_SlotsLen)
                    CP   B
                    JR   C, .ht_decide                 ; scan >= len → нет next
                    JR   Z, .ht_decide
.ht_next_loop:      LD   A, (Bullet_TmpScan)
                    LD   H, 0 : LD L, A
                    LD   DE, VDC_Slots
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_next_found
                    LD   A, (Bullet_TmpScan)
                    INC  A
                    LD   (Bullet_TmpScan), A
                    LD   B, A
                    LD   A, (VDC_SlotsLen)
                    CP   B
                    JR   Z, .ht_decide
                    JR   C, .ht_decide
                    JR   .ht_next_loop
.ht_next_found:     LD   A, (Bullet_TmpScan)
                    CALL VDC_SlotPos
                    JR   C, .ht_decide
                    CALL Bullet_ManhattanToBC_DE
                    LD   (Bullet_TmpDistN), A
.ht_decide:
                    ; if dist_next < dist_prev → target = hit + 1, else hit
                    LD   A, (Bullet_TmpDistN)
                    LD   B, A
                    LD   A, (Bullet_TmpDistP)
                    CP   B
                    LD   A, (Bullet_TmpHit)
                    RET  C                             ; prev < next → target=hit
                    INC  A                             ; next ≤ prev → target=hit+1
                    RET


; ----------------------------------------------------------------------------
; Bullet_ManhattanToBC_DE — A = |Bullet_X - BC| + |Bullet_Y - DE| clamped 255.
; ----------------------------------------------------------------------------
Bullet_ManhattanToBC_DE:
                    PUSH DE                            ; save Y
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   Z, .mh_dx_ok
                    LD   L, 255
.mh_dx_ok:          LD   B, L                          ; B = |dx| clamped
                    POP  DE                            ; restore Y
                    LD   HL, (Bullet_Y)
                    AND  A
                    SBC  HL, DE
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   Z, .mh_dy_ok
                    LD   L, 255
.mh_dy_ok:          LD   A, L
                    ADD  A, B                          ; |dy| + |dx|
                    RET  NC
                    LD   A, 255                        ; sat
                    RET


; ----------------------------------------------------------------------------
; Bullet_AbsHL — HL = |HL| (signed → unsigned magnitude).
; ----------------------------------------------------------------------------
Bullet_AbsHL:       BIT  7, H
                    RET  Z
                    LD   A, H : CPL : LD H, A
                    LD   A, L : CPL : LD L, A
                    INC  HL
                    RET


; ----------------------------------------------------------------------------
; Bullet_SignExtendA_HL — HL = sign-extended A.
; ----------------------------------------------------------------------------
Bullet_SignExtendA_HL:
                    LD   H, 0
                    BIT  7, A
                    JR   Z, .pp
                    DEC  H
.pp:                LD   L, A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Draw — render bullet sprite в DL.  handle 0 chain atlas.
; Cell = Bullet_Color * 8 (без spin — один кадр).  Reset matrix.
; ----------------------------------------------------------------------------
Bullet_Draw:        LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    CALL ZL_EmitLoadId
                    CALL ZL_EmitSetMatrix

                    FT_BitmapHandle 0
                    FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                    FT_BitmapLayout FT_ARGB4, 32 * 2, 32
                    FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, 32, 32
                    FT_Begin FT_BITMAPS
                    LD   A, (Bullet_Color)
                    ADD  A, A : ADD A, A : ADD A, A : ADD A, A   ; * 16 (cell = color*16)
                    CALL FT.Coprocessor.Cell
                    ; Vertex2f((X - 28) * 16, (Y - 28) * 16)
                    LD   HL, (Bullet_X)
                    LD   DE, BULLET_SPRITE_HALF
                    AND  A
                    SBC  HL, DE
                    ADD  HL, HL : ADD HL, HL
                    ADD  HL, HL : ADD HL, HL
                    LD   B, H : LD C, L
                    LD   HL, (Bullet_Y)
                    LD   DE, BULLET_SPRITE_HALF
                    AND  A
                    SBC  HL, DE
                    ADD  HL, HL : ADD HL, HL
                    ADD  HL, HL : ADD HL, HL
                    EX   DE, HL
                    CALL FT.Coprocessor.Vertex2f
                    FT_End
                    RET


; ----------------------------------------------------------------------------
Bullet_Active:      DEFB 0
Bullet_X:           DEFW 0
Bullet_Y:           DEFW 0
Bullet_VX:          DEFB 0
Bullet_VY:          DEFB 0
Bullet_Color:       DEFB 0
Bullet_TmpHit:      DEFB 0                            ; hemisphere scratch
Bullet_TmpScan:     DEFB 0
Bullet_TmpDistP:    DEFB 0
Bullet_TmpDistN:    DEFB 0
