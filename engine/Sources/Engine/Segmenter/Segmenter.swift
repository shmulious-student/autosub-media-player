// Segmenter — turn ASR words into subtitle cues with readable timing (SPEC §4).
//
// Splits the word stream into cues that honor reading-speed (CPS) and min/max
// duration, breaking on speech pauses so cue boundaries land between phrases
// rather than mid-word. Hebrew is tuned to a lower CPS than English defaults.

import Foundation

/// One on-screen subtitle cue (pre-translation it holds source text; the
/// translator replaces `.text` in place, preserving timing).
public struct SubtitleCue: Codable, Sendable, Identifiable {
    public var index: Int
    public var startMs: Int
    public var endMs: Int
    public var text: String
    /// Optional speaker (set in fixture/known-transcript mode or by a later
    /// speaker-attribution pass) — drives gendered translation.
    public var speakerId: String?

    public var id: Int { index }
    public var durationMs: Int { max(0, endMs - startMs) }
    /// Characters per second — the core readability metric.
    public var cps: Double {
        durationMs > 0 ? Double(text.count) / (Double(durationMs) / 1000.0) : .infinity
    }

    public init(index: Int, startMs: Int, endMs: Int, text: String, speakerId: String? = nil) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerId = speakerId
    }
}

public struct SegmenterConfig: Sendable {
    public var maxChars: Int          // hard cap on cue length
    public var maxCPS: Double         // reading-speed ceiling (Hebrew-tuned)
    public var minDurationMs: Int     // a cue must linger at least this long
    public var maxDurationMs: Int     // …and no longer than this
    public var pauseBreakMs: Int      // a gap >= this forces a cue break

    public init(maxChars: Int = 42, maxCPS: Double = 15.0,
                minDurationMs: Int = 1000, maxDurationMs: Int = 7000,
                pauseBreakMs: Int = 700) {
        self.maxChars = maxChars
        self.maxCPS = maxCPS
        self.minDurationMs = minDurationMs
        self.maxDurationMs = maxDurationMs
        self.pauseBreakMs = pauseBreakMs
    }

    /// Defaults tuned for Hebrew (denser script → lower CPS).
    public static let hebrew = SegmenterConfig(maxCPS: 15.0)
}

public struct Segmenter: Sendable {
    private let config: SegmenterConfig
    public init(config: SegmenterConfig = .hebrew) { self.config = config }

    /// Sentence-ending punctuation we prefer to break cues on.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "؟"]

    public func segment(_ asr: ASRResult) -> [SubtitleCue] {
        let words = asr.segments.flatMap { $0.words }
        // No word-level timing (e.g. some ASR fallbacks) → one cue per segment.
        guard !words.isEmpty else {
            let cues = asr.segments.enumerated().map { i, s in
                SubtitleCue(index: i + 1, startMs: s.startMs, endMs: s.endMs, text: s.text)
            }
            return normalize(cues)
        }

        var cues: [SubtitleCue] = []
        var buf: [ASRWord] = []

        func flush() {
            guard !buf.isEmpty else { return }
            let text = buf.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            cues.append(SubtitleCue(index: cues.count + 1,
                                    startMs: buf.first!.startMs,
                                    endMs: buf.last!.endMs,
                                    text: text))
            buf.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let last = buf.last {
                let gap = word.startMs - last.endMs
                let projected = (buf.map { $0.text }.joined(separator: " ") + " " + word.text).count
                let projectedDur = word.endMs - buf.first!.startMs
                // Break BEFORE this word on a pause or when limits would be exceeded.
                if gap >= config.pauseBreakMs
                    || projected > config.maxChars
                    || projectedDur > config.maxDurationMs {
                    flush()
                }
            }
            buf.append(word)
            // Break AFTER a word that ends a sentence, so cues align to sentences
            // instead of splitting mid-phrase.
            if let lastChar = word.text.trimmingCharacters(in: .whitespaces).last,
               Self.sentenceEnders.contains(lastChar) {
                flush()
            }
        }
        flush()
        return normalize(cues)
    }

    /// Enforce min/max duration + CPS headroom, and guarantee cues never overlap
    /// (a later cue's start caps the previous cue's end). Re-indexes 1..n.
    private func normalize(_ input: [SubtitleCue]) -> [SubtitleCue] {
        var cues = input
        for i in cues.indices {
            var c = cues[i]
            // Target end: at least min duration, and enough time to read (CPS).
            let needForCPS = Int(Double(c.text.count) / config.maxCPS * 1000.0)
            var end = max(c.endMs, c.startMs + max(config.minDurationMs, needForCPS))
            end = min(end, c.startMs + config.maxDurationMs)
            // Never run into the next cue (leave a tiny gap).
            if i + 1 < cues.count {
                end = min(end, cues[i + 1].startMs - 1)
            }
            c.endMs = max(c.startMs + 1, end)
            c.index = i + 1
            cues[i] = c
        }
        return cues
    }
}
