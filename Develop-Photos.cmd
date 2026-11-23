@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "python_exec=%~dp0.venv\Scripts\python.exe"
set "python_version="
if exist "%python_exec%" goto run
where py.exe >nul 2>nul
if errorlevel 1 goto system_python
set "python_exec=py.exe"
set "python_version=-3"
goto run
:system_python
where python.exe >nul 2>nul
if errorlevel 1 goto missing
set "python_exec=python.exe"
:run
"%python_exec%" %python_version% "%~dp0tools\develop_photos.py" %*
set "developer_result=%ERRORLEVEL%"
if "%developer_result%"=="0" exit /b 0
echo Check that Python includes Tcl/Tk and see the error above.
pause
exit /b %developer_result%
:missing
echo Install Python 3 with Tcl/Tk to launch TerraTech Legion Photo Developer.
pause
exit /b 1
