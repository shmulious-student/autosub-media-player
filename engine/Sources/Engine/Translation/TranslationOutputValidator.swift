// TranslationOutputValidator — deterministic (no-LLM) checks that a translated
// subtitle line is a FAITHFUL rendering of its source.
//
// The fidelity prompts ask the model to translate exactly what was said, but a
// prompt can't GUARANTEE it: the model still occasionally leaves a line in the
// source language, drops a clause, hallucinates extra text, loops a word, or loses
// a number. These are the cheap, high-precision signals for those failure modes.
// A flagged line is re-asked through the translator's existing scene-context repair
// (ScenePacketTranslator.buildLeanRepairPrompt); anything still failing is kept as
// the best candidate and surfaced in qaFlags.
//
// Thresholds are deliberately CONSERVATIVE: a false positive costs an extra decode
// (working against the throughput target), so every check errs toward "looks fine".

import Foundation

public enum TranslationOutputValidator {
    public enum Issue: String, Sendable, Equatable {
        case empty          // no output at all
        case untranslated   // output equals the source, or has no target-script text
        case leakedSource   // a non-Latin target line is dominated by Latin-script text
        case omission       // far too short vs the source (likely a dropped clause)
        case addition       // far too long vs the source (likely hallucinated text)
        case repetition     // a word / phrase loops (classic decode failure)
        case numberDrift    // a multi-digit number in the source is absent from the output
        case genderHedge    // a dual-gender hedge (את/אתה, יודע/ת, יודע(ת))
    }

    public struct Thresholds: Sendable {
        /// Skip length-ratio + number checks on sources shorter than this (too noisy).
        public var minSourceCharsForRatio: Int
        /// output.count / source.count floor (Hebrew is compact, so keep this low).
        public var minLengthRatio: Double
        /// output.count / source.count ceiling.
        public var maxLengthRatio: Double
        /// For a non-Latin target: min Latin LETTERS before "leaked" can trip (so a
        /// single retained proper name never trips it).
        public var leakedLatinMinLetters: Int
        /// …and Latin letters must be at least this fraction of all letters.
        public var leakedLatinFraction: Double

        public init(
            minSourceCharsForRatio: Int = 12,
            minLengthRatio: Double = 0.30,
            maxLengthRatio: Double = 2.6,
            leakedLatinMinLetters: Int = 8,
            leakedLatinFraction: Double = 0.6
        ) {
            self.minSourceCharsForRatio = minSourceCharsForRatio
            self.minLengthRatio = minLengthRatio
            self.maxLengthRatio = maxLengthRatio
            self.leakedLatinMinLetters = leakedLatinMinLetters
            self.leakedLatinFraction = leakedLatinFraction
        }
    }

    public static let defaultThresholds = Thresholds()

    public static func isValid(
        source: String, translation: String, targetLang: String,
        thresholds: Thresholds = defaultThresholds
    ) -> Bool {
        issue(source: source, translation: translation, targetLang: targetLang,
              thresholds: thresholds) == nil
    }

    /// First fidelity issue found, or nil when the line passes every check.
    public static func issue(
        source: String, translation: String, targetLang: String,
        thresholds t: Thresholds = defaultThresholds
    ) -> Issue? {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = translation.trimmingCharacters(in: .whitespacesAndNewlines)

        if out.isEmpty { return .empty }

        // Nothing to verify against a source with no letters (e.g. "...", "?!").
        let srcLetters = letterCount(src)
        guard srcLetters.total > 0 else { return nil }

        let nonLatinTarget = targetScript(targetLang) != .latin

        // Untranslated: identical to the source, or (non-Latin target) carries no
        // target-script letters at all.
        if normalizedEqual(src, out) { return .untranslated }
        if nonLatinTarget {
            let outLetters = letterCount(out, targetLang: targetLang)
            if outLetters.targetScript == 0 { return .untranslated }
            // Leaked source: the line is mostly Latin despite a non-Latin target.
            if outLetters.latin >= t.leakedLatinMinLetters,
               Double(outLetters.latin) / Double(max(outLetters.total, 1)) >= t.leakedLatinFraction {
                return .leakedSource
            }
        }

        if repetitionLoop(out) { return .repetition }

        // A dual-gender hedge is a hard failure even though the line is otherwise
        // faithful: it is the model refusing to commit, and it is never how a human
        // subtitler writes. The addressee ladder exists so the model never has to.
        if genderHedge(out) { return .genderHedge }

        // Length-ratio + number checks only on substantial source lines.
        if src.count >= t.minSourceCharsForRatio {
            let ratio = Double(out.count) / Double(src.count)
            if ratio < t.minLengthRatio { return .omission }
            if ratio > t.maxLengthRatio { return .addition }
        }

        if let missing = droppedNumber(source: src, translation: out), missing { return .numberDrift }

        return nil
    }

    // MARK: - Checks

    private static func normalizedEqual(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let ka = key(a)
        return !ka.isEmpty && ka == key(b)
    }

    /// A unigram repeated ≥4× in a row, or a 2-/3-gram repeated ≥3× in a row.
    static func repetitionLoop(_ s: String) -> Bool {
        let words = s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map { String($0).lowercased() }
        guard words.count >= 4 else { return false }
        for k in 1...3 {
            let limit = k == 1 ? 4 : 3
            guard words.count >= k * limit else { continue }
            var i = 0
            while i + k <= words.count {
                let window = Array(words[i ..< i + k])
                var reps = 1
                var j = i + k
                while j + k <= words.count && Array(words[j ..< j + k]) == window {
                    reps += 1; j += k
                }
                if reps >= limit { return true }
                i = reps > 1 ? j : i + 1
            }
        }
        return false
    }

    /// True when a 3+-digit source number (year, quantity, time) is missing from the
    /// output. Restricted to long digit-runs because short numbers are often spelled
    /// out in translation ("3" → "שלוש"), which is legitimate.
    static func droppedNumber(source: String, translation: String) -> Bool? {
        let outDigits = digitRuns(translation)
        for run in digitRuns(source) where run.count >= 3 {
            if !outDigits.contains(run) { return true }
        }
        return false
    }

    private static func digitRuns(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var cur = ""
        for ch in s {
            if ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty { out.insert(cur); cur = "" }
        }
        if !cur.isEmpty { out.insert(cur) }
        return out
    }

    /// True when the line contains a DUAL-GENDER HEDGE — the model writing both
    /// inflections instead of choosing one.
    ///
    /// Two shapes occur in practice:
    ///   - slash:      `את/אתה`, `יודע/ת`, `תזוז/תזוזי`
    ///   - parenthesis: `יודע(ת)`, `בטוח(ה)`
    /// Both are refusals to resolve gender, and both read as machine output. We flag
    /// them so the line is re-asked with an explicit binding (or explicit instruction
    /// to phrase neutrally) rather than shipped.
    ///
    /// `ו/או` ("and/or") is the one legitimate Hebrew slash construction, so it is
    /// excluded. The check is script-generic — the same shapes hedge in Arabic.
    static func genderHedge(_ s: String) -> Bool {
        let text = s.replacingOccurrences(of: "ו/או", with: " ")
        // Hebrew + Arabic letter ranges, written as escapes so the class is explicit.
        let letters = "\u{0590}-\u{05FF}\u{0600}-\u{06FF}"
        let patterns = [
            // word/word, both in the same non-Latin script and no spaces around the
            // slash (a spaced slash is usually a real alternative, e.g. a title).
            "[\(letters)]+/[\(letters)]+",
            // word(suffix) — a bracketed inflection tail of 1-3 letters.
            "[\(letters)]{2,}\\([\(letters)]{1,3}\\)",
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Script helpers

    enum Script { case latin, hebrew, arabic, cyrillic, cjk, hangul, devanagari, other }

    static func targetScript(_ code: String) -> Script {
        switch code.lowercased().prefix(2) {
        case "he", "iw": return .hebrew
        case "ar", "fa": return .arabic
        case "ru", "uk", "bg", "sr": return .cyrillic
        case "ja", "zh": return .cjk
        case "ko": return .hangul
        case "hi": return .devanagari
        default: return .latin
        }
    }

    private struct LetterTally { var total = 0; var latin = 0; var targetScript = 0 }

    private static func letterCount(_ s: String, targetLang: String? = nil) -> LetterTally {
        let script = targetLang.map(targetScript)
        var t = LetterTally()
        for scalar in s.unicodeScalars where CharacterSet.letters.contains(scalar) {
            t.total += 1
            let v = Int(scalar.value)
            let isLatin = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || (0x00C0...0x024F).contains(v)
            if isLatin { t.latin += 1 }
            if let script, inScript(v, script) { t.targetScript += 1 }
        }
        return t
    }

    private static func inScript(_ v: Int, _ script: Script) -> Bool {
        switch script {
        case .hebrew: return (0x0590...0x05FF).contains(v) || (0xFB1D...0xFB4F).contains(v)
        case .arabic: return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
            || (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
        case .cyrillic: return (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v)
        case .cjk: return (0x4E00...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v)
            || (0x3400...0x4DBF).contains(v)
        case .hangul: return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
        case .devanagari: return (0x0900...0x097F).contains(v)
        case .latin: return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0x00C0...0x024F).contains(v)
        case .other: return false
        }
    }
}
