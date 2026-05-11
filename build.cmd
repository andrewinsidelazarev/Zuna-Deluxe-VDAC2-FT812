@echo off
setlocal
cd /d %~dp0

set SJASMPLUS=c:\z80\tsconf_project\exe\sjasmplus\sjasmplus.exe
set SPGBLD=c:\z80\tsconf_project\exe\spgbld\spgbld.exe
set UNREAL=c:\Users\Администратор\Desktop\unreal_x64\Unreal.exe

echo === sjasmplus ===
%SJASMPLUS% main.asm --syntax=ab --lst=main.lst
if errorlevel 1 goto :err

echo === spgbld ===
%SPGBLD% -b spgbld_vdac2.ini zuma_vdac2.spg
if errorlevel 1 goto :err

echo === run ===
start "" "%UNREAL%" "%~dp0zuma_vdac2.spg"
goto :eof

:err
echo BUILD FAILED
exit /b 1
