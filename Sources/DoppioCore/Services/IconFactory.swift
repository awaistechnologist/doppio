import Foundation
import AppKit

/// Extracts a target app's icon and renders the Shot's own variant: optional
/// colour tint plus a short text badge, written out as a multi-resolution
/// `.icns` so the Dock, Cmd-Tab and Finder all look right.
public enum IconError: LocalizedError {
    case icnsConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .icnsConversionFailed(let name):
            return "Could not build \(name): iconutil failed. The Shot will use the original app's icon."
        }
    }
}

public enum IconFactory {
    /// Sizes a well-formed `.icns` is expected to carry.
    public static let iconSizes: [(name: String, px: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    public static func baseImage(for shot: Shot, target: TargetApp?) -> NSImage {
        if let target {
            let icon = NSWorkspace.shared.icon(forFile: target.path)
            icon.size = NSSize(width: 1024, height: 1024)
            return icon
        }
        if shot.mode == .web {
            return symbolImage("globe")
        }
        if shot.mode == .file, let path = shot.documentPath {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 1024, height: 1024)
            return icon
        }
        return symbolImage("cup.and.saucer.fill")
    }

    static func symbolImage(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 640, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let canvas = NSImage(size: NSSize(width: 1024, height: 1024))
        canvas.lockFocus()
        NSColor.darkGray.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 180, yRadius: 180).fill()
        if let image {
            let rect = NSRect(x: 192, y: 192, width: 640, height: 640)
            NSColor.white.set()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        canvas.unlockFocus()
        return canvas
    }

    /// Composites tint and badge onto the base icon.
    public static func renderedImage(for shot: Shot, target: TargetApp?) -> NSImage {
        let base = baseImage(for: shot, target: target)
        let size = NSSize(width: 1024, height: 1024)
        let output = NSImage(size: size)
        output.lockFocus()
        defer { output.unlockFocus() }

        base.draw(in: NSRect(origin: .zero, size: size),
                  from: .zero, operation: .sourceOver, fraction: 1.0)

        if let hex = shot.iconTint, let tint = NSColor(hex: hex) {
            // Multiply keeps the icon's shape and shading legible while
            // shifting its hue, which reads better than a flat overlay.
            tint.withAlphaComponent(0.55).set()
            NSRect(origin: .zero, size: size).fill(using: .plusDarker)
        }

        if let badge = shot.iconBadge, !badge.isEmpty {
            drawBadge(String(badge.prefix(3)), in: size)
        }

        return output
    }

    static func drawBadge(_ text: String, in size: NSSize) {
        let diameter: CGFloat = 400
        let rect = NSRect(x: size.width - diameter - 40, y: 40, width: diameter, height: diameter)

        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -10, dy: -10)).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()

        let fontSize: CGFloat = text.count > 2 ? 170 : 230
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        string.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                               y: rect.midY - textSize.height / 2))
    }

    /// Writes a real multi-representation `.icns`.
    ///
    /// `iconutil` needs an `.iconset` directory, so build one in a temporary
    /// location and convert. Falls back to a single-size icns if `iconutil` is
    /// unavailable, which keeps Shot creation working rather than failing.
    public static func writeIcon(for shot: Shot, target: TargetApp?, to destination: URL) throws {
        let image = renderedImage(for: shot, target: target)
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("doppio-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        for entry in iconSizes {
            guard let png = pngData(from: image, pixels: entry.px) else { continue }
            try png.write(to: iconset.appendingPathComponent("\(entry.name).png"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        // If iconutil is unavailable or fails, do NOT write PNG bytes into a
        // .icns: the file would exist, satisfy every "did we write an icon"
        // check, and render as a blank tile. Report it instead so the caller
        // can fall back to the target's own icon.
        guard fm.fileExists(atPath: destination.path) else {
            throw IconError.icnsConversionFailed(destination.lastPathComponent)
        }
    }

    static func pngData(from image: NSImage, pixels: Int) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}

extension NSColor {
    /// Parses `#RRGGBB` / `RRGGBB`.
    public convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0)
    }

    public var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
