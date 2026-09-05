// TheilSen — robust linear fit of subtitle time → true speech time (handoff §6.4).
//
// After DTW we have anchor pairs (subtitleTime, spokenTime). Fitting a line through
// them recovers BOTH kinds of desync at once: a constant offset (intercept) and a
// framerate/stretch drift (slope). Least squares cannot be used here — a handful of
// anchors are always wrong (the ASR mis-hears a word, a cue paraphrases, a repeated
// line matches the wrong occurrence), and a single outlier several seconds off will
// drag an least-squares line across the whole file.
//
// Theil-Sen takes the MEDIAN of all pairwise slopes, so it tolerates up to ~29% of
// anchors being arbitrarily wrong and still returns the right line. The pairs are
// restricted to anchors at least `minSpanMs` apart because a slope measured across
// two nearby anchors is dominated by their individual timing noise: two anchors 1 s
// apart with ±50 ms of error imply a slope anywhere in [0.90, 1.10], which is noise,
// not drift. Across 15 s the same error is ±0.3%.

import Foundation

public struct TimeMapping: Sendable, Equatable {
    /// Multiplier on subtitle time — 1.0 means no stretch. A 0.5% fast subtitle
    /// track fits ≈0.995.
    public var slope: Double
    /// Constant offset in milliseconds.
    public var interceptMs: Double
    /// How many anchors the fit was built from.
    public var anchorCount: Int

    public init(slope: Double, interceptMs: Double, anchorCount: Int) {
        self.slope = slope
        self.interceptMs = interceptMs
        self.anchorCount = anchorCount
    }

    public static let identity = TimeMapping(slope: 1, interceptMs: 0, anchorCount: 0)

    public func apply(_ ms: Int) -> Int { Int((Double(ms) * slope + interceptMs).rounded()) }
}

public enum TheilSen {
    /// Fit `y = slope * x + intercept` robustly.
    ///
    /// - `minSpanMs`: ignore pairs closer together than this on the x axis (see header).
    /// - Returns nil when there are too few usable pairs to fit anything — the caller
    ///   must then leave timings alone rather than apply a guess.
    public static func fit(anchors: [(x: Double, y: Double)],
                           minSpanMs: Double = 15_000,
                           minAnchors: Int = 4) -> TimeMapping? {
        guard anchors.count >= minAnchors else { return nil }

        var slopes: [Double] = []
        slopes.reserveCapacity(anchors.count * 4)
        for i in 0 ..< anchors.count {
            for j in (i + 1) ..< anchors.count {
                let dx = anchors[j].x - anchors[i].x
                guard abs(dx) >= minSpanMs else { continue }
                slopes.append((anchors[j].y - anchors[i].y) / dx)
            }
        }
        // Too short a clip (or too few spread-out anchors) to measure drift: fall back
        // to a pure offset fit, which is still far better than nothing.
        let slope = slopes.isEmpty ? 1.0 : median(slopes)
        // A wild slope means the anchors are garbage, not that the film is stretched
        // 40%. Refuse rather than destroy the timing.
        guard slope.isFinite, slope > 0.8, slope < 1.25 else { return nil }

        let intercept = median(anchors.map { $0.y - slope * $0.x })
        guard intercept.isFinite else { return nil }
        return TimeMapping(slope: slope, interceptMs: intercept, anchorCount: anchors.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}
