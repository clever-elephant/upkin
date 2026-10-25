import AppKit

@MainActor
enum MenuBarQuotaImage {
    static func make(remainingPercent: Int?, runnerImage: NSImage, hasWaiting: Bool = false) -> NSImage {
        let size = NSSize(width: hasWaiting ? 70 : 65, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            self.drawRunner(runnerImage, in: NSRect(x: 0, y: 0, width: 36, height: 22),
                templateColor: .labelColor)
            self.drawQuota(
                remainingPercent,
                in: NSRect(x: 32, y: 0, width: 34, height: 22),
                color: .labelColor)

            if hasWaiting {
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 66, y: 10, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = runnerImage.isTemplate
        return image
    }

    // The system receives one still per state; the independent character layer handles animation.
    static func makeRasterized(remainingPercent: Int?, runnerImage: NSImage, scale: CGFloat, hasWaiting: Bool = false) -> NSImage {
        return autoreleasepool {
            let source = self.make(remainingPercent: remainingPercent, runnerImage: runnerImage, hasWaiting: hasWaiting)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(source.size.width * scale), pixelsHigh: Int(source.size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            context.cgContext.scaleBy(x: scale, y: scale)
            source.draw(in: NSRect(origin: .zero, size: source.size))
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = source.size
            let image = NSImage(size: source.size)
            image.addRepresentation(bitmap)
            image.isTemplate = source.isTemplate
            return image
        }
    }

    private static func drawRunner(_ runnerImage: NSImage, in rect: NSRect, templateColor: NSColor) {
        let scale = min(rect.width / runnerImage.size.width, rect.height / runnerImage.size.height)
        let size = NSSize(width: runnerImage.size.width * scale, height: runnerImage.size.height * scale)
        let imageRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height)
        if runnerImage.isTemplate {
            let tinted = NSImage(size: imageRect.size)
            tinted.lockFocus()
            templateColor.withAlphaComponent(0.94).setFill()
            NSRect(origin: .zero, size: imageRect.size).fill()
            runnerImage.draw(
                in: NSRect(origin: .zero, size: imageRect.size),
                from: .zero,
                operation: .destinationIn,
                fraction: 0.92)
            tinted.unlockFocus()
            tinted.draw(in: imageRect)
        } else {
            runnerImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 0.92)
        }
    }

    private static func drawQuota(
        _ remainingPercent: Int?,
        in rect: NSRect,
        color: NSColor)
    {
        let text = (remainingPercent.map { "\($0)%" } ?? "--") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(remainingPercent == nil ? 0.48 : 1)
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.minX, y: rect.midY - textSize.height / 2),
                  withAttributes: attributes)
    }

}
