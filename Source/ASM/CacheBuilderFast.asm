                ifndef _ZUMA_CACHE_BUILDER_FAST_
                define _ZUMA_CACHE_BUILDER_FAST_

                ASSERT VDC_CELL_SIZE * TRACK_V2_REC == #0100
                ASSERT TRACK_V2_PAGE_SAMPLES * TRACK_V2_REC == #4000

; ============================================================================
; Быстрый сборщик кеша стабильной цепочки L19.
; В обычном заполненном кадре все слоты живые, offsets равны нулю, а последний
; слот точно лежит на неотрицательном t. Тогда соседний шар отстоит на 32
; сэмпла, то есть адрес восьмибайтной записи Track V4 уменьшается на #0100.
; Любое переходное состояние отклоняется до изменения кеша и идёт в общий путь.
; Выход: CF=1 — кеш полностью построен; CF=0 — требуется общий сборщик.
; ============================================================================
ZL_BuildActiveChainCacheFastL19Maybe:
                LD   A, (ZL_L19SplitBuildMode)
                DEC  A
                JP   NZ, .reject
                LD   A, (VDC_GameState)
                OR   A
                RET  NZ
                LD   A, (VDC_SecondActive)
                OR   A
                JR   Z, .check_explode1
                LD   A, (VDC2_ChainLocal + (VDC_ExplodeActive - VDC_ChainLocalStart))
                JR   .explode_ready
.check_explode1:
                LD   A, (VDC_ExplodeActive)
.explode_ready: OR   A
                RET  NZ
                LD   A, (CurrentLevel)
                CP   18
                JP   NZ, .reject
                LD   A, (VDC_HasSecondChain)
                OR   A
                RET  Z
                CALL ZL_GetTopMaskForCurrentLevel
                LD   A, (HL)
                OR   A
                RET  Z

                LD   A, (VDC_HSA)
                INC  A
                LD   HL, VDC_SlotsLen
                CP   (HL)
                JP   NZ, .reject                       ; исключить отрицательный хвост t

                LD   A, (VDC_SlotsLen)
                CP   ZL_L19_SPLIT_CAPACITY + 1
                RET  NC
                LD   B, A
                LD   HL, (VDC_pSlots)
                LD   DE, (VDC_pOffsets)
.check_loop:    LD   A, (HL)
                CP   VDC_NUM_COLORS
                RET  NC                                ; GAP и marker требуют общего пути
                INC  HL
                LD   A, (DE)
                INC  DE
                OR   A
                RET  NZ                                ; insert/cascade offset меняет шаг t
                DJNZ .check_loop

                LD   A, (VDC_HSA)
                LD   H, 0
                LD   L, A
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL                            ; HSA * 32
                LD   A, (VDC_HSub)
                LD   E, A
                LD   D, 0
                ADD  HL, DE                            ; t первого шара
                PUSH HL
                LD   DE, (VDC_ActiveTrackSamples)
                AND  A
                SBC  HL, DE
                POP  HL
                RET  NC                                ; редкий clamp оставляет общий путь

                LD   (VDC_WinTmpMax), HL
                LD   A, 1
                LD   (VDC_WinTmpFound), A
                LD   A, (VDC_SecondActive)
                OR   A
                JR   NZ, .store_head2
                LD   (VDC_WinHeadS1), HL
                JR   .head_stored
.store_head2:   LD   (VDC_WinHeadS2), HL
.head_stored:
                LD   A, #C0
                LD   (ZL_TangentQuantMask), A
                LD   A, #20
                LD   (ZL_TangentQuantAdd), A

                LD   A, H
                RRCA
                RRCA
                RRCA
                AND  #03
                LD   (VDC_RenderTrackPageIdx), A
                LD   E, A
                LD   D, 0
                PUSH HL
                LD   HL, (VDC_pTrackPages)
                ADD  HL, DE
                LD   A, (HL)
                SetPage2_A
                POP  HL

                LD   A, H
                AND  #07
                LD   H, A
                ADD  HL, HL
                ADD  HL, HL
                ADD  HL, HL
                SET  7, H                              ; IY = запись Track V4 первого шара
                PUSH HL
                POP  IY
                LD   IX, (VDC_pSlots)
                LD   HL, (ZL_CacheBasePtr)
                LD   DE, ZL_L19_SPLIT_LANE_BYTES
                ADD  HL, DE
                EX   DE, HL                            ; DE = начало верхней полосы
                LD   HL, (ZL_CacheBasePtr)             ; HL = начало нижней полосы
                EXX
                LD   BC, 0                             ; B' = under count, C' = over count
                EXX
                LD   A, (VDC_SlotsLen)
                LD   B, A
                JR   .process

.next_record:   LD   A, IYH
                DEC  A
                LD   IYH, A                            ; минус 32 сэмпла по восемь байт
                CP   #7F
                JP   NZ, .process
                LD   IYH, #BF                          ; #8000 предыдущей страницы -> #BF00
                LD   A, (VDC_RenderTrackPageIdx)
                DEC  A
                LD   (VDC_RenderTrackPageIdx), A
                PUSH DE                                ; сохранить указатель верхней полосы
                LD   E, A
                LD   D, 0
                PUSH HL
                LD   HL, (VDC_pTrackPages)
                ADD  HL, DE
                LD   A, (HL)
                SetPage2_A
                POP  HL
                POP  DE

.process:       LD   A, (IX+0)
                INC  IX
                LD   C, A                              ; цвет 0..5 доказан предварительным проходом
                BIT  0, (IY+7)
                JR   Z, .record_done                   ; невидимая запись не входит ни в одну полосу

                LD   A, (IY+5)
                AND  ZL_TRACKF_TUNNEL | ZL_TRACKF_DRAW_ABOVE
                CP   ZL_TRACKF_DRAW_ABOVE
                JR   Z, .select_over
                EXX
                INC  B
                EXX
                JR   .target_ready
.select_over:   SET  7, C                              ; временная метка для обратного EX DE,HL
                EX   DE, HL
                EXX
                INC  C
                EXX
.target_ready:

                LD   A, (IY+4)
                ADD  A, #20
                AND  #C0
                LD   (HL), A                           ; +0 округлённая касательная L19
                INC  HL
                LD   A, C
                AND  #07
                ADD  A, A
                ADD  A, C
                AND  #7F
                ADD  A, A
                ADD  A, A
                                                        ; цвет * 12, bit 7 в C не участвует
                ADD  A, (IY+6)
                LD   (HL), A                           ; +1 ячейка atlas
                INC  HL
                LD   A, (IY+0)
                LD   (HL), A                           ; +2..+5 готовый VERTEX2F
                INC  HL
                LD   A, (IY+1)
                LD   (HL), A
                INC  HL
                LD   A, (IY+2)
                LD   (HL), A
                INC  HL
                LD   A, (IY+3)
                LD   (HL), A
                INC  HL
                BIT  7, C
                JR   Z, .record_done
                EX   DE, HL                            ; вернуть роли указателей после верхней записи

.record_done:  DJNZ .next_record
                EXX
                LD   A, (VDC_SecondActive)
                OR   A
                JR   NZ, .store_meta2
                LD   A, 1
                LD   (ZL_L19CacheSplit1), A
                LD   A, B
                LD   (ZL_L19CacheUnder1), A
                LD   A, C
                LD   (ZL_L19CacheOver1), A
                JR   .meta_stored
.store_meta2:   LD   A, 1
                LD   (ZL_L19CacheSplit2), A
                LD   A, B
                LD   (ZL_L19CacheUnder2), A
                LD   A, C
                LD   (ZL_L19CacheOver2), A
.meta_stored:   EXX
                SCF
                RET

.reject:       OR   A                                 ; CF=0 при любом отказе
                RET

                endif
