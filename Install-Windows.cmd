@echo off
setlocal
call "%~dp0windows\Run-Python.cmd" install %*
set "camera_result=%ERRORLEVEL%"
pause
exit /b %camera_result%
