// AsrValidator — a deterministic (no-LLM) pass that cleans and grades ASR cues
// before they become the translation source (SPEC §3 "forced-alignment refinement").
//
// WhisperKit cues are built from word timestamps (so they're already aligned), but
// the raw transcript still has two failure modes that corrupt the eventual
// translation if left in:
//   1. Repetition loops — Whisper occasionally repeats a word/phrase many times.
//      We COLLAPSE these (the model would otherwise faithfully translate the loop).
//   2. Low-confidence stretches — quiet/noisy audio yields shaky text. We don't
//      rewrite it (deterministic-only), but we FLAG the affected cues so the result
//      carries honest QA metadata (and a later pass / the UI can act on it).
// It also drops empty cues and flags any cue still too fast to read (CPS).

import Foundation

public enum AsrValidator {
    public struct Config: Sendable {
        /// Mean per-word probability below this marks a cue low-confidence.
        public var minWordProbability: Double
        /// Segment avgLogprob below this also marks low-confidence (≈ p 0.37 at -1.0).
        public var minAvgLogprob: Double
        /// Reading-speed ceiling; cues above it are flagged (matches SegmenterConfig).
        public var maxCPS: Double
        public init(minWordProbability: Double = 0.5, minAvgLogprob: Double = -1.0,
                    maxCPS: Double = 15.0) {
            self.minWordProbability = minWordProbability
            self.minAvgLogprob = minAvgLogprob
            self.maxCPS = maxCPS
        }
    }

    public struct Result: Sendable {
        public var cues: [SubtitleCue]
        public var qaFlags: [String]
    }

    /// Clean + grade `cues` (already produced by the Segmenter) against the raw `asr`.
    public static func validate(
        cues: [SubtitleCue], asr: ASRResult, config: Config = Config()
    ) -> Result {
        // 1. Collapse repetition loops and drop now-empty cues; re-index 1..n.
        var cleaned: [SubtitleCue] = []
        for cue in cues {
            var c = cue
            c.text = collapseRepeats(c.text)
            if c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            cleaned.append(c)
        }
        for i in cleaned.indices { cleaned[i].index = i + 1 }

        // 2. Time ranges (ms) the ASR itself wasn't confident about.
        let lowConf: [(Int, Int)] = asr.segments.compactMap { seg in
            isLowConfidence(seg, config) ? (seg.startMs, seg.endMs) : nil
        }

        // 3. Flag (don't rewrite) per cue.
        var flags: [String] = []
        for c in cleaned {
            if c.cps > config.maxCPS { flags.append("fast-cps@\(c.index)") }
            if overlapsAny(start: c.startMs, end: c.endMs, ranges: lowConf) {
                flags.append("low-confidence@\(c.index)")
            }
        }
        return Result(cues: cleaned, qaFlags: flags)
    }

    // MARK: - Helpers

    static func isLowConfidence(_ seg: ASRSegment, _ config: Config) -> Bool {
        if let lp = seg.avgLogprob, lp < config.minAvgLogprob { return true }
        let probs = seg.words.compactMap { $0.probability }
        if !probs.isEmpty {
            let mean = probs.reduce(0, +) / Double(probs.count)
            if mean < config.minWordProbability { return true }
        }
        return false
    }

    private static func overlapsAny(start: Int, end: Int, ranges: [(Int, Int)]) -> Bool {
        ranges.contains { start < $0.1 && end > $0.0 }
    }

    /// Collapse a window (1–4 words) that repeats ≥3× in a row down to a single copy —
    /// the signature of a Whisper decode loop. Two repeats ("very very") are preserved.
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3 else { return text }
        var changed = true
        var guardCounter = 0
        while changed && guardCounter < 1_000 {
            changed = false
            guardCounter += 1
            search: for k in 1 ... min(4, words.count / 2) {
                var i = 0
                while i + 2 * k <= words.count {
                    let window = Array(words[i ..< i + k])
                    var reps = 1
                    var j = i + k
                    while j + k <= words.count && Array(words[j ..< j + k]) == window {
                        reps += 1; j += k
                    }
                    if reps >= 3 {
                        words.removeSubrange((i + k) ..< (i + k * reps))
                        changed = true
                        break search
                    }
                    i += 1
                }
            }
        }
        return words.joined(separator: " ")
    }
}
