// DialogueAnalyzer — read the whole dialogue and infer a consistent
// character → gender map (SPEC §4: gender correctness is the core differentiator).
//
// Hebrew inflects verbs, adjectives, and 2nd-person pronouns (את/אתה) by gender.
// Inferring gender chunk-by-chunk during translation gives only LOCAL context, so
// the same character can flip gender between scenes. This pass reads the dialogue
// (in chunks, merged) to build ONE script-wide map of who is male/female, which the
// translator then applies consistently across every line.

import Foundation

public struct DialogueAnalyzer: Sendable {
    private let chat: LlamaChat
    public init(chat: LlamaChat) { self.chat = chat }

    /// Returns a map of character name → "m" | "f" | "u" (unknown), inferred from
    /// names, pronouns (he/him vs she/her), titles, and surrounding context.
    public func characterGenders(lines: [String], chunkSize: Int = 60,
                                 onProgress: @Sendable (Double) -> Void = { _ in }) async throws -> [String: String] {
        guard !lines.isEmpty else { return [:] }
        var merged: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let chunk = Array(lines[i ..< min(i + chunkSize, lines.count)])
            let part = (try? await analyzeChunk(chunk)) ?? [:]
            for (name, g) in part {
                // A known gender wins over "unknown"; first known value is kept.
                if let existing = merged[name] {
                    if existing == "u", g != "u" { merged[name] = g }
                } else {
                    merged[name] = g
                }
            }
            i += chunkSize
            onProgress(Double(min(i, lines.count)) / Double(max(lines.count, 1)))
        }
        // Keep only VALIDATED, gendered character names. Drop "unknown" (which is
        // usually noise) and anything that doesn't look like a person's name, so we
        // never inject junk like "The insurance company=u" into the translator.
        return merged.filter { name, g in (g == "m" || g == "f") && Self.looksLikeName(name) }
    }

    /// Heuristic: a person's name is 1–3 capitalized words, not a pronoun/article.
    static func looksLikeName(_ s: String) -> Bool {
        let words = s.split(separator: " ").map(String.init)
        guard (1 ... 3).contains(words.count), s.count >= 2, s.count <= 30 else { return false }
        for w in words {
            guard let first = w.first, first.isUppercase, first.isLetter else { return false }
        }
        let stop: Set<String> = ["The", "They", "He", "She", "It", "We", "You", "I",
                                 "A", "An", "And", "But", "This", "That", "Their"]
        if words.count == 1, stop.contains(words[0]) { return false }
        return true
    }

    private func analyzeChunk(_ chunk: [String]) async throws -> [String: String] {
        let text = chunk.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Read this dialogue excerpt and list only the PERSONAL NAMES of characters \
        (actual people). For each, infer gender from pronouns (he/him vs she/her), \
        titles, and context. Do NOT include pronouns, job titles, organizations, \
        groups, or descriptive phrases — only real character names. If there are no \
        named characters, output {}. Output ONLY a compact JSON object mapping name \
        to "m" (male), "f" (female), or "u" (unknown) — no commentary, no code \
        fences. Example: {"David":"m","Sarah":"f"}

        DIALOGUE:
        \(text)
        """
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: 400, temperature: 0.1)
        return Self.parseMap(raw)
    }

    static func parseMap(_ raw: String) -> [String: String] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end else { return [:] }
        guard let data = String(raw[start ... end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in obj {
            let g = (value as? String)?.lowercased() ?? "u"
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out[trimmed] = ["m", "f"].contains(g) ? g : "u" }
        }
        return out
    }
}
