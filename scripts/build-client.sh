#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
CLIENT_DIR="$ROOT_DIR/client"
BUILD_DIR="$CLIENT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist/mac"
APP_DIR="$DIST_DIR/MeetingClient.app"
LIVEKIT_CHECKOUT="$BUILD_DIR/checkouts/client-sdk-swift"
LIVEKIT_SCREEN_CAPTURER="$LIVEKIT_CHECKOUT/Sources/LiveKit/Track/Capturers/MacOSScreenCapturer.swift"
LIVEKIT_DYNAMIC_APPS_PATCH="$ROOT_DIR/patches/livekit-macos-dynamic-apps.patch"
RUNTIME_DIR="$ROOT_DIR/.runtime"
swift_options=(--disable-sandbox --skip-update --disable-automatic-resolution
    --cache-path "${MEETING_SWIFT_CACHE:-$RUNTIME_DIR/swiftpm-cache}"
    --config-path "$RUNTIME_DIR/swiftpm-config"
    --security-path "$RUNTIME_DIR/swiftpm-security")

cd "$CLIENT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

swift package "${swift_options[@]}" resolve
if ! /usr/bin/grep -Fq "excludingApplications: excludedApps" "$LIVEKIT_SCREEN_CAPTURER"; then
    /usr/bin/patch -V none -p1 -d "$LIVEKIT_CHECKOUT" < "$LIVEKIT_DYNAMIC_APPS_PATCH"
fi

swift run "${swift_options[@]}" MeetingCoreCheck
swift build "${swift_options[@]}" -c release --product MeetingClient

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/release/MeetingClient" "$APP_DIR/Contents/MacOS/MeetingClient"
# Do not ship local source paths and debug symbols in the public application.
strip -S "$APP_DIR/Contents/MacOS/MeetingClient"
cp -R "$BUILD_DIR/release/LiveKitWebRTC.framework" \
    "$APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework"
cp "$CLIENT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# SwiftPM resources are runtime dependencies too (including privacy manifests).
for resource_bundle in "$BUILD_DIR"/release/*.bundle(N); do
    cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done
python3 "$ROOT_DIR/scripts/collect-licenses.py" --platform macos \
    --output "$APP_DIR/Contents/Resources/Licenses"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_DIR/Contents/MacOS/MeetingClient"
codesign --force --sign - \
    "$APP_DIR/Contents/Frameworks/LiveKitWebRTC.framework"
codesign --force --sign - \
    --requirements '=designated => identifier "local.meeting.udp-client"' \
    "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR"
