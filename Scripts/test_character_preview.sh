#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
mkdir -p "$TEMP/Resources"
cp -R "$ROOT/Resources/CharacterFrames" "$TEMP/Resources/CharacterFrames"
cat > "$TEMP/check.swift" <<'SWIFT'
import AppKit
import UpkinCore

@main
@MainActor
struct Check {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let panel = CharacterPreviewController()
            panel.present()
            try await Task.sleep(for: .milliseconds(250))
            let packs = CharacterFrames.catalog.packs
            precondition(Set(packs.map(\.id)) == Set(["clawd", "chatgpt", "grok"]), "Fixture contains all three bundled character packs")
            precondition(CharacterFrames.character(for: "codex") == "chatgpt", "Default public resources include the ChatGPT character for Codex")
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            do {
                let controls = descendants(panel.window!.contentView!)
                precondition(!controls.contains { $0 is NSPopUpButton }, "No provider or character dropdowns")
                let choices = controls.compactMap { $0 as? NSButton }
                precondition(choices.filter { $0.identifier?.rawValue.hasPrefix("character-") == true }.count == packs.count, "Every pack has a choice")
                precondition(choices.contains { $0.identifier?.rawValue == "reset-characters" }, "Reset is available")
                for label in ["待机", "思考", "工作", "等待", "完成", "错误", "待确认"] {
                    precondition(controls.contains { ($0 as? NSTextField)?.stringValue == label }, "Visible state caption: \(label)")
                }
            }
            let choices = descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("character-") == true }
            let defaultsBefore = UserDefaults.standard.object(forKey: "characterSelections")
            defer { UserDefaults.standard.set(defaultsBefore, forKey: "characterSelections") }
            var playbackFailures: [String] = []
            for pack in packs {
                UserDefaults.standard.set(Dictionary(uniqueKeysWithValues:
                    ["codex", "claude", "grok"].map { ($0, pack.id) }), forKey: "characterSelections")
                precondition(["codex", "claude", "grok"].allSatisfy {
                    CharacterFrames.character(for: $0) == (CharacterFrames.catalog.defaultPack(for: $0)?.id ?? packs.first?.id)
                }, "Legacy cross-provider built-in selections must not override provider identity")
            }
            for (index, pack) in packs.enumerated() {
                let name = pack.id
                weak var old = panel.previews.first
                panel.select(character: index)
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(40))
                precondition(old == nil, "Switching releases all old preview frames")
                precondition(panel.previews.count == GrokBallEmotion.allCases.count)
                for (preview, emotion) in zip(panel.previews, GrokBallEmotion.allCases) {
                    let info = CharacterFrames.state(emotion, folder: CharacterFrames.folder(character: name))!
                    precondition(preview.character == name && preview.loadedFrameCount == info.frames)
                    precondition(preview.currentImage != nil)
                    precondition(preview.bounds.size == NSSize(width: 36, height: 22), "Menu-bar size")
                    let rect = preview.convert(preview.bounds, to: panel.window!.contentView!)
                    let first = panel.previews[0].convert(panel.previews[0].bounds, to: panel.window!.contentView!)
                    precondition(rect.minY == first.minY, "All states share one row")
                    precondition(panel.window!.contentView!.bounds.contains(rect), "State fits in window")
                    precondition(preview.superview?.toolTip?.isEmpty == false, "States have tooltips")
                    precondition(preview.visibleRect.contains(preview.bounds), "Every state is fully visible")
                    if info.frames > 1 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        guard preview.isAnimating else {
                            playbackFailures.append("Playback \(name)/\(emotion.rawValue): visible=\(preview.window?.isVisible ?? false), occluded=\(preview.window?.occlusionState.contains(.visible) != true), hidden=\(preview.isHiddenOrHasHiddenAncestor), frames=\(preview.loadedFrameCount), finished=\(preview.animationFinished), frame=\(preview.window!.frame), screen=\(String(describing: preview.window!.screen?.frame)), appActive=\(NSApp.isActive)")
                            continue
                        }
                        let animation = preview.animationLayer.animation(forKey: "character")!
                        precondition(animation.repeatCount == (info.loop && info.loopStartFrame == nil ? .infinity : 1))
                    }
                }
            }
            for (index, pack) in packs.enumerated() {
                let button = choices.first { $0.identifier?.rawValue == "character-\(pack.id)" }!
                button.performClick(nil)
                precondition(["codex", "claude", "grok"].allSatisfy {
                    CharacterFrames.character(for: $0) == (CharacterFrames.catalog.defaultPack(for: $0)?.id ?? packs.first?.id)
                }, "Clicking a built-in only previews it, preserving provider identity")
                precondition(panel.previews.allSatisfy { $0.character == pack.id })
                precondition(choices.filter { $0.state == .on }.count == 1 && button.state == .on,
                             "Exactly one character is selected")
                let preview = panel.previews.first
                button.performClick(nil)
                precondition(preview === panel.previews.first, "Repeated selection does not restart playback")
                panel.select(character: index)
            }
            panel.select(character: 0)
            weak var old = panel.previews.first
            panel.select(character: 0)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(40))
            precondition(old == nil, "Replay creates fresh playback without changing live state")
            panel.window!.close()
            precondition(panel.previews.isEmpty, "Close releases all preview frames")
            panel.present()
            precondition(panel.previews.count == 7 && panel.previews.allSatisfy { $0.character == packs[0].id && $0.loadedFrameCount > 0 })
            try await Task.sleep(for: .milliseconds(250))
            let custom = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/CharacterFrames/fourth-fixture")
            try FileManager.default.copyItem(at: packs[0].directory, to: custom)
            let manifestURL = custom.appendingPathComponent("manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            manifest["name"] = String(repeating: "x", count: 80)
            manifest.removeValue(forKey: "defaultFor")
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            panel.prepare()
            let updated = descendants(panel.window!.contentView!).compactMap { $0 as? NSButton }
            let customChoice = updated.first { $0.identifier?.rawValue == "character-fourth-fixture" }!
            try await Task.sleep(for: .milliseconds(100))
            panel.window!.contentView!.layoutSubtreeIfNeeded()
            precondition(customChoice.toolTip == String(repeating: "x", count: 80), "Full custom name remains in the tooltip")
            let customLabel = descendants(customChoice).compactMap { $0 as? NSTextField }.first!
            let labelRect = customLabel.convert(customLabel.bounds, to: customChoice)
            precondition(customChoice.bounds.contains(labelRect), "Long custom names stay inside the choice card: \(labelRect)")
            customChoice.performClick(nil)
            precondition(panel.previews.allSatisfy { $0.character == "fourth-fixture" })
            precondition(["codex", "claude", "grok"].allSatisfy {
                CharacterFrames.character(for: $0) == (CharacterFrames.catalog.defaultPack(for: $0)?.id ?? packs.first?.id)
            }, "Custom previews never replace provider characters")
            updated.first { $0.identifier?.rawValue == "reset-characters" }!.performClick(nil)
            precondition(["codex", "claude", "grok"].allSatisfy {
                CharacterFrames.character(for: $0) == CharacterFrames.catalog.defaultPack(for: $0)?.id
            }, "Reset leaves provider characters unchanged")
            if let path = ProcessInfo.processInfo.environment["CHARACTER_PREVIEW_CAPTURE"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-l", String(panel.window!.windowNumber), path]
                try process.run()
                process.waitUntilExit()
                precondition(process.terminationStatus == 0)
            }
            panel.window!.close()
            UserDefaults.standard.set(defaultsBefore, forKey: "characterSelections")
            precondition(playbackFailures.isEmpty, playbackFailures.joined(separator: "\n"))
            print("PASS: catalog choices, custom pack, reset, fixed provider identities, seven visible state labels, native playback, release on switch/close, reopen")
            NSApp.terminate(nil)
        }
        NSApp.run()
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -I "$BIN/Modules" "$TEMP/check.swift" \
    "$ROOT/Sources/Upkin/GrokBallView.swift" \
    "$ROOT/Sources/Upkin/CharacterPreviewController.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
(cd "$TEMP" && ./check)
