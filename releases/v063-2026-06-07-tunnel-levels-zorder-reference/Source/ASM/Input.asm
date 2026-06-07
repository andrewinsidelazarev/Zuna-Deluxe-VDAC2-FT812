; ============================================================================
; Input.asm — РЕЗИДЕНТНЫЙ глобальный модуль ВСЕГО управления. Здесь читаются ВСЕ
; источники ввода, поэтому любая сцена-overlay (геймплей #04, UI #41) может
; опрашивать ввод без переключения страниц.
;
; Источники (всё в одном месте — клавиатура + джойстик + мышь):
;   * Расширенная PC-клавиатура ZX Evolution через Mr.Gluk Z-контроллер:
;       OUT #EFF7,#80 = enable; OUT #DFF7,рег = выбор регистра; #BFF7 = данные.
;       Регистр #F0 = PS/2 FIFO scancode'ов (set-2). Тот же чип, что и RTC
;       (VDC.ReadRTCSeconds), который ГАСИТ #EFF7 после чтения — поэтому
;       Input_Scan каждый кадр включает его заново. См. заметку памяти
;       reference_zuma_vdac2_zxevo_ps2_keyboard.
;   * Kempston-джойстик (TSLib Input.Kempston). KJoystick=1 направляет PC-стрелки
;     сюда же.
;   * Мышь (TSLib Input.Mouse) — позиция + ЛКМ.
;
; Схема управления: лягушка = вращение Влево/Вправо (геймплей). Глобальные UI:
;   Up/Down — навигация меню/выбор сложности; Влево/Вправо — активная кнопка в
;   диалогах; ESC — меню/назад; Fire = Space | Enter | Kempston-Fire | ЛКМ.
; Клавиатурные эквиваленты направлений (классическая ZX-раскладка):
;   Up = ↑ | Q;  Down = ↓ | A;  Влево = ← | O;  Вправо = → | P.
;
; Применение: Input_Init один раз на старте; Input_Scan один раз за кадр (в любой
; сцене — он обновляет и клавиатуру, и мышь); затем опросы Input_Up/Down/Left/
; Right/Fire/Esc (каждый возвращает NZ = активно). Edge-хелперы — для навигации.
; ============================================================================

; Скан-коды PS/2 set-2 (make-коды; стрелки идут с префиксом E0, но их коды
; уникальны, поэтому при сопоставлении префикс E0 игнорируется).
INP_SC_ESC      EQU #76
INP_SC_UP       EQU #75
INP_SC_DOWN     EQU #72
INP_SC_LEFT     EQU #6B
INP_SC_RIGHT    EQU #74
INP_SC_ENTER    EQU #5A
INP_SC_SPACE    EQU #29
INP_SC_Q        EQU #15
INP_SC_A        EQU #1C
INP_SC_O        EQU #44          ; O = Влево (классическая ZX-раскладка)
INP_SC_P        EQU #4D          ; P = Вправо

; Флаги «клавиша нажата» (1 = нажата, 0 = отпущена), обновляются Input_Scan.
Input_KEsc:     DEFB 0
Input_KUp:      DEFB 0
Input_KDown:    DEFB 0
Input_KLeft:    DEFB 0
Input_KRight:   DEFB 0
Input_KEnter:   DEFB 0
Input_KSpace:   DEFB 0
Input_KQ:       DEFB 0
Input_KA:       DEFB 0
Input_KO:       DEFB 0
Input_KP:       DEFB 0
Input_PS2Brk:   DEFB 0          ; ожидается префикс отпускания (#F0)
Input_DrainCnt: DEFB 0          ; ограничитель дренажа FIFO (макс байт за скан)

; ----------------------------------------------------------------------------
; Input_Init — включить Mr.Gluk и взвести PS/2-клавиатуру. Вызвать раз на старте.
; ----------------------------------------------------------------------------
Input_Init:
                LD   BC, #EFF7 : LD A, #80 : OUT (C), A    ; Mr.Gluk enable
                LD   BC, #DFF7 : LD A, #0C : OUT (C), A
                LD   BC, #BFF7 : LD A, #01 : OUT (C), A    ; сброс буфера PS/2
                LD   BC, #DFF7 : LD A, #F0 : OUT (C), A
                LD   BC, #BFF7 : LD A, #02 : OUT (C), A    ; PS/2 ON
                RET

; ----------------------------------------------------------------------------
; Input_Scan — опросить ВСЕ источники за кадр: дренаж PS/2 FIFO (флаги клавиш) +
; обновление состояния мыши. Вызывать раз за кадр в любой сцене.
; Сначала заново включает Mr.Gluk (чтение RTC его гасит). Портит AF, BC, DE, HL.
; ----------------------------------------------------------------------------
Input_Scan:
                CALL Input.Mouse.UpdateMouseState          ; мышь — единая точка опроса здесь
                LD   BC, #EFF7 : LD A, #80 : OUT (C), A    ; заново enable (RTC мог погасить)
                LD   BC, #DFF7 : LD A, #F0 : OUT (C), A    ; выбрать регистр PS/2 FIFO
                LD   A, 24 : LD (Input_DrainCnt), A        ; ограничить дренаж (без зависания на мусоре)
                LD   BC, #BFF7                             ; BC = порт данных (держим на весь цикл)
.drain:         IN   A, (C)
                OR   A : RET Z                             ; 0 = FIFO пуст -> готово
                CP   #FF : JR Z, .next                     ; маркер переполнения -> пропустить
                CP   #E0 : JR Z, .next                     ; префикс extended -> игнор (коды уникальны)
                CP   #F0 : JR Z, .set_brk                  ; префикс break -> следующий код = отпускание
                CALL Input_SetKey
.next:          LD   A, (Input_DrainCnt) : DEC A : LD (Input_DrainCnt), A : RET Z
                JR   .drain
.set_brk:       LD   A, 1 : LD (Input_PS2Brk), A
                JR   .next

; A = scancode -> выставить/сбросить его флаг (1 если make, 0 если break),
; затем съесть префикс break. Сохраняет BC (порт дренажа #BFF7). Портит AF, DE, HL.
Input_SetKey:
                LD   E, A                                  ; E = scancode
                LD   A, (Input_PS2Brk)
                XOR  1                                     ; A = 1 (make) или 0 (break)
                LD   D, A                                  ; D = значение для записи
                XOR  A : LD (Input_PS2Brk), A              ; съесть префикс break
                LD   A, E
                LD   HL, Input_KEsc   : CP INP_SC_ESC   : JR Z, .sk
                LD   HL, Input_KUp    : CP INP_SC_UP    : JR Z, .sk
                LD   HL, Input_KDown  : CP INP_SC_DOWN  : JR Z, .sk
                LD   HL, Input_KLeft  : CP INP_SC_LEFT  : JR Z, .sk
                LD   HL, Input_KRight : CP INP_SC_RIGHT : JR Z, .sk
                LD   HL, Input_KEnter : CP INP_SC_ENTER : JR Z, .sk
                LD   HL, Input_KSpace : CP INP_SC_SPACE : JR Z, .sk
                LD   HL, Input_KQ     : CP INP_SC_Q     : JR Z, .sk
                LD   HL, Input_KA     : CP INP_SC_A     : JR Z, .sk
                LD   HL, Input_KO     : CP INP_SC_O     : JR Z, .sk
                LD   HL, Input_KP     : CP INP_SC_P     : JR Z, .sk
                RET                                        ; неотслеживаемый код
.sk:            LD   (HL), D
                RET

; ----------------------------------------------------------------------------
; Опросы направлений/огня — возвращают NZ = активно (Z = нет). Объединяют все
; источники по схеме управления. Портят AF (Kempston/мышь также HL).
; ----------------------------------------------------------------------------
Input_Esc:      LD   A, (Input_KEsc) : OR A : RET           ; только клавиатура (у Kempston ESC нет)

Input_Up:       LD   A, (Input_KUp) : OR A : RET NZ         ; ↑ (PS/2)
                LD   A, (Input_KQ)  : OR A : RET NZ         ; Q
                LD   A, Input.VK_KEMPSTON_UP
                JP   Input.Kempston.KeyState               ; Kempston-Up (NZ = нажато)

Input_Down:     LD   A, (Input_KDown) : OR A : RET NZ       ; ↓ (PS/2)
                LD   A, (Input_KA)    : OR A : RET NZ       ; A
                LD   A, Input.VK_KEMPSTON_DOWN
                JP   Input.Kempston.KeyState

Input_Left:     LD   A, (Input_KLeft) : OR A : RET NZ       ; ← (PS/2)
                LD   A, (Input_KO)    : OR A : RET NZ       ; O
                LD   A, Input.VK_KEMPSTON_LEFT
                JP   Input.Kempston.KeyState

Input_Right:    LD   A, (Input_KRight) : OR A : RET NZ      ; → (PS/2)
                LD   A, (Input_KP)     : OR A : RET NZ      ; P
                LD   A, Input.VK_KEMPSTON_RIGHT
                JP   Input.Kempston.KeyState

; Input_FireKey — огонь БЕЗ ЛКМ: Space | Enter | Kempston-Fire. Для сцен, где ЛКМ
; обрабатывается отдельно (лягушка-aim, hit-test диалогов) — иначе ЛКМ дала бы
; двойной огонь. NZ = нажато.
Input_FireKey:  LD   A, (Input_KSpace) : OR A : RET NZ      ; Space
                LD   A, (Input_KEnter) : OR A : RET NZ      ; Enter
                LD   A, Input.VK_KEMPSTON_B
                JP   Input.Kempston.KeyState               ; Kempston-Fire (NZ = нажато)

; Input_Fire — полный огонь: Input_FireKey + ЛКМ. Для сцен без отдельного
; hit-test'а (напр. выход из More Games — любой ввод = огонь). NZ = нажато.
Input_Fire:     CALL Input_FireKey : RET NZ                 ; Space|Enter|Kempston
                LD   A, Input.Mouse.SVK_LBUTTON
                JP   Input.Mouse.KeyState                  ; ЛКМ (NZ = нажато)

; ----------------------------------------------------------------------------
; Input_EdgeZ — детектор фронта нажатия (для навигации меню/диалогов: одно
; действие на одно нажатие, без автоповтора при удержании).
; Вход: флаг Z = состояние клавиши СЕЙЧАС (Z = отпущена, NZ = нажата),
;       HL = адрес байта «было нажато в прошлом кадре» (0/1).
; Выход: NZ = фронт (0->1, только что нажали), Z = фронта нет. Обновляет (HL).
; Портит A. Вызывать СРАЗУ после Input_Up/Down/Left/Right/FireKey/Esc —
; промежуточный «LD HL, addr» флаги не трогает, поэтому Z доходит сюда целым.
; ----------------------------------------------------------------------------
Input_EdgeZ:    JR   Z, .released
                LD   A, (HL)                               ; было нажато?
                LD   (HL), 1                               ; запомнить «нажато»
                XOR  1                                     ; было 0 -> A=1 (фронт, NZ); было 1 -> A=0 (Z)
                RET
.released:      LD   (HL), 0                               ; отпущено -> сброс
                XOR  A                                     ; Z = фронта нет
                RET

; ----------------------------------------------------------------------------
; Доступ к мыши (единая точка; позиция обновляется в Input_Scan).
;   Input_MouseX / Input_MouseY -> HL = координата.
;   Input_MouseLMB -> NZ = ЛКМ нажата.
; ----------------------------------------------------------------------------
Input_MouseX:   LD   HL, (Input.Mouse.PositionX) : RET
Input_MouseY:   LD   HL, (Input.Mouse.PositionY) : RET
Input_MouseLMB: LD   A, Input.Mouse.SVK_LBUTTON
                JP   Input.Mouse.KeyState
