import AppKit
import UpkinCore

@MainActor
final class StatusPopoverController: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let controller = NSViewController()
    private let content = NSStackView()
    private let refresh: () -> Void
    private let openSettings: () -> Void
    private var claudeConnected = false
    private let openConversation: (Conversation) async throws -> Void
    private var openingConversation = false
    private(set) var snapshot: CodexUsageSnapshot?
    private var session = CodexSessionActivitySnapshot(activeThreadCount: 0, loadedThreadCount: 0)
    private var agents = AgentActivitySnapshot()
    private var grokSnapshot: GrokUsageSnapshot?
    private var grokError: String?
    private var claudeSnapshot: ClaudeUsageSnapshot?
    private var claudeError: String?
    private var error: String?
    private var refreshing = false
    private var expandedQuota: Int?
    private let icons = ConversationIcons()
    private let width: CGFloat = 400
    private var renderedConversations: [Conversation]?
    private var renderedOpening = false
    private var quotaDirty = true
    private var renderedExpandedQuota: Int?
    private var completedLabels: [(NSTextField, TimeInterval)] = []
    private var runningLabels: [(NSTextField, Conversation)] = []
    private(set) var durationTimer: Timer?

    init(refresh: @escaping () -> Void,
         openSettings: @escaping () -> Void = {},
         openConversation: @escaping (Conversation) async throws -> Void = ConversationLauncher.open) {
        self.refresh = refresh
        self.openSettings = openSettings
        self.openConversation = openConversation
        super.init()
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        self.content.orientation = .vertical
        self.content.alignment = .leading
        self.content.spacing = 10
        self.content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(self.content)
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: self.width),
            self.content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            self.content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            self.content.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            self.content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
        ])
        self.controller.view = background
        self.popover.contentViewController = self.controller
        self.popover.behavior = .transient
        self.popover.animates = false
        self.popover.delegate = self
    }

    func update(snapshot: CodexUsageSnapshot?, session: CodexSessionActivitySnapshot,
                agents: AgentActivitySnapshot, error: String?, refreshing: Bool,
                claudeSnapshot: ClaudeUsageSnapshot? = nil, claudeError: String? = nil,
                claudeConnected: Bool = false,
                grokSnapshot: GrokUsageSnapshot? = nil, grokError: String? = nil) {
        self.quotaDirty = self.quotaDirty || self.snapshot != snapshot || self.grokSnapshot != grokSnapshot
            || self.claudeSnapshot != claudeSnapshot || self.error != error || self.grokError != grokError
            || self.claudeError != claudeError || self.refreshing != refreshing
            || self.claudeConnected != claudeConnected
        self.claudeConnected = claudeConnected
        self.grokSnapshot = grokSnapshot
        self.grokError = grokError
        self.claudeSnapshot = claudeSnapshot
        self.claudeError = claudeError
        self.snapshot = snapshot
        self.session = session
        self.agents = agents
        self.error = error
        self.refreshing = refreshing
        if self.popover.isShown { self.render() }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if self.popover.isShown {
            self.popover.close()
        } else {
            self.render()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()
            self.refresh()
        }
    }

    // Quota/refresh changes preserve row views, playback and the scroll position.
    func render() {
        let conversations = self.session.conversations + self.agents.conversations
        let tree = Conversation.tree(conversations)
        let reuseList = self.renderedConversations == conversations && self.renderedOpening == self.openingConversation
        if reuseList && !self.quotaDirty && self.renderedExpandedQuota == self.expandedQuota {
            self.updateRunningDurations()
            if self.popover.isShown { self.icons.load() }
            return
        }
        let preserved = reuseList ? Array(self.content.arrangedSubviews.prefix(2)) : []
        for view in self.content.arrangedSubviews where !preserved.contains(view) {
            self.content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let refresh = self.iconButton("arrow.clockwise", label: self.refreshing ? "正在刷新" : "刷新额度与状态",
                                      action: #selector(self.refreshAction))
        refresh.keyEquivalent = "r"
        refresh.isEnabled = !self.refreshing
        if !reuseList {
            self.runningLabels.removeAll()
            self.completedLabels.removeAll()
            self.icons.clearTargets()
            let header = self.row([self.label("会话", size: 14, weight: .semibold), NSView(),
                                   self.iconButton("gearshape", label: "设置", action: #selector(self.moreAction))])
            header.identifier = NSUserInterfaceItemIdentifier("conversation-header")
            self.append(header)
            let list = ConversationTreeList()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 0
            for group in ConversationGroup.allCases {
                let items = tree.filter { $0.group == group }
                guard !items.isEmpty else { continue }
                let caption = self.label("\(group.rawValue)  \(items.filter { $0.depth == 0 }.count)", size: 11, color: .secondaryLabelColor)
                list.addArrangedSubview(caption)
                caption.heightAnchor.constraint(equalToConstant: 24).isActive = true
                for item in items {
                    let row = self.conversationRow(item.conversation, depth: item.depth)
                    list.addArrangedSubview(row)
                    list.rows.append((row, item.depth))
                    row.widthAnchor.constraint(equalTo: list.widthAnchor,
                        constant: -NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) - 2).isActive = true
                }
            }
            if tree.isEmpty {
                self.append(self.label(self.refreshing ? "正在读取会话…" : "暂无近期会话", size: 13, color: .secondaryLabelColor))
            } else {
                let scroll = NSScrollView()
                scroll.drawsBackground = false
                scroll.hasVerticalScroller = true
                scroll.scrollerStyle = .overlay
                scroll.verticalScroller?.controlSize = .small
                scroll.autohidesScrollers = true
                scroll.documentView = list
                list.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                    list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                    list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                ])
                let height = min(360, CGFloat(tree.reduce(0) { $0 + ($1.depth > 0 ? 26 : 32) }
                    + Set(tree.map(\.group)).count * 24))
                scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
                self.append(scroll)
            }
            self.renderedConversations = conversations
            self.renderedOpening = self.openingConversation
        } else if conversations.isEmpty, let label = self.content.arrangedSubviews.last as? NSTextField {
            label.stringValue = self.refreshing ? "正在读取会话…" : "暂无近期会话"
        }
        self.updateRunningDurations()
        self.separator()
        let sources: [(name: String, icon: String, windows: [UsageWindow?], date: Date?, error: String?)] = [
            ("Codex", "openai", [self.snapshot?.fiveHour, self.snapshot?.weekly], self.snapshot?.fetchedAt, self.error),
            ("Claude", "claude", [self.claudeSnapshot?.fiveHour, self.claudeSnapshot?.weekly], self.claudeSnapshot?.fetchedAt, self.claudeError),
            ("Grok", "grok", [self.grokSnapshot?.window], self.grokSnapshot?.fetchedAt, self.grokError),
        ]
        var buttons: [NSView] = []
        for (index, source) in sources.enumerated() {
            if index == 1 && !self.claudeConnected {
                if self.expandedQuota == index { self.expandedQuota = nil }
                continue
            }
            guard source.date != nil || source.error != nil else {
                if self.expandedQuota == index { self.expandedQuota = nil }
                continue
            }
            buttons.append(self.quotaButton(source.name, icon: source.icon, windows: source.windows, index: index))
        }
        if buttons.isEmpty {
            buttons.append(self.label(self.refreshing ? "正在读取额度…" : "暂无额度数据", size: 11, color: .secondaryLabelColor))
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let footer = self.row(buttons + [NSView(), divider, refresh])
        footer.identifier = NSUserInterfaceItemIdentifier("quota-footer")
        footer.spacing = 12
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        self.append(footer)
        if let selected = self.expandedQuota {
            let source = sources[selected]
            self.append(self.label(source.name, size: 11, color: .secondaryLabelColor))
            for (index, window) in source.windows.enumerated() {
                if let window { self.quota(selected == 2 ? (self.grokSnapshot?.periodLabel ?? "当前周期") : (index == 0 ? "5 小时" : "每周"), window: window) }
            }
            if source.windows.allSatisfy({ $0 == nil }) {
                self.append(self.label("暂无额度数据", size: 11, color: .secondaryLabelColor))
            }
            if let date = source.date {
                let stale = source.error != nil || Date().timeIntervalSince(date) >= 900
                self.append(self.label("\(stale ? "上次更新于" : "更新于") \(date.formatted(.dateTime.month().day().hour().minute()))", size: 11, color: .secondaryLabelColor))
            }
        }
        self.quotaDirty = false
        self.renderedExpandedQuota = self.expandedQuota
        self.controller.view.layoutSubtreeIfNeeded()
        self.popover.contentSize = NSSize(width: self.width, height: self.controller.view.fittingSize.height)
        self.controller.view.setFrameSize(self.popover.contentSize)
        self.controller.view.layoutSubtreeIfNeeded()
        if self.popover.isShown { self.icons.load() }
    }

    func popoverDidShow(_ notification: Notification) {
        self.icons.load()
        self.durationTimer?.invalidate()
        self.durationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRunningDurations() }
        }
        self.durationTimer?.tolerance = 3
    }

    func popoverDidClose(_ notification: Notification) {
        self.icons.stop()
        self.durationTimer?.invalidate()
        self.durationTimer = nil
    }

    func updateRunningDurations(at now: Date = Date()) {
        for (label, updatedAt) in self.completedLabels {
            let minutes = max(0, Int((now.timeIntervalSince1970 - updatedAt) / 60))
            label.stringValue = minutes < 1 ? "刚刚" : minutes < 60 ? "\(minutes) 分钟前" : "\(minutes / 60) 小时前"
        }
        for (label, conversation) in self.runningLabels {
            label.stringValue = conversation.runningDuration(at: now) ?? ""
        }
    }

    private func quotaButton(_ name: String, icon: String, windows: [UsageWindow?], index: Int) -> NSButton {
        let percent = windows.compactMap { $0?.roundedRemainingPercent }.min()
        let value = percent.map { "\($0)%" } ?? "—"
        let button = NSButton(title: value, target: self, action: #selector(self.toggleQuota))
        button.identifier = NSUserInterfaceItemIdentifier("quota-" + name.lowercased())
        button.tag = index
        button.bezelStyle = .inline
        button.isBordered = false
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.font = font
        button.image = ConversationIcons.providerImage(icon, size: 16)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        let text = NSMutableAttributedString(string: value + "  ", attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        let arrow = NSTextAttachment()
        arrow.image = NSImage(systemSymbolName: self.expandedQuota == index ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        arrow.bounds = NSRect(x: 0, y: 0, width: 9, height: 9)
        text.append(NSAttributedString(attachment: arrow))
        button.attributedTitle = text
        let description = percent.map { "剩余 \($0)%（最紧张窗口）" } ?? "暂无额度数据"
        button.toolTip = "\(name) · \(description)，点击\(self.expandedQuota == index ? "收起" : "展开")详情"
        button.setAccessibilityLabel("\(name) \(description)")
        button.setAccessibilityHelp("点击展开或收起额度详情")
        button.setAccessibilityValue(self.expandedQuota == index ? "已展开" : "已收起")
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func conversationRow(_ conversation: Conversation, depth: Int) -> NSView {
        let nested = depth > 0
        let displayTitle = nested && conversation.displayTitle.hasPrefix("子代理 · ")
            ? String(conversation.displayTitle.dropFirst("子代理 · ".count)) : conversation.displayTitle
        let title = self.label(displayTitle, size: nested ? 12 : 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let project = self.label(conversation.project.map { "· " + $0 } ?? "", size: 11, color: .secondaryLabelColor)
        project.lineBreakMode = .byTruncatingTail
        project.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        project.widthAnchor.constraint(lessThanOrEqualToConstant: 95).isActive = true
        let icon = self.icons.image(for: conversation, compact: nested)
        icon.identifier = NSUserInterfaceItemIdentifier("conversation-icon")
        var views: [NSView] = [icon, title]
        if !nested { views.append(project) }
        views.append(NSView())
        if let duration = conversation.runningDuration() {
            let label = self.label(duration, size: 11, color: .secondaryLabelColor)
            self.runningLabels.append((label, conversation))
            views.append(label)
        } else if conversation.isStale {
            views.append(self.label(conversation.statusLabel, size: 11, color: .secondaryLabelColor))
        } else if conversation.phase == .completed {
            let minutes = max(0, Int((Date().timeIntervalSince1970 - conversation.updatedAt) / 60))
            let time = minutes < 1 ? "刚刚" : minutes < 60 ? "\(minutes) 分钟前" : "\(minutes / 60) 小时前"
            let label = self.label(time, size: 11, color: .secondaryLabelColor)
            self.completedLabels.append((label, conversation.updatedAt))
            views.append(label)
        }
        if nested {
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: CGFloat(min(depth, 5) * 18)).isActive = true
            views.insert(indent, at: 0)
        }
        let target = conversation.launchTarget(in: self.session.conversations + self.agents.conversations)
        let canOpen = target.flatMap { ITermConversationLauncher.sessionID(for: $0) } != nil
        if canOpen {
            let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)!)
            arrow.symbolConfiguration = .init(pointSize: 10, weight: .medium)
            arrow.contentTintColor = .secondaryLabelColor
            arrow.identifier = NSUserInterfaceItemIdentifier("open-conversation")
            arrow.widthAnchor.constraint(equalToConstant: 16).isActive = true
            arrow.setAccessibilityElement(false)
            views.append(arrow)
        }
        let row = self.row(views)
        row.spacing = 6
        if nested { row.setCustomSpacing(0, after: views[0]) }
        row.setCustomSpacing(nested ? 6 : 8, after: icon)
        row.heightAnchor.constraint(equalToConstant: nested ? 26 : 32).isActive = true
        let source = conversation.provider?.name ?? "Codex"
        row.toolTip = [conversation.displayTitle, conversation.cwd, "\(source) · \(conversation.statusLabel)",
                       conversation.runningDuration(),
                       "更新于 " + Date(timeIntervalSince1970: conversation.updatedAt).formatted()].compactMap { $0 }.joined(separator: "\n")
        if conversation.isSubagent {
            row.toolTip = (row.toolTip ?? "") + "\n" + (target.map { "所属主会话：" + $0.displayTitle } ?? "父会话不在当前列表中")
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel([conversation.displayTitle, conversation.project, source, conversation.statusLabel].compactMap { $0 }.joined(separator: "，"))
        if canOpen {
            let destination = target?.desktopURL == nil ? "iTerm" : "Codex 桌面端"
            let action = conversation.isSubagent ? "打开所属主会话" : "继续此会话"
            let button = ConversationOpenButton(title: "", target: self, action: #selector(self.openConversationAction(_:)))
            button.isBordered = false
            button.isEnabled = !self.openingConversation
            button.identifier = NSUserInterfaceItemIdentifier(conversation.id)
            button.toolTip = "点击在 \(destination) 中\(action) · " + (row.toolTip ?? "")
            button.setAccessibilityLabel("在 \(destination) 中\(action)：" + conversation.displayTitle + "，" + conversation.statusLabel)
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
            row.setAccessibilityElement(false)
        }
        return row
    }

    @objc private func openConversationAction(_ sender: NSButton) {
        guard !self.openingConversation,
              let conversation = (self.session.conversations + self.agents.conversations).first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        self.openingConversation = true
        self.render()
        Task {
            defer {
                self.openingConversation = false
                if self.popover.isShown { self.render() }
            }
            do {
                guard let target = conversation.launchTarget(in: self.session.conversations + self.agents.conversations) else { return }
                try await self.openConversation(target)
                self.popover.close()
            } catch {
                let alert = NSAlert()
                alert.messageText = "会话打开失败"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func toggleQuota(_ sender: NSButton) {
        self.expandedQuota = self.expandedQuota == sender.tag ? nil : sender.tag
        self.render()
    }

    private func quota(_ name: String, window: UsageWindow) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        let row = self.row([self.label(name, size: 13), NSView(),
                            self.label("剩余 \(window.roundedRemainingPercent)%", size: 13, weight: .medium)])
        let bar = QuotaBar(remainingPercent: window.remainingPercent, name: name)
        let reset: String
        if let date = window.resetsAt {
            let minutes = max(0, Int(ceil(date.timeIntervalSinceNow / 60)))
            if minutes == 0 { reset = "等待额度更新" }
            else if minutes >= 1440 { reset = "\(minutes / 1440) 天" + (minutes % 1440 / 60 > 0 ? " \(minutes % 1440 / 60) 小时" : "") + "后重置" }
            else if minutes >= 60 { reset = "\(minutes / 60) 小时" + (minutes % 60 > 0 ? " \(minutes % 60) 分钟" : "") + "后重置" }
            else { reset = "\(minutes) 分钟后重置" }
        } else { reset = "重置时间未知" }
        for view in [row, bar, self.label(reset, size: 11, color: .secondaryLabelColor)] {
            group.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        self.append(group)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func append(_ view: NSView) {
        self.content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: self.content.widthAnchor).isActive = true
    }

    private func separator() {
        let line = NSBox()
        line.boxType = .separator
        self.append(line)
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func refreshAction() { self.refresh() }

    @objc private func moreAction(_ sender: NSButton) {
        self.popover.close()
        self.openSettings()
    }

}

@MainActor
final class ConversationTreeList: NSStackView {
    var rows: [(view: NSView, depth: Int)] = []

    var branches: [NSBezierPath] {
        var parents: [NSRect] = []
        var paths: [NSBezierPath] = []
        for (row, depth) in self.rows {
            guard let icon = row.subviews.first(where: { $0.identifier?.rawValue == "conversation-icon" }) else { continue }
            let rect = self.convert(icon.bounds, from: icon)
            if depth < parents.count { parents.removeLast(parents.count - depth) }
            if let parent = parents.last, depth > 0, rect.minX > parent.midX {
                let direction: CGFloat = rect.midY > parent.midY ? 1 : -1
                let radius: CGFloat = 4
                let path = NSBezierPath()
                path.move(to: NSPoint(x: parent.midX, y: parent.midY + direction * parent.height / 2))
                path.line(to: NSPoint(x: parent.midX, y: rect.midY - direction * radius))
                path.curve(to: NSPoint(x: parent.midX + radius, y: rect.midY),
                           controlPoint1: NSPoint(x: parent.midX, y: rect.midY),
                           controlPoint2: NSPoint(x: parent.midX, y: rect.midY))
                path.line(to: NSPoint(x: rect.minX - 2, y: rect.midY))
                paths.append(path)
            }
            parents.append(rect)
        }
        return paths
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        for path in self.branches {
            path.lineWidth = 1
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

@MainActor
private final class ConversationOpenButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering: Bool {
        guard let window, window.isKeyWindow else { return false }
        return self.bounds.intersection(self.visibleRect).contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { self.removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.hoverArea = area
        self.needsDisplay = true
    }

    override func resetCursorRects() {
        if self.isEnabled { self.addCursorRect(self.bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard self.isEnabled && (self.hovering || self.isHighlighted) else { return }
        NSColor.controlAccentColor.withAlphaComponent(self.isHighlighted ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: self.bounds, xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class QuotaBar: NSView {
    private let remainingPercent: Double

    init(remainingPercent: Double, name: String) {
        self.remainingPercent = remainingPercent
        super.init(frame: .zero)
        self.heightAnchor.constraint(equalToConstant: 5).isActive = true
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.progressIndicator)
        self.setAccessibilityLabel("\(name)剩余额度")
        self.setAccessibilityValue(remainingPercent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: self.bounds, xRadius: 2.5, yRadius: 2.5).fill()
        NSColor.systemTeal.setFill()
        var fill = self.bounds
        fill.size.width *= self.remainingPercent / 100
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}
