import SwiftUI

struct MixerView: View {
    @ObservedObject var mixer: Mixer
    @ViewState private var search = ""
    @Environment(\.colorScheme) var scheme
    @Environment(\.larixPalette) private var palette
    @Environment(\.solidSurfaces) private var solid
    private var visible: [Channel] {
        mixer.channels.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ZStack {
            Atmosphere()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        Brand()
                        Spacer()
                        AppearanceMenu()
                    }.padding(.top, 43)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find an app", text: $search).textFieldStyle(.plain)
                            .accessibilityLabel("Find an application")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }.padding(9).background(solid ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial),
                                           in: RoundedRectangle(cornerRadius: 9))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            appSection("Active audio", apps: visible.filter { $0.playing || $0.usingInput })
                            appSection("Applications", apps: visible.filter { !$0.playing && !$0.usingInput })
                            if visible.isEmpty {
                                Text(search.isEmpty ? "No apps available" : "No matching apps")
                                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 9) {
                        Image(systemName: "hifispeaker.2").font(.system(size: 17)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("System output").font(.caption).foregroundStyle(.secondary)
                            Text(mixer.systemOutput).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        }
                    }.padding(.bottom, 18)
                }.padding(.horizontal, 16).frame(width: 216)
                    .background(solid ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                Divider()
                if let app = mixer.channels.first(where: { $0.id == mixer.selected }) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                AppIcon(app: app, mixer: mixer, size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.system(size: 25, weight: .semibold, design: .rounded))
                                        .lineLimit(1).help(app.name)
                                    HStack(spacing: 8) {
                                        StatusLight(text: app.playing ? "Playing" : app.usingInput ? "Using input" : app.running ? "Idle" : "Offline",
                                                    on: app.playing || app.usingInput)
                                        if mixer.routed.contains(app.id) { PeakMeter(levels: mixer.levels) }
                                    }
                                }
                                Spacer(minLength: 4)
                                Menu {
                                    Button("Reset playback to defaults") { mixer.restorePlayback(app) }
                                    Button("Audio recording permissions…") { openAudioPrivacy() }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(.system(size: 18))
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel("Playback options")
                            }
                            Divider()
                            VolumeView(mixer: mixer, app: app)
                        }.padding(16).glassSurface()
                            .padding(.horizontal, 22).padding(.top, 33).padding(.bottom, 12)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if let message = mixer.errors[app.id] {
                                    PlaybackError(mixer: mixer, app: app, message: message)
                                }
                                Equalizer(mixer: mixer, app: app)
                                RoutingView(mixer: mixer, app: app)
                            }.padding(.horizontal, 22).padding(.bottom, 20)
                        }.id(app.id)
                    }.frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(mixer.ready ? "Open an audio app" : "Finding applications…").font(.title2.weight(.semibold))
                        if mixer.ready { Text("Its playback and routing controls will appear here.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    @ViewBuilder private func appSection(_ title: String, apps: [Channel]) -> some View {
        if !apps.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 8).padding(.top, 7).padding(.bottom, 3)
            ForEach(apps) { app in
                let selected = mixer.selected == app.id
                Button { mixer.selected = app.id } label: {
                    HStack(spacing: 9) {
                        AppIcon(app: app, mixer: mixer, size: 27)
                        Text(app.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if mixer.profiles[app.id]?.muted == true {
                            Image(systemName: "speaker.slash.fill").font(.caption2).foregroundStyle(.secondary)
                        } else if app.playing || app.usingInput {
                            Image(systemName: app.playing ? "waveform" : "mic.fill").font(.caption).foregroundStyle(.tint)
                        }
                    }.padding(.horizontal, 8).frame(height: 38).contentShape(Rectangle())
                        .background(selected ? palette.accent(.light).opacity(scheme == .dark ? 0.31 : 0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

}

struct VolumeView: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    @Environment(\.colorScheme) var scheme
    @Environment(\.larixPalette) private var palette
    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        HStack(spacing: 10) {
            Button {
                mixer.selected = app.id
                mixer.change(app) { $0.muted.toggle() }
            } label: {
                Image(systemName: p.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 23, height: 24)
            }.buttonStyle(.borderless).accessibilityLabel(p.muted ? "Unmute " + app.name : "Mute " + app.name)
                .help(p.muted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { mixer.profiles[app.id]?.volume ?? 1 }, set: { volume in
                if mixer.selected != app.id { mixer.selected = app.id }
                mixer.change(app) { $0.volume = (volume * 100).rounded() / 100 }
            }), in: 0...1).accessibilityLabel(app.name + " volume")
                .accessibilityValue(Text(p.volume, format: .percent.precision(.fractionLength(0))))
                .tint(p.muted ? .gray : palette.accent(scheme))
            Text(p.volume, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(p.muted ? .secondary : .primary).frame(width: 42, alignment: .trailing)
        }

    }
}

private struct PeakMeter: View {
    @ObservedObject var levels: Levels
    var body: some View {
        let bars = max(0, min(12, (levels.decibels + 48) / 4))
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { n in
                Capsule().fill(n < bars ? (n > 9 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint)) : AnyShapeStyle(.secondary.opacity(0.18)))
                    .frame(width: 2, height: 8)
            }
        }.accessibilityLabel("Output peak").accessibilityValue("\(levels.decibels) decibels")
    }
}

private func openAudioPrivacy() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}

private struct PlaybackError: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    let message: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { mixer.refresh(scan: true, retry: app.id) }
            if message.contains("Recording") {
                Button("Settings") { openAudioPrivacy() }
            }
        }.padding(12).glassSurface(12)
    }
}

struct OutputMenu: View {
    @ObservedObject var mixer: Mixer
    let app: Channel
    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        let list = mixer.devices.filter(\.output)
        Picker("Output", selection: Binding(get: { p.output }, set: { value in mixer.change(app) { $0.output = value } })) {
            Text("App output").tag(defaultOutput)
            Text("System default").tag(systemOutputChoice)
            Divider()
            ForEach(list) { Text($0.name).tag($0.id) }
            if !p.output.isEmpty && p.output != systemOutputChoice && !list.contains(where: { $0.id == p.output }) {
                Text("Disconnected output").tag(p.output)
            }
        }.labelsHidden().accessibilityLabel("Output for " + app.name)
    }
}

private struct RoutingView: View {
    @ObservedObject var mixer: Mixer
    let app: Channel

    var body: some View {
        let p = mixer.profiles[app.id] ?? Profile()
        let alias = mixer.aliases[LXInputUID(app.id)]
        let connected = alias.map { app.inputs.contains($0) && app.usingInput } ?? false
        let source = mixer.devices.first { $0.id == p.input }
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio routing", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .semibold))
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Output device", systemImage: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                    OutputMenu(mixer: mixer, app: app)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Microphone", systemImage: "mic").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("Use app settings") { mixer.changeInput(app, to: nil) }
                        Divider()
                        ForEach(mixer.devices.filter(\.input)) { device in
                            Button { mixer.changeInput(app, to: device.id) } label: {
                                if p.input == device.id && alias != nil { Label(device.name, systemImage: "checkmark") }
                                else { Text(device.name) }
                            }
                        }
                    } label: {
                        Text(mixer.changingInputs.contains(app.id) ? "Updating…" : source?.name ?? (p.input == nil ? "App settings" : "Disconnected input"))
                            .lineLimit(1)
                    }.disabled(mixer.changingInputs.contains(app.id)).accessibilityLabel("Microphone for " + app.name)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = mixer.inputErrors[app.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if p.input != nil {
                if alias == nil {
                    Button("Recreate Larix input") { mixer.changeInput(app, to: p.input) }
                        .disabled(source == nil || mixer.changingInputs.contains(app.id))
                } else {
                    Text(connected ? "Input connected to \(app.name)." :
                            "In \(app.name)’s microphone menu, choose “Larix · \(app.name)”.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }.padding(18).glassSurface()
    }
}

struct QuickPanel: View {
    @ObservedObject var mixer: Mixer
    let screenHeight: CGFloat
    let openMixer: () -> Void
    @ViewState private var expanded: String?
    @ViewState private var contentHeight: CGFloat = 0
    @ViewState private var order: [String]

    init(mixer: Mixer, screenHeight: CGFloat, openMixer: @escaping () -> Void) {
        self.mixer = mixer
        self.screenHeight = screenHeight
        self.openMixer = openMixer
        _order = ViewState(initialValue: mixer.channels.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Brand()
                Spacer()
                AppearanceMenu()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("Quit Larix").accessibilityLabel("Quit Larix")
            }
            if mixer.channels.isEmpty {
                Text(mixer.ready ? "Open an app to adjust its sound." : "Finding applications…")
                    .foregroundStyle(.secondary)
            } else {
                appList
            }
            Button(action: openMixer) {
                HStack {
                    Text("Open mixer").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }.padding(.vertical, 3).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(14).frame(width: 348).fixedSize(horizontal: false, vertical: true)
            .background { Atmosphere() }
            .onChange(of: mixer.channels.map(\.id), initial: true) { _, incoming in
                order = Self.updatedOrder(order, incoming: incoming)
                if let expanded, !incoming.contains(expanded) { self.expanded = nil }
            }
    }

    private static let rowHeight: CGFloat = 66

    static func updatedOrder(_ current: [String], incoming: [String]) -> [String] {
        let present = Set(incoming)
        let previous = Set(current)
        return current.filter(present.contains) + incoming.filter { !previous.contains($0) }
    }

    static func listHeight(content: CGFloat, screenHeight: CGFloat) -> CGFloat {
        // Leave room for the brand, footer, popover arrow, and window margins.
        let capacity = max(1, min(6, floor((screenHeight - 140) / rowHeight)))
        return min(capacity * rowHeight, content)
    }

    private var appList: some View {
        let lookup = Dictionary(uniqueKeysWithValues: mixer.channels.map { ($0.id, $0) })
        let apps = order.compactMap { lookup[$0] }
        let rowsHeight = CGFloat(apps.count) * Self.rowHeight
        let content = expanded == nil ? rowsHeight : max(rowsHeight, contentHeight)
        let height = Self.listHeight(content: content, screenHeight: screenHeight)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        row(app)
                            .overlay(alignment: .bottom) {
                                if app.id != apps.last?.id { Divider().padding(.horizontal, 14) }
                            }
                            .id(app.id)
                    }
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: height)
            .scrollBounceBehavior(.basedOnSize)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollIndicators(content > height ? .automatic : .hidden)
            .onChange(of: expanded) { _, id in
                if let id { reader.scrollTo(id) }
            }
            .onChange(of: height) { _, _ in
                if let expanded { reader.scrollTo(expanded) }
            }
        }
        .clipShape(shape)
        .glassSurface(14)
    }

    private func row(_ app: Channel) -> some View {
        let isExpanded = expanded == app.id
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 3) {
                Button {
                    mixer.selected = app.id
                    expanded = isExpanded ? nil : app.id
                } label: {
                    HStack(spacing: 8) {
                        AppIcon(app: app, mixer: mixer, size: 23)
                        Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if app.playing { Image(systemName: "waveform").font(.caption).foregroundStyle(.tint) }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(app.name + " playback options")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                VolumeView(mixer: mixer, app: app)
            }.frame(height: Self.rowHeight)
            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Equalizer") { PresetMenu(mixer: mixer, app: app) }
                    LabeledContent("Output") { OutputMenu(mixer: mixer, app: app).lineLimit(1) }
                    if let message = mixer.errors[app.id] {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
        }.padding(.horizontal, 14)
    }
}
