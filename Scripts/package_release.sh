#!/usr/bin/env bash
# Builds a universal Upkin.app and writes dist/Upkin-<version>-macos.zip plus its SHA-256.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

if [[ -n "${UPKIN_EXTRA_CHARACTERS:-}" ]]; then
  echo 'Release builds must not include UPKIN_EXTRA_CHARACTERS.' >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ -n "${UPKIN_RELEASE_TAG:-}" && "$UPKIN_RELEASE_TAG" != "v$VERSION" ]]; then
  echo "Tag $UPKIN_RELEASE_TAG does not match Info.plist version $VERSION." >&2
  exit 1
fi

UPKIN_UNIVERSAL=1 ./Scripts/build_app.sh
[[ "$(lipo -archs Upkin.app/Contents/MacOS/Upkin)" == *arm64* && "$(lipo -archs Upkin.app/Contents/MacOS/Upkin)" == *x86_64* ]]

mkdir -p dist
ZIP="dist/Upkin-$VERSION-macos.zip"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps the bundle's signature and extended attributes intact, unlike plain zip.
ditto -c -k --sequesterRsrc --keepParent Upkin.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "$ROOT/$ZIP"
