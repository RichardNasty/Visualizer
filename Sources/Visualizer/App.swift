import AVKit
import MetalKit
import SwiftUI

@main
struct VisualizerApp: App {
    @StateObject private var engine: Engine

    init() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        _engine = StateObject(wrappedValue: Engine())
    }

    var body: some Scene {
        WindowGroup("Visualizer") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 640, minHeight: 400)
        }

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let renderer = engine.renderer {
                MetalView(renderer: renderer).ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 4) {
                if engine.showSongTitle, !engine.songTitle.isEmpty {
                    Text(engine.songTitle).font(.headline)
                }
                Text(engine.status).font(.caption).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(16)
            .opacity(engine.overlayVisible ? 1 : 0)
            .animation(.easeInOut(duration: 1.2), value: engine.overlayVisible)

            if let problem = engine.problem {
                Notice(text: problem, button: "Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            } else if engine.noSound {
                Notice(text: "No sound yet. Play something in any app. If music is playing and nothing moves, allow Visualizer under Privacy & Security › Screen & System Audio Recording.",
                       button: "Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            }
        }
        .onAppear { engine.start() }
        .onHover { if $0 { engine.flashOverlay() } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Section("Play sound through") {
                        ForEach(engine.outputs) { device in
                            Button {
                                engine.select(device)
                            } label: {
                                Label(device.name, systemImage: device.id == engine.currentOutput ? "checkmark" : device.symbol)
                            }
                        }
                    }
                    Divider()
                    Button("Show on a TV with AirPlay…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                    }
                    Button("Refresh devices") { engine.refreshOutputs() }
                } label: {
                    Label("Sound output", systemImage: "hifispeaker.2")
                }
                .help("Choose speakers, Bluetooth headphones or AirPlay")

                RoutePicker()
                    .frame(width: 30, height: 22)
                    .help("AirPlay and Bluetooth")

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen")
            }
        }
    }
}

private struct Notice: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(text).multilineTextAlignment(.center)
            Button(button, action: action)
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MetalView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Apple's AirPlay / Bluetooth picker button.
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var key = ""

    var body: some View {
        Form {
            Section("AI story") {
                Toggle("Write stories with Claude when a key is set", isOn: $engine.useAI)
                SecureField("Claude API key", text: $key)
                HStack {
                    Button("Save key") { engine.saveAPIKey(key); key = "" }
                    Button("Remove key") { engine.saveAPIKey(""); key = "" }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
                Text(engine.hasAPIKey ? "A key is saved. Each new song costs a few cents, and stories are remembered so replays are free."
                                      : "No key saved. Stories come from the free built-in reader.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Forget saved stories") { engine.clearStories() }
            }
            Section("Display") {
                Toggle("Show the song name for a few seconds", isOn: $engine.showSongTitle)
                Picker("Color the note lines", selection: $engine.noteColors) {
                    ForEach(NoteColors.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
