// SubtitleTokenizer — turn a subtitle cue and an ASR transcript into comparable
// token streams (handoff §6.3).
//
// The alignment quality of the whole sync engine turns on one detail: HOW the text
// is split. Subtitles are full of hyphenated stutter ("I-I-I figure", "an-an-and",
// "th-th-that") and hyphenated compounds ("New-York's-subway-system"). Splitting on
// whitespace alone glues those into single nonsense tokens ("ananand",
// "newyorkssubwaysystem") that match NOTHING in the ASR stream — so the aligner
// skips the opening words of a cue and snaps to a later word instead, which in the
// sister project's measurements cost about +1500 ms on affected cues.
//
// Splitting on `[\s\-—–]+` instead makes "I-I-I figure" four tokens, three of which
// the ASR also produced. Normalization then strips case, punctuation and diacritics
// so "figure," and "Figure" compare equal.

import Foundation

/// One token with the position it held inside its cue.
public struct SubtitleToken: Sendable, Equatable {
    public var text: String
    /// Index of the cue this token came from, within the cue array.
    public var cueIdx: Int
    /// Position of the token within its own cue. `<= 1` marks a SPEECH ONSET token —
    /// the only ones we take timing anchors from, because a cue's START is when
    /// speech begins while its END carries reading-time padding (500–1500 ms of
    /// silence), which makes end-derived anchors systematically wrong.
    public var tokenIdx: Int

    public init(text: String, cueIdx: Int, tokenIdx: Int) {
        self.text = text
        self.cueIdx = cueIdx
        self.tokenIdx = tokenIdx
    }

    /// True for the first two tokens of a cue — the speech-onset anchor window.
    public var isOnset: Bool { tokenIdx <= 1 }
}

public enum SubtitleTokenizer {
    /// Split on whitespace AND every kind of dash, then normalize.
    public static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { ch in
            ch.isWhitespace || ch == "-" || ch == "—" || ch == "–" || ch == "‐"
        })
        .map(normalize)
        .filter { !$0.isEmpty }
    }

    /// Cue array → one flat token stream carrying cue/token positions.
    public static func tokens(cues: [SubtitleCue]) -> [SubtitleToken] {
        var out: [SubtitleToken] = []
        for (cueIdx, cue) in cues.enumerated() {
            for (i, t) in tokenize(cue.text).enumerated() {
                out.append(SubtitleToken(text: t, cueIdx: cueIdx, tokenIdx: i))
            }
        }
        return out
    }

    /// ASR words → the same token stream shape. A word the ASR itself hyphenated is
    /// split too, and its timing is divided across the pieces by character length so
    /// each piece keeps a plausible onset.
    public static func tokens(words: [ASRWord]) -> [(text: String, startMs: Int, endMs: Int)] {
        var out: [(String, Int, Int)] = []
        for w in words {
            let pieces = tokenize(w.text)
            guard !pieces.isEmpty else { continue }
            if pieces.count == 1 {
                out.append((pieces[0], w.startMs, w.endMs))
                continue
            }
            let totalChars = max(pieces.reduce(0) { $0 + $1.count }, 1)
            let span = max(w.endMs - w.startMs, 0)
            var cursor = w.startMs
            for p in pieces {
                let slice = span * p.count / totalChars
                out.append((p, cursor, cursor + slice))
                cursor += slice
            }
        }
        return out
    }

    /// Lowercase, strip everything but letters/digits, fold diacritics. Keeps
    /// alignment insensitive to punctuation, casing and typography, which differ
    /// freely between a subtitle file and an ASR transcript of the same speech.
    public static func normalize(_ s: some StringProtocol) -> String {
        let folded = String(s).folding(options: [.diacriticInsensitive, .caseInsensitive],
                                       locale: Locale(identifier: "en_US"))
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
