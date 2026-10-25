#!/bin/bash
# Run with nix develop .#tests --command ./Tests/release-tool.sh.
# Synthetic artifacts exercise validation without downloading release assets.
set -euo pipefail
cd "$(dirname "$0")/.."
tool="${MYPOD_RELEASE_TOOL:-$(nix build .#release-tool --no-link --print-out-paths)/bin/mypod-release-tool}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mypod-release-tests.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
revision=0123456789012345678901234567890123456789
mkdir -p "$scratch/artifacts" "$scratch/tree/mypod-1.2.3-sources/mypod/core/libgpod" \
  "$scratch/tree/mypod-1.2.3-sources/third-party/example-1"
printf 'license\n' > "$scratch/tree/mypod-1.2.3-sources/mypod/core/libgpod/COPYING"
for system in aarch64-darwin x86_64-darwin; do
  directory="$scratch/artifacts/mypod-$system"
  root="mypod-1.2.3-$system"
  mkdir -p "$directory" "$scratch/tree/$root/bin"
  printf '%s\n' "$revision" > "$directory/SOURCE_REVISION"
  printf 'fixture\n' > "$scratch/tree/$root/bin/mypod"
  cat > "$scratch/tree/$root/bundle.json" <<JSON
{"version":"1.2.3","system":"$system","sourceRevision":"$revision","correspondingSources":"mypod-1.2.3-sources.tar.gz","libraries":[{"name":"example","version":"1","licenses":["MIT"],"homepage":""}]}
JSON
  tar -czf "$directory/$root.tar.gz" -C "$scratch/tree" "$root"
done
arm="$scratch/artifacts/mypod-aarch64-darwin"
tar -czf "$arm/mypod-1.2.3-sources.tar.gz" -C "$scratch/tree" mypod-1.2.3-sources
checksums() {
  for system in aarch64-darwin x86_64-darwin; do
    (cd "$scratch/artifacts/mypod-$system"; shasum -a 256 *.tar.gz > SHA256SUMS)
  done
}
pin() { "$tool" pin --artifacts "$scratch/artifacts" --revision "$revision" --output "$scratch/release.json"; }
reject() {
  local before
  before=$(shasum "$scratch/release.json")
  if pin > "$scratch/error" 2>&1; then echo "Accepted invalid artifacts: $1" >&2; exit 1; fi
  if ! rg -q "$2" "$scratch/error"; then cat "$scratch/error" >&2; exit 1; fi
  [ "$before" = "$(shasum "$scratch/release.json")" ]
  printf 'Rejected %s\n' "$1"
}
checksums
pin
[ "$(/usr/bin/plutil -extract version raw -o - "$scratch/release.json")" = 1.2.3 ]
[ "$(/usr/bin/plutil -extract bundles.aarch64-darwin.hash raw -o - "$scratch/release.json")" = "sha256-$(shasum -a 256 "$arm/mypod-1.2.3-aarch64-darwin.tar.gz" | cut -d ' ' -f1 | xxd -r -p | base64)" ]
printf wrong > "$arm/SOURCE_REVISION"
reject provenance 'wrong source revision'
printf '%s\n' "$revision" > "$arm/SOURCE_REVISION"
printf corrupt >> "$arm/mypod-1.2.3-sources.tar.gz"
reject 'source checksum' 'Invalid or duplicate checksum'
tar -czf "$arm/mypod-1.2.3-sources.tar.gz" -C "$scratch/tree" mypod-1.2.3-sources
root=mypod-1.2.3-aarch64-darwin
cp "$arm/$root.tar.gz" "$scratch/valid.tar.gz"
printf 'invalid archive' > "$arm/$root.tar.gz"
checksums
reject 'malformed archive' 'Cannot open archive'
cp "$scratch/valid.tar.gz" "$arm/$root.tar.gz"
ln -s /etc/passwd "$scratch/tree/$root/link"
tar -czf "$arm/$root.tar.gz" -C "$scratch/tree" "$root"
checksums
reject symlink 'Unsafe or duplicate'
rm "$scratch/tree/$root/link"
ln "$scratch/tree/$root/bin/mypod" "$scratch/tree/$root/hardlink"
tar -czf "$arm/$root.tar.gz" -C "$scratch/tree" "$root"
checksums
reject hardlink 'Unsafe or duplicate'
rm "$scratch/tree/$root/hardlink"
tar -czf "$arm/$root.tar.gz" -C "$scratch/tree" "$root" "$root/bundle.json"
checksums
reject 'duplicate member' 'Unsafe or duplicate'
tar -czf "$arm/$root.tar.gz" --transform="s|^$root|../$root|" -C "$scratch/tree" "$root"
checksums
reject traversal 'Unsafe or duplicate'
cp "$scratch/valid.tar.gz" "$arm/$root.tar.gz"
rmdir "$scratch/tree/mypod-1.2.3-sources/third-party/example-1"
tar -czf "$arm/mypod-1.2.3-sources.tar.gz" -C "$scratch/tree" mypod-1.2.3-sources
checksums
reject 'missing corresponding source' 'Missing corresponding source'
echo 'Release validation checks passed'
