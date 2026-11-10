import Foundation
import AppKit

func measure(_ path: String) {
    guard let img = NSImage(contentsOfFile: path),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { print("  cannot read \(path)"); return }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.06 else { continue }
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= 0 else { print("  \(path): fully transparent"); return }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    let name = (path as NSString).lastPathComponent
    print(String(format: "  %-26s canvas %dx%d  body %dx%d  = %.1f%% wide, insets L%d R%d T%d B%d",
                 (name as NSString).utf8String!, w, h, bw, bh,
                 100.0 * Double(bw) / Double(w), minX, w - 1 - maxX, minY, h - 1 - maxY))
}

func makeIconset(source: String, out: String, bodyFraction: Double) {
    guard let image = NSImage(contentsOfFile: source) else { print("cannot read \(source)"); exit(1) }
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in sizes {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let body = (Double(px) * bodyFraction).rounded()
        let inset = ((Double(px) - body) / 2).rounded()
        image.draw(in: NSRect(x: inset, y: inset, width: body, height: body),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
    print("wrote \(sizes.count) sizes into \(out) at \(Int(bodyFraction * 100))% body")
}


/// iOS wants the opposite of macOS: a full-bleed square with no alpha and no rounded
/// corners, because the system applies its own mask. The source art is a rounded square
/// on transparency, so the canvas is painted by first drawing the art oversized - far
/// enough that only its solid interior is in frame, which floods the corners with the
/// art's own background colour - and then drawing it again at true size on top. That
/// avoids having to sample or hard-code the background colour anywhere.
func makeIOSIcons(source: String, out: String) {
    guard let image = NSImage(contentsOfFile: source) else { print("cannot read \(source)"); exit(1) }
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

    let flood: CGFloat = 1.35   // comfortably past the corner radius

    for (name, px) in [("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180),
                       ("AppIcon76x76@2x~ipad", 152), ("AppIcon1024", 1024)] {
        // Opaque RGB with an unused fourth byte. A three-sample NSBitmapImageRep with no
        // alpha looks like the obvious way to say "no alpha", but AppKit can't make a
        // graphics context for that format: NSGraphicsContext(bitmapImageRep:) returns
        // nil, every draw goes nowhere, and the PNG comes out solid black - which is what
        // shipped to the phone until it was caught. noneSkipLast is a format Quartz
        // draws into, and it still encodes without an alpha channel.
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high

        let side = CGFloat(px)
        let over = side * flood
        let offset = (side - over) / 2
        image.draw(in: NSRect(x: offset, y: offset, width: over, height: over),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        // A canvas with every colour byte still zero is the signature of a context that
        // silently drew nothing. Refuse it rather than write another black icon.
        if let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self),
           !(0..<(ctx.bytesPerRow * px)).contains(where: { $0 % 4 != 3 && bytes[$0] != 0 }) {
            print("  \(name): rendered blank - refusing to write it")
            exit(1)
        }

        guard let cg = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { continue }
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        print("  \(name).png  \(px)x\(px)")
    }
    print("wrote iOS icons into \(out) (opaque, unrounded)")
}

@main
struct IconKit {
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 2 else { print("usage: iconkit measure <png>… | make <src> <out.iconset> <fraction>"); exit(1) }
        switch a[1] {
        case "measure": for p in a.dropFirst(2) { measure(p) }
        case "make":    makeIconset(source: a[2], out: a[3], bodyFraction: Double(a[4]) ?? 0.805)
        case "ios":     makeIOSIcons(source: a[2], out: a[3])
        default: print("unknown \(a[1])"); exit(1)
        }
    }
}
