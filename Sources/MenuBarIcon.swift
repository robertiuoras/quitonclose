import AppKit

/// The QuitOnClose mark, menu bar size: a window outline with a power glyph
/// where its content would be. Same idea as the app icon, stripped to two
/// strokes so it survives 18 points.
///
/// Returned as a template image, so macOS tints it black on a light menu bar
/// and white on a dark one and dims it when the menu is open.
func makeMenuBarImage(height: CGFloat = 18) -> NSImage {
    let size = NSSize(width: height, height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        drawMenuBarMark(in: size)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "QuitOnClose"
    return image
}

/// Draws the mark into the current context, designed on an 18x18 grid and
/// scaled to whatever `size` asks for. Coordinates are y-up (AppKit default).
func drawMenuBarMark(in size: NSSize, tint: NSColor = .black) {
    let s = size.height / 18.0
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

    tint.setStroke()

    // Window frame. The path sits half a line width inside the visual bounds
    // (1.4...16.6) so the stroke does not spill off the canvas.
    let lw: CGFloat = 1.3 * s
    let frame = NSRect(x: 2.05 * s, y: 3.25 * s, width: 13.9 * s, height: 11.5 * s)
    let window = NSBezierPath(roundedRect: frame, xRadius: 1.95 * s, yRadius: 1.95 * s)
    window.lineWidth = lw
    window.stroke()

    // Title bar divider: the line that makes the rectangle read as a window.
    let divider = NSBezierPath()
    divider.move(to: p(2.05, 12.0))
    divider.line(to: p(15.95, 12.0))
    divider.lineWidth = 1.1 * s
    divider.stroke()

    // Power glyph: ring with a gap at the top, plus a stem through the gap.
    let center = p(9, 6.8)
    let ring = NSBezierPath()
    ring.appendArc(
        withCenter: center,
        radius: 2.5 * s,
        startAngle: 132,
        endAngle: 408,
        clockwise: false
    )
    ring.lineWidth = lw
    ring.lineCapStyle = .round
    ring.stroke()

    let stem = NSBezierPath()
    stem.move(to: p(9, 7.8))
    stem.line(to: p(9, 11.0))
    stem.lineWidth = lw
    stem.lineCapStyle = .round
    stem.stroke()
}
