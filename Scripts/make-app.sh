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
BUILT_HELPERS=()
SPEAKER_HELPER=""
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

  # The Vision helper. Without it the app still works — it falls back to running
  # Vision in-process behind the two-request gate — but it gives up the
  # throughput the extra processes exist for, and Apple's OCR crash stops being
  # contained.
  swift build -c "$CONFIG" \
    --triple "$triple" \
    --scratch-path "$scratch" \
    --product wherefilm-vision-helper

  binary="$scratch/$architecture-apple-macosx/$CONFIG/WhereFilmApp"
  [[ -f "$binary" ]] || {
    echo "Build produced no $architecture binary at $binary" >&2
    exit 1
  }
  BUILT_BINARIES+=("$binary")

  helper="$scratch/$architecture-apple-macosx/$CONFIG/wherefilm-vision-helper"
  [[ -f "$helper" ]] || {
    echo "Build produced no $architecture Vision helper at $helper" >&2
    exit 1
  }
  BUILT_HELPERS+=("$helper")

  # The speaker helper is arm64 only, and that is a fact about the dependency
  # rather than a decision: FluidAudio does not compile for x86_64, and its
  # models need a neural engine no Intel Mac has. Building it for arm64 and
  # skipping it elsewhere keeps one universal app that simply reports the
  # capability absent on hardware that could never have run it.
  if [[ "$architecture" == "arm64" ]]; then
    swift build -c "$CONFIG" \
      --triple "$triple" \
      --scratch-path "$scratch" \
      --product wherefilm-speaker-helper
    speaker="$scratch/$architecture-apple-macosx/$CONFIG/wherefilm-speaker-helper"
    [[ -f "$speaker" ]] || {
      echo "Build produced no arm64 speaker helper at $speaker" >&2
      exit 1
    }
    SPEAKER_HELPER="$speaker"
  fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BUILT_BINARIES[@]} -eq 1 ]]; then
  cp "${BUILT_BINARIES[0]}" "$APP/Contents/MacOS/WhereFilm"
else
  lipo -create "${BUILT_BINARIES[@]}" -output "$APP/Contents/MacOS/WhereFilm"
fi

mkdir -p "$APP/Contents/Helpers"
if [[ ${#BUILT_HELPERS[@]} -eq 1 ]]; then
  cp "${BUILT_HELPERS[0]}" "$APP/Contents/Helpers/wherefilm-vision-helper"
else
  lipo -create "${BUILT_HELPERS[@]}" -output "$APP/Contents/Helpers/wherefilm-vision-helper"
fi
chmod +x "$APP/Contents/Helpers/wherefilm-vision-helper"

if [[ -n "$SPEAKER_HELPER" ]]; then
  cp "$SPEAKER_HELPER" "$APP/Contents/Helpers/wherefilm-speaker-helper"
  chmod +x "$APP/Contents/Helpers/wherefilm-speaker-helper"
fi

for architecture in $ARCHITECTURES; do
  lipo "$APP/Contents/MacOS/WhereFilm" -verify_arch "$architecture"
  lipo "$APP/Contents/Helpers/wherefilm-vision-helper" -verify_arch "$architecture"
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
