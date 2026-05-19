#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="Recorder.app"
BIN_NAME="Recorder"

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64

BIN_PATH=$(swift build -c release --arch arm64 --show-bin-path)/$BIN_NAME
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Build did not produce expected binary at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> codesign (inside-out)"
# Prefer the stable "Recorder Dev" self-signed identity (set up by
# setup-dev-cert.sh) so TCC permission grants survive rebuilds.
# Falls back to ad-hoc if the cert isn't installed.
IDENTITY="Recorder Dev"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGN_AS="$IDENTITY"
else
    SIGN_AS="-"
    echo "    (no '$IDENTITY' identity found; using ad-hoc. Run ./setup-dev-cert.sh once to fix re-prompts.)"
fi
codesign --force --sign "$SIGN_AS" --timestamp=none "$APP/Contents/MacOS/$BIN_NAME"
codesign --force --sign "$SIGN_AS" "$APP"

echo "==> done: $APP"
