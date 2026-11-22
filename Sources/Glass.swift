import SwiftUI

typealias ViewState<Value> = SwiftUI.State<Value>
extension Color {
    static let pine = Color(red: 0.15, green: 0.49, blue: 0.42)
    static let seafoam = Color(red: 0.52, green: 0.94, blue: 0.76)
}

struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) var scheme
    @Environment(\.solidSurfaces) private var solid
    var radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if solid {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12)))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.12 : 0.5)))
                .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
        }
    }
}
extension View {
    func glassSurface(_ radius: CGFloat = 18) -> some View { modifier(GlassSurface(radius: radius)) }
}

struct Atmosphere: View {
    @Environment(\.colorScheme) var scheme
    @Environment(\.larixPalette) private var palette
    var body: some View {
        let dark = scheme == .dark
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: dark ? [
                    Color(red: 0.035, green: 0.09, blue: 0.10), Color(red: 0.09, green: 0.14, blue: 0.18)
                ] : [
                    Color(red: 0.85, green: 0.91, blue: 0.89), Color(red: 0.91, green: 0.94, blue: 0.96)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [palette.glow.opacity(dark ? 0.16 : 0.24), .clear],
                               center: UnitPoint(x: 0.08, y: 0.95), startRadius: 0, endRadius: geo.size.width * 0.65)
                RadialGradient(colors: [.indigo.opacity(dark ? 0.21 : 0.14), .clear],
                               center: UnitPoint(x: 0.98, y: 0.18), startRadius: 12, endRadius: geo.size.width * 0.49)
                Canvas { context, size in
                    // Quiet contour lines remain visible through the materials at the window edges.
                    for i in 0..<19 {
                        let offset = CGFloat(i) * 8
                        var p = Path()
                        p.move(to: CGPoint(x: -24, y: size.height * 0.65 + offset))
                        p.addCurve(to: CGPoint(x: size.width + 40, y: size.height * 0.81 + offset),
                                   control1: CGPoint(x: size.width * 0.34, y: size.height * 0.34 + offset),
                                   control2: CGPoint(x: size.width * 0.67, y: size.height * 1.43 + offset))
                        context.stroke(p, with: .color((dark ? Color.white : palette.accent(.light)).opacity(0.065)), lineWidth: 0.8)
                    }
                }
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 38, height: 38).accessibilityHidden(true)
            Text("Larix").font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-1.1)
        }
    }
}

struct AppIcon: View {
    let app: Channel
    let mixer: Mixer
    var size: CGFloat
    @Environment(\.solidSurfaces) private var solid
    var body: some View {
        Group {
            if let image = mixer.icon(app) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "waveform").resizable().scaledToFit().padding(size * 0.22)
                    .background(solid ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial),
                                in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct StatusLight: View {
    var text: String
    var on: Bool
    @Environment(\.solidSurfaces) private var solid
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.65))).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 10).padding(.vertical, 5)
            .background(solid ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.thinMaterial), in: Capsule())
    }
}
