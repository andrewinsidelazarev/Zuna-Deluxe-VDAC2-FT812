                ; Smoke-build для Init_Video.asm — проверяет что подключение TSLib и
                ; макросы разворачиваются без ошибок. Не предназначен для запуска.

                DEVICE ZXSPECTRUM4096
                define MAPPING_REGISTERS

                ORG #6000

                ; Z80-RAM указатели для FT_RESOLUTION
ResolutionWidthPtr   EQU #40F3
ResolutionHeightPtr  EQU #40F5

                ; Подключаем TSLib (минимум для Init_Video + MainLoop)
                include "../../Docs/TSLib/Include/TSConf.inc"
                include "../../Docs/TSLib/Include/Memory/Include.inc"     ; GetPage3/SetPage3_A для Inflate.asm
                include "../../Docs/TSLib/Include/Video/Macro.inc"
                include "../../Docs/TSLib/Include/FT/81x Const.inc"
                include "../../Docs/TSLib/Include/FT/DL  Macro.inc"
                include "../../Docs/TSLib/Include/FT/812 Macro.inc"
                module FT
                include "../../Docs/TSLib/Include/FT/812 Func.asm"
                include "../../Docs/TSLib/Include/FT/Coprocessor/Include.inc"
                endmodule

                ; Точка входа: Init_Video → MainLoop
EntryPoint:     CALL Init_Video
                JP   MainLoop

                include "Init_Video.asm"
                include "MainLoop.asm"

                END EntryPoint
