#Requires -Version 5.1
<#
.SYNOPSIS
    Installs scrcpy and prepares this PC for mirroring an Android device.

.DESCRIPTION
    Installs scrcpy via winget (adb ships with it), starts the adb server and
    optionally puts shortcuts to mirror.bat / mirror-dark.bat on the desktop.
    Safe to run repeatedly.

.PARAMETER NoShortcut
    Skip creating the desktop shortcuts.

.EXAMPLE
    .\setup.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }

Write-Step 'Checking winget'
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store, then run this again.'
}

Write-Step 'Installing scrcpy (skipped if already present)'
winget install --id Genymobile.scrcpy -e `
    --accept-package-agreements --accept-source-agreements --disable-interactivity
# winget exits 0 on success and -1978335189 when already installed and up to date.
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    throw "winget failed with exit code $LASTEXITCODE"
}

Write-Step 'Locating scrcpy'
$pkgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
$scrcpy = Get-ChildItem -Path $pkgRoot -Filter 'scrcpy.exe' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $scrcpy) {
    $cmd = Get-Command scrcpy -ErrorAction SilentlyContinue
    if ($cmd) { $scrcpy = Get-Item $cmd.Source }
}
if (-not $scrcpy) { throw 'scrcpy.exe not found after install.' }
Write-Host "    $($scrcpy.FullName)"

$adb = Join-Path $scrcpy.DirectoryName 'adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }

Write-Step 'Starting adb server'
& $adb start-server | Out-Null
& $adb devices

if (-not $NoShortcut) {
    Write-Step 'Creating desktop shortcuts'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $created = 0
    foreach ($item in @(
        @{ Name = 'Android Control Panel'; Target = 'panel.bat' },
        @{ Name = 'Android Mirror';        Target = 'mirror.bat' },
        @{ Name = 'Android Mirror (dark)'; Target = 'mirror-dark.bat' }
    )) {
        $target = Join-Path $root $item.Target
        if (-not (Test-Path $target)) {
            Write-Host "    skipped $($item.Target) - not found next to setup.ps1" -ForegroundColor Yellow
            continue
        }
        $lnk = $shell.CreateShortcut((Join-Path $desktop "$($item.Name).lnk"))
        $lnk.TargetPath = $target
        $lnk.WorkingDirectory = $root
        $lnk.Description = 'Mirror an Android device to this PC'
        $lnk.Save()
        Write-Host "    $($item.Name).lnk"
        $created++
    }
    if ($created -eq 0) {
        Write-Host '    No shortcuts created. Run setup.ps1 from the cloned repo so the .bat files sit next to it.' -ForegroundColor Yellow
    }
}

Write-Host @"

Done. Remaining steps on the phone:

  1. Settings > About phone   -> tap "Build number" 7 times
  2. Settings > System > Developer options -> enable "USB debugging"
  3. Plug in a USB DATA cable and confirm "Allow USB debugging?" on the phone

Then run mirror.bat (or mirror-dark.bat to keep the phone screen off).
"@ -ForegroundColor Green
