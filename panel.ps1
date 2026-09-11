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

$script:Tools        = $null
$script:Serial       = $null
$script:RecordRemote = $null
$script:RecordProc   = $null
$script:RecordStamp  = $null
$script:Busy         = $false

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
    # Read before waiting: a full pipe buffer would otherwise deadlock us.
    $stdout = $proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { }
    }
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
    param([string]$FilePath, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.Arguments       = ConvertTo-CommandLine $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    return [System.Diagnostics.Process]::Start($psi)
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
            Model = $null; Android = $null; Battery = $null; Count = $all.Count
        }
    }

    # Keep the current pick if it is still attached, otherwise take the first.
    if (-not $script:Serial -or -not ($ready.Serial -contains $script:Serial)) {
        $script:Serial = $ready[0].Serial
    }

    $model   = ((Invoke-AdbTarget @('shell', 'getprop', 'ro.product.model')) -join '').Trim()
    $android = ((Invoke-AdbTarget @('shell', 'getprop', 'ro.build.version.release')) -join '').Trim()
    $battery = $null
    foreach ($line in (Invoke-AdbTarget @('shell', 'dumpsys', 'battery'))) {
        if ($line -match '^\s*level:\s*(\d+)') { $battery = [int]$Matches[1] }
    }

    return [pscustomobject]@{
        Ready = $true; Status = 'device'; Serial = $script:Serial
        Model = $model; Android = $android; Battery = $battery; Count = $ready.Count
    }
}

# Closures created with GetNewClosure() live in their own module, where $script:
# resolves to that module rather than to this file. Script-scope state is therefore
# read through functions, which do resolve correctly from inside a closure.
function Get-CurrentSerial { return $script:Serial }
function Reset-CurrentSerial { $script:Serial = $null }
function Test-RecordingActive { return [bool]$script:RecordRemote }
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
    # screenrecord only finalises the MP4 container on SIGINT, so signal the
    # process on the device instead of killing the adb client here.
    Invoke-AdbTarget @('shell', 'pkill', '-INT', 'screenrecord') | Out-Null
    Start-Sleep -Seconds 3
    if ($script:RecordProc -and -not $script:RecordProc.HasExited) {
        try { $script:RecordProc.Kill() } catch { }
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
    param([int]$MaxSize, [int]$Fps, [switch]$StayAwake, [switch]$ScreenOff)
    $argList = @()
    if ($script:Serial) { $argList += @('-s', $script:Serial) }
    if ($MaxSize -gt 0) { $argList += "--max-size=$MaxSize" }
    if ($Fps -gt 0)     { $argList += "--max-fps=$Fps" }
    if ($StayAwake)     { $argList += '--stay-awake' }
    if ($ScreenOff)     { $argList += @('--turn-screen-off', '--power-off-on-close') }
    # Plain value: ConvertTo-CommandLine quotes it because of the space. Quoting it
    # here as well would put the quotes into the title scrcpy displays.
    $argList += '--window-title=Android Mirror'

    # CreateNoWindow suppresses scrcpy's console; its own SDL window is unaffected
    # and is what we wait for below.
    $proc = Start-Hidden -FilePath $script:Tools.Scrcpy -Arguments $argList

    # Inheriting aside, scrcpy needs a moment before it owns a window. Wait for it
    # and pull it to the front, rather than trusting the show state alone.
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        if ($proc.HasExited) { break }
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [void][PanelNative]::ShowWindow($proc.MainWindowHandle, 9)   # SW_RESTORE
            [void][PanelNative]::SetForegroundWindow($proc.MainWindowHandle)
            break
        }
    }
    return $proc
}

# --------------------------------------------------------------------- UI

function New-Panel {
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'Android Control Panel'
    $form.ClientSize      = New-Object System.Drawing.Size(470, 545)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

    # -- status bar ------------------------------------------------------
    $status              = New-Object System.Windows.Forms.Label
    $status.Text         = '  Starting ...'
    $status.AutoSize     = $false
    $status.Size         = New-Object System.Drawing.Size(454, 22)
    $status.Location     = New-Object System.Drawing.Point(8, 516)
    $status.TextAlign    = 'MiddleLeft'
    $status.BorderStyle  = 'Fixed3D'
    $form.Controls.Add($status)

    # One shared bag for everything the handlers touch. Closures capture variables
    # by value, so a hashtable reference is what makes mutations visible to all of
    # them; plain $script: variables would land in each closure's own module.
    $ui = @{
        Status           = $status
        Busy             = $false
        AutoStartPending = [bool]$StartMirror
    }

    # Must be a closure itself: a plain scriptblock resolves its variables in
    # whatever scope invokes it, and would not find $status from a handler.
    $setStatus = {
        param([string]$Text, $Color)
        if ($null -eq $Color) { $Color = [System.Drawing.SystemColors]::ControlText }
        $ui.Status.Text      = "  $Text"
        $ui.Status.ForeColor = $Color
        $ui.Status.Refresh()
    }.GetNewClosure()

    # -- device ----------------------------------------------------------
    $grpDevice          = New-Object System.Windows.Forms.GroupBox
    $grpDevice.Text     = ' Device '
    $grpDevice.Location = New-Object System.Drawing.Point(8, 6)
    $grpDevice.Size     = New-Object System.Drawing.Size(454, 78)
    $form.Controls.Add($grpDevice)

    $lblDevice          = New-Object System.Windows.Forms.Label
    $lblDevice.Location = New-Object System.Drawing.Point(12, 22)
    $lblDevice.Size     = New-Object System.Drawing.Size(320, 20)
    $lblDevice.Font     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $grpDevice.Controls.Add($lblDevice)

    $lblSerial           = New-Object System.Windows.Forms.Label
    $lblSerial.Location  = New-Object System.Drawing.Point(12, 46)
    $lblSerial.Size      = New-Object System.Drawing.Size(320, 20)
    $lblSerial.ForeColor = [System.Drawing.SystemColors]::GrayText
    $grpDevice.Controls.Add($lblSerial)

    $btnRefresh          = New-Object System.Windows.Forms.Button
    $btnRefresh.Text     = 'Refresh'
    $btnRefresh.Location = New-Object System.Drawing.Point(344, 30)
    $btnRefresh.Size     = New-Object System.Drawing.Size(96, 28)
    $grpDevice.Controls.Add($btnRefresh)

    # -- mirror ----------------------------------------------------------
    $grpMirror          = New-Object System.Windows.Forms.GroupBox
    $grpMirror.Text     = ' Mirror '
    $grpMirror.Location = New-Object System.Drawing.Point(8, 90)
    $grpMirror.Size     = New-Object System.Drawing.Size(454, 118)
    $form.Controls.Add($grpMirror)

    $lblSize          = New-Object System.Windows.Forms.Label
    $lblSize.Text     = 'Max size'
    $lblSize.Location = New-Object System.Drawing.Point(12, 28)
    $lblSize.Size     = New-Object System.Drawing.Size(60, 20)
    $grpMirror.Controls.Add($lblSize)

    $cmbSize               = New-Object System.Windows.Forms.ComboBox
    $cmbSize.DropDownStyle = 'DropDownList'
    $cmbSize.Location      = New-Object System.Drawing.Point(76, 24)
    $cmbSize.Size          = New-Object System.Drawing.Size(110, 24)
    [void]$cmbSize.Items.AddRange(@('Original', '1920', '1280', '1024', '800'))
    $cmbSize.SelectedIndex = 0
    if ($MaxSize -gt 0) {
        $index = $cmbSize.Items.IndexOf([string]$MaxSize)
        if ($index -ge 0) { $cmbSize.SelectedIndex = $index }
    }
    $grpMirror.Controls.Add($cmbSize)

    $lblFps          = New-Object System.Windows.Forms.Label
    $lblFps.Text     = 'Max FPS'
    $lblFps.Location = New-Object System.Drawing.Point(206, 28)
    $lblFps.Size     = New-Object System.Drawing.Size(58, 20)
    $grpMirror.Controls.Add($lblFps)

    $cmbFps               = New-Object System.Windows.Forms.ComboBox
    $cmbFps.DropDownStyle = 'DropDownList'
    $cmbFps.Location      = New-Object System.Drawing.Point(268, 24)
    $cmbFps.Size          = New-Object System.Drawing.Size(80, 24)
    [void]$cmbFps.Items.AddRange(@('60', '30', '24'))
    $cmbFps.SelectedIndex = 0
    $fpsIndex = $cmbFps.Items.IndexOf([string]$Fps)
    if ($fpsIndex -ge 0) { $cmbFps.SelectedIndex = $fpsIndex }
    $grpMirror.Controls.Add($cmbFps)

    $chkAwake          = New-Object System.Windows.Forms.CheckBox
    $chkAwake.Text     = 'Keep device awake'
    $chkAwake.Location = New-Object System.Drawing.Point(14, 56)
    $chkAwake.Size     = New-Object System.Drawing.Size(170, 22)
    $chkAwake.Checked  = $true
    $grpMirror.Controls.Add($chkAwake)

    $chkScreenOff          = New-Object System.Windows.Forms.CheckBox
    $chkScreenOff.Text     = 'Phone screen off'
    $chkScreenOff.Location = New-Object System.Drawing.Point(206, 56)
    $chkScreenOff.Size     = New-Object System.Drawing.Size(170, 22)
    $chkScreenOff.Checked  = [bool]$ScreenOff
    $grpMirror.Controls.Add($chkScreenOff)

    $btnMirror          = New-Object System.Windows.Forms.Button
    $btnMirror.Text     = 'Start mirroring'
    $btnMirror.Location = New-Object System.Drawing.Point(12, 82)
    $btnMirror.Size     = New-Object System.Drawing.Size(428, 30)
    $grpMirror.Controls.Add($btnMirror)

    # -- capture ---------------------------------------------------------
    $grpCapture          = New-Object System.Windows.Forms.GroupBox
    $grpCapture.Text     = ' Capture '
    $grpCapture.Location = New-Object System.Drawing.Point(8, 214)
    $grpCapture.Size     = New-Object System.Drawing.Size(454, 92)
    $form.Controls.Add($grpCapture)

    $btnShot          = New-Object System.Windows.Forms.Button
    $btnShot.Text     = 'Screenshot'
    $btnShot.Location = New-Object System.Drawing.Point(12, 24)
    $btnShot.Size     = New-Object System.Drawing.Size(136, 30)
    $grpCapture.Controls.Add($btnShot)

    $btnRec          = New-Object System.Windows.Forms.Button
    $btnRec.Text     = 'Start recording'
    $btnRec.Location = New-Object System.Drawing.Point(158, 24)
    $btnRec.Size     = New-Object System.Drawing.Size(136, 30)
    $grpCapture.Controls.Add($btnRec)

    $btnFolder          = New-Object System.Windows.Forms.Button
    $btnFolder.Text     = 'Open folder'
    $btnFolder.Location = New-Object System.Drawing.Point(304, 24)
    $btnFolder.Size     = New-Object System.Drawing.Size(136, 30)
    $grpCapture.Controls.Add($btnFolder)

    $lblCapture           = New-Object System.Windows.Forms.Label
    $lblCapture.Location  = New-Object System.Drawing.Point(12, 60)
    $lblCapture.Size      = New-Object System.Drawing.Size(428, 20)
    $lblCapture.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblCapture.Text      = 'Saved to Pictures\AndroidMirror. Recording stops by itself after 3 min.'
    $grpCapture.Controls.Add($lblCapture)

    # -- wireless --------------------------------------------------------
    $grpWireless          = New-Object System.Windows.Forms.GroupBox
    $grpWireless.Text     = ' Wireless '
    $grpWireless.Location = New-Object System.Drawing.Point(8, 312)
    $grpWireless.Size     = New-Object System.Drawing.Size(454, 92)
    $form.Controls.Add($grpWireless)

    $btnWireless          = New-Object System.Windows.Forms.Button
    $btnWireless.Text     = 'Go wireless'
    $btnWireless.Location = New-Object System.Drawing.Point(12, 24)
    $btnWireless.Size     = New-Object System.Drawing.Size(210, 30)
    $grpWireless.Controls.Add($btnWireless)

    $btnUsb          = New-Object System.Windows.Forms.Button
    $btnUsb.Text     = 'Back to USB only'
    $btnUsb.Location = New-Object System.Drawing.Point(230, 24)
    $btnUsb.Size     = New-Object System.Drawing.Size(210, 30)
    $grpWireless.Controls.Add($btnUsb)

    $lblWireless           = New-Object System.Windows.Forms.Label
    $lblWireless.Location  = New-Object System.Drawing.Point(12, 60)
    $lblWireless.Size      = New-Object System.Drawing.Size(428, 20)
    $lblWireless.ForeColor = [System.Drawing.SystemColors]::GrayText
    $lblWireless.Text      = 'Leaves a debugging port open on your network until reboot.'
    $grpWireless.Controls.Add($lblWireless)

    # -- maintenance -----------------------------------------------------
    $grpMaint          = New-Object System.Windows.Forms.GroupBox
    $grpMaint.Text     = ' Maintenance '
    $grpMaint.Location = New-Object System.Drawing.Point(8, 410)
    $grpMaint.Size     = New-Object System.Drawing.Size(454, 68)
    $form.Controls.Add($grpMaint)

    $btnUpdate          = New-Object System.Windows.Forms.Button
    $btnUpdate.Text     = 'Check for scrcpy update'
    $btnUpdate.Location = New-Object System.Drawing.Point(12, 24)
    $btnUpdate.Size     = New-Object System.Drawing.Size(210, 30)
    $grpMaint.Controls.Add($btnUpdate)

    $btnApk          = New-Object System.Windows.Forms.Button
    $btnApk.Text     = 'Install APK ...'
    $btnApk.Location = New-Object System.Drawing.Point(230, 24)
    $btnApk.Size     = New-Object System.Drawing.Size(210, 30)
    $grpMaint.Controls.Add($btnApk)

    $lblVersion           = New-Object System.Windows.Forms.Label
    $lblVersion.Location  = New-Object System.Drawing.Point(8, 486)
    $lblVersion.Size      = New-Object System.Drawing.Size(454, 20)
    $lblVersion.ForeColor = [System.Drawing.SystemColors]::GrayText
    $form.Controls.Add($lblVersion)

    # -- behaviour -------------------------------------------------------

    $deviceButtons = @($btnMirror, $btnShot, $btnRec, $btnWireless, $btnUsb, $btnApk)

    $refresh = {
        if ($ui.Busy) { return }
        $info = Get-DeviceInfo
        if ($info.Ready) {
            $battery = ''
            if ($null -ne $info.Battery) { $battery = "  -  $($info.Battery)%" }
            $lblDevice.Text      = "$($info.Model)  -  Android $($info.Android)$battery"
            $lblDevice.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 60)
            $extra = ''
            if ($info.Count -gt 1) { $extra = "   ($($info.Count) devices, using this one)" }
            $lblSerial.Text = "$($info.Serial)$extra"
            foreach ($b in $deviceButtons) { $b.Enabled = $true }
        } else {
            $text = 'No device connected'
            if ($info.Status -eq 'unauthorized') { $text = 'Device attached but not authorised' }
            if ($info.Status -eq 'offline')      { $text = 'Device offline - replug the cable' }
            $lblDevice.Text      = $text
            $lblDevice.ForeColor = [System.Drawing.Color]::FromArgb(170, 60, 0)
            $lblSerial.Text      = 'Enable USB debugging and confirm the prompt on the phone.'
            foreach ($b in $deviceButtons) { $b.Enabled = $false }
        }
        # A running recording must stay stoppable even if the device blips.
        if (Test-RecordingActive) { $btnRec.Enabled = $true }
    }.GetNewClosure()

    $runGuarded = {
        param([scriptblock]$Work, [string]$Running)
        if ($ui.Busy) { return }
        $ui.Busy = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        & $setStatus $Running $null
        try {
            & $Work
        } catch {
            & $setStatus "Failed: $($_.Exception.Message)" ([System.Drawing.Color]::FromArgb(170, 30, 30))
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $ui.Busy = $false
        }
    }.GetNewClosure()

    $btnRefresh.Add_Click({
        & $runGuarded { & $refresh; & $setStatus 'Refreshed.' $null } 'Reading device ...'
    }.GetNewClosure())

    $btnMirror.Add_Click({
        & $runGuarded {
            $size = 0
            if ($cmbSize.SelectedItem -ne 'Original') { $size = [int]$cmbSize.SelectedItem }
            Start-Mirror -MaxSize $size -Fps ([int]$cmbFps.SelectedItem) `
                -StayAwake:$chkAwake.Checked -ScreenOff:$chkScreenOff.Checked | Out-Null
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
                & $setStatus 'Recording ...' ([System.Drawing.Color]::FromArgb(170, 30, 30))
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
            Start-Sleep -Seconds 2
            $out = Invoke-Adb @('connect', "${ip}:5555")
            & $setStatus (($out -join ' ').Trim()) $null
        } 'Switching to wireless ...'
    }.GetNewClosure())

    $btnUsb.Add_Click({
        & $runGuarded {
            Invoke-Adb @('disconnect') | Out-Null
            Invoke-AdbTarget @('usb') | Out-Null
            Reset-CurrentSerial
            & $refresh
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
            $lblVersion.Text = "  scrcpy: $(Get-ScrcpyPath)"
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

    # -StartMirror fires once, and only when a device is genuinely ready, so
    # plugging the cable in after opening the panel still works.
    $tryAutoStart = {
        if (-not $ui.AutoStartPending) { return }
        if ($ui.Busy -or -not (Get-CurrentSerial) -or -not $btnMirror.Enabled) { return }
        $ui.AutoStartPending = $false
        $btnMirror.PerformClick()
    }.GetNewClosure()

    # Poll so the panel notices a cable being plugged in or pulled.
    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({ & $refresh; & $tryAutoStart }.GetNewClosure())

    $form.Add_Shown({
        $lblVersion.Text = "  scrcpy: $(Get-ScrcpyPath)"
        & $refresh
        if ($ui.AutoStartPending -and -not (Get-CurrentSerial)) {
            & $setStatus 'Waiting for a device, then mirroring starts by itself ...' $null
        } else {
            & $setStatus 'Ready.' $null
        }
        $timer.Start()
        & $tryAutoStart
    }.GetNewClosure())

    $form.Add_FormClosing({
        $timer.Stop()
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
    Write-Host ("info       : ready=$($info.Ready) model='$($info.Model)' android=$($info.Android) battery=$($info.Battery) count=$($info.Count)")
    Write-Host ("output dir : {0}" -f (Get-OutputDir))
    $upd = Test-ScrcpyUpdate
    Write-Host ("update     : available=$($upd.Available) reason='$($upd.Reason)'")
    if ($info.Ready) { Write-Host ("wlan ip    : {0}" -f (Get-DeviceIp)) }

    Write-Host '--- building the form (not shown) ---' -ForegroundColor Cyan
    $form = New-Panel
    $groups = @($form.Controls | Where-Object { $_ -is [System.Windows.Forms.GroupBox] })
    Write-Host ("form       : '{0}' {1}x{2}" -f $form.Text, $form.ClientSize.Width, $form.ClientSize.Height)
    Write-Host ("groups     : {0}" -f (($groups | ForEach-Object { $_.Text.Trim() }) -join ', '))
    $buttons = @()
    foreach ($g in $groups) {
        $buttons += @($g.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] } | ForEach-Object { $_.Text })
    }
    Write-Host ("buttons    : {0}" -f ($buttons -join ', '))

    # Prove the -MaxSize/-Fps/-ScreenOff parameters actually reached the controls.
    $mirror  = $groups | Where-Object { $_.Text.Trim() -eq 'Mirror' }
    $combos  = @($mirror.Controls | Where-Object { $_ -is [System.Windows.Forms.ComboBox] })
    $checks  = @($mirror.Controls | Where-Object { $_ -is [System.Windows.Forms.CheckBox] })
    $picked  = ($combos | ForEach-Object { $_.SelectedItem }) -join ' / '
    $ticked  = ($checks | ForEach-Object { "$($_.Text)=$($_.Checked)" }) -join ', '
    Write-Host ("mirror set : $picked   [$ticked]")
    Write-Host ("auto start : {0}" -f $form.Tag.AutoStartPending)
    $form.Dispose()
    Write-Host "OK`n" -ForegroundColor Green
    return
}

Hide-OwnConsole
[void][System.Windows.Forms.Application]::Run((New-Panel))
