; ============================================================================
; Bullet.asm — летящий шар (одиночный выстрел из лягушки).
;
; Состояние: Active flag, позиция X/Y (signed 16-bit), velocity VX/VY
; (signed 8-bit), цвет 0..5. Spawn вызывается из start-fire
; (Frog_HandleMouse / Frog_FireKeyboard).
; Update каждый кадр двигает X/Y; выход за экран отключает пулю.
; Render использует handle 0 chain atlas, тот же, что ball-now/next-ball/chain.
;
; Текущая логика: полёт, проверка попадания по обеим цепям, hemisphere-target
; и вставка через VDC_InsertAt. Пули в tunnel-track не попадают, но учитываются
; для gap-bonus-трекинга.
; ============================================================================

; 1024×768 порт: пуля летит в 1024-пространстве (трек/шары ×1.6). Скорость,
; размер спрайта и пороги коллизии масштабируются ×1.6 (= ×8/5).
BULLET_SPEED        EQU 19                            ; 12×1.6 — тот же экранный путь/время на бо́льшем экране
BULLET_SPRITE_HALF  EQU 26                            ; round(51/2) — центр draw-rect'а (ball 51px)
BULLET_DRAW         EQU 51                            ; экранный размер = round(32×8/5)
BULLET_DRAW_SCALE   EQU #00019800                     ; 51/32 в f16.16 (cmd_scale: 32px atlas → 51px screen)
BULLET_HIT_THR      EQU 35                            ; 22×1.6 bbox prefilter: |dx|<THR && |dy|<THR.
BULLET_HIT_MANHATTAN_THR EQU 54                       ; 34×1.6 отсекает дальние углы bbox.
                                                      ; Порог 30/46 был слишком магнитным на кривой цепи:
                                                      ; иногда выбирался шар за несколько слотов до прицела.
                                                      ; 22/34 оставляет небольшой запас без раннего захвата.
BULLET_TRACKF_TUNNEL EQU #01                          ; bit0 track flags: hidden/tunnel, недоступен для выстрела.


; ----------------------------------------------------------------------------
; Bullet_Init — обнулить state.
; ----------------------------------------------------------------------------
Bullet_Init:        XOR  A
                    LD   (Bullet_Active), A
                    LD   (Bullet_TunnelSeen), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Spawn — вызывается из Frog start-fire (LMB или SPACE).
; Берёт цвет из Frog_BallColor, angle из Frog_Angle и стартовую позицию
; Frog_PosStartX/Y (центр лягушки).
; Velocity = BULLET_SPEED * (cos(angle), sin(angle)) / 128.
; ----------------------------------------------------------------------------
Bullet_Spawn:       LD   A, (VDC_DialogState)
                    OR   A
                    JR   NZ, .bs_block
                    ; Разрешено стрелять только в PLAY (=0): не во время INTRO/PREVIEW/CLOSING,
                    ; ABSORB (шары улетают в killzone — стрельба бессмысленна), GAMEOVER.
                    LD   A, (VDC_GameState)
                    OR   A
                    JR   NZ, .bs_block
                    LD   A, (Bullet_Active)
                    OR   A
                    JR   Z, .bs_free
.bs_block:          SCF
                    RET
.bs_free:
                    RET  NZ                           ; уже в полёте — разрешена только одна пуля
                    LD   A, 1
                    LD   (Bullet_Active), A
                    XOR  A
                    LD   (Bullet_TunnelSeen), A
                    LD   A, (Frog_BallColor)
                    LD   (Bullet_Color), A

                    LD   HL, (Frog_PosStartX)
                    LD   (Bullet_X), HL
                    LD   HL, (Frog_PosStartY)
                    LD   (Bullet_Y), HL

                    if RUNTIME_DIAGNOSTICS_ENABLED
                    CALL LogShotFired
                    endif
                    LD   A, SND_FIREBALL1
                    CALL GS_PlaySfx

                    CALL VDC_ResetBulletGapTracking   ; min-dist=255 на новый полёт

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
; Bullet_Update — X += VX, Y += VY каждый кадр. Деактивация при выходе за экран.
; ----------------------------------------------------------------------------
Bullet_Update:      LD   A, (VDC_DialogState)
                    CP   3
                    RET  Z
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    LD   A, (Bullet_VX)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_X)
                    ADD  HL, DE
                    LD   (Bullet_X), HL
                    ; signed-проверка выхода X за экран
                    BIT  7, H
                    JR   NZ, .deactivate              ; X < 0
                    LD   DE, 1024
                    AND  A
                    SBC  HL, DE
                    JR   NC, .deactivate              ; X ≥ 1024

                    LD   A, (Bullet_VY)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_Y)
                    ADD  HL, DE
                    LD   (Bullet_Y), HL
                    BIT  7, H
                    JR   NZ, .deactivate
                    LD   DE, 768
                    AND  A
                    SBC  HL, DE
                    RET  C                            ; Y < 768 → ОК
.deactivate:        XOR  A
                    LD   (Bullet_Active), A
                    CALL VDC_BreakShotStats           ; промах/вылет: нет destroy и gap bonus
                    XOR  A
                    LD   (Bullet_TunnelSeen), A
                    RET


; ----------------------------------------------------------------------------
; Bullet_CheckCollision — итерация по chain slots. Находит ближайший шар
; (min Manhattan distance) среди тех, что попали в bbox BULLET_HIT_THR.
; Если найден → VDC_InsertAt(target_idx, color), Active=0.
; ----------------------------------------------------------------------------
Bullet_CheckCollisionAllChains:
                    CALL Bullet_CheckCollision
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z
                    LD   A, (VDC_HasSecondChain)
                    OR   A
                    RET  Z
                    CALL VDC_SwapChains
                    CALL SetSecondTrackPage
                    CALL Bullet_CheckCollision
                    CALL VDC_SwapChains
                    JP   SetCurrentTrackPage

Bullet_CheckCollision:
                    LD   A, (Bullet_Active)
                    OR   A
                    RET  Z
                    LD   A, (VDC_SlotsLen)
                    OR   A
                    RET  Z
                    LD   B, A                          ; B = SlotsLen; нельзя брать B после загрузки 255,
                                                       ; иначе loop уйдёт в stale slots за концом цепи.

                    ; Инициализация scratch для ближайшего попадания.
                    LD   A, 255
                    LD   (Bullet_TmpHit), A
                    LD   (Bullet_TmpDistP), A

                    LD   C, 0                          ; C = i
.bcc_loop:          PUSH BC
                    LD   A, C
                    LD   H, 0 : LD L, A
                    LD   DE, (VDC_pExplodeFrame)
                    ADD  HL, DE
                    LD   A, (HL)
                    OR   A
                    JR   NZ, .bcc_skip
                    LD   A, C
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=skip
                    JR   C, .bcc_skip
                    LD   A, (VDC_LastTrackFlags)
                    AND  BULLET_TRACKF_TUNNEL
                    LD   (Bullet_TmpTunnel), A

                    ; bbox-проверка: |Bullet_X - X| < THR
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   NZ, .bcc_skip                 ; |dx| > 255 → слишком далеко
                    LD   A, L
                    CP   BULLET_HIT_THR
                    JR   NC, .bcc_skip                 ; |dx| ≥ thr → слишком далеко

                    ; bbox-проверка: |Bullet_Y - Y| < THR
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

                    LD   A, (Bullet_TmpTunnel)
                    OR   A
                    JR   Z, .bcc_not_tunnel
                    LD   A, 1
                    LD   (Bullet_TunnelSeen), A
                    JR   .bcc_skip                     ; шар внутри tunnel нельзя сбить
.bcc_not_tunnel:
                    ; BBOX HIT: считаем Manhattan distance и обновляем лучший hit.
                    PUSH BC                            ; [1] сохранить X
                    PUSH DE                            ; [2] сохранить Y
                    CALL Bullet_ManhattanToBC_DE       ; A = distance
                    POP  DE                            ; [2] восстановить Y
                    POP  BC                            ; [1] восстановить X
                    CP   BULLET_HIT_MANHATTAN_THR
                    JR   NC, .bcc_skip                 ; диагональный угол bbox визуально слишком далёк
                    
                    LD   HL, Bullet_TmpDistP
                    CP   (HL)
                    JR   NC, .bcc_skip                 ; dist >= best_dist → пропустить
                    
                    ; Новый лучший кандидат.
                    LD   (HL), A                       ; обновить best_dist
                    ; Текущий i (C) берётся со стека: он был PUSHed в .bcc_loop.
                    LD   HL, 0
                    ADD  HL, SP
                    LD   A, (HL)                       ; A = C (low byte of outer PUSH BC)
                    LD   (Bullet_TmpHit), A            ; обновить best_idx

.bcc_skip:          POP  BC
                    INC  C
                    DEC  B
                    JP   NZ, .bcc_loop

                    ; Финализация: Bullet_TmpHit != 255 → выполнить insert.
                    LD   A, (Bullet_TmpHit)
                    CP   255
                    JP   Z, VDC_UpdateBulletGapTracking  ; нет hit → проверить близость gap

                    if RUNTIME_DIAGNOSTICS_ENABLED
                    CALL LogBboxHit                    ; in: A=best_hit_idx (preserved)
                    endif
                    LD   A, SND_BALLCLICK2
                    CALL GS_PlaySfx
                    LD   A, (Bullet_TmpHit)

                    LD   (Bullet_TmpHit), A            ; сохранить hit для hemisphere-target
                    CALL Bullet_HemisphereTarget       ; A = target_idx
                    if RUNTIME_DIAGNOSTICS_ENABLED
                    CALL LogHemi                       ; in: A=target_idx (preserved)
                    endif

                    LD   C, A                          ; сохранить target
                    LD   A, (Bullet_Color)
                    LD   B, A
                    LD   A, C
                    CALL VDC_InsertAt                 ; A=1, если выстрел сразу уничтожил шары
                    OR   A
                    CALL NZ, VDC_AwardGapBonus        ; gap bonus только за through-gap destroy
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
                    ; target по умолчанию = hit
                    ; Поиск предыдущего non-gap (k < hit).
                    LD   A, 255
                    LD   (Bullet_TmpDistP), A
                    LD   (Bullet_TmpDistN), A          ; next_dist по умолчанию = 255

                    LD   A, (Bullet_TmpHit)
                    OR   A
                    JR   Z, .ht_skip_prev              ; hit=0 → нет prev
                    DEC  A
.ht_prev_loop:      LD   (Bullet_TmpScan), A
                    LD   H, 0 : LD L, A
                    LD   DE, (VDC_pExplodeFrame)
                    ADD  HL, DE
                    LD   A, (HL)
                    OR   A
                    JR   NZ, .ht_prev_continue
                    LD   A, (Bullet_TmpScan)
                    LD   H, 0 : LD L, A
                    LD   DE, (VDC_pSlots)
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_prev_found
.ht_prev_continue:
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
                    ; Поиск следующего non-gap (k > hit).
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
                    LD   DE, (VDC_pExplodeFrame)
                    ADD  HL, DE
                    LD   A, (HL)
                    OR   A
                    JR   NZ, .ht_next_continue
                    LD   A, (Bullet_TmpScan)
                    LD   H, 0 : LD L, A
                    LD   DE, (VDC_pSlots)
                    ADD  HL, DE
                    LD   A, (HL)
                    CP   VDC_NUM_COLORS
                    JR   C, .ht_next_found
.ht_next_continue:
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
                    ; нет next (hit=len-1) → считаем dist(bullet, hit) как next_dist
                    LD   A, (Bullet_TmpHit)
                    CALL VDC_SlotPos
                    CALL Bullet_ManhattanToBC_DE
                    LD   (Bullet_TmpDistN), A

.ht_final_compare:
                    ; если dist_next < dist_prev → target = hit + 1, иначе hit
                    LD   A, (Bullet_TmpDistN)
                    LD   B, A
                    LD   A, (Bullet_TmpDistP)
                    CP   B
                    LD   A, (Bullet_TmpHit)
                    RET  C                             ; prev < next → target=hit
                    INC  A                             ; next ≤ prev → target=hit+1
                    RET


; ----------------------------------------------------------------------------
; Bullet_ManhattanToBC_DE — A = |Bullet_X - BC| + |Bullet_Y - DE|, clamped 255.
; ----------------------------------------------------------------------------
Bullet_ManhattanToBC_DE:
                    PUSH DE                            ; сохранить Y
                    LD   HL, (Bullet_X)
                    AND  A
                    SBC  HL, BC
                    CALL Bullet_AbsHL
                    LD   A, H
                    OR   A
                    JR   Z, .mh_dx_ok
                    LD   L, 255
.mh_dx_ok:          LD   B, L                          ; B = |dx| clamped
                    POP  DE                            ; восстановить Y
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
; Bullet_Draw — вывод sprite пули в DL. Current level selects ARGB4 or L19 PALETTED atlas.
; PALETTED L19 atlas uses local cell = color*12 (neutral phase).
; Matrix должна быть identity/scale-only.
; ----------------------------------------------------------------------------
Bullet_Draw:        LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    ; Гарантируем identity matrix
                    ; перед draw — иначе если matrix унаследована от tongue/body
                    ; rotation, bullet sprite рисуется в неправильном месте экрана.
                    ; 1024×768: normal atlas needs 32px→51px scale; L19 native 51px uses identity.
                    CALL ZL_EmitBallStaticMatrixCurrent

                    LD   A, (Bullet_Color)
                    CALL ZL_BallHandleFromColor
.bullet_h:          CALL ZL_EmitBallHandle
                    CALL ZL_EmitBallLayoutCurrent
                    FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, BULLET_DRAW, BULLET_DRAW
                    LD   A, (Bullet_Color)                ; перечитать: макросы портят B/C/D/E
                    CALL ZL_BallNeutralCellFromColor
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
                    ; Сброс matrix → identity после scale-матрицы.
                    CALL ZL_EmitLoadId
                    JP   ZL_EmitSetMatrix


; ----------------------------------------------------------------------------
Bullet_Active:      DEFB 0
Bullet_X:           DEFW 0
Bullet_Y:           DEFW 0
Bullet_VX:          DEFB 0
Bullet_VY:          DEFB 0
Bullet_Color:       DEFB 0
Bullet_TunnelSeen:  DEFB 0                            ; bullet прошёл рядом с tunnel-шаром за текущий полёт
Bullet_TmpTunnel:   DEFB 0                            ; текущий scanned slot имеет TRACKF_TUNNEL
Bullet_TmpHit:      DEFB 0                            ; scratch для hemisphere-target
Bullet_TmpScan:     DEFB 0
Bullet_TmpDistP:    DEFB 0
Bullet_TmpDistN:    DEFB 0
