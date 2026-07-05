@echo off
setlocal
cd /d %~dp0
python Source\OTHER\regress.py %*
exit /b %errorlevel%
