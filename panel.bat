@echo off
rem Opens the control panel window.
rem
rem Goes through panel.vbs because that is the only way to get no console window
rem at all: "powershell -WindowStyle Hidden" still leaves an empty Windows
rem Terminal tab behind on Windows 11.
rem
rem Arguments are passed on, so "panel.bat -StartMirror -ScreenOff" works.
start "" wscript "%~dp0panel.vbs" %*
