#!/bin/bash
#
# Downloads the on-device models WhereFilm needs and compiles them for Core ML.
#
# Nothing here is bundled with the app: the weights are a few hundred megabytes,
# they are licensed by Apple under ASCL, and keeping them out of the repository
# keeps the checkout small and the licensing clean.
#
#   ./Scripts/fetch-models.sh          # MobileCLIP-S0 (default, smallest)
#   ./Scripts/fetch-models.sh s2       # better recall, ~2.4x the image cost
#
# Speech models are NOT downloaded here — macOS manages those itself through
# AssetInventory, which is exactly why they don't inflate the app.

set -euo pipefail

VARIANT="${1:-s0}"
MODELS_DIR="${WHEREFILM_MODELS_DIR:-$HOME/Library/Application Support/WhereFilm/Models}"
HF="https://huggingface.co"

case "$VARIANT" in
  s0|s1|s2|blt) ;;
  *) echo "Unknown variant '$VARIANT'. Use s0, s1, s2 or blt." >&2; exit 1 ;;
esac

mkdir -p "$MODELS_DIR"
echo "Installing into: $MODELS_DIR"
echo

# ---------------------------------------------------------------------------
# CLIP tokenizer assets
#
# MobileCLIP uses the standard CLIP byte-level BPE vocabulary. openai/clip-vit-
# base-patch32 is the canonical source for the exact vocab.json / merges.txt
# pair, and it is what the Swift tokenizer was verified against.
# ---------------------------------------------------------------------------
fetch_tokenizer() {
  local base="$HF/openai/clip-vit-base-patch32/resolve/main"
  if [[ ! -f "$MODELS_DIR/clip-vocab.json" ]]; then
    echo "· CLIP vocabulary"
    curl -fsSL "$base/vocab.json" -o "$MODELS_DIR/clip-vocab.json"
  fi
  if [[ ! -f "$MODELS_DIR/clip-merges.txt" ]]; then
    echo "· CLIP merges"
    curl -fsSL "$base/merges.txt" -o "$MODELS_DIR/clip-merges.txt"
  fi
}

# ---------------------------------------------------------------------------
# Core ML encoders
#
# An .mlpackage is a directory, so each of its three parts is fetched
# individually rather than cloning the whole (multi-gigabyte) repository.
# ---------------------------------------------------------------------------
fetch_mlpackage() {
  local name="$1"
  local target="$MODELS_DIR/$name.mlpackage"
  local base="$HF/apple/coreml-mobileclip/resolve/main/$name.mlpackage"

  if [[ -d "$MODELS_DIR/$name.mlmodelc" ]]; then
    echo "· $name — already compiled"
    return
  fi

  echo "· $name"
  mkdir -p "$target/Data/com.apple.CoreML/weights"
  curl -fsSL "$base/Manifest.json" -o "$target/Manifest.json"
  curl -fSL --progress-bar "$base/Data/com.apple.CoreML/model.mlmodel" \
    -o "$target/Data/com.apple.CoreML/model.mlmodel"
  curl -fSL --progress-bar "$base/Data/com.apple.CoreML/weights/weight.bin" \
    -o "$target/Data/com.apple.CoreML/weights/weight.bin"
}

# Compiling ahead of time means the first search doesn't pay for it.
compile_model() {
  local name="$1"
  local package="$MODELS_DIR/$name.mlpackage"
  local compiled="$MODELS_DIR/$name.mlmodelc"

  [[ -d "$compiled" ]] && return
  echo "· compiling $name"
  xcrun coremlcompiler compile "$package" "$MODELS_DIR" >/dev/null
  rm -rf "$package"
}

fetch_tokenizer

IMAGE_MODEL="mobileclip_${VARIANT}_image"
TEXT_MODEL="mobileclip_${VARIANT}_text"

fetch_mlpackage "$IMAGE_MODEL"
fetch_mlpackage "$TEXT_MODEL"
compile_model "$IMAGE_MODEL"
compile_model "$TEXT_MODEL"

echo
echo "Done. Installed:"
du -sh "$MODELS_DIR"/*.mlmodelc "$MODELS_DIR"/clip-*.* 2>/dev/null || true
echo
echo "Verify with:  swift run wherefilm doctor"
