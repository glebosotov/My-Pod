{ lib, stdenvNoCC, fetchurl, release, system }:
let
  bundle = release.bundles.${system};
in stdenvNoCC.mkDerivation {
  pname = "mypod";
  inherit (release) version;
  src = fetchurl {
    url = bundle.url;
    hash = bundle.hash;
  };
  dontConfigure = true;
  dontBuild = true;
  # The archive is already signed and relocatable. Strip/fixup would invalidate it.
  dontFixup = true;
  installPhase = ''
    mkdir -p "$out"
    cp -R . "$out/"
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/mypod" help | grep -q 'Usage: mypod'
  '';
  meta = {
    description = "Prebuilt tag-aware music sync CLI for classic iPods";
    homepage = "https://github.com/glebosotov/My-Pod";
    license = [ lib.licenses.mit lib.licenses.lgpl21Plus ];
    platforms = lib.platforms.darwin;
    mainProgram = "mypod";
  };
}
