import AppKit

/// The app's icon, drawn in code rather than shipped as artwork.
///
/// Lives in its own file because two very different things need it and must not drift
/// apart: the running app (its About panel, its alerts, the Dock icon the menu-bar
/// placement fallback puts up) and `build-app.sh`, which compiles this file into a small
/// generator to bake `AnywayConnect.icns` into the bundle. Finder and the Dock's own slot
/// read the bundle rather than anything set at runtime, so the icon file is the only way
/// the app stops looking blank there — and one drawing serves both.
///
/// The mark is the same pairing as the menu bar icon: a globe, with a padlock badge.
enum AppIcon {
    /// Share of the canvas the rounded plate occupies, Apple's proportion; the rest is the
    /// transparent margin the Dock expects an icon to leave around itself.
    static let plateShare: CGFloat = 0.8047

    private static let deepBlue = NSColor(srgbRed: 0.13, green: 0.26, blue: 0.75, alpha: 1)
    private static let lightBlue = NSColor(srgbRed: 0.35, green: 0.60, blue: 1.00, alpha: 1)

    /// Below this the badge is dropped: at 32px it renders as roughly nine pixels holding a
    /// five-pixel padlock, which reads as dirt rather than as a lock. Simplifying instead of
    /// shrinking is what Apple's own icons do at the small end.
    private static let badgeFloor: CGFloat = 64

    // MARK: - Runtime images

    /// The icon for use in the running app.
    ///
    /// A drawing handler, not a raster, so AppKit re-renders it at whatever scale is asked
    /// for and it stays sharp from a 16pt menu row to a 128pt Dock tile.
    static let standard: NSImage = image(side: 512)

    static func image(side: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(side: side)
            return true
        }
        out.accessibilityDescription = "AnywayConnect"
        return out
    }

    // MARK: - The drawing itself

    /// Draws the icon into the current graphics context at `side` points square.
    ///
    /// Split out from any particular image so the generator can rasterise it at exact pixel
    /// sizes, which `NSImage.lockFocus` cannot promise — it adopts the deepest screen's
    /// scale, so on a Retina display it would quietly produce double-size reps and the
    /// iconset entries would all be wrong.
    static func draw(side: CGFloat) {
        NSGraphicsContext.current?.imageInterpolation = .high

        // Apple's proportions: the rounded square covers about four fifths of the canvas,
        // and its corner radius is a little over a fifth of its own side.
        let margin = (1 - plateShare) / 2
        let plate = NSRect(x: side * margin, y: side * margin,
                           width: side * plateShare, height: side * plateShare)
        let radius = plate.width * 0.2237
        let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
        NSGradient(colors: [lightBlue, deepBlue])?.draw(in: shape, angle: -90)

        // Everything after this is confined to the plate, so no glyph can break the rounded
        // silhouette. Belt as well as braces: the badge is also positioned to sit inside the
        // corner arc, but clipping means a later tweak to either cannot leak white into the
        // transparent margin — which is what the first draft did.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        shape.setClip()

        let badgeSide = plate.width * 0.34
        let wantsBadge = side >= badgeFloor

        // Placed by measured ink, so the padding SF Symbols carry cannot shift it off
        // centre — the same measurement the menu bar icon depends on. Without the badge the
        // globe can sit a touch larger, since nothing is overlapping it.
        if let globe = tintedSymbol("globe", pointSize: plate.width * 0.62,
                                    weight: .light, color: .white),
           let ink = inkBounds(of: globe, scale: 2) {
            drawByInk(globe, ink: ink, targetSide: plate.width * (wantsBadge ? 0.54 : 0.62),
                      centeredOn: NSPoint(x: plate.midX, y: plate.midY))
        }

        guard wantsBadge else { return }

        // The disc is composed here rather than using lock.circle.fill, for the same reason
        // the menu bar badge does: the stock symbol gives its padlock only about half the
        // disc, which is too small to read.
        //
        // Inset far enough to clear the corner arc, not just the straight edges: the corner
        // radius is 22.4% of the plate, so a disc tucked into the corner has to sit further
        // in than the edges alone would suggest.
        let badgeCenter = NSPoint(x: plate.maxX - badgeSide * 0.72,
                                  y: plate.minY + badgeSide * 0.72)
        let disc = NSRect(x: badgeCenter.x - badgeSide / 2, y: badgeCenter.y - badgeSide / 2,
                          width: badgeSide, height: badgeSide)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: disc).fill()
        if let lock = tintedSymbol("lock.fill", pointSize: badgeSide,
                                   weight: .bold, color: deepBlue),
           let ink = inkBounds(of: lock, scale: 4) {
            drawByInk(lock, ink: ink, targetSide: badgeSide * 0.56, centeredOn: badgeCenter)
        }
    }

    /// An SF Symbol in a solid colour. Symbols ship as template images and draw black
    /// otherwise; `.sourceAtop` keeps the glyph's alpha and replaces only its colour.
    static func tintedSymbol(_ name: String, pointSize: CGFloat,
                             weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let box = NSRect(origin: .zero, size: base.size)
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: box)
        color.set()
        box.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// Draw `image` so its *ink* — not its padded box — is `targetSide` at the longest and
    /// centred on `centeredOn`.
    static func drawByInk(_ image: NSImage, ink: NSRect,
                          targetSide: CGFloat, centeredOn c: NSPoint) {
        let scale = targetSide / max(ink.width, ink.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = NSPoint(x: c.x - ink.midX * scale, y: c.y - ink.midY * scale)
        image.draw(in: NSRect(origin: origin, size: size))
    }

    /// Bounding box of an image's non-transparent pixels, in points.
    ///
    /// The scale sets the measuring resolution, and that resolution becomes the placement
    /// error for anything positioned by the result: at 4x the grid is 0.25pt, which left the
    /// menu bar globe's ink 0.06pt off a whole point and its lock 0.09pt off centre.
    static func inkBounds(of image: NSImage, scale: CGFloat = 16) -> NSRect? {
        let w = Int((image.size.width * scale).rounded())
        let h = Int((image.size.height * scale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        let stride = rep.bytesPerRow
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * stride + x * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run top-down; flip into AppKit's bottom-up image coordinates.
        return NSRect(x: CGFloat(minX) / scale,
                      y: (CGFloat(h) - CGFloat(maxY + 1)) / scale,
                      width: CGFloat(maxX + 1 - minX) / scale,
                      height: CGFloat(maxY + 1 - minY) / scale)
    }

    // MARK: - Build-time output

    /// The sizes `iconutil` expects, with the filenames it matches on.
    static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16),     ("icon_16x16@2x", 32),
        ("icon_32x32", 32),     ("icon_32x32@2x", 64),
        ("icon_128x128", 128),  ("icon_128x128@2x", 256),
        ("icon_256x256", 256),  ("icon_256x256@2x", 512),
        ("icon_512x512", 512),  ("icon_512x512@2x", 1024),
    ]

    /// PNG of the icon at an exact pixel size.
    ///
    /// Rendered into a bitmap of that many pixels declared as the same number of *points*,
    /// which pins the scale at 1:1. Going through `NSImage.lockFocus` instead would inherit
    /// the screen's scale and silently double every size.
    static func pngData(pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32) else {
            throw Failure("could not allocate a \(pixels)x\(pixels) bitmap")
        }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure("could not encode the \(pixels)x\(pixels) PNG")
        }
        return png
    }

    /// Fills an `.iconset` directory ready for `iconutil -c icns`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in iconsetEntries {
            let data = try pngData(pixels: entry.pixels)
            try data.write(to: dir.appendingPathComponent("\(entry.name).png"))
        }
    }

    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}
