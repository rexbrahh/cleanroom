#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/Cleanroom.app"
DESTINATION_DIR="${CLEANROOM_DESTINATION_DIR:-$HOME/Applications}"
DESTINATION_APP="$DESTINATION_DIR/Cleanroom.app"
CLI_LINK_DIR="${CLEANROOM_CLI_LINK_DIR:-$HOME/bin}"

AGENT_REL="Contents/Library/LaunchServices/cleanroom-agent"
OLD_HASH=""
if [[ -x "$DESTINATION_APP/$AGENT_REL" ]]; then
  OLD_HASH="$(/usr/bin/codesign -dv --verbose=4 "$DESTINATION_APP/$AGENT_REL" 2>&1 \
    | /usr/bin/awk -F= '/^CDHash=/{print $2}')"
fi

"$ROOT/scripts/build-app.sh"
BIN_PATH="$(swift build -c "${CONFIGURATION:-release}" --show-bin-path)"
mkdir -p "$DESTINATION_DIR" "$CLI_LINK_DIR"
NEW_HASH="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP/$AGENT_REL" 2>&1 \
  | /usr/bin/awk -F= '/^CDHash=/{print $2}')"

STAGING_DIR="$(mktemp -d "$DESTINATION_DIR/.cleanroom-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/Cleanroom.app"
SWAPPED=0
cleanup() {
  if (( SWAPPED )) && [[ -d "$STAGED_APP" ]]; then
    print -u2 -r -- "Previous app preserved at $STAGED_APP"
  else
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Library/LaunchAgents/com.rex.cleanroom.agent.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
[[ -x "$STAGED_APP/Contents/MacOS/Cleanroom" ]]
[[ -x "$STAGED_APP/$AGENT_REL" ]]
[[ -x "$STAGED_APP/Contents/Resources/cleanroomctl" ]]
/usr/libexec/PlistBuddy -c "Print :MachServices:com.rex.cleanroom.agent" \
  "$STAGED_APP/Contents/Library/LaunchAgents/com.rex.cleanroom.agent.plist" >/dev/null

"$BIN_PATH/cleanroom-install-helper" "$STAGED_APP" "$DESTINATION_APP"
SWAPPED=1
if [[ -d "$STAGED_APP" ]]; then
  BACKUP_APP="$DESTINATION_DIR/Cleanroom.previous.$(/bin/date +%Y%m%d%H%M%S).$$.app"
  /bin/mv "$STAGED_APP" "$BACKUP_APP"
  print -r -- "Previous app preserved at $BACKUP_APP"
fi
/bin/rmdir "$STAGING_DIR"
SWAPPED=0
trap - EXIT

/bin/ln -sfn "$DESTINATION_APP/Contents/Resources/cleanroomctl" "$CLI_LINK_DIR/cleanroomctl"

# Restart the agent only when its binary is unchanged. A changed binary has a
# new code hash, so launchd refuses to respawn it (EX_CONFIG) until the menu
# app refreshes the registration through SMAppService.
if [[ -n "$OLD_HASH" && "$OLD_HASH" == "$NEW_HASH" ]]; then
  /bin/launchctl kickstart -k "gui/$(id -u)/com.rex.cleanroom.agent" 2>/dev/null || true
else
  print -r -- "Agent binary changed; open Cleanroom.app to refresh its registration."
fi

print -r -- "Installed $DESTINATION_APP"
print -r -- "Open Cleanroom.app once to register its background agent."
