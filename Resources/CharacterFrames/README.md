# Offline character frames

The app plays these PNGs natively in the menu bar at 36×22pt. Each frame is a
72×44 RGBA PNG (2× backing scale) with a transparent background.

The native app reads `<character>/manifest.json` and
`<character>/<state>/<index>.png`. Manifest version 1 contains `width`,
`height`, optional `name` / `defaultFor` / `sortOrder`, and a `states`
dictionary covering all seven states. Every state supplies `frames` (1–150),
`fps`, `loop`, and `staticFrame` (representative frame for reduced motion and
static icons). Frame indices are contiguous and zero-based. All built-in states
use 15 FPS.

Bundled defaults: ChatGPT (AGPL-3.0) for Codex; Grok (from Grok Ball, MIT) for Grok Build; Clawd (original
Upkin drawing, AGPL-3.0) for Claude Code. Clawd is Anthropic’s character; this
unofficial fan rendition grants no character or trademark rights.

Built-in timing (see `docs/character-animation-guidelines.md`):

- Looping states share a 4-second main beat; packs with two alternating rounds
  (A/B faces or left/right glances) store 8 seconds / 120 frames.
- Completed (`33`) plays once for 2.2 seconds / 33 frames and holds its last frame.
- Error (`34`): Grok plays 1 second / 15 frames once and holds. Packs may
  instead set `loopStartFrame` to play an intro once and loop the tail. Clawd
  uses 75 frames, `loopStartFrame: 15`: a 1s intro and infinite 4s tail.

Regenerate from repository-local source SVG/JS (development dependencies only):

```sh
NODE_PATH=/path/to/existing/node_modules node Scripts/export_character_frames.cjs [character] [state]
swift Scripts/test_character_frames.swift
node Scripts/test_unified_cadence.cjs
```

The exporter needs Playwright and an installed Chrome; `CHROME_PATH` overrides
its macOS default path. It seeds random numbers, integrates JavaScript at a fixed
60Hz, samples CSS animation time, and bakes 15 FPS. Loops start at phase zero on
the shared beat and are checked for closed seams. Export is not a live
hot-reload: finish it before launching the app.

These fixed recordings replace random blinks and mouse-follow behavior. Artwork
uses the original light-appearance styling; backgrounds stay transparent. Each
pack retains its source attribution and upstream license alongside the
derivatives. Only redistributable packs belong in this directory.
