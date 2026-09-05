// Tests for the deterministic dialogue layer: the addressee ladder, scene
// segmentation, speaker-label recovery, and the prompt bindings they produce.
//
// These are the parts that must be RIGHT rather than merely plausible: everything
// here runs before the model and decides what the model is told as fact.

import XCTest
@testable import Engine

private func cue(_ i: Int, _ start: Int, _ end: Int, _ text: String,
                 speaker: String? = nil) -> SubtitleCue {
    SubtitleCue(index: i, startMs: start, endMs: end, text: text, speakerId: speaker)
}

final class AddresseeLadderTests: XCTestCase {
    private let roster = ["Danny": "m", "Maya": "f", "Sarah": "f"]

    // MARK: Rung 1 — vocatives

    func testVocativeLeadingTrailingAndAfterGreeting() {
        let r = Set(roster.keys)
        XCTAssertEqual(AddresseeResolver.vocative(in: "Danny, move!", roster: r), "Danny")
        XCTAssertEqual(AddresseeResolver.vocative(in: "Move it, Danny!", roster: r), "Danny")
        XCTAssertEqual(AddresseeResolver.vocative(in: "Hey, Maya, look at this.", roster: r), "Maya")
        XCTAssertEqual(AddresseeResolver.vocative(in: "- Sarah, wait.", roster: r), "Sarah")
    }

    func testVocativeIgnoresNonNamesAndOffRosterWords() {
        let r = Set(roster.keys)
        // A sentence-initial capitalized word that is not a name must not be read
        // as a vocative — that would bind the whole line to a nonexistent person.
        XCTAssertNil(AddresseeResolver.vocative(in: "Well, that went badly.", roster: r))
        XCTAssertNil(AddresseeResolver.vocative(in: "No, I don't think so.", roster: r))
        XCTAssertNil(AddresseeResolver.vocative(in: "Kevin, over here.", roster: r),
                     "a name that is not on the roster must not resolve")
    }

    func testVocativeWithoutRosterFallsBackToNameShape() {
        XCTAssertEqual(AddresseeResolver.vocative(in: "Danny, move!"), "Danny")
        XCTAssertNil(AddresseeResolver.vocative(in: "Yes, absolutely."))
    }

    func testVocativeWinsAndCarriesHighestConfidence() {
        let cues = [
            cue(1, 0, 1_500, "I'm going in.", speaker: "Maya"),
            cue(2, 2_000, 3_500, "Danny, move!", speaker: "Maya"),
        ]
        let b = AddresseeResolver.resolve(cues: cues, characters: roster)[1]
        XCTAssertEqual(b.method, .vocative)
        XCTAssertEqual(b.addressee, "Danny")
        XCTAssertEqual(b.addresseeGender, .m)
        XCTAssertEqual(b.addresseeNumber, .singular)
        XCTAssertEqual(b.confidence, 0.95, accuracy: 0.001)
    }

    // MARK: Rung 2 — direct reply

    func testDirectReplyBindsToThePreviousSpeakerWithinTheGap() {
        let cues = [
            cue(1, 0, 1_500, "Are we clear?", speaker: "Maya"),
            cue(2, 2_500, 4_000, "Not yet.", speaker: "Danny"),
        ]
        let b = AddresseeResolver.resolve(cues: cues, characters: roster)[1]
        XCTAssertEqual(b.method, .directReply)
        XCTAssertEqual(b.addressee, "Maya")
        XCTAssertEqual(b.addresseeGender, .f)
        XCTAssertEqual(b.confidence, 0.85, accuracy: 0.001)
    }

    func testGapTooLongIsNotAReply() {
        // 6 s of silence after the previous speaker: the new line is not a reply to
        // them, so we must not bind (and must not guess) an addressee.
        let cues = [
            cue(1, 0, 1_500, "Are we clear?", speaker: "Maya"),
            cue(2, 7_500, 9_000, "Not yet.", speaker: "Danny"),
            cue(3, 10_000, 11_000, "Right.", speaker: "Danny"),
        ]
        let bindings = AddresseeResolver.resolve(cues: cues, characters: roster)
        XCTAssertNotEqual(bindings[1].method, .directReply)
    }

    // MARK: Rung 3 — two-hander elimination

    func testTwoHanderResolvesByElimination() {
        // Three turns, two people, and a line with no vocative that is NOT a quick
        // reply (Danny speaks twice in a row) — only elimination can resolve it.
        let cues = [
            cue(1, 0, 2_000, "We should wait.", speaker: "Danny"),
            cue(2, 3_000, 5_000, "I disagree.", speaker: "Maya"),
            cue(3, 12_000, 14_000, "Fine.", speaker: "Danny"),
            cue(4, 20_000, 22_000, "I said fine.", speaker: "Danny"),
        ]
        let b = AddresseeResolver.resolve(cues: cues, characters: roster)[3]
        XCTAssertEqual(b.method, .twoHander)
        XCTAssertEqual(b.addressee, "Maya")
        XCTAssertEqual(b.confidence, 0.75, accuracy: 0.001)
    }

    // MARK: Rung 4 — group address

    func testGroupAddressIsPluralAndMasculineByDefault() {
        XCTAssertEqual(AddresseeResolver.groupGender(in: "Everyone, get down!"), .m)
        XCTAssertEqual(AddresseeResolver.groupGender(in: "Come on, guys."), .m)
        XCTAssertEqual(AddresseeResolver.groupGender(in: "Ladies, this way."), .f,
                       "an explicitly female group takes the feminine plural")
        XCTAssertNil(AddresseeResolver.groupGender(in: "Danny, move!"))
    }

    func testGroupAddressOutranksDirectReply() {
        // "Everyone" is plural no matter who spoke a second ago.
        let cues = [
            cue(1, 0, 1_500, "What now?", speaker: "Danny"),
            cue(2, 2_000, 3_500, "Everyone, get down!", speaker: "Maya"),
        ]
        let b = AddresseeResolver.resolve(cues: cues, characters: ["Danny": "m", "Maya": "f"])[1]
        XCTAssertEqual(b.method, .groupAddress)
        XCTAssertEqual(b.addresseeNumber, .plural)
        XCTAssertEqual(b.addresseeGender, .m)
    }

    // MARK: Rung 5 — unknown

    func testUnknownAddresseeDemandsNeutralPhrasingRatherThanAGuess() {
        // No speakers, no vocative, no group marker: nothing determines the addressee.
        let cues = [cue(1, 0, 2_000, "Keep moving.")]
        let b = AddresseeResolver.resolve(cues: cues)[0]
        XCTAssertEqual(b.method, .unknown)
        XCTAssertEqual(b.confidence, 0)
        XCTAssertNil(b.addressee)
        XCTAssertTrue(b.needsNeutralPhrasing)
    }

    func testKnownGroupIsNotTreatedAsNeedingNeutralPhrasing() {
        let cues = [cue(1, 0, 2_000, "Everyone, get down!")]
        XCTAssertFalse(AddresseeResolver.resolve(cues: cues)[0].needsNeutralPhrasing)
    }
}

final class BindingPromptTests: XCTestCase {
    func testBindingTagRendersSpeakerAndAddressee() {
        let b = DialogueBinding(cueIndex: 1, speaker: "Maya", speakerGender: .f,
                                addressee: "Danny", addresseeGender: .m,
                                addresseeNumber: .singular, method: .vocative, confidence: 0.95)
        XCTAssertEqual(ScenePacketTranslator.bindingTag(b),
                       "[SPEAKER: Maya (F)] [TO: Danny (M)] ")
    }

    func testUnknownAddresseeTagAsksForNeutralPhrasing() {
        let b = DialogueBinding(cueIndex: 1, speaker: "Maya", speakerGender: .f)
        let tag = ScenePacketTranslator.bindingTag(b)
        XCTAssertTrue(tag.contains("[TO: unknown"))
        XCTAssertTrue(tag.contains("gender-neutral"))
    }

    func testGroupAddresseeTagCarriesPlural() {
        let b = DialogueBinding(cueIndex: 1, addresseeGender: .m,
                                addresseeNumber: .plural, method: .groupAddress, confidence: 0.9)
        XCTAssertTrue(ScenePacketTranslator.bindingTag(b).contains("a group (M plural)"))
    }

    func testPromptCarriesBindingsRulesAndSynopsis() async throws {
        let packet = ScenePacket(
            cueIndices: [1],
            lines: ["Move!"],
            bindings: [DialogueBinding(cueIndex: 1, speaker: "Maya", speakerGender: .f,
                                       addressee: "Danny", addresseeGender: .m,
                                       addresseeNumber: .singular, method: .vocative,
                                       confidence: 0.95)],
            synopsis: "They are forcing a locked storeroom door at night.")
        let translator = ScenePacketTranslator(chat: RecordingChat(), format: .lean)
        let prompt = translator.buildPrompt(packet: packet, targetLang: "he")

        XCTAssertTrue(prompt.contains("[SPEAKER: Maya (F)] [TO: Danny (M)] Move!"))
        XCTAssertTrue(prompt.contains("SCENE: They are forcing a locked storeroom door"))
        XCTAssertTrue(prompt.contains("RESOLVED FACTS"))
        XCTAssertTrue(prompt.contains("NEVER write two gendered forms"))
    }

    func testPromptWithoutBindingsIsUnchangedApartFromTheHedgeRule() {
        let packet = ScenePacket(cueIndices: [1], lines: ["Move!"])
        let prompt = ScenePacketTranslator(chat: RecordingChat(), format: .lean)
            .buildPrompt(packet: packet, targetLang: "he")
        XCTAssertTrue(prompt.contains("1. Move!"))
        XCTAssertFalse(prompt.contains("[SPEAKER"))
        XCTAssertFalse(prompt.contains("RESOLVED FACTS"))
    }
}

/// A chat that records nothing and answers nothing — prompt-shape tests only.
private struct RecordingChat: LlamaChat {
    func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String { "" }
}

final class SpeakerTagsTests: XCTestCase {
    func testLiftsNameLabelsIntoSpeakerId() {
        let cues = SpeakerTags.apply([
            cue(1, 0, 1_000, "DANNY: Move!"),
            cue(2, 1_000, 2_000, "Maya: I'm going."),
            cue(3, 2_000, 3_000, "[SARAH] Wait."),
            cue(4, 3_000, 4_000, "- DANNY: Now!"),
        ])
        XCTAssertEqual(cues.map { $0.speakerId }, ["Danny", "Maya", "Sarah", "Danny"])
        XCTAssertEqual(cues.map { $0.text }, ["Move!", "I'm going.", "Wait.", "Now!"])
    }

    func testDoesNotMisreadOrdinaryLines() {
        let cues = SpeakerTags.apply([
            cue(1, 0, 1_000, "It was 3:30 when I left."),
            cue(2, 1_000, 2_000, "Here's the thing: nobody knew."),
            cue(3, 2_000, 3_000, "[DOOR CREAKS]"),
        ])
        XCTAssertEqual(cues.compactMap { $0.speakerId }, [],
                       "colons and bracketed sound cues are not speaker labels")
    }
}

final class SceneSegmenterTests: XCTestCase {
    func testSplitsOnLongSilence() {
        // Two 12 s conversations separated by 20 s of silence.
        var cues: [SubtitleCue] = []
        for i in 0 ..< 6 { cues.append(cue(i + 1, i * 2_000, i * 2_000 + 1_500, "a\(i)")) }
        for i in 0 ..< 6 {
            cues.append(cue(i + 7, 32_000 + i * 2_000, 32_000 + i * 2_000 + 1_500, "b\(i)"))
        }
        let scenes = SceneSegmenter.segment(cues: cues)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].range, 0 ..< 6)
        XCTAssertEqual(scenes[1].range, 6 ..< 12)
    }

    func testDoesNotSplitBelowTheMinimumDuration() {
        // A 9 s gap inside a 6 s exchange: still one situation, not two scenes.
        let cues = [
            cue(1, 0, 1_000, "a"),
            cue(2, 10_000, 11_000, "b"),
            cue(3, 11_500, 12_500, "c"),
        ]
        XCTAssertEqual(SceneSegmenter.segment(cues: cues).count, 1)
    }

    func testForceCutsAnOverlongScene() {
        // 100 evenly-spaced cues over 200 s with no gaps at all — the 120 s clamp
        // is the only thing that can break it up.
        let cues = (0 ..< 100).map { cue($0 + 1, $0 * 2_000, $0 * 2_000 + 1_800, "line \($0)") }
        let scenes = SceneSegmenter.segment(cues: cues)
        XCTAssertGreaterThan(scenes.count, 1)
        for s in scenes { XCTAssertLessThanOrEqual(s.durationMs, 130_000) }
    }

    func testScenesCoverEveryCueExactlyOnce() {
        let cues = (0 ..< 60).map { i -> SubtitleCue in
            let t = i < 20 ? i * 1_500 : (i < 40 ? 60_000 + i * 1_500 : 200_000 + i * 1_500)
            return cue(i + 1, t, t + 1_000, "line \(i)", speaker: i % 2 == 0 ? "A" : "B")
        }
        let covered = SceneSegmenter.segment(cues: cues).flatMap { Array($0.range) }
        XCTAssertEqual(covered, Array(0 ..< 60))
    }

    func testSpeakerShiftIsASignal() {
        // Same timing throughout; only the cast changes at the midpoint.
        var cues: [SubtitleCue] = []
        for i in 0 ..< 10 {
            cues.append(cue(i + 1, i * 2_000, i * 2_000 + 1_500, "x",
                            speaker: i % 2 == 0 ? "A" : "B"))
        }
        for i in 10 ..< 20 {
            cues.append(cue(i + 1, i * 2_000, i * 2_000 + 1_500, "x",
                            speaker: i % 2 == 0 ? "C" : "D"))
        }
        let scenes = SceneSegmenter.segment(cues: cues)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].speakers, ["A", "B"])
        XCTAssertEqual(scenes[1].speakers, ["C", "D"])
    }
}

final class SceneSynopsisTests: XCTestCase {
    func testCleanRejectsRefusalsAndStripsDecoration() {
        XCTAssertEqual(SceneSynopsis.clean("NONE"), "")
        XCTAssertEqual(SceneSynopsis.clean("  none of this is clear "), "")
        XCTAssertEqual(SceneSynopsis.clean("Situation: They are in a car at night."),
                       "They are in a car at night.")
        XCTAssertEqual(SceneSynopsis.clean("\"They argue in a hospital corridor.\""),
                       "They argue in a hospital corridor.")
        XCTAssertEqual(SceneSynopsis.clean("Too short"), "", "a stub is not a synopsis")
    }

    func testKeysAreStableForTheSameSceneAndDifferForAnother() {
        let a = SceneSynopsis.cacheKey(["one", "two"])
        XCTAssertEqual(a, SceneSynopsis.cacheKey(["one", "two"]))
        XCTAssertNotEqual(a, SceneSynopsis.cacheKey(["one", "three"]))
    }

    func testPacketsNeverSpanTwoScenesAndInheritTheSynopsis() {
        let cues = (0 ..< 8).map { cue($0 + 1, $0 * 1_000, $0 * 1_000 + 800, "line \($0)") }
        // Cues 1-4 in scene 0, 5-8 in scene 1 — with gaps small enough that the
        // packeter would otherwise merge them into one packet.
        let sceneId = Dictionary(uniqueKeysWithValues: (1 ... 8).map { ($0, $0 <= 4 ? 0 : 1) })
        let packets = ScenePacketer.packets(
            cues: cues,
            sceneIdByCueIndex: sceneId,
            synopsisBySceneId: [0: "A kitchen argument.", 1: "Driving away at night."])
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].synopsis, "A kitchen argument.")
        XCTAssertEqual(packets[1].synopsis, "Driving away at night.")
    }
}
