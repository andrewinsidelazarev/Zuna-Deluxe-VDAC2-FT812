        DEVICE ZXSPECTRUM128
        INCLUDE "fat32.inc"
        INCLUDE "filex.inc"
        INCLUDE "extension_ids.inc"

; Рабочая страница #0000-#3FFF (fat32-work.bin): GENBU/NXTBU #0000-#1FFF,
; нулевой буфер FILEX #2000-#21FF (он же DIR_OLDER_BUFFER), код и таблицы
; safety.asm/filex_cache.asm #2200-#2FFF, SECBU #3000, LOBU #3200, LOBU2 #3400,
; вехи FILEX #3600-#36FF, курсоры с #37F8, переменные ядра с #3800,
; SD-ZC #3900-#3DFF (включая CRC16), кэш сектора данных #3E00-#3FFF.
FAT32_ZERO_SCRATCH      EQU #2000
FAT32_ZERO_SCRATCH_SIZE EQU #0200
FAT32_LOW_CODE          EQU FAT32_ZERO_SCRATCH+FAT32_ZERO_SCRATCH_SIZE
FAT32_LOW_END           EQU #3000

        ORG FAT32_BASE

API_TABLE:
        JP DRIVER_BIND                   ; 0
        JP FAT_DEVICE_INIT               ; 1
        JP FAT_INFO                      ; 2
        JP FAT_MOUNT                     ; 3
        JP WDOS.RDD                      ; 4
        JP WDOS.SDD                      ; 5
        JP WDOS.GIPAG                    ; 6
        JP FAT_READ                      ; 7
        JP FAT_WRITE                     ; 8
        JP DRIVER_BIND                   ; 9
        JP WDOS.GLSTCAT                  ; 10
        JP WDOS.TLSTCAT                  ; 11
        JP WDOS.SRHFCL                   ; 12
        JP FAT_APPEND                    ; 13: для APPEND также есть вход 76
        JP WDOS.MKSG                     ; 14
        JP FAT_FILEX                     ; 15: для FILEX также есть вход 77
        JP WDOS.RFRH                     ; 16
        JP WDOS.GENTRY                   ; 17
        JP WDOS.TENTRY                   ; 18
        JP FAT_CREATE                    ; 19
        JP FAT_MKDIR                     ; 20
        JP FAT_DELETE                    ; 21
        JP FAT_RENAME                    ; 22
        JP WDOS.DLSG                     ; 23
        JP WDOS.CHTOSE                   ; 24
        JP FAT_NOT_SUPPORTED             ; 25
        JP FAT_FIND                      ; 26
        JP FAT_READ_VIDEO                ; 27: LOAD256 выбранного файла
        JP FAT_SKIP                      ; 28: LOADNON выбранного файла
        JP WDOS.NXTETY                   ; 29
        JP WDOS.NXTETY2                  ; 30
        JP FAT_SET_DIR                   ; 31
        JP FAT_SET_ROOT                  ; 32
        JP FAT_SEEK_START                ; 33
        JP FAT_SYNC                      ; 34
        JP FAT_CLOSE                     ; 35
        JP FAT_MOUNT_AT                  ; 36
        DUP 11                          ; 37..47
        JP FAT_NOT_SUPPORTED
        EDUP
        JP FAT_READ                      ; 48: LOAD512
        JP FAT_WRITE                     ; 49: SAVE512
        JP FAT_SEEK_START                ; 50: GIPAGPL
        JP WDOS.TENTRY                   ; 51: TENTRY
        JP WDOS.CHTOSE                   ; 52: CHTOSEP
        JP FAT_NOT_SUPPORTED             ; 53
        JP FAT_NOT_SUPPORTED             ; 54: отметка в интерфейсе — задача приложения
        JP FAT_NOT_SUPPORTED             ; 55
        JP FAT_SET_DIR                   ; 56: ADIR
        JP FAT_NOT_SUPPORTED             ; 57: STREAM переключает панели WC
        JP WDOS.NXTETY2                  ; 58
        JP FAT_FIND                      ; 59
        JP FAT_READ_VIDEO                ; 60
        JP FAT_SKIP                      ; 61
        JP FAT_SEEK_START                ; 62: GFILE
        JP FAT_SET_DIR                   ; 63: GDIR
        DUP 8                           ; 64..71
        JP FAT_NOT_SUPPORTED
        EDUP
        JP FAT_CREATE                    ; 72: MKFILE
        JP FAT_MKDIR                     ; 73
        JP FAT_RENAME                    ; 74
        JP FAT_DELETE                    ; 75
        JP FAT_APPEND                    ; 76: полный APPEND
        JP FAT_FILEX                     ; 77: полный FILEX
        DUP FAT32_COMMAND_COUNT-78       ; запас для команд 78..127
        JP FAT_NOT_SUPPORTED
        EDUP
API_TABLE_END:
        ASSERT API_TABLE_END-API_TABLE == FAT32_COMMAND_COUNT*3

        MODULE WDOS
        INCLUDE "state.inc"
START EQU @API_TABLE
        INCLUDE "core32.asm"
        ENDMODULE
        MODULE WDOS_EXT
        INCLUDE "extension.asm"
        ENDMODULE
        INCLUDE "filex.asm"
        INCLUDE "public.asm"
        INCLUDE "block_io.asm"
CODE_END:
        ASSERT CODE_END <= #8000, FAT32 code exceeds the 16 KiB code window
        SAVEBIN "build/fat32.bin",FAT32_BASE,CODE_END-FAT32_BASE

; Проверки сохранности данных — в рабочей странице: собираются в свободном
; окне #C000 устройства ассемблера с адресами исполнения FAT32_LOW_CODE;
; build.py кладёт образ в fat32-work.bin.
        ORG #C000
LOW_IMAGE:
        DISP FAT32_LOW_CODE
        MODULE WDOS_EXT
        INCLUDE "safety.asm"
        ENDMODULE
        INCLUDE "filex_cache.asm"
LOW_END:
        ENT
        ASSERT LOW_END <= FAT32_LOW_END, safety code exceeds the work-page window
        SAVEBIN "build/fat32-low.bin",LOW_IMAGE,LOW_END-FAT32_LOW_CODE
