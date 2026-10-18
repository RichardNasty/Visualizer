import AppKit
import CoreAudio
import MetalKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// The visualizer surface: takes keyboard shortcuts and hides the cursor while it sits still.
final class VisualizerView: MTKView {
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var view: VisualizerView!
    private var renderer: Renderer!
    private let engine = Engine()
    private let tap = SystemAudioTap()
    private var lastFrame = CACurrentMediaTime()
    private var hud: NSTextField!
    private var hint: NSTextField!
    private var silentSince: Double?
    private var hudHideWork: DispatchWorkItem?
    private let soundMenu = NSMenu(title: "Sound")
    private var restartWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Visualizer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 300)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("VisualizerWindow")

        view = VisualizerView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        window.contentView = view

        do {
            renderer = try Renderer(outputFormat: view.colorPixelFormat)
            view.device = renderer.device
            view.delegate = self
        } catch {
            showFatal(error.localizedDescription)
        }

        hud = makeLabel(size: 22, weight: .medium)
        hint = makeLabel(size: 14, weight: .regular)
        hint.textColor = NSColor(white: 1, alpha: 0.7)
        layoutLabels()

        engine.director.onChange = { [weak self] text in
            DispatchQueue.main.async { self?.flashHUD(text) }
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        startListening()
        AudioDevices.observeChanges { [weak self] in
            self?.rebuildSoundMenu()
            self?.scheduleRestart()
        }
        flashHUD("\(engine.director.sceneName) · \(engine.director.paletteName)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { tap.stop() }

    // MARK: - Audio

    private func startListening() {
        let analyzer = engine.analyzer
        tap.onSamples = { samples, count, rate in analyzer.push(samples, count: count, sampleRate: rate) }
        do {
            try tap.start()
        } catch {
            hint.stringValue = "Couldn't listen to your Mac's sound: \(error.localizedDescription)"
            hint.isHidden = false
        }
    }

    /// The tap follows the current output, so rebuild it when the output changes.
    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startListening() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = now - lastFrame
        lastFrame = now
        guard let renderer, let drawable = view.currentDrawable,
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let (w, h) = renderer.feedbackSize(for: Int(size.width), Int(size.height))
        let uniforms = engine.step(dt: dt, width: w, height: h)
        renderer.encode(commandBuffer, uniforms: uniforms, wave: engine.analyzer.wave,
                        spectrum: engine.analyzer.spectrum, output: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        updateSilenceHint(now: now)
    }

    private func updateSilenceHint(now: Double) {
        guard tap.isRunning else { return }
        if engine.analyzer.features.silent {
            if silentSince == nil { silentSince = now }
            let show = now - silentSince! > 6
            if show && hint.isHidden {
                hint.stringValue = "Play something on your Mac. If music is playing and nothing moves, choose Sound › Allow Listening…"
                hint.isHidden = false
            }
        } else {
            silentSince = nil
            if !hint.isHidden { hint.isHidden = true }
        }
    }

    // MARK: - Overlay text

    private func makeLabel(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = .white
        label.alignment = .center
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = .black
            s.shadowBlurRadius = 6
            return s
        }()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        view.addSubview(label)
        return label
    }

    private func layoutLabels() {
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
    }

    private func flashHUD(_ text: String) {
        hud.stringValue = text
        hud.alphaValue = 1
        hud.isHidden = false
        hudHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                self?.hud.animator().alphaValue = 0
            }
        }
        hudHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func showFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Visualizer can't start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Keys and menus

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 49: nextScene(nil); return true          // right arrow, space
        case 123: previousScene(nil); return true          // left arrow
        case 53:                                           // escape
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return true
        default: return false
        }
    }

    @objc private func nextScene(_ sender: Any?) { engine.director.nextScene() }
    @objc private func previousScene(_ sender: Any?) { engine.director.nextScene(-1) }
    @objc private func nextPalette(_ sender: Any?) { engine.director.nextPalette() }
    @objc private func toggleFullScreen(_ sender: Any?) { window.toggleFullScreen(nil) }

    @objc private func toggleLock(_ sender: NSMenuItem) {
        engine.director.locked.toggle()
        sender.state = engine.director.locked ? .on : .off
        flashHUD(engine.director.locked ? "Staying on \(engine.director.sceneName)" : "Following the music")
    }

    @objc private func openPrivacySettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func chooseOutput(_ sender: NSMenuItem) {
        AudioDevices.setDefaultOutput(AudioObjectID(sender.tag))
    }

    func windowDidEnterFullScreen(_ notification: Notification) { NSCursor.setHiddenUntilMouseMoves(true) }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === soundMenu { rebuildSoundMenu() } }

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Visualizer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Visualizer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Visualizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let next = viewMenu.addItem(withTitle: "Next Scene", action: #selector(nextScene(_:)), keyEquivalent: "]")
        next.target = self
        let prev = viewMenu.addItem(withTitle: "Previous Scene", action: #selector(previousScene(_:)), keyEquivalent: "[")
        prev.target = self
        let pal = viewMenu.addItem(withTitle: "Next Colors", action: #selector(nextPalette(_:)), keyEquivalent: "p")
        pal.target = self
        pal.keyEquivalentModifierMask = []
        let lock = viewMenu.addItem(withTitle: "Stay on This Scene", action: #selector(toggleLock(_:)), keyEquivalent: "l")
        lock.target = self
        lock.keyEquivalentModifierMask = []
        viewMenu.addItem(.separator())
        let full = viewMenu.addItem(withTitle: "Full Screen", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        full.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let soundItem = NSMenuItem()
        soundMenu.delegate = self
        soundItem.submenu = soundMenu
        main.addItem(soundItem)
        rebuildSoundMenu()

        NSApp.mainMenu = main
    }

    private func rebuildSoundMenu() {
        soundMenu.removeAllItems()
        let header = soundMenu.addItem(withTitle: "Play Through", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let current = AudioDevices.defaultOutput()
        for device in AudioDevices.outputs() {
            let item = soundMenu.addItem(withTitle: device.name, action: #selector(chooseOutput(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(device.id)
            item.state = device.id == current ? .on : .off
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
        }
        soundMenu.addItem(.separator())
        let allow = soundMenu.addItem(withTitle: "Allow Listening…", action: #selector(openPrivacySettings(_:)), keyEquivalent: "")
        allow.target = self
    }
}
