// Tests for the machine-adaptive inference policy and the Hebrew quality signals.
//
// The hardware tests encode findings that cost a full bake-off to establish on real
// machines: they assert POLICY, so a future edit that quietly re-enables draft-model
// speculation or hands a 16 GB Mac a 24 GB machine's context fails here rather than
// at a customer's Metal command buffer.

import XCTest
@testable import Engine

final class InferenceConfigTests: XCTestCase {
    private func mac(_ gb: Double, appleSilicon: Bool = true) -> MachineProfile {
        MachineProfile(totalRAMBytes: UInt64(gb * 1_073_741_824),
                       performanceCores: 8, isAppleSilicon: appleSilicon)
    }

    func testDraftModelSpeculationIsNeverEnabledOnAnyMachine() {
        // The hard rule: a target + draft model in one process exhausts Metal's
        // shared allocation on 16 GB Apple Silicon (kIOGPUCommandBufferCallback-
        // ErrorOutOfMemory). No machine tier may opt back into it.
        for gb in [8.0, 16.0, 24.0, 64.0, 192.0] {
            XCTAssertFalse(InferenceConfig.forMachine(mac(gb)).allowsDraftModelSpeculation,
                           "\(gb) GB tier must not allow draft-model speculation")
        }
        XCTAssertFalse(InferenceConfig.current.allowsDraftModelSpeculation)
    }

    func testEachMemoryTierGetsItsOwnPolicy() {
        XCTAssertEqual(InferenceConfig.forMachine(mac(8)).tier, .constrained)
        XCTAssertEqual(InferenceConfig.forMachine(mac(16)).tier, .balanced)
        XCTAssertEqual(InferenceConfig.forMachine(mac(24)).tier, .comfortable)
        XCTAssertEqual(InferenceConfig.forMachine(mac(64)).tier, .ample)
    }

    func testConstrainedMachinesKeepOneModelWarmAndSerializeTheAccelerators() {
        // The 16 GB M1 the benchmarks were measured on: ~6.5 GB is all that is left
        // for a model after macOS, the app and ASR, so a second warm model is what
        // pushes it into swap.
        let m1 = InferenceConfig.forMachine(mac(16))
        XCTAssertFalse(m1.allowsBothModelTiersWarm)
        XCTAssertTrue(m1.serializeASRAndLLM)
        XCTAssertTrue(m1.quantizeKVCache)
        XCTAssertEqual(m1.contextSize, 4_096)
        XCTAssertEqual(m1.llmBudgetGB, 6.5, accuracy: 0.01)
    }

    func testRoomyMachinesKeepBothTiersWarmAndAllowOverlap() {
        let m4 = InferenceConfig.forMachine(mac(24))
        XCTAssertTrue(m4.allowsBothModelTiersWarm)
        XCTAssertFalse(m4.serializeASRAndLLM)
        XCTAssertEqual(m4.contextSize, 8_192)

        let big = InferenceConfig.forMachine(mac(64))
        XCTAssertGreaterThan(big.contextSize, m4.contextSize)
        XCTAssertGreaterThan(big.llmBudgetGB, m4.llmBudgetGB)
    }

    func testContextAndBudgetNeverShrinkAsMemoryGrows() {
        let tiers = [8.0, 16.0, 24.0, 64.0].map { InferenceConfig.forMachine(mac($0)) }
        for (a, b) in zip(tiers, tiers.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.contextSize, a.contextSize)
            XCTAssertGreaterThanOrEqual(b.llmBudgetGB, a.llmBudgetGB)
        }
    }

    func testIntelMacsAreTreatedAsConstrainedRegardlessOfRAM() {
        // No unified memory and no usable Metal LLM path: never promise the
        // throughput of an Apple Silicon tier.
        XCTAssertEqual(InferenceConfig.forMachine(mac(64, appleSilicon: false)).tier, .constrained)
    }

    func testWhisperTierIsCappedOnConstrainedMachines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try ModelPaths.resolve(environment: ["AUTOSUB_MODELS": dir.path])
        for name in ["openai_whisper-base", "openai_whisper-small", "openai_whisper-large-v3_turbo"] {
            try FileManager.default.createDirectory(
                at: paths.whisperKit.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        XCTAssertEqual(WhisperKitASR.resolveBestModel(modelPaths: paths, maxTier: "large-v3-turbo"),
                       "openai_whisper-large-v3_turbo")
        XCTAssertEqual(WhisperKitASR.resolveBestModel(modelPaths: paths, maxTier: "small"),
                       "openai_whisper-small")
    }
}

final class GPUGateTests: XCTestCase {
    func testExclusiveAccessSerializesWorkWhenEnabled() async {
        let gate = GPUGate(enabled: true)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await gate.withExclusiveAccess {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await counter.leave()
                    }
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1, "ASR and LLM work must never overlap on a gated machine")
    }

    func testDisabledGateIsAPassThrough() async {
        let gate = GPUGate(enabled: false)
        let value = await gate.withExclusiveAccess { 42 }
        XCTAssertEqual(value, 42)
    }

    private actor Counter {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }
}

final class GenderHedgeTests: XCTestCase {
    func testCatchesSlashAndBracketHedges() {
        // The exact shapes the sister project measured a 4B model emitting when it
        // could not resolve the addressee.
        XCTAssertTrue(TranslationOutputValidator.genderHedge("את/אתה בטוח בזה?"))
        XCTAssertTrue(TranslationOutputValidator.genderHedge("אני יודע/ת מה קורה"))
        XCTAssertTrue(TranslationOutputValidator.genderHedge("תזוז/תזוזי משם"))
        XCTAssertTrue(TranslationOutputValidator.genderHedge("אתה בטוח(ה)?"))
    }

    func testDoesNotFlagOrdinaryHebrewOrLegitimateSlashes() {
        XCTAssertFalse(TranslationOutputValidator.genderHedge("אתה בטוח בזה?"))
        XCTAssertFalse(TranslationOutputValidator.genderHedge("את בטוחה בזה?"))
        XCTAssertFalse(TranslationOutputValidator.genderHedge("הוא ו/או היא יגיעו"),
                       "ו/או is the one legitimate Hebrew slash construction")
        XCTAssertFalse(TranslationOutputValidator.genderHedge("Are you sure about this?"))
        XCTAssertFalse(TranslationOutputValidator.genderHedge("היא אמרה (בשקט) משהו"),
                       "a real parenthetical is not an inflection hedge")
    }

    func testAHedgedLineFailsFidelityValidationAndIsRepairable() {
        // The repair loop keys off `isValid`, so the hedge has to fail there — not
        // merely be detectable in isolation.
        XCTAssertEqual(
            TranslationOutputValidator.issue(
                source: "Are you sure about this?",
                translation: "את/אתה בטוח/ה בזה?", targetLang: "he"),
            .genderHedge)
        XCTAssertTrue(TranslationOutputValidator.isValid(
            source: "Are you sure about this?", translation: "את בטוחה בזה?", targetLang: "he"))
    }
}

final class HebrewQualityMatrixTests: XCTestCase {
    func testMatrixCoversSpeakerAddresseeAndGroupAgreement() {
        // The probe scene is the ground-truth matrix: 1st person (speaker gender),
        // 2nd person singular (addressee gender), and 2nd person plural (group).
        let payload = TranslationQualityGate.scene.filter { $0.expectAny != nil }
        XCTAssertGreaterThanOrEqual(payload.count, 10)
        XCTAssertTrue(payload.contains { $0.expectAny?.contains("מוכנים") == true },
                      "masculine plural (group address) must be covered")
        XCTAssertTrue(payload.contains { $0.expectAny?.contains("מוכנות") == true },
                      "feminine plural must be covered")
        XCTAssertTrue(payload.contains { $0.expectAny?.contains("עייפה") == true },
                      "female speaker, 1st person must be covered")
        XCTAssertTrue(payload.contains { $0.expectAny?.contains("חזק") == true },
                      "male addressee, 2nd person must be covered")
    }

    func testHedgedOutputScoresAsAFailureEvenWhenItContainsTheRightWord() {
        var translations: [Int: String] = [:]
        for (i, probe) in TranslationQualityGate.scene.enumerated() {
            guard let expect = probe.expectAny?.first else { continue }
            // Contains the expected token, but as half of a dual-gender hedge.
            translations[i + 1] = "אני \(expect)/\(probe.forbidAny.first ?? expect)"
        }
        let result = TranslationQualityGate.score(approach: "hedged",
                                                  translationsByCueIndex: translations)
        XCTAssertEqual(result.correct, 0, "a hedge is never a correct answer")
        XCTAssertTrue(result.failures.contains { $0.contains("hedged") })
    }

    func testPolysemyProbesPairTheSameWordWithOppositeScenes() {
        // Each ambiguous English word appears twice with different scenes and
        // opposite ground truth, so a model that ignores the synopsis cannot pass
        // both by guessing the common sense.
        let bySource = Dictionary(grouping: TranslationQualityGate.contextProbes) {
            $0.source.contains("bat") ? "bat" : "bank"
        }
        XCTAssertEqual(bySource["bat"]?.count, 2)
        XCTAssertEqual(bySource["bank"]?.count, 2)
        for (word, pair) in bySource {
            // What one scene expects is exactly what the other forbids.
            XCTAssertTrue(pair[1].forbidAny.contains(pair[0].expectAny[0]), "\(word)")
            XCTAssertTrue(pair[0].forbidAny.contains(pair[1].expectAny[0]), "\(word)")
        }
    }

    func testContextScoringRewardsTheSceneAppropriateSense() {
        // Right sense for each scene → full marks; the common sense everywhere → not.
        var right: [Int: String] = [:]
        var lazy: [Int: String] = [:]
        for (i, probe) in TranslationQualityGate.contextProbes.enumerated() {
            right[i] = "תביא את ה\(probe.expectAny[0])"
            lazy[i] = "תביא את ה\(probe.forbidAny[0])"
        }
        XCTAssertEqual(TranslationQualityGate.scoreContext(approach: "ctx", translations: right).accuracy,
                       1.0, accuracy: 0.001)
        XCTAssertEqual(TranslationQualityGate.scoreContext(approach: "lazy", translations: lazy).correct, 0)
    }
}
