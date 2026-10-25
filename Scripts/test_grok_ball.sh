#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Runtime is native; validate the baked pack and shared playback lifecycle.
bash "$ROOT/Scripts/test_native_animation.sh" --character grok
