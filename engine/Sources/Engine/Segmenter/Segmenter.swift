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

    public func segment(_ asr: ASRResult) -> [SubtitleCue] {
        let words = asr.segments.flatMap { $0.words }
        // No word-level timing (e.g. some ASR fallbacks) → one cue per segment.
        guard !words.isEmpty else {
            return asr.segments.enumerated().map { i, s in
                clampDuration(SubtitleCue(index: i + 1, startMs: s.startMs,
                                          endMs: s.endMs, text: s.text))
            }
        }

        var cues: [SubtitleCue] = []
        var buf: [ASRWord] = []

        func flush() {
            guard !buf.isEmpty else { return }
            let text = buf.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let cue = SubtitleCue(index: cues.count + 1,
                                  startMs: buf.first!.startMs,
                                  endMs: buf.last!.endMs,
                                  text: text)
            cues.append(clampDuration(cue))
            buf.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let last = buf.last {
                let gap = word.startMs - last.endMs
                let projected = (buf.map { $0.text }.joined(separator: " ") + " " + word.text).count
                let projectedDur = word.endMs - buf.first!.startMs
                if gap >= config.pauseBreakMs
                    || projected > config.maxChars
                    || projectedDur > config.maxDurationMs {
                    flush()
                }
            }
            buf.append(word)
        }
        flush()
        return cues
    }

    /// Enforce min/max duration and nudge toward the CPS ceiling where there's room.
    private func clampDuration(_ cue: SubtitleCue) -> SubtitleCue {
        var c = cue
        if c.durationMs < config.minDurationMs {
            c.endMs = c.startMs + config.minDurationMs
        }
        // If too fast to read, extend up to maxDuration (best-effort; the next
        // cue's start would cap this in a fuller implementation).
        let neededMs = Int(Double(c.text.count) / config.maxCPS * 1000.0)
        if neededMs > c.durationMs {
            c.endMs = c.startMs + min(neededMs, config.maxDurationMs)
        }
        if c.durationMs > config.maxDurationMs {
            c.endMs = c.startMs + config.maxDurationMs
        }
        return c
    }
}
