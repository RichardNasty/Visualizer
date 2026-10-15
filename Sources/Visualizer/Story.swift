import Foundation

/// The hidden "staging" for one moment of a song. Never shown as text: it only steers motion.
enum StoryAction: String, CaseIterable, Codable {
    case drift, approach, embrace, separate, chase, orbit, rise, fall
    case shatter, bloom, hide, reveal, storm, calm

    var meaning: String {
        switch self {
        case .drift: return "wandering, unresolved, searching"
        case .approach: return "drawing closer, longing, attraction"
        case .embrace: return "together, love, union, comfort"
        case .separate: return "apart, loss, distance, goodbye"
        case .chase: return "pursuit, running after or from something"
        case .orbit: return "circling, dancing, routine, obsession"
        case .rise: return "hope, freedom, flying, triumph"
        case .fall: return "sadness, defeat, sinking, giving up"
        case .shatter: return "breaking point, anger, a sudden blow"
        case .bloom: return "joy, opening up, celebration"
        case .hide: return "fear, secrets, shame, loneliness"
        case .reveal: return "realisation, confession, coming into the light"
        case .storm: return "chaos, conflict, overwhelming emotion"
        case .calm: return "peace, stillness, acceptance, breath"
        }
    }
}

/// The three visual worlds the story moves between.
enum StoryWorld: String, CaseIterable, Codable {
    /// Classic iTunes: liquid colour trails and glowing waveform ribbons. Memory, dreaming, reflection.
    case classic
    /// Apple Music Magnetosphere: a glowing particle nebula. Longing, tenderness, building up.
    case magnetosphere
    /// Original Xbox: neon wireframes, tunnels and bursts. Energy, conflict, the big moments.
    case xbox

    var meaning: String {
        switch self {
        case .classic: return "dreamy liquid colour and flowing waveforms: memories, reflection, intimacy, the quiet verses"
        case .magnetosphere: return "a glowing particle nebula: longing, tenderness, hope, things building up"
        case .xbox: return "neon wireframes rushing through a tunnel with bursts of light: energy, conflict, release, the chorus and the climax"
        }
    }

    static func fallback(energy: Double, valence: Double) -> StoryWorld {
        if energy > 0.62 { return .xbox }
        if valence < -0.15 || energy < 0.35 { return .classic }
        return .magnetosphere
    }
}

enum ShapeKind: String, CaseIterable, Codable {
    case sphere, cube, torus, tetrahedron, octahedron, icosahedron
}

struct StoryCharacter: Codable {
    var name: String
    var shape: ShapeKind
    var hue: Double

    enum CodingKeys: String, CodingKey { case name, shape, hue }

    init(name: String, shape: ShapeKind, hue: Double) {
        self.name = name
        self.shape = shape
        self.hue = hue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "?"
        let shapeName = ((try? c.decode(String.self, forKey: .shape)) ?? "").lowercased()
        shape = ShapeKind(rawValue: shapeName) ?? .sphere
        hue = Story.wrap((try? c.decode(Double.self, forKey: .hue)) ?? 0.6)
    }
}

struct StoryBeat: Codable {
    var time: Double
    var action: StoryAction
    var actors: [Int]
    var valence: Double
    var energy: Double
    var hue: Double
    var world: StoryWorld

    enum CodingKeys: String, CodingKey { case time, action, actors, valence, energy, hue, world }

    init(time: Double, action: StoryAction, actors: [Int], valence: Double, energy: Double, hue: Double, world: StoryWorld? = nil) {
        self.time = time
        self.action = action
        self.actors = actors
        self.valence = valence
        self.energy = energy
        self.hue = hue
        self.world = world ?? StoryWorld.fallback(energy: energy, valence: valence)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        let actionName = ((try? c.decode(String.self, forKey: .action)) ?? "").lowercased()
        action = StoryAction(rawValue: actionName) ?? .drift
        actors = (try? c.decode([Int].self, forKey: .actors)) ?? []
        valence = max(-1, min(1, (try? c.decode(Double.self, forKey: .valence)) ?? 0))
        energy = max(0, min(1, (try? c.decode(Double.self, forKey: .energy)) ?? 0.5))
        hue = Story.wrap((try? c.decode(Double.self, forKey: .hue)) ?? 0.6)
        let worldName = ((try? c.decode(String.self, forKey: .world)) ?? "").lowercased()
        world = StoryWorld(rawValue: worldName) ?? StoryWorld.fallback(energy: energy, valence: valence)
    }
}

struct Story: Codable {
    var title: String
    var characters: [StoryCharacter]
    var beats: [StoryBeat]
    var author: String?

    static func wrap(_ hue: Double) -> Double {
        let h = hue.truncatingRemainder(dividingBy: 1)
        return h < 0 ? h + 1 : h
    }

    /// Clean up whatever came back so the director can trust it.
    func sanitized() -> Story? {
        var characters = Array(self.characters.prefix(3))
        if characters.isEmpty {
            characters = [StoryCharacter(name: "one", shape: .icosahedron, hue: 0.08)]
        }
        let beats = self.beats
            .map { beat -> StoryBeat in
                var beat = beat
                beat.actors = beat.actors.filter { $0 >= 0 && $0 < characters.count }
                return beat
            }
            .sorted { $0.time < $1.time }
        guard !beats.isEmpty else { return nil }
        return Story(title: title, characters: characters, beats: beats, author: author)
    }
}

/// A free, offline storyteller: reads each lyric line for feeling and movement words.
enum SimpleStoryteller {
    private static let actionWords: [(StoryAction, [String])] = [
        (.embrace, ["hold", "holding", "together", "kiss", "touch", "arms", "close", "love", "loving", "lover", "forever", "mine", "yours", "home"]),
        (.separate, ["goodbye", "leave", "leaving", "left", "gone", "apart", "away", "without", "miss", "lost", "lose", "alone", "end", "over", "broke"]),
        (.chase, ["run", "running", "chase", "follow", "catch", "after", "faster", "escape", "race"]),
        (.rise, ["fly", "flying", "high", "higher", "sky", "rise", "rising", "up", "heaven", "free", "stars", "light", "sun"]),
        (.fall, ["fall", "falling", "down", "sink", "drown", "drowning", "low", "cry", "crying", "tears", "rain", "cold"]),
        (.shatter, ["break", "breaking", "broken", "fire", "burn", "burning", "explode", "scream", "hate", "kill", "war", "crash"]),
        (.bloom, ["dance", "dancing", "party", "alive", "happy", "smile", "shine", "bright", "celebrate", "summer", "gold"]),
        (.hide, ["hide", "hiding", "secret", "dark", "darkness", "shadow", "afraid", "fear", "scared", "night", "nobody"]),
        (.reveal, ["see", "know", "truth", "realize", "finally", "open", "show", "wake", "awake", "now"]),
        (.storm, ["storm", "wild", "crazy", "chaos", "fight", "thunder", "shake", "loud", "rage"]),
        (.orbit, ["around", "circle", "again", "round", "spin", "spinning", "turn", "turning", "every"]),
        (.approach, ["come", "closer", "want", "need", "waiting", "call", "reach", "find", "toward", "towards"]),
        (.calm, ["slow", "quiet", "peace", "breathe", "still", "rest", "sleep", "dream", "easy", "gentle"]),
    ]
    private static let positive: Set<String> = ["love", "happy", "joy", "light", "sun", "smile", "free", "alive", "beautiful", "good", "best", "dream", "dance", "shine", "bright", "heaven", "hope", "together", "gold", "sweet", "warm", "yes"]
    private static let negative: Set<String> = ["cry", "tears", "pain", "hurt", "sad", "lonely", "alone", "dark", "cold", "lost", "die", "dead", "hate", "broken", "fear", "never", "goodbye", "gone", "wrong", "bad", "rain", "no"]
    private static let energetic: Set<String> = ["run", "fire", "burn", "dance", "fight", "scream", "loud", "wild", "fast", "faster", "crazy", "jump", "shake", "go", "now", "explode", "war"]

    static func story(title: String, lines: [LyricLine]) -> Story? {
        guard !lines.isEmpty else { return nil }
        let characters = [
            StoryCharacter(name: "I", shape: .icosahedron, hue: 0.07),
            StoryCharacter(name: "you", shape: .torus, hue: 0.58),
        ]
        var beats: [StoryBeat] = []
        var previous: StoryAction = .drift
        var repeats = 0
        var mood = 0.0
        // Lines that come back are the chorus: give them the big, energetic world.
        var counts: [String: Int] = [:]
        for line in lines { counts[normalized(line.text), default: 0] += 1 }
        let fallbacks: [StoryAction] = [.approach, .orbit, .drift, .reveal, .chase, .rise, .embrace, .calm]

        for (index, line) in lines.enumerated() {
            let words = line.text.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }

            if words.isEmpty {
                beats.append(StoryBeat(time: line.time, action: .calm, actors: [], valence: mood, energy: 0.2, hue: 0.62, world: .classic))
                continue
            }
            let isChorus = (counts[normalized(line.text)] ?? 0) > 1

            var best: StoryAction?
            var bestScore = 0
            for (action, keys) in actionWords {
                let score = words.filter { keys.contains($0) }.count
                if score > bestScore { best = action; bestScore = score }
            }
            // Keep the story moving: no keyword match, or the same staging three times running, picks something new.
            var action = best ?? fallbacks[index % fallbacks.count]
            repeats = action == previous ? repeats + 1 : 0
            if repeats >= 2 {
                action = fallbacks[(index * 3) % fallbacks.count]
                if action == previous { action = .orbit }
                repeats = 0
            }
            if isChorus, best == nil { action = [.bloom, .orbit, .rise][index % 3] }
            previous = action

            let pos = Double(words.filter { positive.contains($0) }.count)
            let neg = Double(words.filter { negative.contains($0) }.count)
            mood = mood * 0.6 + ((pos - neg) / max(1, pos + neg)) * 0.4
            var energy = 0.35 + 0.15 * Double(words.filter { energetic.contains($0) }.count) + (isChorus ? 0.3 : 0)
            if line.text.contains("!") { energy += 0.2 }
            if line.text == line.text.uppercased(), line.text.count > 3 { energy += 0.2 }

            var actors: [Int] = []
            let set = Set(words)
            if !set.isDisjoint(with: ["we", "us", "our", "together"]) { actors = [0, 1] }
            else if !set.isDisjoint(with: ["you", "your", "you're", "yours"]) { actors = set.isDisjoint(with: ["i", "me", "my", "im"]) ? [1] : [0, 1] }
            else if !set.isDisjoint(with: ["i", "me", "my", "im", "myself"]) { actors = [0] }

            let hue = mood >= 0 ? 0.05 + 0.1 * (1 - mood) : 0.55 + 0.15 * -mood
            if actors.isEmpty { actors = index % 3 == 0 ? [0, 1] : [index % 2] }
            let world: StoryWorld = isChorus ? .xbox : StoryWorld.fallback(energy: min(1, energy), valence: mood)
            beats.append(StoryBeat(time: line.time, action: action, actors: actors, valence: mood, energy: min(1, energy), hue: hue, world: world))
        }
        return Story(title: title, characters: characters, beats: beats, author: "simple").sanitized()
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }
}
