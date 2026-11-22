import CoreGraphics

enum LarixWaveform {
    // Draw in top-left coordinates at every icon size, including the menu bar template.
    static func path(in rect: CGRect) -> CGPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: point(0, 0.53))
        path.addCurve(to: point(0.18, 0.32), control1: point(0.12, 0.53), control2: point(0.12, 0.32))
        path.addCurve(to: point(0.33, 0.88), control1: point(0.25, 0.32), control2: point(0.24, 0.88))
        path.addCurve(to: point(0.53, 0.08), control1: point(0.43, 0.88), control2: point(0.42, 0.08))
        path.addCurve(to: point(0.71, 0.71), control1: point(0.63, 0.08), control2: point(0.61, 0.71))
        path.addCurve(to: point(0.85, 0.41), control1: point(0.78, 0.71), control2: point(0.78, 0.41))
        path.addCurve(to: point(1, 0.53), control1: point(0.91, 0.41), control2: point(0.90, 0.53))
        return path
    }
}
