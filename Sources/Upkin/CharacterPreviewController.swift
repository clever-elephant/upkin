import AppKit
import UpkinCore

@MainActor
final class CharacterPreviewController: NSWindowController, NSWindowDelegate {
    private let characters = NSStackView()
    private let grid = NSStackView()
    private var packs: [CharacterPack] = []
    private var choices: [NSButton] = []
    private var selectedID: String?
    private(set) var previews: [GrokBallView] = []
    private static let labels = ["待机", "思考", "工作", "等待", "完成", "错误", "待确认"]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 526, height: 270),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "角色"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        self.characters.spacing = 12
        self.grid.distribution = .fillEqually
        let divider = NSBox()
        divider.boxType = .separator
        let heading = NSTextField(labelWithString: "状态预览")
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.textColor = .secondaryLabelColor
        let reset = NSButton(title: "默认预览", target: self, action: #selector(self.resetCharacters))
        reset.bezelStyle = .inline
        reset.identifier = NSUserInterfaceItemIdentifier("reset-characters")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = self.characters
        self.characters.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        for view in [scroll, divider, heading, reset, self.grid] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.heightAnchor.constraint(equalToConstant: 110),
            self.characters.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            self.characters.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            self.characters.heightAnchor.constraint(equalToConstant: 96),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            heading.leadingAnchor.constraint(equalTo: divider.leadingAnchor),
            heading.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 20),
            reset.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            self.grid.leadingAnchor.constraint(equalTo: divider.leadingAnchor),
            self.grid.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
            self.grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        self.prepare()
        self.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func prepare() {
        CharacterFrames.reloadCatalog()
        self.packs = CharacterFrames.catalog.packs
        for view in self.characters.arrangedSubviews {
            self.characters.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        self.choices.removeAll()
        for (index, pack) in self.packs.enumerated() {
            let button = CharacterChoiceButton(title: "", target: self, action: #selector(self.chooseCharacter(_:)))
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("character-\(pack.id)")
            button.setAccessibilityLabel(pack.name)
            button.toolTip = pack.name
            let image = NSImageView()
            image.image = Self.thumbnail(character: pack.id)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 54).isActive = true
            image.heightAnchor.constraint(equalToConstant: 33).isActive = true
            let label = NSTextField(labelWithString: pack.name)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.alignment = .center
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 68).isActive = true
            let content = NSStackView(views: [image, label])
            content.orientation = .vertical
            content.alignment = .centerX
            content.spacing = 12
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.widthAnchor.constraint(equalToConstant: 96).isActive = true
            button.heightAnchor.constraint(equalToConstant: 96).isActive = true
            self.characters.addArrangedSubview(button)
            self.choices.append(button)
        }
        let current = self.selectedID ?? CharacterFrames.character(for: "codex")
        self.select(character: self.packs.firstIndex { $0.id == current } ?? 0)
    }

    private static func thumbnail(character: String) -> NSImage? {
        guard let image = CharacterFrames.representative(character: character, emotion: .idle),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: source)
        var bounds = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        // Menu-bar frames include asymmetric transparent space; center only the gallery artwork.
        guard !bounds.isNull, let cropped = source.cropping(to: bounds) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    @objc private func chooseCharacter(_ sender: NSButton) {
        guard self.packs.indices.contains(sender.tag) else { return }
        let id = self.packs[sender.tag].id
        if self.selectedID != id { self.select(character: sender.tag) }
        else { sender.state = .on }  // Clicking the current choice must not toggle it off.
    }

    @objc private func resetCharacters() {
        self.selectedID = nil
        self.prepare()
    }

    func select(character: Int) {
        guard self.packs.indices.contains(character) else {
            self.releasePreviews()
            return
        }
        let id = self.packs[character].id
        self.selectedID = id
        for (index, button) in self.choices.enumerated() {
            let selected = index == character
            button.state = selected ? .on : .off
            button.layer?.borderWidth = selected ? 1 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
            button.setAccessibilityValue(selected ? "已选择" : "")
        }
        self.releasePreviews()
        for (index, emotion) in GrokBallEmotion.allCases.enumerated() {
            let view = GrokBallView(character: id)
            view.setAccessibilityLabel(Self.labels[index])
            let label = NSTextField(labelWithString: Self.labels[index])
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let item = NSStackView(views: [view, label])
            item.orientation = .vertical
            item.alignment = .centerX
            item.spacing = 12
            item.toolTip = Self.labels[index]
            self.grid.addArrangedSubview(item)
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 36),
                view.heightAnchor.constraint(equalToConstant: 22),
            ])
            self.previews.append(view)
            if !view.show(emotion) {
                item.toolTip = "资源缺失或损坏：\(id)/\(emotion.rawValue)"
                view.setAccessibilityLabel(item.toolTip)
            }
        }
    }

    func releasePreviews() {
        for preview in self.previews {
            preview.stop()
            preview.removeFromSuperview()
        }
        self.previews.removeAll()
        for row in self.grid.arrangedSubviews {
            self.grid.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.releasePreviews()
    }
}

@MainActor
private final class CharacterChoiceButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the icon and label inside the same clickable choice.
        super.hitTest(point) == nil ? nil : self
    }
}
