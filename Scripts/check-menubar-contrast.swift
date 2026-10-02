// Run: swiftc Apps/Mac/Sources/MenuBarBarImage.swift Scripts/check-menubar-contrast.swift -o /tmp/qv-contrast-check
// Then: /tmp/qv-contrast-check /tmp/qv-menubar-contrast.png
import AppKit

// The renderer only needs these two cases from AppModel; avoid launching the app or reading accounts.
enum MenuBarPercentPlacement { case beside, inside }

@main
struct ContrastCheck {
    static func main() throws {
        let percents: [Double?] = [0, 24, 66, 72, 95, 100, nil]
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 256,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let scale = AffineTransform(scale: 4)
        (scale as NSAffineTransform).concat()
        for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                (row == 0 ? NSColor.white : NSColor.darkGray).setFill()
                NSRect(x: 0, y: CGFloat(row * 32), width: 140, height: 32).fill()
                let image = MenuBarBarImage.render(percents: percents, placement: .inside)
                assert(abs(image.size.width - 125.2) < 0.01 && image.size.height == 16, "Capsule layout changed")
                image.draw(at: NSPoint(x: 7, y: CGFloat(row * 32 + 8)), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Every number must contain both white ink and black backing, independent of fill/appearance.
        for row in 0..<2 {
            for column in 0..<6 {
                let x = Int((7 + Double(column) * 18.6) * 4)
                var white = 0, black = 0
                for px in (x + 8)..<(x + 46) {
                    for py in (row * 128 + 40)..<(row * 128 + 88) {
                        let color = bitmap.colorAt(x: px, y: py)!.usingColorSpace(.deviceRGB)!
                        if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9 { white += 1 }
                        if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.1 { black += 1 }
                    }
                }
                assert(white > 5 && black > 5, "Missing contrasting digits/backing at \(percents[column]!) in row \(row)")
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Contrast and layout checks passed (0, 24, 66, 72, 95, 100; light and dark).")
    }
}
