import AppKit
import UpkinCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let pane = SettingsPane()
    private let title = NSTextField(labelWithString: "工具连接")
    private let connections = NSStackView()
    private let characterPreview = CharacterPreviewController()
    private lazy var characterContent: NSView = {
        let view = self.characterPreview.window!.contentView!
        view.heightAnchor.constraint(equalToConstant: 270).isActive = true
        return view
    }()
    private let hookConfiguration: ActivityHookConfiguration
    private let hookHint = NSTextField(labelWithString: "连接后自动接入额度与会话活动。")
    private var navigation: [NSButton] = []
    private var statuses: [NSTextField] = []
    private var actions: [NSButton] = []
    private let refreshCodex: () -> Void
    private let refreshGrok: () -> Void
    private let connectClaude: () -> Void
    private let disconnectClaude: () -> Void
    private let notificationsChanged: () -> Void
    private var connectionValues: [(ready: Bool, error: String?, busy: Bool)] = Array(repeating: (false, nil, false), count: 3)
    private var hookErrors: [Int: String] = [:]
    private var claudeGranted = false
    private var claudeNeedsHookCleanup = false
    private(set) var selectedSection = 0

    init(refreshCodex: @escaping () -> Void, refreshGrok: @escaping () -> Void,
         connectClaude: @escaping () -> Void, disconnectClaude: @escaping () -> Void,
         notificationsChanged: @escaping () -> Void = {},
         hookConfiguration: ActivityHookConfiguration? = nil) {
        self.hookConfiguration = hookConfiguration ?? ActivityHookConfiguration(script:
            Bundle.main.resourceURL!.appendingPathComponent("upkin-activity.py"))
        self.refreshCodex = refreshCodex
        self.refreshGrok = refreshGrok
        self.connectClaude = connectClaude
        self.disconnectClaude = disconnectClaude
        self.notificationsChanged = notificationsChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Upkin 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = window.contentView!
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        self.pane.clipsToBounds = true
        self.pane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self.pane)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 166),
            self.pane.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            self.pane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            self.pane.topAnchor.constraint(equalTo: root.topAnchor),
            self.pane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let brand = NSStackView()
        brand.spacing = 6
        let mascot = NSImageView(image: CharacterFrames.representative(character: "grok", emotion: .idle)
                                 ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        mascot.imageScaling = .scaleProportionallyUpOrDown
        mascot.widthAnchor.constraint(equalToConstant: 36).isActive = true
        mascot.heightAnchor.constraint(equalToConstant: 28).isActive = true
        brand.addArrangedSubview(mascot)
        brand.addArrangedSubview(self.label("Upkin", size: 18, weight: .semibold))
        let list = NSStackView(views: [brand])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.setCustomSpacing(22, after: brand)
        for (index, title) in ["连接", "角色", "通知", "关于"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(self.sectionAction(_:)))
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("settings-section-\(index)")
            button.bezelStyle = .recessed
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.widthAnchor.constraint(equalToConstant: 142).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            self.navigation.append(button)
            list.addArrangedSubview(button)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            list.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
        ])
        self.title.font = .systemFont(ofSize: 20, weight: .semibold)
        self.selectSection(0)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        self.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if self.selectedSection == 1 { self.characterPreview.prepare() }
        self.updateConnections()
    }

    func update(codexReady: Bool, codexError: String?, codexBusy: Bool,
                claudeReady: Bool, claudeGranted: Bool, claudeError: String?, claudeBusy: Bool,
                grokReady: Bool, grokError: String?, grokBusy: Bool) {
        self.claudeGranted = claudeGranted
        self.connectionValues = [(codexReady, codexError, codexBusy), (claudeReady, claudeError, claudeBusy), (grokReady, grokError, grokBusy)]
        self.updateConnections()
    }

    private func updateConnections() {
        for (index, value) in self.connectionValues.enumerated() {
            var hookStatus = ActivityHookConfiguration.Status.configured
            var error = self.hookErrors[index] ?? value.error
            if index > 0 {
                do { hookStatus = try self.hookConfiguration.status(for: index == 1 ? .claude : .grok) }
                catch let failure { error = failure.localizedDescription }
            }
            let ready = value.ready && error == nil && hookStatus == .configured
            self.statuses[index].stringValue = value.busy ? "连接中…" : error != nil ? "连接失败"
                : ready ? "已连接" : hookStatus == .outdated ? "需更新" : "未连接"
            self.statuses[index].textColor = ready && !value.busy ? .systemGreen : .secondaryLabelColor
            self.statuses[index].toolTip = error
            self.actions[index].isEnabled = !value.busy
            self.actions[index].title = index == 1 && (self.claudeGranted || self.claudeNeedsHookCleanup) ? "管理…"
                : error != nil ? "重试" : ready ? "刷新" : "连接"
            self.actions[index].toolTip = index == 1 && (self.claudeGranted || self.claudeNeedsHookCleanup) ? "刷新、重试或断开 Claude 连接"
                : error ?? (index == 0 ? "刷新 Codex" : "连接额度并配置本地会话活动")
            self.actions[index].menu?.items.forEach { $0.isEnabled = !value.busy }
            if index == 1 {
                self.actions[index].menu?.items.last?.title = !self.claudeGranted && self.claudeNeedsHookCleanup ? "重试清理会话配置" : "断开"
            }
            let primary = !ready && !value.busy
            self.actions[index].bezelColor = primary ? .controlAccentColor : nil
            self.actions[index].contentTintColor = primary ? .white : nil
        }
    }

    func selectSection(_ index: Int) {
        guard self.navigation.indices.contains(index) else { return }
        self.characterPreview.releasePreviews()
        self.selectedSection = index
        for button in self.navigation {
            let selected = button.tag == index
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            button.contentTintColor = selected ? .white : .labelColor
            button.setAccessibilityValue(selected ? "已选择" : "")
        }
        self.pane.subviews.forEach { $0.removeFromSuperview() }
        self.title.stringValue = ["工具连接", "角色", "通知", "关于 Upkin"][index]
        self.title.translatesAutoresizingMaskIntoConstraints = false
        self.pane.addSubview(self.title)
        NSLayoutConstraint.activate([
            self.title.leadingAnchor.constraint(equalTo: self.pane.leadingAnchor, constant: 28),
            self.title.topAnchor.constraint(equalTo: self.pane.topAnchor, constant: 48),
        ])
        let body: NSView
        if index == 0 {
            if self.statuses.isEmpty { self.buildConnections() }
            self.updateConnections()
            body = self.connections
        } else if index == 1 {
            body = self.characterContent
        } else if index == 2 {
            let toggle = NSButton(checkboxWithTitle: "会话完成或等待操作时通知", target: self, action: #selector(self.notificationsAction(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier("completion-notifications")
            toggle.state = CompletionNotificationController.isEnabled ? .on : .off
            let settings = NSButton(title: "系统通知设置…", target: self, action: #selector(self.notificationSettingsAction))
            settings.bezelStyle = .rounded
            let stack = NSStackView(views: [toggle,
                self.label("默认静音，点击通知返回对应会话。", size: 12),
                self.label("菜单栏气泡无需通知权限；允许系统通知可保留历史提醒。", size: 12), settings])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            body = stack
        } else {
            let version = UpkinVersion.current
            let info = NSStackView(views: [self.label("Upkin \(version)", size: 15, weight: .medium),
                self.label("在菜单栏显示 Codex、Claude Code、Grok Build 的任务状态和剩余额度。", size: 13),
                self.label("AGPL-3.0", size: 11)])
            info.orientation = .vertical
            info.alignment = .leading
            info.spacing = 12
            let notices = NSButton(title: "开源许可…", target: self, action: #selector(self.noticesAction))
            notices.bezelStyle = .rounded
            info.addArrangedSubview(notices)
            body = info
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        self.pane.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: self.pane.leadingAnchor, constant: index == 1 ? 4 : 28),
            body.trailingAnchor.constraint(equalTo: self.pane.trailingAnchor, constant: index == 1 ? -4 : -28),
            body.topAnchor.constraint(equalTo: self.title.bottomAnchor, constant: 28),
        ])
        if index == 1 {
            if self.window?.isVisible == true { self.characterPreview.prepare() }
        }
    }

    private func buildConnections() {
        self.connections.orientation = .vertical
        self.connections.alignment = .leading
        self.connections.spacing = 0
        for (index, item) in [("Codex", "openai"), ("Claude Code", "claude"), ("Grok Build", "grok")].enumerated() {
            let icon = NSImageView(image: ConversationIcons.providerImage(item.1, size: 24))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let status = self.label("未连接", size: 11)
            status.textColor = .secondaryLabelColor
            status.identifier = NSUserInterfaceItemIdentifier("settings-status-\(index)")
            let action = NSButton(title: "连接", target: self, action: #selector(self.connectionAction(_:)))
            action.tag = index
            action.identifier = NSUserInterfaceItemIdentifier("settings-action-\(index)")
            action.bezelStyle = .rounded
            action.controlSize = .small
            action.widthAnchor.constraint(equalToConstant: 70).isActive = true
            if index == 1 {
                let menu = NSMenu()
                menu.autoenablesItems = false
                for (title, selector) in [("刷新／重试连接", #selector(self.retryClaudeAction)),
                                          ("断开", #selector(self.disconnectClaudeAction))] {
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
                action.menu = menu
            }
            let row = NSStackView(views: [icon, self.label(item.0, size: 13, weight: .medium), NSView(), status, action])
            row.spacing = 12
            row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 62).isActive = true
            self.connections.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: self.connections.widthAnchor).isActive = true
            self.statuses.append(status)
            self.actions.append(action)
            let line = NSBox()
            line.boxType = .separator
            self.connections.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: self.connections.widthAnchor).isActive = true
        }
        self.hookHint.font = .systemFont(ofSize: 11)
        self.hookHint.textColor = .secondaryLabelColor
        self.connections.addArrangedSubview(self.hookHint)
        self.connections.setCustomSpacing(12, after: self.connections.arrangedSubviews[self.connections.arrangedSubviews.count - 2])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    @objc private func notificationsAction(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: CompletionNotificationController.enabledKey)
        self.notificationsChanged()
    }

    @objc private func notificationSettingsAction() { CompletionNotificationController.openSystemSettings() }

    @objc private func sectionAction(_ sender: NSButton) { self.selectSection(sender.tag) }
    @objc private func connectionAction(_ sender: NSButton) {
        let index = sender.tag
        guard self.connectionValues.indices.contains(index), !self.connectionValues[index].busy else { return }
        if index == 1 && (self.claudeGranted || self.claudeNeedsHookCleanup) {
            sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
            return
        }
        self.connect(index)
    }

    @objc private func retryClaudeAction() { self.connect(1) }

    @objc private func disconnectClaudeAction() {
        guard self.claudeGranted || self.claudeNeedsHookCleanup, !self.connectionValues[1].busy else { return }
        if self.claudeGranted {
            self.claudeGranted = false
            self.disconnectClaude()
        }
        do {
            try self.hookConfiguration.configure(.claude, install: false)
            self.claudeNeedsHookCleanup = false
            self.hookErrors[1] = nil
            self.hookHint.stringValue = "已断开 Claude Code。"
        } catch {
            self.claudeNeedsHookCleanup = true
            self.hookErrors[1] = error.localizedDescription
            self.hookHint.stringValue = "额度授权已撤销；会话配置清理失败，请修复配置后重试。"
        }
        self.updateConnections()
    }

    private func connect(_ index: Int) {
        guard !self.connectionValues[index].busy else { return }
        if index == 0 { self.refreshCodex(); return }
        let provider: CodingAgent = index == 1 ? .claude : .grok
        do {
            if try self.hookConfiguration.status(for: provider) != .configured {
                try self.hookConfiguration.configure(provider, install: true)
                self.hookHint.stringValue = "会话接入已配置，重新打开 \(provider.name) 会话后生效。"
            }
            self.hookErrors[index] = nil
            if index == 1 { self.connectClaude() }
            else { self.refreshGrok() }
        } catch {
            self.hookErrors[index] = error.localizedDescription
        }
        self.updateConnections()
    }

    @objc private func noticesAction() {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = root.appendingPathComponent("THIRD_PARTY_NOTICES.md")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("THIRD_PARTY_NOTICES.md")
        if !NSWorkspace.shared.open(bundled) { NSWorkspace.shared.open(local) }
    }
    func windowWillClose(_ notification: Notification) { self.characterPreview.releasePreviews() }
}

@MainActor
private final class SettingsPane: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        self.bounds.intersection(dirtyRect).fill()
    }
}
