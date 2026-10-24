#!/bin/bash
# Run in the pinned shell: nix develop --command ./Scripts/build-nix.sh
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-libgpod.sh
derived="${MYPOD_BUILD_DIR:-build}"
packages=(glib-2.0 gobject-2.0 gmodule-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0 sqlite3 zlib)
cflags=$(pkg-config --cflags "${packages[@]}")
libs=$(pkg-config --libs "${packages[@]}")
export DEVELOPER_DIR="${MYPOD_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/usr/bin/xcodebuild -project 'My Pod.xcodeproj' -scheme 'My Pod' \
  -configuration Release -derivedDataPath "$derived" \
  "HEADER_SEARCH_PATHS=$PWD/core/ipod-api $PWD/core/libgpod/src" \
  "OTHER_CFLAGS=$cflags" \
  "OTHER_LDFLAGS=$PWD/core/libgpod/src/.libs/libgpod.a $libs" \
  'LD_RUNPATH_SEARCH_PATHS=' 'LIBRARY_SEARCH_PATHS=' \
  'LD=/usr/bin/clang' 'LDPLUSPLUS=/usr/bin/clang++' \
  "OTHER_SWIFT_FLAGS=${MYPOD_SWIFT_FLAGS:-}" build
ln -sf 'My Pod.app/Contents/MacOS/My Pod' "$derived/Build/Products/Release/mypod"
