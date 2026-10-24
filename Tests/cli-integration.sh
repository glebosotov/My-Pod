#!/bin/bash
# Mounted disk-image test; run in nix develop after build-nix.sh.
# Uses only a disposable HFS+ image, never an attached physical iPod.
set -euo pipefail
cd "$(dirname "$0")/.."
cli="${MYPOD_CLI:-$PWD/build/Build/Products/Release/mypod}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mypod-cli.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
attached=false
cleanup() {
  if $attached && ! hdiutil detach "$scratch/device" >/dev/null; then
    echo "Could not detach test image; retained at $scratch" >&2
    return
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/device" "$scratch/library"
python3 Tests/make-fixtures.py "$scratch/library"
hdiutil create -quiet -size 64m -fs HFS+ -volname MyPodCLITest "$scratch/ipod.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$scratch/device" "$scratch/ipod.dmg"
attached=true
/usr/bin/clang -Icore/libgpod/src -Icore/ipod-api \
  $(pkg-config --cflags glib-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0) \
  Tests/device-fixture.c core/ipod-api/ipod-api.c core/libgpod/src/.libs/libgpod.a \
  $(pkg-config --libs glib-2.0 gobject-2.0 gmodule-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0 sqlite3 zlib) \
  -o "$scratch/device-fixture"
"$scratch/device-fixture" "$scratch/device"
args=(--library "$scratch/library" --device "$scratch/device" --quality aac48 --cache "$scratch/cache")
before=$(shasum "$scratch/device/iPod_Control/iTunes/iTunesDB")
"$cli" plan "${args[@]}" > "$scratch/plan.json"
[ "$before" = "$(shasum "$scratch/device/iPod_Control/iTunes/iTunesDB")" ]
id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deviceID"])' "$scratch/plan.json")
if "$cli" sync "${args[@]}" --device-id definitely-wrong; then
  echo 'Wrong device ID was accepted' >&2; exit 1
fi
[ "$before" = "$(shasum "$scratch/device/iPod_Control/iTunes/iTunesDB")" ]
"$cli" sync "${args[@]}" --device-id "$id" > "$scratch/sync.json"
"$cli" plan "${args[@]}" > "$scratch/repeat.json"
python3 - "$scratch/sync.json" "$scratch/repeat.json" <<'PY'
import json, sys
result, plan = (json.load(open(p)) for p in sys.argv[1:])
assert result['added'] == 5 and result['tracks'] == 5
assert plan['add'] == [] and plan['remove'] == [] and plan['metadataUpdates'] == []
PY
# A failed preflight must preserve the existing library and leave the device mounted.
mkdir -p "$scratch/broken/Artist/Album"
printf 'invalid audio' > "$scratch/broken/Artist/Album/Broken.mp3"
before=$(shasum "$scratch/device/iPod_Control/iTunes/iTunesDB")
if "$cli" sync --library "$scratch/broken" --device "$scratch/device" --device-id "$id" --delete --eject; then
  echo 'Invalid audio was accepted' >&2; exit 1
fi
[ "$before" = "$(shasum "$scratch/device/iPod_Control/iTunes/iTunesDB")" ]
mount | rg -F " on $scratch/device (" >/dev/null
"$cli" sync "${args[@]}" --device-id "$id" --eject > "$scratch/eject.json"
python3 - "$scratch/eject.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['ejected'] is True
PY
if mount | rg -F " on $scratch/device ("; then
  echo 'Ejected volume is still mounted' >&2; exit 1
fi
attached=false
echo 'CLI plan, target verification, sync, idempotence and eject checks passed'
