#!/bin/bash
#
# Assembles WhereFilm.app from the SwiftPM executable.
#
#   ./Scripts/make-app.sh            # build into ./build/WhereFilm.app
#   ./Scripts/make-app.sh --open     # …and launch it
#
# There is no .xcodeproj on purpose: everything builds from the command line,
# and `open Package.swift` still gives you the full Xcode experience when you
# want a debugger.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/WhereFilm.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product WhereFilmApp

BINARY="$(swift build -c "$CONFIG" --show-bin-path)/WhereFilmApp"
[[ -f "$BINARY" ]] || { echo "Build produced no binary at $BINARY" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/WhereFilm"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>WhereFilm</string>
    <key>CFBundleDisplayName</key>     <string>WhereFilm</string>
    <key>CFBundleIdentifier</key>      <string>gt.roo.wherefilm</string>
    <key>CFBundleExecutable</key>      <string>WhereFilm</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>

    <!-- Menu-bar app: no Dock icon until a window is opened on purpose. -->
    <key>LSUIElement</key>             <true/>

    <!-- Deliberately absent: NSMicrophoneUsageDescription.
         Indexing reads audio tracks out of files on disk. The microphone is
         never opened, so the permission is never requested. -->
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. Shipping this to someone else needs a
# Developer ID certificate and notarisation (US$99/year Apple Developer Program).
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null \
    || echo "· could not sign — the app will still run locally"

echo "Built $APP"
echo
echo "Before first use, install the visual model:"
echo "  ./Scripts/fetch-models.sh"

if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
