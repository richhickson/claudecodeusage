import AppKit

enum MenubarIconStyle: String, CaseIterable {
    case spark = "spark"
    case clawd = "clawd"

    var displayName: String {
        switch self {
        case .spark: return "Spark"
        case .clawd: return "Clawd"
        }
    }
}

enum StatusIcon {

    private static let menubarHeight: CGFloat = 18

    // icon.png resized to 36x36 (2x for menubar)
    private static let sparkBase64 = "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"

    // clawd.png with white border removed, resized to height 36, nearest-neighbor for pixel art
    private static let clawdBase64 = "iVBORw0KGgoAAAANSUhEUgAAACwAAAAkCAYAAADy19hsAAAB3UlEQVR4nOWYS0rEQBCGv+qJL3yBoIjgVsGNZ9CFF3Ch5xBBj6DgQXThatYeZHwsBEXd+MIHOGpJSc8YM8mY0WAS/SAQOt3Vf1cqleoWkhHyRdOKqgBDqnpFjojICHALPIfbXUzf/rzFGqp6aY4jQhBtAPpsZfvry7Gv5LeY2ti2t98PmPO0nYfzjt0wLfriBBcaR8lwlIwgFLeBX0APxaHb63nx6U0DL3ZYVa99p2MKgqoeRPLylYntUtW6NdZWF5vpQ4KuT4OnN3ea97W1pUwETbexqc/1j35bu++ZS0S6Gx6OFZknEq+lUrqPzlEygrQds4rbn9osnYcdJcNRMsT/TUZV9TT8oCDl5SdEpCdo/PJEZM7XwhVVrVIARGQe6AUegSPg1AS/Ahd+O2LZeozicA6ceaea6JdGWrPi4s6HiK2oKNwA1+12HPYg19j9c1nCUTIcf7WWmArlxWiOjsuZcey3GZc276cW/BUisgDY4Ud0YvE7mr0s5slMMHAInCQIHs9qkiwFPwH1BMFP//ajc/xjwUJOjKsqnV7AZIJo+YHNiajNOA8/iMjsNxZ6n1CHqLc504mxarW6YuOiNpNO4Af9lSZkrDw1sS2n5RGbdjg90KFNq9askmzyBn/yz6+c1NcLAAAAAElFTkSuQmCC"

    /// Returns a tinted menubar icon for the given usage level.
    static func menubarIcon(style: MenubarIconStyle, color: NSColor) -> NSImage? {
        guard let baseImage = loadEmbeddedImage(style: style) else { return nil }
        let resized = resizeForMenubar(baseImage)
        switch style {
        case .spark:
            return tintedImage(resized, color: color)
        case .clawd:
            return colorBlendImage(resized, color: color)
        }
    }

    /// Returns the appropriate NSColor for a usage percentage.
    static func color(forUtilization utilization: Double) -> NSColor {
        if utilization >= 90 { return .systemRed }
        if utilization >= 70 { return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) }
        return .systemGreen
    }

    /// Load image from embedded Base64 data — no bundle/asset catalog dependency.
    private static func loadEmbeddedImage(style: MenubarIconStyle) -> NSImage? {
        let b64: String
        switch style {
        case .spark: b64 = sparkBase64
        case .clawd: b64 = clawdBase64
        }
        guard let data = Data(base64Encoded: b64),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    /// Resize image to fit menubar height, preserving aspect ratio.
    private static func resizeForMenubar(_ image: NSImage) -> NSImage {
        let originalSize = image.size
        guard originalSize.height > 0 else { return image }

        let scale = menubarHeight / originalSize.height
        let newSize = NSSize(width: round(originalSize.width * scale), height: menubarHeight)

        let resized = NSImage(size: newSize, flipped: false) { rect in
            image.draw(in: rect,
                       from: NSRect(origin: .zero, size: originalSize),
                       operation: .copy,
                       fraction: 1.0)
            return true
        }
        return resized
    }

    /// Tints a silhouette image — fills all opaque pixels with the given color.
    private static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Color-blend tint — changes hue/saturation while preserving luminance.
    /// Keeps black (eyes) dark and white (outline) light.
    private static func colorBlendImage(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let result = NSImage(size: size, flipped: false) { rect in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw original image
            ctx.draw(cgImage, in: rect)

            // Apply color blend: keeps luminance from original, takes hue+saturation from tint
            ctx.setBlendMode(.color)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)

            // Restore alpha from the original (color blend can affect transparency)
            ctx.setBlendMode(.destinationIn)
            ctx.draw(cgImage, in: rect)

            return true
        }
        return result
    }
}
