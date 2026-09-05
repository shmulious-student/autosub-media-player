// Tests for the incremental translation cache — specifically the property that
// makes it worth having: correcting ONE character must invalidate only the lines
// that character is actually in, never the whole film.

import XCTest
@testable import Engine

final class CueTranslationCacheKeyTests: XCTestCase {
    private let glossary = ["Sarah": "f", "David": "m", "Maya": "f"]

    private func key(
        _ source: String,
        binding: DialogueBinding? = nil,
        synopsis: String? = nil,
        glossary: [String: String]? = nil
    ) -> String {
        CueTranslationCache.key(
            source: source, targetLang: "he", binding: binding,
            synopsis: synopsis, glossary: glossary ?? self.glossary)
    }

    func testSameInputsGiveTheSameKey() {
        XCTAssertEqual(key("Are you sure?"), key("Are you sure?"))
        XCTAssertEqual(key("Are you sure?"), key("  Are you sure?  "),
                       "surrounding whitespace is not a translation input")
    }

    func testTextTargetAndSynopsisAllAffectTheKey() {
        XCTAssertNotEqual(key("Are you sure?"), key("Are you certain?"))
        XCTAssertNotEqual(
            key("It's open."),
            key("It's open.", synopsis: "They are forcing a storeroom door."))
        XCTAssertNotEqual(
            CueTranslationCache.key(source: "Hello", targetLang: "he",
                                    binding: nil, synopsis: nil, glossary: glossary),
            CueTranslationCache.key(source: "Hello", targetLang: "ar",
                                    binding: nil, synopsis: nil, glossary: glossary))
    }

    func testResolvedAddresseeAffectsTheKey() {
        // The whole point of the ladder: the same English sentence is a different
        // Hebrew sentence depending on who it is addressed to.
        let toMale = DialogueBinding(
            cueIndex: 1, addressee: "David", addresseeGender: .m,
            addresseeNumber: .singular, method: .vocative, confidence: 0.95)
        let toFemale = DialogueBinding(
            cueIndex: 1, addressee: "Sarah", addresseeGender: .f,
            addresseeNumber: .singular, method: .vocative, confidence: 0.95)
        XCTAssertNotEqual(key("Are you sure?", binding: toMale),
                          key("Are you sure?", binding: toFemale))
    }

    func testEditingOneCharacterInvalidatesOnlyTheLinesAboutThem() {
        // The defect this replaces: a bible edit changed one hash for the whole
        // file, so every line was re-translated.
        var corrected = glossary
        corrected["Sarah"] = "m"

        let aboutSarah = key("Sarah went home.")
        let aboutDavid = key("David went home.")
        let aboutNobody = key("It started raining.")

        XCTAssertNotEqual(aboutSarah, key("Sarah went home.", glossary: corrected))
        XCTAssertEqual(aboutDavid, key("David went home.", glossary: corrected),
                       "a line about David must survive an edit to Sarah")
        XCTAssertEqual(aboutNobody, key("It started raining.", glossary: corrected),
                       "a line about neither must survive any character edit")
    }

    func testALineSpokenByTheEditedCharacterIsAlsoInvalidated() {
        // Sarah's own lines carry her gender in the 1st person even when her name
        // never appears in them.
        let binding = DialogueBinding(cueIndex: 1, speaker: "Sarah", speakerGender: .f)
        var corrected = glossary
        corrected["Sarah"] = "m"
        XCTAssertNotEqual(key("I am tired.", binding: binding),
                          key("I am tired.", binding: binding, glossary: corrected))
    }

    func testAddingAnUnrelatedCharacterChangesNothing() {
        var extended = glossary
        extended["Jonathan"] = "m"
        XCTAssertEqual(key("It started raining."),
                       key("It started raining.", glossary: extended))
    }

    func testRelevantCharactersPicksSpeakerAddresseeAndNamesInTheLine() {
        let binding = DialogueBinding(
            cueIndex: 1, speaker: "Maya", addressee: "David", method: .vocative)
        let relevant = CueTranslationCache.relevantCharacters(
            source: "Tell Sarah I'm leaving.", binding: binding, glossary: glossary)
        XCTAssertEqual(relevant.map { $0.0 }, ["David", "Maya", "Sarah"])
    }
}

final class CueTranslationCacheStorageTests: XCTestCase {
    private func tempVideo() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Film.mkv").path
    }

    func testRoundTripsThroughTheSidecar() throws {
        let video = try tempVideo()
        var cache = CueTranslationCache(videoPath: video)
        cache.store("שלום", for: "k1")
        cache.store("להתראות", for: "k2")
        cache.save()

        let reloaded = CueTranslationCache(videoPath: video)
        XCTAssertEqual(reloaded.value(for: "k1"), "שלום")
        XCTAssertEqual(reloaded.value(for: "k2"), "להתראות")
        XCTAssertNil(reloaded.value(for: "k3"))
    }

    func testPruningDropsKeysTheTitleNoLongerUses() throws {
        let video = try tempVideo()
        var cache = CueTranslationCache(videoPath: video)
        cache.store("ישן", for: "stale")
        cache.store("חדש", for: "live")
        cache.save(keeping: ["live"])

        let reloaded = CueTranslationCache(videoPath: video)
        XCTAssertEqual(reloaded.value(for: "live"), "חדש")
        XCTAssertNil(reloaded.value(for: "stale"),
                     "keys no longer referenced must not accumulate forever")
    }

    func testTwoFilmsInOneFolderDoNotShareEntries() throws {
        let video = try tempVideo()
        let sibling = URL(fileURLWithPath: video).deletingLastPathComponent()
            .appendingPathComponent("Other.mkv").path
        var first = CueTranslationCache(videoPath: video)
        first.store("שלום", for: "k1")
        first.save()

        XCTAssertNil(CueTranslationCache(videoPath: sibling).value(for: "k1"))
    }
}

final class CachedTranslationRunTests: XCTestCase {
    /// A packet whose lines are all cached must cost ZERO model requests.
    func testFullyCachedPacketMakesNoRequests() async throws {
        let chat = CountingChat()
        let packet = ScenePacket(cueIndices: [1, 2], lines: ["Hello.", "Goodbye."])
        let out = try await ScenePacketTranslator(chat: chat, format: .lean)
            .translate(packets: [packet], targetLang: "he",
                       cached: [1: "שלום", 2: "להתראות"])

        XCTAssertEqual(out.translationsByCueIndex, [1: "שלום", 2: "להתראות"])
        XCTAssertEqual(out.stats.requests, 0)
        XCTAssertEqual(out.stats.cachedLines, 2)
        let calls = await chat.calls
        XCTAssertEqual(calls, 0, "a cached scene must never reach the model")
    }

    /// One invalidated line in an otherwise cached packet re-asks for THAT line
    /// only, with the scene as context — not a full re-decode.
    func testPartiallyCachedPacketOnlyAsksForTheMissingLine() async throws {
        let chat = CountingChat(reply: "2. שלום חדש")
        let packet = ScenePacket(cueIndices: [1, 2, 3],
                                 lines: ["Hello.", "Are you sure?", "Goodbye."])
        let out = try await ScenePacketTranslator(chat: chat, format: .lean)
            .translate(packets: [packet], targetLang: "he",
                       cached: [1: "שלום", 3: "להתראות"])

        XCTAssertEqual(out.translationsByCueIndex[1], "שלום", "kept")
        XCTAssertEqual(out.translationsByCueIndex[2], "שלום חדש", "re-translated")
        XCTAssertEqual(out.translationsByCueIndex[3], "להתראות", "kept")
        XCTAssertEqual(out.stats.cachedLines, 2)

        let prompts = await chat.prompts
        XCTAssertEqual(prompts.count, 1, "exactly one targeted re-ask")
        XCTAssertTrue(prompts[0].contains("ONLY the lines numbered: 2"))
        XCTAssertTrue(prompts[0].contains("1. Hello."),
                      "the whole scene is still given as context")
    }
}

/// Counts calls and answers with a fixed reply.
private actor CountingChat: LlamaChat {
    private(set) var calls = 0
    private(set) var prompts: [String] = []
    private let reply: String

    init(reply: String = "") { self.reply = reply }

    func complete(system: String?, user: String,
                  maxTokens: Int, temperature: Double) async throws -> String {
        calls += 1
        prompts.append(user)
        return reply
    }
}
