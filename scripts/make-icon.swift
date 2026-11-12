import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging"
let grid = 32

func pixel(_ x: Int, _ y: Int) -> Int {
    let fx = Double(x) + 0.5, fy = Double(y) + 0.5
    let inBody = x >= 7 && x <= 24 && y >= 1 && y <= 30
    let bodyEdge = inBody && (x == 7 || x == 24 || y == 1 || y == 30)
    if bodyEdge { return 1 }
    guard inBody else { return -1 }
    let inScreen = x >= 10 && x <= 21 && y >= 4 && y <= 13
    if inScreen {
        if x == 10 || x == 21 || y == 4 || y == 13 { return 1 }
        return (x + y) % 2 == 0 ? 1 : 0
    }
    let dx = fx - 16, dy = fy - 21.5
    let d = (dx * dx + dy * dy).squareRoot()
    if d <= 2.4 { return d > 1.5 ? 1 : 0 }
    if d <= 6.6 { return d > 5.7 ? 1 : 0 }
    return 0
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cell = Double(size) / Double(grid)
    for py in 0..<size {
        for px in 0..<size {
            let v = pixel(min(grid - 1, Int(Double(px) / cell)), min(grid - 1, Int(Double(py) / cell)))
            let color = v < 0 ? NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0) : (v == 1 ? NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1))
            rep.setColor(color, atX: px, y: py)
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

let iconset = "\(out)/Connector.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
