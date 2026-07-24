#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/Cleanroom.app"
DESTINATION_DIR="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIR/Cleanroom.app"

AGENT_REL="Contents/Library/LaunchServices/cleanroom-agent"
OLD_HASH=""
if [[ -x "$DESTINATION_APP/$AGENT_REL" ]]; then
  OLD_HASH="$(/usr/bin/codesign -dv --verbose=4 "$DESTINATION_APP/$AGENT_REL" 2>&1 \
    | /usr/bin/awk -F= '/^CDHash=/{print $2}')"
fi

"$ROOT/scripts/build-app.sh"
mkdir -p "$DESTINATION_DIR" "$HOME/bin"
NEW_HASH="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP/$AGENT_REL" 2>&1 \
  | /usr/bin/awk -F= '/^CDHash=/{print $2}')"
rm -rf "$DESTINATION_APP"
/usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
/bin/ln -sfn "$DESTINATION_APP/Contents/Resources/cleanroomctl" "$HOME/bin/cleanroomctl"

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
