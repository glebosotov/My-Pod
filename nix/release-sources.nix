{ pkgs }:
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
in pkgs.writeText "mypod-release-sources.json" (builtins.toJSON entries)
