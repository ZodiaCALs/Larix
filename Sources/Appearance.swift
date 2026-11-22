import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var native: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Palette: String, CaseIterable {
    case forest = "Forest", ocean = "Ocean", iris = "Iris"

    func accent(_ scheme: ColorScheme) -> Color {
        switch self {
        case .forest: scheme == .dark ? .seafoam : .pine
        case .ocean: scheme == .dark ? Color(red: 0.48, green: 0.85, blue: 1) : Color(red: 0.08, green: 0.40, blue: 0.71)
        case .iris: scheme == .dark ? Color(red: 0.81, green: 0.73, blue: 1) : Color(red: 0.43, green: 0.30, blue: 0.70)
        }
    }

    var glow: Color {
        switch self {
        case .forest: .mint
        case .ocean: .cyan
        case .iris: .purple
        }
    }
}

enum SurfaceStyle: String, CaseIterable {
    case glass = "Glass", solid = "Solid"
}

@MainActor final class AppearancePreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var mode: AppearanceMode { didSet { defaults.set(mode.rawValue, forKey: "appearance.mode") } }
    @Published var palette: Palette { didSet { defaults.set(palette.rawValue, forKey: "appearance.palette") } }
    @Published var surface: SurfaceStyle { didSet { defaults.set(surface.rawValue, forKey: "appearance.surface") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: "appearance.mode").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        palette = defaults.string(forKey: "appearance.palette").flatMap(Palette.init(rawValue:)) ?? .forest
        surface = defaults.string(forKey: "appearance.surface").flatMap(SurfaceStyle.init(rawValue:)) ?? .glass
    }
}

private enum PaletteKey: EnvironmentKey { static let defaultValue = Palette.forest }
private enum SolidSurfacesKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var larixPalette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
    var solidSurfaces: Bool {
        get { self[SolidSurfacesKey.self] }
        set { self[SolidSurfacesKey.self] = newValue }
    }
}

struct MixerStyle: ViewModifier {
    @ObservedObject var preferences: AppearancePreferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environmentObject(preferences)
            .environment(\.larixPalette, preferences.palette)
            .environment(\.solidSurfaces, reduceTransparency || preferences.surface == .solid)
            .tint(preferences.palette.accent(scheme))
    }
}

struct AppearanceMenu: View {
    @EnvironmentObject private var preferences: AppearancePreferences

    var body: some View {
        Menu {
            Picker("Appearance", selection: $preferences.mode) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Palette", selection: $preferences.palette) {
                ForEach(Palette.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Surfaces", selection: $preferences.surface) {
                ForEach(SurfaceStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "paintpalette").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Appearance").help("Appearance")
    }
}
