import SwiftUI

let frequencyNames = ["80 Hz", "250 Hz", "1 kHz", "4 kHz", "12 kHz"]
private func decibels(_ value: Double) -> String {
    value == 0 ? "0 dB" : String(format: "%+.1f dB", value)
}

struct PresetMenu: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        let name = presets.first { $0.1 == p.bands }?.0 ?? "Custom"
        Menu {
            ForEach(presets, id: \.0) { preset in
                Button { mixer.change(app) { $0.bands = preset.1; $0.eqEnabled = true } } label: {
                    if preset.0 == name { Label(preset.0, systemImage: "checkmark") }
                    else { Text(preset.0) }
                }
            }
        } label: { Text(p.eqEnabled ? name : "Bypassed") }.fixedSize()
            .accessibilityLabel(p.eqEnabled ? "Equalizer preset, " + name : "Equalizer bypassed, select a preset to enable")
    }
}

struct Equalizer: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        let device = app.destination(in: mixer.devices, defaultDevice: mixer.systemDevice, preference: p.output)
        let rate = device.flatMap { $0.rate >= 8000 ? $0.rate : nil } ?? 48000
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("Equalizer", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                PresetMenu(mixer: mixer, app: app)
                Toggle("Enable equalizer", isOn: Binding(get: { p.eqEnabled }, set: { enabled in
                    mixer.change(app) { $0.eqEnabled = enabled }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            ResponsePlot(gains: p.bands, rate: rate, enabled: p.eqEnabled,
                         tracking: { mixer.trackEQ(app, editing: $0) }) { band, value in
                mixer.change(app) { $0.bands[band] = value }
            }.id(rate).frame(height: 154)
            HStack(spacing: 6) {
                ForEach(0..<frequencyNames.count, id: \.self) { i in
                    BandControl(mixer: mixer, app: app, index: i, available: LXBandAvailable(UInt32(i), rate))
                    if i < frequencyNames.count - 1 { Divider().frame(height: 25) }
                }
            }
        }.padding(18).glassSurface()
    }
}

private struct BandControl: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    let index: Int
    let available: Bool
    @ViewState private var editing = false

    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        let name = frequencyNames[index]
        Button { editing = true } label: {
            VStack(spacing: 4) {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(available ? decibels(p.bands[index]) : "—")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }.frame(maxWidth: .infinity).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!p.eqEnabled || !available)
            .help(available ? "Adjust " + name : "Outside this output’s frequency range")
            .popover(isPresented: $editing) {
                BandEditor(mixer: mixer, app: app, index: index)
            }
            .onChange(of: p.eqEnabled && available) { _, active in if !active { editing = false } }
    }
}

private struct BandEditor: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    let index: Int

    var body: some View {
        let gain = Binding<Double>(
            get: { mixer.profiles[app.id]?.bands[index] ?? 0 },
            set: { value in mixer.change(app) { $0.bands[index] = value } }
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(frequencyNames[index]).bold()
                Spacer()
                Text(decibels(gain.wrappedValue)).monospacedDigit()
            }
            Slider(value: gain, in: -12...12, step: 0.5) { editing in mixer.trackEQ(app, editing: editing) }
                .accessibilityLabel(frequencyNames[index] + " gain")
        }.padding().frame(width: 220).onDisappear { mixer.trackEQ(app, editing: false) }
    }
}

private struct ResponsePlot: View {
    var gains: [Double]
    var rate: Double
    var enabled: Bool
    let tracking: (Bool) -> Void
    let change: (Int, Double) -> Void
    @ViewState private var held: (band: Int, initialGain: Double)?
    @Environment(\.larixPalette) private var palette
    private var upperFrequency: Double { min(20000, rate / 2) }
    private func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        log(hz / 30) / log(upperFrequency / 30) * width
    }
    private func endDrag() {
        guard held != nil else { return }
        held = nil
        tracking(false)
    }
    var body: some View {
        GeometryReader { g in
            let inset: CGFloat = 15, right: CGFloat = 34
            let w = max(1, g.size.width - inset - right), h = max(1, g.size.height - 26)
            let values = (enabled ? gains : flat).map(Float.init)
            let bands = gains.indices.filter { LXBandAvailable(UInt32($0), rate) }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
                    colors: [palette.accent(.light).opacity(0.40), palette.accent(.light).opacity(0.20)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .background(.black, in: RoundedRectangle(cornerRadius: 12))
                Canvas { c, _ in
                    func ypos(_ gain: Double) -> CGFloat { 13 + h * (0.5 - min(16, max(-16, gain)) / 32) }
                    for gain in [-12, -6, 0, 6, 12] {
                        let y = ypos(Double(gain))
                        var grid = Path()
                        grid.move(to: CGPoint(x: inset, y: y)); grid.addLine(to: CGPoint(x: inset + w, y: y))
                        c.stroke(grid, with: .color(.white.opacity(gain == 0 ? 0.24 : 0.10)),
                                 style: StrokeStyle(lineWidth: 0.7, dash: gain == 0 ? [3, 4] : []))
                        if gain == 0 || abs(gain) == 12 {
                            c.draw(Text(gain > 0 ? "+12" : String(gain)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.62)), at: CGPoint(x: inset + w + 15, y: y))
                        }
                    }
                    for i in bands {
                        let dx = inset + x(LXBandFrequency(UInt32(i)), w)
                        var line = Path()
                        line.move(to: CGPoint(x: dx, y: 12)); line.addLine(to: CGPoint(x: dx, y: 14 + h))
                        c.stroke(line, with: .color(.white.opacity(0.10)), lineWidth: 0.7)
                    }
                    var curve = Path()
                    let segments = enabled && gains != flat ? max(72, Int(w / 3)) : 1
                    var frequencies = (0...segments).map { 30 * pow(upperFrequency / 30, Double($0) / Double(segments)) }
                    frequencies.append(contentsOf: bands.map { LXBandFrequency(UInt32($0)) })
                    var response = [Double](repeating: 0, count: frequencies.count)
                    LXResponseCurveDB(rate, values, frequencies, &response, UInt32(frequencies.count))
                    for i in 0...segments {
                        let f = Double(i) / Double(segments)
                        let p = CGPoint(x: inset + f * w, y: ypos(response[i]))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    var fill = curve
                    fill.addLine(to: CGPoint(x: inset + w, y: 13 + h))
                    fill.addLine(to: CGPoint(x: inset, y: 13 + h)); fill.closeSubpath()
                    let color = enabled ? palette.accent(.dark) : .gray
                    c.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0.015)]),
                                                        startPoint: .zero, endPoint: CGPoint(x: 0, y: 13 + h)))
                    c.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    for (offset, i) in bands.enumerated() {
                        let freq = LXBandFrequency(UInt32(i))
                        let center = CGPoint(x: inset + x(freq, w), y: ypos(response[segments + 1 + offset]))
                        let r: CGFloat = held?.band == i ? 5.5 : 4
                        let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                        c.fill(dot, with: .color(.black))
                        c.stroke(dot, with: .color(color), lineWidth: 2)
                    }
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                    guard enabled else { return }
                    if held == nil, let band = bands.min(by: {
                        abs(inset + x(LXBandFrequency(UInt32($0)), w) - drag.startLocation.x) <
                        abs(inset + x(LXBandFrequency(UInt32($1)), w) - drag.startLocation.x)
                    }) {
                        held = (band, gains[band])
                        tracking(true)
                    }
                    guard let held else { return }
                    let gain = held.initialGain - 32 * drag.translation.height / h
                    change(held.band, min(12, max(-12, (gain * 2).rounded() / 2)))
                }.onEnded { _ in endDrag() })
                .allowsHitTesting(enabled)
                .onChange(of: enabled) { _, active in if !active { endDrag() } }
                .onDisappear { endDrag() }
                .accessibilityLabel("Equalizer response").help("Drag vertically to adjust a frequency band")
        }
    }
}
