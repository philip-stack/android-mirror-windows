@echo off
rem Opens the control panel window.
rem "start" lets this console close immediately, and -WindowStyle Hidden keeps
rem PowerShell itself from flashing up a second one.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0panel.ps1"
