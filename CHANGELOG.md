# Changelog

## 3.2.4

- Advances the bundle build identity so Homebrew and Nix installs replace
  earlier internal build-11 agent registrations instead of reusing a stale
  Service Management helper.
- Removes Raycast from the Phantom Forces quit list so restore no longer
  relaunches it. Build 13 forces a helper replacement after that change.
- Build 14 is a helper replacement for menu-bar warning diagnostics.
- Recycles an enabled-but-silent helper after a bundle digest change and
  waits until XPC answers, instead of asking for Login Items surgery.

## 3.2.3

- Cached status no longer hides an XPC connection failure. Agent commands stay
  disabled until a live status request succeeds.
- Settings no longer presents an update-channel control without an updater.
  It links to the manual release download instead.
- Menu launch no longer deletes AppKit's private status-item ordering value as
  if it were a screen coordinate. External menu-bar managers remain in control
  of their own hide/show policy.
- Release tags must match `Info.plist` and use a build number greater than the
  previous tag. Release CI no longer replaces the app build with a smaller
  workflow run number.

## 3.2.2

- Restoration now resolves executable symlinks before it compares saved and
  running process identities. A slow JankyBorders launch no longer leaves the
  session degraded when the final process and executable checks succeed.

## 3.2.0

- Refreshes a changed background-agent registration after a recovery-safe local
  install and hides expired preflight findings instead of presenting stale
  process data as current.
- Adds named gameplay profiles, per-device calibration, global shortcuts, and
  deterministic session simulation without expanding the agent's mutation
  boundary.
- Adds authenticated build handshakes, bounded XPC admission, durable recovery
  receipts, and safer ownership transfer across app and agent replacement.
- Adds telemetry summaries, pressure alerts, update metadata verification, and
  redacted support bundles for faster diagnosis without exposing private data.
- Adds transactional app installation with version validation, rollback, and
  stable-channel manifest verification.
- Expands automated coverage across the agent, app, CLI, installer, recovery,
  profiles, diagnostics, simulation, networking, and update paths.

- Entry no longer waits for preflight: inspection runs after the session is
  secured for the non-gating profile, cutting roughly 1.5s off cleanroom
  entry after Roblox launches.
- Drift verification reads preferences in-process through CFPreferences, so
  steady-state gameplay monitoring spawns no shell probes; preference writes
  and `killall` synchronization now happen only when a value actually
  changed, eliminating pointless Dock restarts.
- Subprocess completion is delivered through `terminationHandler` instead of
  a 20ms polling loop, removing the latency floor on every helper command.
- The recovery journal is signature-cached, the event log is tail-read, and
  the menu app publishes only when values change instead of re-rendering on
  every two-second poll.
- The menu refreshes immediately when opened and adds keyboard shortcuts for
  preflight, entry, restore, and the dashboard.
- Agent liveness repair is staged: kickstart revives an unloaded job, a status
  probe spares a healthy-but-busy agent, and only a wedged job is booted out
  and forcibly re-registered. Registration refreshes boot the old job out
  first, so a replaced app bundle can no longer leave the agent crash-looping
  on an unresolvable program path.

## 3.1.0

- Restoration after Roblox quits is never blocked by a failed entry: automatic
  retry suppression is now scoped to the transition kind that failed, so a
  wedged entry no longer strands stopped helpers until manual recovery.
- Failed entries roll back to the saved snapshot automatically and clear the
  recovery journal once the rollback verifies; only a failed rollback retains
  the journal and waits for explicit recovery.
- Stop operations succeed based on the postcondition probe instead of the kill
  command's exit code and retry with backoff; a helper that exits on its own
  mid-stop no longer wedges the session.
- `defaults` reads, writes, and deletes retry transient cfprefsd failures, a
  missing domain counts as key absence, and post-restore verification settles
  and re-checks before failing.
- Automatic restore waits for a stable five-second Roblox exit, preventing
  restore/re-enter thrash when Roblox relaunches itself after an update or a
  crash. Manual restore stays immediate.
- The menu-bar item renders as an icon only so it remains visible on
  notch-limited displays, and an off-screen status-item position saved from a
  disconnected display is discarded at launch.
- Launch-at-login re-registers from the running bundle, clearing stale
  registrations bound to old build locations.
- Adds an app icon, an application category, and OSLog breadcrumbs for launch,
  registration, agent connectivity, and a one-time window inventory that makes
  menu-bar visibility problems diagnosable from the unified log.
- XPC calls to the agent are time-bounded, so a wedged or crash-looping agent
  can no longer deadlock menu-app polling or hang `cleanroomctl` forever.
- The menu app repairs a registered-but-dead agent by kickstarting its
  launchd job, falling back to a forced re-registration when the job is gone.
- The installer restarts an already-registered agent only when its binary is
  unchanged; a changed binary is left for the menu app's registration refresh
  instead of entering a launchd EX_CONFIG crash loop.

## 3.0.1

- Canonicalizes saved numeric booleans to `true` or `false` before invoking
  macOS `defaults` during restoration.
- Treats a failed preference deletion as successful when a follow-up read
  verifies the saved absent state.
- Suppresses automatic mutation retries after a degraded entry, drift repair,
  or restore; recovery resumes only after an explicit user action.
- Serializes Service Management unregister/register refreshes and prevents
  connection polling from repeatedly replacing an already-current registration.

## 3.0.0

- Adds a multi-section native dashboard for overview, preflight, activity, and
  the complete fixed Phantom Forces policy.
- Adds opt-in degraded/recovery notifications without activation banners during
  gameplay.
- Adds menu-app launch-at-login control while keeping agent registration
  independent.
- Adds bounded diagnostics copy and JSON export.
- Makes the read-only network boundary visible in the UI.

## 2.0.0

- Persists pause intent across managed-agent restarts and fails closed when the
  preference file is unreadable.
- Adds live heartbeat health, session age, readiness summary, and timestamped
  activity history.
- Adds version injection and durable tag-driven GitHub releases.
- Adds a regression test that excludes network infrastructure from the mutation
  profile.

## 1.0.0

- Initial fixed Roblox / Phantom Forces menu-bar app, recovery agent, CLI,
  competitive preflight, drift repair, and recovery journal.
