@echo off
rem Mirror an Android device to Windows and control it with mouse + keyboard.
rem Any extra arguments are passed straight through to scrcpy.
title Android Screen Mirror
setlocal enabledelayedexpansion

call :resolve_scrcpy
if not defined SCRCPY (
  echo.
  echo   scrcpy was not found.
  echo   Run setup.ps1 first, or install it manually:
  echo     winget install --id Genymobile.scrcpy -e
  echo.
  pause
  exit /b 1
)

echo.
echo   Waiting for an Android device ...
echo   Plug in the USB cable. If the phone shows
echo   "Allow USB debugging?" choose "Always allow" -^> OK
echo.

"!ADB!" start-server >nul 2>&1
"!ADB!" wait-for-device
if errorlevel 1 goto failed

echo   Device found. Starting mirror ...
echo.
"!SCRCPY!" --stay-awake --max-fps=60 %*
if errorlevel 1 goto failed

endlocal
exit /b 0

:resolve_scrcpy
rem Prefer the winget package directory (version independent), fall back to PATH.
set "SD="
rem for /d only expands a wildcard in the LAST path segment, hence two loops.
set "PKG=%LOCALAPPDATA%\Microsoft\WinGet\Packages"
for /d %%A in ("%PKG%\Genymobile.scrcpy*") do (
  for /d %%B in ("%%A\scrcpy-win64-*") do (
    if exist "%%B\scrcpy.exe" set "SD=%%B"
  )
)
if defined SD (
  set "SCRCPY=!SD!\scrcpy.exe"
  set "ADB=!SD!\adb.exe"
  goto :eof
)
where scrcpy >nul 2>&1
if errorlevel 1 ( set "SCRCPY=" & goto :eof )
set "SCRCPY=scrcpy"
set "ADB=adb"
goto :eof

:failed
echo.
echo   ---------------------------------------------------
echo   Something went wrong. Check:
echo     1. USB debugging enabled in Developer options?
echo     2. Did you confirm the prompt on the phone?
echo     3. Try another USB port or cable - it must be a
echo        DATA cable, many charge-only cables have no
echo        data lines.
echo   Run "adb devices" to see the current state.
echo   ---------------------------------------------------
echo.
pause
endlocal
exit /b 1
