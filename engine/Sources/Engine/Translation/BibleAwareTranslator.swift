// BibleAwareTranslator — context-aware translation with gender/speaker injection.
//
// This is the product's core differentiator (SPEC §4). For each subtitle line we
// inject ONLY the relevant bible context into the LLM prompt:
//   - the speaker's gender (drives Hebrew verb/adjective conjugation),
//   - the addressee's gender (second-person forms are gendered in Hebrew),
//   - glossary-locked character name translations (so names never drift across
//     episodes/films of a contextual parent),
//   - relevant relationships.
//
// Engine: DictaLM 3.0 (Apache-2.0, Hebrew-native) for the Hebrew default;
// Qwen3/Qwen-MT for other targets. Runtime: MLX preferred, llama.cpp (GGUF)
// fallback, behind one inference interface.
//
// v0 status: protocol + stub that BUILDS the real prompt (so the prompt shape is
// reviewable now) and returns a placeholder translation. No LLM dep yet (TODO).

import Foundation

/// Resolved per-line context fed to the translator.
public struct LineContext: Sendable {
    public var sourceText: String
    public var speaker: BibleCharacter?
    public var addressee: BibleCharacter?
    /// Characters mentioned/relevant to this line (glossary lock).
    public var relevantCharacters: [BibleCharacter]

    public init(
        sourceText: String,
        speaker: BibleCharacter? = nil,
        addressee: BibleCharacter? = nil,
        relevantCharacters: [BibleCharacter] = []
    ) {
        self.sourceText = sourceText
        self.speaker = speaker
        self.addressee = addressee
        self.relevantCharacters = relevantCharacters
    }
}

public protocol BibleAwareTranslator: Sendable {
    /// Translate one line into `targetLang` using the injected bible context.
    func translate(line: LineContext, targetLang: String) async throws -> String

    /// Exposed for review/testing: the exact prompt that would be sent.
    func buildPrompt(line: LineContext, targetLang: String) -> String
}

/// DictaLM-backed translator. Builds the bible-aware prompt and (when a chat
/// client is attached) runs it on a local llama-server; otherwise returns a
/// placeholder so the pipeline still composes without a model.
public struct DictaLMTranslator: BibleAwareTranslator {
    private let modelPaths: ModelPaths
    private let chat: LlamaChat?

    public init(modelPaths: ModelPaths, chat: LlamaChat? = nil) {
        self.modelPaths = modelPaths
        self.chat = chat
    }

    /// PROMPT SHAPE (documented contract):
    ///
    ///   System: translation instruction + target language + RTL/gender rules.
    ///   Context block:
    ///     SPEAKER: <canonical> (gender=<m|f|nb|unknown>)
    ///     ADDRESSEE: <canonical> (gender=...)
    ///     GLOSSARY (locked): <source name> -> <target name>   [per character]
    ///     RELATIONSHIPS: <...>
    ///   Task: translate the SOURCE line only, preserving meaning, applying the
    ///   speaker/addressee gender to all gendered forms, and using the glossary
    ///   names verbatim.
    ///   SOURCE: <sourceText>
    ///
    /// The model must output ONLY the translated line (no commentary).
    public func buildPrompt(line: LineContext, targetLang: String) -> String {
        var parts: [String] = []

        parts.append("""
        You are an expert subtitle translator. Translate the SOURCE line into \
        \(targetLang). Output ONLY the translated line, no commentary. Preserve \
        meaning and natural spoken register. Apply gendered grammar correctly \
        based on the SPEAKER and ADDRESSEE genders given below. Use the GLOSSARY \
        name translations verbatim — never invent or vary a character's name.
        """)

        parts.append("--- CONTEXT ---")
        if let s = line.speaker {
            parts.append("SPEAKER: \(s.canonicalName) (gender=\(s.gender.rawValue))")
        }
        if let a = line.addressee {
            parts.append("ADDRESSEE: \(a.canonicalName) (gender=\(a.gender.rawValue))")
        }

        let glossary = line.relevantCharacters.compactMap { c -> String? in
            guard let target = c.nameTranslations[targetLang] else { return nil }
            return "  \(c.canonicalName) -> \(target)"
        }
        if !glossary.isEmpty {
            parts.append("GLOSSARY (locked):")
            parts.append(contentsOf: glossary)
        }

        let rels = line.relevantCharacters
            .flatMap { $0.relationships }
            .filter { !$0.isEmpty }
        if !rels.isEmpty {
            parts.append("RELATIONSHIPS: \(rels.joined(separator: "; "))")
        }

        parts.append("--- TASK ---")
        parts.append("SOURCE: \(line.sourceText)")
        parts.append("TRANSLATION:")

        return parts.joined(separator: "\n")
    }

    public func translate(line: LineContext, targetLang: String) async throws -> String {
        let prompt = buildPrompt(line: line, targetLang: targetLang)
        guard let chat else {
            _ = modelPaths.llm
            return "[\(targetLang)] \(line.sourceText)" // placeholder (no model attached)
        }
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: 256, temperature: 0.2)
        return Self.cleanLine(raw)
    }

    /// The model is instructed to output ONLY the translated line, but be robust
    /// to a stray label / surrounding quotes / extra blank lines.
    static func cleanLine(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "TRANSLATION:") {
            s = String(s[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // First non-empty line only.
        s = s.split(separator: "\n").map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? s
        // Strip wrapping quotes.
        let quotes: Set<Character> = ["\"", "“", "”", "'", "«", "»"]
        if let f = s.first, let l = s.last, quotes.contains(f), quotes.contains(l), s.count > 1 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Batch translation (throughput)

    /// Translate many lines with FAR fewer model round-trips by sending chunks of
    /// numbered lines per call. The model infers speaker/addressee gender from the
    /// surrounding lines in the chunk. Falls back to per-line translation for any
    /// chunk the model misformats, so output length always matches the input.
    public func translateBatch(
        lines: [String],
        targetLang: String,
        chunkSize: Int = 20,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [String] {
        guard chat != nil else { return lines.map { "[\(targetLang)] \($0)" } }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let chunk = Array(lines[i ..< min(i + chunkSize, lines.count)])
            out.append(contentsOf: try await translateChunk(chunk, targetLang: targetLang))
            i += chunkSize
            onProgress(Double(min(i, lines.count)) / Double(max(lines.count, 1)))
        }
        return out
    }

    private func translateChunk(_ chunk: [String], targetLang: String) async throws -> [String] {
        guard let chat else { return chunk.map { "[\(targetLang)] \($0)" } }
        let prompt = buildBatchPrompt(chunk, targetLang: targetLang)
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: 60 * chunk.count + 80, temperature: 0.2)
        let parsed = Self.parseNumbered(raw, expected: chunk.count)
        if parsed.count == chunk.count, !parsed.contains(where: { $0.isEmpty }) {
            return parsed
        }
        // Misformatted → reliable per-line fallback for this chunk only.
        var result: [String] = []
        for line in chunk {
            result.append(try await translate(line: LineContext(sourceText: line),
                                               targetLang: targetLang))
        }
        return result
    }

    func buildBatchPrompt(_ chunk: [String], targetLang: String) -> String {
        var parts: [String] = []
        parts.append("""
        You are an expert subtitle translator. Translate EACH numbered line into \
        \(targetLang). Infer each speaker's and addressee's gender from the \
        surrounding dialogue and apply gendered grammar correctly. Use natural \
        spoken register. Output EXACTLY one line per input, in the same order, \
        each formatted as "<number>. <translation>" — no notes, no blank lines.
        """)
        parts.append("--- LINES ---")
        for (i, line) in chunk.enumerated() { parts.append("\(i + 1). \(line)") }
        parts.append("--- TRANSLATIONS ---")
        return parts.joined(separator: "\n")
    }

    /// Parse `<n>. <text>` lines into an ordered array of length `expected`
    /// (missing entries become empty strings, which trigger the per-line fallback).
    static func parseNumbered(_ raw: String, expected: Int) -> [String] {
        var byNum: [Int: String] = [:]
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let dot = line.firstIndex(of: "."),
                  let n = Int(line[line.startIndex ..< dot]), n >= 1, n <= expected
            else { continue }
            byNum[n] = cleanLine(String(line[line.index(after: dot)...]))
        }
        return (1 ... max(expected, 1)).map { byNum[$0] ?? "" }
    }
}
