@echo off
setlocal
where py.exe >nul 2>nul
if errorlevel 1 goto python
py -3 "%~dp0photo_camera.py" %*
exit /b %ERRORLEVEL%
:python
where python.exe >nul 2>nul
if errorlevel 1 goto missing
python "%~dp0photo_camera.py" %*
exit /b %ERRORLEVEL%
:missing
echo Install Python 3.11 or newer for Windows with Tcl/Tk, then try again.
echo https://www.python.org/downloads/windows/
exit /b 1
