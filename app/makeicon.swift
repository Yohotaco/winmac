import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for s in [16, 32, 64, 128, 256, 512, 1024] {
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
        let inset = r.insetBy(dx: r.width * 0.08, dy: r.height * 0.08)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.width * 0.22)
        NSGradient(starting: NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(red: 0.45, green: 0.15, blue: 0.75, alpha: 1))!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: inset.width * 0.5, weight: .bold).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let sz = sym.size
            sym.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    let png = rep.representation(using: .png, properties: [:])!
    for (n, scale) in [(s, 1), (s / 2, 2)] where n >= 16 && n <= 512 {
        try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(n)x\(n)\(scale == 2 ? "@2x" : "").png"))
    }
}
