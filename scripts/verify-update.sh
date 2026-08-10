#!/bin/zsh
set -euo pipefail

[[ $# == 2 ]] || {
  print -u2 -r -- "usage: verify-update.sh MANIFEST ARCHIVE"
  exit 64
}
MANIFEST="$1"
ARCHIVE="$2"
[[ -f "$MANIFEST" && -f "$ARCHIVE" ]] || {
  print -u2 -r -- "Manifest and archive must both exist."
  exit 66
}

SCHEMA="$(/usr/bin/plutil -extract schemaVersion raw -o - "$MANIFEST")"
CHANNEL="$(/usr/bin/plutil -extract channel raw -o - "$MANIFEST")"
URL="$(/usr/bin/plutil -extract archiveURL raw -o - "$MANIFEST")"
EXPECTED="$(/usr/bin/plutil -extract sha256 raw -o - "$MANIFEST")"
[[ "$SCHEMA" == 1 && ( "$CHANNEL" == stable || "$CHANNEL" == beta ) && "$URL" == https://* ]] || {
  print -u2 -r -- "Update manifest schema, channel, or HTTPS URL is invalid."
  exit 65
}
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
[[ "$EXPECTED" == "$ACTUAL" ]] || {
  print -u2 -r -- "Update checksum mismatch: expected $EXPECTED, found $ACTUAL."
  exit 65
}
print -r -- "Verified $CHANNEL update SHA-256 $ACTUAL"
