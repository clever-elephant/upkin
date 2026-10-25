#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/conversation-hover-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
python3 - "$ROOT" "$TEMP" <<'PY'
import pathlib, sys
root, temp = map(pathlib.Path, sys.argv[1:])
source = (root / 'Sources/Upkin/StatusPopoverController.swift').read_text()
start = source.index('@MainActor\nprivate final class ConversationOpenButton:')
end = source.index('@MainActor\nprivate final class QuotaBar:', start)
(temp / 'main.swift').write_text('import AppKit\n' + source[start:end] + r'''
@MainActor
private final class HoverTestWindow: NSWindow {
    var pointer = NSPoint.zero
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}
extension ConversationOpenButton {
    static func verifyScrollHover() {
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(scroll)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        scroll.documentView = document
        let rows = (0..<3).map { index in
            let button = ConversationOpenButton(frame: NSRect(x: 0, y: index * 40, width: 180, height: 32))
            document.addSubview(button)
            return button
        }
        scroll.contentView.scroll(to: .zero)
        window.pointer = rows[1].convert(NSPoint(x: 20, y: 16), to: nil)
        precondition(rows[1].hovering && rows.filter(\.hovering).count == 1)
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        rows[1].mouseEntered(with: entered)
        // Scroll with a stationary pointer and no mouseExited event for the old row.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        rows.forEach { $0.updateTrackingAreas() }
        precondition(!rows[1].hovering, "Scrolling must clear the previous row's hover")
        precondition(rows[2].hovering && rows.filter(\.hovering).count == 1,
                     "Only the row currently under the pointer may be highlighted")
        rows[2].needsDisplay = false
        rows[2].updateTrackingAreas()
        precondition(rows[2].needsDisplay, "Tracking changes must redraw the hover")
        window.pointer = NSPoint(x: -20, y: -20)
        precondition(rows.allSatisfy { !$0.hovering }, "Leaving the list clears every hover")
        print("PASS: stationary-pointer scroll clears stale hover; exactly one current row; redraw; pointer outside")
    }
}
_ = NSApplication.shared
ConversationOpenButton.verifyScrollHover()
''')
PY
swiftc -swift-version 6 "$TEMP/main.swift" -o "$TEMP/check"
"$TEMP/check"
