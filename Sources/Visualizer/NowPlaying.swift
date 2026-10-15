import AppKit
import AVFoundation
import Foundation
import ShazamKit

struct TrackInfo: Equatable {
    enum Source: String { case music = "Apple Music", spotify = "Spotify", browser = "Browser", shazam = "Shazam" }

    var title: String
    var artist: String?
    var duration: Double?
    var position: Double?
    var source: Source

    var key: String { "\(artist ?? "") – \(title)".lowercased() }
    var display: String { artist.map { "\(title) · \($0)" } ?? title }
}

/// Keeps a running song position between updates.
struct SongClock {
    private var base: Double?
    private var reference: Double = 0

    mutating func sync(_ position: Double?) {
        base = position
        reference = ProcessInfo.processInfo.systemUptime
    }

    var position: Double? {
        guard let base else { return nil }
        return base + (ProcessInfo.processInfo.systemUptime - reference)
    }
}

/// Asks Apple Music, Spotify, Safari and Chrome what is playing (needs Automation permission).
final class NowPlayingWatcher {
    var onUpdate: ((TrackInfo?) -> Void)?

    private let queue = DispatchQueue(label: "visualizer.nowplaying")
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        queue.async { [weak self] in
            let info = Self.query(running: running)
            DispatchQueue.main.async { self?.onUpdate?(info) }
        }
    }

    private static func query(running: Set<String>) -> TrackInfo? {
        if running.contains("com.spotify.client"), let lines = run("""
            tell application "Spotify"
                if player state is playing then
                    return (name of current track) & linefeed & (artist of current track) & linefeed & ((duration of current track) / 1000) & linefeed & (player position)
                end if
            end tell
            return ""
            """), lines.count >= 4 {
            return TrackInfo(title: lines[0], artist: lines[1], duration: number(lines[2]), position: number(lines[3]), source: .spotify)
        }
        if running.contains("com.apple.Music"), let lines = run("""
            tell application "Music"
                if player state is playing then
                    return (name of current track) & linefeed & (artist of current track) & linefeed & (duration of current track) & linefeed & (player position)
                end if
            end tell
            return ""
            """), lines.count >= 4 {
            return TrackInfo(title: lines[0], artist: lines[1], duration: number(lines[2]), position: number(lines[3]), source: .music)
        }
        for (bundle, script) in [
            ("com.apple.Safari", """
                tell application "Safari"
                    if (count of windows) > 0 then return name of current tab of front window
                end tell
                return ""
                """),
            ("com.google.Chrome", """
                tell application "Google Chrome"
                    if (count of windows) > 0 then return title of active tab of front window
                end tell
                return ""
                """),
        ] where running.contains(bundle) {
            if let lines = run(script), let title = lines.first, let song = youTubeSong(from: title) {
                return TrackInfo(title: song, artist: nil, duration: nil, position: nil, source: .browser)
            }
        }
        return nil
    }

    /// "(3) Artist - Song (Official Video) - YouTube" → "Artist - Song"
    static func youTubeSong(from title: String) -> String? {
        guard title.hasSuffix(" - YouTube") || title.hasSuffix(" - YouTube Music") else { return nil }
        var song = title
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
        song = song.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        song = song.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*(official|video|lyric|audio|visuali[sz]er|hd|4k|live|remaster)[^\)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        song = song.trimmingCharacters(in: .whitespaces)
        return song.isEmpty ? nil : song
    }

    private static func run(_ source: String) -> [String]? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let result = script.executeAndReturnError(&error).stringValue,
              !result.isEmpty else { return nil }
        return result.components(separatedBy: .newlines)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// Identifies whatever is playing by listening, for sources that can't tell us (games, videos, other apps).
final class ShazamMatcher: NSObject, SHSessionDelegate {
    var onMatch: ((TrackInfo) -> Void)?
    var enabled = false

    private let session = SHSession()
    private let queue = DispatchQueue(label: "visualizer.shazam")
    private var format: AVAudioFormat?
    private var failed = false

    override init() {
        super.init()
        session.delegate = self
    }

    /// Called on the audio thread.
    func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard enabled, !failed, count > 0 else { return }
        let copy = Array(UnsafeBufferPointer(start: samples, count: count))
        queue.async { [weak self] in
            guard let self else { return }
            if self.format?.sampleRate != sampleRate {
                self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            }
            guard let format = self.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            copy.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
            }
            self.session.matchStreamingBuffer(buffer, at: nil)
        }
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first, let title = item.title else { return }
        let info = TrackInfo(title: title, artist: item.artist, duration: nil,
                             position: item.predictedCurrentMatchOffset, source: .shazam)
        DispatchQueue.main.async { self.onMatch?(info) }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        guard let error = error as NSError? else { return }
        // No match is normal; anything else (e.g. the service isn't available to this build) means stop trying.
        if error.domain == SHErrorDomain, error.code == SHError.Code.matchAttemptFailed.rawValue {
            NSLog("Visualizer: Shazam unavailable: \(error.localizedDescription)")
            failed = true
        }
    }
}
