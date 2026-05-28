; Level-select thumbnail marker loader/draw helpers.
; Kept in always-visible slot 0 because main1_play is at the 16K page limit.

LoadLevelSelectPreviewMarkers:
                DI
                SetPage3 UI_OVL_PAGE                   ; keep the level-select (UI) page mapped: SafeInflatePage2
                                                       ; streams via PAGE2 and leaves PAGE3 untouched, so the old
                                                       ; `SetPage3 #04` (from the legacy FT.Coprocessor.Inflate path
                                                       ; that DID use slot 3) is vestigial. Mapping the gameplay page
                                                       ; here is unnecessary and inconsistent post-split.
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
                SetPage3 #41                            ; = UI_OVL_PAGE: restore level-select overlay (called from LevelSelect)
                EI
                RET

LevelSelectDrawPreviewMarkers:
                ; Reuses gameplay frog/DL emit code + Frog_SinTable (gameplay overlay #04).
                ; The caller (LevelSelectBuildFrame) maps #04 around the WHOLE
                ; DrawLevelSelectPreview->markers->title chain, so NO SetPage3 here —
                ; doing it here would restore #41 mid-chain and crash DrawLevelSelectTitle.
                ; LevelSelectPreviewFrogAngle is hoisted resident.
                CALL LevelSelectUpdatePreviewMarkerXY
                CALL LevelSelectUpdatePreviewFrogAngle
                CALL Core.ZL_EmitLoadId
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle LS_PREVIEW_MARKER_HANDLE
                FT_BitmapSource LS_PREVIEW_KZ_RAMG
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_KZ_W * 2, LS_PREVIEW_KZ_H
                FT_BitmapSize FT_BILINEAR, FT_BORDER, FT_BORDER, LS_PREVIEW_KZ_W, LS_PREVIEW_KZ_H
                FT_Begin FT_BITMAPS
                XOR  A
                CALL FT.Coprocessor.Cell
                LD   BC, (LevelSelectPreviewKzX16)
                LD   DE, (LevelSelectPreviewKzY16)
                CALL FT.Coprocessor.Vertex2f
                CALL Core.ZL_EmitLoadId
                LD   HL, LS_PREVIEW_FROG_HALF
                LD   DE, LS_PREVIEW_FROG_HALF
                CALL Core.ZL_EmitTranslate
                LD   A, (Core.LevelSelectPreviewFrogAngle)
                ADD  A, 192
                CALL Core.Frog_EmitRotateRaw
                LD   HL, -LS_PREVIEW_FROG_HALF & #FFFF
                LD   DE, -LS_PREVIEW_FROG_HALF & #FFFF
                CALL Core.ZL_EmitTranslate
                CALL Core.ZL_EmitSetMatrix
                FT_BitmapHandle LS_PREVIEW_MARKER_HANDLE
                FT_BitmapSource LS_PREVIEW_FROG_RAMG
                FT_BitmapLayout FT_ARGB4, LS_PREVIEW_FROG_W * 2, LS_PREVIEW_FROG_H
                FT_BitmapSize FT_BILINEAR, FT_BORDER, FT_BORDER, LS_PREVIEW_FROG_W, LS_PREVIEW_FROG_H
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
                LD   DE, LS_PREVIEW_FROG_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewFrogX16), HL
                CALL Core.GetCurrentFrogY
                CALL LevelSelectPreviewCalcY
                LD   (LevelSelectPreviewFrogCenterY), HL
                LD   DE, LS_PREVIEW_FROG_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewFrogY16), HL
                CALL Core.GetCurrentKzX
                CALL LevelSelectPreviewCalcX
                LD   DE, LS_PREVIEW_KZ_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewKzX16), HL
                CALL Core.GetCurrentKzY
                CALL LevelSelectPreviewCalcY
                LD   DE, LS_PREVIEW_KZ_HALF
                AND  A
                SBC  HL, DE
                CALL LevelSelectPreviewPxTo16
                LD   (LevelSelectPreviewKzY16), HL
                RET

LevelSelectPreviewCalcX:
                LD   D, H
                LD   E, L                              ; coord
                ADD  HL, HL                            ; *2
                ADD  HL, HL                            ; *4
                ADD  HL, HL                            ; *8
                AND  A
                SBC  HL, DE                            ; *7
                LD   A, 16
                CALL Core.VDC_DivHLbyA
                LD   DE, LS_PREVIEW_BG_X
                ADD  HL, DE
                RET

LevelSelectPreviewCalcY:
                LD   D, H
                LD   E, L                              ; coord
                ADD  HL, HL                            ; *2
                ADD  HL, HL                            ; *4
                ADD  HL, HL                            ; *8
                ADD  HL, HL                            ; *16
                ADD  HL, DE                            ; *17
                LD   A, 48
                CALL Core.VDC_DivHLbyA
                LD   DE, LS_PREVIEW_BG_Y
                ADD  HL, DE
                RET

LevelSelectPreviewPxTo16:
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                RET

LevelSelectPreviewFrogCenterX: DEFW 0
LevelSelectPreviewFrogCenterY: DEFW 0
LevelSelectPreviewFrogX16:     DEFW 0
LevelSelectPreviewFrogY16:     DEFW 0
LevelSelectPreviewKzX16:       DEFW 0
LevelSelectPreviewKzY16:       DEFW 0
