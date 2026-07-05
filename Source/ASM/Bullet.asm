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
                    ; MainLoop вызывает Frog_Update до VDC_UpdateAllChains.
                    ; Если череп почти открыт, этот же кадр может войти в
                    ; ABSORB после проверки spawn. Новый выстрел тут запрещён.
                    LD   A, (VDC_KzFrame)
                    CP   9
                    JR   NC, .bs_block
                    LD   A, (VDC2_KzFrame)
                    CP   9
                    JR   NC, .bs_block
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
                    CALL Bullet_TrajInitForAngle
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

                    LD   A, (BulletTrajValid)
                    OR   A
                    JR   Z, .legacy_bounds

                    LD   A, (Bullet_Frame)
                    LD   (Bullet_PrevFrame), A
                    INC  A
                    LD   (Bullet_Frame), A

                    LD   A, (Bullet_VX)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_X)
                    ADD  HL, DE
                    LD   (Bullet_X), HL

                    LD   A, (Bullet_VY)
                    CALL Bullet_SignExtendA_HL
                    LD   DE, (Bullet_Y)
                    ADD  HL, DE
                    LD   (Bullet_Y), HL

                    LD   A, (Bullet_Frame)
                    LD   B, A
                    LD   A, (Bullet_ExitFrame)
                    CP   B
                    JR   C, .deactivate
                    JR   Z, .deactivate
                    RET

.legacy_bounds:
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
; Bullet_CheckCollision — чтение потока событий ZBT1 в resident Main0.
; Старый full scan Slots[] убран из hot path: таблица даёт VDC-cell кандидаты,
; а BulletTraj.asm валидирует их тем же bbox/manhattan тестом.
; ----------------------------------------------------------------------------
Bullet_CheckCollisionAllChains:
                    JP   Bullet_CheckCollisionEvents

Bullet_CheckCollision:
                    JP   Bullet_CheckCollisionEvents


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
                    CALL VDC_SlotPos                   ; BC=X, DE=Y, CF=пропуск
                    JR   C, .ht_skip_prev
                    CALL Bullet_ManhattanToBC_DE       ; A = |bx-X|+|by-Y| (ограничено 255)
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
; Bullet_ManhattanToBC_DE — A = |Bullet_X - BC| + |Bullet_Y - DE|, ограничение 255.
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
.mh_dx_ok:          LD   B, L                          ; B = |dx| с ограничением
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
; Bullet_AbsHL — HL = |HL| (signed → unsigned magnitude; модуль).
; ----------------------------------------------------------------------------
Bullet_AbsHL:       BIT  7, H
                    RET  Z
                    LD   A, H : CPL : LD H, A
                    LD   A, L : CPL : LD L, A
                    INC  HL
                    RET


; ----------------------------------------------------------------------------
; Bullet_SignExtendA_HL — HL = A с расширенным знаком.
; ----------------------------------------------------------------------------
Bullet_SignExtendA_HL:
                    LD   H, 0
                    BIT  7, A
                    JR   Z, .pp
                    DEC  H
.pp:                LD   L, A
                    RET


; ----------------------------------------------------------------------------
; Bullet_Draw — вывод sprite пули в DL. Current level выбирает ARGB4 или L19 PALETTED atlas.
; PALETTED L19 atlas использует local cell = color*12 (neutral phase).
; Matrix должна быть identity/scale-only.
; ----------------------------------------------------------------------------
Bullet_Draw:        LD   A, (Bullet_Active)
                    OR   A
                    RET  Z

                    ; Гарантируем identity matrix
                    ; перед draw — иначе если matrix унаследована от tongue/body
                    ; rotation, bullet sprite рисуется в неправильном месте экрана.
                    ; 1024×768: обычному атласу нужен scale 32px→51px; L19 native 51px использует identity.
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
Bullet_Frame:       DEFB 0                            ; fixed-speed bullet frame since spawn
Bullet_PrevFrame:   DEFB 0
Bullet_ExitFrame:   DEFB 0                            ; выход полного sprite за экран из ZBT1 stream
Bullet_EventPtr:    DEFW 0                            ; #8000-based pointer inside BULLET_TRAJ_PAGE
Bullet_EventCount:  DEFB 0
Bullet_NoHitMask:   DEFB 0                            ; bit0=track1 tunnel/no-hit, bit1=track2
Bullet_EventTrackState: DEFB 0                         ; 0=chain1 active, 1=chain2 active inside event reader
Bullet_TmpEventFrame: DEFB 0
Bullet_TmpEventFlags: DEFB 0
Bullet_TmpEventCell: DEFB 0
Bullet_TmpEventSub: DEFB 0
Bullet_TmpEventTrack: DEFB 0
Bullet_TmpHitTrack: DEFB 0
Bullet_TmpCandidateBase: DEFB 0
