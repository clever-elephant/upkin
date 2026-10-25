#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/native-animation-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
CHARACTER="all"
if [[ "${1:-}" == "--character" ]]; then
    CHARACTER="${2:?Expected a bundled character ID, e.g. grok}"
    case "$CHARACTER" in grok|clawd|chatgpt) ;; *) echo "Unknown character: $CHARACTER" >&2; exit 2 ;; esac
fi
if grep -Eq 'import WebKit|WKWebView|takeSnapshot|Timer\(|Timer\.|Task\.sleep|frameStride' "$ROOT/Sources/Upkin/GrokBallView.swift" "$ROOT/Sources/Upkin/ConversationIcons.swift"; then
    echo "Native renderers must not start WebKit" >&2; exit 1
fi
source "$ROOT/Scripts/test_support.sh"
cat > "$TEMP/check.swift" <<'SWIFT'
import AppKit
import UpkinCore

@main
@MainActor
struct Check {
    static func check() async throws {
        let selected = CommandLine.arguments[2]
        let characters = selected == "all" ? CharacterFrames.catalog.packs.map(\.id) : [selected]
        for character in characters {
            let assets = CharacterFrames.folder(character: character)
            for emotion in GrokBallEmotion.allCases {
                guard let state = CharacterFrames.state(emotion, folder: assets) else {
                    preconditionFailure("Missing manifest: \(character)/\(emotion.rawValue)")
                }
                precondition(state.loop == ((emotion != .completed && emotion != .error) || state.loopStartFrame != nil))
                for index in 0..<state.frames {
                    precondition(CharacterFrames.image(folder: assets, emotion: emotion, index: index) != nil,
                                 "Missing/corrupt frame \(character)/\(emotion.rawValue)/\(index)")
                }
                let representative = CharacterFrames.representative(character: character, emotion: emotion)!
                let bitmap = NSBitmapImageRep(data: representative.tiffRepresentation!)!
                precondition(bitmap.hasAlpha && bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0,
                             "Character background must stay transparent")
                var visible = false
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0 {
                        visible = true
                        break
                    }
                    if visible { break }
                }
                precondition(visible, "Representative character frame must not be blank")
            }
            if let captures = ProcessInfo.processInfo.environment["NATIVE_ANIMATION_CAPTURE_DIR"] {
                let output = URL(fileURLWithPath: captures)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 260, pixelsHigh: 504,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 260, height: 504).fill()
                for (row, emotion) in GrokBallEmotion.allCases.enumerated() {
                    let state = CharacterFrames.state(emotion, folder: assets)!
                    let y = CGFloat(6 - row) * 72
                    ("\(emotion.rawValue) \(emotion)" as NSString).draw(at: NSPoint(x: 8, y: y + 48),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
                    for (column, index) in [0, state.frames / 2, state.frames - 1].enumerated() {
                        CharacterFrames.image(folder: assets, emotion: emotion, index: index)!.draw(
                            in: NSRect(x: 8 + column * 84, y: Int(y) + 2, width: 72, height: 44))
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                let file = output.appendingPathComponent("\(character)-native-contact.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: file)
                print("CAPTURE: \(file.path)")
            }
            print("PASS: \(character) all states, frame dimensions, transparent nonblank pixels")
        }
        let clawdAssets = CharacterFrames.folder(character: "clawd")
        let clawdError = CharacterFrames.state(.error, folder: clawdAssets)!
        precondition(clawdError.loop && clawdError.loopStartFrame == 15 && clawdError.frames == 75 && clawdError.fps == 15)
        let clawdHost = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 60),
            styleMask: .borderless, backing: .buffered, defer: false)
        clawdHost.isReleasedWhenClosed = false
        let clawd = GrokBallView(character: "clawd", directory: clawdAssets)
        clawd.attach(to: clawdHost.contentView!)
        clawdHost.orderFrontRegardless()
        clawd.show(.error, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(1200))
        let clawdTail = clawd.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(clawdTail.repeatCount.isInfinite && clawdTail.values?.count == 61 && abs(clawdTail.duration - 4) < 0.001,
                     "Real Clawd error plays its 15-frame intro once, then an infinite 4s tail")
        clawd.stop()
        clawdHost.close()
        print("PASS: real clawd/34 loopStartFrame=15, infinite 4s tail")
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        var states: [String: Any] = [:]
        for emotion in GrokBallEmotion.allCases {
            let stateFolder = folder.appendingPathComponent(emotion.rawValue)
            try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
            let count = emotion == .working ? 12 : 3
            states[emotion.rawValue] = ["frames": count, "fps": 15, "loop": (emotion != .completed && emotion != .error)]
            for index in 0..<count {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 44,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                [NSColor.red, .green, .blue][index % 3].setFill()
                NSRect(x: 8, y: 8, width: 56, height: 28).fill()
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])!.write(to: stateFolder.appendingPathComponent("\(index).png"))
            }
        }
        states["30"] = ["frames": 3, "fps": 15, "loop": true, "staticFrame": 1]
        let manifest: [String: Any] = ["version": 1, "width": 72, "height": 44, "states": states]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        let view = GrokBallView(character: "fixture-initial", directory: folder)
        view.attach(to: host)
        window.orderFrontRegardless()
        defer { view.stop(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        precondition(view.show(.working, reduceMotion: false))
        precondition(view.loadedFrameCount == 12 && view.isAnimating)
        precondition(view.animationLayer.superlayer === host.layer)
        let working = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(working.keyPath == "contents" && working.calculationMode == .discrete)
        precondition(working.values?.count == 13 && working.keyTimes?.count == 13,
                     "Every source frame must be submitted; the last endpoint holds one full frame")
        precondition(abs(working.duration - 0.8) < 0.001 && working.repeatCount.isInfinite)
        let start = working.beginTime
        view.show(.working, reduceMotion: false)
        view.attach(to: host)
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).beginTime == start)
        let stillDuringPlayback = view.currentImage
        try await Task.sleep(for: .milliseconds(180))
        precondition(view.currentImage === stillDuringPlayback, "CA playback must not replace the static image per frame")
        precondition(view.currentImage != nil)
        if let contents = view.animationLayer.presentation()?.contents {
            precondition(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
            let image = contents as! CGImage
            precondition(image.width == 72 && image.height == 44)
        } else { preconditionFailure("Visible host must expose real animated presentation contents") }
        view.isHidden = true
        precondition(!view.isAnimating && view.animationLayer.isHidden)
        view.isHidden = false
        precondition(view.isAnimating)
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!view.isAnimating, "Hidden host windows remove the animation")
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        precondition(view.isAnimating, "Visible host windows resume CA playback")
        let movedWindow = NSWindow(contentRect: NSRect(x: 250, y: 100, width: 120, height: 60),
            styleMask: .borderless, backing: .buffered, defer: false)
        movedWindow.isReleasedWhenClosed = false
        movedWindow.level = .floating
        view.playbackWindow = window
        host.removeFromSuperview()
        movedWindow.contentView!.addSubview(host)
        movedWindow.orderFrontRegardless()
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        precondition(host.window === movedWindow && view.isAnimating,
                     "Moving the live host uses its new visible window, not a stale playbackWindow")
        host.removeFromSuperview()
        window.contentView!.addSubview(host)
        movedWindow.close()
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        precondition(view.isAnimating)
        view.show(.thinking, reduceMotion: true)
        precondition(!view.isAnimating && view.frameIndex == 1, "Reduced motion holds manifest representative pose")
        view.show(.waiting, reduceMotion: false, oneShot: true)
        let waitCue = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(waitCue.repeatCount == 1 && waitCue.values?.count == 4 && abs(waitCue.duration - 0.2) < 0.001,
                     "Waiting cue overrides a looping manifest for exactly one complete cycle")
        try await Task.sleep(for: .milliseconds(300))
        precondition(view.animationFinished && !view.isAnimating)
        view.restartPlayback()
        view.show(.waiting, reduceMotion: false, oneShot: true)
        precondition(view.isAnimating, "Consecutive same-provider wait events replay from frame zero")
        view.show(.waiting, reduceMotion: false)
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount.isInfinite,
                     "Panel waiting still follows the manifest's looping playback")
        for emotion in [GrokBallEmotion.completed, .error] {
            view.show(emotion, reduceMotion: false)
            let finite = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
            precondition(finite.values?.count == 4 && finite.repeatCount == 1 && abs(finite.duration - 0.2) < 0.001)
            precondition(view.frameIndex == 2, "Finite animation model layer already holds its final frame")
            try await Task.sleep(for: .milliseconds(300))
            precondition(view.animationFinished && !view.isAnimating)
            let still = view.currentImage
            view.show(emotion, reduceMotion: false)
            precondition(!view.isAnimating && view.currentImage === still,
                         "State refresh must not restart a completed animation")
        }
        // Exercise intro -> tail playback separately from legacy finite error packs.
        for index in 3..<6 {
            try FileManager.default.copyItem(at: folder.appendingPathComponent("34/\(index - 3).png"),
                                            to: folder.appendingPathComponent("34/\(index).png"))
        }
        var introStates = states
        introStates["34"] = ["frames": 6, "fps": 15, "loop": true, "loopStartFrame": 3, "staticFrame": 3]
        var introManifest = manifest
        introManifest["states"] = introStates
        try JSONSerialization.data(withJSONObject: introManifest).write(to: folder.appendingPathComponent("manifest.json"))
        view.show(.idle, reduceMotion: false)
        view.show(.error, reduceMotion: false)
        let entry = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(entry.repeatCount == 1 && entry.values?.count == 4 && abs(entry.duration - 0.2) < 0.001)
        view.show(.error, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(350))
        let tail = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(tail.repeatCount.isInfinite && tail.values?.count == 4 && abs(tail.duration - 0.2) < 0.001)
        precondition(!view.animationFinished && view.frameIndex == 3)
        view.show(.error, reduceMotion: false)
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount.isInfinite,
                     "Repeated error updates must not restart entry")
        view.show(.idle, reduceMotion: false)
        view.show(.error, reduceMotion: false)
        view.isHidden = true
        view.isHidden = false
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount.isInfinite,
                     "Visibility resume starts only the calm tail")
        for _ in 0..<2 {
            view.show(.error, reduceMotion: true)
            precondition(!view.isAnimating && view.frameIndex == 3)
            view.show(.error, reduceMotion: false)
            precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount.isInfinite,
                         "Motion preference changes resume the calm tail, never the entry")
        }
        view.restartPlayback()
        view.show(.error, reduceMotion: false)
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount == 1,
                     "Explicit restart still replays the entry")
        view.show(.idle, reduceMotion: false)
        view.show(.error, reduceMotion: false)
        precondition((view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation).repeatCount == 1,
                     "A new state still starts its entry")
        view.show(.thinking, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(350))
        precondition(view.loadedFrameCount == 3 && view.frameIndex == 1 && view.isAnimating,
                     "Cancelled entry callbacks must not replace a newer state")
        print("PASS: intro once, infinite tail only, no replay on refresh/resume, reduce-motion, stale callbacks")
        view.show(.idle, reduceMotion: false)
        let idle = view.animationLayer.animation(forKey: "character") as! CAKeyframeAnimation
        precondition(idle.values?.count == 4 && abs(idle.duration - 0.2) < 0.001,
                     "Idle remains a continuous complete 15 FPS sequence")
        view.setCharacter("grok")
        precondition(view.loadedFrameCount == 0 && !view.isAnimating && view.animationLayer.contents == nil)
        precondition(view.show(.thinking, reduceMotion: false))
        view.setCharacter("grok")
        precondition(view.loadedFrameCount == 3 && view.isAnimating)
        let missing = GrokBallView(directory: folder.appendingPathComponent("missing"))
        precondition(!missing.show(.working) && !missing.isAnimating)
        try Data("broken PNG".utf8).write(to: folder.appendingPathComponent("35/1.png"))
        precondition(!view.show(.waiting) && view.loadedFrameCount == 0,
                     "Incomplete or malformed state must fail without retaining partial frames")
        var invalidManifest = manifest
        invalidManifest["states"] = ["02": ["frames": 99999, "fps": 15, "loop": true]]
        try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(!view.show(.idle) && view.loadedFrameCount == 0)
        for count in [150, 151] {
            invalidManifest["states"] = ["02": ["frames": count, "fps": 15, "loop": true, "staticFrame": 0]]
            try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
            precondition((CharacterFrames.state(.idle, folder: folder) != nil) == (count == 150),
                         "Expanded frame budget must retain an exact upper bound")
        }
        for start in [-1, 0, 3, 4] {
            invalidManifest["states"] = ["02": ["frames": 3, "fps": 15, "loop": true, "loopStartFrame": start]]
            try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
            precondition(CharacterFrames.state(.idle, folder: folder) == nil, "Invalid intro boundary rejected")
        }
        invalidManifest["states"] = ["02": ["frames": 3, "fps": 15, "loop": false, "loopStartFrame": 1]]
        try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(CharacterFrames.state(.idle, folder: folder) == nil, "Intro tail requires a looping state")
        invalidManifest["states"] = ["02": ["frames": 3, "fps": 15, "loop": true, "staticFrame": 3]]
        try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(CharacterFrames.state(.idle, folder: folder) == nil)
        invalidManifest["states"] = [
            "02": ["frames": 3, "fps": 15, "loop": true],
            "32": ["frames": 151, "fps": 15, "loop": true],
        ]
        try JSONSerialization.data(withJSONObject: invalidManifest).write(to: folder.appendingPathComponent("manifest.json"))
        let invalidStateManifest = try JSONDecoder().decode(CharacterManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        precondition(!invalidStateManifest.isValid && CharacterFrames.state(.idle, folder: folder) == nil,
                     "Catalog and playback share validation, including unselected corrupt states")
        try Data(repeating: 32, count: 65_537).write(to: folder.appendingPathComponent("manifest.json"))
        precondition(CharacterFrames.state(.idle, folder: folder) == nil)
        try Data(repeating: 32, count: 262_145).write(to: folder.appendingPathComponent("32/0.png"))
        precondition(CharacterFrames.image(folder: folder, emotion: .working, index: 0) == nil)
        print("PASS: complete15FPS CA contents, presentation pixels, no perframe callbacks, finite freeze, continuous idle, motion/visibility lifecycle, character release, corrupt/missing/bounded assets")
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
swiftc -parse-as-library -swift-version 6 -I "$BIN/Modules" "$TEMP/check.swift" \
    "$ROOT/Sources/Upkin/GrokBallView.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
if [[ "${NATIVE_ANIMATION_COMPILE_ONLY:-0}" == "1" ]]; then
    echo "PASS: native CA fixture compiled (UI execution skipped)"
    exit 0
fi
"$TEMP/check" "$TEMP" "$CHARACTER"
