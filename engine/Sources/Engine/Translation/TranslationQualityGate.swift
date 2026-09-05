// TranslationQualityGate — prove that a FASTER approach did not sacrifice the
// product's core promise: correct Hebrew gendered grammar (SPEC §4).
//
// The risk with the `lean` approach is concrete: it drops the explicit per-line
// `sg`/`ag` gender fields that `fused-json` makes the model emit. The open question
// is whether forcing that bookkeeping actually IMPROVES gender correctness, or
// whether the model decides gender implicitly anyway (it must — "אני עייפה" vs
// "אני עייף" IS the gender decision). This gate answers it empirically.
//
// The probe is a short continuous scene: names establish each character's gender,
// then NAME-LESS gendered lines follow whose correct Hebrew inflection is fully
// determined by WHO is speaking / being addressed. The model has to track identity
// across lines (the "scene relation" the spec cares about) and inflect correctly.
// Expected/forbidden tokens are standard textbook Hebrew inflections, not invented
// content: עייף(m)/עייפה(f), שמח(m)/שמחה(f), אתה(m)/את(f), …

import Foundation

/// One scene line. `expectAny == nil` marks a setup line (only there to establish
/// identity); payload lines carry the gendered ground truth.
public struct GenderProbeLine: Sendable {
    public var source: String
    public var expectAny: [String]?
    public var forbidAny: [String]
    public init(_ source: String, expect: [String]? = nil, forbid: [String] = []) {
        self.source = source
        self.expectAny = expect
        self.forbidAny = forbid
    }
}

public struct GenderGateResult: Sendable, Codable {
    public var approach: String
    public var total: Int
    public var correct: Int
    public var accuracy: Double
    public var failures: [String]
}

public enum TranslationQualityGate {
    /// Built-in probe scene — a two-person dialogue (David m, Sarah f). Lines 1–2
    /// establish genders by name. Every payload line OPENS WITH A VOCATIVE (the
    /// addressee), which deterministically fixes both the speaker (the other person)
    /// and the addressee — so the correct Hebrew inflection is unambiguous ground
    /// truth, while the gendered word itself stays name-less.
    ///
    /// Token choices avoid unvocalized homographs and the accusative particle את:
    ///   - female-addressee lines forbid the masculine adjective AND אתה (safe);
    ///   - male-addressee lines forbid only the feminine adjective (NOT את, which is
    ///     also the accusative particle and could legitimately appear).
    public static let scene: [GenderProbeLine] = [
        .init("Hello, my name is David."),
        .init("Hi, my name is Sarah."),
        // 1st-person present — gender = SPEAKER (the non-addressed character).
        .init("Sarah, I am very glad to see you.", expect: ["שמח"], forbid: ["שמחה"]),   // David m
        .init("David, I am a little tired.", expect: ["עייפה"], forbid: ["עייף"]),        // Sarah f
        .init("Sarah, I am not so sure about this.", expect: ["בטוח"], forbid: ["בטוחה"]),// David m
        .init("David, I am really hungry.", expect: ["רעבה"], forbid: ["רעב"]),           // Sarah f
        // 2nd-person — gender = ADDRESSEE (the vocative).
        .init("Sarah, you are very kind.", expect: ["נחמדה", "את"], forbid: ["נחמד", "אתה"]),
        .init("David, you are very strong.", expect: ["חזק", "אתה"], forbid: ["חזקה"]),
        .init("Sarah, you are very smart.", expect: ["חכמה", "את"], forbid: ["חכם", "אתה"]),
        .init("David, are you ready to go?", expect: ["מוכן", "אתה"], forbid: ["מוכנה"]),
    ]

    /// Build evenly-timed cues (small gaps so ScenePacketer keeps them in one scene).
    public static func sceneCues() -> [SubtitleCue] {
        scene.enumerated().map { i, p in
            SubtitleCue(index: i + 1, startMs: i * 1_500, endMs: i * 1_500 + 1_200, text: p.source)
        }
    }

    /// Score a translation set (cueIndex → Hebrew) against the scene ground truth.
    public static func score(approach: String, translationsByCueIndex: [Int: String]) -> GenderGateResult {
        var total = 0, correct = 0
        var failures: [String] = []
        for (i, probe) in scene.enumerated() {
            guard let expect = probe.expectAny else { continue } // skip setup lines
            total += 1
            let out = translationsByCueIndex[i + 1] ?? ""
            let words = hebrewWords(out)
            let hasExpected = expect.contains { words.contains($0) }
            let hasForbidden = probe.forbidAny.contains { words.contains($0) }
            if hasExpected && !hasForbidden {
                correct += 1
            } else {
                let why = !hasExpected ? "missing \(expect)" : "has wrong-gender \(probe.forbidAny)"
                failures.append("“\(probe.source)” → “\(out)”  [\(why)]")
            }
        }
        return GenderGateResult(
            approach: approach, total: total, correct: correct,
            accuracy: total > 0 ? Double(correct) / Double(total) : 0, failures: failures)
    }

    /// Tokenize Hebrew output into bare words: strip niqqud/cantillation, RTL marks,
    /// maqaf and punctuation, so "עייף" and "עייפה" compare as DISTINCT whole words.
    static func hebrewWords(_ s: String) -> Set<String> {
        let stripScalars = Set<UnicodeScalar>([
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
            "\u{202D}", "\u{202E}", "\u{FEFF}", "\u{05BE}", // maqaf
        ])
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { sc in
            if stripScalars.contains(sc) { return false }
            if (0x0591...0x05C7).contains(Int(sc.value)) { return false } // niqqud/cantillation
            return true
        }))
        let parts = cleaned.split { !CharacterSet.letters.contains($0.unicodeScalars.first!) }
        return Set(parts.map(String.init))
    }
}
