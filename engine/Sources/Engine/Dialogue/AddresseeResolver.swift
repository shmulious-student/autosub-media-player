// AddresseeResolver — decide WHO each line is spoken to, deterministically,
// BEFORE the model ever sees it (handoff §2).
//
// Hebrew inflects 2nd-person forms by the addressee's gender and number
// (אתה/את, תזוז/תזוזי, בטוח/בטוחה) and 1st-person forms by the speaker's. A 7B/12B
// model handed raw dialogue has to GUESS the addressee, and it guesses badly: it
// either misgenders, or — worse — hedges with a dual form (`את/אתה`, `תזוז/תזוזי`),
// which is not Hebrew anyone speaks and is instantly visible as machine output.
//
// So we resolve the addressee OURSELVES wherever the dialogue actually determines
// it, and tell the model the answer instead of asking for one. Five rungs, most
// reliable first; the first that fires wins:
//
//   1. Vocative in the cue     "Danny, move!"            → Danny        0.95
//   2. Direct reply            previous speaker, < 4 s   → that speaker 0.85
//   3. Two-hander scene        only two people present   → the other    0.75
//   4. Group address           "everyone", "guys"        → plural       0.90
//   5. Unknown                 nothing determines it     → neutral      0.00
//
// Rung 5 is the important one: when the dialogue genuinely does not say, we do NOT
// pick a gender at random and we do NOT let the model hedge. We instruct it to
// phrase the line so that gender never surfaces (Hebrew has plenty of room to do
// this — infinitives, impersonal constructions, noun phrases). A wrong guess and a
// slash-hedge are both worse than a neutral sentence.
//
// Everything here is pure and testable: no LLM call, no I/O.

import Foundation

/// Which rung of the ladder produced the addressee.
public enum AddresseeMethod: String, Sendable, Equatable {
    case vocative, directReply, twoHander, groupAddress, unknown
}

/// Grammatical number of the addressee — Hebrew 2nd-person forms need it as much
/// as gender ("you" singular and "you" plural are different words).
public enum GrammaticalNumber: String, Sendable, Equatable {
    case singular, plural, unknown
}

/// The resolved speaker/addressee binding for one cue.
public struct DialogueBinding: Sendable, Equatable {
    /// `SubtitleCue.index` this binding belongs to.
    public var cueIndex: Int
    public var speaker: String?
    public var speakerGender: Gender
    /// Resolved addressee name, or nil for a group / unknown addressee.
    public var addressee: String?
    public var addresseeGender: Gender
    public var addresseeNumber: GrammaticalNumber
    public var method: AddresseeMethod
    /// 0.0 (nothing determined it) … 0.95 (an explicit vocative).
    public var confidence: Double

    public init(cueIndex: Int, speaker: String? = nil, speakerGender: Gender = .unknown,
                addressee: String? = nil, addresseeGender: Gender = .unknown,
                addresseeNumber: GrammaticalNumber = .unknown,
                method: AddresseeMethod = .unknown, confidence: Double = 0) {
        self.cueIndex = cueIndex
        self.speaker = speaker
        self.speakerGender = speakerGender
        self.addressee = addressee
        self.addresseeGender = addresseeGender
        self.addresseeNumber = addresseeNumber
        self.method = method
        self.confidence = confidence
    }

    /// True when the model must avoid gendered 2nd-person forms entirely.
    public var needsNeutralPhrasing: Bool {
        addresseeNumber != .plural && (addresseeGender == .unknown || addresseeGender == .nb)
    }
}

public enum AddresseeResolver {
    public struct Config: Sendable {
        /// A cue starting within this long after the previous one is treated as a
        /// direct reply to whoever spoke it (rung 2).
        public var replyGapMs: Int
        public init(replyGapMs: Int = 4_000) { self.replyGapMs = replyGapMs }
        public static let `default` = Config()
    }

    /// Resolve bindings for every cue, scene by scene.
    ///
    /// - `characters`: name → "m"/"f"/"u", the script-wide gender map (DialogueAnalyzer
    ///   output merged with the series bible). Also acts as the roster that vocative
    ///   detection matches against, so stray capitalized words are never read as names.
    /// - `scenes`: from `SceneSegmenter`. Rung 3 needs them: "only two people are
    ///   present" is a statement about a SCENE, not about the whole film.
    public static func resolve(
        cues: [SubtitleCue],
        characters: [String: String] = [:],
        scenes: [DialogueScene]? = nil,
        config: Config = .default
    ) -> [DialogueBinding] {
        guard !cues.isEmpty else { return [] }
        let scenes = scenes ?? SceneSegmenter.segment(cues: cues)
        var out = [DialogueBinding](repeating: DialogueBinding(cueIndex: 0), count: cues.count)

        for scene in scenes {
            let cast = scene.speakers
            for i in scene.range {
                out[i] = resolveOne(
                    cues: cues, at: i, sceneRange: scene.range, sceneCast: cast,
                    characters: characters, config: config)
            }
        }
        return out
    }

    private static func resolveOne(
        cues: [SubtitleCue], at i: Int, sceneRange: Range<Int>, sceneCast: Set<String>,
        characters: [String: String], config: Config
    ) -> DialogueBinding {
        let cue = cues[i]
        let speaker = cue.speakerId
        var b = DialogueBinding(
            cueIndex: cue.index, speaker: speaker, speakerGender: gender(speaker, characters))

        // Rung 1 — an explicit vocative names the addressee outright.
        if let name = vocative(in: cue.text, roster: Set(characters.keys)) {
            b.addressee = name
            b.addresseeGender = gender(name, characters)
            b.addresseeNumber = .singular
            b.method = .vocative
            b.confidence = 0.95
            return b
        }

        // Rung 4 — a group address. Checked before the single-addressee rungs
        // because "Come on, everyone" is plural no matter who spoke last.
        if let g = groupGender(in: cue.text) {
            b.addressee = nil
            b.addresseeGender = g
            b.addresseeNumber = .plural
            b.method = .groupAddress
            b.confidence = 0.90
            return b
        }

        // Rung 2 — a quick turn after a DIFFERENT speaker is a reply to them.
        if i > sceneRange.lowerBound {
            let prev = cues[i - 1]
            if let prevSpeaker = prev.speakerId, prevSpeaker != speaker,
               cue.startMs - prev.endMs <= config.replyGapMs {
                b.addressee = prevSpeaker
                b.addresseeGender = gender(prevSpeaker, characters)
                b.addresseeNumber = .singular
                b.method = .directReply
                b.confidence = 0.85
                return b
            }
        }

        // Rung 3 — a two-hander scene: if only two people are in it and one is
        // speaking, the other is being addressed. Process of elimination.
        if sceneCast.count == 2, let speaker, sceneCast.contains(speaker),
           let other = sceneCast.first(where: { $0 != speaker }) {
            b.addressee = other
            b.addresseeGender = gender(other, characters)
            b.addresseeNumber = .singular
            b.method = .twoHander
            b.confidence = 0.75
            return b
        }

        // Rung 5 — nothing determines it. Neutral phrasing, never a guess or a hedge.
        b.method = .unknown
        b.confidence = 0
        return b
    }

    // MARK: - Rung 1: vocatives

    /// The name being ADDRESSED in this line, if the line names one.
    ///
    /// A vocative is set off by a comma — leading ("Danny, move!", "Hey, Danny!") or
    /// trailing ("Move, Danny!", "Are you sure, Dr. Ross?"). Candidates must be on
    /// the roster when we have one; without a roster we fall back to the name-shape
    /// heuristic, so an unlisted character still resolves.
    public static func vocative(in text: String, roster: Set<String> = []) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[-–—]\\s*", with: "", options: .regularExpression)
        guard !line.isEmpty else { return nil }

        // Trailing: "…, Danny!"  /  "…, Mel Brooks."
        if let m = firstMatch(line, #",\s*([A-Z][\w'’.-]*(?:\s+[A-Z][\w'’.-]*){0,2})\s*[!?.…]*$"#),
           let name = candidate(m, roster: roster) {
            return name
        }
        // Leading: "Danny, move!"  —  including after a greeting: "Hey, Danny, move!"
        if let m = firstMatch(line, #"^(?:(?:[Hh]ey|[Hh]i|[Hh]ello|[Yy]o|[Oo]kay|[Oo]k|[Ww]ell|[Ll]ook|[Ll]isten|[Pp]lease|[Ee]xcuse me|[Ss]orry)\s*,?\s*)*([A-Z][\w'’.-]*(?:\s+[A-Z][\w'’.-]*){0,2})\s*,"#),
           let name = candidate(m, roster: roster) {
            return name
        }
        return nil
    }

    /// Accept a regex capture as a vocative name: on the roster (case-insensitively),
    /// or name-shaped when there is no roster at all.
    private static func candidate(_ raw: String, roster: Set<String>) -> String? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard !name.isEmpty, !stopWords.contains(name.lowercased()) else { return nil }
        if !roster.isEmpty {
            return roster.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return DialogueAnalyzer.looksLikeName(name) ? name : nil
    }

    /// Capitalized words that open sentences but are never vocatives.
    private static let stopWords: Set<String> = [
        "i", "he", "she", "it", "we", "they", "you", "the", "a", "an", "and", "but",
        "so", "yes", "no", "not", "if", "then", "what", "why", "how", "when", "where",
        "who", "this", "that", "there", "here", "god", "jesus", "christ", "sir",
        "ma'am", "man", "guys", "everyone", "okay", "ok", "oh", "hey", "hi", "hello",
        "please", "thanks", "sorry", "wait", "stop", "come", "go", "well", "now",
    ]

    // MARK: - Rung 4: group address

    /// The addressee gender for a line addressed to a GROUP, or nil if it isn't one.
    ///
    /// Hebrew has no gender-neutral plural: a mixed or unspecified group takes the
    /// MASCULINE plural, which is the language's own convention, not a coin flip.
    /// An explicitly all-female address ("ladies", "girls") takes the feminine plural.
    public static func groupGender(in text: String) -> Gender? {
        let s = normalized(text)
        if feminineGroupMarkers.contains(where: { s.contains(" \($0) ") }) { return .f }
        if groupMarkers.contains(where: { s.contains(" \($0) ") }) { return .m }
        return nil
    }

    private static let groupMarkers: [String] = [
        "everyone", "everybody", "guys", "y'all", "yall", "you all", "all of you",
        "folks", "team", "gentlemen", "boys", "men", "people", "listen up",
        "both of you", "you two", "you lot", "children", "kids", "class",
    ]

    private static let feminineGroupMarkers: [String] = [
        "ladies", "girls", "women",
    ]

    // MARK: - Helpers

    private static func gender(_ name: String?, _ characters: [String: String]) -> Gender {
        guard let name else { return .unknown }
        let hit = characters.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        switch hit?.value.lowercased() {
        case "m": return .m
        case "f": return .f
        case "nb": return .nb
        default: return .unknown
        }
    }

    /// Lowercased, punctuation-stripped, space-padded — so `" guys "` matches on
    /// word boundaries without a regex per marker.
    private static func normalized(_ text: String) -> String {
        " " + text.lowercased()
            .replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression) + " "
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
}
