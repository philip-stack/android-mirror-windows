@echo off
rem Same as mirror.bat, but keeps the phone screen off while you control it
rem from the PC. The screen stays off when scrcpy is closed.
rem Press Alt+Shift+O in the scrcpy window to turn the phone screen back on.
call "%~dp0mirror.bat" --turn-screen-off --power-off-on-close %*
