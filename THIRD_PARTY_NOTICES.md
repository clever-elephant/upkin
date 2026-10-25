# Third-party notices

Upkin source code is licensed under GNU AGPL v3.0. Third-party components retain their own copyright and license notices. No affiliation or trademark license is implied.

| Component | Author / source | Pinned version | License / notices |
| --- | --- | --- | --- |
| ChatGPT character | Local editable artwork: `Resources/ChatGPT`; PNG derivatives: `Resources/CharacterFrames/chatgpt` | Repository version | Drawn by clever-elephant; both folders contain `LICENSE` and `SOURCE.txt` — AGPL-3.0; cloud outline adapted from the OpenAI Codex logo, marks belong to OpenAI |
| App icon | `Resources/AppIcon.icns`; README derivative: `docs/media/app-icon.png` | Repository version | Original work by clever-elephant — AGPL-3.0 |
| Grok Ball | tycoding / [grok-ball](https://github.com/TyCoding/grok-ball) | `de368ce3acdc5a70e871ee46ebbe8f60b11d3d6a` | `ThirdParty/GrokBall/LICENSE`, `SOURCE.txt` — MIT |
| Clawd (Upkin pixel rendition) | [Abderrahim GHAZALI / clawd-pet](https://github.com/abderrahimghazali/clawd-pet); local Upkin animations; character / trademarks: Anthropic | `clawd-happy.svg` Git blob `6c1a9f0e47e1b9643bdb6403f1f8f32285988375` | `Resources/Clawd/LICENSE`, `SOURCE.txt` — upstream pixel geometry MIT, local adaptations AGPL-3.0; unofficial fan rendition, no character or trademark rights granted |
| Provider icons | [LobeHub Icons](https://github.com/lobehub/icons) | `@lobehub/icons-static-png` 2.2.0 | `Resources/ProviderIcons/LICENSE`, `SOURCE.txt` — MIT; marks belong to their owners |
| Menu-bar layer animation approach | Takuto Nakamura / [RunCat Neo](https://github.com/runcat-dev/RunCatNeo) | `592cd606e735ce20da98d9ae62ecf1a2608635d7` | `ThirdParty/RunCatNeo/LICENSE` — Apache-2.0; copyright 2026 Kyome22 (Takuto Nakamura) |

The menu-bar integration adapts RunCat Neo's independent Core Animation layer and static-replica background-clearing approach to AppKit, colored character frames and a separate quota region. No RunCat artwork or runtime dependency is included.

The Grok Ball runtime retains its upstream contents. The local HTML host in `Resources/GrokBall` adapts viewport, state mapping and playback cadence to the menu bar. The app plays offline-rendered transparent PNG derivatives in `Resources/CharacterFrames/grok`, which retain the upstream MIT license and attribution. README previews in `docs/media` include a GIF derived from those frames and screenshots of the native UI. Packaging includes these notices, the frames and the component licenses; the JS source remains in the repository for reproducible offline export, not in the running app.

The Clawd PNG derivatives are exported from the local SVG/CSS adapter. Its rectangular body, eye spacing and palette adapt the MIT-licensed clawd-pet pixel geometry; the state animations and local adaptations are by Upkin. The frame pack includes both the upstream MIT notice and the local AGPL license, together with the unofficial Anthropic character notice. The README Clawd animation is derived from this frame pack.

"Grok" / xAI, "OpenAI" / "Codex", "Claude" / "Clawd" / Anthropic and related names and logos are trademarks of their respective owners and are used only to identify the tools Upkin works with.

Character packs that users install themselves, or add to a local build, are not part of this distribution and keep their own terms.

The ChatGPT character is drawn by clever-elephant and distributed under AGPL-3.0. Its cloud outline is adapted from the OpenAI Codex logo, which remains an OpenAI mark. Its editable sources are in `Resources/ChatGPT`; its PNG frames, license and source notes are in `Resources/CharacterFrames/chatgpt`. It is included in default builds and is not a local-only pack.
