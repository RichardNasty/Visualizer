import AppKit
import Combine
import CoreAudio
import Foundation

/// Wires everything together: audio in → analysis → song detection → lyrics → story → visuals.
/// Used from the main thread only.
final class Engine: ObservableObject {
    @Published var songTitle = ""
    @Published var status = "Listening…"
    @Published var overlayVisible = true
    @Published var problem: String?
    @Published var noSound = false
    @Published var outputs: [OutputDevice] = []
    @Published var currentOutput = AudioObjectID(0)

    @Published var showSongTitle = UserDefaults.standard.object(forKey: "showSongTitle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSongTitle, forKey: "showSongTitle") }
    }
    @Published var useAI = UserDefaults.standard.object(forKey: "useAI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useAI, forKey: "useAI") }
    }
    @Published var hasAPIKey = Keychain.load() != nil
    @Published var noteColors = NoteColors(rawValue: UserDefaults.standard.string(forKey: "noteColors") ?? "") ?? .byOctave {
        didSet {
            UserDefaults.standard.set(noteColors.rawValue, forKey: "noteColors")
            renderer?.noteColors = noteColors
        }
    }

    let renderer: Renderer?
    private let analyzer = AudioAnalyzer()
    private let director = Director()
    private let tap = SystemAudioTap()
    private let watcher = NowPlayingWatcher()
    private let shazam = ShazamMatcher()
    private let lyrics = LyricsService()
    private let stories = StoryService()

    private var clock = SongClock()
    private var track: TrackInfo?
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var overlayToken = 0
    private var silentSince: Double?
    private var lastPlayerUpdate: Double = -100
    private var latestAudio = AudioFeatures()

    init() {
        do {
            renderer = try Renderer()
        } catch {
            renderer = nil
            problem = error.localizedDescription
        }
        renderer?.frameSource = { [weak self] dt in
            guard let self else { return (SceneState(), AudioFeatures()) }
            let now = ProcessInfo.processInfo.systemUptime
            let audio = self.analyzer.analyze(time: now)
            self.latestAudio = audio
            return (self.director.update(dt: dt, audio: audio), audio)
        }
        director.songPosition = { [weak self] in self?.clock.position }
        renderer?.noteColors = noteColors
    }

    func start() {
        guard !started else { return }
        started = true

        let analyzer = self.analyzer
        let shazam = self.shazam
        tap.onSamples = { samples, count, rate in
            analyzer.push(samples, count: count, sampleRate: rate)
            shazam.feed(samples, count: count, sampleRate: rate)
        }
        startTap()

        refreshOutputs()
        AudioDevices.observeChanges { [weak self] in
            guard let self else { return }
            let previous = self.currentOutput
            self.refreshOutputs()
            // The capture follows the sound output, so rebuild it when the output changes.
            if previous != self.currentOutput { self.startTap() }
        }

        watcher.onUpdate = { [weak self] info in self?.playerUpdate(info) }
        shazam.onMatch = { [weak self] info in self?.shazamMatch(info) }
        watcher.start()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkSilence() }
        flashOverlay()
    }

    private func startTap() {
        do {
            try tap.start()
            if problem?.hasPrefix("Can't hear") == true { problem = nil }
        } catch {
            problem = "Can't hear your Mac's audio: \(error.localizedDescription). Allow Visualizer under System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app."
        }
    }

    // MARK: - Sound output

    func refreshOutputs() {
        outputs = AudioDevices.outputs()
        currentOutput = AudioDevices.defaultOutput()
    }

    func select(_ device: OutputDevice) {
        AudioDevices.setDefaultOutput(device.id)
        refreshOutputs()
    }

    // MARK: - Song detection

    private func playerUpdate(_ info: TrackInfo?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let info else {
            // Nothing in Music/Spotify/a browser: let Shazam listen instead.
            shazam.enabled = !latestAudio.silent
            if track?.source != .shazam, now - lastPlayerUpdate > 6, track != nil {
                track = nil
                songTitle = ""
                clock.sync(nil)
                director.story = nil
                loadTask?.cancel()
                status = "Listening…"
            }
            return
        }
        lastPlayerUpdate = now
        if info.source == .browser {
            // A browser tab gives us the name but not the position; Shazam can supply that.
            shazam.enabled = true
            if track?.source == .shazam { return }
        } else {
            shazam.enabled = false
        }
        if info.key != track?.key {
            songChanged(info)
        } else if let position = info.position {
            clock.sync(position)
        }
    }

    private func shazamMatch(_ info: TrackInfo) {
        if info.key != track?.key { songChanged(info) }
        clock.sync(info.position)
    }

    private func songChanged(_ info: TrackInfo) {
        track = info
        songTitle = info.display
        clock.sync(info.position ?? 0)
        director.story = nil
        status = "Finding the lyrics…"
        flashOverlay()

        loadTask?.cancel()
        let useAI = self.useAI
        loadTask = Task { [weak self, lyrics = self.lyrics, stories = self.stories] in
            let lines = (try? await lyrics.fetch(title: info.title, artist: info.artist, duration: info.duration)) ?? []
            if Task.isCancelled { return }
            if !lines.isEmpty, useAI, Keychain.load() != nil {
                await MainActor.run { self?.status = "Writing the story…" }
            }
            let outcome = await stories.story(for: info, lyrics: lines, useAI: useAI)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.track?.key == info.key else { return }
                switch outcome {
                case let .ai(story):
                    self.director.story = story
                    self.status = "Story: \(story.title)"
                case let .simple(story, reason: reason):
                    self.director.story = story
                    self.status = reason.map { "Simple story (\($0))" } ?? "Simple story"
                case .none:
                    self.status = lines.isEmpty ? "No lyrics found, improvising" : "Improvising"
                }
                self.flashOverlay()
            }
        }
    }

    // MARK: - UI helpers

    func flashOverlay() {
        overlayVisible = true
        overlayToken += 1
        let token = overlayToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            if self?.overlayToken == token { self?.overlayVisible = false }
        }
    }

    private func checkSilence() {
        let now = ProcessInfo.processInfo.systemUptime
        if latestAudio.silent {
            if silentSince == nil { silentSince = now }
            noSound = now - (silentSince ?? now) > 15
        } else {
            silentSince = nil
            noSound = false
        }
    }

    func saveAPIKey(_ key: String) {
        Keychain.save(key)
        hasAPIKey = Keychain.load() != nil
        if let track { songChanged(track) }
    }

    func clearStories() {
        stories.clearCache()
        if let track { songChanged(track) }
    }
}
