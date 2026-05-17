; ============================================================================
; Frog.asm — рендер лягушки 1:1 с Zuma-Deluxe-HD/src/zuma/Frog.c.
;
; Композиция (Frog_Draw):
;   • plate (no rotation) под body
;   • body с rotation matrix вокруг центра, angle = atan2(mouse - frog).
;     Native sprite face = south (BRAD 64), поэтому ZL_EmitRotate уже делает
;     ADD A,192 (= -64) — передаём raw FrogAngle.
;   • tongue с offset (tongueExpand · dir) и той же rotation matrix вокруг
;     центра sprite. dir = (cos(angle), sin(angle)) (см. SinTable ниже).
;
; Recoil/fire (Frog_Update):
;   ЛКМ rise edge → fireRecoilTick=0, isFire=1, ballExpand=0.
;   Каждый кадр: tick += 10 BRAD (≈0.245 rad ≈ HD 0.25 rad/frame).
;   recoil = sin(tick); пока recoil ≥ 0:
;     tongueExpand = 24 - (recoil * 24) >> 7         ; язык втянут в рот
;     ballExpand   = min(32, ballExpand + 2)         ; вылет шара
;     pos.x = posStart.x - (cos(angle) * recoil) / 2048    ; ≈ -dir*recoil*8/128
;     pos.y = posStart.y - (sin(angle) * recoil) / 2048
;   recoil < 0 → end: tongueExpand=24, ballExpand=32, pos=posStart, isFire=0.
;
; FT812 BITMAP_HANDLE: 2=body, 4=plate, 5=tongue.
; ============================================================================

FROG_SPR_W        EQU 122
FROG_SPR_HALF     EQU 61
FROG_SPR_HALF_NEG EQU -FROG_SPR_HALF & 0xFFFF          ; -61 в 16-bit two's-comp

; Tongue full 122×122 ARGB4 — точный 1:1 перенос из Python visual_emulator.py.
; Pivot UV (61, 61) = sprite centre = HD anchor (native sprite centre 81, 81 в
; 162×162, после resize 162→122).  Screen rect совпадает со sprite size, sprite
; circular fits в square rect при любом угле rotation, без clipping.
FROG_TONGUE_W     EQU 122                               ; sprite W в RAM_G
FROG_TONGUE_H     EQU 122                               ; sprite H в RAM_G
FROG_TONGUE_UV_HW EQU 61                                ; UV pivot = sprite centre
FROG_TONGUE_UV_HH EQU 61
FROG_TONGUE_SCR_W EQU 122
FROG_TONGUE_SCR_H EQU 122
FROG_TONGUE_SCR_HALF EQU 61
FROG_TONGUE_SCR_HALF_NEG EQU -FROG_TONGUE_SCR_HALF & 0xFFFF

; Overlay 122×122 (= same size как body — features alignment ✓).

FROG_RECOIL_STEP  EQU 10                                ; BRAD/frame; π/0.25 ≈ 12.6 кадров полу-периода
FROG_DEFAULT_X    EQU 327
FROG_DEFAULT_Y    EQU 231

FROG_BALL_IDLE    EQU 24                                ; HD: ballExpand idle 24 (= точное Python значение)
FROG_NEXT_OFFSET  EQU 28                                ; HD next-ball orbit (= точное Python значение)
FROG_BALL_W       EQU 32                                ; ball atlas cell native classic 32×32
FROG_BALL_DST_W   EQU 32                                ; screen size = native
FROG_BALL_DST_HALF EQU 16


; ----------------------------------------------------------------------------
; Frog_Init — обнулить state.  F12-reset не reload'ит RAM, поэтому всё
; инициализируется явно.
; ----------------------------------------------------------------------------
Frog_Init:        XOR  A
                  LD   (Frog_Angle), A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_IsFire), A
                  LD   (FROG_RTC_MIX_CNT_ADDR), A      ; slot 1 free RAM counter — F12 reset не чистит её сам
                  LD   (FROG_RTC_MIX_FLAG_ADDR), A     ; pending RTC mix flag
                  DEC  A                                ; A = #FF (was 0)
                  LD   (FROG_EXCLUDE_COLOR_ADDR), A    ; exclude-color = 0xFF (none)
                  XOR  A                                ; restore A=0 для последующих stores
                  LD   A, 1                            ; pre-init = pressed → no spurious
                  LD   (Frog_PrevMouseLeft), A         ; edge-rise на первом кадре
                  LD   (Frog_KeySpacePrev), A
                  XOR  A
                  LD   A, 24
                  LD   (Frog_TongueExpand), A
                  LD   A, FROG_BALL_IDLE
                  LD   (Frog_BallExpand), A
                  LD   HL, FROG_DEFAULT_X
                  LD   (Frog_PosX), HL
                  LD   (Frog_PosStartX), HL
                  LD   HL, FROG_DEFAULT_Y
                  LD   (Frog_PosY), HL
                  LD   (Frog_PosStartY), HL
                  ; Initial ball colors via VDC RNG (already seeded by VDC_Init).
                  CALL VDC_RandomColor
                  LD   (Frog_BallColor), A
                  CALL VDC_RandomColor
                  AND  3                                ; 0..3 (HD: nextBallColor 4 colors)
                  LD   (Frog_NextBallColor), A
                  RET


; ----------------------------------------------------------------------------
; Frog_Update — Smart-conditional (Gemini-fix 2026-05-16): звать ComputeAngle
; пока mouse активна ИЛИ grace > 0 (после motion stop Smooth догоняет raw N кадров).
; Без grace — angle фризится на lagged значении (mouse wrong-target).
; После grace expired — keyboard ←/→ управляет Frog_Angle через ZL_AimUpdate
; без overwrite от atan2.
; ----------------------------------------------------------------------------
Frog_Update:      LD   A, (ZL_MouseMoved)
                  OR   A
                  JR   NZ, .fu_compute                 ; motion → update
                  LD   A, (ZL_MotionGrace)
                  OR   A
                  JR   Z, .fu_skip                     ; grace=0 → keyboard mode, skip
                  DEC  A
                  LD   (ZL_MotionGrace), A             ; tick down
.fu_compute:      CALL Frog_ComputeAngle
.fu_skip:         CALL Frog_RefilterCurrent            ; check & replace BallColor/NextBallColor если не в mask
                  CALL Frog_HandleMouse
                  JP   Frog_TickRecoil


; ----------------------------------------------------------------------------
; Frog_ComputeAngle — Frog_Angle = atan2(SmoothY-PosStartY, SmoothX-PosStartX).
; 8-октантная схема + AtanTable[129] + hybrid slow/fast follow.
; ----------------------------------------------------------------------------
Frog_ComputeAngle:
                  ; dx = SmoothX - PosStartX
                  LD   HL, (ZL_SmoothX)
                  LD   DE, (Frog_PosStartX)
                  AND  A
                  SBC  HL, DE
                  LD   B, 0                            ; flags: b0=dx<0, b1=dy<0, b2=swap
                  BIT  7, H
                  JR   Z, .dx_pos
                  SET  0, B
                  LD   A, H : CPL : LD H, A
                  LD   A, L : CPL : LD L, A
                  INC  HL
.dx_pos:          ; Clamp |dx| до 255 (если H≠0 значит |dx|>255 → насыщать).  Без clamp
                  ; truncate (LD C, L) даёт 0x39=57 для dx=313=0x139, swap-логика
                  ; сходит с ума → frog дёргается у краёв экрана.  (Кредит: Gemini.)
                  LD   A, H
                  OR   A
                  JR   Z, .dx_clamped
                  LD   L, 255
.dx_clamped:      LD   C, L                            ; C = |dx| (true 8-bit clamp)
                  ; dy = SmoothY - PosStartY
                  LD   HL, (ZL_SmoothY)
                  LD   DE, (Frog_PosStartY)
                  AND  A
                  SBC  HL, DE
                  BIT  7, H
                  JR   Z, .dy_pos
                  SET  1, B
                  LD   A, H : CPL : LD H, A
                  LD   A, L : CPL : LD L, A
                  INC  HL
.dy_pos:          LD   A, H
                  OR   A
                  JR   Z, .dy_clamped
                  LD   L, 255
.dy_clamped:      LD   E, L                            ; E = |dy| (true 8-bit clamp)
                  ; swap = (|dy| > |dx|)
                  LD   A, E
                  CP   C
                  JR   C, .no_swap
                  SET  2, B
                  LD   A, C : LD C, E : LD E, A
.no_swap:         ; C = max, E = min
                  LD   A, C
                  OR   A
                  JR   Z, .cfa_done                    ; курсор в frog center → не менять угол
                  ; t = E*128 / C
                  LD   H, 0
                  LD   L, E
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL
                  CALL Frog_Div16by8                   ; A = HL / C
                  CP   129
                  JR   C, .lookup
                  LD   A, 128
.lookup:          LD   HL, Frog_AtanTable
                  LD   D, 0 : LD E, A
                  ADD  HL, DE
                  LD   A, (HL)                         ; A = угол 0..32 (1-й октант)
                  ; mirror at 90° если был swap
                  BIT  2, B
                  JR   Z, .no_mirror
                  LD   E, A : LD A, 64 : SUB E
.no_mirror:       ; A в 0..64. Применяем знаки dx/dy.
                  BIT  0, B
                  JR   Z, .dx_pos2
                  BIT  1, B
                  JR   Z, .q2
                  ; Q3: dx<0, dy<0 → 128 + A
                  LD   E, A : LD A, 128 : ADD A, E
                  JR   .store
.q2:              ; Q2: dx<0, dy≥0 → 128 - A
                  LD   E, A : LD A, 128 : SUB E
                  JR   .store
.dx_pos2:         BIT  1, B
                  JR   Z, .store                       ; Q1: A
                  NEG                                  ; Q4: 256 - A
.store:           ; A = new angle. Hybrid follow: |diff|≥4 → snap, иначе ±1.
                  LD   B, A                            ; B = new
                  LD   A, C
                  CP   5
                  JR   C, .cfa_done                    ; deadzone
                  LD   A, B
                  LD   HL, Frog_Angle
                  SUB  (HL)                            ; A = signed diff (8-bit wrap)
                  JR   Z, .cfa_done
                  LD   D, A
                  BIT  7, A
                  JR   Z, .gp_pos
                  NEG
.gp_pos:          CP   4
                  JR   NC, .gp_full
                  LD   A, (HL)
                  BIT  7, D
                  JR   NZ, .gp_dec
                  INC  A
                  JR   .gp_save
.gp_dec:          DEC  A
.gp_save:         LD   (HL), A
                  RET
.gp_full:         LD   (HL), B
.cfa_done:        RET


; ----------------------------------------------------------------------------
; Frog_Div16by8 — HL / C → A (assumed quotient ≤ 129).
; ----------------------------------------------------------------------------
Frog_Div16by8:    XOR  A
                  LD   D, 0
.d8_loop:         LD   E, C
                  AND  A
                  SBC  HL, DE
                  JR   C, .d8_restore
                  INC  A
                  CP   130
                  JR   C, .d8_loop
                  RET
.d8_restore:      ADD  HL, DE
                  RET


; ----------------------------------------------------------------------------
; Frog_FireKeyboard — start fire от SPACE (вызывается ZL_AimUpdate при port
; #7FFE bit 0 pressed). Свой debounce через Frog_KeySpacePrev — независимо от
; LMB edge-rise в Frog_HandleMouse, чтобы зажатый SPACE не повторял огонь.
; ----------------------------------------------------------------------------
Frog_FireKeyboard:
                  LD   A, (Frog_KeySpacePrev)
                  OR   A
                  RET  NZ                              ; уже fired в прошлом кадре
                  LD   A, 1
                  LD   (Frog_KeySpacePrev), A
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                              ; уже стреляем (recoil идёт)
                  ; Start fire (= копия Frog_HandleMouse start-fire блока):
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= что вылетает изо рта)
                  RET  C
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now (новый шар во рту)
                  CALL Frog_NewNextColor               ; force fresh filtered new NextBallColor
                  LD   A, 1
                  LD   (Frog_IsFire), A
                  XOR  A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_BallExpand), A
                  RET


; ----------------------------------------------------------------------------
; Frog_HandleMouse — edge-rise по SVK_LBUTTON, при необходимости стартует fire.
; HD: при первом нажатии (was=0, now=1) и !isFire — start fire.
; ----------------------------------------------------------------------------
Frog_HandleMouse:
                  ; Fire = только LMB (стабильно работает). RMB/SPACE/Kempston —
                  ; видимо в этом Unreal phantom-pressed (port reads bit clear
                  ; постоянно) → блокировали edge-rise.
                  LD   A, Input.Mouse.SVK_LBUTTON
                  CALL Input.Mouse.KeyState            ; Z=released, NZ=pressed
                  LD   A, 0
                  JR   Z, .save
                  LD   A, 1
.save:            LD   HL, Frog_PrevMouseLeft
                  LD   B, (HL)                         ; B = prev
                  LD   (HL), A                         ; save curr
                  OR   A
                  RET  Z                                ; curr=0 → не rise
                  LD   A, B
                  OR   A
                  RET  NZ                               ; prev=1 → не rise
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                               ; уже стреляем
                  ; --- Start fire (HD): promote nextBall → ballColor, new next 0..3,
                  ; ballExpand=0, recoilTick=0, isFire=1.
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= что вылетает изо рта)
                  RET  C
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now (новый шар во рту)
                  CALL Frog_NewNextColor               ; force fresh filtered new NextBallColor
                  LD   A, 1
                  LD   (Frog_IsFire), A
                  XOR  A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_BallExpand), A
                  RET


; ----------------------------------------------------------------------------
; Frog_TickRecoil — если isFire: tick++, обновить tongueExpand, ballExpand, pos.
; recoil < 0 → выйти из fire-state, восстановить idle-значения.
; ----------------------------------------------------------------------------
Frog_TickRecoil:
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  Z

                  ; tick += FROG_RECOIL_STEP
                  LD   HL, Frog_RecoilTick
                  LD   A, (HL)
                  ADD  A, FROG_RECOIL_STEP
                  LD   (HL), A

                  ; recoil = SinTable[tick]
                  CALL Frog_LookupSin                   ; A = signed sin (-127..127)
                  BIT  7, A
                  JP   NZ, .end_fire                    ; sin < 0 → recoil закончился

                  LD   (Frog_TmpRecoil), A              ; recoil unsigned 0..127

                  ; tongueExpand = 24 - (recoil * 24) >> 7
                  LD   D, A
                  LD   E, 24
                  CALL Frog_Mul8x8u                     ; HL = recoil*24, ≤ 3048
                  SLA  L : RL  H                        ; HL <<= 1; H = HL>>7 (= 0..23)
                  LD   A, 24
                  SUB  H
                  LD   (Frog_TongueExpand), A

                  ; ballExpand: if < FROG_BALL_IDLE → += 2 (HD = 2.5/frame, floor to 2).
                  LD   A, (Frog_BallExpand)
                  CP   FROG_BALL_IDLE
                  JR   NC, .be_done
                  ADD  A, 2
                  CP   FROG_BALL_IDLE + 1
                  JR   C, .be_save
                  LD   A, FROG_BALL_IDLE
.be_save:         LD   (Frog_BallExpand), A
.be_done:

                  ; pos.x = posStart.x - (cos(angle) * recoil) / 2048
                  LD   A, (Frog_Angle)
                  ADD  A, 64                            ; cos = sin(angle + 64)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TmpRecoil)
                  LD   C, A
                  CALL Frog_SignedScale_div2048         ; A = signed (cos*recoil)/2048
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosStartX)
                  ADD  HL, DE
                  LD   (Frog_PosX), HL

                  ; pos.y = posStart.y - (sin(angle) * recoil) / 2048
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TmpRecoil)
                  LD   C, A
                  CALL Frog_SignedScale_div2048
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosStartY)
                  ADD  HL, DE
                  LD   (Frog_PosY), HL
                  RET

.end_fire:        XOR  A
                  LD   (Frog_IsFire), A
                  LD   (Frog_RecoilTick), A
                  LD   A, 24
                  LD   (Frog_TongueExpand), A
                  LD   A, FROG_BALL_IDLE
                  LD   (Frog_BallExpand), A
                  LD   HL, (Frog_PosStartX)
                  LD   (Frog_PosX), HL
                  LD   HL, (Frog_PosStartY)
                  LD   (Frog_PosY), HL
                  RET


; ----------------------------------------------------------------------------
; Frog_LookupSin — A = SinTable[A].  Corrupts D, E, HL.
; ----------------------------------------------------------------------------
Frog_LookupSin:   LD   HL, Frog_SinTable
                  LD   D, 0 : LD E, A
                  ADD  HL, DE
                  LD   A, (HL)
                  RET


; ----------------------------------------------------------------------------
; Frog_SignExtendA_HL — HL = sign-extended A.
; ----------------------------------------------------------------------------
Frog_SignExtendA_HL:
                  LD   H, 0
                  BIT  7, A
                  JR   Z, .pp
                  DEC  H                                ; H=0xFF (negative)
.pp:              LD   L, A
                  RET


; ----------------------------------------------------------------------------
; Frog_SignedScale_div128 — signed (B*C) / 128, range ±127.
;   In:  B = signed multiplier, C = unsigned (0..127, обычно 0..24)
;   Out: A = signed result
; ----------------------------------------------------------------------------
Frog_SignedScale_div128:
                  LD   A, B
                  LD   E, 0                             ; sign flag
                  BIT  7, A
                  JR   Z, .pos
                  INC  E
                  NEG
.pos:             LD   D, A                             ; D = |B|
                  PUSH DE
                  LD   E, C
                  CALL Frog_Mul8x8u                     ; HL = |B|*C
                  POP  DE
                  SLA  L : RL  H                        ; HL <<= 1; H = HL/128
                  LD   A, H
                  BIT  0, E
                  RET  Z
                  NEG
                  RET


; ----------------------------------------------------------------------------
; Frog_SignedScale_div2048 — signed (B*C) / 2048, range ±8.
;   In:  B = signed multiplier (cos/sin), C = unsigned (0..127, recoil)
;   Out: A = signed result (-8..+8 px)
; ----------------------------------------------------------------------------
Frog_SignedScale_div2048:
                  LD   A, B
                  LD   E, 0
                  BIT  7, A
                  JR   Z, .pos
                  INC  E
                  NEG
.pos:             LD   D, A
                  PUSH DE
                  LD   E, C
                  CALL Frog_Mul8x8u
                  POP  DE
                  LD   A, H                             ; A = HL/256, range 0..63
                  SRL  A : SRL A : SRL A                ; A /= 8 → /2048 total
                  BIT  0, E
                  RET  Z
                  NEG
                  RET


; ----------------------------------------------------------------------------
; Frog_Mul8x8u — D × E → HL (unsigned 16-bit).  Corrupts A, B, DE.
; ----------------------------------------------------------------------------
Frog_Mul8x8u:     LD   A, D
                  LD   HL, 0
                  LD   D, 0                             ; DE = E (extended unsigned)
                  LD   B, 8
.loop:            SRL  A
                  JR   NC, .skip
                  ADD  HL, DE
.skip:            SLA  E : RL D
                  DJNZ .loop
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawPlate — handle 4, no rotation, на текущем pos (с recoil offset).
; Перед вызовом ожидается matrix = identity.  Plate matrix не трогает.
; ----------------------------------------------------------------------------
Frog_DrawPlate:   FT_BitmapHandle 4
                  FT_BitmapSource PLATE_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawBody — handle 2, rotation matrix вокруг центра sprite.
;   matrix = T(61,61) · R(angle - 64) · T(-61,-61)
; Body native face = SOUTH (BRAD 64) → нужен offset -64 (= +192 mod 256).
; ----------------------------------------------------------------------------
Frog_DrawBody:    LD   A, (Frog_Angle)
                  ADD  A, 192                          ; body: -64 BRAD (south native)
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 2
                  FT_BitmapSource FROG_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawTongue — handle 5, tight-crop sprite 32×80, на pos + tongueExpand·dir,
; rotation вокруг tongue centre.
;   tongueX = pos.x + (cos(angle) * tongueExpand) / 128
;   tongueY = pos.y + (sin(angle) * tongueExpand) / 128
;   matrix  = T(16, 40) · R(angle + 192) · T(-16, -40)
; Tongue native = south (tip внизу 32×80 кадра); rotation как у body.
; ----------------------------------------------------------------------------
Frog_DrawTongue:
                  ; HD-style: tongue centre = pos + tongueExpand·dir (orbit).
                  ; tongueExpand=24 idle, втягивается до 0 при выстреле.
                  ;   offsetX = (cos(angle) · tongueExpand) / 128
                  ;   offsetY = (sin(angle) · tongueExpand) / 128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TongueExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL

                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_TongueExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Matrix: T(uv_pivot) · R(angle + 192) · T(-screen_pivot)
                  ; UV centra sprite (16, 40) фиксируется в screen centra (48, 48)
                  ; rect'a 96×96 — sprite 32×80 рисуется внутри расширенного
                  ; screen rect'а и не клипается при любом угле rotation.
                  CALL ZL_EmitLoadId
                  LD   HL, FROG_TONGUE_UV_HW
                  LD   DE, FROG_TONGUE_UV_HH
                  CALL ZL_EmitTranslate
                  LD   A, (Frog_Angle)
                  ADD  A, 192
                  CALL Frog_EmitRotateRaw
                  LD   HL, FROG_TONGUE_SCR_HALF_NEG
                  LD   DE, FROG_TONGUE_SCR_HALF_NEG
                  CALL ZL_EmitTranslate
                  CALL ZL_EmitSetMatrix

                  FT_BitmapHandle 5
                  FT_BitmapSource TONGUE_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_TONGUE_W * 2, FROG_TONGUE_H
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_TONGUE_SCR_W, FROG_TONGUE_SCR_H

                  ; Vertex2f((TmpX - 48) * 16, (TmpY - 48) * 16)
                  LD   HL, (Frog_TmpX)
                  LD   DE, FROG_TONGUE_SCR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_TmpY)
                  LD   DE, FROG_TONGUE_SCR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  CALL FT.Coprocessor.Vertex2f

                  ; Reset matrix → identity для последующих ops.
                  CALL ZL_EmitLoadId
                  CALL ZL_EmitSetMatrix
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawFaceOverlay — handle 6, frog без лап (HD blink frame 0), та же
; rotation matrix что body.  Рисуется ПОСЛЕ tongue (и ball, когда будет) —
; перекрывает корень tongue, виден только tip торчащий за face area.
; ----------------------------------------------------------------------------
Frog_DrawFaceOverlay:
                  ; Overlay 122×122 = same size as body → identical rotation matrix.
                  LD   A, (Frog_Angle)
                  ADD  A, 192                            ; body native = south
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 6
                  FT_BitmapSource OVERLAY_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_SPR_W, FROG_SPR_W
                  ; Сбросить cell в 0: предыдущий next-ball оставил Cell=NextBallColor*8.
                  ; Cell — persistent DL state; без сброса Vertex2f читает overlay с
                  ; offset cell*29768 байт от OVERLAY_RAMG_ADDR — попадает за пределы
                  ; sprite в zero-padding RAM_G → alpha=0 → overlay invisible.
                  ; Проявлялось как «крышка иногда пропадает после выстрела» (75%
                  ; выстрелов: NextBallColor ∈ {1,2,3} ≠ 0).
                  XOR  A
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_PosCentered
                  CALL ZL_EmitLoadId
                  CALL ZL_EmitSetMatrix
                  RET


; ----------------------------------------------------------------------------
; Frog_EmitFrogMatrix — emit T(61) · R(A) · T(-61) → setmatrix.
;   In: A = raw rotation byte (caller добавил offset под native face direction)
; Body native = SOUTH (вызывает с Frog_Angle + 192).
; Tongue native = NORTH (вызывает с Frog_Angle + 64).
; ----------------------------------------------------------------------------
Frog_EmitFrogMatrix:
                  LD   (Frog_TmpRotByte), A
                  CALL ZL_EmitLoadId
                  LD   HL, FROG_SPR_HALF
                  LD   DE, FROG_SPR_HALF
                  CALL ZL_EmitTranslate
                  LD   A, (Frog_TmpRotByte)
                  CALL Frog_EmitRotateRaw
                  LD   HL, FROG_SPR_HALF_NEG
                  LD   DE, FROG_SPR_HALF_NEG
                  CALL ZL_EmitTranslate
                  JP   ZL_EmitSetMatrix


; ----------------------------------------------------------------------------
; Frog_EmitRotateRaw — append cmd_rotate(A) without face-direction offset.
; (ZL_EmitRotate в MainLoop делает +192 для chain — нам нужно raw.)
; ----------------------------------------------------------------------------
Frog_EmitRotateRaw:
                  LD   D, A : LD E, 0
                  LD   (ZL_TmpAngle), DE
                  LD   DE, FT_CMD_ROTATE & #FFFF
                  LD   BC, FT_CMD_ROTATE >> 16
                  CALL FT.Coprocessor.Command_BCDE
                  LD   BC, 0
                  LD   DE, (ZL_TmpAngle)
                  JP   FT.Coprocessor.Command_BCDE


; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_PosCentered — Vertex2f((PosX-61)*16, (PosY-61)*16).
; Общая часть DrawPlate / DrawBody (рисуем в текущем pos).
; ----------------------------------------------------------------------------
Frog_EmitVertex2f_PosCentered:
                  LD   HL, (Frog_PosX)
                  LD   DE, FROG_SPR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_PosY)
                  LD   DE, FROG_SPR_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  JP   FT.Coprocessor.Vertex2f


; ----------------------------------------------------------------------------
; Frog_DrawBallNow — handle 0 (chain atlas), при pos + ballExpand·dir.
; ballExpand = 24 idle, при выстреле 0 → восстанавливается.  Cell = ballColor*16.
; ----------------------------------------------------------------------------
Frog_DrawBallNow:
                  ; offsetX = (cos · ballExpand) / 128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_BallExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL
                  ; offsetY = (sin · ballExpand) / 128
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, (Frog_BallExpand)
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Native size 56×56 — оригинальный chain-ball размер.
                  FT_BitmapHandle 0
                  FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_BallColor)
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A    ; *16 (cell = color*16)
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawNextBall — handle 0, на спине frog: pos - 39·dir.
; Dark-spot в native body на (61, 22) = 39 px над centre, после rotation
; ends up в -dir (back of frog) на screen.
; ----------------------------------------------------------------------------
Frog_DrawNextBall:
                  ; offsetX = -(cos · 39) / 128 → pos - cos·39/128
                  LD   A, (Frog_Angle)
                  ADD  A, 64
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, FROG_NEXT_OFFSET
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosX)
                  ADD  HL, DE
                  LD   (Frog_TmpX), HL
                  LD   A, (Frog_Angle)
                  CALL Frog_LookupSin
                  LD   B, A
                  LD   A, FROG_NEXT_OFFSET
                  LD   C, A
                  CALL Frog_SignedScale_div128
                  NEG
                  CALL Frog_SignExtendA_HL
                  LD   DE, (Frog_PosY)
                  ADD  HL, DE
                  LD   (Frog_TmpY), HL

                  ; Native size 56×56 — оригинальный chain-ball размер.
                  FT_BitmapHandle 0
                  FT_BitmapSource FT_RAM_G + BALLS_RAMG_ADDR
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  FT_BitmapSize   FT_BILINEAR, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_NextBallColor)
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A    ; *16 (cell = color*16)
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  RET


; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_Tmp_BallCentred — Vertex2f((TmpX-16)*16, (TmpY-16)*16) для
; ball screen rect 32×32 (centra TmpX, TmpY).
; ----------------------------------------------------------------------------
Frog_EmitVertex2f_Tmp_BallCentred:
                  LD   HL, (Frog_TmpX)
                  LD   DE, FROG_BALL_DST_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_TmpY)
                  LD   DE, FROG_BALL_DST_HALF
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  EX   DE, HL
                  JP   FT.Coprocessor.Vertex2f


; ----------------------------------------------------------------------------
; Frog_AtanTable — atan(i/128) * 256/(2π) для i=0..128.  129 entries.
; ----------------------------------------------------------------------------
Frog_AtanTable:
                  DB  0,  0,  1,  1,  1,  2,  2,  2
                  DB  3,  3,  3,  3,  4,  4,  4,  5
                  DB  5,  5,  6,  6,  6,  7,  7,  7
                  DB  8,  8,  8,  8,  9,  9,  9, 10
                  DB 10, 10, 11, 11, 11, 11, 12, 12
                  DB 12, 13, 13, 13, 13, 14, 14, 14
                  DB 15, 15, 15, 15, 16, 16, 16, 17
                  DB 17, 17, 17, 18, 18, 18, 18, 19
                  DB 19, 19, 19, 20, 20, 20, 20, 21
                  DB 21, 21, 21, 22, 22, 22, 22, 23
                  DB 23, 23, 23, 23, 24, 24, 24, 24
                  DB 25, 25, 25, 25, 25, 26, 26, 26
                  DB 26, 26, 27, 27, 27, 27, 27, 28
                  DB 28, 28, 28, 28, 29, 29, 29, 29
                  DB 29, 29, 30, 30, 30, 30, 30, 31
                  DB 31, 31, 31, 31, 31, 32, 32, 32
                  DB 32


; ----------------------------------------------------------------------------
; Frog_SinTable — sin(i * 2π / 256) * 127, signed byte, для i=0..255.
; Сгенерировано: round(127 * math.sin(i * 2*pi / 256)).  Отрицательные
; значения — two's-complement (DB 253 = -3).
; Использование: cos(angle) = SinTable[(angle + 64) & 0xFF].
; ----------------------------------------------------------------------------
Frog_SinTable:
                  DB   0,   3,   6,   9,  12,  16,  19,  22,  25,  28,  31,  34,  37,  40,  43,  46
                  DB  49,  51,  54,  57,  60,  63,  65,  68,  71,  73,  76,  78,  81,  83,  85,  88
                  DB  90,  92,  94,  96,  98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116
                  DB 117, 118, 120, 121, 122, 122, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127
                  DB 127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 122, 122, 121, 120, 118
                  DB 117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100,  98,  96,  94,  92
                  DB  90,  88,  85,  83,  81,  78,  76,  73,  71,  68,  65,  63,  60,  57,  54,  51
                  DB  49,  46,  43,  40,  37,  34,  31,  28,  25,  22,  19,  16,  12,   9,   6,   3
                  DB   0, 253, 250, 247, 244, 240, 237, 234, 231, 228, 225, 222, 219, 216, 213, 210
                  DB 207, 205, 202, 199, 196, 193, 191, 188, 185, 183, 180, 178, 175, 173, 171, 168
                  DB 166, 164, 162, 160, 158, 156, 154, 152, 150, 149, 147, 145, 144, 143, 141, 140
                  DB 139, 138, 136, 135, 134, 134, 133, 132, 131, 131, 130, 130, 130, 129, 129, 129
                  DB 129, 129, 129, 129, 130, 130, 130, 131, 131, 132, 133, 134, 134, 135, 136, 138
                  DB 139, 140, 141, 143, 144, 145, 147, 149, 150, 152, 154, 156, 158, 160, 162, 164
                  DB 166, 168, 171, 173, 175, 178, 180, 183, 185, 188, 191, 193, 196, 199, 202, 205
                  DB 207, 210, 213, 216, 219, 222, 225, 228, 231, 234, 237, 240, 244, 247, 250, 253


; ----------------------------------------------------------------------------
; Frog state (data section).
; ----------------------------------------------------------------------------
Frog_Angle:        DEFB 0
Frog_RecoilTick:   DEFB 0
Frog_IsFire:       DEFB 0
Frog_PrevMouseLeft:DEFB 0
Frog_KeySpacePrev: DEFB 0                              ; SPACE debounce (0=ready, 1=fired)
Frog_TongueExpand: DEFB 24
Frog_BallExpand:   DEFB 32
Frog_TmpRecoil:    DEFB 0
Frog_TmpRotByte:   DEFB 0
Frog_BallColor:    DEFB 0
Frog_NextBallColor:DEFB 0
Frog_PosX:         DEFW FROG_DEFAULT_X
Frog_PosY:         DEFW FROG_DEFAULT_Y
Frog_PosStartX:    DEFW FROG_DEFAULT_X
Frog_PosStartY:    DEFW FROG_DEFAULT_Y
Frog_TmpX:         DEFW 0
Frog_TmpY:         DEFW 0
