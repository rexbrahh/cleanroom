#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Cleanroom.app"
PROFILE="${CLEANROOM_NOTARY_PROFILE:-}"
IDENTITY="${CLEANROOM_SIGN_IDENTITY:--}"

[[ -d "$APP" ]] || {
  print -u2 -r -- "Missing $APP; build the app first."
  exit 66
}
[[ -n "$PROFILE" && "$IDENTITY" != - ]] || {
  print -u2 -r -- "Notarization requires CLEANROOM_SIGN_IDENTITY and CLEANROOM_NOTARY_PROFILE credentials."
  exit 77
}

SUBMISSION="$(mktemp -t cleanroom-notary).zip"
trap '/bin/rm -f "$SUBMISSION"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION"
/usr/bin/xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
