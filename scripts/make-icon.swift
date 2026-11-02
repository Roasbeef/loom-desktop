// Renders the app icon: strands crossing on a dark squircle, a literal loom weave.
//
//   swift scripts/make-icon.swift App/Loom.icns
//
// The output is committed, so a build does not need to run this.
import AppKit

func render(size: CGFloat) -> Data {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // The system's icon grid: an 824 unit body inside a 1024 canvas.
    let unit = size / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGradient(colors: [
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // Four warp threads and four weft threads, passing over and under in turn.
    context.saveGState()
    squircle.addClip()
    let thread = 58 * unit
    let positions: [CGFloat] = [302, 442, 582, 722].map { $0 * unit }
    let warp = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)
    let weft = NSColor(srgbRed: 0.95, green: 0.64, blue: 0.24, alpha: 1)

    func bar(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: thread / 2, yRadius: thread / 2).fill()
    }

    let span0 = 214 * unit
    let spanLength = 596 * unit
    for x in positions {
        bar(CGRect(x: x - thread / 2, y: span0, width: thread, height: spanLength), warp)
    }
    for y in positions {
        bar(CGRect(x: span0, y: y - thread / 2, width: spanLength, height: thread), weft)
    }

    // Where a warp passes over, redraw it with a gap so the over and under reads.
    let gap = 12 * unit
    for (row, y) in positions.enumerated() {
        for (column, x) in positions.enumerated() where (row + column) % 2 == 0 {
            NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1).setFill()
            CGRect(x: x - thread / 2 - gap, y: y - thread / 2, width: thread + 2 * gap, height: thread).fill()
            warp.setFill()
            CGRect(x: x - thread / 2, y: y - thread / 2 - 1, width: thread, height: thread + 2).fill()
        }
    }
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Loom-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: CGFloat(base)).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: CGFloat(base * 2)).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", set.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try FileManager.default.removeItem(at: set)
