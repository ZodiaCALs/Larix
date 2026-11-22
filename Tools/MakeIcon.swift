import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func uint32(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}
func icon(_ size: Int) -> Data {
    let colors = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 16, bytesPerRow: 0,
                      space: colors, bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 128
    c.scaleBy(x: scale, y: scale)
    func gradient(_ stops: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: colors, colors: stops as CFArray, locations: nil)!
    }
    func blue(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    func glow(at center: CGPoint, radius: CGFloat, color: CGColor) {
        c.drawRadialGradient(gradient([color, color.copy(alpha: 0)!]),
                             startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    let rect = CGRect(x: 8, y: 8, width: 112, height: 112)
    let shape = CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)
    c.setShadow(offset: CGSize(width: 0, height: -1.5 * scale), blur: 2.5 * scale, color: blue(0.01, 0.07, 0.22, 0.38))
    c.addPath(shape); c.setFillColor(CGColor(gray: 0.16, alpha: 1)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(shape); c.clip()
    c.drawLinearGradient(gradient([blue(0.28, 0.79, 1), blue(0.055, 0.37, 0.86), blue(0.055, 0.13, 0.48)]),
                         start: CGPoint(x: 32, y: 119), end: CGPoint(x: 80, y: 8),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    glow(at: CGPoint(x: 24, y: 15), radius: 51, color: blue(0.08, 0.86, 1, 0.70))
    glow(at: CGPoint(x: 114, y: 36), radius: 41, color: blue(0.39, 0.44, 1, 0.65))

    // A broad reflection follows the top face. Leave the centre clear around the waveform.
    c.saveGState()
    c.move(to: CGPoint(x: 6, y: 68))
    c.addCurve(to: CGPoint(x: 122, y: 99), control1: CGPoint(x: 48, y: 106), control2: CGPoint(x: 84, y: 71))
    c.addLine(to: CGPoint(x: 122, y: 123))
    c.addLine(to: CGPoint(x: 6, y: 123))
    c.closePath()
    c.clip()
    c.drawLinearGradient(gradient([blue(0.90, 0.97, 1, 0.50), blue(0.76, 0.90, 1, 0.09)]),
                         start: CGPoint(x: 28, y: 119), end: CGPoint(x: 82, y: 74), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    c.restoreGState()

    // A refractive lip catches light on opposing edges of the tile.
    let rim = CGPath(roundedRect: rect.insetBy(dx: 2.1, dy: 2.1), cornerWidth: 26, cornerHeight: 26, transform: nil)
    c.saveGState()
    c.addPath(rim)
    c.setLineWidth(4.2)
    c.replacePathWithStrokedPath()
    c.clip()
    c.drawLinearGradient(gradient([blue(0.94, 1, 1, 0.88), blue(0.84, 0.97, 1, 0.10), blue(0.025, 0.15, 0.48, 0.48)]),
                         start: CGPoint(x: 44, y: 120), end: CGPoint(x: 84, y: 10), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    glow(at: CGPoint(x: 91, y: 11), radius: 43, color: blue(0.43, 0.87, 1, 0.98))
    c.restoreGState()
    c.addPath(shape)
    c.setLineWidth(1.4)
    c.setStrokeColor(blue(0.80, 0.92, 1, 0.62))
    c.strokePath()
    c.translateBy(x: 0, y: 128)
    c.scaleBy(x: 1, y: -1)
    let wave = LarixWaveform.path(in: CGRect(x: 23, y: 29, width: 82, height: 70))
    c.setLineWidth(size <= 32 ? 7.0 : 6.2)
    c.setLineCap(.round)
    c.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2 * scale, color: blue(0.01, 0.10, 0.37, 0.58))
    c.setStrokeColor(blue(0.78, 0.93, 1))
    c.addPath(wave)
    c.strokePath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.translateBy(x: 0, y: -0.65)
    c.setLineWidth(size <= 32 ? 5.6 : 4.9)
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
    c.addPath(wave)
    c.strokePath()
    let bytes = NSMutableData()
    let dest = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
    let filters = IMAGEIO_PNG_FILTER_NONE | IMAGEIO_PNG_FILTER_SUB | IMAGEIO_PNG_FILTER_UP | IMAGEIO_PNG_FILTER_AVG | IMAGEIO_PNG_FILTER_PAETH
    let pngOptions = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: filters]]
    // Quantize once after compositing the glass layers so the gradients compress cleanly.
    let packed = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    packed.draw(c.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    CGImageDestinationAddImage(dest, packed.makeImage()!, pngOptions as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return bytes as Data
}
@main enum MakeIcon {
    static func main() throws {
        var chunks = Data()
        for (size, tags) in [(16, ["icp4"]), (32, ["ic11", "icp5"]), (64, ["ic12"]),
                             (128, ["ic07"]), (256, ["ic13", "ic08"]), (512, ["ic14", "ic09"]), (1024, ["ic10"])] {
            let data = icon(size)
            for tag in tags { chunks += Data(tag.utf8) + uint32(data.count + 8) + data }
        }
        try (Data("icns".utf8) + uint32(chunks.count + 8) + chunks)
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
