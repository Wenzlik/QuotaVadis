import AppKit

/// A vendor mark for one bar. `isTemplate` marks that `image` is a colourless alpha shape to be tinted;
/// `false` is a real, full-colour icon (e.g. an installed app's own `.icns`) drawn as-is.
struct MenuBarVendorMark {
    let image: NSImage
    let isTemplate: Bool
}

/// Renders the menu bar glyph ("Direction A"): 1–4 round 18 pt badges with a stable charcoal centre, the percent
/// as white digits inside (or beside), and usage carried by a coloured proportional arc on the rim — colour never
/// sits under the digits, so they keep the same contrast at every percentage. An optional monochrome vendor mark
/// sits ahead of each badge. Everything (every badge, mark, number, the stale dot) is one composed `NSImage`:
/// `MenuBarExtra`'s label only reliably renders a single Image plus a single Text (see the label-limitation
/// comment on `MenuBarLabel`), so a second sibling `Image` for a second bar was silently dropped — baking the
/// whole thing into one image sidesteps that. The image is non-template: the opaque centres provide their own
/// digit contrast on any wallpaper, and the rim uses a fixed palette (same thresholds as `usageTint`).
/// `.classic` keeps the 0.5.6 look instead: 16 pt stroked capsule pills filled bottom-up, tiny outlined digits.
enum MenuBarBarImage {
    private static let discSize: CGFloat = 18
    private static let rimWidth: CGFloat = 2
    private static let classicHeight: CGFloat = 16
    private static let strokeWidth: CGFloat = 1.3
    private static let fillInset: CGFloat = 2.8
    private static let barGap: CGFloat = 5
    private static let besideTextGap: CGFloat = 3
    private static let iconGap: CGFloat = 3
    private static let charcoal = NSColor(red: 0x20 / 255, green: 0x24 / 255, blue: 0x2A / 255, alpha: 1)
    private static var besideFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
    private static var insideFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .semibold) }
    private static var classicInsideFont: NSFont { .monospacedDigitSystemFont(ofSize: 6.5, weight: .bold) }

    static func render(percents: [Double?], icons: [MenuBarVendorMark?] = [], shortWindow: [Bool] = [], placement: MenuBarPercentPlacement?, isStale: Bool = false, style: MenuBarBadgeStyle = .circular) -> NSImage {
        let circular = style == .circular
        let height = circular ? discSize : classicHeight
        let iconSize: CGFloat = circular ? 12 : 11
        // Classic pills widen for inside text; circular badges are always a fixed disc.
        let slot = circular ? discSize : height * (placement == .inside ? 0.85 : 0.6)
        let bars = percents.isEmpty ? [nil] : percents
        let icons = icons.count == bars.count ? icons : Array(repeating: nil, count: bars.count)
        let shortWindow = shortWindow.count == bars.count ? shortWindow : Array(repeating: false, count: bars.count)
        // Inside placement drops the "%" (just "72"); beside has room to spell it out. Missing data inside a
        // circular badge shows an en dash so it never reads as 0 (a classic pill is just left empty).
        let texts = bars.map { percent -> String? in
            guard let placement else { return nil }
            guard let percent else { return placement == .inside && circular ? "–" : nil }
            return placement == .inside ? "\(Int(percent.rounded()))" : "\(Int(percent.rounded()))%"
        }
        let besideWidths = texts.map { placement == .beside ? ($0.map { ($0 as NSString).size(withAttributes: [.font: besideFont]).width } ?? 0) : 0 }
        let slotWidths = zip(besideWidths, icons).map { textWidth, icon in
            slot + (textWidth > 0 ? besideTextGap + textWidth : 0) + (icon != nil ? iconSize + iconGap : 0)
        }
        let dotSpace: CGFloat = isStale ? 7 : 0
        let width = slotWidths.reduce(0, +) + CGFloat(max(0, bars.count - 1)) * barGap + dotSpace
        let image = NSImage(size: NSSize(width: max(width, slot), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, percent) in bars.enumerated() {
                if let icon = icons[index] {
                    // Template marks are monochrome (the rim carries the colour); a real app icon is drawn
                    // full-colour, as-is. Drawn smaller for a session/5h window so a same-provider pair
                    // (e.g. Claude 5h + Claude weekly) doesn't show two identical-looking marks.
                    drawIcon(icon.image, x: x, size: iconSize, height: height, tint: icon.isTemplate ? .labelColor : nil,
                             bold: circular, scale: shortWindow[index] ? (circular ? 0.75 : 0.7) : 1)
                    x += iconSize + iconGap
                }
                let insideText = placement == .inside ? texts[index] : nil
                if circular {
                    drawBadge(percent: percent, x: x, insideText: insideText)
                } else {
                    drawPill(percent: percent, x: x, width: slot, height: height, insideText: insideText)
                }
                x += slot
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
                // The loop left a trailing barGap; sit the dot inside the reserved dotSpace instead of past the edge.
                NSBezierPath(ovalIn: NSRect(x: x - barGap + 2, y: height - 6, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws `icon` at `scale` within its reserved slot (so badge/text spacing doesn't shift), centred. A
    /// template (alpha-mask) icon is tinted by painting `tint` over the shape it left behind — when `bold`, it is
    /// first drawn a second time a hair to each side for optical weight; `tint == nil` draws a real, full-colour
    /// icon as-is.
    private static func drawIcon(_ icon: NSImage, x: CGFloat, size slotSize: CGFloat, height: CGFloat, tint: NSColor?, bold: Bool, scale: CGFloat = 1) {
        let size = slotSize * scale
        let rect = NSRect(x: x + (slotSize - size) / 2, y: (height - size) / 2, width: size, height: size)
        guard let tint else {
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        for dx: CGFloat in bold ? [-0.25, 0, 0.25] : [0] {
            icon.draw(in: rect.offsetBy(dx: dx, dy: 0), from: .zero, operation: .sourceOver, fraction: 1)
        }
        tint.setFill()
        rect.insetBy(dx: -1, dy: 0).fill(using: .sourceAtop)
    }

    private static func drawBadge(percent: Double?, x: CGFloat, insideText: String?) {
        let disc = NSRect(x: x, y: 0, width: discSize, height: discSize)
        charcoal.setFill()
        NSBezierPath(ovalIn: disc).fill()
        // Rim: faint full ring (keeps the badge outlined on dark bars), then the usage arc clockwise from 12 o'clock.
        let ring = disc.insetBy(dx: rimWidth / 2, dy: rimWidth / 2)
        let center = NSPoint(x: ring.midX, y: ring.midY)
        let ringPath = NSBezierPath(ovalIn: ring)
        ringPath.lineWidth = rimWidth
        NSColor.white.withAlphaComponent(0.22).setStroke()
        ringPath.stroke()
        if let percent, percent > 0 {
            // Floor at 4% of the circle so 1–3% still shows a visible tick instead of a sub-pixel sliver.
            let sweep = 360 * max(0.04, min(100, percent) / 100)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: ring.width / 2, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = rimWidth
            arc.lineCapStyle = sweep < 360 ? .round : .butt
            nsColor(for: percent).setStroke()
            arc.stroke()
        }
        guard let insideText else { return }
        // Shrink only when the text (i.e. "100") would overrun the charcoal centre.
        let room = discSize - rimWidth * 2 - 1
        var font = insideFont
        let natural = (insideText as NSString).size(withAttributes: [.font: font]).width
        if natural > room { font = .monospacedDigitSystemFont(ofSize: font.pointSize * room / natural, weight: .semibold) }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (insideText as NSString).size(withAttributes: attrs)
        (insideText as NSString).draw(at: NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2), withAttributes: attrs)
    }

    /// The 0.5.6 pill: a stroked capsule track filled bottom-up in the usage colour, digits outlined in black.
    private static func drawPill(percent: Double?, x: CGFloat, width: CGFloat, height: CGFloat, insideText: String?) {
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
            .font: classicInsideFont, .foregroundColor: NSColor.white,
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
