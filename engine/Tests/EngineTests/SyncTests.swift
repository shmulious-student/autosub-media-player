// Tests for the subtitle synchronization engine: tokenization, the robust fit, and
// the end-to-end acceptance case the sister project defined —
//   "take a correct SRT, shift it +2.3 s and stretch it 0.5%, re-sync it, and the
//    median cue error must come back under 100 ms."
// That case is reproduced here against synthetic ASR word timings, so it runs in
// CI with no media file, no alass binary and no model.

import XCTest
@testable import Engine

final class SubtitleTokenizerTests: XCTestCase {
    func testSplitsHyphenatedStutterIntoRealWords() {
        // The failure this exists to prevent: whitespace-only splitting turns
        // "an-an-and" into "ananand", which matches nothing the ASR produced.
        XCTAssertEqual(SubtitleTokenizer.tokenize("I-I-I figure"), ["i", "i", "i", "figure"])
        XCTAssertEqual(SubtitleTokenizer.tokenize("an-an-and then"), ["an", "an", "and", "then"])
        XCTAssertEqual(SubtitleTokenizer.tokenize("New-York's-subway-system"),
                       ["new", "yorks", "subway", "system"])
    }

    func testNormalizationIgnoresCasePunctuationAndDiacritics() {
        XCTAssertEqual(SubtitleTokenizer.normalize("Figure,"), "figure")
        XCTAssertEqual(SubtitleTokenizer.normalize("café"), "cafe")
        XCTAssertEqual(SubtitleTokenizer.tokenize("— Wait... what?!"), ["wait", "what"])
    }

    func testOnsetTokensAreTheFirstTwoOfEachCue() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1_000, text: "one two three four")]
        let tokens = SubtitleTokenizer.tokens(cues: cues)
        XCTAssertEqual(tokens.map { $0.isOnset }, [true, true, false, false])
    }

    func testHyphenatedAsrWordSplitsAndKeepsPlausibleTiming() {
        let out = SubtitleTokenizer.tokens(words: [
            ASRWord(text: "I-I-I", startMs: 1_000, endMs: 1_600),
        ])
        XCTAssertEqual(out.map { $0.text }, ["i", "i", "i"])
        XCTAssertEqual(out[0].startMs, 1_000)
        XCTAssertGreaterThan(out[2].startMs, out[0].startMs)
    }
}

final class TheilSenTests: XCTestCase {
    func testRecoversASlopeAndOffset() {
        // y = 0.995x + 2300, sampled every 5 s across 90 s.
        let anchors = stride(from: 0, through: 90_000, by: 5_000).map { x -> (x: Double, y: Double) in
            (Double(x), 0.995 * Double(x) + 2_300)
        }
        let fit = TheilSen.fit(anchors: anchors)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slope, 0.995, accuracy: 0.0005)
        XCTAssertEqual(fit!.interceptMs, 2_300, accuracy: 20)
    }

    func testIgnoresOutliersThatWouldWreckLeastSquares() {
        var anchors = stride(from: 0, through: 90_000, by: 5_000).map { x -> (x: Double, y: Double) in
            (Double(x), Double(x) + 1_000)
        }
        // Four badly-matched anchors, each many seconds off.
        anchors[2].y += 30_000
        anchors[5].y -= 25_000
        anchors[11].y += 40_000
        anchors[13].y -= 18_000
        let fit = TheilSen.fit(anchors: anchors)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slope, 1.0, accuracy: 0.01)
        XCTAssertEqual(fit!.interceptMs, 1_000, accuracy: 300)
    }

    func testRefusesAnImplausibleFitRatherThanReturningOne() {
        // Random noise must not produce a "correction" — better to leave timings alone.
        let anchors: [(x: Double, y: Double)] = [
            (0, 0), (20_000, 90_000), (40_000, 5_000), (60_000, 150_000), (80_000, 1_000),
        ]
        XCTAssertNil(TheilSen.fit(anchors: anchors))
    }

    func testTooFewAnchorsIsNoFit() {
        XCTAssertNil(TheilSen.fit(anchors: [(0, 0), (20_000, 20_000)]))
    }
}

final class SubtitleSyncTests: XCTestCase {
    /// A 90 s dialogue: 36 cues of five distinct words each, spoken 100 ms after the
    /// cue appears (the standard reading lead-in the engine calibrates for).
    private func fixture() -> (cues: [SubtitleCue], words: [ASRWord]) {
        let vocabulary = [
            "figure", "they", "using", "mirrors", "something", "hide", "entrance",
            "sorry", "following", "room", "didn't", "notice", "before", "power",
            "years", "quiet", "listen", "someone", "downstairs", "waiting", "door",
            "locked", "outside", "morning", "afraid", "never", "again", "promise",
        ]
        var cues: [SubtitleCue] = []
        var words: [ASRWord] = []
        for i in 0 ..< 36 {
            let start = i * 2_500
            let text = (0 ..< 5).map { "\(vocabulary[($0 + i * 5) % vocabulary.count])\(i)" }
            cues.append(SubtitleCue(index: i + 1, startMs: start, endMs: start + 2_000,
                                    text: text.joined(separator: " ")))
            for (k, w) in text.enumerated() {
                let ws = start + 100 + k * 350
                words.append(ASRWord(text: w, startMs: ws, endMs: ws + 300))
            }
        }
        return (cues, words)
    }

    /// Apply the acceptance-case perturbation: +2.3 s and a 0.5% stretch.
    private func perturb(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map {
            var c = $0
            c.startMs = Int((Double($0.startMs) * 1.005).rounded()) + 2_300
            c.endMs = Int((Double($0.endMs) * 1.005).rounded()) + 2_300
            return c
        }
    }

    private func errors(_ got: [SubtitleCue], _ truth: [SubtitleCue]) -> [Int] {
        zip(got, truth).map { abs($0.startMs - $1.startMs) }
    }

    func testShiftAndStretchAreBothCorrectedUnderTheAcceptanceBar() {
        let (truth, words) = fixture()
        let perturbed = perturb(truth)

        let before = errors(perturbed, truth)
        XCTAssertGreaterThan(Int(TheilSen.median(before.map(Double.init))), 2_000,
                             "the fixture must actually be badly out of sync to begin with")

        let (fixed, report) = SubtitleSync.refine(cues: perturbed, words: words)
        let after = errors(fixed, truth)
        let median = Int(TheilSen.median(after.map(Double.init)))

        XCTAssertNil(report.skippedReason)
        XCTAssertGreaterThanOrEqual(report.anchorCount, 30)
        XCTAssertLessThan(median, 100, "median cue error after refinement (got \(median) ms)")
        XCTAssertLessThan(after.max() ?? .max, 250, "worst cue error")
        // The 0.5% stretch means the fitted slope must be ≈ 1/1.005.
        XCTAssertEqual(report.mapping?.slope ?? 0, 1 / 1.005, accuracy: 0.003)
    }

    func testPureOffsetIsAlsoCorrected() {
        let (truth, words) = fixture()
        let shifted = truth.map { c -> SubtitleCue in
            var x = c; x.startMs += 4_000; x.endMs += 4_000; return x
        }
        let (fixed, _) = SubtitleSync.refine(cues: shifted, words: words)
        XCTAssertLessThan(Int(TheilSen.median(errors(fixed, truth).map(Double.init))), 100)
    }

    func testLeadInIsAppliedSoCuesPrecedeSpeech() {
        let (truth, words) = fixture()
        let (fixed, _) = SubtitleSync.refine(cues: perturb(truth), words: words)
        // Every cue should come up shortly BEFORE its first spoken word, not after.
        for (i, c) in fixed.enumerated() {
            let firstWord = words[i * 5].startMs
            XCTAssertLessThan(c.startMs, firstWord + 40,
                              "cue \(i) starts after the speech it subtitles")
        }
    }

    func testUnrelatedTranscriptLeavesTimingsAlone() {
        // A transcript of a different film must produce no anchors and therefore no
        // "correction" — silently mangling the timing would be much worse than nothing.
        let (truth, _) = fixture()
        let noise = (0 ..< 200).map {
            ASRWord(text: "zzz\($0)", startMs: $0 * 400, endMs: $0 * 400 + 200)
        }
        let (out, report) = SubtitleSync.refine(cues: truth, words: noise)
        XCTAssertNotNil(report.skippedReason)
        XCTAssertEqual(out.map { $0.startMs }, truth.map { $0.startMs })
    }

    func testOrderingAndMinimumGapAreEnforced() {
        var cues = [
            SubtitleCue(index: 1, startMs: 1_000, endMs: 3_000, text: "a"),
            SubtitleCue(index: 2, startMs: 2_000, endMs: 2_500, text: "b"),  // overlaps
            SubtitleCue(index: 3, startMs: 1_500, endMs: 1_800, text: "c"),  // out of order
        ]
        SubtitleSync.enforceOrdering(&cues, minGapMs: 20)
        XCTAssertEqual(cues[1].startMs, 3_020)
        XCTAssertGreaterThanOrEqual(cues[2].startMs, cues[1].endMs + 20)
        for i in 1 ..< cues.count {
            XCTAssertGreaterThan(cues[i].startMs, cues[i - 1].endMs)
            XCTAssertGreaterThan(cues[i].endMs, cues[i].startMs)
        }
    }

    func testNearestSnapsOnlyWithinTheWindow() {
        let starts = [1_000, 5_000, 9_000]
        XCTAssertEqual(SubtitleSync.nearest(starts, to: 5_120, within: 250), 5_000)
        XCTAssertNil(SubtitleSync.nearest(starts, to: 7_000, within: 250))
    }
}
