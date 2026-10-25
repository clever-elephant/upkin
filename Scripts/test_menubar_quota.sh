#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/menu-bar-quota-test.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/test_support.sh"
cat > "$TEMP/check.swift" <<'SWIFT'
import AppKit
import UpkinCore

@main
@MainActor
struct Check {
    static func main() throws {
        let runner = NSImage(size: NSSize(width: 19, height: 18))
        runner.lockFocus()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 15, height: 14)).fill()
        runner.unlockFocus()
        for scale in [1, 2] {
            for template in [false, true] {
                runner.isTemplate = template
                var outputs = Set<Data>()
                for percent: Int? in [nil, 0, 85, 100] {
                    let standard = MenuBarQuotaImage.make(
                        remainingPercent: percent,
                        runnerImage: runner)
                    let width = percent == nil ? 44 : (percent == 0 ? 52 : (percent == 100 ? 68 : 60))
                    precondition(standard.size == NSSize(width: width, height: 22))
                    precondition(standard.isTemplate == template)
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: width * scale, pixelsHigh: 22 * scale,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                    standard.draw(in: NSRect(origin: .zero, size: standard.size))
                    NSGraphicsContext.restoreGraphicsState()
                    outputs.insert(bitmap.representation(using: .png, properties: [:])!)
                    let text = (percent.map { "\($0)%" } ?? "--") as NSString
                    let textWidth = text.size(withAttributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                    ]).width
                    precondition(CGFloat(width) >= 32 + textWidth && CGFloat(width) < 33 + textWidth,
                        "Quota must fit without extra trailing padding")
                }
                precondition(outputs.count == 4, "Standard quota values must render distinctly at 1x and 2x")
            }
        }
        runner.isTemplate = false
        for scale: CGFloat in [1, 2] {
            let raster = MenuBarQuotaImage.makeRasterized(remainingPercent: 85, runnerImage: runner, scale: scale)
            let bitmap = raster.representations.first as! NSBitmapImageRep
            precondition(raster.size == NSSize(width: 60, height: 22))
            precondition(bitmap.pixelsWide == Int(60 * scale) && bitmap.pixelsHigh == Int(22 * scale))
            precondition(bitmap.hasAlpha && !raster.isTemplate)
            var visible = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0 { visible = true }
            }
            precondition(visible, "Flat bitmap must contain both icon/quota drawing, not an empty image")
        }
        var themed: [Data] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let raster = MenuBarQuotaImage.makeRasterized(remainingPercent: 85, runnerImage: runner, scale: 2)
                themed.append(raster.tiffRepresentation!)
            }
        }
        precondition(themed[0] != themed[1], "Rasterized quota must respect light/dark appearance")
        print("PASS: single icon/quota layout; template/color; unknown/0/85/100 at 1x/2x without clipping")
    }
}
SWIFT
swiftc -parse-as-library -I "$BIN/Modules" "$TEMP/check.swift" \
    "$ROOT/Sources/Upkin/MenuBarQuotaImage.swift" \
    "${CORE_OBJECTS[@]}" -o "$TEMP/check"
"$TEMP/check"
