# Changelog

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
