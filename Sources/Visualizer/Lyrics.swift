import Foundation

struct LyricLine: Codable, Equatable {
    var time: Double
    var text: String
}

/// Fetches time-synced lyrics from LRCLIB (free, no key needed).
final class LyricsService {
    private struct Entry: Decodable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    func fetch(title: String, artist: String?, duration: Double?) async throws -> [LyricLine] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        if let artist, !artist.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
        } else {
            components.queryItems = [URLQueryItem(name: "q", value: title)]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Visualizer/1.0 (https://github.com/RichardNasty/visualizer)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard !entries.isEmpty else { return [] }

        func distance(_ entry: Entry) -> Double {
            guard let duration, let other = entry.duration else { return 0 }
            return abs(duration - other)
        }
        let candidates = entries.filter { $0.instrumental != true }
        if let synced = candidates.filter({ $0.syncedLyrics?.isEmpty == false && distance($0) < 8 })
            .min(by: { distance($0) < distance($1) }), let text = synced.syncedLyrics {
            let lines = Self.parseLRC(text)
            if !lines.isEmpty { return lines }
        }
        if let plain = candidates.first(where: { $0.plainLyrics?.isEmpty == false }), let text = plain.plainLyrics {
            return Self.spread(text, duration: duration ?? plain.duration ?? 200)
        }
        return []
    }

    /// Parses "[01:23.45] words" lines. Lines with several stamps are repeated.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var result: [LyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                times.append(minutes * 60 + seconds)
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { result.append(LyricLine(time: time, text: words)) }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Unsynced lyrics: spread lines evenly across the song, skipping a short intro.
    static func spread(_ text: String, duration: Double) -> [LyricLine] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return [] }
        let start = min(15, duration * 0.08)
        let step = max(1.5, (duration - start - 10) / Double(lines.count))
        return lines.enumerated().map { LyricLine(time: start + Double($0.offset) * step, text: $0.element) }
    }
}
