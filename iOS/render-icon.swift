// Renders the iOS app icon: swift iOS/render-icon.swift <out.png>
// Opaque, because App Store Connect rejects an iOS icon with an alpha channel.
import AppKit

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

let gradient = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 1.00, green: 0.55, blue: 0.26, alpha: 1),
        CGColor(srgbRed: 0.91, green: 0.25, blue: 0.42, alpha: 1),
    ] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Waveform bars, drawn rather than taken from SF Symbols, which aren't
// licensed for app icons.
let heights: [CGFloat] = [0.18, 0.34, 0.56, 0.42, 0.24, 0.46, 0.30, 0.14]
let barWidth: CGFloat = 64
let gap: CGFloat = 40
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
context.setFillColor(CGColor(gray: 1, alpha: 1))
for height in heights {
    let h = height * CGFloat(size)
    let rect = CGRect(x: x, y: (CGFloat(size) - h) / 2, width: barWidth, height: h)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.fillPath()
    x += barWidth + gap
}

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
