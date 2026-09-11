# android-mirror-windows

Mirror an Android phone onto a Windows PC and control it with mouse and keyboard —
like an emulator, except it is the real device.

These are two small batch launchers and a setup script around
[scrcpy](https://github.com/Genymobile/scrcpy). scrcpy does all the real work;
this repo just removes the "which flags did I need again?" step and makes
double-clicking an icon enough.

No app on the phone, no root, no account, no ads.

## What you get

| File | Purpose |
| --- | --- |
| `setup.ps1` | Installs scrcpy via winget, starts the adb server, creates desktop shortcuts |
| `mirror.bat` | Checks for a scrcpy update, waits for a device, then mirrors it |
| `mirror-dark.bat` | Same, but keeps the phone screen off while you use it from the PC |

Both launchers pass any extra arguments straight through to scrcpy, so
`mirror.bat --max-size=1024` works.

## Requirements

- Windows 10/11 with `winget` (ships as "App Installer")
- An Android 5.0+ device
- A USB **data** cable — many charge-only cables have no data lines and are the
  single most common reason nothing shows up

## Install

```powershell
git clone https://github.com/philip-stack/android-mirror-windows.git
cd android-mirror-windows
.\setup.ps1
```

If PowerShell blocks the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` is safe to run repeatedly — it skips the install if scrcpy is already
current. Use `-NoShortcut` to skip the desktop shortcuts.

Manual alternative, if you would rather not run the script:

```powershell
winget install --id Genymobile.scrcpy -e
```

adb is bundled with scrcpy, so there is nothing else to install.

## Enable USB debugging on the phone

1. **Settings → About phone** → tap **Build number** seven times
2. **Settings → System → Developer options** → enable **USB debugging**
3. Plug in the cable and confirm **Allow USB debugging?** on the phone
   (tick *Always allow from this computer*)

Menu paths are for stock Android/Pixel. Samsung, Xiaomi and others move
*Build number* around slightly, but the seven-tap trick is the same everywhere.

## Usage

Double-click `mirror.bat`, or run it from a terminal. It waits for a device, so
you can start it before plugging the phone in.

`mirror-dark.bat` adds `--turn-screen-off --power-off-on-close`: the phone screen
goes dark immediately, you keep full control from the PC, and the screen stays off
when you close the window. Touching the phone, or its fingerprint sensor, wakes the
screen again — press `Alt+Shift+O` to turn it back off.

Note that a dark screen is not a locked screen. The device is unlocked, just not
lit.

## Update check

`mirror.bat` checks for a newer scrcpy release on each start and asks before
installing anything:

```
  New version available:  4.1  ->  4.2
  Update now? [Y/N]  (20s, default: No)
```

Answering `N`, pressing Enter or letting the 20 second timeout expire carries on
with the installed version, so the launcher never blocks. Answering `Y` runs
`winget upgrade` and then re-resolves the path, picking up the new version in
the same run.

The check costs about a second. It deliberately uses `winget list
--upgrade-available` rather than `winget upgrade`, because the latter would
install the update immediately instead of asking. Detection keys on the package
id appearing in the output, not on any message text, so it works regardless of
the display language.

## Shortcuts

`MOD` is left `Alt` or left `Super` by default (`--shortcut-mod` changes it).

| Shortcut | Action |
| --- | --- |
| `MOD+f` / `F11` | Fullscreen |
| `MOD+h` | Home |
| `MOD+b` / right-click | Back |
| `MOD+s` | App switcher |
| `MOD+n` | Expand notifications |
| `MOD+o` | Turn phone screen off (keep mirroring) |
| `MOD+Shift+o` | Turn phone screen on |
| `MOD+p` | Power button |
| `MOD+r` | Rotate device screen |
| `MOD+w` | Resize window, drop black borders |
| `MOD+c` / `MOD+v` | Copy from / paste to device clipboard |
| `MOD+q` | Quit |

Drag an APK onto the window to install it; drag any other file to push it to the
device.

## Useful flags

| Flag | Effect |
| --- | --- |
| `--max-size=1024` | Cap resolution — the main lever for latency |
| `--max-fps=30` | Cap frame rate, useful over Wi-Fi |
| `--stay-awake` (`-w`) | Do not let the device sleep while plugged in |
| `--turn-screen-off` (`-S`) | Phone screen off from the start |
| `--power-off-on-close` | Leave the screen off when scrcpy exits |
| `--no-audio` | Skip audio forwarding |
| `--record=out.mp4` | Record the session |

`scrcpy --help` lists all of them.

## Wireless

USB is lower latency and needs no setup, so the launchers target it. Wireless is
a few extra commands.

Enable **Wireless debugging** in Developer options, then pair once:

```powershell
adb pair 192.168.x.x:PORT     # port and code from "Pair device with pairing code"
adb connect 192.168.x.x:PORT  # port from the Wireless debugging main screen (different port)
mirror.bat
```

Or, while still connected by cable, switch over in one step and unplug:

```powershell
adb tcpip 5555
scrcpy --tcpip
```

Expect noticeably more latency than USB. `--max-size=1024 --max-fps=30` helps.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `adb devices` lists nothing | Charge-only cable, or USB debugging is off |
| Device shows as `unauthorized` | Confirm the prompt on the phone; if it never appears, run `adb kill-server`, then replug |
| Device shows as `offline` | Unplug, replug, and re-confirm the prompt |
| Windows does not detect the phone | Install the Google USB driver: `winget install Google.PlatformTools` |
| `scrcpy` not found in a new terminal | winget adds it to PATH — open a new shell, or sign out and back in |
| Laggy over Wi-Fi | Lower `--max-size` and `--max-fps` |

## Credits

All credit to [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0).
This repo only wraps it.

## License

MIT — see [LICENSE](LICENSE).
