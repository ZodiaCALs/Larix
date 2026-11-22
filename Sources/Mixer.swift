import AppKit
import Combine
import CoreAudio

let defaultOutput = ""
let systemOutputChoice = "audio.larix.follow-system"
let flat = Array(repeating: 0.0, count: Int(LX_BANDS))
let presets: [(String, [Double])] = [
    ("Flat", flat), ("Warm", [4, 2, 0, -1, -2]),
    ("Voice", [-5, -2, 2, 4, 0]), ("Bright", [-2, -1, 0, 2, 4])
]

struct Profile: Codable, Equatable {
    var name = ""
    var path: String?
    var volume = 1.0
    var muted = false
    var bands = flat
    var eqEnabled = true
    var output = defaultOutput
    var input: String?
    var effectiveBands: [Double] { eqEnabled ? bands : flat }
    var needsPlayback: Bool { muted || volume != 1 || effectiveBands != flat || !output.isEmpty }
}

struct Channel: Identifiable, Equatable {
    let id: String
    var name: String
    var path: String?
    var processes = [UInt32]()
    var running = false
    var playing = false
    var usingInput = false
    var inputs = Set<UInt32>()
    var outputs = Set<UInt32>()

    func destination(in devices: [Device], defaultDevice: UInt32, preference: String) -> Device? {
        let available = devices.filter(\.output)
        let system = available.first { $0.object == defaultDevice }
        if preference == systemOutputChoice { return system }
        if !preference.isEmpty { return available.first { $0.id == preference } }
        if outputs.contains(defaultDevice) { return system }
        return available.first { outputs.contains($0.object) } ?? system
    }
}

struct Device: Identifiable, Equatable {
    let id: String
    let object: UInt32
    let name: String
    let rate: Double
    let input: Bool
    let output: Bool
}

struct Hardware {
    var channels = [String: Channel]()
    var devices = [Device]()
    var defaultDevice: UInt32 = 0
    var inputAliases = [String: UInt32]()
    var defaultName: String { devices.first { $0.object == defaultDevice }?.name ?? "No output device" }

    static func scan() -> Hardware {
        var h = Hardware()
        let system = AudioObjectID(kAudioObjectSystemObject)
        let global = kAudioObjectPropertyScopeGlobal
        h.defaultDevice = LXNumber(system, kAudioHardwarePropertyDefaultOutputDevice)
        for number in LXObjects(system, kAudioHardwarePropertyDevices, global) {
            let obj = number.uint32Value
            guard let uid = LXString(obj, kAudioDevicePropertyDeviceUID) else { continue }
            if uid.hasPrefix("audio.larix.input.") {
                h.inputAliases[uid] = obj
                continue
            }
            guard !uid.hasPrefix("audio.larix.playback."),
                  LXNumber(obj, kAudioDevicePropertyDeviceIsAlive) != 0 else { continue }
            let input = !LXObjects(obj, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty
            let output = !LXObjects(obj, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty
            h.devices.append(Device(id: uid, object: obj, name: LXString(obj, kAudioObjectPropertyName) ?? uid,
                                    rate: LXRate(obj), input: input, output: output))
        }
        h.devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            guard let key = app.bundleIdentifier else { continue }
            h.channels[key] = Channel(id: key, name: app.localizedName ?? key, path: app.bundleURL?.path, running: true)
        }
        for number in LXObjects(system, kAudioHardwarePropertyProcessObjectList, global) {
            let object = number.uint32Value
            let pid = pid_t(bitPattern: LXNumber(object, kAudioProcessPropertyPID))
            guard pid > 0 && pid != ownPID else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundle = LXString(object, kAudioProcessPropertyBundleID)
            var key = bundle.flatMap { $0.isEmpty ? nil : $0 } ?? app?.bundleIdentifier
            var path = app?.bundleURL?.path
            // Nesting identifies the owning app for Electron and other bundled audio helpers.
            if let url = app?.bundleURL, let range = url.path.range(of: ".app/") {
                let outer = String(url.path[..<range.lowerBound]) + ".app"
                if let owner = Bundle(path: outer)?.bundleIdentifier {
                    key = owner
                    path = outer
                }
            }
            let playing = LXNumber(object, kAudioProcessPropertyIsRunningOutput) != 0
            let usingInput = LXNumber(object, kAudioProcessPropertyIsRunningInput) != 0
            // Include active command-line clients with a process-lifetime identity.
            let id = key ?? app?.executableURL?.path ?? "pid.\(pid)"
            guard id != Bundle.main.bundleIdentifier,
                  h.channels[id] != nil || playing || usingInput || app?.activationPolicy == .regular
            else { continue }
            let fallback = path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            var channel = h.channels[id] ?? Channel(id: id, name: fallback ?? app?.localizedName ?? key ?? "Process \(pid)", path: path)
            channel.running = true
            channel.playing = channel.playing || playing
            channel.usingInput = channel.usingInput || usingInput
            channel.processes.append(object)
            channel.inputs.formUnion(LXObjects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).map(\.uint32Value))
            channel.outputs.formUnion(LXObjects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput).map(\.uint32Value))
            h.channels[id] = channel
        }
        return h
    }
}

private struct RouteKey: Equatable {
    var processes: [UInt32]
    var device: UInt32
    var rate: Double
}

private struct Playback {
    var key: RouteKey
    var route: LXRoute?
    var error: String?
    var neutralSince: ContinuousClock.Instant?
    var applied: Profile?
}

// Accessed exclusively on the audio control queue. The HAL callbacks use the C signal path.
private final class Engine: @unchecked Sendable {
    var hardware = Hardware()
    var playback = [String: Playback]()

    func apply(_ profiles: [String: Profile], retry: String?, editingEQ: String?, checkClocks: Bool) {
        for id in Set(playback.keys).union(profiles.keys) {
            guard let profile = profiles[id], profile.needsPlayback || playback[id] != nil,
                  let app = hardware.channels[id], !app.processes.isEmpty else {
                playback.removeValue(forKey: id)?.route?.stop()
                continue
            }
            let device = app.destination(in: hardware.devices, defaultDevice: hardware.defaultDevice, preference: profile.output)
            let key = RouteKey(processes: app.processes.sorted(), device: device?.object ?? 0, rate: device?.rate ?? 0)
            if var previous = playback[id], previous.key == key, let route = previous.route,
               id != retry, !(checkClocks && route.clockChanged) {
                if profile.needsPlayback || (editingEQ == id && profile.eqEnabled) {
                    previous.neutralSince = nil
                } else if let since = previous.neutralSince, since.duration(to: .now) >= .milliseconds(80) {
                    playback.removeValue(forKey: id)?.route?.stop()
                    continue
                } else if previous.neutralSince == nil {
                    // Let the last EQ fade finish before returning to direct playback.
                    previous.neutralSince = .now
                }
                if previous.applied != profile {
                    route.adjust(Float(profile.volume), muted: profile.muted, bands: profile.effectiveBands.map(NSNumber.init(value:)))
                    previous.applied = profile
                }
                playback[id] = previous
                continue
            }
            if profile.needsPlayback, let previous = playback[id], previous.key == key,
               previous.error != nil, id != retry { continue }
            playback.removeValue(forKey: id)?.route?.stop()
            guard profile.needsPlayback else { continue }
            guard let device else {
                playback[id] = Playback(key: key, error: "Output disconnected. Using the app’s own playback.")
                continue
            }
            let route = LXRoute()
            do {
                try route.start(processes: key.processes.map(NSNumber.init(value:)), output: device.object,
                                volume: Float(profile.volume), muted: profile.muted, bands: profile.effectiveBands.map(NSNumber.init(value:)))
                playback[id] = Playback(key: key, route: route, applied: profile)
            } catch {
                playback[id] = Playback(key: key, error: error.localizedDescription)
            }
        }
    }
}

@MainActor final class Mixer: ObservableObject {
    @Published var channels = [Channel]()
    @Published var devices = [Device]()
    @Published var systemOutput = "Looking for devices…"
    @Published var systemDevice: UInt32 = 0
    @Published var selected: String? { didSet { updateMeter() } }
    @Published var profiles: [String: Profile]
    @Published var errors = [String: String]()
    @Published var inputErrors = [String: String]()
    @Published var aliases = [String: UInt32]()
    @Published var routed = Set<String>() {
        didSet {
            updateDiscovery()
            updateMeter()
        }
    }
    @Published var changingInputs = Set<String>()
    @Published var ready = false
    let levels = Levels()
    private let engine = Engine()
    private let queue = DispatchQueue(label: "audio.larix.controls", qos: .userInitiated)
    private var started = false
    private var scanTimer: Timer?
    private var meterTimer: Timer?
    private var mixerVisible = false
    private var panelVisible = false
    private var meterID: String?
    private var meterPending = false
    private var saveTimer: Timer?
    private var busy = false
    private var pending = false
    private var scanPending = false
    private var retryIDs = Set<String>()
    private var editingEQ: String?
    private var icons = [String: NSImage]()
    private static let settings = "appProfiles.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.settings)
        profiles = stored.flatMap { try? JSONDecoder().decode([String: Profile].self, from: $0) } ?? [:]
        profiles = profiles.filter { !$0.key.hasPrefix("pid.") }.mapValues {
            var p = $0
            p.volume = min(1, max(0, p.volume))
            p.bands = p.bands.count == flat.count ? p.bands.map { min(12, max(-12, $0)) } : flat
            return p
        }
    }

    func start() {
        guard !started else { return }
        started = true
        updateDiscovery()
        updateMeter()
    }

    func setMixerVisible(_ visible: Bool) {
        guard visible != mixerVisible else { return }
        mixerVisible = visible
        updateDiscovery(refreshNow: visible)
        updateMeter()
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        updateDiscovery(refreshNow: visible)
    }

    private func updateDiscovery(refreshNow: Bool = false) {
        guard started && (mixerVisible || panelVisible || !routed.isEmpty || profiles.values.contains(where: \.needsPlayback)) else {
            scanTimer?.invalidate()
            scanTimer = nil
            return
        }
        if scanTimer == nil {
            scanTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(scan: true) }
            }
            scanTimer?.tolerance = 0.2
            refresh(scan: true)
        } else if refreshNow {
            refresh(scan: true)
        }
    }

    private func updateMeter() {
        let id = mixerVisible && started ? selected.flatMap { routed.contains($0) ? $0 : nil } : nil
        guard id != meterID else { return }
        meterID = id
        meterTimer?.invalidate()
        meterTimer = nil
        levels.update(0)
        guard let id else { return }
        readLevel(id)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLevel(id) }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func readLevel(_ id: String) {
        guard !meterPending else { return }
        meterPending = true
        queue.async { [engine] in
            let peak = engine.playback[id]?.route?.peak ?? 0
            DispatchQueue.main.async {
                self.meterPending = false
                if self.meterID == id { self.levels.update(peak) }
            }
        }
    }

    func refresh(scan: Bool = false, retry: String? = nil) {
        guard started else { return }
        if let retry { retryIDs.insert(retry) }
        scanPending = scanPending || scan
        guard !busy else { pending = true; return }
        busy = true
        let shouldScan = scanPending, retry = retryIDs.popFirst(), settings = profiles, editingEQ = self.editingEQ
        scanPending = false
        pending = !retryIDs.isEmpty
        queue.async { [engine] in
            if shouldScan { engine.hardware = Hardware.scan() }
            let hardware = engine.hardware
            engine.apply(settings, retry: retry, editingEQ: editingEQ, checkClocks: shouldScan)
            let errors = engine.playback.compactMapValues(\.error)
            let routed = Set(engine.playback.compactMap { $1.route == nil ? nil : $0 })
            DispatchQueue.main.async {
                var apps = hardware.channels
                for (id, p) in self.profiles where apps[id] == nil && (p.needsPlayback || p.input != nil || p.bands != flat) {
                    apps[id] = Channel(id: id, name: p.name, path: p.path)
                }
                let sorted = apps.values.sorted {
                    if $0.playing != $1.playing { return $0.playing }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                if self.channels != sorted { self.channels = sorted }
                if self.devices != hardware.devices { self.devices = hardware.devices }
                if self.systemOutput != hardware.defaultName { self.systemOutput = hardware.defaultName }
                if self.systemDevice != hardware.defaultDevice { self.systemDevice = hardware.defaultDevice }
                if self.aliases != hardware.inputAliases { self.aliases = hardware.inputAliases }
                if self.errors != errors { self.errors = errors }
                if self.routed != routed { self.routed = routed }
                if self.selected.flatMap({ apps[$0] }) == nil, self.selected != sorted.first?.id { self.selected = sorted.first?.id }
                if !self.ready { self.ready = true }
                self.busy = false
                if self.pending { self.refresh() }
            }
        }
    }

    func trackEQ(_ app: Channel, editing: Bool) {
        if editing { editingEQ = app.id }
        else if editingEQ == app.id { finishEQEdit() }
    }

    func finishEQEdit() {
        guard editingEQ != nil else { return }
        editingEQ = nil
        refresh()
    }

    func change(_ app: Channel, _ edit: (inout Profile) -> Void) {
        var p = profiles[app.id] ?? Profile()
        let old = p
        edit(&p)
        guard p != old else { return }
        p.name = app.name
        p.path = app.path
        profiles[app.id] = p
        scheduleSave()
        if p.needsPlayback != old.needsPlayback { updateDiscovery() }
        refresh()
    }

    private func scheduleSave() {
        let fireDate = Date(timeIntervalSinceNow: 0.3)
        if let saveTimer {
            saveTimer.fireDate = fireDate
            return
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProfiles() }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    private func saveProfiles() {
        guard let saveTimer else { return }
        saveTimer.invalidate()
        self.saveTimer = nil
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.settings) }
    }

    func changeInput(_ app: Channel, to source: String?) {
        guard !changingInputs.contains(app.id) else { return }
        changingInputs.insert(app.id)
        inputErrors.removeValue(forKey: app.id)
        queue.async {
            do {
                try LXInput.configure(appKey: app.id, name: "Larix · " + app.name, source: source)
                DispatchQueue.main.async {
                    self.changingInputs.remove(app.id)
                    self.change(app) { $0.input = source }
                    self.refresh(scan: true)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.changingInputs.remove(app.id)
                    self.inputErrors[app.id] = message
                }
            }
        }
    }

    func restorePlayback(_ app: Channel) {
        change(app) {
            $0.volume = 1
            $0.muted = false
            $0.bands = flat
            $0.eqEnabled = true
            $0.output = defaultOutput
        }
    }

    func icon(_ app: Channel) -> NSImage? {
        guard let path = app.path else { return nil }
        if let image = icons[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
    func stop() {
        saveProfiles()
        started = false
        updateDiscovery()
        updateMeter()
        queue.sync { engine.playback.removeAll() }
    }
}

@MainActor final class Levels: ObservableObject {
    @Published private(set) var decibels = -80
    func update(_ peak: Float) {
        let value = Int(floor(20 * log10(max(0.0001, Double(peak)))))
        if decibels != value { decibels = value }
    }
}
