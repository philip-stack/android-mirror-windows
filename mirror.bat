@echo off
rem Mirror an Android device to Windows and control it with mouse + keyboard.
rem Checks for a newer scrcpy version on each start and offers to install it.
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

call :check_update

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
rem for /d only expands a wildcard in the LAST path segment, hence two loops.
rem dir /o-d sorts newest first so an update wins: sorting by name would rank
rem v4.10 below v4.2. Falls back to PATH if the winget package dir is absent.
set "SD="
set "PKG=%LOCALAPPDATA%\Microsoft\WinGet\Packages"
for /d %%A in ("%PKG%\Genymobile.scrcpy*") do (
  for /f "delims=" %%B in ('dir /b /ad /o-d "%%A\scrcpy-win64-*" 2^>nul') do (
    if not defined SD if exist "%%A\%%B\scrcpy.exe" set "SD=%%A\%%B"
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


:check_update
rem No winget, no check - just carry on.
where winget >nul 2>&1
if errorlevel 1 goto :eof

echo   Checking for a newer scrcpy version ...
set "OLDVER="
set "NEWVER="
rem "winget upgrade <package>" would install straight away. "list
rem --upgrade-available" changes nothing and only prints the package id when an
rem update really exists, which makes this independent of the display language.
for /f "tokens=1-5" %%a in ('winget list --id Genymobile.scrcpy -e --upgrade-available --disable-interactivity 2^>nul ^| findstr /C:"Genymobile.scrcpy"') do (
  set "OLDVER=%%c"
  set "NEWVER=%%d"
)

if not defined NEWVER (
  echo   scrcpy is up to date.
  goto :eof
)

echo.
echo   New version available:  !OLDVER!  -^>  !NEWVER!
choice /c YN /n /t 20 /d N /m "   Update now? [Y/N]  (20s, default: No) "
if errorlevel 2 (
  echo   Skipped.
  goto :eof
)

echo.
echo   Updating ...
winget upgrade --id Genymobile.scrcpy -e --accept-package-agreements --accept-source-agreements --disable-interactivity
if errorlevel 1 (
  echo   Update failed - continuing with the installed version.
  goto :eof
)
echo   Update installed.
call :resolve_scrcpy
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
