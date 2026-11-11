# BluetoothSwitcher

A lightweight Windows 11 app that switches a PC between two Bluetooth adapters with one click:

- **Upstairs** - the internal adapter.
- **Downstairs** - an external USB adapter near the TV.

Windows only supports one active Bluetooth adapter at a time, so switching means disabling
one adapter and enabling the other, then verifying the result.

**Status: switching is validated on real hardware in both directions with the script
(2026-11-10). The WinUI 3 app and its installer are built and tested without hardware;
switching through the installed app has not been run on real hardware yet.**

## Install, update, uninstall

The app must be installed in a protected folder before it will switch adapters, because it
starts the switch script as administrator (see [Security](#security)).

**1. Build the package** from a normal terminal. No administrator rights; needs the .NET 10 SDK.
It runs the tests, builds the app, and writes `dist\BluetoothSwitcher`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Package.ps1
```

**2. Install** from a PowerShell opened **as administrator**. The script refuses to run
unelevated and never requests elevation itself. Add `-WhatIf` to preview without changing anything:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\dev\personal\BluetoothSwitcher\installer\Install.ps1"
```

It copies the package to `C:\Program Files\BluetoothSwitcher`, verifies every file, makes
Administrators the owner, sets the permissions (SYSTEM and Administrators full control, Users
read and run, nothing inherited), and creates the all-users Start menu shortcut
**BluetoothSwitcher**. It does not start the app, touch any Bluetooth device, or add a
service, scheduled task, registry entry, or auto-start item.

**3. Run** BluetoothSwitcher from the Start menu. The app runs without administrator rights;
Windows asks for approval once per switch.

**Update:** repeat steps 1 and 2. Close the app first.

**Uninstall** from a PowerShell opened as administrator (add `-RemoveLogs` to also delete the
switch logs in `%LOCALAPPDATA%\BluetoothSwitcher`). Bluetooth adapters are left as they are:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\BluetoothSwitcher\Uninstall.ps1"
```

**Check an installed copy** (no window; exit code 0 means it may switch, 14 means the folder
is not protected, 13 means the script does not match the app):

```
"C:\Program Files\BluetoothSwitcher\BluetoothSwitcher.exe" --verify-install
```

## Quick commands

Read-only status check (no admin rights, changes nothing):

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\poc\Get-AdapterStatus.ps1
```

Tests (no admin rights, no real device is changed; the switching logic runs against a
simulated `pnputil`):

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Build and run the app (needs the .NET 10 SDK; the app itself runs unelevated):

```
dotnet build src\BluetoothSwitcher.App -c Release
```

```
src\BluetoothSwitcher.App\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64\BluetoothSwitcher.exe
```

Add `--demo` to run against simulated adapters (nothing real is read or changed). Demo
variants: `--demo=fail`, `--demo=die`, `--demo=decline`, `--demo=lie`.

A development build shows the real adapters but has switching disabled, because its folder is
not protected. `--dev` lifts that for development only; the script's hash is still verified.

Manual switch from an elevated PowerShell (dry run unless `-Execute` is given):

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\poc\Switch-Adapter.ps1 -Target Upstairs -Execute
```

## v1 scope

- Identify both adapters reliably (not by fixed instance ID).
- Show each adapter's current status.
- One-click switch upstairs <-> downstairs.
- Verify the switch against real adapter state, report clear errors, roll back on failure.
- Compact, modern Windows 11 window: dark mode, Fluent styling, clear switching feedback.

Out of scope for v1: system tray, background services, DualSense button-combo switching,
automatic controller reconnection.

## Architecture

```
BluetoothSwitcher.exe (WinUI 3, NOT elevated)
  |
  |-- status:  pnputil /enum-devices /connected /class Bluetooth /format xml   (read-only)
  |
  '-- switch:  powershell.exe -File Switch-Adapter.ps1 -Target <X> -Execute -LogPath <file>
               started elevated (one UAC prompt per switch), hidden window
```

- **The UI never runs elevated.** It only reads device state.
- **The switching engine is the validated PowerShell script**, unchanged. The app starts it
  elevated, follows its log file for progress, and waits for it to exit.
- **Success is decided by hardware state, not by the script.** After the script exits, the app
  re-reads the adapters. It reports success only if the target is started with a Bluetooth
  enumerator running and the other adapter is disabled. The script's exit code and log are
  used only to explain a failure.
- **Cancellation.** A switch can be cancelled before the elevated script starts (declining the
  UAC prompt). Once the script is running it is never killed, because stopping it between
  "disable" and "enable" would leave Bluetooth off. Closing the window during a switch is
  blocked for the same reason.
- **Unexpected termination.** If the script dies or times out, the app re-reads the adapters
  and shows what is actually true, with recovery commands if no adapter is active.

### Security

The UAC prompt only says "Windows PowerShell", so it cannot show which script is being
approved. Two checks, made immediately before every prompt, tie the approval to the script
that was built and installed:

- **Protected location.** The script, its folder, and the parent folder must be owned by, and
  writable only by, SYSTEM, Administrators or TrustedInstaller. Otherwise the app refuses to
  switch. This is what stops another program from swapping the script.
- **SHA-256 match.** The build embeds the hash of `poc/Switch-Adapter.ps1` in the app. A script
  with any other hash is not started. This catches a mismatched or damaged copy.

PowerShell is started by its full System32 path with `-NoProfile`. There is no background
service, scheduled task, or stored credential. `package.sha256` in the package only detects a
damaged or incomplete copy; it is not a signature.

### Projects

| Path | Purpose |
|---|---|
| `poc/Switch-Adapter.ps1` | Switching engine (disable, verify, enable, verify, rollback). |
| `poc/Get-AdapterStatus.ps1` | Read-only status report. |
| `src/BluetoothSwitcher.Core` | Adapter detection, state parsing, switch orchestration, script verification. No UI. |
| `src/BluetoothSwitcher.App` | WinUI 3 window. |
| `installer/` | `Build-Package.ps1`, `Install.ps1`, `Uninstall.ps1`. |
| `tests/` | Mocked PowerShell scenarios, parser tests, and Core unit tests. |

## Stack

**C# on .NET 10, WinUI 3 (Windows App SDK), unpackaged.** Chosen over WPF with Fluent styling
because a native Windows 11 look was the top priority, and because the UI runs unelevated,
which avoids WinUI 3's weak spot. WPF remains the fallback; the UI layer is thin.

Earlier evaluation of other options: PowerShell-only UI (weak error handling), C++/Win32
(more code, no gain), Rust or Python (toolchain and packaging cost), Electron/Tauri
(cross-platform is worthless for Windows-only device control).

## Hardware findings (verified)

| | Internal (upstairs) | External (downstairs) |
|---|---|---|
| Name | MediaTek Bluetooth Adapter | BARROT Bluetooth 6.0 Adapter (UGREEN BT6.0 dongle) |
| Hardware ID | `USB\VID_0489&PID_E139&MI_00` | `USB\VID_33FA&PID_0012` |
| Driver | Mediatek 1.1147.0.616, service BTHUSB | Barrot 11.8.41.844, service BTHUSB |
| Connection | Root hub port 12, function 0 of a composite device | Port 1 of a generic USB hub |
| Built-in | Yes | No (removable) |

- The dongle has no USB serial number, so its instance ID depends on the USB port. Moving it
  creates a new, *enabled* instance. Adapters are always matched by hardware ID.
- Measured on 2026-11-10: a switch takes about 5-6 s in total. The old adapter reads as
  stopped immediately after the disable; the new one is active about 0.3 s after the enable.

### History of failures

- The original scripts failed with "Generic failure", the catch-all error of the WMI-backed
  `Disable-PnpDevice` / `Enable-PnpDevice` cmdlets, and at least once started the second
  adapter while the first was still active (BTHUSB event 6).
- The first real run of this project's script was ended by an uncatchable PowerShell pipeline
  stop while a WMI-backed cmdlet was polling right after the disable. Rollback did not run and
  both adapters were left disabled. Fixed by polling with `pnputil` and running rollback from
  `finally`. The exact trigger was never reproduced; it has not recurred.
- DualSense "mutual authentication failed" events are a pairing limitation: the controller
  remembers one host and each adapter has its own address. Not a switching bug; out of scope.

## Privileges, risk, and recovery

- Disabling or enabling a device requires administrator rights (one UAC prompt per switch).
- During a switch every Bluetooth device disconnects. Devices paired to the other adapter
  will not reconnect until switched back. Pairings are per adapter.
- A disabled adapter stays disabled across reboots.
- **Keep a non-Bluetooth keyboard and mouse available.**

Recovery if Bluetooth is lost:

1. Device Manager -> Bluetooth -> right-click the adapter -> Enable device
   (disable the other one first).
2. Or from an elevated terminal: `pnputil /enable-device "<instance id>"`.
3. If an adapter fails to start, unplug and replug the dongle (external) or reboot
   (internal), then enable it again.

## Plan

1. Investigation and stack decision. *(done)*
2. Switching proof of concept, validated on hardware in both directions. *(done)*
3. WinUI 3 app, first working version. *(done)*
4. Installer with protected install folder and script verification. *(done, tested in a
   throwaway folder; the real install has not been run)*
5. Real install, then hardware validation of switching through the app, with explicit
   approval per test. *(next)*

## Future possibilities

- System tray icon and hotkey.
- Switching from a DualSense button combination.
- Automatic DualSense reconnection after a switch.
- Switching without a UAC prompt.
- Shorter switch time (faster detection, shorter settle pause).
