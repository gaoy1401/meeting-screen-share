#!/bin/zsh
set -euo pipefail
ROOT_DIR=${0:A:h:h}
"$ROOT_DIR/scripts/build-client.sh"
APP="$ROOT_DIR/dist/mac/MeetingClient.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
OUTPUT="$ROOT_DIR/dist/releases"
NAME="MeetingClient-$VERSION-macos-$ARCH"
STAGE="$ROOT_DIR/.runtime/$NAME"
mkdir -p "$OUTPUT"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MeetingClient.app"
cp "$ROOT_DIR/docs/INSTALL_MAC.md" "$STAGE/INSTALL_MAC.md"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$STAGE/"
ditto -c -k --keepParent --norsrc "$STAGE" "$OUTPUT/$NAME.zip"
(
    cd "$OUTPUT"
    shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256"
)
print -- "Created $OUTPUT/$NAME.zip"
# A ZIP is an installable drag-to-Applications distribution and does not
# require disk-image mounting privileges. Developer ID/notarization is separate.
