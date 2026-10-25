#!/usr/bin/env bash
# Shared compile inputs only; callers own fixtures, compiler flags and cleanup.
cd "$ROOT"
swift build --product Upkin
BIN="$(swift build --show-bin-path)"
CORE_OBJECTS=()
for source in "$ROOT"/Sources/UpkinCore/*.swift; do
    CORE_OBJECTS+=("$BIN/UpkinCore.build/$(basename "$source").o")
done
UI_SOURCES=()
for source in "$ROOT"/Sources/Upkin/*.swift; do
    [[ "$(basename "$source")" == main.swift ]] || UI_SOURCES+=("$source")
done
