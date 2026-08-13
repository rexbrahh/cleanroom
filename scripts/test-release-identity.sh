#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
INFO="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"

ACTUAL="$($ROOT/scripts/release-identity.sh "v$VERSION" "$((BUILD - 1))")" || {
  print -u2 -r -- "Expected the current version and a newer build to pass."
  exit 1
}
[[ "$ACTUAL" == "$VERSION $BUILD" ]] || {
  print -u2 -r -- "Expected '$VERSION $BUILD', found '$ACTUAL'."
  exit 1
}

if "$ROOT/scripts/release-identity.sh" "v0.0.0" 0 >/dev/null 2>&1; then
  print -u2 -r -- "A tag that differs from Info.plist must fail."
  exit 1
fi

if "$ROOT/scripts/release-identity.sh" "v$VERSION" "$BUILD" >/dev/null 2>&1; then
  print -u2 -r -- "A non-increasing build number must fail."
  exit 1
fi

print -r -- "Release identity checks passed."
