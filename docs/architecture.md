# Architecture

## Processes

- `Cleanroom.app`: SwiftUI menu-bar status, settings, preflight, and recovery UX.
- `cleanroom-agent`: LaunchAgent and sole owner of cleanroom state.
- `cleanroomctl`: command-line XPC client.

All targets share `CleanroomCore`. macOS-specific inspection and mutation live
behind protocols in `CleanroomMac`.

The app registers the agent with `SMAppService`. It fingerprints the embedded
helper and refreshes registration when an installed helper changes, as required
by Service Management for updated LaunchAgent executables. When the agent stops
answering, the app first kickstarts its launchd job and falls back to a forced
re-registration if the job is gone; all XPC calls are time-bounded so a dead
agent cannot wedge clients. The CLI and app use one per-user Mach service;
neither process mutates cleanroom state directly. The menu app can register
itself as a login item independently; that setting does not change the
recovery agent's registration or state.

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

Any failed or unknown postcondition enters `degraded`. A failed entry rolls the
saved snapshot back automatically; the journal is cleared when the rollback
verifies and is retained only when the rollback itself is incomplete.

Automatic retry suppression is scoped to the transition kind that failed: a
failed entry or drift repair blocks only automatic re-entry, a failed restore
blocks only automatic restore retries, and a failed rollback blocks both.
Restoration of a saved session therefore stays armed after an entry failure,
and restore loops are still impossible. Recovery can retry entry, retry
restoration, or explicitly discard the journal after user confirmation.

Automatic restoration fires only after the Roblox exit probe has been stable
for five seconds, so a Roblox auto-update relaunch or a quick crash-and-
relaunch does not thrash between restore and re-entry. Manual restore commands
are never debounced.

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
Preference inspection reads through CFPreferences in-process, and the journal
is signature-cached, so steady idle and active monitoring launch no
AppleScript or shell probes. Writes and process synchronization happen only
when a preference value actually changes. Preflight inspection runs after
entry for the non-gating profile so it never delays the transition. Heartbeat
writes are bounded to one every five seconds, event diagnostics are capped at
512 KiB and tail-read on query, and the active drift verifier runs every
fifteen seconds. Stop and restore work for independent helpers is launched
concurrently, and subprocess completion is delivered through
`terminationHandler` rather than polling.

## Presentation settings

Menu-app launch-at-login and notification consent live in the app's user
defaults. Pause intent lives in the agent-owned application-support directory
and is loaded before reconciliation begins. Notifications are opt-in and cover
only degraded transitions and completed restoration, avoiding activation
banners during gameplay.
