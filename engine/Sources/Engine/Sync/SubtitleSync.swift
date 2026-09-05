// SubtitleSync — the two-stage subtitle synchronization engine (handoff §6).
//
//   Stage 1  alass --no-split           removes the gross global offset.
//   Stage 2  DTW + Theil-Sen            removes the residual drift, per cue.
//
// Stage 1 alone leaves ~154 ms median error on a track with a non-standard stretch,
// because alass can only try standard framerate ratios (see AlassRunner). Stage 2
// closes that gap by aligning the subtitle's own words against the words the ASR
// heard, fitting a robust line through the speech-onset anchors, and re-timing every
// cue on it: measured 26 ms median / 66 ms worst case on the sister project's
// fixture, against a <100 ms acceptance bar.
//
// Three corrections are applied after the fit, and each matters on real files:
//
//   LEAD-IN (+100 ms). A subtitle that appears exactly when the sound starts reads
//   as late — the eye needs a moment. Broadcast practice puts the cue up slightly
//   BEFORE the speech, so the fitted speech onset is shifted back by 100 ms.
//
//   SNAPPING. The fitted line is a global average; individual cues can still sit a
//   few tens of ms off a word boundary. Where a spoken word starts within
//   `snapWindowMs` of a fitted cue start, we take the word's own timestamp — the
//   ground truth beats the model.
//
//   MONOTONICITY + MINIMUM GAP. Independent per-cue corrections can reorder or
//   overlap neighbours, which players render as flicker or dropped cues. Cue starts
//   are forced non-decreasing and consecutive cues are kept at least `minGapMs`
//   apart, so the output is always a well-formed track.

import Foundation

public struct SubtitleSyncReport: Sendable {
    public var alassApplied: Bool
    public var anchorCount: Int
    public var mapping: TimeMapping?
    /// Median absolute shift applied to a cue start, in ms — how much work stage 2 did.
    public var medianShiftMs: Int
    public var snappedCues: Int
    /// Set when stage 2 declined to act (too few anchors, implausible fit).
    public var skippedReason: String?
}

public struct SubtitleSyncOptions: Sendable {
    /// Human reading lead-in: the cue goes up this long before the speech.
    public var leadInMs: Int
    /// Snap a fitted cue start to a spoken word within this distance.
    public var snapWindowMs: Int
    /// Minimum gap enforced between consecutive cues.
    public var minGapMs: Int
    /// Anchors must be at least this far apart to contribute a pairwise slope.
    public var minAnchorSpanMs: Double
    /// Below this many anchors we refuse to re-time anything.
    public var minAnchors: Int

    public init(leadInMs: Int = 100, snapWindowMs: Int = 250, minGapMs: Int = 20,
                minAnchorSpanMs: Double = 15_000, minAnchors: Int = 4) {
        self.leadInMs = leadInMs
        self.snapWindowMs = snapWindowMs
        self.minGapMs = minGapMs
        self.minAnchorSpanMs = minAnchorSpanMs
        self.minAnchors = minAnchors
    }

    public static let `default` = SubtitleSyncOptions()
}

public enum SubtitleSync {
    /// Stage 2 only: re-time `cues` against ASR word timings.
    ///
    /// Returns the cues unchanged (with `skippedReason` set) whenever the evidence is
    /// too thin to justify moving them — a subtitle that is merely *probably* wrong is
    /// better than one confidently moved to the wrong place.
    public static func refine(
        cues: [SubtitleCue],
        words: [ASRWord],
        options: SubtitleSyncOptions = .default
    ) -> (cues: [SubtitleCue], report: SubtitleSyncReport) {
        var report = SubtitleSyncReport(
            alassApplied: false, anchorCount: 0, mapping: nil,
            medianShiftMs: 0, snappedCues: 0, skippedReason: nil)
        guard !cues.isEmpty, !words.isEmpty else {
            report.skippedReason = "no cues or no ASR words"
            return (cues, report)
        }

        let anchors = DTWAligner.anchors(cues: cues, words: words)
        report.anchorCount = anchors.count
        guard anchors.count >= options.minAnchors else {
            report.skippedReason = "only \(anchors.count) anchors (need \(options.minAnchors))"
            return (cues, report)
        }

        guard let mapping = TheilSen.fit(
            anchors: anchors.map { (x: Double($0.subtitleMs), y: Double($0.spokenMs)) },
            minSpanMs: options.minAnchorSpanMs, minAnchors: options.minAnchors)
        else {
            report.skippedReason = "no plausible fit through \(anchors.count) anchors"
            return (cues, report)
        }
        report.mapping = mapping

        let wordStarts = words.map { $0.startMs }.sorted()
        let wordEnds = words.map { $0.endMs }.sorted()

        var shifts: [Int] = []
        var out = cues
        for i in out.indices {
            let duration = out[i].durationMs
            // Fitted speech onset, then backed off by the reading lead-in.
            var start = mapping.apply(out[i].startMs) - options.leadInMs
            var end = mapping.apply(out[i].endMs)

            if let snapped = nearest(wordStarts, to: start + options.leadInMs,
                                     within: options.snapWindowMs) {
                start = snapped - options.leadInMs
                report.snappedCues += 1
            }
            if let snapped = nearest(wordEnds, to: end, within: options.snapWindowMs) {
                end = snapped
            }
            // Never let snapping collapse or invert a cue.
            if end <= start { end = start + max(duration, 500) }

            shifts.append(abs(start - out[i].startMs))
            out[i].startMs = max(0, start)
            out[i].endMs = max(out[i].startMs + 1, end)
        }

        enforceOrdering(&out, minGapMs: options.minGapMs)
        report.medianShiftMs = Int(TheilSen.median(shifts.map(Double.init)))
        return (out, report)
    }

    /// The full pipeline: alass macro sync (when the binary and video are available),
    /// then the DTW/Theil-Sen refinement.
    ///
    /// `alassOutputPath` is where the intermediate alass result is written; pass a
    /// temporary path. When alass is unavailable the function silently runs stage 2
    /// alone, which handles offset and drift together — just with less margin.
    public static func synchronize(
        cues: [SubtitleCue],
        words: [ASRWord],
        videoPath: String? = nil,
        subtitlePath: String? = nil,
        alassOutputPath: String? = nil,
        options: SubtitleSyncOptions = .default,
        alassOptions: AlassOptions = .default
    ) -> (cues: [SubtitleCue], report: SubtitleSyncReport) {
        var working = cues
        var alassApplied = false

        if let videoPath, let subtitlePath, let alassOutputPath,
           AlassRunner.align(videoPath: videoPath, subtitlePath: subtitlePath,
                             outputPath: alassOutputPath, options: alassOptions),
           let shifted = SubtitleExtractor().cuesFromFile(path: alassOutputPath),
           shifted.count == cues.count {
            // Take alass's TIMING only, keeping our own text: alass rewrites the file
            // and we do not want a round-trip through its parser to change the text.
            for i in working.indices {
                working[i].startMs = shifted[i].startMs
                working[i].endMs = shifted[i].endMs
            }
            alassApplied = true
        }

        var (refined, report) = refine(cues: working, words: words, options: options)
        report.alassApplied = alassApplied
        // Stage 2 declining is not a failure when stage 1 did land — keep its result.
        if report.skippedReason != nil { refined = working }
        return (refined, report)
    }

    // MARK: - Helpers

    /// Nearest value in a SORTED array within `window` ms, else nil.
    static func nearest(_ sorted: [Int], to target: Int, within window: Int) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0, hi = sorted.count - 1, best = sorted[0]
        while lo <= hi {
            let mid = (lo + hi) / 2
            if abs(sorted[mid] - target) < abs(best - target) { best = sorted[mid] }
            if sorted[mid] < target { lo = mid + 1 } else { hi = mid - 1 }
        }
        return abs(best - target) <= window ? best : nil
    }

    /// Force non-decreasing starts and a minimum gap between cues, so no player ever
    /// sees an inverted or overlapping track.
    static func enforceOrdering(_ cues: inout [SubtitleCue], minGapMs: Int) {
        for i in 1 ..< max(cues.count, 1) {
            let floor = cues[i - 1].endMs + minGapMs
            if cues[i].startMs < floor {
                let duration = cues[i].durationMs
                cues[i].startMs = floor
                cues[i].endMs = max(floor + 1, floor + duration)
            }
            if cues[i].endMs <= cues[i].startMs {
                cues[i].endMs = cues[i].startMs + 1
            }
        }
    }
}
