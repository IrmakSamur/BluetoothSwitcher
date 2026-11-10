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
- **`poc/Switch-Adapter.ps1` is the switching engine.** It is validated on real hardware in
  both directions. Do not change it, shorten its detection, or reduce the 2 s settle pause
  unless the user asks; reliability comes before speed.
- The app starts the script elevated (one UAC prompt per switch) and follows its log file.
- **Never report success from the script's log or exit code.** After the script exits, re-read
  the real adapter state: success only if the target is started with a Bluetooth enumerator
  running and the other adapter is disabled.
- Never kill the elevated script once it is running. Cancellation is only possible before it
  starts. Block closing the window during a switch.
- After the first device change, the script must not call the WMI-backed PnP cmdlets
  (`Get-PnpDevice` etc.); it polls with `pnputil`.
- v1 has no system tray, background service, or controller reconnection.

## Layout

- `poc/` - PowerShell engine and status script (PowerShell 5.1 compatible).
- `src/BluetoothSwitcher.Core/` - detection, state parsing, switch orchestration; no UI, unit-testable.
- `src/BluetoothSwitcher.App/` - WinUI 3 window; keep it thin.
- `tests/` - `Run-Tests.ps1` runs everything.

## Workflow

1. Investigation and stack decision (done).
2. Switching proof of concept, validated on hardware both ways (done).
3. WinUI 3 app, first working version (in progress).
4. Hardware validation through the app, with explicit approval per test.
5. Packaging.

## Conventions

- Keep it small: prefer OS-provided mechanisms over third-party dependencies.
- Run `tests/Run-Tests.ps1` after any change to the script or to Core. Tests need no elevation
  and must never touch real device state; add a mocked scenario for each new failure mode.
- Every device-state change must be verified by re-reading device status, with a timeout.
- State clearly whether a claim is verified on this machine or a hypothesis.
- The repository is local only for now. Ask before committing.
