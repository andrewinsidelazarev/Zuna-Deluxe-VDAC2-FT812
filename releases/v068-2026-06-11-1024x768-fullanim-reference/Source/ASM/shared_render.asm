; shared_render.asm — DL-matrix + frog-render machinery, HOISTED RESIDENT.
;
; These routines/tables/vars are used by BOTH gameplay (overlay #04) AND the
; level-select preview render (overlay #41). After the main1_play overlay split
; they MUST be resident (slot 1, always mapped) so either scene can call them
; without paging gymnastics. Moved verbatim from VDC.asm/Frog.asm/MainLoop.asm;
; names unchanged (module Core) so all existing references resolve untouched.
; (User decision 2026-05-27: keep render machinery global, split the rest.)

; ===================== moved from VDC.asm =====================
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

; ===================== moved from Frog.asm =====================
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
; (Тело Frog_FireKeyboard — в Frog.asm. Вызывается ZL_AimUpdate после того, как
; ГЛОБАЛЬНЫЙ Input_FireKey вернул «нажато»; порт #7FFE напрямую больше не читается.
; Свой debounce через Frog_KeySpacePrev — независимо от LMB edge-rise в
; Frog_HandleMouse, чтобы зажатый огонь не повторял выстрел.)
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
Frog_Angle:        DEFB 0
Frog_PosStartX:    DEFW FROG_DEFAULT_X
Frog_PosStartY:    DEFW FROG_DEFAULT_Y

; ===================== moved from MainLoop.asm =====================
ZL_EmitLoadId:  LD   DE, FT_CMD_LOADIDENTITY & #FFFF
                LD   BC, FT_CMD_LOADIDENTITY >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitTranslate — append cmd_translate(tx, ty) в CMD буфер.
;   In:  HL = tx_int_px (signed 16), DE = ty_int_px (signed 16)
;   Параметры передаются в FT812 как fixed-point 1/65536 px:
;   tx_subpx = tx_px * 65536 → low_word = 0, high_word = tx_px.
; ----------------------------------------------------------------------------
ZL_EmitTranslate:
                LD   (ZL_TmpTx), HL
                LD   (ZL_TmpTy), DE
                LD   DE, FT_CMD_TRANSLATE & #FFFF
                LD   BC, FT_CMD_TRANSLATE >> 16
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTx)
                CALL FT.Coprocessor.Command_BCDE
                LD   DE, 0
                LD   BC, (ZL_TmpTy)
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitRotate — append cmd_rotate(angle) в CMD буфер.
;   In:  A = tangent byte 0..255 (256 = full circle)
;   Native sprite face direction в spritesheet — DOWN (0° = низ экрана).
;   tangent байт = atan2(dy, dx): 0=right, 64=down, 128=left, 192=up.
;   Чтобы face шёл по track-направлению, поворачиваем на (tangent - 64),
;   то есть для tangent=64 (= down) поворот=0 (face остаётся внизу = вдоль
;   движения). Эквивалент `ADD A, 192` (= -64 mod 256).
; ----------------------------------------------------------------------------
ZL_EmitSetMatrix:
                LD   DE, FT_CMD_SETMATRIX & #FFFF
                LD   BC, FT_CMD_SETMATRIX >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_AimUpdate — detect mouse motion (с threshold для подавления Hyper-V Kempston
; jitter) + keyboard arrows меняют Frog_Angle напрямую.
;
; Архитектура (1:1 с VDC коллеги): Frog_Angle = primary state (8-bit BRAD wraps
; → 360° автоматом). Если мышь двинулась — set ZL_MouseMoved=1, иначе =0.
; Frog_Update вызывает ComputeFrogAngle ТОЛЬКО при ZL_MouseMoved=1 — иначе
; угол от клавиш сохраняется. Combine, не mode-toggle: клавиши применяются
; КАЖДЫЙ кадр (до atan2-проверки), мышь wins при движении.
;
; Threshold ZL_MOTION_THR = 1 px: отсекает только полный «zero motion» когда мышь
; физически не движется (защищает клавиатурный режим от ложных takeover при
; idle mouse). Sub-pixel Hyper-V jitter подавляется EMA-фильтром в ZL_SmoothMouse,
; не deadzone'ом — иначе медленный aim (1-2 px/frame) теряется.
; ----------------------------------------------------------------------------
ZL_SmoothX:     DEFW 512                              ; центр 1024×768
ZL_SmoothY:     DEFW 384
ZL_TmpTx:       DEFW 0                                ; ZL_EmitTranslate scratch X
ZL_TmpTy:       DEFW 0                                ; ZL_EmitTranslate scratch Y
ZL_TmpAngle:    DEFW 0                                ; ZL_EmitRotate scratch angle
