@echo off
rem Switches a USB-connected Android device over to wireless debugging, so the
rem cable can be unplugged and mirror.bat works over Wi-Fi.
rem
rem Run "adb usb" (or just reboot the phone) to go back to USB only.
title Android Wireless Debugging
setlocal enabledelayedexpansion

set "PORT=5555"

call :resolve_adb
if not defined ADB (
  echo.
  echo   adb was not found. Run setup.ps1 first.
  echo.
  pause
  exit /b 1
)

echo.
echo   Connect the phone by USB first - pairing needs the cable once.
echo.

"!ADB!" start-server >nul 2>&1
call :count_usb_devices
if !DEVCOUNT! EQU 0 (
  echo   No USB device ready. Plug it in, confirm the prompt, then run this again.
  echo.
  pause
  endlocal
  exit /b 1
)
if !DEVCOUNT! GTR 1 (
  echo   More than one device is connected:
  echo.
  "!ADB!" devices
  echo.
  echo   Unplug the others, or set ANDROID_SERIAL to pick one.
  echo.
  pause
  endlocal
  exit /b 1
)

echo   Using device !SERIAL!
echo   Reading the phone's Wi-Fi address ...
set "IP="
set "RAW="
rem Via a temp file on purpose: calling an exe whose path contains spaces from
rem inside for /f ('...') breaks cmd's parser. Line looks like
rem   47: wlan0    inet 10.202.200.166/16 brd ...
rem so the address is token 4, and the /16 prefix length gets stripped below.
set "TMPF=%TEMP%\amw_ip_%RANDOM%.txt"
"!ADB!" -s !SERIAL! shell ip -f inet -o addr show wlan0 > "!TMPF!" 2>nul
for /f "usebackq tokens=4" %%a in ("!TMPF!") do (
  if not defined RAW set "RAW=%%a"
)
del "!TMPF!" >nul 2>&1
if defined RAW for /f "tokens=1 delims=/" %%b in ("!RAW!") do set "IP=%%b"

if not defined IP (
  echo.
  echo   Could not read a Wi-Fi address. Is the phone on Wi-Fi?
  echo   Check manually with:  adb shell ip addr show wlan0
  echo.
  pause
  endlocal
  exit /b 1
)

echo   Phone is on !IP!
echo   Switching adb to TCP/IP on port !PORT! ...
"!ADB!" -s !SERIAL! tcpip !PORT!
if errorlevel 1 goto failed

rem The daemon needs a moment to come back up on the new transport.
timeout /t 2 /nobreak >nul

echo   Connecting to !IP!:!PORT! ...
"!ADB!" connect !IP!:!PORT!
if errorlevel 1 goto failed

echo.
"!ADB!" devices
echo.
echo   Done. You can unplug the cable now and start mirror.bat.
echo   Wi-Fi adds noticeable latency - try --max-size=1024 --max-fps=30
echo.
echo   Note: this leaves a debugging port open on your network until the
echo   phone reboots or you run "adb usb".
echo.
pause
endlocal
exit /b 0


:count_usb_devices
set "DEVCOUNT=0"
set "SERIAL="
for /f "skip=1 tokens=1,2" %%a in ('"!ADB!" devices 2^>nul') do (
  if "%%b"=="device" (
    rem Skip entries that are already network transports (host:port).
    echo %%a | findstr /C:":" >nul
    if errorlevel 1 (
      set /a DEVCOUNT+=1
      set "SERIAL=%%a"
    )
  )
)
goto :eof


:resolve_adb
set "SD="
set "PKG=%LOCALAPPDATA%\Microsoft\WinGet\Packages"
for /d %%A in ("%PKG%\Genymobile.scrcpy*") do (
  for /f "delims=" %%B in ('dir /b /ad /o-d "%%A\scrcpy-win64-*" 2^>nul') do (
    if not defined SD if exist "%%A\%%B\adb.exe" set "SD=%%A\%%B"
  )
)
if defined SD (
  set "ADB=!SD!\adb.exe"
  goto :eof
)
where adb >nul 2>&1
if errorlevel 1 ( set "ADB=" & goto :eof )
set "ADB=adb"
goto :eof


:failed
echo.
echo   That did not work. Things to check:
echo     - Phone and PC on the same Wi-Fi network?
echo     - Some routers block device-to-device traffic (client isolation).
echo     - Try again over USB with:  adb usb
echo.
pause
endlocal
exit /b 1
