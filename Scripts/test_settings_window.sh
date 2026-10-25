#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/upkin-settings.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
cat > "$TEMP/main.swift" <<'SWIFT'
import AppKit
import UpkinCore

for provider in [nil, CodingAgent.claude, .grok] {
    let conversation = Conversation(id: (provider?.rawValue ?? "codex") + ":01a169fe-5cd9-7e82-920a-16ea94854438",
        provider: provider, title: "通知目标", cwd: "/tmp/project", phase: .waiting, updatedAt: 1000,
        source: provider == nil ? .desktop : .terminal)
    for kind in [ConversationEventKind.completed, .waiting] {
        let event = ConversationEvent(conversation: conversation, kind: kind)
        let content = CompletionNotificationController.content(for: event)
        precondition(content.title == "\(provider?.name ?? "Codex") · " + (kind == .waiting ? "需要你操作" : "本轮已完成"))
        precondition(content.subtitle == conversation.displayTitle && content.sound == nil)
        if kind == .waiting { precondition(content.body == "点击返回会话处理") }
        let info = content.userInfo["conversation"] as! [String: String]
        precondition(Conversation(notificationInfo: info)?.id == conversation.id,
                     "Notification click retains the triggering task, independent of current menu focus")
    }
}
print("PASS: six provider/kind notification contents and exact click targets")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let bubble = ConversationBubbleController()
let bubbleTarget = Conversation(id: "codex:01a169fe-5cd9-7e82-920a-16ea94854438",
    title: "为工具图标添加表情气泡", phase: .completed, updatedAt: 1000, source: .desktop)
let screen = NSScreen.main!.visibleFrame
let anchor = NSRect(x: screen.maxX - 180, y: screen.maxY, width: 40, height: 24)
var launched: String?
bubble.show(ConversationEvent(conversation: bubbleTarget, kind: .completed), anchoredTo: anchor) {
    launched = bubbleTarget.id
}
let bubbleButton = bubble.panel.contentView as! ConversationBubbleButton
precondition(bubble.panel.isVisible && !bubble.panel.isKeyWindow, "Bubble never steals keyboard focus")
precondition(bubbleButton.symbolName == "checkmark.circle.fill")
bubbleButton.setHovered(true)
precondition(bubbleButton.symbolName == "arrow.up.right", "Hover exposes jump affordance")
bubbleButton.setHovered(false)
precondition(bubbleButton.symbolName == "checkmark.circle.fill")
precondition(screen.contains(bubble.panel.frame), "Bubble stays inside its anchor screen")
for style in [NSAppearance.Name.aqua, .darkAqua] {
    bubbleButton.appearance = NSAppearance(named: style)
    let bitmap = bubbleButton.bitmapImageRepForCachingDisplay(in: bubbleButton.bounds)!
    bubbleButton.cacheDisplay(in: bubbleButton.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".codex-qa/notification-\(style.rawValue).png"))
}
bubbleButton.performClick(nil)
precondition(launched == bubbleTarget.id && !bubble.panel.isVisible, "Whole bubble opens exact target and dismisses")
bubble.show(ConversationEvent(conversation: bubbleTarget, kind: .waiting), anchoredTo: anchor) {}
precondition((bubble.panel.contentView as! ConversationBubbleButton).symbolName == "questionmark.circle")
bubble.removeWaiting(for: "unrelated")
precondition(bubble.panel.isVisible)
bubble.removeWaiting(for: bubbleTarget.id)
precondition(!bubble.panel.isVisible, "Resuming task clears its waiting bubble")
bubble.show(ConversationEvent(conversation: bubbleTarget, kind: .completed), anchoredTo: anchor) {}
bubble.removeWaiting(for: bubbleTarget.id)
precondition(bubble.panel.isVisible, "Waiting cleanup never dismisses completion")
bubble.dismiss()
print("PASS: bubble hover, exact click target, focus, screen bounds, light/dark rendering and stale wait removal")

let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: home) }
let hookScript = home.appendingPathComponent("upkin-activity.py")
try Data("# fixture".utf8).write(to: hookScript)
let hookConfiguration = ActivityHookConfiguration(home: home, script: hookScript)
var calls = [0, 0, 0, 0]
let settings = SettingsWindowController(refreshCodex: { calls[0] += 1 }, refreshGrok: { calls[1] += 1 },
    connectClaude: { calls[2] += 1 }, disconnectClaude: { calls[3] += 1 }, hookConfiguration: hookConfiguration)
@MainActor func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
@MainActor func button(_ id: String) -> NSButton {
    views(settings.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }!
}
@MainActor func claudeMenuAction(_ index: Int) {
    let item = button("settings-action-1").menu!.items[index]
    precondition(item.isEnabled)
    precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
}
@MainActor func update(ready: Bool = false, granted: Bool = false, error: String? = nil, busy: Bool = false) {
    settings.update(codexReady: true, codexError: nil, codexBusy: false,
        claudeReady: ready, claudeGranted: granted, claudeError: error, claudeBusy: busy,
        grokReady: false, grokError: "请先安装并登录 Grok Build", grokBusy: false)
}
precondition(!settings.window!.isVisible, "Creating settings must not open an onboarding window")
update()
settings.present()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
precondition(settings.window!.isVisible && settings.selectedSection == 0)
for index in 0...3 {
    precondition(button("settings-section-\(index)").image == nil, "Sidebar navigation is text only")
}
precondition(settings.window!.contentView!.bounds.size == NSSize(width: 700, height: 430))
precondition(calls == [0, 0, 0, 0], "Opening settings must not trigger credentials or network requests")
update(ready: true, granted: true)
precondition(button("settings-action-1").title == "管理…", "Granted access can be revoked even when hooks are missing")
update()
button("settings-action-0").performClick(nil)
button("settings-action-2").performClick(nil)
button("settings-action-1").performClick(nil)
precondition(calls == [1, 1, 1, 0], "Provider actions configure local hooks and use existing quota callbacks")
update(ready: true, granted: true)
precondition(button("settings-action-1").title == "管理…")
claudeMenuAction(1)
precondition(calls[3] == 1)
let disconnectedHooks = try hookConfiguration.status(for: .claude)
precondition(disconnectedHooks == .missing, "Disconnect removes only this provider's Upkin hooks")
update(granted: true, error: "fixture failure")
precondition(button("settings-action-1").title == "管理…", "Quota failures keep both repair and revocation reachable")
claudeMenuAction(0)
precondition(calls[2] == 2)
update(busy: true)
precondition(!button("settings-action-1").isEnabled)
button("settings-action-1").performClick(nil)
precondition(calls[2] == 2, "Busy connection blocks duplicate authorization")
update()
let claudeHooks = try hookConfiguration.status(for: .claude)
let grokHooks = try hookConfiguration.status(for: .grok)
precondition(claudeHooks == .configured && grokHooks == .configured,
             "Single provider action configures hooks as well as invoking quota callbacks")
let connectionButtons = views(settings.window!.contentView!).compactMap { $0 as? NSButton }.filter {
    $0.identifier?.rawValue.hasPrefix("settings-action-") == true
}
precondition(connectionButtons.count == 3, "Exactly one action per tool")
precondition(!views(settings.window!.contentView!).contains {
    $0.identifier?.rawValue.hasPrefix("hook-") == true
}, "No separate hook controls")
try FileManager.default.removeItem(at: hookScript)
button("settings-action-1").performClick(nil)
precondition(calls[2] == 2, "Failed hook setup must not continue to quota connection")
precondition(button("settings-action-1").title == "重试", "One button also handles hook failures")
try Data("# fixture".utf8).write(to: hookScript)
button("settings-action-1").performClick(nil)
precondition(calls[2] == 3, "The same button recovers after fixing the resource")
// Revocation must not depend on credentials, quota, hook presence or valid hook JSON.
update(granted: true, error: "credentials expired")
claudeMenuAction(1)
precondition(calls[3] == 2, "Failed credentials still allow revocation")
update(granted: true)
claudeMenuAction(1)
precondition(calls[3] == 3, "Missing hooks do not block revocation")
try hookConfiguration.configure(.claude, install: true)
let claudeConfig = home.appendingPathComponent(".claude/settings.json")
let validConfig = try Data(contentsOf: claudeConfig)
let corruptConfig = Data("{invalid".utf8)
try corruptConfig.write(to: claudeConfig)
update(granted: true, error: "fixture failure")
claudeMenuAction(1)
precondition(calls[3] == 4, "Corrupt hooks must not block quota revocation")
let preservedCorruptConfig = try Data(contentsOf: claudeConfig)
precondition(preservedCorruptConfig == corruptConfig, "Cleanup preserves corrupt user data")
update()
precondition(button("settings-action-1").title == "管理…")
precondition(button("settings-action-1").menu!.items[1].title == "重试清理会话配置")
try validConfig.write(to: claudeConfig)
claudeMenuAction(0)
precondition(calls[2] == 4, "Repairing hooks keeps connection retry available after failed cleanup")
update(ready: true, granted: true)
precondition(button("settings-action-1").menu!.items[1].title == "断开",
             "A reauthorized connection is labeled disconnect, not cleanup retry")
try corruptConfig.write(to: claudeConfig)
claudeMenuAction(1)
precondition(calls[3] == 5, "Disconnect revokes the newly granted connection even after earlier cleanup failure")
update()
try validConfig.write(to: claudeConfig)
claudeMenuAction(1)
precondition(calls[3] == 5, "Retrying cleanup never reauthorizes or repeats quota revocation")
let cleanedClaudeHooks = try hookConfiguration.status(for: .claude)
precondition(cleanedClaudeHooks == .missing)
precondition(button("settings-action-1").title == "连接")
print("PASS: failed/missing/corrupt hooks keep revocation reachable; cleanup retries preserve user data")
let root = settings.window!.contentView!
let strings = views(root).compactMap { ($0 as? NSTextField)?.stringValue } + views(root).compactMap { ($0 as? NSButton)?.title }
for removed in ["活动", "工作状态", "继续", "上一步", "开始设置"] {
    precondition(!strings.contains(removed), "Removed setup UI must stay absent")
}
for name in [NSAppearance.Name.aqua, .darkAqua] {
    settings.window!.appearance = NSAppearance(named: name)
    settings.window!.displayIfNeeded()
    CATransaction.flush()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    root.layoutSubtreeIfNeeded()
    for view in views(root) where view is NSButton || view is NSTextField {
        let rect = view.convert(view.bounds, to: root)
        precondition(root.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Control must fit: \(view)")
    }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-l", String(settings.window!.windowNumber), ".codex-qa/settings-window-\(name.rawValue).png"]
    try shot.run()
    shot.waitUntilExit()
    precondition(shot.terminationStatus == 0, "Capture the actual settings window")
    let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to:
        URL(fileURLWithPath: ".codex-qa/settings-\(name.rawValue).png"))
}
for _ in 0..<3 {
    button("settings-section-1").performClick(nil)
    precondition(settings.selectedSection == 1)
    precondition(!views(root).contains { $0 is NSPopUpButton }, "Character page has no dropdown controls")
    precondition(views(root).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("character-") == true }.count == CharacterFrames.catalog.packs.count,
                 "Show every discovered character choice")
    precondition(views(root).compactMap { $0 as? GrokBallView }.count == 7)
    button("settings-section-3").performClick(nil)
    precondition(settings.selectedSection == 3)
    precondition(!views(root).contains { $0 is GrokBallView }, "Hidden character page releases preview views")
    precondition(views(root).contains { ($0 as? NSButton)?.title == "开源许可…" })
    button("settings-section-0").performClick(nil)
    precondition(button("settings-action-1").title == "连接", "Connection state survives tab changes")
}
button("settings-section-2").performClick(nil)
precondition(settings.selectedSection == 2)
let notificationToggle = button("completion-notifications")
precondition(notificationToggle.title == "会话完成或等待操作时通知")
precondition(notificationToggle.state == (CompletionNotificationController.isEnabled ? .on : .off))
button("settings-section-1").performClick(nil)
for name in [NSAppearance.Name.aqua, .darkAqua] {
    settings.window!.appearance = NSAppearance(named: name)
    root.layoutSubtreeIfNeeded()
    settings.window!.displayIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    for view in views(root) where view is NSButton || view is NSTextField || view is GrokBallView {
        let rect = view.convert(view.bounds, to: root)
        precondition(root.bounds.contains(rect), "Character control fits: \(view)")
    }
    for choice in views(root).compactMap({ $0 as? NSButton }).filter({ $0.identifier?.rawValue.hasPrefix("character-") == true }) {
        let content = choice.subviews.compactMap { $0 as? NSStackView }.first!
        precondition(abs(content.frame.midX - choice.bounds.midX) < 0.5 && abs(content.frame.midY - choice.bounds.midY) < 0.5,
                     "Icon and name are centered together inside the choice")
        precondition(content.arrangedSubviews.allSatisfy {
            choice.bounds.insetBy(dx: 12, dy: 12).contains($0.convert($0.bounds, to: choice))
        }, "Visible icon and name have balanced inner padding")
        let image = content.arrangedSubviews[0]
        let thumbnail = (image as! NSImageView).image!
        let bitmap = NSBitmapImageRep(cgImage: thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let occupiedColumns = (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.01 }
        }
        precondition(occupiedColumns.first == 0 && occupiedColumns.last == bitmap.pixelsWide - 1,
                     "Gallery thumbnail has no asymmetric transparent horizontal padding")
        let label = content.arrangedSubviews[1]
        precondition(abs(image.frame.midX - label.frame.midX) < 0.5, "Icon and name share a horizontal center")
        precondition(choice.hitTest(choice.convert(NSPoint(x: choice.bounds.midX, y: choice.bounds.midY), to: choice.superview)) === choice,
                     "Clicking choice content reaches its button")
    }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-l", String(settings.window!.windowNumber), ".codex-qa/characters-window-\(name.rawValue).png"]
    try shot.run()
    shot.waitUntilExit()
    precondition(shot.terminationStatus == 0)
}
weak var preview: GrokBallView?
autoreleasepool {
    button("settings-section-1").performClick(nil)
    preview = views(root).compactMap { $0 as? GrokBallView }.first
    settings.close()
}
CATransaction.flush()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
precondition(preview == nil, "Closing settings releases preview frames")
settings.present()
precondition(views(root).compactMap { $0 as? GrokBallView }.count == 7, "Reopening restores role previews")
settings.close()
precondition(!views(root).contains { ($0 as? NSButton)?.title.contains("退出") == true }, "Settings has no quit action")
var opens = 0
let panel = StatusPopoverController(refresh: {}, openSettings: { opens += 1 })
panel.render()
let gear = views(panel.popover.contentViewController!.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "设置" }!
gear.performClick(nil)
precondition(opens == 1 && !panel.popover.isShown, "Gear directly opens settings, not a menu")
print("PASS: settings entry, provider callbacks, consent/busy/disconnect, tabs, preview release, light/dark layout")
SWIFT
mkdir -p .codex-qa
swiftc -swift-version 6 -I "$BIN/Modules" "${UI_SOURCES[@]}" "$TEMP/main.swift" "${CORE_OBJECTS[@]}" -o "$TEMP/check"
"$TEMP/check"
