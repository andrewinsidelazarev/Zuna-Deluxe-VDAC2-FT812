; Helpers загрузки/рисования thumbnail marker для level-select.
; Хранятся в always-visible slot 0, потому что main1_play близок к лимиту 16K.

LoadLevelSelectPreviewMarkers:
                DI
                SetPage3 UI_OVL_PAGE                   ; держать level-select UI page mapped:
                                                       ; SafeInflatePage2 стримит через PAGE2 и не трогает PAGE3.
                                                       ; Мапить gameplay page здесь после split не нужно.
                LD   HL, 0
                EXX
                LD   B, 1
                EXX
                LD   HL, 0
                LD   A, LS_PREVIEW_FROG_PAGE
                EX   AF, AF'
                LD   BC, LS_PREVIEW_FROG_Z_SIZE
                LD   A, (LS_PREVIEW_FROG_RAMG >> 16) & #FF
                LD   DE, LS_PREVIEW_FROG_RAMG & #FFFF
                CALL SafeInflatePage2
                LD   HL, 0
                EXX
                LD   B, 1
                EXX
                LD   HL, 0
                LD   A, LS_PREVIEW_KZ_PAGE
                EX   AF, AF'
                LD   BC, LS_PREVIEW_KZ_Z_SIZE
                LD   A, (LS_PREVIEW_KZ_RAMG >> 16) & #FF
                LD   DE, LS_PREVIEW_KZ_RAMG & #FFFF
                CALL SafeInflatePage2
                SetPage3 #41                            ; = UI_OVL_PAGE: restore level-select overlay
                EI
                RET

LevelSelectDrawPreviewMarkers:
                ; Переиспользует gameplay frog/DL emit code + Frog_SinTable
                ; из gameplay overlay #04. Caller LevelSelectBuildFrame мапит #04
                ; вокруг всей цепочки DrawLevelSelectPreview→markers→title, поэтому
                ; SetPage3 здесь запрещён: он вернёт #41 посреди цепочки и сломает
                ; DrawLevelSelectTitle. LevelSelectPreviewFrogAngle resident.
                CALL LevelSelectUpdatePreviewMarkerXY
                CALL LevelSelectUpdatePreviewFrogAngle
                ; 1024×768: kz-маркер ×1.6 (#04 замаплен вокруг превью-цепочки)
                CALL Core.Resident_EmitScale16
                FT_BitmapHandle LS_PREVIEW_MARKER_HANDLE
                FT_BitmapSource LS_PREVIEW_KZ_RAMG
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_KZ_W * 2, LS_PREVIEW_KZ_H
                FT_BitmapSize FT_BILINEAR, FT_BORDER, FT_BORDER, LS_PREVIEW_KZ_W * 8 / 5, LS_PREVIEW_KZ_H * 8 / 5
                FT_Begin FT_BITMAPS
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (LevelSelectPreviewKzX16)
                LD   DE, (LevelSelectPreviewKzY16)
                CALL FT.Coprocessor.Vertex2f
                ; 1024×768: rotate+scale(58→92) ЗАПЕЧЁННОЙ матрицей из LUT в #41
                ; (level-select работает при slot3=#41 — вызов корректен; экономит slot0).
                LD   A, (Core.LevelSelectPreviewFrogAngle)
                CALL Core.LevelSelectEmitFrogMarkerMatrix   ; +192 вшит в LUT — сырой угол!
                FT_BitmapHandle LS_PREVIEW_MARKER_HANDLE
                FT_BitmapSource LS_PREVIEW_FROG_RAMG
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_FROG_W * 2, LS_PREVIEW_FROG_H
                FT_BitmapSize FT_BILINEAR, FT_BORDER, FT_BORDER, LS_PREVIEW_FROG_W * 8 / 5, LS_PREVIEW_FROG_H * 8 / 5
                FT_Begin FT_BITMAPS
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (LevelSelectPreviewFrogX16)
                LD   DE, (LevelSelectPreviewFrogY16)
                CALL FT.Coprocessor.Vertex2f
                CALL Core.ZL_EmitLoadId
                JP   Core.ZL_EmitSetMatrix

LevelSelectUpdatePreviewFrogAngle:
                LD   HL, (Input.Mouse.PositionX)
                LD   (Core.ZL_SmoothX), HL
                LD   HL, (Input.Mouse.PositionY)
                LD   (Core.ZL_SmoothY), HL
                LD   HL, (LevelSelectPreviewFrogCenterX)
                LD   (Core.Frog_PosStartX), HL
                LD   HL, (LevelSelectPreviewFrogCenterY)
                LD   (Core.Frog_PosStartY), HL
                CALL Core.Frog_ComputeAngle
                LD   A, (Core.Frog_Angle)
                LD   (Core.LevelSelectPreviewFrogAngle), A
                RET

LevelSelectUpdatePreviewMarkerXY:
                CALL Core.GetCurrentFrogX
                CALL LevelSelectPreviewCalcX
                LD   (LevelSelectPreviewFrogCenterX), HL
                LD   DE, LS_PREVIEW_FROG_DRAW_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewFrogX16), HL
                CALL Core.GetCurrentFrogY
                CALL LevelSelectPreviewCalcY
                LD   (LevelSelectPreviewFrogCenterY), HL
                LD   DE, LS_PREVIEW_FROG_DRAW_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewFrogY16), HL
                CALL Core.GetCurrentKzX
                CALL LevelSelectPreviewCalcX
                LD   DE, LS_PREVIEW_KZ_DRAW_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewKzX16), HL
                CALL Core.GetCurrentKzY
                CALL LevelSelectPreviewCalcY
                LD   DE, LS_PREVIEW_KZ_DRAW_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewKzY16), HL
                RET

LevelSelectPreviewCalcX:
                ; коэфф. 11/23 ИНВАРИАНТЕН: вход (таблица) и выход (экран) оба ×1.6
                CALL LevelSelectPreviewScale
                LD   DE, LS_PREVIEW_BG_SX              ; экранная позиция превью (×1.6)
                ADD  HL, DE
                RET

LevelSelectPreviewCalcY:
                LD   DE, 56                            ; center-crop Y offset для 1024-входа (35×1.6)
                AND  A
                SBC  HL, DE
                JR   NC, .y_nonneg
                LD   HL, 0
.y_nonneg:      CALL LevelSelectPreviewScale
                LD   DE, LS_PREVIEW_BG_SY              ; экранная позиция превью (×1.6)
                ADD  HL, DE
                RET

LevelSelectPreviewScale:
                LD   D, H
                LD   E, L                              ; координата
                ADD  HL, HL                            ; *2
                ADD  HL, HL                            ; *4
                ADD  HL, HL                            ; *8
                ADD  HL, DE                            ; *9
                ADD  HL, DE                            ; *10
                ADD  HL, DE                            ; *11
                LD   A, 23                             ; ~= 306/640 and 196/410
                JP   Core.VDC_DivHLbyA

LevelSelectPreviewPxTo16:
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                RET

; Временные значения полностью записываются UpdatePreviewMarkerXY до чтения.
; Держим их в свободной постоянно отображённой ОЗУ сразу после двух кешей шаров,
; а не в переполненном блоке кода Slot0. Диагностический GAMELOG начинается после них.
LevelSelectPreviewFrogCenterX EQU #4B80
LevelSelectPreviewFrogCenterY EQU #4B82
LevelSelectPreviewFrogX16     EQU #4B84
LevelSelectPreviewFrogY16     EQU #4B86
LevelSelectPreviewKzX16       EQU #4B88
LevelSelectPreviewKzY16       EQU #4B8A
