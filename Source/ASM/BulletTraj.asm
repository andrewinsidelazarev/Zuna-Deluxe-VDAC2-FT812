; ============================================================================
; BulletTraj.asm -- resident bullet collision event reader.
;
; ZBT1 lives in physical page #13, appended to the current level Track V2 blob.
; Runtime still validates every candidate with the old bbox/manhattan test; the
; table only replaces the full Slots[] scan with a small per-frame event stream.
; ============================================================================

BULLET_TRAJ_DIR_OFF       EQU 16
BULLET_TRAJ_STREAM_BASE   EQU #8000
BULLET_TRAJ_VERSION       EQU 2
BULLET_TRAJ_EV_TRACK2     EQU #01
BULLET_TRAJ_EV_HIT        EQU #02
BULLET_TRAJ_EV_TUNNEL     EQU #04
BULLET_TRAJ_EV_TUNNEL_IN  EQU #08
BULLET_TRAJ_EV_TUNNEL_OUT EQU #10
BULLET_TRAJ_MASK_TRACK1   EQU #01
BULLET_TRAJ_MASK_TRACK2   EQU #02
BULLET_TRAJ_HIT_THR       EQU 35
BULLET_TRAJ_MANHATTAN_THR EQU 54
BULLET_TRAJ_TRACKF_TUNNEL EQU #01
BULLET_TRAJ_TRACKF_DRAW_ABOVE EQU #02
BULLET_TRAJ_NUM_COLORS    EQU 6

; ----------------------------------------------------------------------------
; Bullet_TrajInitForAngle -- initialise the ZBT1 stream for Frog_Angle.
; Called from Bullet_Spawn after velocity is computed.
; ----------------------------------------------------------------------------
Bullet_TrajInitForAngle:
                XOR  A
                LD   (Bullet_Frame), A
                LD   (Bullet_PrevFrame), A
                LD   (Bullet_EventCount), A
                LD   (Bullet_ExitFrame), A
                LD   (Bullet_NoHitMask), A
                LD   (Bullet_EventTrackState), A
                LD   A, (BulletTrajValid)
                OR   A
                RET  Z

                LD   A, BULLET_TRAJ_PAGE
                SetPage2_A
                LD   A, (#8000) : CP #5A : JR NZ, .bad   ; 'Z'
                LD   A, (#8001) : CP #42 : JR NZ, .bad   ; 'B'
                LD   A, (#8002) : CP #54 : JR NZ, .bad   ; 'T'
                LD   A, (#8003) : CP #31 : JR NZ, .bad   ; '1'
                LD   A, (#8004) : CP BULLET_TRAJ_VERSION : JR NZ, .bad

                LD   A, (Frog_Angle)
                LD   L, A
                LD   H, 0
                ADD  HL, HL
                LD   DE, BULLET_TRAJ_STREAM_BASE + BULLET_TRAJ_DIR_OFF
                ADD  HL, DE
                LD   E, (HL)
                INC  HL
                LD   D, (HL)
                LD   HL, BULLET_TRAJ_STREAM_BASE
                ADD  HL, DE
                LD   A, (HL)
                LD   (Bullet_ExitFrame), A
                INC  HL
                LD   A, (HL)
                LD   (Bullet_EventCount), A
                INC  HL
                LD   (Bullet_EventPtr), HL
                JP   SetCurrentTrackPage
.bad:          XOR  A
                LD   (BulletTrajValid), A
                JP   SetCurrentTrackPage

; ----------------------------------------------------------------------------
; Bullet_CheckCollisionEvents -- event stream collision path.
; Replaces Bullet_CheckCollisionAllChains full scan.
; ----------------------------------------------------------------------------
Bullet_CheckCollisionEvents:
                LD   A, (Bullet_Active)
                OR   A
                RET  Z
                LD   A, (BulletTrajValid)
                OR   A
                RET  Z

                XOR  A
                LD   (Bullet_EventTrackState), A
                CALL SetCurrentTrackPage
                LD   A, 255
                LD   (Bullet_TmpHit), A
                LD   (Bullet_TmpDistP), A
                XOR  A
                LD   (Bullet_TmpHitTrack), A

.loop:          LD   A, (Bullet_EventCount)
                OR   A
                JR   Z, .done

                LD   A, BULLET_TRAJ_PAGE
                SetPage2_A
                LD   HL, (Bullet_EventPtr)
                LD   A, (HL)
                LD   (Bullet_TmpEventFrame), A
                LD   B, A
                LD   A, (Bullet_Frame)
                CP   B
                JR   C, .done_from_table              ; next event belongs to a future frame

                INC  HL
                LD   A, (HL)
                LD   (Bullet_TmpEventFlags), A
                INC  HL
                LD   A, (HL)
                LD   (Bullet_TmpEventCell), A
                INC  HL
                LD   A, (HL)
                LD   (Bullet_TmpEventSub), A
                INC  HL
                LD   (Bullet_EventPtr), HL
                LD   HL, Bullet_EventCount
                DEC  (HL)

                CALL BulletTraj_RestoreEventTrackPage
                CALL BulletTraj_ProcessEvent
                JR   .loop

.done_from_table:
                CALL BulletTraj_RestoreEventTrackPage
.done:          LD   A, (Bullet_TmpHit)
                CP   255
                JR   Z, .no_hit

                LD   A, (Bullet_TmpHitTrack)
                CALL BulletTraj_SelectTrack
                JR   C, .no_hit

                LD   A, (Bullet_TmpHit)
                if RUNTIME_DIAGNOSTICS_ENABLED
                CALL LogBboxHit
                endif
                LD   A, SND_BALLCLICK2
                CALL GS_PlaySfx
                LD   A, (Bullet_TmpHit)
                LD   (Bullet_TmpHit), A
                CALL Bullet_HemisphereTarget
                if RUNTIME_DIAGNOSTICS_ENABLED
                CALL LogHemi
                endif

                LD   C, A
                LD   A, (Bullet_Color)
                LD   B, A
                LD   A, C
                CALL VDC_InsertAt
                OR   A
                CALL NZ, VDC_AwardGapBonus
                XOR  A
                LD   (Bullet_Active), A
                CALL BulletTraj_RestoreChain1
                RET

.no_hit:        CALL BulletTraj_RestoreChain1
                RET

; ----------------------------------------------------------------------------
; Event handling.
; ----------------------------------------------------------------------------
BulletTraj_ProcessEvent:
                LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_TUNNEL_IN
                JR   Z, .no_in
                CALL BulletTraj_EventMaskToB
                LD   A, (Bullet_NoHitMask)
                OR   B
                LD   (Bullet_NoHitMask), A
.no_in:         LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_TUNNEL_OUT
                JR   Z, .no_out
                CALL BulletTraj_EventMaskToB
                LD   A, B
                CPL
                LD   B, A
                LD   A, (Bullet_NoHitMask)
                AND  B
                LD   (Bullet_NoHitMask), A
.no_out:        LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_HIT
                RET  Z

                LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_TRACK2
                LD   (Bullet_TmpEventTrack), A

                LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_TUNNEL
                JR   NZ, .tunnel_skip

                LD   A, (Bullet_TmpEventTrack)
                CALL BulletTraj_SelectTrack
                RET  C
                JP   BulletTraj_ProcessHitEvent

.tunnel_skip:   LD   A, 1
                LD   (Bullet_TunnelSeen), A
                RET

BulletTraj_EventMaskToB:
                LD   A, (Bullet_TmpEventFlags)
                AND  BULLET_TRAJ_EV_TRACK2
                JR   Z, .track1
                LD   B, BULLET_TRAJ_MASK_TRACK2
                RET
.track1:        LD   B, BULLET_TRAJ_MASK_TRACK1
                RET

; ----------------------------------------------------------------------------
; Select active chain/track. In: A=0 for chain1, A=1 for chain2.
; Out: CF=1 if chain2 requested but absent. Slot2 restored to selected track.
; ----------------------------------------------------------------------------
BulletTraj_SelectTrack:
                LD   B, A
                OR   A
                JR   Z, .have
                LD   A, (VDC_HasSecondChain)
                OR   A
                JR   Z, .no_second
.have:          LD   A, (Bullet_EventTrackState)
                CP   B
                JR   Z, .same
                LD   A, B
                PUSH AF
                CALL VDC_SwapChains
                POP  AF
                LD   (Bullet_EventTrackState), A
                LD   B, A
.same:          LD   A, B
                OR   A
                JR   Z, .set_first
                CALL SetSecondTrackPage
                OR   A
                RET
.set_first:     CALL SetCurrentTrackPage
                OR   A
                RET
.no_second:     CALL SetCurrentTrackPage
                SCF
                RET

BulletTraj_RestoreEventTrackPage:
                LD   A, (Bullet_EventTrackState)
                OR   A
                JP   Z, SetCurrentTrackPage
                JP   SetSecondTrackPage

BulletTraj_RestoreChain1:
                LD   A, (Bullet_EventTrackState)
                OR   A
                JR   Z, .page
                CALL VDC_SwapChains
                XOR  A
                LD   (Bullet_EventTrackState), A
.page:          JP   SetCurrentTrackPage

; ----------------------------------------------------------------------------
; Hit event -> check base slot +/-2 around event cell.
; ----------------------------------------------------------------------------
BulletTraj_ProcessHitEvent:
                LD   A, (VDC_HSA)
                LD   B, A
                LD   A, (Bullet_TmpEventCell)
                LD   C, A
                LD   A, B
                SUB  C                                  ; base = HSA - cell
                LD   B, A
                LD   A, (Bullet_TmpEventSub)
                LD   C, A
                LD   A, (VDC_HSub)
                CP   C
                JR   C, .base_ok
                JR   Z, .base_ok
                INC  B                                  ; sub < HSub -> next slot
.base_ok:       LD   A, B
                LD   (Bullet_TmpCandidateBase), A

                CP   2
                JR   C, .skip_m2
                SUB  2
                CALL BulletTraj_CheckCandidateA
.skip_m2:       LD   A, (Bullet_TmpCandidateBase)
                OR   A
                JR   Z, .skip_m1
                DEC  A
                CALL BulletTraj_CheckCandidateA
.skip_m1:       LD   A, (Bullet_TmpCandidateBase)
                CALL BulletTraj_CheckCandidateA
                LD   A, (Bullet_TmpCandidateBase)
                INC  A
                CALL BulletTraj_CheckCandidateA
                LD   A, (Bullet_TmpCandidateBase)
                INC  A
                INC  A
                JP   BulletTraj_CheckCandidateA

; ----------------------------------------------------------------------------
; In: A=candidate slot. Updates Bullet_TmpHit/Bullet_TmpDistP on better hit.
; Also updates gap min-distance for gap candidates, replacing the old full gap scan.
; ----------------------------------------------------------------------------
BulletTraj_CheckCandidateA:
                LD   (Bullet_TmpScan), A
                LD   C, A
                LD   A, (VDC_SlotsLen)
                CP   C
                RET  Z
                RET  C

                LD   A, C
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pExplodeFrame)
                ADD  HL, DE
                LD   A, (HL)
                OR   A
                RET  NZ

                LD   A, (Bullet_TmpScan)
                LD   H, 0 : LD L, A
                LD   DE, (VDC_pSlots)
                ADD  HL, DE
                LD   A, (HL)
                CP   BULLET_TRAJ_NUM_COLORS
                JR   NC, .gap_candidate

                LD   A, (Bullet_TmpScan)
                CALL VDC_SlotPos
                RET  C
                LD   A, (VDC_LastTrackFlags)
                AND  BULLET_TRAJ_TRACKF_TUNNEL
                JR   Z, .not_tunnel_ball
                LD   A, 1
                LD   (Bullet_TunnelSeen), A
                RET

.not_tunnel_ball:
                ; A lower tunnel/no-hit interval must not block balls explicitly
                ; flagged to draw above the top layer (bridge-over-tunnel case).
                LD   A, (VDC_LastTrackFlags)
                AND  BULLET_TRAJ_TRACKF_DRAW_ABOVE
                JR   NZ, .visible_ball
                PUSH BC
                CALL BulletTraj_EventMaskToB
                LD   A, (Bullet_NoHitMask)
                AND  B
                POP  BC
                JR   Z, .visible_ball
                LD   A, 1
                LD   (Bullet_TunnelSeen), A
                RET

.visible_ball:  LD   HL, (Bullet_X)
                AND  A
                SBC  HL, BC
                CALL Bullet_AbsHL
                LD   A, H
                OR   A
                RET  NZ
                LD   A, L
                CP   BULLET_TRAJ_HIT_THR
                RET  NC

                LD   HL, (Bullet_Y)
                AND  A
                SBC  HL, DE
                CALL Bullet_AbsHL
                LD   A, H
                OR   A
                RET  NZ
                LD   A, L
                CP   BULLET_TRAJ_HIT_THR
                RET  NC

                CALL Bullet_ManhattanToBC_DE
                CP   BULLET_TRAJ_MANHATTAN_THR
                RET  NC
                LD   HL, Bullet_TmpDistP
                CP   (HL)
                RET  NC
                LD   (HL), A
                LD   A, (Bullet_TmpScan)
                LD   (Bullet_TmpHit), A
                LD   A, (Bullet_TmpEventTrack)
                LD   (Bullet_TmpHitTrack), A
                RET

.gap_candidate: LD   A, (Bullet_TmpScan)
                CALL VDC_SlotPosAllowGap
                RET  C
                CALL Bullet_ManhattanToBC_DE
                LD   HL, VDC_BulletGapMinDist
                CP   (HL)
                RET  NC
                LD   (HL), A
                RET
