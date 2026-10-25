<p align="center">
  <img src="docs/media/app-icon.png" width="128" alt="Upkin">
</p>

<div align="center">
  <h1>Upkin</h1>
  <p><b>A tiny menu-bar character that shows what your AI coding agents are up to, in real time.</b></p>
  <p><a href="README.md">简体中文</a> · English</p>
  <a href="https://github.com/clever-elephant/upkin/releases"><img src="https://img.shields.io/github/v/release/clever-elephant/upkin?label=version&style=flat-square" alt="Version"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square" alt="Platform">
  <a href="https://github.com/clever-elephant/upkin/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/clever-elephant/upkin/ci.yml?branch=main&label=CI&style=flat-square" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square" alt="License"></a>
</div>

<p align="center">
  <img src="docs/media/hero.gif" width="720" alt="Upkin demo: the ChatGPT (Codex), Clawd (Claude Code) and Grok (Grok Build) characters cycle through thinking, working, waiting for you and done.">
</p>

I usually have Codex, Claude Code and Grok Build running at once, and kept switching back to a terminal only to find the task had finished long ago, or had been stuck waiting for me. Upkin gives each tool a little character, so one glance at the menu bar tells you whether it's thinking, working, waiting for you or done. Open the panel to see your sessions and remaining quota, and jump straight back into any of them.

## Features

- **Live status**: thinking, working, waiting for you, done and error, each with a full animation cycle played natively at 15 FPS in the menu bar
- **All three at once**: Codex, Claude Code and Grok Build are tracked separately; works fine with just one or two installed, and shows whichever started most recently
- **Sessions at a glance**: grouped into needs-you, running and done, with Codex subtasks nested under their parent; click to jump back to the Codex desktop app or the iTerm tab
- **Quota**: remaining quota and reset times right in the menu bar; ⌘R refreshes
- **Done alerts**: a silent notification when a task finishes (optional)
- **Pick a character**: ChatGPT, Clawd and Grok built in, or import your own [character pack](docs/character-packs.md)
- **Lightweight**: native AppKit, no WebView, no background daemon; session content is read locally only

## Quick Start

Download `Upkin-<version>-macos.zip` from **[GitHub Releases](https://github.com/clever-elephant/upkin/releases/latest)**, unzip it and drag `Upkin.app` into Applications. Requires macOS 14+; universal for Apple Silicon and Intel.

> [!NOTE]
> The app isn't notarized by Apple yet, so macOS blocks the first launch. Open System Settings → Privacy & Security and click "Open Anyway", or run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/Upkin.app
> ```

Upkin lives only in the menu bar, with no Dock icon; settings are behind the gear in the panel. Codex works out of the box; connect Claude Code and Grok Build with one click in Settings → Connections.

<details>
<summary><strong>Build from source</strong></summary>
<br/>

Requires Swift 6 (comes with Xcode 16 or the Command Line Tools).

```bash
git clone https://github.com/clever-elephant/upkin.git
cd upkin
./Scripts/build_app.sh
open Upkin.app
```

See the [getting started guide](docs/getting-started.md) for details.

</details>

## Supported Tools

| Tool | Session status | Quota | Jump back |
| --- | --- | --- | --- |
| **Codex** | Read from local sessions, no setup | Codex CLI or desktop app signed in with ChatGPT | Desktop app / iTerm |
| **Claude Code** | Needs [hooks](docs/grok-claude-activity.md) | Authorize in Settings → Connections; subscription accounts only | iTerm |
| **Grok Build** | Needs [hooks](docs/grok-claude-activity.md) | Just sign in to the Grok CLI | iTerm |

Hooks need Python 3, are installed only when you click Connect, and keep any other hooks you have. To remove them, run `python3 Scripts/configure_agent_hooks.py --remove`. macOS asks for Automation permission the first time Upkin jumps to iTerm.

## Screenshots

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/conversations-dark.png">
    <img src="docs/media/conversations-light.png" width="520" alt="Sessions panel">
  </picture>
</p>

<details>
<summary>More screenshots</summary>
<br>
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/media/characters-dark.png"><img src="docs/media/characters-light.png" width="680" alt="Character settings"></picture></p>
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/media/quota-dark.png"><img src="docs/media/quota-light.png" width="520" alt="Quota details"></picture></p>
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/media/connections-dark.png"><img src="docs/media/connections-light.png" width="680" alt="Tool connections"></picture></p>
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/media/notifications-dark.png"><img src="docs/media/notifications-light.png" width="680" alt="Done notifications"></picture></p>
</details>

Tasks and quota in the screenshots are demo data. The UI is currently Chinese only.

## Privacy

- Session content is read on your Mac only; prompts, replies and project files are never uploaded, and there is no analytics
- Network access happens only for quota: Codex via its local app-server, Claude via Anthropic's OAuth usage endpoint, Grok via the CLI's own billing endpoint
- Claude credentials are read only after you consent, and can be revoked under Manage… → Disconnect
- Launch and background refresh never change any config; see [architecture](docs/architecture.md) for exactly which files are read

## Docs

| Doc | What's in it |
| --- | --- |
| [Getting started](docs/getting-started.md) | Install, first-run setup and FAQ |
| [Claude / Grok activity](docs/grok-claude-activity.md) | What the hooks do and how to remove them |
| [Character packs](docs/character-packs.md) | Make and import your own character |
| [Animation guidelines](docs/character-animation-guidelines.md) | Motion timing and expression rules |
| [Architecture](docs/architecture.md) | Data sources, read scope and design |
| [Releasing](docs/releasing.md) | Packaging and release checklist |

Docs are written in Chinese.

## Known Issues

- The UI is Chinese only for now
- Status is inferred from recent events; a Claude / Grok task with no new events for over an hour shows as "needs checking"
- Grok quota may break after a Grok CLI update
- On Intel Macs with multiple displays, the menu bar on inactive screens may show quota only

## Contributing

Issues and PRs are welcome on [GitHub](https://github.com/clever-elephant/upkin/issues). Local development:

```bash
swift build
swift run UpkinCoreTests
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full checks and conventions, and report security issues privately per [SECURITY.md](SECURITY.md).

## Acknowledgments

- [clawd-pet](https://github.com/abderrahimghazali/clawd-pet): pixel reference for Clawd
- [Grok Ball](https://github.com/TyCoding/grok-ball): source of the Grok character
- [RunCat Neo](https://github.com/runcat-dev/RunCatNeo): approach to menu-bar animation
- [LobeHub Icons](https://github.com/lobehub/icons): provider icons

## License

Source code is licensed under the [GNU AGPL-3.0](LICENSE), Copyright (C) 2026 clever-elephant. Sources and licenses for every character and icon are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md):

- The **ChatGPT** character is drawn by clever-elephant, AGPL-3.0; its cloud outline is adapted from the OpenAI Codex logo, and the related marks belong to OpenAI.
- **Clawd** is Anthropic's character. This pixel art is an unofficial fan rendition based on the MIT-licensed clawd-pet and grants no character or trademark rights.
- The **Grok** character comes from [TyCoding/grok-ball](https://github.com/TyCoding/grok-ball), MIT.
- **App icon** is drawn by clever-elephant, AGPL-3.0.

This is a personal project, not affiliated with or endorsed by OpenAI, Anthropic or xAI.
