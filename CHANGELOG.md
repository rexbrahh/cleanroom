# Changelog

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
