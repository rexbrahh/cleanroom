# Cleanroom

Cleanroom is a private macOS companion for competitive Roblox/Phantom Forces
play. It detects Roblox, snapshots the user's current desktop/input state,
temporarily suppresses selected sources of interference, and restores the exact
saved state when Roblox exits.

Cleanroom 3.2.1 and later require macOS 15 or later.

The first release is intentionally focused on one Mac and one game profile.
The background agent owns all state transitions; the menu-bar app and
`cleanroomctl` are clients.

## Current scope

- Native Swift menu-bar application
- User LaunchAgent registered through Service Management
- Recovery-safe enter, re-enforce, and restore state machine
- Automatic rollback when entry verification fails
- Scoped automatic-retry suppression that never blocks restore-on-quit
- Stable-exit debounce before automatic restoration
- Preconfigured Roblox/Phantom Forces helper policy
- Pointer acceleration and built-in-trackpad control
- Competitive preflight and degraded-state recovery
- CLI and structured diagnostics
- Persistent pause intent across agent restarts
- Live health, session, readiness, and activity views
- Durable versioned GitHub release artifacts
- Multi-section overview, preflight, activity, and fixed-policy dashboard
- Opt-in recovery notifications and menu-app launch-at-login control
- Clipboard and file diagnostics export

See [Architecture](docs/architecture.md) for process and safety boundaries.

## Build and install

```sh
swift test
./scripts/build-app.sh
./scripts/install.sh
```

Open `/Applications/Cleanroom.app` once. The menu-bar app registers its
per-user background agent and then watches for Roblox automatically. The
installer writes that system Applications path by default and fails instead of
falling back to `~/Applications`. Leftover user-space copies are reported in
the Repair card. The installer also exposes `~/bin/cleanroomctl` for status,
preflight, recovery, and bounded diagnostics.

Uninstall unregisters the helper and login item first, then removes
`/Applications/Cleanroom.app`, leftover `~/Applications` copies, and the CLI
link. Local profiles stay unless you pass `--purge-data` or enable **Also
delete local Cleanroom data** in Settings:

```sh
./scripts/uninstall.sh
./scripts/uninstall.sh --purge-data
```

Useful commands:

```sh
cleanroomctl status
cleanroomctl preflight
cleanroomctl restore
cleanroomctl events --limit 20
cleanroomctl doctor --json
cleanroomctl watch --count 30 --interval 2 --json
```

Engine scenarios can run without desktop mutation:

```sh
swift run cleanroom-sim --example > /private/tmp/cleanroom-scenario.json
swift run cleanroom-sim /private/tmp/cleanroom-scenario.json
```

Scenario events can set trigger state, advance virtual time, queue system
outcomes or timeouts, corrupt the next journal read, restart the engine, and
run engine commands. Identical input produces identical normalized output.

`cleanroomctl` uses stable exit codes:

| Code | Meaning |
|---:|---|
| 0 | Requested state is healthy or contains no critical preflight finding. |
| 2 | Status or transition is degraded. |
| 3 | Preflight contains a critical finding. |
| 4 | Agent protocol or response validation failed. |
| 5 | The agent is unreachable or timed out twice. |
| 6 | The request is still running and was not started again. |
| 7 | One or more doctor checks failed. |

The LaunchAgent continues watching when the menu-bar UI is closed. Use Pause
in the menu or `cleanroomctl pause` to suppress new cleanroom entry; restoration
of an already-saved session remains armed.

When Roblox exits, the agent restores the saved state automatically once the
exit has been stable for five seconds (Roblox sometimes relaunches itself for
updates). If entry ever fails partway, Cleanroom rolls back to the saved
snapshot on its own instead of leaving helpers stopped.

Cleanroom never clears `recovery.json` after a partial or unknown restoration.
Use the dashboard's recovery panel or `cleanroomctl recover retry-restore`.
Journal discard requires an explicit confirmation because it gives up the
remaining automatic restore path.

## Continuous integration

GitHub Actions runs Swift formatting checks, the complete test suite, release
assembly, nested code-signature verification, and ZIP validation on pushes to
`main`, pull requests, and manual dispatches. Successful runs upload
`Cleanroom.zip`, its SHA-256 checksum, and a stable-channel update manifest as
a 14-day workflow artifact.

To reproduce the artifact locally:

```sh
./scripts/build-app.sh
./scripts/package-app.sh
```

Semantic tags such as `v2.0.0` additionally create a durable private GitHub
release containing the verified app ZIP and SHA-256 checksum. Build metadata is
read from `Resources/Info.plist` for local builds and can be injected with
`CLEANROOM_VERSION` and `CLEANROOM_BUILD_NUMBER` for releases. Assembly fails if
the app, CLI, and agent do not all report the injected identity.

Stable tags use `vMAJOR.MINOR.PATCH`; beta releases use
`vMAJOR.MINOR.PATCH-beta.NUMBER`. Packaging emits schema-validated stable or
beta metadata and verifies the archive checksum before publication. The
installer preserves the previous bundle under Application Support;
`scripts/rollback-app.sh` swaps an exact verified previous bundle back
atomically. Developer ID signing is set by
`CLEANROOM_SIGN_IDENTITY`. Notarization is deliberately credential-gated by
`CLEANROOM_NOTARY_PROFILE`; set `CLEANROOM_REQUIRE_NOTARIZATION=1` to make a
missing credential fail packaging rather than produce an explicitly
unnotarized artifact.

## Network boundary

Network infrastructure remains operator-controlled. Cleanroom can report VPN,
route, filter, and interface conditions during preflight, but it never stops or
reconfigures VPNs, Tailscale, Little Snitch, firewalls, network extensions,
routes, DNS, or network interfaces.

The Policy screen lists the complete mutation set and separately identifies
operator-controlled software. This makes the boundary visible in the app in
addition to enforcing it in tests.

## Support bundles

The Activity screen can create a local ZIP containing only bounded status,
probe freshness, outcome counts, recovery times, and performance timings. Its
manifest lists every omitted field, including process identity, journal state,
preference values, action details, network targets, hardware identity, and
paths. Cleanroom has no support-upload or automatic-submission path.
