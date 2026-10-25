{ pkgs, src, package, sources, system, revision, release-tool }:
let
  name = "mypod-${package.version}-${system}";
in pkgs.runCommand "${name}-bundle" {
  nativeBuildInputs = [ release-tool pkgs.darwin.cctools pkgs.darwin.sigtool pkgs.gnutar pkgs.gzip ];
} ''
  mypod-release-tool bundle --package ${package} --source ${src} \
    --sources ${sources} --version ${package.version} --system ${system} \
    --revision ${pkgs.lib.escapeShellArg revision} --output "$TMPDIR/${name}"
  "$TMPDIR/${name}/bin/mypod" help > /dev/null
  mkdir -p "$out"
  tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
    -C "$TMPDIR" -cf - ${name} | gzip -n > "$out/${name}.tar.gz"
''
