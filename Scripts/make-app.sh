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
VERSION="${VERSION:-0.3.1}"
APP="build/WhereFilm.app"
MODELS_DIR="${WHEREFILM_MODELS_DIR:-$HOME/Library/Application Support/WhereFilm/Models}"
MIN_MACOS="${WHEREFILM_MIN_MACOS:-26.0}"
# One bundle for both families. Override only for local diagnostics, e.g.
# WHEREFILM_ARCHS="x86_64" ./Scripts/make-app.sh
ARCHITECTURES="${WHEREFILM_ARCHS:-arm64 x86_64}"

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

BUILT_BINARIES=()
for architecture in $ARCHITECTURES; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
  esac

  scratch=".build-$architecture"
  triple="$architecture-apple-macosx$MIN_MACOS"
  echo "Building $architecture ($CONFIG)…"
  swift build -c "$CONFIG" \
    --triple "$triple" \
    --scratch-path "$scratch" \
    --product WhereFilmApp

  binary="$scratch/$architecture-apple-macosx/$CONFIG/WhereFilmApp"
  [[ -f "$binary" ]] || {
    echo "Build produced no $architecture binary at $binary" >&2
    exit 1
  }
  BUILT_BINARIES+=("$binary")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BUILT_BINARIES[@]} -eq 1 ]]; then
  cp "${BUILT_BINARIES[0]}" "$APP/Contents/MacOS/WhereFilm"
else
  lipo -create "${BUILT_BINARIES[@]}" -output "$APP/Contents/MacOS/WhereFilm"
fi

for architecture in $ARCHITECTURES; do
  lipo "$APP/Contents/MacOS/WhereFilm" -verify_arch "$architecture"
done
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
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Copyright © 2026 WhereFilm</string>

    <!-- Deliberately NOT LSUIElement. An agent app is invisible to Spotlight's
         Applications category, to Launchpad, to the Dock and to Cmd-Tab, which
         is exactly why WhereFilm did not "look like an app". It is a normal
         application that also happens to keep a menu-bar item. Someone who
         wants it out of the Dock can turn that on in the menu; the default is
         to be findable. -->

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
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/WhereFilm")"
echo "Included on-device models from: $MODELS_DIR"

if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
