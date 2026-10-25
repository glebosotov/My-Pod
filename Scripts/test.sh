#!/bin/bash
# Run in the pinned shell: nix develop .#tests --command ./Scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mypod-tests.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/library" "$scratch/device"
export DEVELOPER_DIR="${MYPOD_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/usr/bin/xcrun swiftc Tests/FixtureTool.swift -o "$scratch/fixture-tool"
"$scratch/fixture-tool" generate "$scratch/library"
MYPOD_SWIFT_FLAGS=-DMYPOD_TESTS MYPOD_BUILD_DIR=build-tests ./Scripts/build-nix.sh
/usr/bin/clang -Icore/libgpod/src -Icore/ipod-api \
  $(pkg-config --cflags glib-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0) \
  Tests/device-fixture.c core/ipod-api/ipod-api.c core/libgpod/src/.libs/libgpod.a \
  $(pkg-config --libs glib-2.0 gobject-2.0 gmodule-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0 sqlite3 zlib) \
  -o "$scratch/device-fixture"
"$scratch/device-fixture" "$scratch/device"
build-tests/Build/Products/Release/mypod "$scratch/library" "$scratch/device"
