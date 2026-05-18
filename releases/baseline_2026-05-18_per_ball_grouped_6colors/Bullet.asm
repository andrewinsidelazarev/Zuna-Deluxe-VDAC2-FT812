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
BULLET_HIT_THR      EQU 30                            ; bbox prefilter: |dx|<THR && |dy|<THR.
BULLET_HIT_MANHATTAN_THR EQU 46                       ; reject far bbox corners (30+30 looks wrong).
                                                      ; D=32: trigger when sprites edges touch (~slight magnet).
                                                      ; Was 16 (= D/2) → bullet provalivалsя half-deep before hit (Gemini fix 2026-05-16).


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
                    JR   Z, .bs_free
                    SCF
                    RET
.bs_free:
                    RET  NZ                           ; уже в полёте — single bullet MVP
                    LD   A, 1
                    LD   (Bullet_Active), A
                    LD   A, (Frog_BallColor)
                    LD   (Bullet_Color), A

                    LD   HL, (Frog_PosStartX)
                    LD   (Bullet_X), HL
                    LD   HL, (Frog_PosStartY)
                    LD   (Bullet_Y), HL

                    CALL LogShotFired                 ; SHOT_FIRED event

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
                    OR   A
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
; Bullet_CheckCollision — итерация по chain slots.  Находит ближайший шар
; (min Manhattan dist) среди тех, что попали в bbox BULLET_HIT_THR.
; Если найден → VDC_InsertAt(target_idx, color), Active=0.
; ----------------------------------------------------------------------------
Bullet_CheckCollision:
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z
                    LD   A, (VDC_SlotsLen)
                    OR   A
                    RET  Z
                    LD   B, A                          ; B = loop count = SlotsLen (BUG fix 2026-05-16
                                                       ; from Codex: было LD B, A после LD A,255 → B=255,
                                                       ; loop сканировал stale slots за SlotsLen)

                    ; init best-hit scratch
                    LD   A, 255
                    LD   (Bullet_TmpHit), A
                    LD   (Bullet_TmpDistP), A

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

                    ; BBOX HIT — calculate Manhattan distance and update best
                    PUSH BC                            ; [1] save X
                    PUSH DE                            ; [2] save Y
                    CALL Bullet_ManhattanToBC_DE       ; A = distance
                    POP  DE                            ; [2] restore Y
                    POP  BC                            ; [1] restore X
                    CP   BULLET_HIT_MANHATTAN_THR
                    JR   NC, .bcc_skip                 ; diagonal bbox corner -> visually too far
                    
                    LD   HL, Bullet_TmpDistP
                    CP   (HL)
                    JR   NC, .bcc_skip                 ; dist >= best_dist → skip
                    
                    ; NEW BEST
                    LD   (HL), A                       ; update best_dist
                    ; Get current i (C) from stack (it was PUSHed at .bcc_loop)
                    LD   HL, 0
                    ADD  HL, SP
                    LD   A, (HL)                       ; A = C (low byte of outer PUSH BC)
                    LD   (Bullet_TmpHit), A            ; update best_idx

.bcc_skip:          POP  BC
                    INC  C
                    DEC  B
                    JP   NZ, .bcc_loop

                    ; Finalize: if Bullet_TmpHit != 255 → perform insert
                    LD   A, (Bullet_TmpHit)
                    CP   255
                    RET  Z                             ; no hit

                    CALL LogBboxHit                    ; in: A=best_hit_idx (preserved)

                    LD   (Bullet_TmpHit), A            ; ensure it's there
                    CALL Bullet_HemisphereTarget       ; A = target_idx
                    CALL LogHemi                       ; in: A=target_idx (preserved)

                    LD   C, A                          ; save target
                    LD   A, (Bullet_Color)
                    LD   B, A
                    LD   A, C
                    CALL VDC_InsertAt
                    XOR  A
                    LD   (Bullet_Active), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_HemisphereTarget — A = hit_idx (slot куда попал bullet).
;   Находит target_idx (i или i+1) на основе того, к какому соседу (prev/next)
;   пуля ближе. Если соседа нет (край цепи), сравниваем с самим hit.
; ----------------------------------------------------------------------------
Bullet_HemisphereTarget:
                    LD   (Bullet_TmpHit), A
                    ; default target = hit
                    ; --- find prev non-gap (k < hit) ---
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
                    JR   C, .ht_prev_found
                    LD   A, (Bullet_TmpScan)
                    OR   A
                    JR   Z, .ht_skip_prev              ; дошли до 0
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
                    ; Если одного из соседей нет, сравниваем дистанцию до "hit" с оставшимся соседом.
                    LD   A, (Bullet_TmpDistP)
                    CP   255
                    JR   NZ, .ht_check_next
                    ; нет prev (hit=0 или все перед ним GAP) → считаем dist(bullet, hit)
                    LD   A, (Bullet_TmpHit)
                    CALL VDC_SlotPos
                    CALL Bullet_ManhattanToBC_DE
                    LD   (Bullet_TmpDistP), A
.ht_check_next:
                    LD   A, (Bullet_TmpDistN)
                    CP   255
                    JR   NZ, .ht_final_compare
                    ; нет next (hit=len-1) → считаем dist(bullet, hit) как "next_dist"
                    LD   A, (Bullet_TmpHit)
                    CALL VDC_SlotPos
                    CALL Bullet_ManhattanToBC_DE
                    LD   (Bullet_TmpDistN), A

.ht_final_compare:
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
; Cell = Bullet_Color * 16 (без spin — один кадр).  Matrix должна быть identity.
; ----------------------------------------------------------------------------
Bullet_Draw:        LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    ; Fix 2026-05-14 (Codex подход A): гарантируем identity matrix
                    ; перед draw — иначе если matrix унаследована от tongue/body
                    ; rotation, bullet sprite рисуется в неправильном месте экрана.
                    CALL ZL_EmitLoadId
                    CALL ZL_EmitSetMatrix

                    ; Dual handle 6-color через helper. color<4: handle 0; color>=4: handle 9.
                    ; B-clobber fix 2026-05-18: re-read Bullet_Color из памяти после
                    ; макросов FT_BitmapLayout/Size (которые клобают BCDE), а не из B.
                    LD   A, (Bullet_Color)
                    CP   4
                    LD   A, 0
                    JR   C, .bullet_h
                    LD   A, 9
.bullet_h:          CALL ZL_EmitBallHandle
                    FT_BitmapLayout FT_ARGB4, 32 * 2, 32
                    FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, 32, 32
                    LD   A, (Bullet_Color)                 ; re-read color (B clobbered macros)
                    AND  3                                 ; local color (0..3)
                    ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A   ; *32 = local cell
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
