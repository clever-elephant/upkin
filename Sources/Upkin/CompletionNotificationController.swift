import AppKit
import UpkinCore
import UserNotifications
import OSLog

@MainActor
final class CompletionNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: "com.local.Upkin", category: "notifications")
    static let enabledKey = "conversationNotificationsEnabled"
    private var deliveryTask: Task<Void, Never>?
    var anchor: (() -> NSRect?)?
    private let bubble = ConversationBubbleController()
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool
        ?? UserDefaults.standard.object(forKey: "completionNotificationsEnabled") as? Bool ?? true }

    func start(interactive: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else {
            fputs("Completion notifications require the packaged Upkin.app.\n", stderr)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard Self.isEnabled else {
            self.bubble.dismiss()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            return
        }
        Task {
            do {
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert])
                } else if settings.authorizationStatus == .denied && interactive {
                    let alert = NSAlert()
                    alert.messageText = "请允许 Upkin 通知"
                    alert.informativeText = "请在系统设置 → 通知 → Upkin 中允许通知。会话提醒默认静音，点击可返回对应会话。"
                    alert.addButton(withTitle: "打开系统设置")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn { Self.openSystemSettings() }
                }
            } catch { self.showError(error) }
        }
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    static func content(for event: ConversationEvent) -> UNMutableNotificationContent {
        let conversation = event.conversation
        let content = UNMutableNotificationContent()
        content.title = "\(conversation.provider?.name ?? "Codex") · " + (event.kind == .waiting ? "需要你操作" : "本轮已完成")
        content.subtitle = conversation.displayTitle
        content.body = event.kind == .waiting ? "点击返回会话处理" : conversation.desktopURL == nil ? "点击在 iTerm 中继续会话" : "来自桌面端 · 点击返回会话"
        content.interruptionLevel = .passive
        content.userInfo = ["conversation": conversation.notificationInfo]
        return content
    }

    func post(_ event: ConversationEvent) {
        let conversation = event.conversation
        guard Bundle.main.bundleIdentifier != nil, Self.isEnabled, (ITermConversationLauncher.sessionID(for: conversation) != nil || conversation.desktopURL != nil) else {
            Self.log.debug("Event suppressed: enabled=\(Self.isEnabled), kind=\(event.kind.rawValue, privacy: .public)")
            return
        }
        self.showBubble(event)
        let id = event.notificationID
        let previous = self.deliveryTask
        self.deliveryTask = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, Self.isEnabled, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            do {
                try await center.add(UNNotificationRequest(identifier: id,
                    content: Self.content(for: event), trigger: nil))
                if !Self.isEnabled { center.removeDeliveredNotifications(withIdentifiers: [id]) }
            } catch { fputs("Completion notification: \(error.localizedDescription)\n", stderr) }
        }
    }

    private func showBubble(_ event: ConversationEvent) {
        let conversation = event.conversation
        if let rect = self.anchor?() {
            Self.log.debug("Bubble shown: provider=\(conversation.provider?.rawValue ?? "codex", privacy: .public), kind=\(event.kind.rawValue, privacy: .public), target=\(conversation.id, privacy: .private(mask: .hash))")
            self.bubble.show(event, anchoredTo: rect) { [weak self] in
                Task { await self?.open(conversation) }
            }
        } else {
            Self.log.error("Bubble skipped: menu-bar anchor missing")
        }
    }

    func removeWaiting(for taskID: String) {
        self.bubble.removeWaiting(for: taskID)
        let id = taskID + ".waiting"
        guard Bundle.main.bundleIdentifier != nil else { return }
        let previous = self.deliveryTask
        self.deliveryTask = Task {
            // Serialize removal after an in-flight add so a resumed task cannot leave a late wait alert.
            await previous?.value
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let info = response.notification.request.content.userInfo["conversation"] as? [String: String],
              let conversation = Conversation(notificationInfo: info) else { return }
        await self.open(conversation)
    }

    private func open(_ conversation: Conversation) async {
        Self.log.debug("Bubble/notification clicked: source=\(conversation.source.rawValue, privacy: .public)")
        do { try await ConversationLauncher.open(conversation) }
        catch {
            Self.log.error("Conversation launch failed: \(error.localizedDescription)")
            self.showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "通知操作失败"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class ConversationBubbleController {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    private(set) var event: ConversationEvent?
    private var dismissal: Task<Void, Never>?

    init() {
        self.panel.isReleasedWhenClosed = false
        self.panel.isOpaque = false
        self.panel.backgroundColor = .clear
        self.panel.hasShadow = true
        self.panel.level = .statusBar
        self.panel.hidesOnDeactivate = false
        self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(_ event: ConversationEvent, anchoredTo anchor: NSRect, open: @escaping () -> Void) {
        self.dismiss()
        self.event = event
        let button = ConversationBubbleButton(event: event)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        let width = min(max(150, button.title.size(withAttributes: [.font: button.font!]).width + 68),
                        min(360, visible.width - 16))
        let x = min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        button.frame = NSRect(x: 0, y: 0, width: width, height: 45)
        button.tipX = min(max(anchor.midX - x, 18), width - 18)
        button.onOpen = { [weak self] in
            self?.dismiss()
            open()
        }
        button.onHover = { [weak self] hovering in
            self?.dismissal?.cancel()
            if !hovering { self?.scheduleDismissal() }
        }
        self.panel.contentView = button
        self.panel.setFrame(NSRect(x: x, y: min(anchor.minY - 3, visible.maxY) - 45,
                                  width: width, height: 45), display: true)
        self.panel.orderFrontRegardless()
        self.scheduleDismissal()
    }

    private func scheduleDismissal() {
        self.dismissal?.cancel()
        let seconds = self.event?.kind == .waiting ? 12 : 7
        self.dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.dismiss()
        }
    }

    func removeWaiting(for taskID: String) {
        if self.event?.kind == .waiting && self.event?.conversation.id == taskID { self.dismiss() }
    }

    func dismiss() {
        self.dismissal?.cancel()
        self.dismissal = nil
        self.panel.orderOut(nil)
        self.panel.contentView = nil
        self.event = nil
    }
}

@MainActor
final class ConversationBubbleButton: NSButton {
    let kind: ConversationEventKind
    var tipX: CGFloat = 0
    var onOpen: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    var symbolName: String { self.isHovered ? "arrow.up.right" : self.kind == .completed ? "checkmark.circle.fill" : "questionmark.circle" }

    init(event: ConversationEvent) {
        self.kind = event.kind
        super.init(frame: .zero)
        self.title = event.conversation.displayTitle
        self.font = .systemFont(ofSize: 13, weight: .medium)
        self.isBordered = false
        self.target = self
        self.action = #selector(self.openConversation)
        self.toolTip = "\(self.title) · 点击返回会话"
        self.setAccessibilityLabel("\(event.conversation.provider?.name ?? "Codex") · \(self.title) · \(event.kind == .completed ? "已完成" : "需要你操作")，点击返回会话")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openConversation() { self.onOpen?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in self.trackingAreas { self.removeTrackingArea(area) }
        self.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { self.setHovered(true) }
    override func mouseExited(with event: NSEvent) { self.setHovered(false) }

    func setHovered(_ hovered: Bool) {
        self.isHovered = hovered
        self.needsDisplay = true
        self.onHover?(hovered)
    }

    override func resetCursorRects() { self.addCursorRect(self.bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let body = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        // NSButton coordinates are flipped; the small tail points up to the menu-bar character.
        let top: CGFloat = 6.5
        let bottom = body.maxY
        let left = body.minX
        let right = body.maxX
        let radius: CGFloat = 13
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left + radius, y: top))
        path.line(to: NSPoint(x: self.tipX - 7, y: top))
        path.curve(to: NSPoint(x: self.tipX, y: 0.5), controlPoint1: NSPoint(x: self.tipX - 3, y: top), controlPoint2: NSPoint(x: self.tipX - 2, y: 0.5))
        path.curve(to: NSPoint(x: self.tipX + 7, y: top), controlPoint1: NSPoint(x: self.tipX + 2, y: 0.5), controlPoint2: NSPoint(x: self.tipX + 3, y: top))
        path.line(to: NSPoint(x: right - radius, y: top))
        path.curve(to: NSPoint(x: right, y: top + radius), controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
        path.line(to: NSPoint(x: right, y: bottom - radius))
        path.curve(to: NSPoint(x: right - radius, y: bottom), controlPoint1: NSPoint(x: right, y: bottom), controlPoint2: NSPoint(x: right, y: bottom))
        path.line(to: NSPoint(x: left + radius, y: bottom))
        path.curve(to: NSPoint(x: left, y: bottom - radius), controlPoint1: NSPoint(x: left, y: bottom), controlPoint2: NSPoint(x: left, y: bottom))
        path.line(to: NSPoint(x: left, y: top + radius))
        path.curve(to: NSPoint(x: left + radius, y: top), controlPoint1: NSPoint(x: left, y: top), controlPoint2: NSPoint(x: left, y: top))
        path.close()
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: self.font!, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let height = self.title.size(withAttributes: attributes).height
        self.title.draw(in: NSRect(x: 16, y: top + (bottom - top - height) / 2,
                                  width: self.bounds.width - 58, height: height), withAttributes: attributes)
        let color: NSColor = self.isHovered ? .secondaryLabelColor : self.kind == .completed ? .systemGreen : .systemOrange
        if let symbol = NSImage(systemSymbolName: self.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors:
                    !self.isHovered && self.kind == .completed ? [.white, color] : [color]))) {
            symbol.draw(in: NSRect(x: self.bounds.width - 31, y: top + (bottom - top - 16) / 2, width: 16, height: 16))
        }
    }
}
