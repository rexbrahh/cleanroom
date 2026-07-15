#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/Cleanroom.app"
DESTINATION_DIR="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIR/Cleanroom.app"

"$ROOT/scripts/build-app.sh"
mkdir -p "$DESTINATION_DIR" "$HOME/bin"
rm -rf "$DESTINATION_APP"
/usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
/bin/ln -sfn "$DESTINATION_APP/Contents/Resources/cleanroomctl" "$HOME/bin/cleanroomctl"

print -r -- "Installed $DESTINATION_APP"
print -r -- "Open Cleanroom.app once to register its background agent."
