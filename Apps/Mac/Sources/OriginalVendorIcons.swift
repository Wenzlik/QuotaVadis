import AppKit

/// Hand-drawn stand-in for Grok Bot (xAI) when the "Grok Bot" app isn't installed locally.
/// Claude/Cursor/Codex now ship real brand marks in the asset catalog; this file only covers Grok.
enum OriginalVendorIcons {
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
