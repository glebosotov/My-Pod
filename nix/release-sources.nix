{ pkgs, src, version }:
let
  lib = pkgs.lib;
  libraries = with pkgs; [ glib gdk-pixbuf gettext libplist libxml2 sqlite zlib pcre2 libpng libjpeg libffi darwin.libresolv ];
  entries = map (p: {
    name = lib.getName p;
    version = lib.getVersion p;
    src = p.src;
    outputs = lib.unique [ (toString p) (toString (lib.getLib p)) ];
    patches = map toString (p.patches or []);
    recipe = builtins.dirOf (builtins.head (lib.splitString ":" p.meta.position));
    licenses = map (l: l.spdxId or l.shortName) (lib.toList p.meta.license);
    homepage = p.meta.homepage or "";
  }) libraries;
  manifest = pkgs.writeText "mypod-release-sources.json" (builtins.toJSON entries);
  name = "mypod-${version}-sources";
in {
  inherit manifest;
  archive = pkgs.runCommand name {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    root="$TMPDIR/${name}"
    mkdir -p "$root/third-party"
    cp -R ${src} "$root/mypod"
    ${lib.concatMapStringsSep "\n" (entry: let
      metadata = pkgs.writeText "${entry.name}-metadata.json" (builtins.toJSON {
        inherit (entry) name version licenses homepage;
      } + "\n");
    in ''
      target="$root/third-party/${entry.name}-${entry.version}"
      mkdir -p "$target/patches"
      if [ -d ${entry.src} ]; then
        cp -R ${entry.src} "$target/source"
      else
        cp ${entry.src} "$target/"
      fi
      ${lib.concatMapStringsSep "\n" (patch: "cp ${lib.escapeShellArg patch} \"$target/patches/\"") entry.patches}
      cp -R ${entry.recipe} "$target/nix-recipe"
      cp ${metadata} "$target/metadata.json"
    '') entries}
    mkdir -p "$out"
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C "$TMPDIR" -cf - ${name} | gzip -n > "$out/${name}.tar.gz"
  '';
}
