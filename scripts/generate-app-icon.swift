#!/usr/bin/env swift
import AppKit

// Brand colors
let navy = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x2e/255.0, alpha: 1.0)
let green = NSColor(red: 0x00/255.0, green: 0xff/255.0, blue: 0x88/255.0, alpha: 1.0)

let outputDir = "/Users/jmdb/Code/github/ubiqtek/tilr/Sources/Tilr/Assets.xcassets/AppIcon.appiconset"

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_32x32.png", 32),
    ("icon_64x64.png", 64),
    ("icon_128x128.png", 128),
    ("icon_256x256.png", 256),
    ("icon_512x512.png", 512),
    ("icon_1024x1024.png", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Squircle: corner radius ~22.37% of side
    let squircleRadius = size * 0.2237
    let squirclePath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                              cornerWidth: squircleRadius,
                              cornerHeight: squircleRadius,
                              transform: nil)

    // Clip to squircle and fill navy background
    ctx.addPath(squirclePath)
    ctx.clip()

    ctx.setFillColor(navy.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // Inner area: 70% of canvas, 15% margin each side
    let margin = size * 0.15
    let innerWidth = size - 2 * margin
    let innerHeight = size - 2 * margin

    // Split: left ~60%, gap ~2%, right ~38% of inner width
    let gapFraction: CGFloat = 0.02
    let leftFraction: CGFloat = 0.60
    let gap = innerWidth * gapFraction
    let leftWidth = innerWidth * leftFraction - gap / 2
    let rightWidth = innerWidth - leftWidth - gap

    let leftX = margin
    let rightX = margin + leftWidth + gap

    // Tile corner radius ~8% of tile width
    let leftRadius = leftWidth * 0.08
    let rightRadius = rightWidth * 0.08

    ctx.setFillColor(green.cgColor)

    // Left (main) tile
    let leftRect = CGRect(x: leftX, y: margin, width: leftWidth, height: innerHeight)
    let leftPath = CGPath(roundedRect: leftRect,
                          cornerWidth: leftRadius,
                          cornerHeight: leftRadius,
                          transform: nil)
    ctx.addPath(leftPath)
    ctx.fillPath()

    // Right (sidebar) tile
    let rightRect = CGRect(x: rightX, y: margin, width: rightWidth, height: innerHeight)
    let rightPath = CGPath(roundedRect: rightRect,
                           cornerWidth: rightRadius,
                           cornerHeight: rightRadius,
                           transform: nil)
    ctx.addPath(rightPath)
    ctx.fillPath()

    image.unlockFocus()
    return image
}

func writePNG(image: NSImage, to path: String) {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("ERROR: could not get CGImage for \(path)")
        return
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("ERROR: could not create PNG data for \(path)")
        return
    }
    let url = URL(fileURLWithPath: path)
    do {
        try data.write(to: url)
        print("Wrote \(path) (\(data.count) bytes)")
    } catch {
        print("ERROR writing \(path): \(error)")
    }
}

// Render at 1024 then scale down for smaller sizes
let master = drawIcon(size: 1024)

for (filename, px) in sizes {
    let path = "\(outputDir)/\(filename)"
    if px == 1024 {
        writePNG(image: master, to: path)
    } else {
        // Scale master into target size with high interpolation
        let scaled = NSImage(size: NSSize(width: px, height: px))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                    from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                    operation: .copy,
                    fraction: 1.0)
        scaled.unlockFocus()
        writePNG(image: scaled, to: path)
    }
}

print("Done.")
