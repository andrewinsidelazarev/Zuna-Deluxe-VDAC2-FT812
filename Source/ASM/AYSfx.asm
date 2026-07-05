; Оверлейный runtime AY SFX.
; Страница данных содержит таблицу и покадровые полные состояния регистров AY.
; Должен подключаться по одному адресу во всех сценовых оверлеях, которые могут
; вызывать GS_PlaySfx.

        include "ay_sfx_meta.inc"

AY_Start:

AY_REG_PORT        EQU #FFFD
AY_DATA_PORT       EQU #BFFD
AY_MIXER_SILENT    EQU #3F

AY_Init:
        XOR A
        LD (AY_Active),A
        LD (AY_Delay),A
        LD (AY_Page),A
        CALL AY_MuteAll
        RET

AY_PlaySfxFromRequest:
        LD A,(Core.GS_SfxRequestId)
        CP Core.SND_SILENCE
        JP Z,AY_Stop
        CP AY_SOUND_COUNT
        RET NC
        LD (AY_RequestId),A
        LD A,AY_TABLE_PAGE
        CALL AY_MapPage2A

        LD A,(AY_RequestId)
        LD L,A
        LD H,0
        ADD HL,HL
        ADD HL,HL
        LD DE,AY_TABLE_ADDR
        ADD HL,DE

        LD E,(HL)
        INC HL
        LD D,(HL)
        INC HL
        LD A,(HL)
        INC HL
        LD (AY_Page),A
        LD A,D
        OR E
        JR Z,.restore_ret
        LD (AY_Ptr),DE
        XOR A
        LD (AY_Delay),A
        INC A
        LD (AY_Active),A
        CALL AY_RestorePage2
        JP AY_Update
.restore_ret:
        JP AY_RestorePage2

AY_Stop:
        XOR A
        LD (AY_Active),A
        LD (AY_Delay),A
        CALL AY_MuteAll
        RET

AY_MuteAll:
        LD E,0
        LD A,8
        CALL AY_WriteRegE
        LD A,9
        CALL AY_WriteRegE
        LD A,10
        CALL AY_WriteRegE
        LD E,AY_MIXER_SILENT
        LD A,7
        JP AY_WriteRegE

AY_Update:
        PUSH AF
        PUSH BC
        PUSH DE
        PUSH HL
        LD A,(AY_Active)
        OR A
        JR Z,.done
        LD A,(AY_Delay)
        OR A
        JR Z,.read_row
        DEC A
        LD (AY_Delay),A
        JR NZ,.done
.read_row:
        LD A,(AY_Page)
        CALL AY_MapPage2A
        LD HL,(AY_Ptr)
        LD A,(HL)
        OR A
        JR Z,.end_sound
        LD (AY_Delay),A
        INC HL

        LD A,0
        CALL AY_WriteNext
        LD A,1
        CALL AY_WriteNext
        LD A,2
        CALL AY_WriteNext
        LD A,3
        CALL AY_WriteNext
        LD A,4
        CALL AY_WriteNext
        LD A,5
        CALL AY_WriteNext
        LD A,6
        CALL AY_WriteNext
        LD A,7
        CALL AY_WriteNext
        LD A,8
        CALL AY_WriteNext
        LD A,9
        CALL AY_WriteNext
        LD A,10
        CALL AY_WriteNext
        LD (AY_Ptr),HL
        CALL AY_RestorePage2
        JR .done
.end_sound:
        CALL AY_RestorePage2
        CALL AY_Stop
.done:
        POP HL
        POP DE
        POP BC
        POP AF
        RET

AY_WriteNext:
        LD E,(HL)
        INC HL
        JP AY_WriteRegE

AY_MapPage2A:
        LD (AY_MapPage),A
        LD A,(FMADDR_REGS + HIGH PAGE2)
        LD (AY_SavedPage2),A
        LD A,(AY_MapPage)
        LD (FMADDR_REGS + HIGH PAGE2),A
        RET

AY_RestorePage2:
        LD A,(AY_SavedPage2)
        LD (FMADDR_REGS + HIGH PAGE2),A
        RET

AY_WriteRegE:
        LD BC,AY_REG_PORT
        OUT (C),A
        LD BC,AY_DATA_PORT
        LD A,E
        OUT (C),A
        RET

AY_Active:          DB 0
AY_Delay:           DB 0
AY_RequestId:       DB 0
AY_SavedPage2:      DB 0
AY_MapPage:         DB 0
AY_Page:            DB 0
AY_Ptr:             DW 0

AY_End:
