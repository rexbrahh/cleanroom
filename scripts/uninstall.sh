#!/bin/zsh
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge-data) PURGE=1 ;;
    -h|--help)
      print -r -- "usage: uninstall.sh [--purge-data]"
      exit 0
      ;;
    *)
      print -u2 -r -- "usage: uninstall.sh [--purge-data]"
      exit 64
      ;;
  esac
done

APP="${CLEANROOM_DESTINATION_APP:-/Applications/Cleanroom.app}"
HOME_APP="$HOME/Applications/Cleanroom.app"
CLI_LINK="${CLEANROOM_CLI_LINK_DIR:-$HOME/bin}/cleanroomctl"
SUPPORT_DIR="${CLEANROOM_HOME:-$HOME/Library/Application Support/Cleanroom}"
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.rex.cleanroom.agent.plist"
LABEL="gui/$(id -u)/com.rex.cleanroom.agent"

osascript -e 'tell application id "com.rex.cleanroom" to quit' >/dev/null 2>&1 || true
for _ in {1..10}; do
  if ! /usr/bin/pgrep -q -f '/Contents/MacOS/Cleanroom'; then
    break
  fi
  sleep 0.2
done

if [[ -x "$APP/Contents/MacOS/Cleanroom" ]]; then
  ARGS=(--uninstall)
  if (( PURGE )); then
    ARGS+=(--purge-data)
  fi
  "$APP/Contents/MacOS/Cleanroom" "${ARGS[@]}" || true
fi

/bin/launchctl bootout "$LABEL" 2>/dev/null || true

remove_if_present() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    /bin/rm -rf "$path"
    print -r -- "Removed $path"
  fi
}

if [[ -L "$CLI_LINK" ]]; then
  dest="$(readlink "$CLI_LINK")"
  if [[ "$dest" == *Cleanroom.app/* && "$dest" == *cleanroomctl ]]; then
    remove_if_present "$CLI_LINK"
  fi
fi

remove_if_present "$APP"
remove_if_present "$HOME_APP"
setopt NULL_GLOB
for leftover in "$HOME/Applications"/Cleanroom.previous.*.app; do
  remove_if_present "$leftover"
done
for leftover in "$SUPPORT_DIR/previous"/Cleanroom.previous.*.app; do
  remove_if_present "$leftover"
done
remove_if_present "$LEGACY_PLIST"

if (( PURGE )); then
  remove_if_present "$SUPPORT_DIR"
  /usr/bin/defaults delete com.rex.cleanroom >/dev/null 2>&1 || true
fi

print -r -- "Cleanroom uninstall finished."
