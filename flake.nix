{
  description = "My Pod CLI and native macOS development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8ce73368d1efd4d657e9064d29b144a52046b4e8";
  outputs = { self, nixpkgs }:
  let
    systems = [ "aarch64-darwin" "x86_64-darwin" ];
    forAllSystems = f: builtins.listToAttrs (builtins.map (system: { name = system; value = f system; }) systems);
    release = builtins.fromJSON (builtins.readFile ./nix/releases.json);
  in {
    packages = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        fromSource = pkgs.callPackage ./nix/package.nix { src = self; };
        mypod = pkgs.callPackage ./nix/prebuilt.nix { inherit release system; };
        sources = import ./nix/release-sources.nix { inherit pkgs; };
        bundle = import ./nix/bundle.nix {
          inherit pkgs sources system;
          src = self;
          package = fromSource;
          revision = self.rev or (self.dirtyRev or "uncommitted");
        };
        release-sources = pkgs.runCommand "mypod-${fromSource.version}-sources" {
          nativeBuildInputs = [ pkgs.python3 pkgs.gnutar pkgs.gzip ];
        } ''
          python ${self}/Scripts/archive-sources.py --source ${self} \
            --manifest ${sources} --output "$TMPDIR/mypod-${fromSource.version}-sources"
          mkdir -p "$out"
          tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
            -C "$TMPDIR" -cf - mypod-${fromSource.version}-sources | gzip -n \
            > "$out/mypod-${fromSource.version}-sources.tar.gz"
        '';
      in { inherit mypod bundle release-sources; from-source = fromSource; default = mypod; });
    apps = forAllSystems (system:
      let
        bundle = release.bundles.${system};
        # Fetch directly: running a release needs neither a compiler nor a build shell.
        binary = builtins.fetchTarball { url = bundle.url; sha256 = bundle.unpackedHash; };
      in {
        default = { type = "app"; program = "${binary}/bin/mypod"; };
        mypod = self.apps.${system}.default;
        from-source = { type = "app"; program = "${self.packages.${system}.from-source}/bin/mypod"; };
      });
    checks = forAllSystems (system: { cli = self.packages.${system}.mypod; });
    devShells = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ pkg-config autoconf automake libtool gtk-doc intltool ripgrep ffmpeg (python3.withPackages (p: [ p.mutagen ])) ];
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
