// GenderRefinement — two-pass "translate fast, fix gender where it matters".
//
// Why: the decode wall means the strong 12B is too slow to translate everything
// (~8.5 min/30 min), and the fast 7B translates everything in ~5 min but gets
// Hebrew gender wrong on ~1 in 4 gendered lines (it can't reliably infer WHO is
// speaking, and chokes on terse `[s=m a=f]` tags). But most lines don't need gender
// reasoning at all. So:
//
//   Pass 1 (fast, 7B): translate EVERY line, gender-naive.
//   Flag:              mark lines whose Hebrew gender depends on the speaker/addressee
//                      — i.e. lines with 1st/2nd-person reference. 3rd-person and
//                      neutral lines are gender-safe and skip pass 2 entirely.
//   Pass 2 (strong 12B): for each scene, re-resolve ONLY the flagged lines against
//                      the surrounding context and fix gender in place.
//
// The expensive model thus decodes only the gendered subset, with full scene context
// (the spec's "scene relation"), while the fast model carries the bulk.

import Foundation

public enum GenderRefinement {
    /// Does this source line's correct Hebrew inflection depend on the speaker's or
    /// addressee's gender? True when it references 1st or 2nd person (Hebrew inflects
    /// present-tense verbs, adjectives and 2nd-person pronouns by gender). Deliberately
    /// generous — over-flagging only costs a little pass-2 prefill; missing a gendered
    /// line costs correctness.
    public static func needsGenderResolution(_ source: String) -> Bool {
        let s = " " + source.lowercased()
            .replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression) + " "
        let markers = [
            " i ", " i'm ", " im ", " i've ", " ive ", " i'll ", " ill ", " i'd ",
            " me ", " my ", " mine ", " myself ", " we ", " our ", " us ",
            " you ", " you're ", " youre ", " your ", " yours ", " you've ",
            " you'll ", " youll ", " yourself ", " yourselves ",
        ]
        return markers.contains { s.contains($0) }
    }

    /// Local indices (0-based) of a packet's lines that need gender resolution.
    public static func flaggedLocals(_ lines: [String]) -> [Int] {
        lines.enumerated().compactMap { needsGenderResolution($1) ? $0 : nil }
    }

    public struct RefineStats: Sendable, Codable {
        public var totalLines: Int = 0
        public var flaggedLines: Int = 0
        public var correctedLines: Int = 0
        public init() {}
    }

    /// Pass 2: given a packet's source + pass-1 Hebrew, ask the strong model to fix
    /// gender ONLY on the flagged lines, using the whole scene for who-speaks-to-whom.
    /// Returns corrected Hebrew keyed by the packet's LOCAL index (only changed lines).
    public static func correctPacket(
        sourceLines: [String],
        pass1Hebrew: [String],
        flaggedLocals: [Int],
        targetLang: String,
        knownCharacters: [String: String],
        chat: LlamaChat
    ) async throws -> [Int: String] {
        guard !flaggedLocals.isEmpty else { return [:] }
        let wanted = flaggedLocals.map { String($0 + 1) }.joined(separator: ", ")
        var parts: [String] = []
        parts.append("""
        You are a Hebrew subtitle editor. Below is a short scene: each line shows the \
        original English and a draft \(LanguageName.of(targetLang)) translation. The draft may use the \
        WRONG grammatical gender OR number for the speaker or the person being addressed. Work \
        out who is speaking to whom from the whole scene, then output a corrected \
        \(LanguageName.of(targetLang)) translation ONLY for lines numbered: \(wanted). A vocative name (the \
        person addressed, e.g. "…, Mel Brooks!") fixes the addressee to that single person's \
        gender and SINGULAR 2nd-person forms; a recognizable real person keeps their real-world \
        gender. Keep the meaning and wording; change only what gender/number requires (verbs, \
        adjectives, 1st/2nd-person pronouns, imperatives). Output one line per requested number \
        as "<number>. <corrected text>". No notes.
        """)
        if !knownCharacters.isEmpty {
            let list = knownCharacters.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("KNOWN CHARACTER GENDERS: \(list)")
        }
        parts.append("--- SCENE (english => draft) ---")
        for (i, src) in sourceLines.enumerated() {
            let he = i < pass1Hebrew.count ? pass1Hebrew[i] : ""
            parts.append("\(i + 1). \(src)  =>  \(he)")
        }
        parts.append("--- CORRECTIONS (only \(wanted)) ---")
        let prompt = parts.joined(separator: "\n")

        let raw = try await chat.complete(
            system: nil, user: prompt,
            maxTokens: max(120, flaggedLocals.count * 40 + 80), temperature: 0.2)
        let parsed = DictaLMTranslator.parseNumbered(raw, expected: sourceLines.count)
        var out: [Int: String] = [:]
        for local0 in flaggedLocals where !parsed[local0].isEmpty {
            out[local0] = parsed[local0]
        }
        return out
    }
}
