#!/bin/bash
#
# Installs a real face recognition model.
#
#   ./Scripts/fetch-face-model.sh
#
# Without this, WhereFilm groups faces with Vision's general image feature
# print, which is not a face recognition model: it clusters near-duplicates well
# and tells people apart badly. Everything else — detection, quality gating,
# clustering, naming, merging, appearances, erasure — is the same code either
# way, because the descriptor sits behind a protocol and every vector records
# which model produced it. Installing this is a background reindex of the faces
# table and nothing more.
#
# ## What this downloads, and why this one
#
# AuraFace v1: a ResNet-100 trained with ArcFace's additive angular margin loss,
# published by fal and licensed Apache-2.0, trained on commercially available
# data specifically so it can be used commercially.
#
# That licence is the reason it was chosen over the better-known options.
# InsightFace's own weights and EdgeFace are research-only, and this app is
# already research-only because MobileCLIP is. A second non-commercial model
# would have made that permanent; an Apache-2.0 one leaves exactly one thing to
# replace if this ever stops being a gift.
#
# The Core ML conversion is fetched from `camstack/camstack-models`, which
# publishes coremltools exports of it. The upstream weights and their licence
# are fal's: https://huggingface.co/fal/AuraFace-v1
#
# ## The part that is your decision
#
# Face vectors are biometric data about people who did not choose to be in an
# index. Nothing here turns face analysis on — that is `wherefilm index --faces`
# — and `wherefilm people forget --yes` deletes every trace of it without
# touching anything else the library knows.

set -euo pipefail

cd "$(dirname "$0")/.."

MODELS_DIR="${WHEREFILM_MODELS_DIR:-$HOME/Library/Application Support/WhereFilm/Models}"
PACKAGE="$MODELS_DIR/auraface.mlpackage"
COMPILED="$MODELS_DIR/auraface.mlmodelc"
BASE="https://huggingface.co/camstack/camstack-models/resolve/main/faceRecognition/auraface/coreml/camstack-auraface-r100.mlpackage"

if [[ -d "$COMPILED" ]]; then
  echo "Already installed: $COMPILED"
  echo "Delete it to reinstall."
  exit 0
fi

mkdir -p "$PACKAGE/Data/com.apple.CoreML/weights"
echo "Downloading AuraFace (ArcFace R100, Apache-2.0) into $MODELS_DIR…"
curl -fsSL "$BASE/Manifest.json" -o "$PACKAGE/Manifest.json"
curl -fSL --progress-bar "$BASE/Data/com.apple.CoreML/model.mlmodel" \
  -o "$PACKAGE/Data/com.apple.CoreML/model.mlmodel"
curl -fSL --progress-bar "$BASE/Data/com.apple.CoreML/weights/weight.bin" \
  -o "$PACKAGE/Data/com.apple.CoreML/weights/weight.bin"

echo "· compiling for this Mac"
xcrun coremlcompiler compile "$PACKAGE" "$MODELS_DIR" >/dev/null
# The compiler names its output after the package; normalise it so the app has
# one path to look for.
if [[ -d "$MODELS_DIR/camstack-auraface-r100.mlmodelc" ]]; then
  rm -rf "$COMPILED"
  mv "$MODELS_DIR/camstack-auraface-r100.mlmodelc" "$COMPILED"
fi
rm -rf "$PACKAGE"

echo
du -sh "$COMPILED"
echo
echo "Installed. Faces indexed with the old descriptor are still there and will"
echo "not be compared with the new vectors — reindex them when you are ready:"
echo
echo "  wherefilm people forget --yes      # drop the old groupings"
echo "  wherefilm index --faces"
