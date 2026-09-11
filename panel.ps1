#Requires -Version 5.1
<#
.SYNOPSIS
    Small control panel for an Android device connected over adb.

.DESCRIPTION
    Wraps scrcpy and adb in a WinForms window: mirroring, screenshots, screen
    recording, wireless debugging, APK install and a manual scrcpy update check.

.PARAMETER StartMirror
    Begin mirroring as soon as the panel opens. If no device is attached yet it
    waits and starts on its own once one shows up.

.PARAMETER ScreenOff
    Preselect "Phone screen off", and use it for -StartMirror.

.PARAMETER MaxSize
    Preselect a max size. 0 means the device's own resolution.

.PARAMETER Fps
    Preselect a frame rate cap.

.PARAMETER BitRate
    Preselect the video bit rate in Mbit/s. 8 is scrcpy's own default and stays
    the default here: it is thin for a 1280x2856 screen - 0.036 bits per pixel
    at 60 fps, which smears while things move - but raising it makes the phone's
    encoder work harder, and in a game that showed up as stalling rather than a
    sharper picture. Raise it for reading and scrolling, leave it for games, or
    cut the pixel count with -MaxSize instead, which helps both at once.

.PARAMETER SelfTest
    Run the logic and build the window without showing it, printing the results.
    A GUI cannot be clicked headlessly, so this is what keeps the non-visual
    parts verifiable.

.EXAMPLE
    .\panel.ps1

.EXAMPLE
    .\panel.ps1 -StartMirror -ScreenOff
#>
[CmdletBinding()]
param(
    [switch]$StartMirror,
    [switch]$ScreenOff,
    [ValidateSet(0, 800, 1024, 1280, 1920)]
    [int]$MaxSize = 0,
    [ValidateSet(24, 30, 60)]
    [int]$Fps = 60,
    [ValidateSet(8, 16, 24, 32)]
    [int]$BitRate = 8,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Used to pull the scrcpy window forward (see Start-Mirror) and to hide our own
# console window (see Hide-OwnConsole).
if (-not ([System.Management.Automation.PSTypeName]'PanelNative').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class PanelNative {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] buffer, uint count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
}

function Hide-OwnConsole {
    # powershell.exe -WindowStyle Hidden still leaves an empty console window
    # behind, because the console is allocated before the style is applied. Hide
    # it here instead.
    #
    # Only when we are the sole process attached to it: run from an existing
    # terminal the shell is attached too, and hiding that would take the user's
    # own window away.
    $console = [PanelNative]::GetConsoleWindow()
    if ($console -eq [IntPtr]::Zero) { return }
    $buffer = New-Object uint32[] 8
    $count  = [PanelNative]::GetConsoleProcessList($buffer, 8)
    if ($count -eq 1) {
        [void][PanelNative]::ShowWindow($console, 0)   # SW_HIDE
    }
}

# Held for the lifetime of the process, which is what keeps the name taken.
$script:Instance = $null

function Request-SingleInstance {
    # A second panel polls the same phone in parallel and the two end up fighting
    # over adb - we had two of them running at once. Hand the user the window
    # that is already open instead of stacking another one behind it.
    $created = $false
    $script:Instance = New-Object System.Threading.Mutex($true, 'Local\AndroidControlPanel', [ref]$created)
    if ($created) { return $true }

    $existing = [PanelNative]::FindWindow($null, 'Android Control Panel')
    if ($existing -ne [IntPtr]::Zero) {
        [void][PanelNative]::ShowWindow($existing, 9)   # SW_RESTORE
        [void][PanelNative]::SetForegroundWindow($existing)
    }
    return $false
}

$script:Tools        = $null
$script:Serial       = $null
$script:RecordRemote = $null
$script:RecordProc   = $null
$script:RecordStamp  = $null
$script:MirrorProc   = $null
$script:Busy         = $false

# Per serial: model and Android version, which never change once known.
$script:DeviceFacts      = @{}
$script:BatterySerial    = $null
$script:BatteryLevel     = $null
$script:BatteryTemp      = $null
$script:BatteryStamp     = [DateTime]::MinValue
# Ten seconds: the charge level does not need it, but the temperature is worth
# watching while mirroring, and both arrive in the same single adb call.
$script:BatteryMaxAgeSec = 10

# ----------------------------------------------------------------- tooling

function Resolve-Tools {
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $exe = Get-ChildItem -Path $pkgRoot -Filter 'scrcpy.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $exe) {
        $cmd = Get-Command scrcpy -ErrorAction SilentlyContinue
        if ($cmd) { $exe = Get-Item $cmd.Source }
    }
    if (-not $exe) { return $null }

    $adb = Join-Path $exe.DirectoryName 'adb.exe'
    if (-not (Test-Path $adb)) {
        $cmd = Get-Command adb -ErrorAction SilentlyContinue
        if ($cmd) { $adb = $cmd.Source } else { $adb = $null }
    }
    return [pscustomobject]@{ Scrcpy = $exe.FullName; Adb = $adb }
}

# .NET Framework has no ProcessStartInfo.ArgumentList, so the command line is
# built by hand. Only whitespace and quotes need escaping for our purposes.
function ConvertTo-CommandLine {
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

# Runs a console program without letting a console window flash up. Calling adb
# with the call operator pops a window for every invocation, and the device poll
# runs several of those every few seconds - which is exactly the flickering.
#
# CreateNoWindow also sidesteps Windows PowerShell 5.1 turning native stderr into
# a terminating NativeCommandError, because nothing goes through the pipeline.
# Waiting used to block the UI thread outright: adb calls, the wait for scrcpy's
# window, the pause while a recording is finalised. The window stayed frozen for
# seconds at a time. Every wait now runs in small slices and pumps the message
# loop in between, so the panel keeps painting, moving and closing.
#
# Re-entrancy is not a worry: every click handler bails out on the Busy flag, so
# a pumped message can never start a second action on top of a running one.
$script:PumpUi = $false
function Enable-UiPump  { $script:PumpUi = $true }
function Disable-UiPump { $script:PumpUi = $false }
function Test-UiPump    { return $script:PumpUi }

function Wait-Pumped {
    param([int]$Milliseconds)
    $until = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $until) {
        if (Test-UiPump) { [System.Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 15
    }
}

function Invoke-Hidden {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMs = 30000)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ConvertTo-CommandLine $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Both pipes are drained by the framework from here on, so a full buffer
    # cannot deadlock us and the wait below is free to run in slices.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while (-not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        if (Test-UiPump) { [System.Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 10
    }
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }

    [void]$errTask.Wait(2000)
    $stdout = ''
    if ($outTask.Wait(2000)) { $stdout = $outTask.Result }
    if ([string]::IsNullOrEmpty($stdout)) { return @() }
    return @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
}

# One explicit array parameter, deliberately NOT ValueFromRemainingArguments:
# with loose arguments PowerShell would try to bind adb's own flags, and "-o" in
# "ip -f inet -o addr" resolves ambiguously against -OutVariable/-OutBuffer.
function Invoke-Adb {
    param([string[]]$Arguments)
    if (-not $script:Tools -or -not $script:Tools.Adb) { return @() }
    return Invoke-Hidden -FilePath $script:Tools.Adb -Arguments $Arguments
}

# Like Invoke-Hidden but for something we keep running, so no redirection: an
# undrained pipe would eventually block the child.
function Start-Hidden {
    param([string]$FilePath, [string[]]$Arguments, [switch]$CaptureError)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = ConvertTo-CommandLine $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    # stderr only: that is where scrcpy puts its errors. stdout carries nothing
    # but the version banner, and in normal use there is no console for it to
    # land in anyway.
    if ($CaptureError) { $psi.RedirectStandardError = $true }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($CaptureError) {
        # Handed to the framework to drain, so the pipe cannot fill up and stall
        # a child that keeps running. Only read if it dies on us early.
        Add-Member -InputObject $proc -Force -NotePropertyName ErrorTask `
            -NotePropertyValue $proc.StandardError.ReadToEndAsync()
    }
    return $proc
}

function Invoke-AdbTarget {
    param([string[]]$Arguments)
    if ($script:Serial) { return Invoke-Adb (@('-s', $script:Serial) + $Arguments) }
    return Invoke-Adb $Arguments
}

# ------------------------------------------------------------------ device

function Get-Devices {
    $rows = @()
    foreach ($line in (Invoke-Adb @('devices'))) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline)\s*$') {
            $rows += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $rows
}

function Get-DeviceInfo {
    $all   = @(Get-Devices)
    $ready = @($all | Where-Object { $_.State -eq 'device' })

    if ($ready.Count -eq 0) {
        $state = 'no device'
        if ($all.Count -gt 0) { $state = $all[0].State }
        return [pscustomobject]@{
            Ready = $false; Status = $state; Serial = $null
            Model = $null; Android = $null; Battery = $null; Temperature = $null; Count = $all.Count
        }
    }

    # Keep the current pick if it is still attached, otherwise take the first.
    if (-not $script:Serial -or -not ($ready.Serial -contains $script:Serial)) {
        $script:Serial = $ready[0].Serial
    }

    # Model and Android version cannot change under a given serial, so they are
    # asked once per device instead of on every poll. That alone took this from
    # four adb round trips every four seconds down to one.
    $facts = $script:DeviceFacts[$script:Serial]
    if (-not $facts) {
        $facts = @{
            Model   = ((Invoke-AdbTarget @('shell', 'getprop', 'ro.product.model')) -join '').Trim()
            Android = ((Invoke-AdbTarget @('shell', 'getprop', 'ro.build.version.release')) -join '').Trim()
        }
        # Only keep an answer that actually arrived, so a hiccup is retried.
        if ($facts.Model) { $script:DeviceFacts[$script:Serial] = $facts }
    }

    # Charge and temperature come out of this one call, so showing the temperature
    # costs no extra round trip.
    $age = ([DateTime]::UtcNow - $script:BatteryStamp).TotalSeconds
    if ($script:BatterySerial -ne $script:Serial -or $age -ge $script:BatteryMaxAgeSec) {
        foreach ($line in (Invoke-AdbTarget @('shell', 'dumpsys', 'battery'))) {
            if ($line -match '^\s*level:\s*(\d+)') { $script:BatteryLevel = [int]$Matches[1] }
            # Tenths of a degree, and the same figure the phone shows itself. The
            # thermalservice sensor that is also called "battery" is a different
            # one and reads several degrees higher.
            if ($line -match '^\s*temperature:\s*(-?\d+)') {
                $script:BatteryTemp = [double]$Matches[1] / 10
            }
        }
        $script:BatterySerial = $script:Serial
        $script:BatteryStamp  = [DateTime]::UtcNow
    }

    return [pscustomobject]@{
        Ready = $true; Status = 'device'; Serial = $script:Serial
        Model = $facts.Model; Android = $facts.Android
        Battery = $script:BatteryLevel; Temperature = $script:BatteryTemp; Count = $ready.Count
    }
}

# Closures created with GetNewClosure() live in their own module, where $script:
# resolves to that module rather than to this file. Script-scope state is therefore
# read through functions, which do resolve correctly from inside a closure.
function Get-CurrentSerial { return $script:Serial }
# Pressing Refresh should mean now, not "up to ten seconds ago".
function Reset-BatteryCache { $script:BatteryStamp = [DateTime]::MinValue }
function Reset-CurrentSerial { $script:Serial = $null }
# Self clearing: once scrcpy is gone - closed from its own window bar, device
# unplugged, crashed - the handle is dropped and the button goes back to Start.
function Test-MirrorActive {
    if ($script:MirrorProc -and $script:MirrorProc.HasExited) { $script:MirrorProc = $null }
    return [bool]$script:MirrorProc
}

function Stop-Mirror {
    if (-not $script:MirrorProc) { return }
    if (-not $script:MirrorProc.HasExited) {
        # Close the window rather than killing the process: scrcpy has its own
        # shutdown to run, and --power-off-on-close only happens on that path.
        [void]$script:MirrorProc.CloseMainWindow()
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not $script:MirrorProc.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Wait-Pumped 100
        }
        if (-not $script:MirrorProc.HasExited) { try { $script:MirrorProc.Kill() } catch { } }
    }
    $script:MirrorProc = $null
}

function Test-RecordingActive { return [bool]$script:RecordRemote }
# True once the adb client has exited, which happens when screenrecord hits its
# own three minute limit on the device - nobody pressed stop.
function Test-RecordingFinished { return [bool]($script:RecordProc -and $script:RecordProc.HasExited) }
function Get-ScrcpyPath { return $script:Tools.Scrcpy }

function Get-DeviceIp {
    foreach ($line in (Invoke-AdbTarget @('shell', 'ip', '-f', 'inet', '-o', 'addr', 'show', 'wlan0'))) {
        # 47: wlan0    inet 10.0.0.5/16 brd ...  -> field 4 holds the address
        $parts = @(($line -split '\s+') | Where-Object { $_ })
        if ($parts.Count -ge 4 -and $parts[2] -eq 'inet') { return ($parts[3] -split '/')[0] }
    }
    return $null
}

# ----------------------------------------------------------------- actions

function Get-OutputDir {
    $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'AndroidMirror'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Save-Screenshot {
    # Through a file on the device rather than "exec-out screencap -p": PowerShell
    # corrupts binary data coming back over a redirected native stdout.
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $remote = "/sdcard/panel_shot_$stamp.png"
    $local  = Join-Path (Get-OutputDir) "screenshot-$stamp.png"
    Invoke-AdbTarget @('shell', 'screencap', '-p', $remote) | Out-Null
    Invoke-AdbTarget @('pull', $remote, $local) | Out-Null
    Invoke-AdbTarget @('shell', 'rm', '-f', $remote) | Out-Null
    if (-not (Test-Path $local)) { throw 'Screenshot could not be pulled from the device.' }
    return $local
}

function Start-Recording {
    $script:RecordStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:RecordRemote = "/sdcard/panel_rec_$($script:RecordStamp).mp4"
    $argList = @()
    if ($script:Serial) { $argList += @('-s', $script:Serial) }
    $argList += @('shell', 'screenrecord', '--bit-rate', '8000000', $script:RecordRemote)
    $script:RecordProc = Start-Hidden -FilePath $script:Tools.Adb -Arguments $argList
    return $script:RecordRemote
}

function Stop-Recording {
    if (-not $script:RecordRemote) { throw 'No recording is running.' }
    # Already over the line: screenrecord stops by itself after three minutes and
    # takes the adb client with it. Signalling and waiting again would be pure
    # delay, and the file on the phone is finished either way.
    if (-not (Test-RecordingFinished)) {
        # screenrecord only finalises the MP4 container on SIGINT, so signal the
        # process on the device instead of killing the adb client here.
        Invoke-AdbTarget @('shell', 'pkill', '-INT', 'screenrecord') | Out-Null
        Wait-Pumped 3000
        if ($script:RecordProc -and -not $script:RecordProc.HasExited) {
            try { $script:RecordProc.Kill() } catch { }
        }
    }
    $local = Join-Path (Get-OutputDir) "recording-$($script:RecordStamp).mp4"
    Invoke-AdbTarget @('pull', $script:RecordRemote, $local) | Out-Null
    Invoke-AdbTarget @('shell', 'rm', '-f', $script:RecordRemote) | Out-Null
    $script:RecordRemote = $null
    $script:RecordProc   = $null
    if (-not (Test-Path $local)) { throw 'Recording could not be pulled from the device.' }
    return $local
}

function Test-ScrcpyUpdate {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Reason = 'winget not found' }
    }
    # "winget upgrade <package>" would install straight away, so ask "list".
    # Keying on the package id keeps this independent of the display language.
    $winget = (Get-Command winget).Source
    $out = Invoke-Hidden -FilePath $winget -Arguments @(
        'list', '--id', 'Genymobile.scrcpy', '-e', '--upgrade-available', '--disable-interactivity')
    $row = $out | Where-Object { $_ -match 'Genymobile\.scrcpy' } | Select-Object -First 1
    if (-not $row) { return [pscustomobject]@{ Available = $false; Reason = 'up to date' } }

    $parts = @(($row -split '\s+') | Where-Object { $_ })
    $current = ''
    $latest  = ''
    if ($parts.Count -ge 4) { $current = $parts[2]; $latest = $parts[3] }
    return [pscustomobject]@{ Available = $true; Current = $current; Latest = $latest; Reason = 'update available' }
}

function Install-ScrcpyUpdate {
    $winget = (Get-Command winget).Source
    [void](Invoke-Hidden -FilePath $winget -TimeoutMs 300000 -Arguments @(
        'upgrade', '--id', 'Genymobile.scrcpy', '-e',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'))
    $script:Tools = Resolve-Tools
}

function Start-Mirror {
    param([int]$MaxSize, [int]$Fps, [int]$BitRateMbit, [switch]$StayAwake, [switch]$ScreenOff)
    $argList = @()
    if ($script:Serial) { $argList += @('-s', $script:Serial) }
    if ($MaxSize -gt 0) { $argList += "--max-size=$MaxSize" }
    if ($Fps -gt 0)     { $argList += "--max-fps=$Fps" }
    if ($BitRateMbit -gt 0) { $argList += "--video-bit-rate=${BitRateMbit}M" }
    if ($StayAwake)     { $argList += '--stay-awake' }
    if ($ScreenOff)     { $argList += @('--turn-screen-off', '--power-off-on-close') }
    # Plain value: ConvertTo-CommandLine quotes it because of the space. Quoting it
    # here as well would put the quotes into the title scrcpy displays.
    $argList += '--window-title=Android Mirror'

    # CreateNoWindow suppresses scrcpy's console; its own SDL window is unaffected
    # and is what we wait for below. Its stderr is kept so a failure can be named.
    $proc = Start-Hidden -FilePath $script:Tools.Scrcpy -Arguments $argList -CaptureError

    # Inheriting aside, scrcpy needs a moment before it owns a window. Wait for it
    # and pull it to the front, rather than trusting the show state alone.
    # Eight seconds: a healthy start takes about two and a half.
    for ($i = 0; $i -lt 40; $i++) {
        Wait-Pumped 200
        if ($proc.HasExited) { break }
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [void][PanelNative]::ShowWindow($proc.MainWindowHandle, 9)   # SW_RESTORE
            [void][PanelNative]::SetForegroundWindow($proc.MainWindowHandle)
            $script:MirrorProc = $proc
            return $proc
        }
    }

    # Reporting success either way would send the user hunting for a window that
    # never opened. scrcpy quits straight away on an unauthorised or unplugged
    # device and says why on stderr, so pass that on instead.
    if ($proc.HasExited) {
        $reason = ''
        if ($proc.ErrorTask -and $proc.ErrorTask.Wait(2000)) {
            $reason = @($proc.ErrorTask.Result -split "`r?`n" |
                Where-Object { $_ -match '\S' } | Select-Object -Last 1) -join ''
        }
        if (-not $reason) { $reason = "exit code $($proc.ExitCode)" }
        throw "scrcpy stopped right away - $($reason.Trim())"
    }

    # Alive after the full wait but with no window: broken rather than slow. An
    # invisible scrcpy keeps its grip on the device, and pressing the button
    # again would stack up another one, so clear it away instead of leaving it.
    try { $proc.Kill() } catch { }
    throw 'scrcpy did not open a window within 8 seconds and was stopped.'
}

# --------------------------------------------------------------------- theme

function Get-Theme {
    # Follows the system setting. AppsUseLightTheme missing means light.
    $dark = $false
    try {
        $key = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Name AppsUseLightTheme -ErrorAction Stop
        $dark = ($key.AppsUseLightTheme -eq 0)
    } catch { }

    # The user's accent colour, so the primary button matches the rest of Windows.
    $accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    try {
        $dwm = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name ColorizationColor -ErrorAction Stop
        $raw = [uint32]$dwm.ColorizationColor
        $accent = [System.Drawing.Color]::FromArgb(
            [int](($raw -shr 16) -band 0xFF), [int](($raw -shr 8) -band 0xFF), [int]($raw -band 0xFF))
    } catch { }

    $shift = {
        param($c, $amount)
        $f = { param($v, $a) [Math]::Max(0, [Math]::Min(255, $v + $a)) }
        [System.Drawing.Color]::FromArgb((& $f $c.R $amount), (& $f $c.G $amount), (& $f $c.B $amount))
    }

    if ($dark) {
        return @{
            Dark        = $true
            Window      = [System.Drawing.Color]::FromArgb(32, 32, 32)
            Card        = [System.Drawing.Color]::FromArgb(43, 43, 43)
            Border      = [System.Drawing.Color]::FromArgb(58, 58, 58)
            Text        = [System.Drawing.Color]::FromArgb(244, 244, 244)
            TextDim     = [System.Drawing.Color]::FromArgb(155, 155, 155)
            Button      = [System.Drawing.Color]::FromArgb(56, 56, 56)
            ButtonHover = [System.Drawing.Color]::FromArgb(70, 70, 70)
            ButtonDown  = [System.Drawing.Color]::FromArgb(48, 48, 48)
            Field       = [System.Drawing.Color]::FromArgb(56, 56, 56)
            Accent      = $accent
            AccentHover = (& $shift $accent 22)
            AccentDown  = (& $shift $accent -22)
            AccentText  = [System.Drawing.Color]::White
            Ok          = [System.Drawing.Color]::FromArgb(108, 203, 95)
            Warn        = [System.Drawing.Color]::FromArgb(255, 184, 108)
            Bad         = [System.Drawing.Color]::FromArgb(255, 107, 107)
        }
    }
    return @{
        Dark        = $false
        Window      = [System.Drawing.Color]::FromArgb(243, 243, 243)
        Card        = [System.Drawing.Color]::White
        Border      = [System.Drawing.Color]::FromArgb(223, 223, 223)
        Text        = [System.Drawing.Color]::FromArgb(26, 26, 26)
        TextDim     = [System.Drawing.Color]::FromArgb(100, 100, 100)
        Button      = [System.Drawing.Color]::FromArgb(251, 251, 251)
        ButtonHover = [System.Drawing.Color]::FromArgb(240, 240, 240)
        ButtonDown  = [System.Drawing.Color]::FromArgb(230, 230, 230)
        Field       = [System.Drawing.Color]::White
        Accent      = $accent
        AccentHover = (& $shift $accent 18)
        AccentDown  = (& $shift $accent -18)
        AccentText  = [System.Drawing.Color]::White
        Ok          = [System.Drawing.Color]::FromArgb(16, 124, 16)
        Warn        = [System.Drawing.Color]::FromArgb(157, 93, 0)
        Bad         = [System.Drawing.Color]::FromArgb(196, 43, 28)
    }
}

function Set-DarkTitleBar {
    param($Form, [bool]$Dark)
    # DWMWA_USE_IMMERSIVE_DARK_MODE. Silently ignored on builds that predate it.
    try {
        $value = 0
        if ($Dark) { $value = 1 }
        [void][PanelNative]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$value, 4)
    } catch { }
}

# Panels and forms are not double buffered by default, so the background, the
# painted border and every child are drawn in separate passes - visible as
# flicker while the window builds up. The property is protected, hence reflection.
function Set-DoubleBuffered {
    param($Control)
    try {
        $prop = [System.Windows.Forms.Control].GetProperty(
            'DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $prop.SetValue($Control, $true, $null)
    } catch { }
}

function New-Card {
    param($Theme, [int]$X, [int]$Y, [int]$W, [int]$H)
    $card           = New-Object System.Windows.Forms.Panel
    Set-DoubleBuffered $card
    $card.Location  = New-Object System.Drawing.Point($X, $Y)
    $card.Size      = New-Object System.Drawing.Size($W, $H)
    $card.BackColor = $Theme.Card
    $border         = $Theme.Border
    $card.Add_Paint({
        param($sender, $e)
        $pen = New-Object System.Drawing.Pen($border)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1)
        $pen.Dispose()
    }.GetNewClosure())
    return $card
}

function New-SectionLabel {
    param($Theme, [string]$Text, [int]$X, [int]$Y)
    $label           = New-Object System.Windows.Forms.Label
    $label.Text      = $Text.ToUpper()
    $label.Location  = New-Object System.Drawing.Point($X, $Y)
    $label.Size      = New-Object System.Drawing.Size(300, 16)
    $label.ForeColor = $Theme.TextDim
    $label.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
    $label.BackColor = [System.Drawing.Color]::Transparent
    return $label
}

# A DropDownList ComboBox always paints its closed state with the system theme,
# which leaves a white box sitting on a dark card no matter what BackColor or
# owner drawing say. A flat button with a menu is fully themeable instead.
# The chosen value lives in .Tag; .Text carries it plus a chevron.
function New-ThemedDropdown {
    param($Theme, [int]$X, [int]$Y, [int]$W, [string[]]$Items, [string]$Initial)

    $button           = New-FlatButton $Theme '' $X $Y $W 26
    $button.TextAlign = 'MiddleLeft'
    $button.Padding   = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)

    $menu                 = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.ShowImageMargin = $false
    $menu.BackColor       = $Theme.Field
    $menu.ForeColor       = $Theme.Text

    $chevron = [string][char]0x25BE

    foreach ($entry in $Items) {
        $item           = New-Object System.Windows.Forms.ToolStripMenuItem($entry)
        $item.BackColor = $Theme.Field
        $item.ForeColor = $Theme.Text
        $item.Add_Click({
            param($sender, $e)
            $button.Tag  = $sender.Text
            $button.Text = "$($sender.Text)   $chevron"
        }.GetNewClosure())
        [void]$menu.Items.Add($item)
    }

    $button.Add_Click({ $menu.Show($button, 0, $button.Height) }.GetNewClosure())
    # Also hung off the control so right-click works and tests can reach the items.
    $button.ContextMenuStrip = $menu

    $value = $Initial
    if (-not $value) { $value = $Items[0] }
    $button.Tag  = $value
    $button.Text = "$value   $chevron"
    return $button
}

function New-FlatButton {
    param($Theme, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [switch]$Primary, [string]$FontName = 'Segoe UI', [single]$FontSize = 9)
    $button          = New-Object System.Windows.Forms.Button
    $button.Text     = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size     = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = 'Flat'
    $button.Font      = New-Object System.Drawing.Font($FontName, $FontSize)
    $button.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    if ($Primary) {
        $button.BackColor = $Theme.Accent
        $button.ForeColor = $Theme.AccentText
        $button.FlatAppearance.BorderSize          = 0
        $button.FlatAppearance.MouseOverBackColor  = $Theme.AccentHover
        $button.FlatAppearance.MouseDownBackColor  = $Theme.AccentDown
    } else {
        $button.BackColor = $Theme.Button
        $button.ForeColor = $Theme.Text
        $button.FlatAppearance.BorderSize          = 1
        $button.FlatAppearance.BorderColor         = $Theme.Border
        $button.FlatAppearance.MouseOverBackColor  = $Theme.ButtonHover
        $button.FlatAppearance.MouseDownBackColor  = $Theme.ButtonDown
    }
    return $button
}

# --------------------------------------------------------------------- UI

function New-Panel {
    $t = Get-Theme

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'Android Control Panel'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor       = $t.Window
    $form.ForeColor       = $t.Text
    Set-DoubleBuffered $form
    # Invisible until the first paint is through. Child controls are separate
    # windows that paint themselves only once the message loop gets around to
    # them, so a window shown right away stands there with white unpainted
    # rectangles for a moment. The boot timer below turns it visible again -
    # it can only fire once the queue, paints included, has run dry.
    $form.Opacity = 0

    $pad   = 16
    $inner = 420                      # card width
    $y     = 14

    # ---------------------------------------------------------- device card
    $cardDevice = New-Card $t $pad $y $inner 78
    $form.Controls.Add($cardDevice)

    $dotState = @{ Color = $t.TextDim }
    $dot            = New-Object System.Windows.Forms.Panel
    $dot.Location   = New-Object System.Drawing.Point(16, 26)
    $dot.Size       = New-Object System.Drawing.Size(10, 10)
    $dot.BackColor  = $t.Card
    $dot.Add_Paint({
        param($sender, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $brush = New-Object System.Drawing.SolidBrush($dotState.Color)
        $e.Graphics.FillEllipse($brush, 0, 0, 9, 9)
        $brush.Dispose()
    }.GetNewClosure())
    $cardDevice.Controls.Add($dot)

    $lblDevice           = New-Object System.Windows.Forms.Label
    $lblDevice.Location  = New-Object System.Drawing.Point(34, 18)
    $lblDevice.Size      = New-Object System.Drawing.Size(300, 24)
    $lblDevice.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $lblDevice.ForeColor = $t.Text
    $lblDevice.BackColor = [System.Drawing.Color]::Transparent
    $cardDevice.Controls.Add($lblDevice)

    # The second line is three labels rather than one string: the temperature
    # needs a colour of its own, and it should sit right behind the charge level
    # instead of being parked at the far edge. They size themselves and are
    # chained left to right on every refresh, so they read as a single line.
    $lblSerial           = New-Object System.Windows.Forms.Label
    $lblSerial.Location  = New-Object System.Drawing.Point(34, 44)
    $lblSerial.AutoSize  = $true
    $lblSerial.ForeColor = $t.TextDim
    $lblSerial.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblSerial.BackColor = [System.Drawing.Color]::Transparent
    $cardDevice.Controls.Add($lblSerial)

    $lblTemp           = New-Object System.Windows.Forms.Label
    $lblTemp.Location  = New-Object System.Drawing.Point(140, 44)
    $lblTemp.AutoSize  = $true
    $lblTemp.ForeColor = $t.TextDim
    $lblTemp.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
    $lblTemp.BackColor = [System.Drawing.Color]::Transparent
    $cardDevice.Controls.Add($lblTemp)

    $lblSerialRest           = New-Object System.Windows.Forms.Label
    $lblSerialRest.Location  = New-Object System.Drawing.Point(200, 44)
    $lblSerialRest.AutoSize  = $true
    $lblSerialRest.ForeColor = $t.TextDim
    $lblSerialRest.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $lblSerialRest.BackColor = [System.Drawing.Color]::Transparent
    $cardDevice.Controls.Add($lblSerialRest)

    # Glyph-only button, so the icon font does not affect any label text.
    $btnRefresh = New-FlatButton $t ([char]0xE72C) 366 24 38 30 -FontName 'Segoe MDL2 Assets' -FontSize 10
    $cardDevice.Controls.Add($btnRefresh)

    $y += 78 + 18

    # ---------------------------------------------------------- mirror card
    $form.Controls.Add((New-SectionLabel $t 'Mirror' ($pad + 2) $y))
    $y += 18
    $cardMirror = New-Card $t $pad $y $inner 160
    $form.Controls.Add($cardMirror)

    $lblSize           = New-Object System.Windows.Forms.Label
    $lblSize.Text      = 'Max size'
    $lblSize.Location  = New-Object System.Drawing.Point(16, 22)
    $lblSize.Size      = New-Object System.Drawing.Size(58, 20)
    $lblSize.ForeColor = $t.TextDim
    $lblSize.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($lblSize)

    $sizeInitial = 'Original'
    if ($MaxSize -gt 0) { $sizeInitial = [string]$MaxSize }
    $cmbSize = New-ThemedDropdown $t 78 18 108 @('Original', '1920', '1280', '1024', '800') $sizeInitial
    $cardMirror.Controls.Add($cmbSize)

    $lblFps           = New-Object System.Windows.Forms.Label
    $lblFps.Text      = 'Max FPS'
    $lblFps.Location  = New-Object System.Drawing.Point(214, 22)
    $lblFps.Size      = New-Object System.Drawing.Size(56, 20)
    $lblFps.ForeColor = $t.TextDim
    $lblFps.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($lblFps)

    $cmbFps = New-ThemedDropdown $t 274 18 90 @('60', '30', '24') ([string]$Fps)
    $cardMirror.Controls.Add($cmbFps)

    $lblRate           = New-Object System.Windows.Forms.Label
    $lblRate.Text      = 'Bit rate'
    $lblRate.Location  = New-Object System.Drawing.Point(16, 56)
    $lblRate.Size      = New-Object System.Drawing.Size(58, 20)
    $lblRate.ForeColor = $t.TextDim
    $lblRate.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($lblRate)

    $cmbRate = New-ThemedDropdown $t 78 52 108 `
        @('8 Mbit', '16 Mbit', '24 Mbit', '32 Mbit') "$BitRate Mbit"
    $cardMirror.Controls.Add($cmbRate)

    # Both directions are real: more bits sharpen a scrolling page, but they also
    # load the phone's encoder, and in a game that costs responsiveness.
    $lblRateHint           = New-Object System.Windows.Forms.Label
    $lblRateHint.Text      = 'Higher is sharper, lower is smoother'
    $lblRateHint.Location  = New-Object System.Drawing.Point(196, 56)
    $lblRateHint.Size      = New-Object System.Drawing.Size(210, 20)
    $lblRateHint.ForeColor = $t.TextDim
    $lblRateHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblRateHint.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($lblRateHint)

    $chkAwake           = New-Object System.Windows.Forms.CheckBox
    $chkAwake.Text      = 'Keep device awake'
    $chkAwake.Location  = New-Object System.Drawing.Point(16, 88)
    $chkAwake.Size      = New-Object System.Drawing.Size(170, 24)
    $chkAwake.Checked   = $true
    $chkAwake.ForeColor = $t.Text
    # No FlatStyle Flat here: in dark mode that draws an empty white box with no
    # visible tick. The system renderer shows the state properly.
    $chkAwake.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($chkAwake)

    $chkScreenOff           = New-Object System.Windows.Forms.CheckBox
    $chkScreenOff.Text      = 'Phone screen off'
    $chkScreenOff.Location  = New-Object System.Drawing.Point(214, 88)
    $chkScreenOff.Size      = New-Object System.Drawing.Size(170, 24)
    $chkScreenOff.Checked   = [bool]$ScreenOff
    $chkScreenOff.ForeColor = $t.Text
    $chkScreenOff.BackColor = [System.Drawing.Color]::Transparent
    $cardMirror.Controls.Add($chkScreenOff)

    $btnMirror = New-FlatButton $t 'Start mirroring' 16 118 388 32 -Primary -FontSize 9.5
    $cardMirror.Controls.Add($btnMirror)

    $y += 160 + 18

    # --------------------------------------------------------- capture card
    $form.Controls.Add((New-SectionLabel $t 'Capture' ($pad + 2) $y))
    $y += 18
    $cardCapture = New-Card $t $pad $y $inner 86
    $form.Controls.Add($cardCapture)

    $btnShot   = New-FlatButton $t 'Screenshot'     16  18 120 32
    $btnRec    = New-FlatButton $t 'Start recording' 144 18 120 32
    $btnFolder = New-FlatButton $t 'Open folder'    272 18 120 32
    $cardCapture.Controls.AddRange(@($btnShot, $btnRec, $btnFolder))

    $lblCapture           = New-Object System.Windows.Forms.Label
    $lblCapture.Location  = New-Object System.Drawing.Point(16, 56)
    $lblCapture.Size      = New-Object System.Drawing.Size(388, 18)
    $lblCapture.ForeColor = $t.TextDim
    $lblCapture.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblCapture.BackColor = [System.Drawing.Color]::Transparent
    $lblCapture.Text      = 'Saved to Pictures\AndroidMirror. Recording stops by itself after 3 min.'
    $cardCapture.Controls.Add($lblCapture)

    $y += 86 + 18

    # -------------------------------------------------------- wireless card
    $form.Controls.Add((New-SectionLabel $t 'Wireless' ($pad + 2) $y))
    $y += 18
    $cardWireless = New-Card $t $pad $y $inner 86
    $form.Controls.Add($cardWireless)

    $btnWireless = New-FlatButton $t 'Go wireless'      16  18 184 32
    $btnUsb      = New-FlatButton $t 'Back to USB only' 220 18 184 32
    $cardWireless.Controls.AddRange(@($btnWireless, $btnUsb))

    $lblWireless           = New-Object System.Windows.Forms.Label
    $lblWireless.Location  = New-Object System.Drawing.Point(16, 56)
    $lblWireless.Size      = New-Object System.Drawing.Size(388, 18)
    $lblWireless.ForeColor = $t.TextDim
    $lblWireless.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblWireless.BackColor = [System.Drawing.Color]::Transparent
    $lblWireless.Text      = 'Leaves a debugging port open on your network until reboot.'
    $cardWireless.Controls.Add($lblWireless)

    $y += 86 + 18

    # ----------------------------------------------------- maintenance card
    $form.Controls.Add((New-SectionLabel $t 'Maintenance' ($pad + 2) $y))
    $y += 18
    $cardMaint = New-Card $t $pad $y $inner 64
    $form.Controls.Add($cardMaint)

    $btnUpdate = New-FlatButton $t 'Check for scrcpy update' 16  16 184 32
    $btnApk    = New-FlatButton $t 'Install APK ...'         220 16 184 32
    $cardMaint.Controls.AddRange(@($btnUpdate, $btnApk))

    $y += 64 + 14

    # ------------------------------------------------------------- statusbar
    $status           = New-Object System.Windows.Forms.Label
    $status.Text      = 'Starting ...'
    $status.AutoSize  = $false
    $status.Location  = New-Object System.Drawing.Point(($pad + 2), $y)
    $status.Size      = New-Object System.Drawing.Size($inner, 20)
    $status.TextAlign = 'MiddleLeft'
    $status.ForeColor = $t.Text
    $status.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($status)

    $lblVersion           = New-Object System.Windows.Forms.Label
    $lblVersion.Location  = New-Object System.Drawing.Point(($pad + 2), ($y + 20))
    $lblVersion.Size      = New-Object System.Drawing.Size($inner, 16)
    $lblVersion.ForeColor = $t.TextDim
    $lblVersion.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $lblVersion.BackColor = [System.Drawing.Color]::Transparent
    $lblVersion.AutoEllipsis = $true
    $form.Controls.Add($lblVersion)

    # Height from the layout rather than a guessed constant: getting this wrong
    # silently clips the last card and the status line off the bottom.
    $form.ClientSize = New-Object System.Drawing.Size(($inner + 2 * $pad), ($y + 44))

    # Down the left edge instead of centred. scrcpy puts its own window in the
    # middle of the screen, which landed exactly on top of a centred panel and
    # hid it completely the moment mirroring started.
    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(
        ($work.Left + 24),
        ($work.Top + [Math]::Max(0, [int](($work.Height - $form.Height) / 2))))

    # ------------------------------------------------------------ behaviour

    # One shared bag for everything the handlers touch. Closures capture variables
    # by value, so a hashtable reference is what makes mutations visible to all of
    # them; plain $script: variables would land in each closure's own module.
    $ui = @{
        Status           = $status
        Theme            = $t
        Busy             = $false
        AutoStartPending = [bool]$StartMirror
        Buttons          = @{
            Refresh = $btnRefresh; Mirror = $btnMirror; Shot = $btnShot; Rec = $btnRec
            Folder  = $btnFolder;  Wireless = $btnWireless; Usb = $btnUsb
            Update  = $btnUpdate;  Apk = $btnApk
        }
        Combos = @{ Size = $cmbSize; Fps = $cmbFps; Rate = $cmbRate }
        Checks = @{ Awake = $chkAwake; ScreenOff = $chkScreenOff }
    }

    # Must be a closure itself: a plain scriptblock resolves its variables in
    # whatever scope invokes it, and would not find $status from a handler.
    $setStatus = {
        param([string]$Text, $Color)
        # The window can now be closed mid action, because waiting no longer
        # freezes it. Whatever was running carries on for a moment afterwards
        # and must not touch controls that are already gone.
        if ($ui.Status.IsDisposed) { return }
        if ($null -eq $Color) { $Color = $ui.Theme.Text }
        $ui.Status.Text      = $Text
        $ui.Status.ForeColor = $Color
        $ui.Status.Refresh()
    }.GetNewClosure()

    $deviceButtons = @($btnMirror, $btnShot, $btnRec, $btnWireless, $btnUsb, $btnApk)

    # Force is for the callers that run inside runGuarded: that sets Busy before
    # handing over, so without it the poll guard below would turn their refresh
    # into a silent no-op - which is exactly what the Refresh button used to do.
    $refresh = {
        param([switch]$Force)
        if ($form.IsDisposed) { return }
        if ($ui.Busy -and -not $Force) { return }
        $info = Get-DeviceInfo
        if ($form.IsDisposed) { return }
        if ($info.Ready) {
            $battery = ''
            if ($null -ne $info.Battery) { $battery = "   $($info.Battery)%" }
            $lblDevice.Text  = $info.Model
            $dotState.Color  = $ui.Theme.Ok
            $extra = ''
            if ($info.Count -gt 1) { $extra = "   -   $($info.Count) devices, using this one" }
            $lblSerial.Text = "Android $($info.Android)$battery"

            # Dimmed while it is unremarkable, amber once it is warm, red when
            # the phone is hot enough to start throttling.
            if ($null -ne $info.Temperature) {
                $lblTemp.Text = '{0} {1}C' -f `
                    ([string]::Format([cultureinfo]::InvariantCulture, '{0:0.0}', $info.Temperature)),
                    ([char]0x00B0)
                if     ($info.Temperature -ge 45) { $lblTemp.ForeColor = $ui.Theme.Bad }
                elseif ($info.Temperature -ge 40) { $lblTemp.ForeColor = $ui.Theme.Warn }
                else                              { $lblTemp.ForeColor = $ui.Theme.TextDim }
            } else {
                $lblTemp.Text = ''
            }
            $lblSerialRest.Text = "-   $($info.Serial)$extra"

            # PreferredWidth rather than Width: it is the size the label will
            # take for the text just assigned, without waiting for a layout pass.
            $lblTemp.Left = $lblSerial.Left + $lblSerial.PreferredWidth + 10
            if ($lblTemp.Text) {
                $lblSerialRest.Left = $lblTemp.Left + $lblTemp.PreferredWidth + 10
            } else {
                $lblSerialRest.Left = $lblTemp.Left
            }
            foreach ($b in $deviceButtons) { $b.Enabled = $true }
        } else {
            $text = 'No device connected'
            $dotState.Color = $ui.Theme.Bad
            if ($info.Status -eq 'unauthorized') {
                $text = 'Not authorised'
                $dotState.Color = $ui.Theme.Warn
            }
            if ($info.Status -eq 'offline') { $text = 'Device offline' }
            $lblDevice.Text      = $text
            $lblSerial.Text      = 'Enable USB debugging and confirm the prompt on the phone.'
            $lblTemp.Text        = ''
            $lblSerialRest.Text  = ''
            foreach ($b in $deviceButtons) { $b.Enabled = $false }
        }
        $dot.Invalidate()
        # Draw the card now instead of leaving it to the message loop: the caller
        # goes on to block for seconds (auto start waits for scrcpy), and the
        # freshly set model and serial would sit there unpainted until it returns.
        $cardDevice.Refresh()
        # A running recording must stay stoppable even if the device blips.
        if (Test-RecordingActive) { $btnRec.Enabled = $true }
    }.GetNewClosure()

    $runGuarded = {
        param([scriptblock]$Work, [string]$Running)
        if ($ui.Busy -or $form.IsDisposed) { return }
        $ui.Busy = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        & $setStatus $Running $null
        try {
            & $Work
        } catch {
            & $setStatus "Failed: $($_.Exception.Message)" $ui.Theme.Bad
        } finally {
            if (-not $form.IsDisposed) { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
            $ui.Busy = $false
        }
    }.GetNewClosure()

    # The button follows the actual state of scrcpy, so it also flips back on its
    # own when the mirror window is closed by its own X or the cable comes out.
    $syncMirror = {
        if ($form.IsDisposed) { return }
        if (Test-MirrorActive) { $btnMirror.Text = 'Stop mirroring' }
        else                   { $btnMirror.Text = 'Start mirroring' }
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        & $runGuarded {
            Reset-BatteryCache
            & $refresh -Force
            & $setStatus 'Refreshed.' $null
        } 'Reading device ...'
    }.GetNewClosure())

    # One mirror window at a time. Pressing this repeatedly used to stack up a
    # new scrcpy on every click; now the second press closes the one that is up.
    $btnMirror.Add_Click({
        if (Test-MirrorActive) {
            & $runGuarded {
                Stop-Mirror
                & $syncMirror
                & $setStatus 'Mirroring stopped.' $null
            } 'Closing the mirror window ...'
            return
        }
        & $runGuarded {
            $size = 0
            if ($cmbSize.Tag -ne 'Original') { $size = [int]$cmbSize.Tag }
            # Tag reads like "24 Mbit"; scrcpy wants just the number.
            $rate = [int](($cmbRate.Tag -split ' ')[0])
            # Start-Mirror either comes back with a window on screen or raises.
            Start-Mirror -MaxSize $size -Fps ([int]$cmbFps.Tag) -BitRateMbit $rate `
                -StayAwake:$chkAwake.Checked -ScreenOff:$chkScreenOff.Checked | Out-Null
            & $syncMirror
            & $setStatus 'scrcpy started.' $null
        } 'Starting scrcpy ...'
    }.GetNewClosure())

    $btnShot.Add_Click({
        & $runGuarded {
            $file = Save-Screenshot
            & $setStatus "Saved $(Split-Path -Leaf $file)" $null
        } 'Taking screenshot ...'
    }.GetNewClosure())

    $btnRec.Add_Click({
        if (Test-RecordingActive) {
            & $runGuarded {
                $file = Stop-Recording
                $btnRec.Text = 'Start recording'
                & $setStatus "Saved $(Split-Path -Leaf $file)" $null
            } 'Stopping and pulling ...'
        } else {
            & $runGuarded {
                Start-Recording | Out-Null
                $btnRec.Text = 'Stop recording'
                & $setStatus 'Recording ...' $ui.Theme.Bad
            } 'Starting recording ...'
        }
    }.GetNewClosure())

    $btnFolder.Add_Click({
        Start-Process (Get-OutputDir) | Out-Null
    }.GetNewClosure())

    $btnWireless.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "This opens an adb port on your Wi-Fi network until the phone reboots or you press 'Back to USB only'." +
            [Environment]::NewLine + [Environment]::NewLine + 'Continue?',
            'Go wireless', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        & $runGuarded {
            $ip = Get-DeviceIp
            if (-not $ip) { throw 'No Wi-Fi address found. Is the phone on Wi-Fi?' }
            Invoke-AdbTarget @('tcpip', '5555') | Out-Null
            Wait-Pumped 2000
            $out = Invoke-Adb @('connect', "${ip}:5555")
            & $setStatus (($out -join ' ').Trim()) $null
        } 'Switching to wireless ...'
    }.GetNewClosure())

    $btnUsb.Add_Click({
        & $runGuarded {
            Invoke-Adb @('disconnect') | Out-Null
            Invoke-AdbTarget @('usb') | Out-Null
            Reset-CurrentSerial
            & $refresh -Force
            & $setStatus 'Back to USB only.' $null
        } 'Returning to USB ...'
    }.GetNewClosure())

    $btnUpdate.Add_Click({
        & $runGuarded {
            $upd = Test-ScrcpyUpdate
            if (-not $upd.Available) {
                & $setStatus "scrcpy is up to date ($($upd.Reason))." $null
                return
            }
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "scrcpy $($upd.Current) is installed, $($upd.Latest) is available." +
                [Environment]::NewLine + [Environment]::NewLine + 'Install it now?',
                'Update available', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { & $setStatus 'Update skipped.' $null; return }
            & $setStatus 'Installing update ...' $null
            Install-ScrcpyUpdate
            $lblVersion.Text = Get-ScrcpyPath
            & $setStatus 'Update installed.' $null
        } 'Checking for updates ...'
    }.GetNewClosure())

    $btnApk.Add_Click({
        $dialog        = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Android package (*.apk)|*.apk'
        $dialog.Title  = 'Pick an APK to install'
        if ($dialog.ShowDialog() -ne 'OK') { return }
        & $runGuarded {
            $out = Invoke-AdbTarget @('install', '-r', $dialog.FileName)
            & $setStatus (@($out | Where-Object { $_ -match '\S' })[-1]) $null
        } 'Installing APK ...'
    }.GetNewClosure())

    # screenrecord stops by itself after three minutes and the adb client exits
    # with it. Without noticing that, the button would keep offering "Stop
    # recording" for a file that is long finished and still on the phone.
    $checkRecording = {
        if ($ui.Busy -or $form.IsDisposed) { return }
        if (-not (Test-RecordingActive) -or -not (Test-RecordingFinished)) { return }
        & $runGuarded {
            $file = Stop-Recording
            $btnRec.Text = 'Start recording'
            & $setStatus "Recording hit the 3 min limit, saved $(Split-Path -Leaf $file)" $null
        } 'Recording finished, pulling ...'
    }.GetNewClosure()

    # -StartMirror fires once, and only when a device is genuinely ready, so
    # plugging the cable in after opening the panel still works.
    $tryAutoStart = {
        if (-not $ui.AutoStartPending) { return }
        # The button toggles now, so firing it while a mirror is already up would
        # close that one instead of opening anything.
        if (Test-MirrorActive) { $ui.AutoStartPending = $false; return }
        if ($ui.Busy -or -not (Get-CurrentSerial) -or -not $btnMirror.Enabled) { return }
        $ui.AutoStartPending = $false
        $btnMirror.PerformClick()
    }.GetNewClosure()

    # Poll so the panel notices a cable being plugged in or pulled.
    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({ & $refresh; & $syncMirror; & $checkRecording; & $tryAutoStart }.GetNewClosure())

    # Startup blocks for seconds: Get-DeviceInfo makes four adb round trips, and
    # -StartMirror then waits for scrcpy's window to exist. Doing that straight
    # from Shown means it all runs before the form has ever painted, and the
    # window sits there with white unpainted rectangles until it is over. A
    # one-shot timer hands control back to the message loop first - WM_PAINT is
    # dispatched ahead of WM_TIMER - so the window is fully drawn before it
    # goes busy.
    $boot          = New-Object System.Windows.Forms.Timer
    $boot.Interval = 1
    $boot.Add_Tick({
        $boot.Stop()
        # First statement, before anything that could throw: a form left at
        # opacity 0 would be invisible for good.
        $form.Opacity    = 1
        # From here on there is a message loop to pump, so waiting stops
        # freezing the window.
        Enable-UiPump
        $form.Cursor     = [System.Windows.Forms.Cursors]::WaitCursor
        $lblVersion.Text = Get-ScrcpyPath
        & $refresh
        if ($ui.AutoStartPending -and -not (Get-CurrentSerial)) {
            & $setStatus 'Waiting for a device, then mirroring starts by itself ...' $null
        } else {
            & $setStatus 'Ready.' $null
        }
        $timer.Start()
        & $tryAutoStart
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }.GetNewClosure())

    # Before the window is visible, otherwise the title bar flashes up white.
    $form.Add_HandleCreated({ Set-DarkTitleBar $form $ui.Theme.Dark }.GetNewClosure())

    $form.Add_Shown({
        & $setStatus 'Reading device ...' $null
        $form.Refresh()
        $boot.Start()
    }.GetNewClosure())

    $form.Add_FormClosing({
        $boot.Stop()
        $timer.Stop()
        # No loop left worth pumping once the window is going away.
        Disable-UiPump
        if (Test-RecordingActive) {
            # Do not leave a half-written file sitting on the phone.
            try { Stop-Recording | Out-Null } catch { }
        }
    }.GetNewClosure())

    # Exposed so -SelfTest can inspect the shared state without showing the window.
    $form.Tag = $ui
    return $form
}

# -------------------------------------------------------------------- main

$script:Tools = Resolve-Tools
if (-not $script:Tools) {
    $message = 'scrcpy was not found. Run setup.ps1 first.'
    if ($SelfTest) { throw $message }
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Android Control Panel', 'OK', 'Error')
    exit 1
}

if ($SelfTest) {
    Write-Host "`n=== Self test ===" -ForegroundColor Cyan
    Write-Host ("scrcpy     : {0}" -f $script:Tools.Scrcpy)
    Write-Host ("adb        : {0}" -f $script:Tools.Adb)
    $devices = @(Get-Devices)
    Write-Host ("devices    : {0}" -f (($devices | ForEach-Object { "$($_.Serial)=$($_.State)" }) -join ', '))
    $info = Get-DeviceInfo
    Write-Host ("info       : ready=$($info.Ready) model='$($info.Model)' android=$($info.Android) battery=$($info.Battery) temp=$($info.Temperature) count=$($info.Count)")
    Write-Host ("output dir : {0}" -f (Get-OutputDir))
    $upd = Test-ScrcpyUpdate
    Write-Host ("update     : available=$($upd.Available) reason='$($upd.Reason)'")
    if ($info.Ready) { Write-Host ("wlan ip    : {0}" -f (Get-DeviceIp)) }

    # A GUI cannot be clicked headlessly, so the one path that used to lie about
    # its outcome is checked here: scrcpy against a device that does not exist
    # must come back as an error, not as "started".
    $keepSerial = $script:Serial
    $script:Serial = 'no-such-device'
    try {
        [void](Start-Mirror -MaxSize 0 -Fps 0)
        Write-Host 'failure    : NOT REPORTED - scrcpy died and nobody noticed' -ForegroundColor Red
    } catch {
        Write-Host ("failure    : reported as '{0}'" -f $_.Exception.Message)
    }
    $script:Serial = $keepSerial

    Write-Host '--- building the form (not shown) ---' -ForegroundColor Cyan
    $form = New-Panel
    $ui   = $form.Tag
    Write-Host ("form       : '{0}' {1}x{2}" -f $form.Text, $form.ClientSize.Width, $form.ClientSize.Height)
    Write-Host ("theme      : {0}   accent #{1:X2}{2:X2}{3:X2}" -f `
        $(if ($ui.Theme.Dark) { 'dark' } else { 'light' }), $ui.Theme.Accent.R, $ui.Theme.Accent.G, $ui.Theme.Accent.B)

    # Walk the cards rather than GroupBoxes: the layout uses plain panels now.
    $cards = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] })
    $labels = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Font.Bold })
    Write-Host ("sections   : {0}" -f (($labels | ForEach-Object { $_.Text }) -join ', '))
    Write-Host ("cards      : {0}" -f $cards.Count)
    Write-Host ("buttons    : {0}" -f (($ui.Buttons.Values | ForEach-Object { $_.Text }) -join ', '))

    # Prove the -MaxSize/-Fps/-ScreenOff parameters actually reached the controls.
    $picked = "$($ui.Combos.Size.Tag) / $($ui.Combos.Fps.Tag) fps / $($ui.Combos.Rate.Tag)"
    $ticked = ($ui.Checks.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value.Checked)" }) -join ', '
    Write-Host ("mirror set : $picked   [$ticked]")
    Write-Host ("auto start : {0}" -f $ui.AutoStartPending)
    $form.Dispose()
    Write-Host "OK`n" -ForegroundColor Green
    return
}

Hide-OwnConsole
if (-not (Request-SingleInstance)) { exit 0 }
[void][System.Windows.Forms.Application]::Run((New-Panel))
