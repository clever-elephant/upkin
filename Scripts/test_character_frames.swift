#!/usr/bin/env swift
import AppKit
import Foundation

struct Manifest: Decodable {
    struct State: Decodable { let frames: Int; let fps: Double; let loop: Bool; let staticFrame: Int; let loopStartFrame: Int? }
    let version: Int
    let width: Int
    let height: Int
    let states: [String: State]
}
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath + "/Resources/CharacterFrames")
let ids = ["02", "30", "32", "35", "33", "34", "11"]
func pixels(_ file: URL) throws -> [UInt8] {
    let image = NSImage(contentsOf: file)!
    var bounds = NSRect(x: 0, y: 0, width: 72, height: 44)
    let cg = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)!
    precondition(cg.width == 72 && cg.height == 44, file.path)
    var bytes = [UInt8](repeating: 0, count: 72 * 44 * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 72, height: 44, bitsPerComponent: 8,
            bytesPerRow: 72 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 72, height: 44))
    }
    return bytes
}
func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    zip(a, b).reduce(0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
}
var tested = 0
let packs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("manifest.json").path)
}.sorted()
precondition(!packs.isEmpty, "No character packs found")
for pack in packs {
    let folder = root.appendingPathComponent(pack)
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    precondition(manifest.version == 1 && manifest.width == 72 && manifest.height == 44)
    precondition(Set(manifest.states.keys) == Set(ids))
    for id in ids {
        let state = manifest.states[id]!
        precondition(state.fps.isFinite && (1...15).contains(state.fps) && (1...150).contains(state.frames) && state.staticFrame >= 0 && state.staticFrame < state.frames)
        if let start = state.loopStartFrame { precondition(state.loop && start > 0 && start < state.frames) }
        let directory = folder.appendingPathComponent(id)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        precondition(Set(files) == Set((0..<state.frames).map { "\($0).png" }))
        var first: [UInt8] = [], last: [UInt8] = []
        var largestStep = 0.0
        for index in 0..<state.frames {
            let bytes = try pixels(directory.appendingPathComponent("\(index).png"))
            let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
            precondition(alpha.contains(0), "\(pack)/\(id)/\(index) lost transparency")
            precondition(alpha.contains { $0 > 0 }, "\(pack)/\(id)/\(index) is empty")
            if index == 0 { first = bytes } else { largestStep = max(largestStep, difference(last, bytes)) }
            last = bytes
            tested += 1
        }
        let seam = difference(first, last)
        print("PASS \(pack)/\(id) \(state.frames) RGBA frames; seam mean=\(String(format: "%.2f", seam)), max consecutive=\(String(format: "%.2f", largestStep)) /255")
    }
}
print("PASS \(tested) PNGs: fixed dimensions, transparency, visible content, complete state sets")
