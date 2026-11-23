@echo off
setlocal
call "%~dp0Run-Python.cmd" launch
if errorlevel 1 pause
