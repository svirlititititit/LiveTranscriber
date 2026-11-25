@echo off
rem Starts LiveTranscriber on this computer and opens its page in the default browser.
rem Close this window to stop the application.
set PYTHONUTF8=1
chcp 65001 >nul
cd /d "%~dp0"
title LiveTranscriber
where py >nul 2>nul
if errorlevel 1 goto plain_python
py -3 server.py %*
goto finished
:plain_python
python server.py %*
:finished
if errorlevel 1 pause
