#!/bin/bash
#
# Builds the complete app and the drag-to-Applications disk image people expect
# from a Mac app, plus a ZIP fallback.
#
#   ./Scripts/make-dmg.sh
#   VERSION=0.3.1 ./Scripts/make-dmg.sh
#
# On signing: this edition is ad-hoc signed, not signed with a paid Apple
# Developer ID and not notarized. That is a deliberate, stated constraint, and it
# has one visible consequence — verified, not assumed, by stamping a real
# download quarantine on the result and asking Gatekeeper:
#
#   spctl -a -vvv WhereFilm.app  →  rejected
#
# So the first launch on someone else's Mac needs one manual approval in
# System Settings → Privacy & Security. There is no free substitute for
# Developer ID + notarization, and nothing here tries to disable or work around
# Gatekeeper: the app is simply approved once, by the person who owns the Mac.

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.1}"
DMG_NAME="WhereFilm-$VERSION-macOS-universal.dmg"
ZIP_NAME="WhereFilm-$VERSION-macOS-universal.zip"
DMG="build/$DMG_NAME"
ZIP="build/$ZIP_NAME"
STAGING_ROOT="$(mktemp -d /private/tmp/wherefilm-dmg.XXXXXX)"
STAGING="$STAGING_ROOT/WhereFilm"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

VERSION="$VERSION" ./Scripts/make-app.sh

mkdir -p "$STAGING"
ditto "build/WhereFilm.app" "$STAGING/WhereFilm.app"
ln -s /Applications "$STAGING/Applications"

# The mounted volume shows the app's own icon instead of a generic disk. Small
# thing; it is most of the difference between a download that feels finished and
# one that feels improvised.
cp "Brand/WhereFilm.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING" 2>/dev/null || true

# Named to sort first in the Finder window, and written for someone who has
# never been asked to approve an app before.
cat > "$STAGING/1 · LÉEME PRIMERO.txt" <<'README'
WHEREFILM
Encuentra tus fotos y videos describiéndolos con tus palabras.


CÓMO INSTALARLA

1. Arrastra WhereFilm a la carpeta Applications, aquí al lado.
2. Abre WhereFilm desde Applications.
3. La primera vez, tu Mac dirá que no puede comprobar quién la hizo.
   Es normal: esta versión no paga la licencia de distribución de Apple.
   Pulsa "Aceptar" y sigue con el paso 4.
4. Abre  Configuración del Sistema › Privacidad y seguridad.
   Baja hasta el aviso sobre WhereFilm y pulsa "Abrir de todas formas".
5. Confirma "Abrir". Listo — no tendrás que repetirlo nunca más.


SI NO APARECE EN SPOTLIGHT NI EN LAUNCHPAD

Cuando una app descargada sigue marcada como "en cuarentena", macOS puede
ejecutarla desde una copia temporal y dejar registrada esa copia en vez de
la que está en Applications. El síntoma es exacto: la app abre, pero no
aparece al buscarla ni en el Dock. Se arregla en una línea, en Terminal:

    xattr -dr com.apple.quarantine /Applications/WhereFilm.app

Después ciérrala y vuelve a abrirla desde Applications. Esto no desactiva
Gatekeeper ni salta ninguna protección: solo le quita a esa copia la marca
de "recién descargada", después de que tú ya la aprobaste en el paso 4.


CÓMO USARLA

· WhereFilm es una app normal: está en Applications, en Launchpad y en
  Spotlight, y tiene su icono en el Dock mientras está abierta.
· También vive en la barra de menús, arriba a la derecha. Si prefieres que
  solo viva ahí, usa "Ocultar del Dock" en ese menú.
· Pulsa ⌘ + ⇧ + Espacio para buscar en cualquier momento.
· Añade una carpeta o un disco y deja que trabaje en segundo plano.
· Escribe lo que recuerdas: "atardecer frente al mar",
  "carretera entre árboles", "donde hablaron del presupuesto".


TU ARCHIVO NO SALE DE TU MAC

No hay nube, no hay cuenta y no hay copias. Tus originales se quedan
exactamente donde están; WhereFilm solo guarda un índice y unas vistas
previas pequeñas, en esta Mac.


USO DE ESTA VISTA PREVIA

Esta edición es experimental, para evaluación personal y no comercial.
Apple Machine Learning Research Model is licensed under the Apple Machine
Learning Research Model License Agreement. Encontrarás el acuerdo completo
dentro de WhereFilm.app, en Contents/Resources/Licenses.
README

hdiutil create \
  -volname "WhereFilm" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

ditto -c -k --sequesterRsrc --keepParent "build/WhereFilm.app" "$ZIP"
(
  cd build
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "SHA256SUMS.txt"
)

echo
echo "Built:"
ls -lh "$DMG" "$ZIP" "build/SHA256SUMS.txt"
echo
echo "Signing (expected for this edition):"
codesign -dv "build/WhereFilm.app" 2>&1 | grep -E "^Signature|^TeamIdentifier" || true
echo "  → first launch elsewhere needs one approval in Privacy & Security."
