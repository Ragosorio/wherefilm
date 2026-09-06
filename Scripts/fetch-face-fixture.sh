#!/bin/bash
#
# Downloads a small set of freely-licensed photographs of real people, so face
# recognition can be measured instead of assumed.
#
#   ./Scripts/fetch-face-fixture.sh /tmp/wherefilm-faces
#
# Everything else in this project can be tested with what the Mac already has.
# Faces cannot: Vision does not detect drawn or synthetic faces at all (measured,
# 0/3 on carefully constructed ones), and clustering is only meaningful with
# *several different photographs of the same person* — different light, angle,
# year, haircut. That is exactly what a Wikimedia Commons category of a public
# figure provides, and it is freely licensed.
#
# The images are NOT committed. They are third-party works under CC/PD licences,
# they are large, and a fixture that has to be downloaded is a fixture nobody
# accidentally ships. `attribution.txt` records author and licence for each file,
# because CC BY-SA asks for credit and that costs nothing to honour.

set -euo pipefail

OUT="${1:-/tmp/wherefilm-faces}"
PER_PERSON="${PER_PERSON:-8}"
WIDTH="${WIDTH:-1024}"

# Public figures with large Commons categories, chosen only for having many
# photographs by many photographers across many years — which is the hard case
# for a face model, and the realistic one for an archive.
PEOPLE=(
  "ANGELA:Category:Angela Merkel"
  "OBAMA:Category:Official portraits of Barack Obama"
  "GRETA:Category:Greta Thunberg"
  "ARDERN:Category:Jacinda Ardern"
  "TRUDEAU:Category:Justin Trudeau"
  "MALALA:Category:Malala Yousafzai"
)

mkdir -p "$OUT"
: > "$OUT/attribution.txt"

for entry in "${PEOPLE[@]}"; do
  name="${entry%%:*}"
  category="${entry#*:}"
  echo "· $name — $category"
  mkdir -p "$OUT/$name"

  python3 - "$category" "$name" "$OUT" "$PER_PERSON" "$WIDTH" <<'PY'
import json, sys, urllib.parse, urllib.request, os

category, name, out, limit, width = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
api = ("https://commons.wikimedia.org/w/api.php?action=query"
       "&generator=categorymembers&gcmtitle=" + urllib.parse.quote(category) +
       "&gcmtype=file&gcmlimit=" + str(limit * 3) +
       "&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=" + str(width) + "&format=json")
request = urllib.request.Request(api, headers={"User-Agent": "WhereFilm-test-fixture/1.0"})
pages = (json.load(urllib.request.urlopen(request)).get("query") or {}).get("pages", {})

saved = 0
with open(os.path.join(out, "attribution.txt"), "a") as credits:
    for page in pages.values():
        if saved >= limit:
            break
        info = (page.get("imageinfo") or [{}])[0]
        url = info.get("thumburl") or info.get("url")
        if not url or not url.lower().split("?")[0].endswith((".jpg", ".jpeg", ".png")):
            continue
        meta = info.get("extmetadata") or {}
        licence = (meta.get("LicenseShortName") or {}).get("value", "unknown")
        # Public-domain and CC images only; anything unclear is skipped rather
        # than assumed.
        if not any(token in licence.lower() for token in ("cc", "public domain", "pd")):
            continue
        artist = (meta.get("Artist") or {}).get("value", "unknown")
        artist = " ".join(artist.replace("<", " <").split())[:120]
        target = os.path.join(out, name, f"{name}_{saved:02d}.jpg")
        try:
            with urllib.request.urlopen(
                urllib.request.Request(url, headers={"User-Agent": "WhereFilm-test-fixture/1.0"})
            ) as response, open(target, "wb") as handle:
                handle.write(response.read())
        except Exception as error:
            print(f"  ! {error}")
            continue
        credits.write(f"{name}/{os.path.basename(target)}\t{licence}\t{artist}\n")
        saved += 1
print(f"  {saved} images")
PY
done

echo
echo "Fixture at $OUT"
find "$OUT" -name "*.jpg" | wc -l | xargs echo "  images:"
echo "  credits: $OUT/attribution.txt"
echo
echo "Index it in an isolated home so your real library is untouched:"
echo "  WHEREFILM_HOME=/tmp/wf-faces-home wherefilm scan $OUT --index --faces"
