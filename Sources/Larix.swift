import SwiftUI
import Combine

@main @MainActor final class Larix: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let mixer = Mixer()
    private let appearance = AppearancePreferences()
    private var appearanceObserver: AnyCancellable?

    static func main() {
        let app = NSApplication.shared
        let delegate = Larix()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObserver = appearance.$mode.sink { [weak self] mode in
            let native = mode.native
            NSApp.appearance = native
            self?.popover.appearance = native
        }
        if let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: iconFile, withExtension: nil),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        makeMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1010, height: 710),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Larix"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 810, height: 490)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: MixerView(mixer: mixer).modifier(MixerStyle(preferences: appearance)).ignoresSafeArea())
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.setFrameAutosaveName("LarixMixer")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(size: NSSize(width: 19, height: 19), flipped: true) { rect in
                let path = NSBezierPath(cgPath: LarixWaveform.path(in: rect.insetBy(dx: 1, dy: 2)))
                path.lineWidth = 1.65
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            button.image = image
            button.toolTip = "Larix audio mixer"
            button.setAccessibilityLabel("Larix audio mixer")
            button.target = self
            button.action = #selector(togglePanel)
        }
        popover.behavior = .transient
        popover.delegate = self
        mixer.start()
        showMixer()
    }

    private func makeMenus() {
        let main = NSMenu()
        let app = NSMenu(title: "Larix")
        app.addItem(withTitle: "Show Mixer", action: #selector(showMixer), keyEquivalent: "1").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Larix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Larix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [app, edit, windows] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            let height = button.window?.screen?.visibleFrame.height ?? 600
            let panel = QuickPanel(mixer: mixer, screenHeight: height) { [weak self] in self?.showMixer() }
            let host = NSHostingController(rootView: panel.modifier(MixerStyle(preferences: appearance)).onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { [weak self] size in
                guard let self, self.popover.isShown, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            })
            host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
            popover.contentViewController = host
            popover.contentSize = host.sizeThatFits(in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: height))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func popoverWillShow(_ notification: Notification) {
        mixer.setPanelVisible(true)
    }
    func popoverDidClose(_ notification: Notification) {
        mixer.setPanelVisible(false)
        popover.contentViewController = nil
    }
    @objc private func showMixer() {
        popover.performClose(nil)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        mixer.finishEQEdit()
        mixer.setMixerVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        mixer.setMixerVisible(changed.occlusionState.contains(.visible))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMixer()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { mixer.stop() }
}
