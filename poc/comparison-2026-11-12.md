# Steam / controller comparison, 2026-11-12

Goal: find out when the DualSense makes Windows veto stopping the active Bluetooth adapter,
and whether closing Steam releases the block without a restart.

Starting state (verified 07:59): boot at 07:43:58, Steam started 07:53:37, controller paired
but not connected since boot, Upstairs (MediaTek) active, Downstairs disabled, no restart
flags, no removal vetoes since boot.

Two tools:

- `poc/Get-BluetoothHandleHolders.ps1` - read-only, no admin. Lists which inspectable
  programs hold a handle on the adapter's device tree.
- `poc/Probe-AdapterStop.ps1 -Execute -StopRequestOnly` - needs an elevated PowerShell.
  Asks Windows to stop the adapter non-persistently and reports who vetoes.

## Results

| Step | Condition | Handle scan (no admin) | Elevated stop probe | Status |
|---|---|---|---|---|
| 1 | Steam running, controller never connected | steam.exe holds nothing | not run | Partly done |
| 2 | Steam running, controller connected | - | - | Waiting: needs the controller switched on |
| 3 | Steam running, controller switched off | - | - | Waiting: needs the controller switched off |
| 4 | Steam closed after controller use | - | - | Not started: depends on 2 and 3 |
| 5 | Steam closed, controller connected | - | - | Waiting: needs the controller switched on |

### Step 1 detail (08:01, three scans, identical)

- 205 processes inspected, 173 not inspectable without admin, about 7,700 file handles checked.
- `steam.exe` holds no handle anywhere in the adapter's device tree.
- `svchost.exe` (Connected Devices Platform User Service, `CDPUserSvc`) holds one handle on
  the adapter itself. This did not block: the app switched successfully at 07:53:54 and
  07:54:03 with Steam running. Whether that handle was already open then is not known.
- "Bluetooth HID Device" (the controller's HID node) has no child devices while the
  controller is not connected.
- The elevated stop probe was not run: the assistant's shell is not elevated and it cannot
  answer a UAC prompt.

## Not tested

Steps 2 to 5, and the elevated probe for every step. No device state was changed, Steam was
not closed, and the switch app was not used.

### Step 2 detail (08:03, two scans, identical) - Steam running, controller connected

- A new device appeared under the controller's HID node: "HID-compliant game controller".
- `steam.exe` (pid 51288) holds 1 handle on it.
- `XboxService.exe` (pid 9848) holds 2 handles on it.
- The CDPUserSvc handle on the adapter itself is unchanged.
- Adapter state unchanged: Upstairs started, no restart flags, no vetoes. Elevated stop probe not run.

### Step 3 detail (08:15, two scans 30 s apart, identical) - Steam running, controller switched off

- Controller reports connected: False.
- The "HID-compliant game controller" device is still present and started.
- `steam.exe` still holds 1 handle on it; `XboxService.exe` still holds 2.
- Adapter state unchanged, no restart flags, no vetoes. Elevated stop probe not run.

### Step 4 detail (08:17) - Steam closed gracefully after controller use, controller off

- `steam.exe -shutdown` at 08:16:45; all Steam processes had exited by 08:16:47. Nothing was killed.
- Steam's handle on the game-controller device is gone.
- `XboxService.exe` still holds 2 handles on it; the device is still present.
- Adapter state unchanged, no restart flags, no vetoes.
- Whether the adapter can now be stopped is NOT yet tested: that needs the elevated stop probe.
- Evidence so far that XboxService is not a blocker: it is not named in any of the 52 removal
  vetoes in the event log (steam.exe 31, svchost.exe 18, PhoneExperienceHost.exe 1).

### Step 4, elevated stop probe (08:20:48) - Steam closed after controller use, controller off

- Launched elevated by the assistant; UAC accepted by the user.
- `CM_Query_And_Remove_SubTree` (no restart, non-persistent): **Stopped, not vetoed.** BLOCKED RIGHT NOW: no.
- No removal veto logged. XboxService.exe did not block, although it held 2 handles on the controller.
- Adapter after the stop: status=Problem, problem code 21, no restart flag, not marked disabled.
- `CM_Setup_DevNode` restarted it; started with the Bluetooth enumerator up 2 s after the stop.
- Final state identical to the start: Upstairs started, Downstairs disabled, no restart flags.

**Conclusion: closing Steam gracefully after controller use releases the block without a restart.**

### Step 5 detail (08:22) - Steam closed, controller connected

- Handle scan: the game-controller device is back; only `XboxService.exe` holds it (2 handles). No Steam.
- Elevated stop probe: NOT RUN. The UAC prompt at 08:22:18 was cancelled, so nothing was started.
- Adapter state unchanged: Upstairs started, no restart flags, no vetoes since boot.

### Step 5, elevated stop probe (08:33:06) - Steam closed, controller connected

- UAC accepted by the user on the second attempt.
- **Stopped, not vetoed.** BLOCKED RIGHT NOW: no. No removal veto logged.
- XboxService.exe held 2 handles on the connected controller and did not block.
- Adapter restarted by `CM_Setup_DevNode`; started with the enumerator up 2 s after the stop.
- No restart flag, not marked disabled. Final state identical to the start.
- The controller was disconnected by the stop and had not reconnected 10 s later.

## Conclusions so far

1. Steam is the only blocker observed. It takes a handle on the controller's HID device when
   the controller connects, and keeps it after the controller is switched off.
2. Closing Steam gracefully releases the block. No restart is needed.
3. Without Steam, the adapter can be stopped with the controller off (step 4) and with it
   connected (step 5). XboxService.exe holds the controller too but does not block.
4. The non-persistent stop (`CM_Query_And_Remove_SubTree`) and restart (`CM_Setup_DevNode`)
   worked twice and left no flags.

## Still untested

- The blocked case with the new stop request: Steam running, controller connected. Expected: a
  clean veto naming Steam, no restart flag. This is what a safer switch method would rely on.
- Whether turning the Bluetooth radio off first lets the adapter stop while Steam is running
  (probe test 2). This decides if one-click switching can work without closing Steam.
- Whether DeviceAssociationService ever blocks by itself (it appears in 18 past vetoes).

### Step 6, elevated stop probe (08:35:30) - Steam running, controller connected

Set up as the blocked case: Steam restarted at 08:34:36 (minimised), controller reconnected,
handle scan at 08:35:02 showed `steam.exe` holding 1 handle on the game-controller device.

- **Unexpected: Stopped, not vetoed.** BLOCKED RIGHT NOW: no. No removal veto logged.
- Adapter restarted by `CM_Setup_DevNode`; started with the enumerator up 2 s later.
- No restart flag, not marked disabled. Final state identical to the start.
- The radio-off test did not run, because there was no veto to work around.

So the block did NOT reproduce, even though Steam held the controller. The expectation that
"Steam holding a handle means a veto" is not confirmed. Not yet explained. Candidates:

1. The non-persistent stop request is not refused in the same way as `pnputil /disable-device`.
2. Steam only refuses in some situations. Differences from last night: Steam had just been
   started minimised and was idle; last night both vetoes came shortly after a FRESH PAIRING of
   the controller (39 s and 184 s after), and there has been no pairing event today.
3. One sample only.

The clean-veto behaviour of the new stop request is therefore still unobserved.

### Step 7, elevated stop probe (08:45:23) - Steam running, controller freshly paired

Set up by the user: pairing removed 08:43:33, paired again 08:43:48, Steam running since 08:34:36.
Handle scan at 08:44:22: `steam.exe` 1 handle and `XboxService.exe` 2 handles on the game-controller device.

- **Stopped, not vetoed**, 95 s after the fresh pairing. No removal veto logged.
- Adapter restarted; started with the enumerator up 2 s later. No restart flag, not marked disabled.

So a fresh pairing is not the trigger either, at least not for this stop method.

## Summary of the elevated stop probes (CM_Query_And_Remove_SubTree, non-persistent)

| Step | Steam | Controller | Result |
|---|---|---|---|
| 4 | closed after use | off | stopped, restarted cleanly |
| 5 | closed | connected | stopped, restarted cleanly |
| 6 | running, holds controller | connected | stopped, restarted cleanly |
| 7 | running, holds controller | freshly paired, connected | stopped, restarted cleanly |

Four of four succeeded, including the two conditions that match last night's failures. Last
night's failures used `pnputil /disable-device`. The remaining explanation is the stop
method, but the two methods have NOT been run side by side in the same condition, and a
refusal of the new method has never been observed.

## Real switches with the experimental script (poc/Switch-Adapter-Next.ps1)

### Switch A, 19:46:23 - Downstairs -> Upstairs, Steam running, controller connected on the dongle

Conditions (verified 19:46:12): controller paired on the dongle at about 19:45 and connected;
`steam.exe` (started 19:42:42) held 1 handle and `XboxService.exe` 2 handles on its game-controller device.

- Non-persistent stop of the dongle: returned 0x0, stopped on the first poll (problem 21). No veto.
- Persistent disable (CM_Disable_DevNode): returned 0x0, status Disabled on the first poll.
- 2 s settle, then `pnputil /enable-device` on the internal adapter: exit 0; active 0.3 s later.
- Script exit code 0. Total about 6 s, of which 1.9 s adapter detection and 2 s settle.
- Verified independently: Upstairs started with the enumerator up, Downstairs disabled, state
  Clean, no restart flags, registry flags consistent (dongle marked disabled, internal not),
  no removal vetoes.

This is the first complete switch in the condition that failed on 2026-11-11.

### Switch B - Upstairs -> Downstairs: waiting for the controller to be paired on the internal adapter

### Switch B, 19:48:20 - Upstairs -> Downstairs, Steam running, controller connected on the internal adapter

Conditions (verified 19:48:07): controller paired on the internal adapter at 19:47:26 and connected;
`steam.exe` held 1 handle and `XboxService.exe` 2 handles on its game-controller device.

- Non-persistent stop of the internal adapter: returned 0x0, stopped on the first poll. No veto.
- Persistent disable: returned 0x0, status Disabled on the first poll.
- 2 s settle, then `pnputil /enable-device` on the dongle: exit 0; active 0.3 s later.
- Script exit code 0. Total about 5.5 s.
- Verified independently: Downstairs started with the enumerator up, Upstairs disabled, state
  Clean, no restart flags, registry flags consistent, no removal vetoes.

## Outcome

Both directions switched cleanly with Steam running and holding a freshly paired, connected
controller: the condition in which `pnputil /disable-device` was refused on 2026-11-11.

Not yet verified:
- A refusal of the new stop request has never occurred on hardware; that path is covered by
  mocked tests only.
- Whether the state survives a Windows restart (the disabled adapter must stay disabled).
- Switching through the app: the installed app still uses the old script.
- Repeatability over many switches and days.

## Validation through the installed app (1.1.0-beta.1, commit 964bebf)

Installed 19:54 by the assistant with the user accepting UAC. `--verify-install` returns 0;
the installed engine is `poc/Switch-Adapter-Next.ps1`. The previous install (1.0.0+ce8b873) is
kept as an installable package in `dist\BluetoothSwitcher-1.0.0-backup` (not in Git).

- App switch A, 19:56:20 - Downstairs -> Upstairs, clicked by the user in the app: **success**.
  Controller paired on the dongle at 19:56:05 (15 s earlier), Steam running since 19:42:42. Engine log:
  stop 0x0, stopped on the first poll; persistent disable 0x0; `pnputil /enable-device` exit 0;
  active 0.3 s later; exit code 0. App showed "Now on Upstairs". Verified afterwards: state Clean,
  no restart flags, registry flags consistent, no removal vetoes. Not checked for this run: a
  handle scan before the click, so that Steam was holding the controller is inferred from the
  earlier runs, not observed.
- App switch B, 19:58:58 - Upstairs -> Downstairs, clicked by the user in the app: **success**.
  Observed 36 s before the click (19:58:22): controller paired on the internal adapter at 19:58:03 and
  connected; `steam.exe` 1 handle and `XboxService.exe` 2 handles on its game-controller device.
  Engine log: stop 0x0, stopped on the first poll; persistent disable 0x0; enable exit 0; active
  0.3 s later; exit code 0. Verified afterwards: state Clean, no restart flags, registry flags
  consistent, no removal vetoes.
- State after a Windows restart: **unchanged**. Restarted by the user; boot at 20:01:23. Checked at
  20:02:39: Downstairs (BARROT) started with the enumerator up, Upstairs (MediaTek) disabled,
  ConfigFlags dongle 0x0 and internal 0x1 (same as before the restart), no restart flags, state
  Clean, no removal vetoes, no adapter errors. Steam started by itself at 20:02:02.

## Validation status of 1.1.0-beta.1

Passed on 2026-11-12: both directions with the script alone, both directions through the
installed app, with Steam running and the controller freshly paired and connected, and the
state after a restart.

Still open:
- A refusal of the stop request has never occurred on hardware; that path is covered by
  mocked tests only.
- Why Windows refuses `pnputil /disable-device` but accepts the non-persistent stop request
  in the same condition is not known.
- Repeatability over more switches and days.
