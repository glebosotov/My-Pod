{ lib, stdenv, swift, libarchive }:
stdenv.mkDerivation {
  pname = "mypod-release-tool";
  version = "1";
  src = lib.fileset.toSource {
    root = ../Scripts;
    fileset = lib.fileset.unions [ ../Scripts/ReleaseTool.swift ../Scripts/CArchive ];
  };
  strictDeps = true;
  nativeBuildInputs = [ swift ];
  buildInputs = [ libarchive ];
  dontConfigure = true;
  buildPhase = ''
    swiftc -O -I CArchive -Xcc -I${libarchive.dev}/include \
      -L${libarchive.lib}/lib ReleaseTool.swift -o release-tool
  '';
  installPhase = ''
    install -Dm755 release-tool "$out/bin/mypod-release-tool"
  '';
  meta.mainProgram = "mypod-release-tool";
}
