// Generates AppIcon.iconset PNGs for LCTMac.
// Run: swift make-icon.swift && iconutil -c icns AppIcon.iconset -o LCTMac/Resources/AppIcon.icns
// Design: terminal-HUD aesthetic — dark squircle, emerald waveform, caption bars.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let emerald = CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1)
let emeraldDim = CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 0.45)
let background = CGColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1)
let dimGray = CGColor(red: 0.43, green: 0.43, blue: 0.46, alpha: 1)
let hairline = CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)

func draw(into ctx: CGContext, pixelSize: Int) {
    let s = CGFloat(pixelSize) / 1024.0
    ctx.scaleBy(x: s, y: s)

    // Apple macOS icon grid: 824x824 squircle centered in 1024 canvas
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: iconRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.addPath(squircle)
    ctx.setFillColor(background)
    ctx.fillPath()

    ctx.addPath(squircle)
    ctx.setStrokeColor(hairline)
    ctx.setLineWidth(8)
    ctx.strokePath()

    // Waveform bars (upper half)
    let barHeights: [CGFloat] = [72, 130, 200, 260, 200, 130, 72]
    let barWidth: CGFloat = 44
    let gap: CGFloat = 34
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    var x = (1024 - totalWidth) / 2
    let waveCenterY: CGFloat = 620

    ctx.setFillColor(emerald)
    for h in barHeights {
        let bar = CGRect(x: x, y: waveCenterY - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }

    // Caption bars (lower half): dim source line above bright translation line
    let lineHeight: CGFloat = 44
    let lineRadius = lineHeight / 2

    let sourceRect = CGRect(x: 252, y: 332, width: 460, height: lineHeight)
    ctx.addPath(CGPath(roundedRect: sourceRect, cornerWidth: lineRadius, cornerHeight: lineRadius, transform: nil))
    ctx.setFillColor(dimGray)
    ctx.fillPath()

    let translationRect = CGRect(x: 252, y: 244, width: 380, height: lineHeight)
    ctx.addPath(CGPath(roundedRect: translationRect, cornerWidth: lineRadius, cornerHeight: lineRadius, transform: nil))
    ctx.setFillColor(emerald)
    ctx.fillPath()

    // Streaming cursor block at the end of the translation line
    let cursorRect = CGRect(x: 664, y: 244, width: 34, height: lineHeight)
    ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.setFillColor(emeraldDim)
    ctx.fillPath()
}

func renderPNG(pixelSize: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Cannot create context") }

    draw(into: ctx, pixelSize: pixelSize)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create image destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let entries: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    renderPNG(pixelSize: entry.size, to: iconsetURL.appendingPathComponent("\(entry.name).png"))
}

print("Generated AppIcon.iconset (\(entries.count) sizes)")
