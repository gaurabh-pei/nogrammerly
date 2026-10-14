// Generates installer artwork from Assets/Nogrammerly-icon.png.
//   swift script/make_artwork.swift icon <source.png> <out.png>             macOS-style icon: transparent corners, standard padding, shadow
//   swift script/make_artwork.swift background <out@1x> <out@2x>             DMG window background with install steps (660×580)
import AppKit

func render(width: Int, height: Int, scale: CGFloat = 1, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(CGFloat(width) * scale), pixelsHigh: Int(CGFloat(height) * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func makeIcon(source: String, output: String) {
    let art = NSImage(contentsOfFile: source)!
    // Apple's macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    save(render(width: 1024, height: 1024) { context in
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.setFill(); shape.fill()
        context.restoreGState()
        shape.addClip()
        // The source fills its canvas edge to edge; overscan slightly so its own outer edge and dark corners are cut off.
        art.draw(in: body.insetBy(dx: -18, dy: -18))
    }, output)
}

func makeBackground(output1x: String, output2x: String) {
    let width = 660, height = 580
    for (scale, path) in [(CGFloat(1), output1x), (CGFloat(2), output2x)] {
        save(render(width: width, height: height, scale: scale) { context in
            let gradient = NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.96, blue: 1.0, alpha: 1), ending: NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.99, alpha: 1))!
            gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

            let indigo = NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.90, alpha: 1)
            let center = NSMutableParagraphStyle(); center.alignment = .center
            NSAttributedString(string: "Install Nogrammerly", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1), .paragraphStyle: center])
                .draw(in: NSRect(x: 0, y: height - 62, width: width, height: 32))
            NSAttributedString(string: "Drag the app onto the Applications folder", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1), .paragraphStyle: center])
                .draw(in: NSRect(x: 0, y: height - 88, width: width, height: 20))

            // Arrow between the two icon slots. Finder positions (from the top): app (170, 165), Applications (490, 165), Read Me (330, 395).
            // The layout keeps everything in the top ~470pt so it fits even when Finder shows its toolbar and path bar.
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 262, y: 415)); arrow.line(to: NSPoint(x: 392, y: 415))
            arrow.move(to: NSPoint(x: 376, y: 429)); arrow.line(to: NSPoint(x: 394, y: 415)); arrow.line(to: NSPoint(x: 376, y: 401))
            arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            indigo.setStroke(); arrow.stroke()

            let steps = [
                "1   Drag Nogrammerly into Applications (choose Replace if asked)",
                "2   Eject this disk, then open Nogrammerly from Applications",
                "3   Follow the Setup window: allow Accessibility in System Settings",
            ]
            let left = NSMutableParagraphStyle(); left.lineSpacing = 6
            NSAttributedString(string: steps.joined(separator: "\n"), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1), .paragraphStyle: left])
                .draw(in: NSRect(x: 110, y: 232, width: 480, height: 80))
            let divider = NSBezierPath(rect: NSRect(x: 110, y: 325, width: 440, height: 1))
            indigo.withAlphaComponent(0.25).setFill(); divider.fill()
            _ = context
        }, path)
    }
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "icon": makeIcon(source: args[2], output: args[3])
case "background": makeBackground(output1x: args[2], output2x: args[3])
default: fatalError("usage: make_artwork.swift icon <src> <out> | background <out1x> <out2x>")
}
