#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/conversation-icons-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
mkdir -p "$TEMP/Resources"
cp -R "$ROOT/Resources/CharacterFrames" "$TEMP/Resources/CharacterFrames"
cp -R "$ROOT/Resources/CharacterFrames/grok" "$TEMP/Resources/CharacterFrames/fourth-fixture"
python3 - "$TEMP/Resources/CharacterFrames/fourth-fixture/manifest.json" <<'PYTHON'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest.update(name="Fourth fixture", sortOrder=999)
manifest.pop("defaultFor", None)
path.write_text(json.dumps(manifest))
PYTHON
cat > "$TEMP/check.swift" <<'SWIFT'
import AppKit
import UpkinCore

// Unit fixture: screen occlusion from concurrent desktop windows is not under test.
@MainActor final class FixtureWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
@main
@MainActor
struct Check {
    static func check() async throws {
        let window = FixtureWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let parent = window.contentView!
        let icons = ConversationIcons()
        func player(_ view: NSView) -> GrokBallView? { view.subviews.compactMap { $0 as? GrokBallView }.first }
        defer {
            icons.stop()
            window.close()
        }
        func waitForPlayer(_ view: NSView) async throws {
            for _ in 0..<100 {
                if player(view) != nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("Visible row animation failed to load")
        }
        let conversation = Conversation(id: "codex:test", title: "动画", cwd: nil,
                                        phase: .working, updatedAt: Date().timeIntervalSince1970)
        let first = icons.image(for: conversation)
        let second = icons.image(for: conversation)
        first.frame = NSRect(x: 0, y: 0, width: 36, height: 22)
        second.frame = NSRect(x: 40, y: 0, width: 36, height: 22)
        parent.addSubview(first)
        parent.addSubview(second)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        precondition(first.image === second.image, "Closed-panel icons share decoded stills")
        precondition(player(first) == nil && player(second) == nil, "No frames decoded before opening")
        let still = first.image!
        precondition(first.accessibilityLabel() == "Codex · 工作")
        icons.load()
        precondition(player(first) == nil, "Loading returns before decoding finishes")
        try await waitForPlayer(first)
        try await waitForPlayer(second)
        let active = player(first)!
        precondition(active.loadedFrameCount > 1 && first.image == nil)
        active.show(.working, reduceMotion: false)
        precondition(active.isAnimating, "Open, visible rows use Core Animation")
        let firstFrames = (active.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).values as! [CGImage]
        let secondFrames = (player(second)!.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).values as! [CGImage]
        precondition(firstFrames[0] === secondFrames[0], "Same character/state shares decoded CGImages")
        let animation = active.animationLayer.animation(forKey: "character")!
        icons.load()
        precondition(player(first) === active && active.animationLayer.animation(forKey: "character")!.beginTime == animation.beginTime,
                     "Repeated load keeps the current player")
        active.show(.working, reduceMotion: true)
        precondition(!active.isAnimating && active.currentImage != nil, "Reduce motion remains static")
        icons.stop()
        precondition(!active.isAnimating && player(first) == nil && first.image === still,
                     "Closing removes animations and restores stills")
        icons.load()
        try await waitForPlayer(first)
        precondition(player(first) != nil && player(first) !== active, "Reopening restores playback")
        icons.clearTargets()
        precondition(player(first) == nil && player(second) == nil)
        icons.load()
        precondition(player(first) == nil, "Cleared targets never restart")
        for provider: CodingAgent? in [nil, .grok, .claude] {
            for phase: AgentTaskPhase in [.idle, .thinking, .working, .waiting, .completed, .error, .unknown] {
                let item = Conversation(id: "fixture", provider: provider, title: nil, cwd: nil,
                                        phase: phase, updatedAt: Date().timeIntervalSince1970)
                let view = icons.image(for: item)
                view.frame = NSRect(x: 0, y: 0, width: 36, height: 22)
                let expectedCharacter = CharacterFrames.character(for: provider?.rawValue ?? "codex")
                let expected = CharacterFrames.representative(character: expectedCharacter, emotion: item.emotion)!
                precondition(view.image!.tiffRepresentation == expected.tiffRepresentation,
                             "Global Clawd selection must not change provider identity in static rows")
                parent.addSubview(view)
                icons.load()
                try await waitForPlayer(view)
                precondition(player(view)?.loadedFrameCount ?? 0 > 1, "Every provider/state uses validated frames")
                precondition(player(view)?.character == expectedCharacter,
                             "Global Clawd selection must not change provider identity in animated rows")
                icons.clearTargets()
                precondition(view.image?.size == NSSize(width: 36, height: 22) && player(view) == nil)
                view.removeFromSuperview()
            }
        }
        first.removeFromSuperview()
        second.removeFromSuperview()
        let scroll = NSScrollView(frame: parent.bounds)
        parent.addSubview(scroll)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 300))
        scroll.documentView = document
        let rows = (0..<6).map { index in
            let view = icons.image(for: conversation)
            view.frame = NSRect(x: 0, y: index * 44, width: 36, height: 22)
            document.addSubview(view)
            return view
        }
        scroll.contentView.scroll(to: .zero)
        icons.load()
        try await waitForPlayer(rows[0])
        precondition(player(rows[0]) != nil && player(rows[5]) == nil, "Offscreen rows do not decode animations")
        let previous = player(rows[0])!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 190))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitForPlayer(rows[5])
        try await waitForPlayer(rows[5])
        precondition(player(rows[0]) == nil && !previous.isAnimating && player(rows[5]) != nil,
                     "Scrolling stops hidden rows and starts newly visible rows")
        icons.stop()
        scroll.contentView.scroll(to: .zero)
        precondition(rows.allSatisfy { player($0) == nil }, "Closed panel has no scroll observer or playback")
        CharacterFrames.reloadCatalog()
        precondition(rows.allSatisfy { player($0) == nil }, "Reloading the catalog never starts closed-panel playback")
        icons.load()
        try await waitForPlayer(rows[0])
        precondition(player(rows[0])?.character == CharacterFrames.character(for: "codex") && player(rows[5]) == nil,
                     "Catalog reload preserves fixed conversation provider icons")
        let changedPlayer = player(rows[0])!
        CharacterFrames.reloadCatalog()
        try await waitForPlayer(rows[0])
        precondition(player(rows[0])?.character == CharacterFrames.catalog.defaultPack(for: "codex")?.id,
                     "Catalog reload updates visible rows immediately")
        precondition(!changedPlayer.isAnimating && player(rows[5]) == nil,
                     "Reloading the catalog releases old playback and keeps hidden rows unloaded")
        icons.load()
        icons.stop()
        try await Task.sleep(for: .milliseconds(100))
        precondition(rows.allSatisfy { player($0) == nil }, "Late decoding must not restart closed icons")
        print("PASS: open/close/reopen; visible-only playback; scroll cleanup; all provider/states; shared stills; reduce motion; no repeated-load restart")
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await check(); NSApp.terminate(nil) }
            catch { print(error); exit(1) }
        }
        NSApp.run()
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -I "$BIN/Modules" "$TEMP/check.swift" "${UI_SOURCES[@]}" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
(cd "$TEMP" && ./check)
