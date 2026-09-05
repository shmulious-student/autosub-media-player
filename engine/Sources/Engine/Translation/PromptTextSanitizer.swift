import Foundation

/// Conservative cleanup before source text enters LLM prompts.
///
/// This does not mutate stored cues. It removes subtitle-rendering noise and pure
/// non-dialogue captions so the translator spends context on actual dialogue.
public enum PromptTextSanitizer {
    private static let nonDialogueCaptions: Set<String> = [
        "music", "theme music", "dramatic music", "applause", "laughter",
        "laughs", "sighs", "groans", "door opens", "door closes",
        "phone ringing", "ringing", "inaudible", "indistinct", "silence",
        "crowd cheering",
    ]

    private static let promptControlScalars: Set<UnicodeScalar> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
        "\u{202D}", "\u{202E}", "\u{FEFF}",
    ]

    /// Returns cleaned text, or nil when the cue is pure non-dialogue noise.
    public static func sanitize(_ raw: String) -> String? {
        var s = raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
        s = String(s.unicodeScalars.filter { !promptControlScalars.contains($0) })
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty else { return nil }
        let normalized = normalizeCaptionKey(s)
        if nonDialogueCaptions.contains(normalized) { return nil }

        if let bracketed = unwrapWholeCueBracket(s),
           nonDialogueCaptions.contains(normalizeCaptionKey(bracketed)) {
            return nil
        }

        let hasContent = s.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.letters.contains($0)
        }
        return hasContent ? s : nil
    }

    public static func sanitizedCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { cue in
            guard let text = sanitize(cue.text) else { return nil }
            var out = cue
            out.text = text
            return out
        }
    }

    private static func normalizeCaptionKey(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?-–—"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func unwrapWholeCueBracket(_ s: String) -> String? {
        guard let first = s.first, let last = s.last else { return nil }
        let isBracketed = (first == "[" && last == "]") || (first == "(" && last == ")")
        guard isBracketed, s.count > 2 else { return nil }
        return String(s.dropFirst().dropLast())
    }
}
