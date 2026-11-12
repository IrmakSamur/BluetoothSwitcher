# BluetoothSwitcher

Windows 11 desktop app for one-click switching between two Bluetooth adapters on one PC
(Alienware Area-51): the internal adapter (used upstairs) and an external USB adapter
(used downstairs near the TV). Windows supports only one active Bluetooth adapter at a time.

## Hardware safety rules (always apply)

- Read-only inspection is always fine. Anything that changes device state is not.
- Never disable, enable, restart, uninstall, re-pair, or reconfigure a Bluetooth device
  without the user's explicit approval **for that specific test**. Approval does not carry over.
- Never run elevated (administrator) commands or scripts without approval.
- Building, running, and testing the app is fine, but never trigger a real switch from it
  (do not click an adapter card in the real app, do not accept a UAC prompt). Use
  `--demo` or the unit tests to exercise switching flows.
- Before proposing any device-changing test, restate: what will change, what connectivity
  may drop, and the recovery procedure (see README).
- Never leave both adapters disabled, and never enable the second while the first is still
  active. Switch order is always: disable current -> confirm stopped -> enable target -> confirm started.
- Do not assume pairings survive a switch. Each adapter has its own address and its own pairings.
- No secrets, tokens, or credentials in Git. Do not record peripheral MAC addresses in the repo.
- Do not push to GitHub or any remote without explicit approval.

## Adapter identification

- Identify adapters by hardware ID, never by a hard-coded instance ID.
  The external dongle has no USB serial number, so its instance ID changes with the USB port.
- Internal / Upstairs: `USB\VID_0489&PID_E139&MI_00` (MediaTek).
- External / Downstairs: `USB\VID_33FA&PID_0012` (Barrot chipset, UGREEN BT6.0 dongle).
- Ignore non-present (phantom) instances; several stale ones exist for the dongle.

## Architecture rules

- Stack: C# / .NET 10, WinUI 3 (Windows App SDK), unpackaged. See README for the diagram.
- **The app runs unelevated.** No `requireAdministrator` manifest. It reads state with
  `pnputil /enum-devices ... /format xml` and changes nothing itself.
- **`poc/Switch-Adapter-Next.ps1` is the switching engine the app ships** (installed as
  `Switch-Adapter.ps1`). It stops the active adapter in two phases: a non-persistent stop
  (`CM_Query_And_Remove_SubTree`), and only once that has succeeded a persistent disable
  (`CM_Disable_DevNode`). A refused stop therefore writes nothing. Never reintroduce
  `pnputil /disable-device` on a running adapter: when Windows vetoes it (Steam holding a
  paired controller did, on 2026-11-11) it leaves the adapter "disabled, pending restart".
- `poc/Switch-Adapter.ps1` is the previous engine, kept for reference and rollback. Do not
  change either script, shorten detection, or reduce the 2 s settle pause unless the user asks.
- The engine declares its cfgmgr32 calls in memory (Reflection.Emit). Do not use
  `Add-Type -TypeDefinition` in it: that compiles to the temp folder while elevated.
- The app starts the script elevated (one UAC prompt per switch) and waits for it to exit.
- **Never report success from the script's log or exit code.** After the script exits, re-read
  the real adapter state: success only if the target is started with a Bluetooth enumerator
  running and the other adapter is disabled.
- Never kill the elevated script once it is running. Cancellation is only possible before it
  starts. Block closing the window during a switch.
- After the first device change, the script must not call the WMI-backed PnP cmdlets
  (`Get-PnpDevice` etc.); it polls with `pnputil`.
- **Before every elevation the app verifies the script** (`EngineGuard`): its folder must be
  writable by administrators only, and its SHA-256 must equal the hash the build embedded.
  Never weaken or bypass this. `--dev` lifts only the location check, for development builds.
- v1 has no system tray, background service, scheduled task, or controller reconnection.

## Install rules

- The app is installed to `C:\Program Files\BluetoothSwitcher` by `installer/Install.ps1`,
  run by the user from an elevated PowerShell. Never run the real install or uninstall
  yourself; test with `-WhatIf`, or with `-TestInstall` into a throwaway folder.
- Install and uninstall scripts never request elevation themselves and never touch devices.
- The package is the Release **build** output. Do not switch `Build-Package.ps1` to
  `dotnet publish`: it omits `BluetoothSwitcher.pri` and the `.xbf` files and the app then
  crashes at startup.
- After changing `poc/Switch-Adapter-Next.ps1` the app must be rebuilt and reinstalled, because the
  embedded hash changes.

## Layout

- `poc/` - PowerShell engine and status script (PowerShell 5.1 compatible).
- `src/BluetoothSwitcher.Core/` - detection, state parsing, switch orchestration; no UI, unit-testable.
- `src/BluetoothSwitcher.App/` - WinUI 3 window; keep it thin.
- `installer/` - `Build-Package.ps1` (no admin), `Install.ps1` and `Uninstall.ps1` (admin).
- `tests/` - `Run-Tests.ps1` runs everything.
- `tools/New-AppIcon.ps1` - regenerates `src/BluetoothSwitcher.App/Assets/AppIcon.ico`.
- `Directory.Build.props` - the version for all projects; change it only for a release.
- `dist/` - built package; ignored by Git.

## Workflow

1. Investigation and stack decision (done).
2. Switching proof of concept, validated on hardware both ways (done).
3. WinUI 3 app, first working version (done).
4. Installer and script verification (done).
5. Real install and hardware validation through the installed app, both directions and
   after a reboot (done by the user, 2026-11-11).
6. Version 1.0.0 with application icon (done, tagged v1.0.0).
7. Two-phase stop after the removal-veto failures of 2026-11-11 (done, 1.1.0). Validated on
   hardware 2026-11-12, both directions through the app with Steam holding the controller, and
   across a restart. Not verified: a refused stop on real hardware, and longer-term reliability.

## Log file rule

- **Never open the script's log file while the script is running**, not even for reading.
  A concurrent reader makes Windows PowerShell 5.1's `Add-Content` fail, and keep failing
  for seconds, so the script loses its own log lines. The runner reads the log once, after
  the process has exited, and not at all if it timed out.
- The progress display comes from adapter state (`SwitchProgressTracker`), never from the log.
- The "busy log" test in the Core tests guards this; keep it.

## Conventions

- Keep it small: prefer OS-provided mechanisms over third-party dependencies.
- Run `tests/Run-Tests.ps1` after any change to the script or to Core. Tests need no elevation
  and must never touch real device state; add a mocked scenario for each new failure mode.
- Every device-state change must be verified by re-reading device status, with a timeout.
- State clearly whether a claim is verified on this machine or a hypothesis.
- The repository is public on GitHub (IrmakSamur/BluetoothSwitcher). Ask before committing; never push, tag or publish a release without explicit approval.
