// SpeakerTags — recover the speaker a subtitle file already tells us about.
//
// The addressee ladder's middle rungs (direct reply, two-hander elimination) need
// to know WHO speaks each line. ASR gives us no speaker at all, but subtitle files
// very often do: SDH and broadcast subs prefix turns with a name — "DANNY: Move!",
// "Danny: Move!", "[DANNY] Move!". That label is ground truth, free, and thrown
// away today (it is also noise the model would otherwise try to translate).
//
// So we lift it into `speakerId` and strip it from the text. Deliberately strict:
// a label must look like a name and be short, because a false positive would both
// corrupt the dialogue text and feed the ladder a speaker who does not exist.

import Foundation

public enum SpeakerTags {
    /// Move any leading speaker label out of `text` and into `speakerId`.
    /// Cues without a recognizable label are returned unchanged.
    public static func apply(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            guard cue.speakerId == nil, let (name, rest) = split(cue.text) else { return cue }
            var c = cue
            c.speakerId = name
            c.text = rest
            return c
        }
    }

    /// `("DANNY", "Move!")` for a labelled line, else nil.
    static func split(_ text: String) -> (name: String, rest: String)? {
        // Strip a leading dialogue dash first: "- DANNY: Move!".
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[-–—]\\s*", with: "", options: .regularExpression)

        let patterns = [
            #"^([A-Z][A-Za-z'’.\-]*(?: [A-Z][A-Za-z'’.\-]*){0,2})\s*:\s*(.*)$"#,   // DANNY: / Danny:
            #"^[\[(]\s*([A-Z][A-Za-z'’.\-]*(?: [A-Z][A-Za-z'’.\-]*){0,2})\s*[\])]\s*(.*)$"#, // [DANNY]
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  m.numberOfRanges > 2,
                  let nameRange = Range(m.range(at: 1), in: line),
                  let restRange = Range(m.range(at: 2), in: line)
            else { continue }
            let name = String(line[nameRange])
            let rest = String(line[restRange]).trimmingCharacters(in: .whitespaces)
            // A label with nothing after it is a sound cue, not a turn; and a very
            // long "name" is a sentence that happened to contain a colon.
            guard !rest.isEmpty, name.count <= 24, DialogueAnalyzer.looksLikeName(titleCased(name))
            else { continue }
            return (normalize(name), rest)
        }
        return nil
    }

    /// "DANNY" and "Danny" are the same person — normalize to Title Case so the
    /// label joins up with the character→gender map, which uses natural casing.
    static func normalize(_ name: String) -> String { titleCased(name) }

    private static func titleCased(_ name: String) -> String {
        name.split(separator: " ").map { w -> String in
            guard let first = w.first else { return String(w) }
            return String(first).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
