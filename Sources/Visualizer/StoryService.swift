import Foundation
import Security

enum Keychain {
    private static let service = "Visualizer"
    private static let account = "anthropic-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func save(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Produces the hidden story for a song: Claude when a key is set, the simple storyteller otherwise.
/// Stories are cached on disk so each song is only written once.
final class StoryService {
    enum Outcome {
        case ai(Story)
        case simple(Story, reason: String?)
        case none
    }

    static let model = "claude-opus-5-5"

    private let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Visualizer/Stories", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func story(for track: TrackInfo, lyrics: [LyricLine], useAI: Bool) async -> Outcome {
        guard !lyrics.isEmpty else { return .none }

        let apiKey = useAI ? Keychain.load() : nil
        if apiKey != nil, let cached = loadCache(track), cached.author == "claude" {
            return .ai(cached)
        }
        if let apiKey {
            do {
                let story = try await askClaude(track: track, lyrics: lyrics, apiKey: apiKey)
                saveCache(story, track)
                return .ai(story)
            } catch {
                NSLog("Visualizer: AI story failed: \(error.localizedDescription)")
                if let story = SimpleStoryteller.story(title: track.title, lines: lyrics) {
                    return .simple(story, reason: error.localizedDescription)
                }
                return .none
            }
        }
        if let story = SimpleStoryteller.story(title: track.title, lines: lyrics) {
            return .simple(story, reason: nil)
        }
        return .none
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Claude

    struct StoryError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func prompt(track: TrackInfo, lyrics: [LyricLine]) -> String {
        let actions = StoryAction.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        let worlds = StoryWorld.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        let lines = lyrics.prefix(240).map { String(format: "[%.2f] %@", $0.time, $0.text.isEmpty ? "(instrumental)" : $0.text) }
            .joined(separator: "\n")
        return """
        Song: \(track.title)\(track.artist.map { " by \($0)" } ?? "")

        Timestamped lyrics (seconds):
        \(lines)

        Read the lyrics closely and find the story underneath them: who is in it, what they want, what happens between them, and how it ends.

        Cast 1 to 3 characters (people, forces or feelings in the song). Each becomes an abstract glowing shape: one of sphere, cube, torus, tetrahedron, octahedron, icosahedron. Give each a hue from 0 to 1 (0 red, 0.08 orange, 0.15 yellow, 0.33 green, 0.5 cyan, 0.62 blue, 0.75 violet, 0.9 pink) that suits who they are.

        Then write exactly one beat for every lyric line, using that line's timestamp as "time". Each beat stages what is happening in the story at that moment with one action:
        \(actions)

        For each beat also give:
        - actors: the indexes (0-based) of the characters taking part
        - valence: -1 (despair) to 1 (joy)
        - energy: 0 (stillness) to 1 (explosive)
        - hue: the colour of the whole world in that moment, 0 to 1
        - world: which of three visual worlds the scene happens in:
        \(worlds)
          Keep the same world through a section (a verse, a chorus, a bridge) and change world when the song moves to a new section, so each chapter of the story has its own look. Choruses usually belong in xbox.

        Give the story an arc that builds, turns and resolves across the song. Repeated choruses should echo each other with the same staging, and the final beats should land the ending.

        Respond with only a JSON object and nothing else, in this shape:
        {"title": "a short name for the story", "characters": [{"name": "...", "shape": "torus", "hue": 0.6}], "beats": [{"time": 12.3, "action": "approach", "actors": [0, 1], "valence": 0.2, "energy": 0.5, "hue": 0.6, "world": "magnetosphere"}]}
        """
    }

    private func askClaude(track: TrackInfo, lyrics: [LyricLine], apiKey: String) async throws -> Story {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": "You are the choreographer for an abstract music visualizer. You turn a song's lyrics into a hidden visual story told only through the movement of glowing 3D shapes, particle clouds and light. No words or pictures are ever shown, so the story has to live in motion, distance, colour and energy.",
            "messages": [["role": "user", "content": Self.prompt(track: track, lyrics: lyrics)]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            if status == 401 { throw StoryError(message: "The Claude API key was not accepted.") }
            throw StoryError(message: "Claude request failed: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw StoryError(message: "Claude declined this song.")
        }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return try Self.parse(text)
    }

    static func parse(_ text: String) throws -> Story {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw StoryError(message: "Claude's reply had no story in it.")
        }
        let data = Data(text[start...end].utf8)
        var story = try JSONDecoder().decode(Story.self, from: data)
        story.author = "claude"
        guard let clean = story.sanitized() else { throw StoryError(message: "Claude's story was empty.") }
        return clean
    }

    // MARK: - Cache

    private func cacheURL(_ track: TrackInfo) -> URL {
        let safe = track.key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return cacheDirectory.appendingPathComponent(String(safe.prefix(120)) + ".json")
    }

    private func loadCache(_ track: TrackInfo) -> Story? {
        guard let data = try? Data(contentsOf: cacheURL(track)) else { return nil }
        return try? JSONDecoder().decode(Story.self, from: data)
    }

    private func saveCache(_ story: Story, _ track: TrackInfo) {
        if let data = try? JSONEncoder().encode(story) { try? data.write(to: cacheURL(track)) }
    }
}
