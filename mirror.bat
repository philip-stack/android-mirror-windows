@echo off
rem Mirror an Android device to Windows and control it with mouse + keyboard.
rem
rem Checks for a newer scrcpy version on each start and offers to install it.
rem Skip that with --no-update-check or by setting SKIP_UPDATE_CHECK=1, which
rem also keeps things quick when there is no network.
rem
rem Any other argument is passed straight through to scrcpy.
title Android Screen Mirror
setlocal enabledelayedexpansion

rem Take the raw command line rather than walking %1/%2: cmd treats "=" as an
rem argument separator, so shifting would turn --max-size=1024 into two tokens
rem and scrcpy would see a broken flag.
set "PASSTHRU=%*"
set "SKIPCHECK=%SKIP_UPDATE_CHECK%"
rem The "if defined" guard is not optional: on an UNDEFINED variable cmd expands
rem !VAR:search=! to the literal search string instead of to nothing, which would
rem hand scrcpy a bogus --no-update-check argument when called without any.
if defined PASSTHRU (
  if not "!PASSTHRU!"=="!PASSTHRU:--no-update-check=!" (
    set "SKIPCHECK=1"
    set "PASSTHRU=!PASSTHRU:--no-update-check=!"
  )
)

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

if not defined SKIPCHECK call :check_update

echo.
echo   Waiting for an Android device ...
echo   Plug in the USB cable. If the phone shows
echo   "Allow USB debugging?" choose "Always allow" -^> OK
echo.

"!ADB!" start-server >nul 2>&1

:wait_loop
call :count_devices
if !DEVCOUNT! GEQ 1 goto have_device
rem Polling instead of "adb wait-for-device": that command errors out when more
rem than one device is attached, and we want to report that properly below.
timeout /t 1 /nobreak >nul
goto wait_loop

:have_device
set "TARGET="
if !DEVCOUNT! GTR 1 (
  if not defined ANDROID_SERIAL (
    echo   More than one device is connected:
    echo.
    "!ADB!" devices
    echo.
    echo   Pick one before starting, for example:
    echo     set ANDROID_SERIAL=0123456789ABCDEF
    echo.
    pause
    endlocal
    exit /b 1
  )
) else (
  rem Be explicit about the target so a device plugged in later cannot confuse us.
  set "TARGET=-s !SERIAL!"
)

echo   Device found. Starting mirror ...
echo.
"!SCRCPY!" !TARGET! --stay-awake --max-fps=60 !PASSTHRU!
if errorlevel 1 goto failed

endlocal
exit /b 0


:count_devices
rem Counts devices in state "device". Anything else - unauthorized, offline -
rem is ignored on purpose so the wait loop keeps going until the phone is ready.
set "DEVCOUNT=0"
set "SERIAL="
for /f "skip=1 tokens=1,2" %%a in ('"!ADB!" devices 2^>nul') do (
  if "%%b"=="device" (
    set /a DEVCOUNT+=1
    set "SERIAL=%%a"
  )
)
goto :eof


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
