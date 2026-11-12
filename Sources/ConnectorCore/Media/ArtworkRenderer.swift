import CoreGraphics
import Foundation

public enum ArtworkRenderer {
    public static func rgb565LE(_ image: CGImage, side: Int) -> Data {
        precondition(side > 0, "invalid artwork side")
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let w = Double(image.width), h = Double(image.height)
            guard w > 0, h > 0 else { return }
            let scale = min(Double(side) / w, Double(side) / h)
            let dw = w * scale, dh = h * scale
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (Double(side) - dw) / 2, y: (Double(side) - dh) / 2, width: dw, height: dh))
        }
        var out = Data(capacity: side * side * 2)
        for i in 0..<(side * side) {
            let r = UInt16(rgba[i * 4] >> 3), g = UInt16(rgba[i * 4 + 1] >> 2), b = UInt16(rgba[i * 4 + 2] >> 3)
            let v = r << 11 | g << 5 | b
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return out
    }
}
