# BluetoothSwitcher

A lightweight Windows 11 app that switches a PC between two Bluetooth adapters with one click:

- **Upstairs** - the internal adapter.
- **Downstairs** - an external USB adapter near the TV.

Windows only supports one active Bluetooth adapter at a time, so switching means disabling
one adapter and enabling the other, then verifying the result.

**Status: investigation complete, stack recommended but not confirmed, no application code yet.**

## v1 scope

- Identify both adapters reliably (not by fixed instance ID).
- Show each adapter's current status.
- One-click switch upstairs <-> downstairs.
- Verify the switch, report clear errors, roll back safely on failure.
- Simple desktop window, built only after the switching mechanism is proven.

Out of scope for v1: DualSense button-combo switching, system tray, automatic DualSense reconnection.

## Investigation findings (2026-11-10, read-only)

### Adapters (verified)

| | Internal (upstairs) | External (downstairs) |
|---|---|---|
| Name | MediaTek Bluetooth Adapter | BARROT Bluetooth 6.0 Adapter (UGREEN BT6.0 dongle) |
| Hardware ID | `USB\VID_0489&PID_E139&MI_00` | `USB\VID_33FA&PID_0012` |
| Instance ID | `USB\VID_0489&PID_E139&MI_00\9&20D79C11&0&0000` | `USB\VID_33FA&PID_0012\B&1DBEFB94&0&1` (port-dependent) |
| Driver | Mediatek 1.1147.0.616 (`oem86.inf`), service BTHUSB | Barrot 11.8.41.844 (`oem109.inf`), service BTHUSB |
| Connection | Root hub port 12, function 0 of a composite device | Port 1 of a generic USB hub (`VID_1A40&PID_0101`) |
| Built-in | Yes (`InLocalMachineContainer`, removal policy 1) | No (removable, removal policy 3) |
| Status at inspection | Disabled (problem code 22) | Started, hosting the Bluetooth stack |

- The dongle has no USB serial number, so its instance ID is derived from the port. Six stale
  instances exist from other ports. Moving it to another port creates a new, *enabled*
  instance - the app must match on hardware ID and handle this.
- Elevation: the inspecting shell was not elevated; changing device state needs administrator rights.

### Why earlier switching failed

Verified from the Windows event log:

- BTHUSB event 6, "Only one active Bluetooth adapter is supported at a time" - at least once,
  the second adapter was started while the first was still active.
- BTHUSB events 3 and 17 - an adapter stopped answering commands during start-up and Windows
  unloaded its driver (twice within five minutes on one evening).
- Kernel-PnP event 411 - the dongle "had a problem starting" on first install.
- BTHUSB event 16 - repeated "mutual authentication failed" against the DualSense Edge.

Hypotheses (not yet verified):

- "Generic failure" is the catch-all error from the WMI-backed `Disable-PnpDevice` /
  `Enable-PnpDevice` cmdlets. Likely causes: not elevated, enabling before the other adapter
  had fully stopped, or not waiting for the stack to settle. The cmdlets hide the real error code.
- A fixed instance ID in the old scripts would silently miss the dongle after a port change.
- DualSense failures are a link-key mismatch: the controller remembers one host, and each
  adapter has a different address, so pairing with one adapter invalidates the other.
  This is a pairing limitation, not a switching bug.

### Mechanism

Disable/enable the adapter's device node - the same operation as Device Manager. Options:
`pnputil /disable-device` and `/enable-device` (built in, real exit codes), or the Configuration
Manager API (`CM_Disable_DevNode`, `CM_Enable_DevNode`, `CM_Get_DevNode_Status`) from code.
The Bluetooth radio on/off toggle only affects the active adapter and cannot switch adapters.

Required sequence: disable current -> wait until stopped -> enable target -> wait until started
and its Bluetooth enumerator child appears -> if that fails, re-enable the original.

## Recommended stack (pending confirmation)

**C# on .NET 10, WinForms, calling the Configuration Manager API directly, with an
administrator manifest.** The proof of concept comes first as a short PowerShell script using `pnputil`.

| Option | Verdict |
|---|---|
| C# / .NET WinForms | Recommended. Direct Windows API access with real error codes, tiny UI code, runtime already installed. Needs the .NET SDK installed to build. |
| PowerShell + WinForms script | Zero install and fine for the PoC, but weak error handling, awkward elevation, hard to maintain as an app. |
| C++ / Win32 | Most direct API access, smallest binary, but far more code for no practical gain. |
| Rust | Good API bindings, but needs a toolchain install and GUI choices are heavier. |
| Python | Needs runtime, ctypes bindings, and bulky packaging. |
| Electron / Tauri | Cross-platform is worthless here (Windows-only device control); heavy and needs a native helper anyway. |

## Privileges, risk, and recovery

- Disabling or enabling a device requires administrator rights (a UAC prompt).
- During a switch every Bluetooth device disconnects. Devices paired to the other adapter
  will not reconnect until switched back. Pairings are per adapter.
- A disabled adapter stays disabled across reboots.
- **Have a wired (or non-Bluetooth) keyboard and mouse available before any test.**

Recovery if Bluetooth is lost:

1. Device Manager -> Bluetooth -> right-click the adapter -> Enable device.
2. Or from an elevated terminal: `pnputil /enable-device "<instance id>"`.
3. If both appear enabled but Bluetooth is broken, disable the one you do not want, then
   disable and re-enable the one you do.
4. If an adapter fails to start, unplug and replug the dongle (external) or reboot (internal).

## Plan

1. Confirm stack. *(next)*
2. PoC: read-only status script, then one approved switch in each direction, measuring timing.
3. Core logic: identification, switch, verification, rollback, error reporting.
4. UI: status of both adapters, one switch button.
5. Packaging.

## Future possibilities

- System tray icon and hotkey.
- Switching from a DualSense button combination.
- Automatic DualSense reconnection after a switch.
- Launch without a UAC prompt.
