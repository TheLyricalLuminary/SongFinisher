// Renders the SongFinisher app icon: sound (waveform bars) becoming words (lyric lines).
// Deterministic — no randomness — so the icon is reproducible from this script.
import AppKit

let S = 1024
let ctx = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

// Background: deep indigo diagonal gradient, subtle radial glow behind the composition.
let bgGradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgb(0x17112E), rgb(0x33195E)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: CGFloat(S)), end: CGPoint(x: CGFloat(S), y: 0), options: [])

let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [rgb(0x6B3FA8, 0.55), rgb(0x6B3FA8, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 540), endRadius: 620, options: []
)

func bar(x: CGFloat, midY: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
    let rect = CGRect(x: x, y: midY - height / 2, width: width, height: height)
    let path = CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

// Left: five waveform bars (white), heights shaped like a melody's rise and fall.
// Group is centered: bars (480) + gap (64) + longest line (250) = 794 → 115 margins.
let midY: CGFloat = 512
let barW: CGFloat = 64
let barGap: CGFloat = 40
let heights: [CGFloat] = [260, 470, 700, 530, 330]
var x: CGFloat = 115
for h in heights {
    bar(x: x, midY: midY, width: barW, height: h, color: rgb(0xFFFFFF, 0.96))
    x += barW + barGap
}

// Right: three lyric lines (yellow — the DSP diagnostic's accent, now the brand accent).
// Strongly staggered widths so it reads as ragged text, not a menu/"E" glyph.
let lineH: CGFloat = 64
let lineGap: CGFloat = 96
let lineX: CGFloat = x + 24
let lineWidths: [CGFloat] = [250, 160, 205]
let lineYs: [CGFloat] = [midY + lineGap + lineH, midY, midY - lineGap - lineH]
for (w, y) in zip(lineWidths, lineYs) {
    let rect = CGRect(x: lineX, y: y - lineH / 2, width: w, height: lineH)
    let path = CGPath(roundedRect: rect, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0xE8E33B))
    ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
