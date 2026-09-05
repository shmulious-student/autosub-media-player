// SceneSegmenter — group cues into NARRATIVE scenes (handoff §3).
//
// `ScenePacketer` already splits cues into packets, but it is a TOKEN-BUDGET
// splitter: it cuts on a 2.5 s gap and on line/char caps so a packet fits the
// context window. That is the wrong unit for situational context. A scene is a
// stretch of story — the same people, the same place, the same situation — and it
// is what a one-or-two-sentence synopsis can meaningfully describe.
//
// Why it matters: an isolated line like "It's open." is ambiguous (a door? a
// container? a shop? a schedule?). Given "They are breaking into a locked
// storeroom at night", it is not. The synopsis is generated once per scene and
// injected into every packet prompt inside that scene, so register and word
// choice stay consistent instead of drifting batch to batch.
//
// Segmentation is DETERMINISTIC (no LLM), so it is cheap, reproducible, and
// unit-testable. Boundaries come from three signals:
//   1. Silence gap  — >= 8 s with nobody speaking is the classic scene cut.
//   2. Speaker shift — the cast talking before and after a point is disjoint.
//   3. Density jump — the cue rate changes sharply (a lull becoming an argument).
// Duration is then clamped to [10 s, 120 s]: shorter scenes cannot support a
// useful synopsis, longer ones stop being one situation.

import Foundation

/// A contiguous run of cues that share one situation.
public struct DialogueScene: Sendable, Equatable {
    /// Indices INTO THE CUE ARRAY passed to `segment` (not `SubtitleCue.index`).
    public var range: Range<Int>
    public var startMs: Int
    public var endMs: Int
    /// Distinct `speakerId`s heard in this scene (empty when cues carry no speaker).
    public var speakers: Set<String>
    /// 1–2 sentence situational summary, filled in later by `SceneSynopsis`.
    public var synopsis: String?

    public var durationMs: Int { max(0, endMs - startMs) }
    public var cueCount: Int { range.count }

    public init(range: Range<Int>, startMs: Int, endMs: Int,
                speakers: Set<String> = [], synopsis: String? = nil) {
        self.range = range
        self.startMs = startMs
        self.endMs = endMs
        self.speakers = speakers
        self.synopsis = synopsis
    }
}

public enum SceneSegmenter {
    public struct Config: Sendable {
        /// A silence at least this long is a scene cut.
        public var silenceGapMs: Int
        /// A scene shorter than this is merged into its neighbour (too little to summarize).
        public var minDurationMs: Int
        /// A scene is force-cut once it runs this long (it is no longer one situation).
        public var maxDurationMs: Int
        /// Cue-rate ratio (either direction) that counts as a density inflection.
        public var densityRatio: Double
        /// Cues on each side of a candidate point used for the speaker/density windows.
        public var windowCues: Int

        public init(silenceGapMs: Int = 8_000, minDurationMs: Int = 10_000,
                    maxDurationMs: Int = 120_000, densityRatio: Double = 2.5,
                    windowCues: Int = 4) {
            self.silenceGapMs = silenceGapMs
            self.minDurationMs = minDurationMs
            self.maxDurationMs = maxDurationMs
            self.densityRatio = densityRatio
            self.windowCues = windowCues
        }

        public static let `default` = Config()
    }

    /// Split `cues` (assumed time-ordered) into narrative scenes covering every cue.
    public static func segment(cues: [SubtitleCue], config: Config = .default) -> [DialogueScene] {
        guard !cues.isEmpty else { return [] }

        var boundaries: [Int] = []   // cue indices that START a new scene
        var sceneStart = 0

        for i in 1 ..< cues.count {
            let gap = cues[i].startMs - cues[i - 1].endMs
            let elapsed = cues[i].startMs - cues[sceneStart].startMs

            // A scene that has run too long is cut here regardless of signal.
            let overlong = elapsed >= config.maxDurationMs
            // Below the minimum, only an overlong scene may cut — a real silence
            // inside a 6 s exchange is still the same situation.
            let mayCut = elapsed >= config.minDurationMs

            let signal = gap >= config.silenceGapMs
                || speakerShift(cues, at: i, window: config.windowCues)
                || densityJump(cues, at: i, window: config.windowCues, ratio: config.densityRatio)

            if overlong || (mayCut && signal) {
                boundaries.append(i)
                sceneStart = i
            }
        }

        var scenes = build(cues: cues, boundaries: boundaries)
        scenes = mergeRunts(scenes, cues: cues, minDurationMs: config.minDurationMs)
        return scenes
    }

    // MARK: - Signals

    /// True when the cast speaking just before `i` and just after are DISJOINT —
    /// a different set of people is now talking, i.e. we cut to another scene.
    /// Returns false when cues carry no speaker labels (nothing to compare).
    static func speakerShift(_ cues: [SubtitleCue], at i: Int, window: Int) -> Bool {
        let before = speakers(cues, in: max(0, i - window) ..< i)
        let after = speakers(cues, in: i ..< min(cues.count, i + window))
        guard !before.isEmpty, !after.isEmpty else { return false }
        return before.isDisjoint(with: after)
    }

    private static func speakers(_ cues: [SubtitleCue], in range: Range<Int>) -> Set<String> {
        Set(range.compactMap { cues[$0].speakerId })
    }

    /// True when the cue RATE changes sharply across `i` — a slow, sparse stretch
    /// giving way to rapid exchange (or the reverse) usually means a new scene.
    static func densityJump(_ cues: [SubtitleCue], at i: Int, window: Int, ratio: Double) -> Bool {
        guard let before = cueRate(cues, in: max(0, i - window) ..< i),
              let after = cueRate(cues, in: i ..< min(cues.count, i + window)),
              before > 0, after > 0
        else { return false }
        return max(before, after) / min(before, after) >= ratio
    }

    /// Cues per second across a window, or nil when the window is too small/instant.
    private static func cueRate(_ cues: [SubtitleCue], in range: Range<Int>) -> Double? {
        guard range.count >= 2 else { return nil }
        let span = cues[range.upperBound - 1].endMs - cues[range.lowerBound].startMs
        guard span > 0 else { return nil }
        return Double(range.count) / (Double(span) / 1000.0)
    }

    // MARK: - Assembly

    private static func build(cues: [SubtitleCue], boundaries: [Int]) -> [DialogueScene] {
        var starts = [0]
        starts.append(contentsOf: boundaries)
        var out: [DialogueScene] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : cues.count
            guard start < end else { continue }
            out.append(scene(cues: cues, range: start ..< end))
        }
        return out
    }

    private static func scene(cues: [SubtitleCue], range: Range<Int>) -> DialogueScene {
        DialogueScene(
            range: range,
            startMs: cues[range.lowerBound].startMs,
            endMs: cues[range.upperBound - 1].endMs,
            speakers: speakers(cues, in: range)
        )
    }

    /// Fold any scene still under the minimum duration into its neighbour, so every
    /// scene is long enough to be worth summarizing. A lone short scene is kept.
    private static func mergeRunts(_ scenes: [DialogueScene], cues: [SubtitleCue],
                                   minDurationMs: Int) -> [DialogueScene] {
        guard scenes.count > 1 else { return scenes }
        var out: [DialogueScene] = []
        for s in scenes {
            if s.durationMs < minDurationMs, let last = out.last {
                out[out.count - 1] = scene(cues: cues, range: last.range.lowerBound ..< s.range.upperBound)
            } else {
                out.append(s)
            }
        }
        // A short FIRST scene can't merge backwards above; fold it forwards instead.
        if out.count > 1, out[0].durationMs < minDurationMs {
            let merged = scene(cues: cues, range: out[0].range.lowerBound ..< out[1].range.upperBound)
            out.replaceSubrange(0 ... 1, with: [merged])
        }
        return out
    }
}
