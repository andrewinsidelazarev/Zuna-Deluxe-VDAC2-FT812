; shared_render.asm — DL-matrix + frog-render machinery, resident Core.
;
; Эти routines/tables/vars используются gameplay overlay #04 и preview render
; в level-select overlay #41. После split main1_play они должны быть resident
; в slot 1, чтобы обе сцены вызывали их без paging gymnastics. Имена сохранены
; в module Core, поэтому существующие ссылки остаются валидными.

; ===================== VDC helpers =====================
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
; VDC_RandomColor — LFSR Galois 16-bit (poly 0xB400). Выход: A = 0..NUM_COLORS-1.
; Распределение: используем (rand8 * NUM_COLORS) >> 8 вместо AND 7 + clamp,
; иначе в 6-цветовом случае colors 0/1 встречаются 2× чаще остальных
; (8 mod 6 = 2 → дубли 6→0 и 7→1). Mul/shift даёт ≤1.4% bias.
; ============================================================================

; ===================== Frog helpers =====================
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
.dx_pos:          PUSH HL                              ; сохранить полный |dx| на время вычитания dy
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
.dy_pos:          LD   A, H                            ; H:E = full |dy|
                  LD   E, L
                  POP  HL
                  LD   C, L                            ; D:C = full |dx|
                  LD   D, H
                  LD   H, A
                  ; Общий scale обеих величин до 8 bit. Независимое насыщение
                  ; ломает ratios дальних targets (600:300 -> 255:255).
.scale_loop:      LD   A, D
                  OR   H
                  JR   Z, .scaled_8
                  SRL  D
                  RR   C
                  SRL  H
                  RR   E
                  JR   .scale_loop
.scaled_8:        ; C = scaled |dx|, E = scaled |dy|
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
                  CALL Frog_Div16by8                   ; A = floor(E*128 / C)
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
; Frog_Div16by8 — floor(E*128 / C) → A для ratio в Frog_ComputeAngle.
;   Вход: E = min(|dx|,|dy|), C = max(|dx|,|dy|), C > 0, E <= C.
;   Выход: A = 0..128. Сохраняет B (quadrant flags) и C.
;   Fixed 7-step fractional division; избегает старого worst case subtract-loop.
; ----------------------------------------------------------------------------
Frog_Div16by8:    LD   A, E
                  OR   A
                  RET  Z
                  CP   C
                  JR   NZ, .d8_not_full
                  LD   A, 128
                  RET
.d8_not_full:     LD   H, 0                            ; 9-bit remainder high byte
                  XOR  A                              ; quotient
                  LD   D, 7
.d8_loop:         SLA  E                              ; remainder <<= 1
                  RL   H
                  ADD  A, A                           ; quotient <<= 1
                  LD   L, A
                  LD   A, H
                  OR   A
                  JR   NZ, .d8_sub
                  LD   A, E
                  CP   C
                  JR   C, .d8_no_sub
.d8_sub:          LD   A, E
                  SUB  C
                  LD   E, A
                  LD   A, H
                  SBC  A, 0
                  LD   H, A
                  LD   A, L
                  INC  A
                  JR   .d8_next
.d8_no_sub:       LD   A, L
.d8_next:         DEC  D
                  JR   NZ, .d8_loop
                  RET


; ----------------------------------------------------------------------------
; (Тело Frog_FireKeyboard — в Frog.asm. Вызывается из Frog_Update после выбора
; активной живой цепочки; порт #7FFE напрямую больше не читается.
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
; Frog_EmitVertex2f_PosCentered — вывод Vertex2f((PosX-61)*16, (PosY-61)*16).
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

; ===================== MainLoop helpers =====================
ZL_EmitLoadId:  LD   DE, FT_CMD_LOADIDENTITY & #FFFF
                LD   BC, FT_CMD_LOADIDENTITY >> 16
                JP   FT.Coprocessor.Command_BCDE

; ----------------------------------------------------------------------------
; ZL_EmitTranslate — append cmd_translate(tx, ty) в CMD буфер.
;   Вход:  HL = tx_int_px (signed 16), DE = ty_int_px (signed 16)
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
;   Вход: A = tangent byte 0..255 (256 = full circle)
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
; Resident_EmitScale16 — LOADIDENTITY + CMD_SCALE(1.6,1.6) + SETMATRIX готовым
; CMD-блоком (LDIR). РЕЗИДЕНТНЫЙ (Main0): доступен из любой сцены/страницы —
; menu/#41, loader/#40, gameplay/#04, slot0. 1024×768-порт.
; ----------------------------------------------------------------------------
Resident_EmitScale16:
                ; ЗАПЕЧЁННЫЕ TRANSFORM-слова (A=E=160/256 = ровно 1/1.6) вместо
                ; CMD_SCALE: инверсия копроцессора усечённая (159/256 = ×1.6101) —
                ; контент дрейфовал до +6px у правого края экрана.
                LD   HL, .cmds
                LD   DE, (FT.Coprocessor.BufferPtr)
                LD   BC, 24
                LDIR
                LD   (FT.Coprocessor.BufferPtr), DE
                RET
.cmds:          DEFD #150000A0                          ; BITMAP_TRANSFORM_A = 160/256
                DEFD #16000000                          ; B = 0
                DEFD #17000000                          ; C = 0
                DEFD #18000000                          ; D = 0
                DEFD #190000A0                          ; BITMAP_TRANSFORM_E = 160/256
                DEFD #1A000000                          ; F = 0

; ----------------------------------------------------------------------------
; DrawBlackTransitionFrame — свопнуть ЧИСТЫЙ чёрный DL (clear-only, ни одной
; ссылки на bitmap'ы RAM_G) и ДОЖДАТЬСЯ его показа. Вызывается на каждом
; межсценном переходе ПЕРЕД перезаписью RAM_G ассетами новой сцены: иначе на
; экране остаётся старый DL, чьи битмапы шинкуются загрузкой, → мусор.
; РЕЗИДЕНТ (Main0, перенесён из page0 — там нет места). Требует slot3=#41
; (MenuSwapFrame живёт на UI-странице) — все вызывающие это гарантируют.
; ----------------------------------------------------------------------------
DrawBlackTransitionFrame:
                FT_CMD_Start
                FT_DL_Start
                FT_VertexFormat 4
                FT_ClearColorRGB32 0x000000
                FT_ClearAll
                FT_Display
                CALL ClearRamDlForShortUiFrame
                FT_CMD_Count
                CALL MenuSwapFrame
                ; MenuSwapFrame сам синхронизируется по INT_SWAP и ставит black
                ; swap в очередь. Здесь ждём только REG_DLSWAP==0: display engine
                ; забрал чёрный DL на границе кадра, значит старый DL со ссылками
                ; на перезаписываемые битмапы больше не активен. INT_FLAGS здесь
                ; не читать: на реальном FT812 это clear-on-read, второй poll мог
                ; бы съесть событие следующего MenuSwapFrame.
                ; Bounded wait: если Unreal/FT пропустит edge, не висеть вечно
                ; на black transition frame.
                LD   L, 64
.wait_black:    FT_RD_REG8 FT_REG_DLSWAP
                AND  3
                JR   Z, .done
                DEC  L
                JR   NZ, .wait_black
.done:
                RET

; ----------------------------------------------------------------------------
; ZL_FT_CMD_Write_DMA — отправка кадра CMD_ADDRESS_PTR..BufferPtr в
; FT_REG_CMDB_WRITE через TS-Config DMA_RAM_SPI. РЕЗИДЕНТ (Main0): зовут и
; MainLoop (#04), и меню/level-select (#41) — раньше сцены меню слали кадр
; медленным OTIR без vsync → дёрганье после 1024-рефактора. Контракт: вызов
; только после WaitFlush предыдущего кадра (в FIFO есть место под весь кадр).
; ----------------------------------------------------------------------------
ZL_CMD_DMA_PAGE EQU #05
ZL_CMD_DMA_ADDR EQU CMD_ADDRESS_PTR & #3FFF

ZL_FT_CMD_Write_DMA:
                FT_CMD_Count                            ; BC = byte count
                LD   A, B
                OR   C
                RET  Z

                ; Перевести byte count в word count для DMA registers.
                SRL  B
                RR   C
                LD   A, B
                LD   (ZL_CmdDmaWordsHi), A              ; full 512-byte chunks
                LD   A, C
                LD   (ZL_CmdDmaWordsLo), A              ; trailing words

                FT_ON
                ; FT812 SPI memory-write header: 1,0,address[21:0], затем payload.
                LD   A, ((FT_REG_CMDB_WRITE >> 16) & #FF) | #80
                OUT  (SPI_DATA), A
                LD   A, (FT_REG_CMDB_WRITE >> 8) & #FF
                OUT  (SPI_DATA), A
                LD   A, FT_REG_CMDB_WRITE & #FF
                OUT  (SPI_DATA), A

                ; DMA source = CMD buffer в Core page #05.
                LD   A, LOW ZL_CMD_DMA_ADDR
                LD   BC, DMASADDRL
                OUT  (C), A
                LD   A, HIGH ZL_CMD_DMA_ADDR
                LD   BC, DMASADDRH
                OUT  (C), A
                LD   A, ZL_CMD_DMA_PAGE
                LD   BC, DMASADDRX
                OUT  (C), A

                ; Полные 512-byte chunks: DMALEN=255 words, DMANUM=chunks-1.
                LD   A, (ZL_CmdDmaWordsHi)
                OR   A
                JR   Z, .tail
                DEC  A
                LD   BC, DMANUM
                OUT  (C), A
                LD   A, #FF
                LD   BC, DMALEN
                OUT  (C), A
                LD   A, DMA_RAM_SPI
                LD   BC, DMACTR
                OUT  (C), A
.wait_full:     LD   BC, DMASTATUS
                IN   A, (C)
                AND  DMA_WNR
                JR   NZ, .wait_full

.tail:          LD   A, (ZL_CmdDmaWordsLo)
                OR   A
                JR   Z, .done
                DEC  A
                LD   BC, DMALEN
                OUT  (C), A
                XOR  A
                LD   BC, DMANUM
                OUT  (C), A
                LD   A, DMA_RAM_SPI
                LD   BC, DMACTR
                OUT  (C), A
.wait_tail:     LD   BC, DMASTATUS
                IN   A, (C)
                AND  DMA_WNR
                JR   NZ, .wait_tail

.done:          FT_OFF
                RET

ZL_CmdDmaWordsHi: DEFB 0
ZL_CmdDmaWordsLo: DEFB 0

; ----------------------------------------------------------------------------
; ZL_AimUpdate — детектирует mouse motion (с threshold для подавления Hyper-V
; Kempston jitter), а keyboard arrows меняют Frog_Angle напрямую.
;
; Архитектура (1:1 с VDC коллеги): Frog_Angle = primary state (8-bit BRAD wraps
; → 360° автоматом). Если мышь двинулась — set ZL_MouseMoved=1, иначе =0.
; Frog_Update вызывает ComputeFrogAngle ТОЛЬКО при ZL_MouseMoved=1 — иначе
; угол от клавиш сохраняется. Combine, не mode-toggle: клавиши применяются
; КАЖДЫЙ кадр (до atan2-проверки), мышь wins при движении.
;
; Threshold ZL_MOTION_THR = 1 px: отсекает только полный «zero motion», когда мышь
; физически не движется (защищает клавиатурный режим от ложных takeover при
; idle mouse). Sub-pixel Hyper-V jitter подавляется EMA-фильтром в ZL_SmoothMouse,
; не deadzone'ом — иначе медленный aim (1-2 px/frame) теряется.
; ----------------------------------------------------------------------------
ZL_SmoothX:     DEFW 512                              ; центр 1024×768
ZL_SmoothY:     DEFW 384
ZL_TmpTx:       DEFW 0                                ; scratch X для ZL_EmitTranslate
ZL_TmpTy:       DEFW 0                                ; scratch Y для ZL_EmitTranslate
ZL_TmpAngle:    DEFW 0                                ; scratch angle для ZL_EmitRotate
