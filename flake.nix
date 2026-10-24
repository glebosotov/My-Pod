{
  description = "My Pod native macOS build dependencies";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8ce73368d1efd4d657e9064d29b144a52046b4e8";
  outputs = { self, nixpkgs }: {
    devShells = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ pkg-config autoconf automake libtool gtk-doc intltool ffmpeg (python3.withPackages (p: [ p.mutagen ])) ];
          buildInputs = with pkgs; [ glib gdk-pixbuf libplist libxml2 sqlite zlib gettext ];
          # Use Apple's SDK/compiler for the Xcode application and C bridge.
          shellHook = ''
            export CC=/usr/bin/clang
            export LIBTOOLIZE=libtoolize
          '';
        };
      });
  };
}
