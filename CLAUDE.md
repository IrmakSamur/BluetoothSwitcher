# BluetoothSwitcher

Windows 11 desktop app for one-click switching between two Bluetooth adapters on one PC
(Alienware Area-51): the internal adapter (used upstairs) and an external USB adapter
(used downstairs near the TV). Windows supports only one active Bluetooth adapter at a time.

## Hardware safety rules (always apply)

- Read-only inspection is always fine. Anything that changes device state is not.
- Never disable, enable, restart, uninstall, re-pair, or reconfigure a Bluetooth device
  without the user's explicit approval **for that specific test**. Approval does not carry over.
- Never run elevated (administrator) commands or scripts without approval.
- Before proposing any device-changing test, restate: what will change, what connectivity
  may drop, and the recovery procedure (see README).
- Never leave both adapters disabled, and never enable the second while the first is still
  active. Switch order is always: disable current -> confirm stopped -> enable target -> confirm started.
- Do not assume pairings survive a switch. Each adapter has its own address and its own pairings.
- No secrets, tokens, or credentials in Git. Do not record peripheral MAC addresses in the repo.
- Do not push to GitHub or any remote without explicit approval.

## Adapter identification

- Identify adapters by hardware ID plus properties, never by a hard-coded instance ID.
  The external dongle has no USB serial number, so its instance ID changes with the USB port.
- Internal: `USB\VID_0489&PID_E139&MI_00` (MediaTek), `InLocalMachineContainer = True`, removal policy 1.
- External: `USB\VID_33FA&PID_0012` (Barrot chipset, UGREEN BT6.0 dongle), removable, removal policy 3.
- Ignore non-present (phantom) instances; several stale ones exist for the dongle.

## Phased workflow

1. **Investigate** (done) - read-only inventory and failure analysis. See README.
2. **Decide stack** (done) - C# on .NET 10, WinForms, Configuration Manager API, admin manifest.
3. **Switching proof of concept** - read-only detection is done (`poc/Get-AdapterStatus.ps1`).
   The switching test is next and runs only with per-test approval, after confirming the
   user's keyboard and mouse do not depend on Bluetooth.
4. **Core switching logic** - detect, switch, verify, roll back on failure, clear errors.
5. **Desktop UI** - status for both adapters, one-click switch.
6. **Packaging** - single distributable, elevation handled cleanly.

Do not start a phase before the previous one is validated. No GUI work before the PoC passes.

## Out of scope for v1

DualSense button-combo switching, system tray, automatic DualSense reconnection.

## Conventions

- PoC scripts live in `poc/` and are PowerShell 5.1 compatible. The app itself is C#.
- The .NET SDK is not installed yet (runtimes only); ask before installing it.
- The repository is local only for now.
- Keep it small: prefer OS-provided mechanisms over third-party dependencies.
- Every device-state change must be verified by re-reading device status, with a timeout.
- State clearly whether a claim is verified on this machine or a hypothesis.
- Ask before committing.
