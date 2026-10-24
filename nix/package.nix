{ lib, stdenv, autoreconfHook, pkg-config, gtk-doc, intltool, glib, gdk-pixbuf
, libplist, libxml2, sqlite, zlib, gettext, swift, src }:
let
  libraries = [ glib gdk-pixbuf libplist libxml2 sqlite zlib gettext ];
  vendoredGpod = stdenv.mkDerivation {
    pname = "mypod-libgpod";
    version = "0.8.3-vendored";
    src = ../core/libgpod;
    nativeBuildInputs = [ autoreconfHook pkg-config gtk-doc intltool ];
    buildInputs = libraries;
    configureFlags = [
      "--disable-udev" "--disable-pygobject" "--disable-more-warnings"
      "--disable-shared" "--enable-static" "--disable-gtk-doc"
    ];
    enableParallelBuilding = true;
    postConfigure = ''
      grep -q '^#define HAVE_GDKPIXBUF' config.h
    '';
    buildPhase = ''
      runHook preBuild
      make -C src -j"$NIX_BUILD_CORES"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib" "$out/include"
      cp src/.libs/libgpod.a "$out/lib/"
      cp src/*.h "$out/include/"
      runHook postInstall
    '';
    meta.license = lib.licenses.lgpl21Plus;
  };
in stdenv.mkDerivation {
  pname = "mypod";
  version = "1.9.1";
  inherit src;
  strictDeps = true;
  nativeBuildInputs = [ swift pkg-config ];
  buildInputs = libraries ++ [ vendoredGpod ];
  dontConfigure = true;
  postPatch = ''
    # Xcode uses MainActor-by-default and opts these value types out. Swift
    # 5.10 has no type-level nonisolated attribute or global isolation default:
    # value types are already nonisolated. Preserve that behavior for this CLI.
    sed -i -E 's/nonisolated (struct|enum)/\1/g' "My Pod"/Models/*.swift "My Pod"/Services/*.swift "My Pod/Log.swift"
  '';
  buildPhase = ''
    runHook preBuild
    packages=(glib-2.0 gobject-2.0 gmodule-2.0 gdk-pixbuf-2.0 libplist-2.0 libxml-2.0 sqlite3 zlib)
    $CC -c core/ipod-api/ipod-api.c -o ipod-api.o \
      -Icore/ipod-api -I${vendoredGpod}/include \
      $(pkg-config --cflags "''${packages[@]}")
    services=(AudioMetadataReader AudioProbe ArtworkLocator ArtworkSync CacheInventory CacheLocation
      ConversionCeiling ConversionService EmbeddedArtwork EmbeddedTags FLACHeader LibraryScanner
      M3UParser MP4Lyrics MyPodCLI SyncEngine TrackMatching)
    sources=("My Pod"/Models/*.swift "My Pod/Log.swift" CLI/Entry.swift)
    for service in "''${services[@]}"; do sources+=("My Pod/Services/$service.swift"); done
    swiftc -O -parse-as-library -D MYPOD_CLI \
      -target ${if stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"}-apple-macos14.0 \
      -import-objc-header core/ipod-api/ipod-api.h \
      "''${sources[@]}" ipod-api.o ${vendoredGpod}/lib/libgpod.a \
      $(pkg-config --libs "''${packages[@]}") -o mypod
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 mypod "$out/bin/mypod"
    mkdir -p "$out/share/mypod"
    # Complete corresponding source for the statically linked LGPL library.
    ln -s ${src} "$out/share/mypod/source"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/mypod" help | grep -q 'Usage: mypod'
  '';
  meta = {
    description = "Tag-aware music sync and safe eject for classic iPods";
    homepage = "https://github.com/glebosotov/My-Pod";
    license = [ lib.licenses.mit lib.licenses.lgpl21Plus ];
    platforms = lib.platforms.darwin;
    mainProgram = "mypod";
  };
}
