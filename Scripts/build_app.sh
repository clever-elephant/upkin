#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/Upkin.app"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/upkin-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
CONTENTS="$STAGING/Upkin.app/Contents"
MACOS="$CONTENTS/MacOS"
APP_RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
mkdir -p "$MACOS" "$APP_RESOURCES"
if [[ "${UPKIN_UNIVERSAL:-}" == 1 ]]; then
  # Per-triple builds work with the Command Line Tools; `--arch a --arch b` needs full Xcode.
  binaries=()
  for arch in arm64 x86_64; do
    swift build -c release --product Upkin --triple "$arch-apple-macosx14.0"
    binaries+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/Upkin")
  done
  lipo -create "${binaries[@]}" -output "$MACOS/Upkin"
else
  swift build -c release --product Upkin
  cp "$(swift build -c release --show-bin-path)/Upkin" "$MACOS/Upkin"
fi
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/"
mkdir -p "$APP_RESOURCES/ThirdParty/RunCatNeo"
cp "$ROOT/ThirdParty/RunCatNeo/LICENSE" "$APP_RESOURCES/ThirdParty/RunCatNeo/LICENSE"
cp "$ROOT/Scripts/agent_activity_hook.py" "$APP_RESOURCES/upkin-activity.py"
cp -R "$ROOT/Resources/CharacterFrames" "$APP_RESOURCES/CharacterFrames"
cp -R "$ROOT/Resources/ProviderIcons" "$APP_RESOURCES/ProviderIcons"

# Optional local-only packs (e.g. artwork you may use privately but not redistribute).
if [[ -n "${UPKIN_EXTRA_CHARACTERS:-}" ]]; then
  EXTRA="$(cd "$UPKIN_EXTRA_CHARACTERS" && pwd -P)"
  case "$EXTRA/" in
    "$ROOT/"*) echo 'Extra character packs must stay outside the repository.' >&2; exit 1 ;;
  esac
  if [[ -n "$(find "$EXTRA" -type l -print -quit)" ]]; then
    echo 'Extra character packs must not contain symlinks.' >&2
    exit 1
  fi
  for pack in "$UPKIN_EXTRA_CHARACTERS"/*/; do
    [[ -f "$pack/manifest.json" ]] || continue
    destination="$APP_RESOURCES/CharacterFrames/$(basename "${pack%/}")"
    if [[ -d "$destination" ]]; then
      echo "Replacing bundled character: $(basename "$destination")"
      rm -rf "$destination"
    fi
    cp -R "${pack%/}" "$destination"
  done
fi

swift "$ROOT/Scripts/test_character_frames.swift" "$APP_RESOURCES/CharacterFrames"

# Local packaging is ad-hoc signed, not Developer ID signed or notarized.
codesign --force --sign - "$STAGING/Upkin.app" >/dev/null
codesign --verify --deep --strict "$STAGING/Upkin.app"

rm -rf "$APP"
mv "$STAGING/Upkin.app" "$APP"
rmdir "$STAGING"
echo "$APP"
