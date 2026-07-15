# Cleanroom

Cleanroom is a private macOS companion for competitive Roblox/Phantom Forces
play. It detects Roblox, snapshots the user's current desktop/input state,
temporarily suppresses selected sources of interference, and restores the exact
saved state when Roblox exits.

The first release is intentionally focused on one Mac and one game profile.
The background agent owns all state transitions; the menu-bar app and
`cleanroomctl` are clients.

## V1 scope

- Native Swift menu-bar application
- User LaunchAgent registered through Service Management
- Recovery-safe enter, re-enforce, and restore state machine
- Preconfigured Roblox/Phantom Forces helper policy
- Pointer acceleration and built-in-trackpad control
- Competitive preflight and degraded-state recovery
- CLI and structured diagnostics

See [Architecture](docs/architecture.md) for process and safety boundaries.

## Build and install

```sh
swift test
./scripts/build-app.sh
./scripts/install.sh
```

Open `~/Applications/Cleanroom.app` once. The menu-bar app registers its
per-user background agent and then watches for Roblox automatically. The
installer also exposes `~/bin/cleanroomctl` for status, preflight, recovery,
and bounded diagnostics.

Useful commands:

```sh
cleanroomctl status
cleanroomctl preflight
cleanroomctl restore
cleanroomctl events --limit 20
```

The LaunchAgent continues watching when the menu-bar UI is closed. Use Pause
in the menu or `cleanroomctl pause` to suppress new cleanroom entry; restoration
of an already-saved session remains armed.

Cleanroom never clears `recovery.json` after a partial or unknown restoration.
Use the dashboard's recovery panel or `cleanroomctl recover retry-restore`.
Journal discard requires an explicit confirmation because it gives up the
remaining automatic restore path.
