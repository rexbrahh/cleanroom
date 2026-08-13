#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 -r -- "Usage: $0 RELEASE_TAG PREVIOUS_BUILD"
  exit 64
fi

ROOT="${0:A:h:h}"
INFO="$ROOT/Resources/Info.plist"
TAG_VERSION="${1#v}"
TAG_VERSION="${TAG_VERSION%%-beta.*}"
PREVIOUS_BUILD="$2"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"

[[ "$TAG_VERSION" == "$VERSION" ]] || {
  print -u2 -r -- "Release tag version $TAG_VERSION does not match Info.plist version $VERSION."
  exit 1
}
[[ "$PREVIOUS_BUILD" =~ '^[0-9]+$' && "$BUILD" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 -r -- "Release build numbers must be non-negative integers."
  exit 1
}
(( BUILD > PREVIOUS_BUILD )) || {
  print -u2 -r -- "Release build $BUILD must be greater than previous build $PREVIOUS_BUILD."
  exit 1
}

print -r -- "$VERSION $BUILD"
