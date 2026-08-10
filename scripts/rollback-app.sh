#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
[[ $# == 2 ]] || {
  print -u2 -r -- "usage: rollback-app.sh INSTALLED_APP PREVIOUS_APP"
  exit 64
}
INSTALLED_APP="${1:A}"
PREVIOUS_APP="${2:A}"
[[ "$INSTALLED_APP" == *.app && "$PREVIOUS_APP" == *.app ]] || {
  print -u2 -r -- "Both rollback paths must be exact .app bundles."
  exit 65
}
[[ -d "$INSTALLED_APP" && -d "$PREVIOUS_APP" ]] || {
  print -u2 -r -- "Installed and previous app bundles must both exist."
  exit 66
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PREVIOUS_APP"
BIN_PATH="$(swift build -c release --show-bin-path)"
"$BIN_PATH/cleanroom-install-helper" "$PREVIOUS_APP" "$INSTALLED_APP"
print -r -- "Rolled back $INSTALLED_APP; replaced version is preserved at $PREVIOUS_APP"
