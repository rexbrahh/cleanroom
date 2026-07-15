# Architecture

## Processes

- `Cleanroom.app`: SwiftUI menu-bar status, settings, preflight, and recovery UX.
- `cleanroom-agent`: LaunchAgent and sole owner of cleanroom state.
- `cleanroomctl`: command-line XPC client.

All targets share `CleanroomCore`. macOS-specific inspection and mutation live
behind protocols in `CleanroomMac`.

The app registers the agent with `SMAppService`. It fingerprints the embedded
helper and refreshes registration when an installed helper changes, as required
by Service Management for updated LaunchAgent executables. The CLI and app use
one per-user Mach service; neither process mutates cleanroom state directly.
The menu app can register itself as a login item independently; that setting
does not change the recovery agent's registration or state.

## Safety invariants

1. Save and validate a complete recovery journal before the first mutation.
2. Serialize transitions through one actor.
3. Treat unreadable system state as unknown and refuse unsafe mutation.
4. Clear the journal only after every required restore postcondition succeeds.
5. Restore only helpers and settings recorded before entry.
6. Keep system services, network extensions, VPN daemons, Time Machine, and
   Karabiner's DriverKit services operator-controlled.

The same boundary applies to Tailscale, Little Snitch, firewalls, DNS, routes,
interfaces, and other network extensions. Network probes are read-only and no
network component may appear in the fixed profile's mutation set.

## State machine

`idle -> entering -> active -> restoring -> idle`

Any failed or unknown postcondition enters `degraded`. Recovery can retry entry,
retry restoration, or explicitly discard the journal after user confirmation.

## Gameplay policy

The fixed Phantom Forces profile snapshots and temporarily changes:

- mouse linearity, external-mouse trackpad gating, and the bottom-right hot corner;
- `skhd`, `yabai`, and JankyBorders;
- the configured input, window, launcher, capture, overlay, and background apps.

The preflight reports high CPU consumers, VM/container workloads, recording and
sync clients, Karabiner/VirtualHID, external pointer availability, Time Machine,
VPN/default-route state, Little Snitch residency, power source, Low Power Mode,
and thermal pressure. Network extensions, VPN daemons, Time Machine, VMs, and
Karabiner DriverKit services remain operator-controlled.

## Runtime cost

Roblox presence and managed application state use `NSRunningApplication`.
Steady idle monitoring launches no AppleScript or shell probes. Heartbeat writes
are bounded to one every five seconds, event diagnostics are capped at 512 KiB,
and the active drift verifier runs every fifteen seconds. Stop and restore work
for independent helpers is launched concurrently.

## Presentation settings

Menu-app launch-at-login and notification consent live in the app's user
defaults. Pause intent lives in the agent-owned application-support directory
and is loaded before reconciliation begins. Notifications are opt-in and cover
only degraded transitions and completed restoration, avoiding activation
banners during gameplay.
