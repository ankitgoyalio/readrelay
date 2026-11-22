#!/bin/bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 VERSION [OUTPUT_DIRECTORY]" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Run this script natively on an Apple silicon Mac." >&2
  exit 1
fi

version="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${2:-$root/.build/releases/v$version}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/readrelay-release.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
name="readrelay-$version-macos-arm64"
archive="$name.tar.gz"
stage="$work/$name"

cd "$root"
sw_vers
xcodebuild -version
swift --version
# Omit the linker debug map (which names the checkout and scratch paths) and UUID.
build_options=(
  --configuration release --scratch-path "$work/build" --force-resolved-versions
  -Xswiftc -gnone -Xlinker -S -Xlinker -no_uuid
)
swift build "${build_options[@]}" --product readrelay
bin_dir="$(swift build "${build_options[@]}" --show-bin-path)"

mkdir -m 755 "$stage"
install -m 755 "$bin_dir/readrelay" "$stage/readrelay"
install -m 644 LICENSE "$stage/LICENSE"
install -m 644 "$work/build/checkouts/swift-argument-parser/LICENSE.txt" "$stage/LICENSE.swift-argument-parser"

if [[ "$(lipo -archs "$stage/readrelay")" != arm64 ]]; then
  echo "Expected an arm64-only executable." >&2
  exit 1
fi
if [[ "$("$stage/readrelay" --version)" != "$version" ]]; then
  echo "The executable does not report $version. Update the CLI version before packaging." >&2
  exit 1
fi

# Normalize archive metadata and omit timestamps from the gzip header.
TZ=UTC touch -t 200001010000 "$stage" "$stage/readrelay" "$stage/LICENSE" "$stage/LICENSE.swift-argument-parser"
(
  cd "$work"
  /usr/bin/tar --format ustar --no-recursion --no-mac-metadata \
    --uid 0 --gid 0 --uname root --gname wheel -cf - \
    "$name" "$name/readrelay" "$name/LICENSE" "$name/LICENSE.swift-argument-parser" |
    /usr/bin/gzip -n > "$archive"
  shasum -a 256 "$archive" > "$archive.sha256"
)

read -r sha256 _ < "$work/$archive.sha256"
mkdir -p "$output/Formula"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha256/g" \
  "$root/packaging/homebrew/readrelay.rb.in" > "$output/Formula/readrelay.rb"
mv "$work/$archive" "$work/$archive.sha256" "$output/"
printf 'Archive: %s/%s\nSHA-256: %s\nFormula: %s/Formula/readrelay.rb\n' \
  "$output" "$archive" "$sha256" "$output"
