import AppKit

/// A vendor mark for one bar. `isTemplate` marks that `image` is a colourless alpha shape to be tinted;
/// `false` is a real, full-colour icon (e.g. an installed app's own `.icns`) drawn as-is.
struct MenuBarVendorMark {
    let image: NSImage
    let isTemplate: Bool
}

/// Renders the Headroom/CodexBar-style menu bar glyph: 1–4 chubby capsule pills — a stroked outline track,
/// filled bottom-up by percent — with an optional tiny vendor mark ahead of each pill and the percent either
/// baked in beside each pill or as tiny text inside it. Everything (every pill, mark, number, the stale dot)
/// is one composed `NSImage`: `MenuBarExtra`'s label only reliably renders a single Image plus a single Text
/// (see the label-limitation comment on `MenuBarLabel`), so a second sibling `Image` for a second bar was
/// silently dropped — baking the whole thing into one image sidesteps that. Bars use a fixed, vivid palette
/// (not the app's dynamic `usageTint`) so the image reads correctly on both light and dark menu bars without
/// re-rendering on appearance changes; vendor marks are drawn as template shapes tinted the same way.
enum MenuBarBarImage {
    private static let height: CGFloat = 16
    private static let strokeWidth: CGFloat = 1.3
    private static let fillInset: CGFloat = 2.8
    private static let barGap: CGFloat = 5
    private static let besideTextGap: CGFloat = 3
    private static let iconSize: CGFloat = 11
    private static let iconGap: CGFloat = 3
    private static var besideFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
    private static var insideFont: NSFont { .monospacedDigitSystemFont(ofSize: 6.5, weight: .bold) }

    static func render(percents: [Double?], icons: [MenuBarVendorMark?] = [], shortWindow: [Bool] = [], placement: MenuBarPercentPlacement?, isStale: Bool = false) -> NSImage {
        let bars = percents.isEmpty ? [nil] : percents
        let icons = icons.count == bars.count ? icons : Array(repeating: nil, count: bars.count)
        let shortWindow = shortWindow.count == bars.count ? shortWindow : Array(repeating: false, count: bars.count)
        // Inside placement drops the "%" (just "72") to fit the tiny type; beside has room to spell it out.
        let barWidth = height * (placement == .inside ? 0.85 : 0.6)
        let texts = bars.map { percent -> String? in
            guard let placement, let percent else { return nil }
            return placement == .inside ? "\(Int(percent.rounded()))" : "\(Int(percent.rounded()))%"
        }
        let besideWidths = texts.map { placement == .beside ? ($0.map { ($0 as NSString).size(withAttributes: [.font: besideFont]).width } ?? 0) : 0 }
        let slotWidths = zip(besideWidths, icons).map { textWidth, icon in
            barWidth + (textWidth > 0 ? besideTextGap + textWidth : 0) + (icon != nil ? iconSize + iconGap : 0)
        }
        let dotSpace: CGFloat = isStale ? 7 : 0
        let width = slotWidths.reduce(0, +) + CGFloat(max(0, bars.count - 1)) * barGap + dotSpace
        let image = NSImage(size: NSSize(width: max(width, barWidth), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, percent) in bars.enumerated() {
                if let icon = icons[index] {
                    // Template marks are colourless (the bar's own fill carries the colour); a real app icon
                    // is drawn full-colour, as-is. Drawn smaller for a session/5h window so a same-provider
                    // pair (e.g. Claude 5h + Claude weekly) doesn't show two identical-looking marks.
                    drawIcon(icon.image, x: x, tint: icon.isTemplate ? .labelColor : nil, scale: shortWindow[index] ? 0.7 : 1)
                    x += iconSize + iconGap
                }
                drawBar(percent: percent, x: x, width: barWidth, insideText: placement == .inside ? texts[index] : nil)
                x += barWidth
                if placement == .beside, let text = texts[index] {
                    let attrs: [NSAttributedString.Key: Any] = [.font: besideFont, .foregroundColor: nsColor(for: percent ?? 0)]
                    let size = (text as NSString).size(withAttributes: attrs)
                    (text as NSString).draw(at: NSPoint(x: x + besideTextGap, y: (height - size.height) / 2), withAttributes: attrs)
                    x += besideTextGap + size.width
                }
                x += barGap
            }
            if isStale {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: height - 6, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws `icon` at `scale` within its reserved slot (so bar/text spacing doesn't shift), centred. A
    /// template (alpha-mask) icon gets tinted by drawing it then painting `tint` over the shape it left
    /// behind; `tint == nil` draws a real, full-colour icon as-is.
    private static func drawIcon(_ icon: NSImage, x: CGFloat, tint: NSColor?, scale: CGFloat = 1) {
        let size = iconSize * scale
        let rect = NSRect(x: x + (iconSize - size) / 2, y: (height - size) / 2, width: size, height: size)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        guard let tint else { return }
        tint.setFill()
        rect.fill(using: .sourceAtop)
    }

    private static func drawBar(percent: Double?, x: CGFloat, width: CGFloat, insideText: String?) {
        let track = NSRect(x: x + strokeWidth / 2, y: strokeWidth / 2, width: width - strokeWidth, height: height - strokeWidth)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: track.width / 2, yRadius: track.width / 2)
        trackPath.lineWidth = strokeWidth
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        trackPath.stroke()
        if let percent, percent > 0 {
            let fillRect = NSRect(x: x + fillInset, y: fillInset, width: width - fillInset * 2, height: height - fillInset * 2)
            let fillHeight = fillRect.height * min(100, max(0, percent)) / 100
            if fillRect.width > 0, fillHeight > 0 {
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRect.width / 2, yRadius: fillRect.width / 2)
                NSGraphicsContext.saveGraphicsState()
                fillPath.addClip()
                NSBezierPath(rect: NSRect(x: fillRect.minX, y: fillRect.minY, width: fillRect.width, height: fillHeight)).addClip()
                nsColor(for: percent).setFill()
                NSBezierPath(rect: fillRect).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let insideText else { return }
        // White with a dark stroke so the number stays legible over both the coloured fill and the bare track.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: insideFont, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.65), .strokeWidth: -3.0,
        ]
        let size = (insideText as NSString).size(withAttributes: attrs)
        (insideText as NSString).draw(at: NSPoint(x: x + (width - size.width) / 2, y: (height - size.height) / 2), withAttributes: attrs)
    }

    /// Same thresholds as `usageTint`, using the dark-mode (more vivid) values that read on both appearances.
    private static func nsColor(for percent: Double) -> NSColor {
        switch percent {
        case ..<50: NSColor(red: 0.30, green: 0.78, blue: 0.47, alpha: 1)
        case ..<80: NSColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 1)
        default: NSColor(red: 0.96, green: 0.36, blue: 0.34, alpha: 1)
        }
    }
}
