// DTWAligner — align a subtitle's words to the words the ASR actually heard,
// producing (subtitleTime, spokenTime) anchors for the robust fit (handoff §6.4).
//
// The two streams say roughly the same thing but never exactly: the ASR mis-hears,
// the subtitle paraphrases or condenses, one has "gonna" where the other has "going
// to". Dynamic time warping is the right tool — it finds the lowest-cost monotonic
// correspondence, absorbing insertions and deletions on both sides.
//
// Full DTW over a feature film is 20k x 20k cells, which is neither fast nor
// necessary: the two streams are already close in time (alass has removed the gross
// offset before we run), so the true path stays near the diagonal. A Sakoe-Chiba
// BAND of ±`band` cells around it makes the cost O(N x band) — seconds, not minutes
// — while still allowing far more drift than any real subtitle file has.
//
// Anchors are taken ONLY from speech-onset tokens (`tokenIdx <= 1`) matched with low
// cost. A cue's start is when speech begins; its end is padded with reading time, so
// anchoring on ends would bake that padding into the fit.

import Foundation

public enum DTWAligner {
    public struct Anchor: Sendable, Equatable {
        public var cueIdx: Int
        /// Cue start in the (possibly wrong) subtitle timeline.
        public var subtitleMs: Int
        /// When the matching word was actually spoken.
        public var spokenMs: Int
    }

    /// Match subtitle tokens against ASR word tokens and return onset anchors.
    ///
    /// - `band`: half-width of the search band, in tokens. The default tolerates a
    ///   very large local mismatch (hundreds of words) and still bounds the work.
    public static func anchors(
        cues: [SubtitleCue],
        words: [ASRWord],
        band: Int = 400
    ) -> [Anchor] {
        let subTokens = SubtitleTokenizer.tokens(cues: cues)
        let refTokens = SubtitleTokenizer.tokens(words: words)
        guard !subTokens.isEmpty, !refTokens.isEmpty else { return [] }

        let pairs = align(subTokens.map { $0.text }, refTokens.map { $0.text }, band: band)

        var out: [Anchor] = []
        var seenCue = Set<Int>()
        for (i, j) in pairs {
            let token = subTokens[i]
            // One anchor per cue, from its earliest confidently-matched onset token.
            guard token.isOnset, !seenCue.contains(token.cueIdx) else { continue }
            guard matchCost(token.text, refTokens[j].text) <= prefixCost else { continue }
            seenCue.insert(token.cueIdx)
            out.append(Anchor(cueIdx: token.cueIdx,
                              subtitleMs: cues[token.cueIdx].startMs,
                              spokenMs: refTokens[j].startMs))
        }
        return out.sorted { $0.subtitleMs < $1.subtitleMs }
    }

    // MARK: - Banded DTW

    /// Cost of substituting one token for another.
    /// 0 identical · 0.35 shared prefix (the ASR heard part of the word) · 1 unrelated.
    static let prefixCost = 0.35
    static func matchCost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        let n = min(a.count, b.count)
        guard n >= 3 else { return 1 }
        return a.prefix(n) == b.prefix(n) ? prefixCost : 1
    }

    /// Skipping a token on either side. Below 1.0 so the path prefers dropping a
    /// mismatched word over forcing a wrong substitution.
    private static let skipCost = 0.9

    /// Lowest-cost monotonic matching within the band, as (subIdx, refIdx) pairs.
    static func align(_ a: [String], _ b: [String], band: Int) -> [(Int, Int)] {
        let n = a.count, m = b.count
        // Band must cover the length difference, or no path can reach the end.
        let band = max(band, abs(n - m) + 1)
        let inf = Double.infinity

        // Only cells within the band are stored: row i covers [lo(i), hi(i)].
        func lo(_ i: Int) -> Int { max(0, i * m / max(n, 1) - band) }
        func hi(_ i: Int) -> Int { min(m - 1, i * m / max(n, 1) + band) }

        var prev = [Double](repeating: inf, count: m + 1)
        var cur = [Double](repeating: inf, count: m + 1)
        // Backpointers: 0 = match, 1 = skip sub token, 2 = skip ref token.
        var moves = [[UInt8]](repeating: [], count: n + 1)

        prev[0] = 0
        for j in 1 ... m { prev[j] = prev[j - 1] + skipCost }
        moves[0] = [UInt8](repeating: 2, count: m + 1)

        for i in 1 ... n {
            for k in cur.indices { cur[k] = inf }
            var row = [UInt8](repeating: 0, count: m + 1)
            let l = max(1, lo(i - 1)), h = min(m, hi(i - 1) + 1)
            if l <= 1 { cur[0] = prev[0] + skipCost; row[0] = 1 }
            for j in l ... max(l, h) where j <= m {
                let mCost = prev[j - 1] + matchCost(a[i - 1], b[j - 1])
                let dCost = prev[j] + skipCost        // skip this subtitle token
                let iCost = cur[j - 1] + skipCost     // skip this ASR token
                if mCost <= dCost && mCost <= iCost {
                    cur[j] = mCost; row[j] = 0
                } else if dCost <= iCost {
                    cur[j] = dCost; row[j] = 1
                } else {
                    cur[j] = iCost; row[j] = 2
                }
            }
            moves[i] = row
            swap(&prev, &cur)
        }

        // Walk back from (n, m) collecting only real matches.
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            let move = moves[i].indices.contains(j) ? moves[i][j] : 1
            switch move {
            case 0: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return pairs.reversed()
    }
}
