// FixtureTranscript — load the deterministic test transcript (scripts/make_test_fixture.py).
//
// Lets the v0 CLI drive the back half of the pipeline (segment → translate →
// assemble) deterministically, with known speakers/genders/timing and reference
// translations — BEFORE real WhisperKit ASR and the real LLM are wired. The lines
// flow through the SAME BibleAwareTranslator interface the production path uses,
// so the bible/gender prompt injection is exercised now.

import Foundation

public struct FixtureTranscript: Codable, Sendable {
    /// Lightweight DTO for fixture characters (plain camelCase keys), kept
    /// separate from the snake_case wire model so the fixture format is simple.
    public struct FixtureCharacter: Codable, Sendable {
        public var id: String
        public var canonicalName: String
        public var gender: Gender
        public var nameTranslations: [String: String]

        /// Convert to the engine model — these are user-locked, fully-confident
        /// hand-authored entries.
        public func toCharacter() -> Character {
            Character(id: id, canonicalName: canonicalName, gender: gender,
                      nameTranslations: nameTranslations, aliases: [],
                      relationships: [], confidence: 1.0, userCorrected: true)
        }
    }

    public struct Line: Codable, Sendable {
        public var speakerId: String?
        public var addresseeId: String?
        public var startMs: Int
        public var endMs: Int
        public var text: String
        public var translations: [String: String]
    }

    public var lang: String
    public var durationMs: Int
    public var characters: [FixtureCharacter]
    public var lines: [Line]

    public static func load(path: String) throws -> FixtureTranscript {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(FixtureTranscript.self, from: data)
    }

    /// Engine-model characters.
    public func engineCharacters() -> [Character] { characters.map { $0.toCharacter() } }

    /// Index characters by id for speaker/addressee resolution.
    public func charactersById() -> [String: Character] {
        Dictionary(uniqueKeysWithValues: engineCharacters().map { ($0.id, $0) })
    }

    /// Build the hand-stubbed bible for the contextual parent.
    public func bible(contextualParentId: String = "fixture-parent") -> CharacterBible {
        CharacterBible(id: "fixture-bible", contextualParentId: contextualParentId,
                       version: 1, lockedByUser: true, characters: engineCharacters())
    }

    /// Source-language cues (text replaced by the translator in place).
    public func sourceCues() -> [SubtitleCue] {
        lines.enumerated().map { i, l in
            SubtitleCue(index: i + 1, startMs: l.startMs, endMs: l.endMs,
                        text: l.text, speakerId: l.speakerId)
        }
    }

    /// Per-line translator context (speaker/addressee/glossary) for prompt building.
    public func lineContext(for line: Line) -> LineContext {
        let byId = charactersById()
        return LineContext(
            sourceText: line.text,
            speaker: line.speakerId.flatMap { byId[$0] },
            addressee: line.addresseeId.flatMap { byId[$0] },
            relevantCharacters: engineCharacters()
        )
    }
}

/// A translator that returns the fixture's reference translations, so the player
/// path can be verified with REAL target-language text before the LLM lands.
/// It still builds the real bible-aware prompt (for inspection) via DictaLM's
/// builder, keeping the interface identical to production.
public struct FixtureTranslator: BibleAwareTranslator {
    private let bySource: [String: [String: String]] // sourceText -> {lang: text}
    private let promptBuilder: DictaLMTranslator

    public init(transcript: FixtureTranscript, modelPaths: ModelPaths) {
        self.bySource = Dictionary(
            transcript.lines.map { ($0.text, $0.translations) },
            uniquingKeysWith: { a, _ in a }
        )
        self.promptBuilder = DictaLMTranslator(modelPaths: modelPaths)
    }

    public func buildPrompt(line: LineContext, targetLang: String) -> String {
        promptBuilder.buildPrompt(line: line, targetLang: targetLang)
    }

    public func translate(line: LineContext, targetLang: String) async throws -> String {
        bySource[line.sourceText]?[targetLang] ?? "[\(targetLang)] \(line.sourceText)"
    }
}
