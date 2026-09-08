import AppKit

/// Hand-drawn stand-ins for Codex (OpenAI) and Grok Bot (xAI): neither has a mark this project can freely
/// redistribute (see the comment on `AppModel.vendorIcon`), so these are original geometry only loosely
/// evocative of each brand's general impression — three interlocking loops for Codex/OpenAI's "connected
/// rings" motif, a plain crossed "X" for xAI/Grok's family mark — not a trace of either company's actual
/// logo path. Drawn as opaque black shapes so `MenuBarBarImage.drawIcon`'s tint-via-sourceAtop trick applies
/// exactly as it does to the real, template-rendered vendor marks.
enum OriginalVendorIcons {
    static var codex: NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let lineWidth: CGFloat = 3.2
            let radius: CGFloat = 6.4
            let offset: CGFloat = 4.4
            NSColor.black.setStroke()
            for i in 0..<3 {
                let angle = CGFloat(i) * (2 * .pi / 3) + .pi / 2
                let loopCenter = NSPoint(x: rect.midX + cos(angle) * offset, y: rect.midY + sin(angle) * offset)
                let path = NSBezierPath(ovalIn: NSRect(x: loopCenter.x - radius, y: loopCenter.y - radius, width: radius * 2, height: radius * 2))
                path.lineWidth = lineWidth
                path.stroke()
            }
            return true
        }
    }

    static var grok: NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let inset: CGFloat = 4.5
            NSColor.black.setStroke()
            for (from, to) in [(NSPoint(x: rect.minX + inset, y: rect.minY + inset), NSPoint(x: rect.maxX - inset, y: rect.maxY - inset)),
                                (NSPoint(x: rect.minX + inset, y: rect.maxY - inset), NSPoint(x: rect.maxX - inset, y: rect.minY + inset))] {
                let path = NSBezierPath()
                path.lineWidth = 4.4
                path.lineCapStyle = .round
                path.move(to: from)
                path.line(to: to)
                path.stroke()
            }
            return true
        }
    }
}
