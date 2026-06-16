; ============================================================================
; Frog.asm — рендер лягушки 1:1 с Zuma-Deluxe-HD/src/zuma/Frog.c.
;
; Композиция (Frog_Draw):
;   • plate без rotation под body;
;   • body с baked BITMAP_TRANSFORM вокруг центра, angle = atan2(mouse - frog);
;     native sprite смотрит вниз (BRAD 64), поэтому вызывающие добавляют +192;
;   • tongue с offset (tongueExpand · dir) и той же baked matrix вокруг центра
;     sprite. dir = (cos(angle), sin(angle)) (см. Frog_SinTable ниже).
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
; Формат слоя выбирается через FROG_ARGB4_ENABLED в main.asm.
; ============================================================================

FROG_SPR_W        EQU 122                               ; atlas layout/UV — НЕ масштабировать
FROG_SPR_HALF     EQU 61                                ; центр atlas = UV pivot
FROG_SPR_HALF_NEG EQU -FROG_SPR_HALF & 0xFFFF          ; -61 в 16-bit two's complement
; 1024×768 порт: тело/тарелка/overlay рисуются ×1.6 через cmd_scale + matrix LUT.
FROG_SPR_DRAW     EQU 195                               ; экранный размер = round(122×8/5)
FROG_SPR_SCR_HALF EQU 98                                ; round(195/2) — screen pivot
FROG_SPR_SCR_HALF_NEG EQU -FROG_SPR_SCR_HALF & 0xFFFF
; FROG_UPSCALE удалён вместе с Frog_EmitUpscale16 (канон: запечённые TRANSFORM)

; Tongue full 122×122 ARGB4 — точный 1:1 перенос из Python visual_emulator.py.
; UV pivot (61,61) = центр sprite = HD anchor (native centre 81,81 в 162×162,
; после resize 162→122). Screen rect совпадает со sprite size; круглый sprite
; помещается в square rect при любом rotation без clipping.
FROG_TONGUE_W     EQU 122                               ; sprite W в RAM_G
FROG_TONGUE_H     EQU 122                               ; sprite H в RAM_G
FROG_TONGUE_UV_HW EQU 61                                ; UV pivot = центр sprite
FROG_TONGUE_UV_HH EQU 61
FROG_TONGUE_SCR_W EQU 195                               ; 1024×768: draw ×1.6
FROG_TONGUE_SCR_H EQU 195
FROG_TONGUE_SCR_HALF EQU 98                              ; экранный центр round(195/2)
FROG_TONGUE_SCR_HALF_NEG EQU -FROG_TONGUE_SCR_HALF & 0xFFFF

; Overlay 122×122: тот же размер, что body; features совпадают по координатам.

FROG_RECOIL_STEP  EQU 10                                ; BRAD/frame; π/0.25 ≈ 12.6 кадров полу-периода

FROG_BALL_IDLE    EQU 38                                ; 1024×768: HD idle 24 ×1.6 (орбита held-ball от центра 195px-тела)
FROG_NEXT_OFFSET  EQU 45                                ; 1024×768: HD 28 ×1.6 — окно спины (next ball) уехало ×1.6
FROG_BALL_W       EQU 32                                ; native classic cell ball atlas 32×32
FROG_BALL_DST_W   EQU 51                                ; 1024×768: экранный размер = round(32×8/5) (как chain ball)
FROG_BALL_DST_HALF EQU 26                               ; round(51/2) — центр draw-rect'а


; ----------------------------------------------------------------------------
; Frog_Init — обнулить state.  F12-reset не reload'ит RAM, поэтому всё
; инициализируется явно.
; ----------------------------------------------------------------------------
Frog_Init:        XOR  A
                  LD   (Frog_Angle), A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_IsFire), A
                  LD   (FROG_RTC_MIX_CNT_ADDR), A      ; slot 1 free RAM counter: F12 reset его не чистит
                  LD   (FROG_RTC_MIX_FLAG_ADDR), A     ; pending RTC mix flag
                  DEC  A                                ; A = #FF
                  LD   (FROG_EXCLUDE_COLOR_ADDR), A    ; exclude-color = 0xFF (none)
                  XOR  A                                ; вернуть A=0 для последующих stores
                  LD   A, 1                            ; pre-init = pressed → без ложного rise edge
                  LD   (Frog_PrevMouseLeft), A         ; edge-rise на первом кадре
                  LD   (Frog_KeySpacePrev), A
                  XOR  A
                  LD   A, 24
                  LD   (Frog_TongueExpand), A
                  LD   A, FROG_BALL_IDLE
                  LD   (Frog_BallExpand), A
                  CALL GetCurrentFrogX
                  LD   (Frog_PosX), HL
                  LD   (Frog_PosStartX), HL
                  CALL GetCurrentFrogY
                  LD   (Frog_PosY), HL
                  LD   (Frog_PosStartY), HL
                  ; Начальные цвета шаров через VDC RNG, уже seeded в VDC_Init.
                  CALL VDC_RandomColor
                  LD   (Frog_BallColor), A
                  CALL VDC_RandomColor
                  LD   (Frog_NextBallColor), A
                  RET


; ----------------------------------------------------------------------------
; Frog_Update — ComputeAngle вызывается, пока mouse активна или grace > 0:
; после остановки motion Smooth ещё несколько кадров догоняет raw-координаты.
; Без grace angle фризится на lagged значении; после истечения grace keyboard
; ←/→ управляет Frog_Angle через ZL_AimUpdate без перезаписи от atan2.
; ----------------------------------------------------------------------------
Frog_Update:      LD   A, (ZL_MouseMoved)
                  OR   A
                  JR   NZ, .fu_compute                 ; motion → обновить angle
                  LD   A, (ZL_MotionGrace)
                  OR   A
                  JR   Z, .fu_skip                     ; grace=0 → keyboard mode
                  DEC  A
                  LD   (ZL_MotionGrace), A             ; tick down
.fu_compute:      CALL Frog_ComputeAngle
.fu_skip:         ; Refilter — это re-randomization которая дёргает LFSR seed и может
                  ; спонтанно менять Frog_BallColor/NextBallColor. Только в PLAY!
                  ; INTRO/PREVIEW/CLOSING/ABSORB/GAMEOVER → колайс жабы остаются стабильные.
                  LD   A, (VDC_GameState)
                  OR   A
                  JR   NZ, .fu_skip_refilter
                  CALL Frog_RefilterCurrent
.fu_skip_refilter:
                  CALL Frog_HandleMouse
                  JP   Frog_TickRecoil


; ----------------------------------------------------------------------------
; Frog_ComputeAngle — Frog_Angle = atan2(SmoothY-PosStartY, SmoothX-PosStartX).
; 8-октантная схема + AtanTable[129] + hybrid slow/fast follow.
; ----------------------------------------------------------------------------
; Frog_FireKeyboard — keyboard path для fire; основная ЛКМ-ветка ниже.
Frog_FireKeyboard:
                  LD   A, (Frog_KeySpacePrev)
                  OR   A
                  RET  NZ                              ; уже fired в прошлом кадре
                  LD   A, 1
                  LD   (Frog_KeySpacePrev), A
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                              ; уже стреляем (recoil идёт)
                  ; Start fire: тот же порядок state updates, что в Frog_HandleMouse.
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= шар изо рта)
                  RET  C
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now
                  CALL Frog_NewNextColor               ; новый filtered NextBallColor
                  LD   A, 1
                  LD   (Frog_IsFire), A
                  XOR  A
                  LD   (Frog_RecoilTick), A
                  LD   (Frog_BallExpand), A
                  RET


; ----------------------------------------------------------------------------
; Frog_HandleMouse — rise edge по Input_MouseLMB, при необходимости стартует fire.
; HD-порядок: первое нажатие (prev=0, curr=1) и !isFire → start fire.
; ----------------------------------------------------------------------------
Frog_HandleMouse:
                  LD   A, (VDC_HudPointerBlock)
                  OR   A
                  JR   Z, .fh_mouse_free
                  CALL Input_MouseLMB
                  LD   A, 0
                  JR   Z, .fh_block_save
                  LD   A, 1
.fh_block_save:   LD   (Frog_PrevMouseLeft), A
                  XOR  A
                  LD   (VDC_HudPointerBlock), A
                  RET
.fh_mouse_free:
                  ; Fire = только ЛКМ через Input.asm. RMB/SPACE/Kempston на этой
                  ; ветке не читаются: на реальном/эмулируемом порту возможен
                  ; phantom-pressed, который ломает rise edge.
                  CALL Input_MouseLMB                  ; Z=released, NZ=pressed
                  LD   A, 0
                  JR   Z, .save
                  LD   A, 1
.save:            LD   HL, Frog_PrevMouseLeft
                  LD   B, (HL)                         ; B = prev
                  LD   (HL), A                         ; сохранить curr
                  OR   A
                  RET  Z                                ; curr=0 → не rise
                  LD   A, B
                  OR   A
                  RET  NZ                               ; prev=1 → не rise
                  LD   A, (Frog_IsFire)
                  OR   A
                  RET  NZ                               ; уже стреляем
                  ; Start fire (HD): promote nextBall → ballColor, new next 0..3,
                  ; ballExpand=0, recoilTick=0, isFire=1.
                  CALL Bullet_Spawn                    ; spawn с CURRENT BallColor (= шар изо рта)
                  RET  C
                  LD   A, (Frog_NextBallColor)
                  LD   (Frog_BallColor), A             ; promote next → ball-now
                  CALL Frog_NewNextColor               ; новый filtered NextBallColor
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

                  ; ballExpand: если < FROG_BALL_IDLE → += 3.
                  ; HD 2.5/frame ×1.6 ≈ 4, но 3 ближе к текущему feel.
                  LD   A, (Frog_BallExpand)
                  CP   FROG_BALL_IDLE
                  JR   NC, .be_done
                  ADD  A, 3
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
; Frog_LookupSin — A = Frog_SinTable[A]. Clobbers D, E, HL.
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
                  LD   E, 0                             ; флаг знака
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
; Frog_Mul8x8u — D × E → HL (unsigned 16-bit). Clobbers A, B, DE.
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
; Frog_DrawPlate — handle 4, без rotation, на текущем pos с recoil offset.
; Ставит scale-only matrix для ×1.6 и выводит plate под body.
; ----------------------------------------------------------------------------
Frog_DrawPlate:   XOR  A
                  CALL Frog_EmitFrogMatrix              ; scale-only matrix (угол 0 = без вращения) для ×1.6
                  FT_BitmapHandle 4
                  if !FROG_ARGB4_ENABLED
                  FT_PaletteSource PLATE_PALETTE_RAMG
                  endif
                  FT_BitmapSource PLATE_RAMG_ADDR
                  if FROG_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  else
                  FT_BitmapLayout FT_PALETTED4444, FROG_SPR_W, FROG_SPR_W
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_SPR_DRAW, FROG_SPR_DRAW
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawBody — handle 2, rotation matrix вокруг центра sprite.
;   matrix = T(61,61) · R(angle - 64) · T(-61,-61)
; Body native face = SOUTH (BRAD 64) → нужен offset -64 (= +192 mod 256).
; ----------------------------------------------------------------------------
Frog_DrawBody:    LD   A, (Frog_Angle)
                  ADD  A, 192                          ; body: -64 BRAD, native south
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 2
                  if !FROG_ARGB4_ENABLED
                  FT_PaletteSource FROG_PALETTE_RAMG
                  endif
                  FT_BitmapSource FROG_RAMG_ADDR
                  if FROG_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  else
                  FT_BitmapLayout FT_PALETTED4444, FROG_SPR_W, FROG_SPR_W
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_SPR_DRAW, FROG_SPR_DRAW
                  CALL Frog_EmitVertex2f_PosCentered
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawTongue — handle 5, full 122×122 sprite на pos + tongueExpand·dir,
; rotation вокруг центра tongue sprite.
;   tongueX = pos.x + (cos(angle) * tongueExpand) / 128
;   tongueY = pos.y + (sin(angle) * tongueExpand) / 128
;   matrix  = baked T(61,61) · R(angle + 192) · T(-61,-61), scale ×1.6
; Tongue native смотрит вниз, rotation как у body.
; ----------------------------------------------------------------------------
Frog_DrawTongue:
                  ; HD-style: центр tongue = pos + tongueExpand·dir (orbit).
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

                  ; 1024×768: запечённая scale+rotate матрица (pivot 61), как тело.
                  LD   A, (Frog_Angle)
                  ADD  A, 192                          ; tongue native face offset
                  CALL Frog_EmitFrogMatrix

                  FT_BitmapHandle 5
                  if !FROG_ARGB4_ENABLED
                  FT_PaletteSource TONGUE_PALETTE_RAMG
                  endif
                  FT_BitmapSource TONGUE_RAMG_ADDR
                  if FROG_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_TONGUE_W * 2, FROG_TONGUE_H
                  else
                  FT_BitmapLayout FT_PALETTED4444, FROG_TONGUE_W, FROG_TONGUE_H
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_TONGUE_SCR_W, FROG_TONGUE_SCR_H

                  ; Vertex2f((TmpX - FROG_TONGUE_SCR_HALF) * 16,
                  ;          (TmpY - FROG_TONGUE_SCR_HALF) * 16)
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
                  ; (reset матрицы убран: следующий слой (overlay/ball/курсор)
                  ;  ставит свою матрицу; экономит Main1 под baked frog matrix)
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawFaceOverlay — handle 6, frog без лап (HD blink frame 0), та же
; rotation matrix что body. Рисуется ПОСЛЕ tongue и ball —
; перекрывает корень tongue, виден только tip торчащий за face area.
; ----------------------------------------------------------------------------
Frog_DrawFaceOverlay:
                  ; Overlay 122×122 = тот же размер, что body → та же rotation matrix.
                  LD   A, (Frog_Angle)
                  ADD  A, 192                            ; body native = south
                  CALL Frog_EmitFrogMatrix
                  FT_BitmapHandle 6
                  if !FROG_ARGB4_ENABLED
                  FT_PaletteSource OVERLAY_PALETTE_RAMG
                  endif
                  FT_BitmapSource OVERLAY_RAMG_ADDR
                  if FROG_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_SPR_W * 2, FROG_SPR_W
                  else
                  FT_BitmapLayout FT_PALETTED4444, FROG_SPR_W, FROG_SPR_W
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_SPR_DRAW, FROG_SPR_DRAW
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
; Frog_EmitFrogMatrix — эмитит ЗАПЕЧЁННУЮ BITMAP_TRANSFORM A..F (scale 0.6256
; + rotate вокруг центра, pivot 61). cmd_scale НЕ компонуется в цепочке
; translate+scale+rotate (cyan-кайма), поэтому матрицу строим напрямую как ball
; LUT. Математика валидирована в Source/OTHER/sim_frog_matrix.py (int=float ±0.22px):
;   A=E=(cos·323)>>8, B=(sin·323)>>8, D=-B  (cos/sin в *127 из Frog_SinTable)
;   C=15616-(cos+sin)·123, F=15616-(cos-sin)·123   (15616=61·256, 123≈61·256/127)
;   In: A = angle BRAD, вызывающий уже добавил face-offset.
; ----------------------------------------------------------------------------
Frog_EmitFrogMatrix:
                  LD   (Frog_TmpRotByte), A
                  CALL Frog_LookupSin                  ; sin127, signed 256-entry table
                  LD   (Frog_TmpSin), A
                  LD   A, (Frog_TmpRotByte)
                  ADD  A, 64
                  CALL Frog_LookupSin                  ; cos127 = sin(b+90°)
                  LD   (Frog_TmpCos), A
                  ; A (op #15) = (cos·323)>>8
                  LD   A, (Frog_TmpCos)
                  CALL Frog_Mul323Sh8                  ; HL = scaled cos
                  LD   (Frog_TmpAE), HL
                  LD   A, #15
                  CALL Frog_EmitX17
                  ; B (op #16) = (sin·323)>>8
                  LD   A, (Frog_TmpSin)
                  CALL Frog_Mul323Sh8
                  LD   (Frog_TmpB), HL
                  LD   A, #16
                  CALL Frog_EmitX17
                  ; C (op #17) = 15616 - (cos+sin)·123
                  LD   A, (Frog_TmpSin)
                  CALL Frog_SignExtendA_HL
                  EX   DE, HL                          ; DE = sin (signed16)
                  LD   A, (Frog_TmpCos)
                  CALL Frog_SignExtendA_HL             ; HL = cos
                  ADD  HL, DE                          ; HL = cos+sin
                  LD   A, #17
                  CALL Frog_EmitCF
                  ; D (op #18) = -B
                  LD   HL, (Frog_TmpB)
                  LD   A, L : CPL : LD L, A
                  LD   A, H : CPL : LD H, A
                  INC  HL                              ; HL = -B
                  LD   A, #18
                  CALL Frog_EmitX17
                  ; E (op #19) = A
                  LD   HL, (Frog_TmpAE)
                  LD   A, #19
                  CALL Frog_EmitX17
                  ; F (op #1A) = 15616 - (cos-sin)·123
                  LD   A, (Frog_TmpSin)
                  CALL Frog_SignExtendA_HL
                  EX   DE, HL                          ; DE = sin
                  LD   A, (Frog_TmpCos)
                  CALL Frog_SignExtendA_HL             ; HL = cos
                  AND  A
                  SBC  HL, DE                          ; HL = cos-sin
                  LD   A, #1A
                  JP   Frog_EmitCF

; Frog_Mul323Sh8 — In A=signed(-127..127), Out HL=signed A·323/256 (точно).
; 323/256 = 1.2617 ≈ 160/127: при cos=127 даёт РОВНО 160 (канон 1/1.6 = 160/256).
; Прежний шорткат A·1.25 давал 158 → эффективный масштаб 256/158 = 1.6203 →
; спрайт 122px рисовался на 197.7px при окне 195 → тарелка резалась справа/снизу.
; 323·x = 256·x + 67·x → результат = |A| + (|A|·67 >> 8), затем знак.
Frog_Mul323Sh8:   LD   C, A                            ; C = исходное signed (знак)
                  BIT  7, A : JR Z, .m323_abs
                  NEG                                  ; A = |A|
.m323_abs:        LD   D, A
                  LD   E, 67
                  CALL Frog_Mul8x8u                    ; HL = |A|·67 (C не клобберится)
                  LD   A, C
                  BIT  7, A : JR Z, .m323_mag
                  NEG                                  ; A = |A| снова
.m323_mag:        ADD  A, H                            ; |A| + (|A|·67)>>8, max 160 — в байт
                  LD   L, A
                  LD   H, 0
                  BIT  7, C
                  RET  Z                               ; положительный — готово
                  XOR  A
                  SUB  L
                  LD   L, A
                  SBC  A, A
                  LD   H, A                            ; HL = -magnitude
                  RET

; Frog_EmitX17 — In A=opcode, HL=signed value → append (op<<24)|(val&0x1FFFF).
Frog_EmitX17:     LD   B, A
                  LD   C, 0
                  BIT  7, H : JR Z, .x17p
                  LD   C, 1                            ; bit16 = sign
.x17p:            EX   DE, HL                          ; DE = value low16
                  JP   FT.Coprocessor.Command_BCDE

; Frog_EmitCF — In A=opcode, HL=(cos±sin) signed → C24 = 15616 - HL·123, append.
Frog_EmitCF:      LD   (Frog_TmpOp), A
                  CALL Frog_Mul123                     ; HL = HL·123
                  LD   A, H : ADD A, A : SBC A, A      ; A = sign byte of HL (0x00/0xFF)
                  LD   B, A                            ; B = sext byte
                  XOR  A : SUB L : LD E, A             ; byte0 = 0-L, CF=borrow0
                  LD   A, #3D : SBC A, H : LD D, A     ; byte1 = 0x3D - H - borrow0
                  LD   A, #00 : SBC A, B : LD C, A     ; byte2 = 0 - sext - borrow1
                  LD   A, (Frog_TmpOp) : LD B, A       ; B = opcode
                  JP   FT.Coprocessor.Command_BCDE     ; word = op<<24 | byte2<<16 | byte1<<8 | byte0

; Frog_Mul123 — In HL=signed, Out HL=HL·123 (= 128·HL - 5·HL).
Frog_Mul123:      LD   D, H : LD E, L                  ; DE = x
                  ADD  HL, HL : ADD HL, HL             ; 4x
                  ADD  HL, DE                          ; 5x
                  EX   DE, HL                          ; DE = 5x, HL = x
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL : ADD HL, HL : ADD HL, HL  ; 128x
                  AND  A : SBC HL, DE                  ; 128x - 5x = 123x
                  RET

; Frog_EmitUpscale16 УДАЛЁН: все вызывающие переведены на ZL_EmitScale16Matrix
; (запечённые TRANSFORM-слова, точная 1.6) — CMD_SCALE давал ×1.6101 из-за
; усечённой инверсии в копроцессоре.

; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_PosCentered — выводит текущий Frog_Pos как центр 195px rect.
; ----------------------------------------------------------------------------
Frog_EmitVertex2f_PosCentered:
                  LD   HL, (Frog_PosX)
                  LD   DE, FROG_SPR_SCR_HALF            ; центр draw-rect'а 195px (1024×768)
                  AND  A
                  SBC  HL, DE
                  ADD  HL, HL : ADD HL, HL
                  ADD  HL, HL : ADD HL, HL
                  LD   B, H : LD C, L
                  LD   HL, (Frog_PosY)
                  LD   DE, FROG_SPR_SCR_HALF
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

                  ; Эмит rotation matrix, совпадающую с направлением лягушки.
                  LD   A, (Frog_Angle)
                  CALL ZL_EmitBallMatrixFromBRAD

                  ; Balls atlas: ARGB4 canary использует один 16-phase handle;
                  ; baseline PALETTED4444 использует dual handle.
                  if BALLS_ARGB4_ENABLED
                  XOR  A
                  else
                  LD   A, (Frog_BallColor)
                  CP   4
                  LD   A, 0
                  JR   C, .fbm_h
                  LD   A, 9
                  endif
.fbm_h:           CALL ZL_EmitBallHandle
                  if BALLS_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  else
                  FT_PaletteSource BALLS_PALETTE_RAMG
                  FT_BitmapLayout FT_PALETTED4444, FROG_BALL_W, FROG_BALL_W
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_BallColor)
                  if BALLS_ARGB4_ENABLED
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A              ; *16 = local cell
                  else
                  AND  3
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A    ; *32 = local cell
                  endif
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  ; (reset матрицы убран: следующий слой ставит свою; экономит Main1)
                  RET


; ----------------------------------------------------------------------------
; Frog_DrawNextBall — handle 0, на спине frog: pos - 39·dir.
; Dark-spot в native body на (61,22) = 39 px над centre; после rotation
; он оказывается в -dir, то есть на screen-спине лягушки.
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

                  ; 1024×768: своя scale(1.6)-матрица — без неё next ball наследует
                  ; scale+rotate матрицу языка (pivot 61) и рисуется криво/мелко.
                  CALL ZL_EmitScale16Matrix
                  ; Balls atlas: ARGB4 canary использует один 16-phase handle;
                  ; baseline PALETTED4444 использует dual handle.
                  if BALLS_ARGB4_ENABLED
                  XOR  A
                  else
                  LD   A, (Frog_NextBallColor)
                  CP   4
                  LD   A, 0
                  JR   C, .fbn_h
                  LD   A, 9
                  endif
.fbn_h:           CALL ZL_EmitBallHandle
                  if BALLS_ARGB4_ENABLED
                  FT_BitmapLayout FT_ARGB4, FROG_BALL_W * 2, FROG_BALL_W
                  else
                  FT_PaletteSource BALLS_PALETTE_RAMG
                  FT_BitmapLayout FT_PALETTED4444, FROG_BALL_W, FROG_BALL_W
                  endif
                  FT_BitmapSize   FT_NEAREST, FT_BORDER, FT_BORDER, FROG_BALL_DST_W, FROG_BALL_DST_W
                  LD   A, (Frog_NextBallColor)
                  if BALLS_ARGB4_ENABLED
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A              ; *16 = local cell
                  else
                  AND  3
                  ADD  A, A : ADD A, A : ADD A, A : ADD A, A : ADD A, A    ; *32 = local cell
                  endif
                  CALL FT.Coprocessor.Cell
                  CALL Frog_EmitVertex2f_Tmp_BallCentred
                  RET


; ----------------------------------------------------------------------------
; Frog_EmitVertex2f_Tmp_BallCentred — Vertex2f((TmpX-16)*16, (TmpY-16)*16)
; для ball screen rect; центр берётся из TmpX/TmpY.
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
; Frog_SinTable — signed sin lookup для BRAD-угла 0..255.
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
Frog_RecoilTick:   DEFB 0
Frog_IsFire:       DEFB 0
Frog_PrevMouseLeft:DEFB 0
Frog_KeySpacePrev: DEFB 0                              ; SPACE debounce: 0=ready, 1=fired
Frog_TongueExpand: DEFB 24
Frog_BallExpand:   DEFB FROG_BALL_IDLE
Frog_TmpRecoil:    DEFB 0
Frog_TmpRotByte:   DEFB 0
Frog_TmpSin:       DEFB 0                               ; scratch baked-matrix: sin127 signed
Frog_TmpCos:       DEFB 0                               ; cos127 signed
Frog_TmpOp:        DEFB 0                               ; opcode для Frog_EmitCF
Frog_TmpAE:        DEFW 0                               ; matrix A=E, scaled cos
Frog_TmpB:         DEFW 0                               ; matrix B, scaled sin
; Frog_BallColor и Frog_NextBallColor живут в loader_resident.asm (resident Core).
Frog_PosX:         DEFW FROG_DEFAULT_X
Frog_PosY:         DEFW FROG_DEFAULT_Y
Frog_TmpX:         DEFW 0
Frog_TmpY:         DEFW 0
