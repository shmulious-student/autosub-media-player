// SpeakerAttributor — infer, per line, WHO is speaking and WHO they address, then
// give each one's gender (SPEC §4 gender correctness).
//
// Knowing a character's gender isn't enough: a line like "I am tired." has no name,
// so the translator can't tell Sarah is speaking. This pass tracks the conversation
// flow (turn-taking, introductions, names) to attribute each line to a speaker +
// addressee and resolve their genders — informed by a script-wide character→gender
// map. The result drives per-line gendered translation. Chunked so long episodes
// fit the model context; the warm DictaLM server does the inference.

import Foundation

public struct LineAttribution: Sendable {
    public var speakerGender: Gender
    public var addresseeGender: Gender
    public init(speakerGender: Gender = .unknown, addresseeGender: Gender = .unknown) {
        self.speakerGender = speakerGender
        self.addresseeGender = addresseeGender
    }

    /// Single-char marker for prompts: m / f / u.
    static func marker(_ g: Gender) -> String { g == .m ? "m" : (g == .f ? "f" : "u") }
}

public struct SpeakerAttributor: Sendable {
    private let chat: LlamaChat
    public init(chat: LlamaChat) { self.chat = chat }

    /// Per-line attribution aligned to `lines` (same length). Lines the model can't
    /// resolve stay `.unknown`. `characters` (name→m/f/u) gives the model the
    /// script-wide genders so attribution stays consistent.
    public func attribute(lines: [String], characters: [String: String] = [:],
                          chunkSize: Int = 40) async throws -> [LineAttribution] {
        var result = [LineAttribution](repeating: LineAttribution(), count: lines.count)
        var i = 0
        while i < lines.count {
            let chunk = Array(lines[i ..< min(i + chunkSize, lines.count)])
            let part = (try? await attributeChunk(chunk, characters: characters)) ?? [:]
            for (local, attr) in part {
                let global = i + local - 1 // local is 1-based within the chunk
                if global >= 0, global < lines.count { result[global] = attr }
            }
            i += chunkSize
        }
        return result
    }

    private func attributeChunk(_ chunk: [String],
                                characters: [String: String]) async throws -> [Int: LineAttribution] {
        let numbered = chunk.enumerated()
            .map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        var charBlock = ""
        if !characters.isEmpty {
            let list = characters.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            charBlock = "Known character genders (m/f/u): \(list)\n\n"
        }
        let prompt = """
        This is a continuous dialogue. For EACH numbered line, work out WHO is \
        speaking and WHO they are addressing by tracking the conversation flow \
        (speakers usually alternate; introductions and names reveal identities), \
        then report the SPEAKER's gender and the ADDRESSEE's gender. Use "m" (male), \
        "f" (female), or "u" (unknown).
        \(charBlock)Output ONLY a JSON array, one object per line, no commentary:
        [{"i":1,"sg":"m","ag":"f"},{"i":2,"sg":"f","ag":"m"}]

        LINES:
        \(numbered)
        """
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: max(256, chunk.count * 20),
                                          temperature: 0.1)
        return Self.parse(raw)
    }

    /// Parse a chunk's JSON array into LOCAL 1-based line index → attribution.
    static func parse(_ raw: String) -> [Int: LineAttribution] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end else { return [:] }
        guard let data = String(raw[start ... end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var out: [Int: LineAttribution] = [:]
        for obj in arr {
            guard let i = intValue(obj["i"]) else { continue }
            out[i] = LineAttribution(speakerGender: gender(obj["sg"]),
                                     addresseeGender: gender(obj["ag"]))
        }
        return out
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func gender(_ v: Any?) -> Gender {
        switch (v as? String)?.lowercased() {
        case "m": return .m
        case "f": return .f
        case "nb": return .nb
        default: return .unknown
        }
    }
}
