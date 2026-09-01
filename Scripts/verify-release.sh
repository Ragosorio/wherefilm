#!/bin/bash
#
# Verifies the built app the way a new person meets it, then reports.
#
#   ./Scripts/verify-release.sh
#   ./Scripts/verify-release.sh build/WhereFilm.app
#
# What makes this worth having rather than trusting `swift test`: the unit tests
# never touch the models inside the app bundle, never scan a folder, and never
# create a window. This runs the actual bundle against a real fixture on a
# simulated clean machine — no installed models, empty index, isolated home —
# and lets the app do the whole journey itself: scan, index, search, render.
#
# The app inspects itself from inside its own process and exits non-zero on
# failure (see Sources/WhereFilmApp/Snapshot.swift). Deliberately no screen
# capture and no accessibility APIs: a screenshot photographs whatever else is
# on the display, which is a privacy surface a search tool should not open.

set -uo pipefail

cd "$(dirname "$0")/.."

APP="${1:-build/WhereFilm.app}"
BINARY="$APP/Contents/MacOS/WhereFilm"
RUN_ARCH="${WHEREFILM_RUN_ARCH:-}"
EXPECTED_ARCHS="${WHEREFILM_EXPECTED_ARCHS:-arm64 x86_64}"

[[ -x "$BINARY" ]] || {
  echo "No app at $APP — build one with ./Scripts/make-app.sh" >&2
  exit 1
}

case "$RUN_ARCH" in
  ""|arm64|x86_64) ;;
  *) echo "Unsupported WHEREFILM_RUN_ARCH: $RUN_ARCH" >&2; exit 1 ;;
esac

for architecture in $EXPECTED_ARCHS; do
  lipo "$BINARY" -verify_arch "$architecture" || {
    echo "The app is missing its $architecture executable slice." >&2
    exit 1
  }
done

RUNNER=("$BINARY")
if [[ -n "$RUN_ARCH" ]]; then
  RUNNER=(/usr/bin/arch "-$RUN_ARCH" "$BINARY")
fi

# The bundled models are the path every downloaded copy takes. If they are
# missing, this whole run would silently fall back to a developer's own install
# and prove nothing.
for model in mobileclip_s0_image.mlmodelc mobileclip_s0_text.mlmodelc \
             clip-vocab.json clip-merges.txt; do
  [[ -e "$APP/Contents/Resources/Models/$model" ]] || {
    echo "The bundle is missing $model — a downloaded copy could not search." >&2
    exit 1
  }
done

# A copy left running from an earlier attempt competes for the same SQLite file
# and the same Neural Engine, which shows up as an indexer that appears to hang.
pkill -f 'WhereFilm.app/Contents/MacOS/WhereFilm' 2>/dev/null && sleep 1

ROOT="$(mktemp -d /private/tmp/wherefilm-verify.XXXXXX)"
trap '[[ ${KEEP_FIXTURE:-0} == 1 ]] || rm -rf "$ROOT"' EXIT

echo "Building a real fixture — genuine photographs and Spanish speech."
swift Scripts/make-test-library.swift "$ROOT/library" >/dev/null 2>&1 || {
  echo "Could not build the test library." >&2
  exit 1
}

echo
printf '%s\n' "─────────────────────────────────────────────────────────"
echo "Signing"
codesign -dv "$APP" 2>&1 | grep -E "^Signature|^TeamIdentifier" | sed 's/^/  /'
echo "  Architectures: $(lipo -archs "$BINARY")"
[[ -z "$RUN_ARCH" ]] || echo "  Exercising slice: $RUN_ARCH"
echo "  → adhoc means one manual approval on someone else's Mac."
printf '%s\n' "─────────────────────────────────────────────────────────"

# query | expectation | required result
CASES=(
  "atardecer frente al mar|found|SUNSET_0005.heic"
  "carretera entre árboles|found|ROAD_0006.heic"
  "acantilados junto al mar|found|CLIFFS_0004.heic"   # plural, absent from dictionary singulars
  "donde hablaron del presupuesto|found|INTERVIEW_JUAN_03.mov"   # dialogue only
  "un plato de espagueti|empty|"      # nothing in the library honestly matches
  "un gato jugando con una pelota|empty|"
)

failures=0
for entry in "${CASES[@]}"; do
  query="${entry%%|*}"
  remainder="${entry#*|}"
  expectation="${remainder%%|*}"
  expected_result="${remainder#*|}"

  home="$ROOT/home-$(echo "$query" | md5 -q | cut -c1-8)"
  mkdir -p "$home"

  # A plain string, not an array: macOS still ships bash 3.2, where expanding
  # an empty array under `set -u` is an error rather than nothing.
  expect_empty=""
  [[ "$expectation" == "empty" ]] && expect_empty="WHEREFILM_QA_EXPECT_EMPTY=1"

  echo
  echo "▸ “${query}”   (espera: ${expectation})"
  if env WHEREFILM_HOME="$home" \
         WHEREFILM_QA_LIBRARY="$ROOT/library" \
         WHEREFILM_DEMO_QUERY="$query" \
         WHEREFILM_QA_EXPECT_RESULT="$expected_result" \
         WHEREFILM_QA_REPORT=1 \
         WHEREFILM_QA_TIMEOUT="${WHEREFILM_QA_TIMEOUT:-180}" \
         ${expect_empty} \
         "${RUNNER[@]}" 2>&1 | sed 's/^/  /'
  then
    :
  else
    failures=$((failures + 1))
  fi
done

echo
printf '%s\n' "─────────────────────────────────────────────────────────"
if [[ $failures -eq 0 ]]; then
  echo "All ${#CASES[@]} cases passed. This bundle is shippable."
  exit 0
fi
echo "$failures of ${#CASES[@]} cases failed."
exit 1
