#!/bin/bash
#
# Assembles WhereFilm.app from the SwiftPM executable.
#
#   ./Scripts/make-app.sh            # build complete app into ./build
#   ./Scripts/make-app.sh --open     # …and launch it
#
# There is no .xcodeproj on purpose: everything builds from the command line,
# and `open Package.swift` still gives you the full Xcode experience when you
# want a debugger.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
APP="build/WhereFilm.app"
MODELS_DIR="${WHEREFILM_MODELS_DIR:-$HOME/Library/Application Support/WhereFilm/Models}"

REQUIRED_MODEL_FILES=(
  "mobileclip_s0_image.mlmodelc"
  "mobileclip_s0_text.mlmodelc"
  "clip-vocab.json"
  "clip-merges.txt"
)

for model_file in "${REQUIRED_MODEL_FILES[@]}"; do
  [[ -e "$MODELS_DIR/$model_file" ]] || {
    echo "Missing $MODELS_DIR/$model_file" >&2
    echo "Install the model first with: ./Scripts/fetch-models.sh" >&2
    exit 1
  }
done

[[ -f "Brand/WhereFilm.icns" ]] || { echo "Missing Brand/WhereFilm.icns" >&2; exit 1; }
[[ -f "ThirdPartyLicenses/APPLE-MOBILECLIP-LICENSE.txt" ]] || {
  echo "Missing MobileCLIP license copy" >&2; exit 1;
}

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product WhereFilmApp

BINARY="$(swift build -c "$CONFIG" --show-bin-path)/WhereFilmApp"
[[ -f "$BINARY" ]] || { echo "Build produced no binary at $BINARY" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/WhereFilm"
cp "Brand/WhereFilm.icns" "$APP/Contents/Resources/WhereFilm.icns"
mkdir -p "$APP/Contents/Resources/Models" "$APP/Contents/Resources/Licenses"
for model_file in "${REQUIRED_MODEL_FILES[@]}"; do
  ditto "$MODELS_DIR/$model_file" "$APP/Contents/Resources/Models/$model_file"
done
cp "ThirdPartyLicenses/APPLE-MOBILECLIP-LICENSE.txt" \
   "$APP/Contents/Resources/Licenses/APPLE-MOBILECLIP-LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>WhereFilm</string>
    <key>CFBundleDisplayName</key>     <string>WhereFilm</string>
    <key>CFBundleIdentifier</key>      <string>gt.roo.wherefilm</string>
    <key>CFBundleExecutable</key>      <string>WhereFilm</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>WhereFilm.icns</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Copyright © 2026 WhereFilm</string>

    <!-- Menu-bar app: no Dock icon until a window is opened on purpose. -->
    <key>LSUIElement</key>             <true/>

    <!-- Deliberately absent: NSMicrophoneUsageDescription.
         Indexing reads audio tracks out of files on disk. The microphone is
         never opened, so the permission is never requested. -->
</dict>
</plist>
PLIST

# Ad-hoc signing keeps the bundle internally consistent. Because this build has
# no paid Developer ID, a different Mac must explicitly approve it once in
# System Settings → Privacy & Security. There is no safe free substitute for
# Apple's Developer ID + notarization path.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Built complete app: $APP"
echo "Included on-device models from: $MODELS_DIR"

if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
