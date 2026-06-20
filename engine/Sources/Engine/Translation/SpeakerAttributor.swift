// SpeakerAttributor — infer per-line speaker/addressee gender for the prod path.
//
// On the production path (real ASR, no character bible yet) we have no speaker
// info, so gendered languages can't be translated correctly per line. This runs
// ONE local-LLM pass over the whole cue list and infers, per line, the speaker's
// gender and the addressee's gender from dialogue context. Those feed the
// bible-aware translator so Hebrew verbs/adjectives inflect correctly.
//
// This is a lightweight stand-in for full audio diarization + the bible-bootstrap
// stage (SPEC §4); it improves the prod path today without those heavier pieces.

import Foundation

public struct LineAttribution: Sendable {
    public var speakerGender: Gender
    public var addresseeGender: Gender
}

public struct SpeakerAttributor: Sendable {
    private let chat: LlamaChat
    public init(chat: LlamaChat) { self.chat = chat }

    /// Returns attributions keyed by `SubtitleCue.index`. Best-effort: lines the
    /// model omits or can't infer are simply absent (translator falls back to
    /// no-gender context).
    public func attribute(cues: [SubtitleCue]) async throws -> [Int: LineAttribution] {
        guard !cues.isEmpty else { return [:] }
        let lines = cues.map { "\($0.index): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        You are analyzing a film/TV dialogue transcript to enable gender-correct \
        translation. For EACH numbered line, infer the SPEAKER's gender and the \
        gender of the person being ADDRESSED, using context across the whole \
        conversation (names, pronouns, who replies to whom). Use "m" (male), \
        "f" (female), or "u" (unknown).

        Output ONLY a compact JSON array — one object per line, no commentary, no \
        code fences:
        [{"i":1,"sg":"m","ag":"f"},{"i":2,"sg":"f","ag":"m"}]

        LINES:
        \(lines)
        """
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: max(256, cues.count * 20),
                                          temperature: 0.1)
        return Self.parse(raw)
    }

    static func parse(_ raw: String) -> [Int: LineAttribution] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"),
              start < end else { return [:] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
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
