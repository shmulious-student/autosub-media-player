// SentenceRegrouper — keep subtitle timing in sync when the source splits a single
// sentence across several cues (common in distributor-embedded subtitles, and in
// our own ASR segmenter's 42-char cues).
//
// THE PROBLEM: if cues 1–3 are fragments of one sentence ("Well, actually," /
// "our research has shown" / "that diarrhea is…"), the translator sees them and
// (correctly) produces ONE Hebrew sentence — but it can no longer keep a 1:1 line
// mapping, so the Hebrew slides relative to the cue timing and the whole track
// reads out of sync.
//
// THE FIX: group fragment-cues into whole sentences, translate each sentence as a
// unit (best Hebrew quality, stable 1:1), then REDISTRIBUTE the Hebrew back across
// the group's original cues by source weight, at word boundaries — every original
// cue keeps its exact start/end, so timing can never drift.

import Foundation

/// One sentence: the original cues it spans (their indices + per-cue source weight)
/// and the combined source text the translator should see as a unit.
public struct SentenceGroup: Sendable {
    public var cueIndices: [Int] // original SubtitleCue.index values, in order
    public var weights: [Int]    // per-cue source weight (char count) for the split
    public var text: String      // combined source text (one sentence)
    public var startMs: Int
    public var endMs: Int

    public init(cueIndices: [Int], weights: [Int], text: String, startMs: Int, endMs: Int) {
        self.cueIndices = cueIndices
        self.weights = weights
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum SentenceRegrouper {
    private static let enders: Set<Character> = [".", "!", "?", "…", "。", "؟", "׃"]

    /// Group consecutive cues into sentences. A group closes after a cue whose text
    /// ends a sentence, on a scene-sized time gap, or at a safety cap on group size.
    public static func group(
        _ cues: [SubtitleCue],
        sceneGapMs: Int = 2_500,
        maxCuesPerSentence: Int = 8
    ) -> [SentenceGroup] {
        var out: [SentenceGroup] = []
        var idxs: [Int] = []
        var weights: [Int] = []
        var texts: [String] = []
        var startMs = 0
        var endMs = 0
        var prevEnd: Int?

        func flush() {
            guard !idxs.isEmpty else { return }
            out.append(SentenceGroup(
                cueIndices: idxs, weights: weights,
                text: texts.joined(separator: " "),
                startMs: startMs, endMs: endMs))
            idxs.removeAll(keepingCapacity: true)
            weights.removeAll(keepingCapacity: true)
            texts.removeAll(keepingCapacity: true)
        }

        for cue in cues {
            let gap = prevEnd.map { cue.startMs - $0 } ?? 0
            if !idxs.isEmpty && (gap >= sceneGapMs || idxs.count >= maxCuesPerSentence) {
                flush()
            }
            if idxs.isEmpty { startMs = cue.startMs }
            idxs.append(cue.index)
            weights.append(max(1, cue.text.count))
            texts.append(cue.text)
            endMs = cue.endMs
            prevEnd = cue.endMs

            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.last, enders.contains(last) { flush() }
        }
        flush()
        return out
    }

    /// Translate sentence groups into per-original-cue text by redistributing each
    /// translated sentence across its source cues. `translationBySentence` is keyed
    /// by sentence ordinal (0-based, matching the order of `groups`).
    public static func redistribute(
        groups: [SentenceGroup],
        translationBySentence: [Int: String]
    ) -> [Int: String] {
        var byCue: [Int: String] = [:]
        for (i, g) in groups.enumerated() {
            let hebrew = translationBySentence[i] ?? g.text
            let parts = SentenceRedistributor.split(hebrew, weights: g.weights)
            for (k, cueIndex) in g.cueIndices.enumerated() {
                byCue[cueIndex] = k < parts.count ? parts[k] : ""
            }
        }
        return byCue
    }
}

public enum SentenceRedistributor {
    /// Split [text] into `weights.count` parts at WORD boundaries, each part sized
    /// proportional to its weight. Never breaks a word; distributes any rounding
    /// remainder to the last part. A single-cue group returns the text unchanged.
    public static func split(_ text: String, weights: [Int]) -> [String] {
        let n = weights.count
        if n <= 1 { return [text] }
        let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
        if words.isEmpty { return Array(repeating: "", count: n) }
        if words.count <= n {
            // Fewer words than cues: one word per leading cue, rest empty. Keeps
            // each word on the cue whose source position it best matches.
            var out = Array(repeating: "", count: n)
            for (k, w) in words.enumerated() { out[min(k, n - 1)] = w }
            return out
        }

        let totalWeight = max(weights.reduce(0, +), 1)
        // Target integer word count per cue, proportional to weight.
        var counts = weights.map {
            Int((Double(words.count) * Double($0) / Double(totalWeight)).rounded())
        }
        // Reconcile the rounded counts to exactly words.count (each part ≥ 1 where
        // possible, so no cue in a multi-cue sentence goes blank).
        for i in 0..<n where counts[i] < 1 { counts[i] = 1 }
        var assigned = counts.reduce(0, +)
        var guardCounter = 0
        while assigned != words.count && guardCounter < 10_000 {
            if assigned > words.count {
                // Trim from the largest part (never below 1).
                if let j = counts.indices.filter({ counts[$0] > 1 }).max(by: { counts[$0] < counts[$1] }) {
                    counts[j] -= 1; assigned -= 1
                } else { break }
            } else {
                // Add to the part with the most source weight.
                if let j = weights.indices.max(by: { weights[$0] < weights[$1] }) {
                    counts[j] += 1; assigned += 1
                } else { break }
            }
            guardCounter += 1
        }

        var out: [String] = []
        var pos = 0
        for c in counts {
            let end = min(pos + c, words.count)
            out.append(words[pos..<end].joined(separator: " "))
            pos = end
        }
        if pos < words.count, !out.isEmpty {
            out[out.count - 1] += " " + words[pos...].joined(separator: " ")
        }
        return out
    }
}
