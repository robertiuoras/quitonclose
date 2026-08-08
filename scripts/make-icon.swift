import AppKit
import CoreGraphics

// Draws the QuitOnClose app icon and writes Assets/AppIcon.icns.
//
//   swiftc -O scripts/make-icon.swift Sources/MenuBarIcon.swift -o build/make-icon
//   ./build/make-icon                 # writes Assets/AppIcon.icns
//   ./build/make-icon --sheet         # also writes build/icon-sheet.png
//
// Everything is laid out on a 1024 grid with y pointing down, matching
// Assets/icon.svg. Keep the two in step: the website uses the SVG.

// MARK: - geometry

let canvas: CGFloat = 1024
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)   // the squircle
let window = CGRect(x: 252, y: 312, width: 520, height: 400)
let windowRadius: CGFloat = 44
let titleBarHeight: CGFloat = 76
let dotRadius: CGFloat = 13
let dotCenterY: CGFloat = 350
let dotCentersX: [CGFloat] = [296, 342, 388]

let ringCenter = CGPoint(x: 512, y: 584)
let ringRadius: CGFloat = 75
let ringWidth: CGFloat = 26
let ringGapDegrees: CGFloat = 40          // half-width of the gap at the top
let stemTopY: CGFloat = 428
let stemBottomY: CGFloat = 564

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let plateTop = rgb(0x39, 0x41, 0x4C)
let plateBottom = rgb(0x0F, 0x12, 0x17)
let titleBarFill = rgb(0xE8, 0xEC, 0xF2)
let bodyFill = rgb(0xFB, 0xFC, 0xFE)
let dividerColor = rgb(0xD6, 0xDC, 0xE6)
let dotColors = [rgb(0xFF, 0x5F, 0x57), rgb(0xFE, 0xBC, 0x2E), rgb(0x28, 0xC8, 0x40)]
let powerTop = rgb(0xFF, 0x71, 0x5F)
let powerBottom = rgb(0xE2, 0x38, 0x28)

/// Superellipse, the shape macOS app icons actually use. n = 5 is very close
/// to Apple's continuous corner; a plain rounded rect reads visibly boxier.
func squircle(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func fill(_ ctx: CGContext, _ path: CGPath, from: CGColor, to: CGColor, vertical rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [from, to] as CFArray, locations: [0, 1])!
    // y is flipped in this context, so "start" is the top edge of `rect`.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
    ctx.restoreGState()
}

/// Draws the power glyph: a ring with a gap at the top and a stem through it.
/// Every dimension is a multiple of `r`, so the small and large variants of
/// the icon stay the same drawing at two sizes. `cy` is the ring centre; the
/// stem runs upward from it.
func drawPower(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, from: CGColor, to: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: 1, y: -1)                 // local frame is y-up

    let path = CGMutablePath()
    let start = (90 + ringGapDegrees) * .pi / 180
    let end = (450 - ringGapDegrees) * .pi / 180
    path.addArc(center: .zero, radius: r, startAngle: start, endAngle: end, clockwise: false)
    path.move(to: CGPoint(x: 0, y: r * 0.267))
    path.addLine(to: CGPoint(x: 0, y: r * 2.08))

    let stroked = path.copy(
        strokingWithWidth: r * 0.347, lineCap: .round, lineJoin: .round, miterLimit: 10
    )
    let box = stroked.boundingBox
    ctx.addPath(stroked)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [from, to] as CFArray, locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: []
    )
    ctx.restoreGState()
}

/// `px` is the rendered pixel size. At 32 and below the window is 8 pixels
/// wide and the traffic lights are sub-pixel, so the mark drops to the power
/// glyph alone, filling the plate. That is the only size-dependent decision.
func drawIcon(_ ctx: CGContext, px: CGFloat) {
    ctx.saveGState()
    ctx.scaleBy(x: px / canvas, y: px / canvas)
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)                 // from here on, y points down

    let small = px <= 32
    let plateShape = squircle(in: plate)

    // Plate, with a soft drop shadow the way a real macOS icon sits on light.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 34, color: rgb(0, 0, 0, 0.34))
    ctx.addPath(plateShape)
    ctx.setFillColor(plateBottom)
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, plateShape, from: plateTop, to: plateBottom, vertical: plate)

    // Top-left sheen, so the plate is not a flat slab.
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [rgb(255, 255, 255, 0.13), rgb(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: 300, y: 240), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 240), endRadius: 620,
        options: []
    )
    ctx.restoreGState()

    // Rim light along the plate edge.
    ctx.addPath(plateShape)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    if small {
        // Glyph-only variant. Brighter red: at this size it is read against
        // the dark plate rather than against white.
        drawPower(
            ctx, cx: 512, cy: 594, r: 165,
            from: rgb(0xFF, 0x8C, 0x7A), to: rgb(0xEF, 0x44, 0x36)
        )
        ctx.restoreGState()
        return
    }

    // Window.
    let windowShape = CGPath(
        roundedRect: window, cornerWidth: windowRadius, cornerHeight: windowRadius, transform: nil
    )
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 44, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(windowShape)
    ctx.setFillColor(bodyFill)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(windowShape)
    ctx.clip()
    ctx.setFillColor(titleBarFill)
    ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: titleBarHeight))
    ctx.setFillColor(dividerColor)
    ctx.fill(CGRect(x: window.minX, y: window.minY + titleBarHeight - 3, width: window.width, height: 3))
    do {
        for (i, cx) in dotCentersX.enumerated() {
            ctx.setFillColor(dotColors[i])
            ctx.fillEllipse(in: CGRect(
                x: cx - dotRadius, y: dotCenterY - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))
        }
    }
    ctx.restoreGState()

    drawPower(ctx, cx: ringCenter.x, cy: ringCenter.y, r: ringRadius, from: powerTop, to: powerBottom)
    ctx.restoreGState()
}

// MARK: - output

func context(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

@main
struct IconMaker {
    static func main() {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let assets = root.appendingPathComponent("Assets")
    let build = root.appendingPathComponent("build")
    let iconset = build.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let px = base * scale
        let ctx = context(px)
        drawIcon(ctx, px: CGFloat(px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(ctx.makeImage()!, to: iconset.appendingPathComponent(name))
    }

    let icns = assets.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { exit(1) }
    print("wrote \(icns.path)")

    // A 1024 PNG for the README and any store listing.
    let big = context(1024)
    drawIcon(big, px: 1024)
    writePNG(big.makeImage()!, to: assets.appendingPathComponent("icon-1024.png"))
    print("wrote \(assets.path)/icon-1024.png")

    // MARK: - SVG, for the website

    // Same numbers as the bitmap path above, so toolstash.xyz/quitonclose and
    // the app icon are one mark rather than two that resemble each other.
    func squircleD(samples: Int = 168) -> String {
        var parts: [String] = []
        let a = plate.width / 2, b = plate.height / 2
        for i in 0..<samples {
            let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = plate.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 0.4)
            let y = plate.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), 0.4)
            parts.append("\(i == 0 ? "M" : "L")\(String(format: "%.1f", x)) \(String(format: "%.1f", y))")
        }
        return parts.joined(separator: " ") + " Z"
    }

    func hex(_ c: CGColor) -> String {
        let p = c.components!
        return String(format: "#%02X%02X%02X", Int(p[0] * 255), Int(p[1] * 255), Int(p[2] * 255))
    }

    func powerD(cx: CGFloat, cy: CGFloat, r: CGFloat) -> (ring: String, stem: String, width: CGFloat) {
        let rad = ringGapDegrees * .pi / 180
        let dx = r * sin(rad), dy = r * cos(rad)
        let ring = String(
            format: "M%.2f %.2f A%.2f %.2f 0 1 1 %.2f %.2f",
            cx - dx, cy - dy, r, r, cx + dx, cy - dy
        )
        let stem = String(format: "M%.2f %.2f L%.2f %.2f", cx, cy - r * 0.267, cx, cy - r * 2.08)
        return (ring, stem, r * 0.347)
    }

    func writeSVG(glyphOnly: Bool, to url: URL) {
        let p = glyphOnly
            ? powerD(cx: 512, cy: 594, r: 165)
            : powerD(cx: ringCenter.x, cy: ringCenter.y, r: ringRadius)
        let glyphTop = (glyphOnly ? 594 - 165 * 2.08 : ringCenter.y - ringRadius * 2.08) - p.width / 2
        let glyphBottom = (glyphOnly ? 594 + 165 : ringCenter.y + ringRadius) + p.width / 2
        let powerA = glyphOnly ? rgb(0xFF, 0x8C, 0x7A) : powerTop
        let powerB = glyphOnly ? rgb(0xEF, 0x44, 0x36) : powerBottom

        var s = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="QuitOnClose">
          <defs>
            <linearGradient id="plate" x1="0" y1="\(plate.minY)" x2="0" y2="\(plate.maxY)" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="\(hex(plateTop))"/><stop offset="1" stop-color="\(hex(plateBottom))"/>
            </linearGradient>
            <radialGradient id="sheen" cx="300" cy="240" r="620" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="#fff" stop-opacity="0.13"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
            </radialGradient>
            <linearGradient id="power" x1="0" y1="\(String(format: "%.1f", glyphTop))" x2="0" y2="\(String(format: "%.1f", glyphBottom))" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="\(hex(powerA))"/><stop offset="1" stop-color="\(hex(powerB))"/>
            </linearGradient>
            <clipPath id="plateClip"><path d="\(squircleD())"/></clipPath>
          </defs>
          <path d="\(squircleD())" fill="url(#plate)"/>
          <rect x="0" y="0" width="1024" height="1024" fill="url(#sheen)" clip-path="url(#plateClip)"/>
          <path d="\(squircleD())" fill="none" stroke="#fff" stroke-opacity="0.12" stroke-width="4"/>

        """
        if !glyphOnly {
            let w = window
            s += """
              <g>
                <rect x="\(w.minX)" y="\(w.minY)" width="\(w.width)" height="\(w.height)" rx="\(windowRadius)" fill="\(hex(bodyFill))"/>
                <clipPath id="win"><rect x="\(w.minX)" y="\(w.minY)" width="\(w.width)" height="\(w.height)" rx="\(windowRadius)"/></clipPath>
                <g clip-path="url(#win)">
                  <rect x="\(w.minX)" y="\(w.minY)" width="\(w.width)" height="\(titleBarHeight)" fill="\(hex(titleBarFill))"/>
                  <rect x="\(w.minX)" y="\(w.minY + titleBarHeight - 3)" width="\(w.width)" height="3" fill="\(hex(dividerColor))"/>
                  <circle cx="\(dotCentersX[0])" cy="\(dotCenterY)" r="\(dotRadius)" fill="\(hex(dotColors[0]))"/>
                  <circle cx="\(dotCentersX[1])" cy="\(dotCenterY)" r="\(dotRadius)" fill="\(hex(dotColors[1]))"/>
                  <circle cx="\(dotCentersX[2])" cy="\(dotCenterY)" r="\(dotRadius)" fill="\(hex(dotColors[2]))"/>
                </g>
              </g>

            """
        }
        s += """
          <g fill="none" stroke="url(#power)" stroke-width="\(String(format: "%.2f", p.width))" stroke-linecap="round">
            <path d="\(p.ring)"/>
            <path d="\(p.stem)"/>
          </g>
        </svg>

        """
        try! s.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    }

    writeSVG(glyphOnly: false, to: assets.appendingPathComponent("icon.svg"))
    writeSVG(glyphOnly: true, to: assets.appendingPathComponent("mark.svg"))

    // MARK: - contact sheet (visual check across the sizes that matter)

    if CommandLine.arguments.contains("--sheet") {
        let sizes = [16, 32, 64, 128, 256]
        let width = 1000, height = 420
        let sheet = context(width)   // square context, cropped by the writer below
        sheet.setFillColor(rgb(0xBF, 0xC5, 0xCC))
        sheet.fill(CGRect(x: 0, y: 0, width: width, height: width))

        var x: CGFloat = 24
        let baseline: CGFloat = CGFloat(width) - 30
        for px in sizes {
            sheet.saveGState()
            sheet.translateBy(x: x, y: baseline - CGFloat(px))
            drawIcon(sheet, px: CGFloat(px))
            sheet.restoreGState()
            x += CGFloat(px) + 28
        }

        // Menu bar mark, light strip then dark strip.
        let stripY = baseline - 380
        sheet.setFillColor(rgb(0xF2, 0xF2, 0xF4))
        sheet.fill(CGRect(x: 24, y: stripY, width: 440, height: 90))
        sheet.setFillColor(rgb(0x22, 0x24, 0x28))
        sheet.fill(CGRect(x: 490, y: stripY, width: 440, height: 90))

        let ns = NSGraphicsContext(cgContext: sheet, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for (originX, tint) in [(CGFloat(60), NSColor.black), (CGFloat(526), NSColor.white)] {
            for (i, h) in [CGFloat(18), 36, 72].enumerated() {
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: originX + CGFloat(i) * 110, yBy: stripY + 10)
                shift.concat()
                drawMenuBarMark(in: NSSize(width: h, height: h), tint: tint)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // CGImage crops from the top-left, and the drawing sits at the top of
        // the square context, so the crop starts at y = 0.
        let cropped = sheet.makeImage()!.cropping(to: CGRect(
            x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)
        ))!
        writePNG(cropped, to: build.appendingPathComponent("icon-sheet.png"))
        print("wrote \(build.path)/icon-sheet.png")
    }
    }
}
