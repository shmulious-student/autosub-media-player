import XCTest
@testable import Engine

final class EngineTests: XCTestCase {
    func testModelPathsFailsLoudlyWhenMissing() {
        let env = ["AUTOSUB_MODELS": "/definitely/not/a/real/path/autosub-models"]
        XCTAssertThrowsError(try ModelPaths.resolve(environment: env)) { error in
            guard case ModelPaths.ResolveError.missing = error else {
                return XCTFail("expected .missing, got \(error)")
            }
        }
    }

    func testBiblePromptInjectsGenderAndGlossary() {
        let speaker = BibleCharacter(
            id: "1", canonicalName: "Sarah", gender: .f,
            nameTranslations: ["he": "שרה"]
        )
        let addressee = BibleCharacter(
            id: "2", canonicalName: "David", gender: .m,
            nameTranslations: ["he": "דוד"]
        )
        let translator = DictaLMTranslator(
            modelPaths: try! makeTempModelPaths()
        )
        let line = LineContext(
            sourceText: "You are late.",
            speaker: speaker,
            addressee: addressee,
            relevantCharacters: [speaker, addressee]
        )
        let prompt = translator.buildPrompt(line: line, targetLang: "he")

        XCTAssertTrue(prompt.contains("SPEAKER: Sarah (gender=f)"))
        XCTAssertTrue(prompt.contains("ADDRESSEE: David (gender=m)"))
        XCTAssertTrue(prompt.contains("Sarah -> שרה"))
        XCTAssertTrue(prompt.contains("David -> דוד"))
        XCTAssertTrue(prompt.contains("SOURCE: You are late."))
    }

    func testPipelineHasTwelveStages() {
        XCTAssertEqual(PipelineStage.allCases.count, 12)
    }

    func testSegmenterBreaksOnSentencesWithoutOverlap() {
        // Two sentences in one ASR segment; the segmenter should split them and
        // produce strictly non-overlapping, ordered cues.
        let words = [
            ASRWord(text: "Hello",  startMs: 0,    endMs: 400),
            ASRWord(text: "there.", startMs: 450,  endMs: 900),
            ASRWord(text: "How",    startMs: 1000, endMs: 1300),
            ASRWord(text: "are",    startMs: 1350, endMs: 1600),
            ASRWord(text: "you?",   startMs: 1650, endMs: 2000),
        ]
        let asr = ASRResult(language: "en", segments: [
            ASRSegment(text: "Hello there. How are you?", startMs: 0, endMs: 2000, words: words),
        ])
        let cues = Segmenter().segment(asr)

        XCTAssertEqual(cues.count, 2, "should split on the sentence boundary")
        XCTAssertEqual(cues[0].text, "Hello there.")
        XCTAssertEqual(cues[1].text, "How are you?")
        // No overlap: each cue starts at/after the previous cue's end.
        XCTAssertLessThanOrEqual(cues[0].endMs, cues[1].startMs)
        // Re-indexed 1..n.
        XCTAssertEqual(cues.map(\.index), [1, 2])
    }

    func testSpeakerAttributorParsesGenderJSON() {
        let raw = "noise [{\"i\":1,\"sg\":\"m\",\"ag\":\"f\"},{\"i\":2,\"sg\":\"f\",\"ag\":\"u\"}] trailing"
        let parsed = SpeakerAttributor.parse(raw)
        XCTAssertEqual(parsed[1]?.speakerGender, .m)
        XCTAssertEqual(parsed[1]?.addresseeGender, .f)
        XCTAssertEqual(parsed[2]?.speakerGender, .f)
        XCTAssertEqual(parsed[2]?.addresseeGender, .unknown)
    }

    // MARK: - Batch translation + SRT parsing

    func testParseNumberedBatchOutput() {
        let raw = "1. שלום עולם\n2. מה שלומך\n3. אני בסדר"
        let out = DictaLMTranslator.parseNumbered(raw, expected: 3)
        XCTAssertEqual(out, ["שלום עולם", "מה שלומך", "אני בסדר"])
    }

    func testParseNumberedHandlesMissingLine() {
        // Line 2 missing → empty placeholder (triggers per-line fallback), order kept.
        let out = DictaLMTranslator.parseNumbered("1. one\n3. three", expected: 3)
        XCTAssertEqual(out, ["one", "", "three"])
    }

    func testDialogueAnalyzerParsesGenderMap() {
        let raw = "Here you go: {\"David\":\"m\",\"Sarah\":\"f\",\"Narrator\":\"x\"} done"
        let map = DialogueAnalyzer.parseMap(raw)
        XCTAssertEqual(map["David"], "m")
        XCTAssertEqual(map["Sarah"], "f")
        XCTAssertEqual(map["Narrator"], "u") // unrecognized value → unknown
    }

    func testLooksLikeNameFiltersJunk() {
        XCTAssertTrue(DialogueAnalyzer.looksLikeName("David"))
        XCTAssertTrue(DialogueAnalyzer.looksLikeName("Marshall Cuso"))
        XCTAssertFalse(DialogueAnalyzer.looksLikeName("The insurance company"))
        XCTAssertFalse(DialogueAnalyzer.looksLikeName("They"))
        XCTAssertFalse(DialogueAnalyzer.looksLikeName("who make tons"))
    }

    func testParseSRTCuesAndTiming() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>Hello there.</i>

        2
        00:00:04,000 --> 00:00:05,200
        How are you?
        """
        let cues = SubtitleExtractor.parseSRT(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startMs, 1000)
        XCTAssertEqual(cues[0].endMs, 3500)
        XCTAssertEqual(cues[0].text, "Hello there.") // <i> tags stripped
        XCTAssertEqual(cues[1].text, "How are you?")
    }

    func testSentenceRegrouperMergesFragmentsUntilSentenceEnd() {
        // A sentence split across 3 cues (no terminal punctuation until the last),
        // then a separate one-cue sentence.
        let cues = [
            SubtitleCue(index: 1, startMs: 2590, endMs: 5427, text: "Well, actually,"),
            SubtitleCue(index: 2, startMs: 5468, endMs: 9055, text: "our research has shown"),
            SubtitleCue(index: 3, startMs: 9097, endMs: 10849, text: "that diarrhea is preferable."),
            SubtitleCue(index: 4, startMs: 10932, endMs: 13980, text: "Next question."),
        ]
        let groups = SentenceRegrouper.group(cues)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].cueIndices, [1, 2, 3])
        XCTAssertEqual(groups[0].startMs, 2590)
        XCTAssertEqual(groups[0].endMs, 10849)
        XCTAssertEqual(groups[1].cueIndices, [4])
    }

    func testRedistributeKeepsEveryCueTimingAndAllWords() {
        let cues = [
            SubtitleCue(index: 1, startMs: 2590, endMs: 5427, text: "Well, actually,"),
            SubtitleCue(index: 2, startMs: 5468, endMs: 9055, text: "our research has shown"),
            SubtitleCue(index: 3, startMs: 9097, endMs: 10849, text: "that diarrhea is preferable."),
        ]
        let groups = SentenceRegrouper.group(cues)
        // One Hebrew sentence for the whole group (6 words) → split across 3 cues.
        let byCue = SentenceRegrouper.redistribute(
            groups: groups, translationBySentence: [0: "ובכן למעשה המחקר שלנו הראה ששלשול"])
        XCTAssertEqual(Set(byCue.keys), [1, 2, 3])
        // No cue is blank, and every source word survives the split.
        for idx in [1, 2, 3] { XCTAssertFalse(byCue[idx]!.isEmpty) }
        let rejoined = [1, 2, 3].map { byCue[$0]! }.joined(separator: " ")
        XCTAssertEqual(rejoined, "ובכן למעשה המחקר שלנו הראה ששלשול")
    }

    func testRedistributeSingleCueIsIdentity() {
        let byCue = SentenceRedistributor.split("שלום עולם", weights: [10])
        XCTAssertEqual(byCue, ["שלום עולם"])
    }

    func testPromptTextSanitizerKeepsDialogueAndDropsPureNoise() {
        XCTAssertEqual(
            PromptTextSanitizer.sanitize("<i>Hello\nthere.</i>\u{202C}"),
            "Hello there."
        )
        XCTAssertEqual(
            PromptTextSanitizer.sanitize("{\\an8}   Sarah, you are late.   "),
            "Sarah, you are late."
        )
        XCTAssertNil(PromptTextSanitizer.sanitize("[MUSIC]"))
        XCTAssertNil(PromptTextSanitizer.sanitize("♪♪"))
    }

    func testScenePacketerSplitsOnGapAndLineLimit() {
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "A"),
            SubtitleCue(index: 2, startMs: 1200, endMs: 2000, text: "B"),
            SubtitleCue(index: 3, startMs: 6000, endMs: 7000, text: "C"),
            SubtitleCue(index: 4, startMs: 7100, endMs: 8000, text: "[MUSIC]"),
        ]
        let packets = ScenePacketer.packets(cues: cues, maxLines: 8, sceneGapMs: 2500)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].cueIndices, [1, 2])
        XCTAssertEqual(packets[1].cueIndices, [3])
    }

    func testScenePacketTranslatorParsesStrictJSON() {
        let raw = """
        {"lines":[
          {"i":1,"sg":"m","ag":"f","t":"שלום"},
          {"i":2,"sg":"f","ag":"m","t":"מה שלומך?"}
        ]}
        """
        let parsed = ScenePacketTranslator.parseTranslations(raw, cueIndices: [10, 11])
        XCTAssertEqual(parsed?[10], "שלום")
        XCTAssertEqual(parsed?[11], "מה שלומך?")
        XCTAssertNil(ScenePacketTranslator.parseTranslations(
            "{\"lines\":[{\"i\":1,\"t\":\"x\"}]}",
            cueIndices: [10, 11]
        ))
    }

    func testLeanScenePacketUsesNumberedFormatNotJSON() async throws {
        // Lean asks for `<n>. <translation>` only — no JSON schema, no sg/ag echo.
        let chat = ScriptedChat(responses: [
            "1. שלום\n2. מה שלומך?\nEND",
        ])
        let packets = [ScenePacket(cueIndices: [10, 11], lines: ["Hello.", "How are you?"])]
        let output = try await ScenePacketTranslator(chat: chat, format: .lean)
            .translate(packets: packets, targetLang: "he")
        XCTAssertEqual(output.translationsByCueIndex[10], "שלום")
        XCTAssertEqual(output.translationsByCueIndex[11], "מה שלומך?")
        XCTAssertEqual(output.stats.requests, 1)
        let prompts = await chat.prompts()
        // The lean prompt must NOT carry the JSON schema (that's the token tax):
        // no sg/ag fields, no {"i":..,"t":..} object shape.
        XCTAssertFalse(prompts.first?.contains("\"sg\"") ?? true)
        XCTAssertFalse(prompts.first?.contains("\"t\"") ?? true)
        XCTAssertFalse(prompts.first?.contains("{\"i\"") ?? true)
    }

    // MARK: - Phase A: translation I/O fidelity

    func testLeanPromptDeclaresSourceLanguage() async throws {
        let chat = ScriptedChat(responses: ["1. שלום\n2. מה שלומך?\nEND"])
        let packets = [ScenePacket(cueIndices: [1, 2], lines: ["Hello.", "How are you?"])]
        _ = try await ScenePacketTranslator(chat: chat, format: .lean, sourceLang: "en")
            .translate(packets: packets, targetLang: "he")
        let prompts = await chat.prompts()
        XCTAssertTrue(prompts.first?.contains("from English into Hebrew") ?? false)
    }

    func testDirectionDropsFromWhenSourceUnknownOrEqualsTarget() {
        XCTAssertEqual(ScenePacketTranslator.direction(source: nil, target: "he"), "into Hebrew")
        XCTAssertEqual(ScenePacketTranslator.direction(source: "he", target: "he"), "into Hebrew")
        XCTAssertEqual(ScenePacketTranslator.direction(source: "en", target: "he"), "from English into Hebrew")
    }

    func testOutputValidatorCatchesUnfaithfulLines() {
        typealias V = TranslationOutputValidator
        // empty / untranslated
        XCTAssertEqual(V.issue(source: "Hello", translation: "  ", targetLang: "he"), .empty)
        XCTAssertEqual(V.issue(source: "Hello there", translation: "Hello there", targetLang: "he"), .untranslated)
        XCTAssertEqual(V.issue(source: "Hello there", translation: "Hello there friend", targetLang: "he"), .untranslated)
        // leaked Latin in a Hebrew line
        XCTAssertEqual(
            V.issue(source: "The meeting is now", translation: "שלום this is the meeting now okay", targetLang: "he"),
            .leakedSource)
        // omission / addition (only on substantial source lines)
        XCTAssertEqual(
            V.issue(source: "This is a long sentence about cats and dogs.", translation: "חתול", targetLang: "he"),
            .omission)
        XCTAssertEqual(
            V.issue(source: "Are you coming?", translation: "האם אתה מתכוון אולי אפשר להגיע לכאן עכשיו בבקשה תודה רבה מאוד", targetLang: "he"),
            .addition)
        // repetition loop
        XCTAssertEqual(
            V.issue(source: "Okay then let's go now", translation: "טוב טוב טוב טוב", targetLang: "he"),
            .repetition)
        // multi-digit number dropped
        XCTAssertEqual(
            V.issue(source: "Meeting at 1995 hours", translation: "פגישה בשעה", targetLang: "he"),
            .numberDrift)
        // a faithful line passes
        XCTAssertNil(V.issue(source: "How are you?", translation: "מה שלומך?", targetLang: "he"))
        XCTAssertTrue(V.isValid(source: "I am very tired today.", translation: "אני מאוד עייף היום.", targetLang: "he"))
    }

    func testRepetitionLoopDetectsUnigramAndBigram() {
        XCTAssertTrue(TranslationOutputValidator.repetitionLoop("go go go go"))
        XCTAssertTrue(TranslationOutputValidator.repetitionLoop("go home go home go home"))
        XCTAssertFalse(TranslationOutputValidator.repetitionLoop("go home and then come back"))
    }

    func testUnfaithfulLineTriggersRepairReaskAndRecovers() async throws {
        // Pass 1 leaves line 2 in English (untranslated); the repair re-ask returns
        // valid Hebrew for line 2 only, which replaces it. No residual qaFlags.
        let chat = ScriptedChat(responses: [
            "1. שלום\n2. How are you?\nEND",
            "2. מה שלומך?",
        ])
        let packets = [ScenePacket(cueIndices: [10, 11], lines: ["Hello.", "How are you?"])]
        let out = try await ScenePacketTranslator(chat: chat, format: .lean, sourceLang: "en")
            .translate(packets: packets, targetLang: "he")
        XCTAssertEqual(out.translationsByCueIndex[10], "שלום")
        XCTAssertEqual(out.translationsByCueIndex[11], "מה שלומך?")
        let calls = await chat.requestCount()
        XCTAssertEqual(calls, 2)  // main + one repair
        XCTAssertTrue(out.stats.qaFlags.isEmpty)
    }

    func testResidualUnfaithfulLineIsKeptAndFlagged() async throws {
        // The repair also fails (still English) → keep the candidate, flag for QA.
        let chat = ScriptedChat(responses: [
            "1. שלום\n2. How are you?\nEND",
            "2. How are you?",
        ])
        let packets = [ScenePacket(cueIndices: [10, 11], lines: ["Hello.", "How are you?"])]
        let out = try await ScenePacketTranslator(chat: chat, format: .lean, sourceLang: "en")
            .translate(packets: packets, targetLang: "he")
        XCTAssertEqual(out.translationsByCueIndex[11], "How are you?")  // best candidate kept
        XCTAssertEqual(out.stats.qaFlags, ["unverified@11"])
    }

    func testSentenceRegrouperLocksPacketBoundariesToSentenceEnds() {
        // Fragment cues spanning two sentences must regroup so each unit is a whole
        // sentence — packets built from these never split a sentence mid-way.
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 800, text: "Well, actually,"),
            SubtitleCue(index: 2, startMs: 820, endMs: 1600, text: "our research shows"),
            SubtitleCue(index: 3, startMs: 1620, endMs: 2400, text: "that it works."),
            SubtitleCue(index: 4, startMs: 2420, endMs: 3200, text: "Then we left."),
        ]
        let groups = SentenceRegrouper.group(cues)
        XCTAssertEqual(groups.count, 2)
        for g in groups {
            XCTAssertTrue(g.text.hasSuffix("."), "each group must end on a sentence boundary: \(g.text)")
        }
        XCTAssertEqual(groups[0].text, "Well, actually, our research shows that it works.")
    }

    // MARK: - Phase B: ASR accuracy + validation

    func testResolveBestModelPrefersTurboThenLargeThenBase() throws {
        let mp = try makeTempModelPaths()
        let wk = mp.whisperKit
        let fm = FileManager.default
        try fm.createDirectory(at: wk, withIntermediateDirectories: true)
        // Only base present → base.
        try fm.createDirectory(at: wk.appendingPathComponent("openai_whisper-base"), withIntermediateDirectories: true)
        XCTAssertEqual(WhisperKitASR.resolveBestModel(modelPaths: mp), "openai_whisper-base")
        // Add large-v3 → wins over base.
        try fm.createDirectory(at: wk.appendingPathComponent("openai_whisper-large-v3"), withIntermediateDirectories: true)
        XCTAssertEqual(WhisperKitASR.resolveBestModel(modelPaths: mp), "openai_whisper-large-v3")
        // Add turbo → wins over plain large-v3.
        let turbo = "openai_whisper-large-v3-v20240930_turbo"
        try fm.createDirectory(at: wk.appendingPathComponent(turbo), withIntermediateDirectories: true)
        XCTAssertEqual(WhisperKitASR.resolveBestModel(modelPaths: mp), turbo)
    }

    func testWhisperLanguageHintMapsCodes() {
        XCTAssertEqual(WhisperKitASR.whisperLanguageHint("eng"), "en")
        XCTAssertEqual(WhisperKitASR.whisperLanguageHint("heb"), "he")
        XCTAssertEqual(WhisperKitASR.whisperLanguageHint("ger"), "de")  // 639-2/B
        XCTAssertEqual(WhisperKitASR.whisperLanguageHint("fre"), "fr")  // 639-2/B
        XCTAssertEqual(WhisperKitASR.whisperLanguageHint("en"), "en")   // already 2-letter
        XCTAssertNil(WhisperKitASR.whisperLanguageHint("und"))
        XCTAssertNil(WhisperKitASR.whisperLanguageHint(nil))
        XCTAssertNil(WhisperKitASR.whisperLanguageHint("xyz"))          // unknown 3-letter
    }

    func testAsrValidatorCollapsesRepetitionAndDropsEmpty() {
        XCTAssertEqual(AsrValidator.collapseRepeats("no no no no please"), "no please")
        XCTAssertEqual(AsrValidator.collapseRepeats("I don't know I don't know I don't know now"),
                       "I don't know now")
        XCTAssertEqual(AsrValidator.collapseRepeats("very very good"), "very very good")  // 2× kept

        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1500, text: "hello there"),
            SubtitleCue(index: 2, startMs: 1600, endMs: 2400, text: "   "),
            SubtitleCue(index: 3, startMs: 2500, endMs: 4000, text: "world"),
        ]
        let asr = ASRResult(language: "en", segments: [])
        let r = AsrValidator.validate(cues: cues, asr: asr)
        XCTAssertEqual(r.cues.map(\.text), ["hello there", "world"])
        XCTAssertEqual(r.cues.map(\.index), [1, 2])  // re-indexed after the drop
    }

    func testAsrValidatorFlagsLowConfidenceAndFastCps() {
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1500, text: "hello there"),
            SubtitleCue(index: 2, startMs: 2000, endMs: 2500, text: String(repeating: "x", count: 40)),
        ]
        // Segment over cue 1's time is low-confidence (avgLogprob below the floor).
        let asr = ASRResult(language: "en", segments: [
            ASRSegment(text: "hello there", startMs: 0, endMs: 1600, words: [], avgLogprob: -2.0),
        ])
        let r = AsrValidator.validate(cues: cues, asr: asr)
        XCTAssertTrue(r.qaFlags.contains("low-confidence@1"))
        XCTAssertTrue(r.qaFlags.contains("fast-cps@2"))   // 40 chars / 0.5s = 80 cps
    }

    // MARK: - Phase C: online source-subtitle handoff

    func testSelectTrackPrefersOriginalLanguageAndRejectsForeign() {
        // Robin Hood case: English audio, but the only TEXT track is Romanian (the
        // English/French/Spanish subs are image-based PGS and never reach here).
        let romanianOnly = [
            SubtitleTrackInfo(index: 0, codec: "ass", language: "rum"),
        ]
        // Original = English: a Romanian translation track is NOT an acceptable source.
        XCTAssertNil(SubtitleExtractor.selectTrack(romanianOnly, targetLang: "he", originalLang: "en"))
        // An English text track IS used when present.
        let withEnglish = romanianOnly + [SubtitleTrackInfo(index: 1, codec: "subrip", language: "eng")]
        XCTAssertEqual(
            SubtitleExtractor.selectTrack(withEnglish, targetLang: "he", originalLang: "en")?.language, "eng")
        // Unknown original language → legacy behavior: any non-target text track.
        XCTAssertEqual(
            SubtitleExtractor.selectTrack(romanianOnly, targetLang: "he", originalLang: nil)?.language, "rum")
    }

    func testDecodeTextHandlesBomAndWindows1252() {
        // UTF-8 with BOM → BOM stripped.
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("Help!".utf8)
        XCTAssertEqual(SubtitleExtractor.decodeText(bom), "Help!")
        // Plain UTF-8 (musical note, as in the real OpenSubtitles file).
        XCTAssertEqual(SubtitleExtractor.decodeText(Data("♪ Yo".utf8)), "♪ Yo")
        // Windows-1252 smart apostrophe (0x92) is INVALID UTF-8 — must still decode,
        // not return nil (which would silently fall back to ASR).
        let cp1252 = Data("I".utf8) + Data([0x92]) + Data("m spent".utf8)
        let decoded = SubtitleExtractor.decodeText(cp1252)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.hasPrefix("I") && decoded!.hasSuffix("m spent"))
    }

    func testLanguageFromSourceSidecar() {
        XCTAssertEqual(SubtitlePipeline.languageFromSourceSidecar("/m/Movie.en.src.srt"), "en")
        XCTAssertEqual(SubtitlePipeline.languageFromSourceSidecar("/m/Movie.en.src.ass"), "en")
        XCTAssertEqual(SubtitlePipeline.languageFromSourceSidecar("/m/Show.S01E02.he.src.srt"), "he")
        XCTAssertNil(SubtitlePipeline.languageFromSourceSidecar("/m/Movie.src.srt"))   // no lang token
        XCTAssertNil(SubtitlePipeline.languageFromSourceSidecar("/m/Movie.en.srt"))    // not a .src sidecar
        XCTAssertNil(SubtitlePipeline.languageFromSourceSidecar("/m/Movie.srt"))
    }

    func testCuesFromFileParsesStandaloneSrt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosub-src-\(UUID().uuidString).srt")
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello there.

        2
        00:00:03,500 --> 00:00:05,000
        How are you?
        """
        try srt.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let cues = SubtitleExtractor().cuesFromFile(path: url.path)
        XCTAssertEqual(cues?.count, 2)
        XCTAssertEqual(cues?[0].text, "Hello there.")
        XCTAssertEqual(cues?[1].startMs, 3500)
        XCTAssertNil(SubtitleExtractor().cuesFromFile(path: "/no/such/file.srt"))
    }

    func testTranslationStrategyWireParsing() {
        XCTAssertEqual(TranslationStrategy(wire: "fast"), .fast)
        XCTAssertEqual(TranslationStrategy(wire: "progressive"), .progressive)
        XCTAssertEqual(TranslationStrategy(wire: "quality"), .quality)
        XCTAssertEqual(TranslationStrategy(wire: nil), .quality)       // default
        XCTAssertEqual(TranslationStrategy(wire: "bogus"), .quality)   // unknown → default
        XCTAssertTrue(TranslationStrategy.progressive.usesFastModel)
        XCTAssertTrue(TranslationStrategy.progressive.usesQualityModel)
        XCTAssertFalse(TranslationStrategy.fast.usesQualityModel)
    }

    func testGenderRefinementFlagsFirstAndSecondPersonOnly() {
        // 1st/2nd-person lines need gender resolution; 3rd-person/neutral don't.
        XCTAssertTrue(GenderRefinement.needsGenderResolution("I am tired."))
        XCTAssertTrue(GenderRefinement.needsGenderResolution("You are very kind."))
        XCTAssertTrue(GenderRefinement.needsGenderResolution("Are you ready?"))
        XCTAssertFalse(GenderRefinement.needsGenderResolution("The train leaves at noon."))
        XCTAssertFalse(GenderRefinement.needsGenderResolution("She walked into the room."))
        // Flag only the lines that need it within a packet.
        let flagged = GenderRefinement.flaggedLocals([
            "Look over there.",      // 0 — neutral
            "I am ready.",           // 1 — 1st person
            "It started to rain.",   // 2 — neutral
            "You look great.",       // 3 — 2nd person
        ])
        XCTAssertEqual(flagged, [1, 3])
    }

    func testLlamaUsageParsesTokensAndRates() {
        let json: [String: Any] = [
            "usage": ["prompt_tokens": 308, "completion_tokens": 353],
            "timings": ["prompt_per_second": 161.6, "predicted_per_second": 21.79],
        ]
        let u = LlamaServerClient.parseUsage(json)
        XCTAssertEqual(u.promptTokens, 308)
        XCTAssertEqual(u.completionTokens, 353)
        XCTAssertEqual(u.decodeTokensPerSecond, 21.79, accuracy: 0.01)
        XCTAssertEqual(u.prefillTokensPerSecond, 161.6, accuracy: 0.01)
    }

    func testGenderGateDistinguishesHebrewGenderWordLevel() {
        // עייף (m) and עייפה (f) must compare as DISTINCT whole words.
        let words = TranslationQualityGate.hebrewWords("‫אני מאוד עייפה היום.‬")
        XCTAssertTrue(words.contains("עייפה"))
        XCTAssertFalse(words.contains("עייף"))
    }

    func testGenderGateScoresCorrectAndWrongInflections() {
        // Build a translation map matching the built-in scene indices. Setup lines
        // (1,2) are skipped; payload starts at index 3 (David m, glad → שמח).
        var good: [Int: String] = [1: "x", 2: "y"]
        var bad: [Int: String] = [1: "x", 2: "y"]
        for (i, probe) in TranslationQualityGate.scene.enumerated() {
            guard let expect = probe.expectAny?.first else { continue }
            good[i + 1] = "אני \(expect)"                 // correct inflection
            bad[i + 1] = "אני \(probe.forbidAny.first ?? expect)" // wrong-gender inflection
        }
        let g = TranslationQualityGate.score(approach: "good", translationsByCueIndex: good)
        let b = TranslationQualityGate.score(approach: "bad", translationsByCueIndex: bad)
        XCTAssertEqual(g.correct, g.total)
        XCTAssertEqual(g.accuracy, 1.0, accuracy: 0.001)
        XCTAssertLessThan(b.correct, b.total) // wrong-gender forms are caught
    }

    func testFusedScenePacketsReducePlannedLLMRequestsVsBaseline() {
        let cues = (1 ... 120).map {
            SubtitleCue(index: $0, startMs: $0 * 1_000, endMs: $0 * 1_000 + 600,
                        text: "Line \($0)")
        }
        let packets = ScenePacketer.packets(cues: cues, maxLines: 24, maxSourceChars: 2_400)

        let baselineRequests =
            Int(ceil(Double(cues.count) / 60.0)) + // character analysis
            Int(ceil(Double(cues.count) / 40.0)) + // speaker attribution
            Int(ceil(Double(cues.count) / 20.0))   // batch translation

        XCTAssertEqual(packets.count, 5)
        XCTAssertEqual(baselineRequests, 11)
        XCTAssertLessThan(packets.count, baselineRequests)
    }

    func testScenePacketTranslatorTranslatesPacketsWithOneRequestEach() async throws {
        let chat = ScriptedChat(responses: [
            """
            {"lines":[
              {"i":1,"sg":"m","ag":"f","t":"שלום"},
              {"i":2,"sg":"f","ag":"m","t":"מה שלומך?"}
            ]}
            END
            """,
            """
            {"lines":[{"i":1,"sg":"m","ag":"u","t":"להתראות"}]}
            END
            """,
        ])
        let packets = [
            ScenePacket(cueIndices: [10, 11], lines: ["Hello.", "How are you?"]),
            ScenePacket(cueIndices: [12], lines: ["Goodbye."]),
        ]

        let output = try await ScenePacketTranslator(chat: chat).translate(
            packets: packets,
            targetLang: "he",
            knownCharacters: ["David": "m", "Sarah": "f"]
        )

        let requestCount = await chat.requestCount()
        let prompts = await chat.prompts()

        XCTAssertEqual(output.stats.requests, 2)
        XCTAssertEqual(output.stats.splits, 0)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(output.translationsByCueIndex[10], "שלום")
        XCTAssertEqual(output.translationsByCueIndex[11], "מה שלומך?")
        XCTAssertEqual(output.translationsByCueIndex[12], "להתראות")
        XCTAssertTrue(prompts.first?.contains("KNOWN CHARACTER GENDERS: David=m, Sarah=f") ?? false)
    }

    func testScenePacketTranslatorSplitsMalformedLargePacket() async throws {
        let left = (1 ... 4)
            .map { #"{"i":\#($0),"sg":"u","ag":"u","t":"L\#($0)"}"# }
            .joined(separator: ",")
        let right = (1 ... 4)
            .map { #"{"i":\#($0),"sg":"u","ag":"u","t":"R\#($0)"}"# }
            .joined(separator: ",")
        let chat = ScriptedChat(responses: [
            "not json",
            #"{"lines":[\#(left)]} END"#,
            #"{"lines":[\#(right)]} END"#,
        ])
        let packet = ScenePacket(
            cueIndices: Array(1 ... 8),
            lines: (1 ... 8).map { "Line \($0)" }
        )

        let output = try await ScenePacketTranslator(chat: chat).translate(
            packets: [packet],
            targetLang: "he"
        )

        let requestCount = await chat.requestCount()

        XCTAssertEqual(output.stats.requests, 3)
        XCTAssertEqual(output.stats.splits, 1)
        XCTAssertEqual(output.stats.fallbackFailures, 0)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(output.translationsByCueIndex[1], "L1")
        XCTAssertEqual(output.translationsByCueIndex[4], "L4")
        XCTAssertEqual(output.translationsByCueIndex[5], "R1")
        XCTAssertEqual(output.translationsByCueIndex[8], "R4")
    }

    // MARK: - BibleCache (series character-map reuse)

    func testBibleCacheDetectsSeriesKeyForEpisodicFiles() {
        // Same show, different episodes / naming styles → same key.
        let a = BibleCache.seriesKey(videoPath: "/m/The.Show.S01E02.1080p.mkv")
        let b = BibleCache.seriesKey(videoPath: "/m/The Show - S01E05.mkv")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        // Other episodic spellings are recognized too.
        XCTAssertNotNil(BibleCache.seriesKey(videoPath: "/m/Dexter 1x03.mkv"))
        XCTAssertNotNil(BibleCache.seriesKey(videoPath: "/m/Friends Season 2 ep.mkv"))
    }

    func testBibleCacheReturnsNilForStandaloneFilms() {
        // No season/episode marker → no shared bible (must analyze fresh).
        XCTAssertNil(BibleCache.seriesKey(videoPath: "/m/Inception.2010.1080p.mkv"))
        XCTAssertNil(BibleCache.seriesKey(videoPath: "/m/Blade Runner 2049.mkv"))
    }

    func testBibleCacheSavesAndReusesAcrossEpisodes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ep1 = dir.appendingPathComponent("The.Show.S01E01.mkv").path
        let ep2 = dir.appendingPathComponent("The.Show.S01E02.mkv").path

        XCTAssertTrue(BibleCache.load(videoPath: ep1).isEmpty, "nothing cached yet")
        BibleCache.save(videoPath: ep1, characters: ["David": "m", "Sarah": "f", "X": "u"])
        // Episode 2 of the same show reuses episode 1's map; "u" was not persisted.
        let reused = BibleCache.load(videoPath: ep2)
        XCTAssertEqual(reused["David"], "m")
        XCTAssertEqual(reused["Sarah"], "f")
        XCTAssertNil(reused["X"])
    }

    func testBibleCacheDoesNotShareAcrossStandaloneFilms() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bible-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let filmA = dir.appendingPathComponent("Inception.mkv").path
        let filmB = dir.appendingPathComponent("Interstellar.mkv").path
        BibleCache.save(videoPath: filmA, characters: ["Cobb": "m"])
        // A different standalone film in the same folder must NOT inherit the map.
        XCTAssertTrue(BibleCache.load(videoPath: filmB).isEmpty)
    }

    // MARK: - Daemon JobStore

    func testJobStoreStateTransitions() async {
        let store = JobStore()
        let job = await store.enqueue(path: "/movies/A.mkv", target: "he")
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.progress, 0.0)
        XCTAssertNil(job.sidecarPath)
        XCTAssertGreaterThan(job.queuedAtUtcMs, 0)

        // queued → running with stage/progress.
        await store.markRunning(job.id, stage: "asr", progress: 0.1)
        var cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.state, .running)
        XCTAssertEqual(cur?.stage, "asr")
        XCTAssertNotNil(cur?.startedAtUtcMs)
        XCTAssertNil(cur?.endedAtUtcMs)

        // progress update keeps it running.
        await store.updateProgress(job.id, stage: "translate", progress: 0.7)
        cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.progress ?? 0, 0.7, accuracy: 1e-9)

        // running → done sets sidecar + 1.0.
        await store.markDone(
            job.id,
            sidecarPath: "/movies/A.he.srt",
            rating: JobRating(score: 94, label: "Great", summary: "Clean QA pass"))
        cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.state, .done)
        XCTAssertEqual(cur?.sidecarPath, "/movies/A.he.srt")
        XCTAssertEqual(cur?.progress ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertNotNil(cur?.endedAtUtcMs)
        XCTAssertGreaterThanOrEqual(cur?.durationMs ?? -1, 0)
        XCTAssertEqual(cur?.rating?.score, 94)

        // updateProgress must NOT resurrect a settled (done) job.
        await store.updateProgress(job.id, stage: "asr", progress: 0.2)
        cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.state, .done)
    }

    func testJobStoreDeduplicatesActiveJobs() async {
        let store = JobStore()
        let a = await store.enqueue(path: "/movies/A.mkv", target: "he")
        let b = await store.enqueue(path: "/movies/A.mkv", target: "he")
        XCTAssertEqual(a.id, b.id, "same path+target should return the existing job")
        let all = await store.all()
        XCTAssertEqual(all.count, 1)

        // A different target is a distinct job.
        let c = await store.enqueue(path: "/movies/A.mkv", target: "en")
        XCTAssertNotEqual(c.id, a.id)
        let count = await store.all().count
        XCTAssertEqual(count, 2)
    }

    func testJobStoreFailedJobIsReenqueuable() async {
        let store = JobStore()
        let a = await store.enqueue(path: "/movies/A.mkv", target: "he")
        await store.markFailed(a.id, error: "boom")
        let cur = await store.job(id: a.id)
        XCTAssertEqual(cur?.state, .failed)
        XCTAssertEqual(cur?.error, "boom")
        XCTAssertNotNil(cur?.endedAtUtcMs)
        XCTAssertEqual(cur?.rating?.label, "Failed")

        // A failed job does NOT block a fresh enqueue for the same path+target.
        let b = await store.enqueue(path: "/movies/A.mkv", target: "he")
        XCTAssertNotEqual(b.id, a.id)
        XCTAssertEqual(b.state, .queued)
    }

    func testClearNonRunningRemovesEverythingExceptRunningJobs() async {
        let store = JobStore()
        let a = await store.enqueue(path: "/movies/A.mkv", target: "he")
        let b = await store.enqueue(path: "/movies/B.mkv", target: "he")
        let c = await store.enqueue(path: "/movies/C.mkv", target: "he")
        let d = await store.enqueue(path: "/movies/D.mkv", target: "he")
        // A is running; B is queued; C failed; D finished.
        await store.markRunning(a.id, stage: "asr", progress: 0.1)
        await store.markFailed(c.id, error: "boom")
        await store.markDone(d.id, sidecarPath: "/movies/D.he.srt")

        let cleared = await store.clearNonRunning()
        XCTAssertEqual(cleared, 3, "queued, failed, and done jobs are removed")

        let all = await store.all()
        XCTAssertEqual(all.count, 1, "the running job is retained")
        XCTAssertEqual(all.first?.id, a.id)
        let removedQueued = await store.job(id: b.id)
        XCTAssertNil(removedQueued)
    }

    func testDeleteHistoryJobRemovesOnlySettledJobs() async {
        let store = JobStore()
        let running = await store.enqueue(path: "/movies/A.mkv", target: "he")
        await store.markRunning(running.id, stage: "asr", progress: 0.1)
        let deletedRunning = await store.deleteHistoryJob(id: running.id)
        XCTAssertFalse(deletedRunning)

        let done = await store.enqueue(path: "/movies/B.mkv", target: "he")
        await store.markRunning(done.id, stage: "translate", progress: 0.5)
        await store.markDone(done.id, sidecarPath: "/movies/B.he.srt")
        let deletedDone = await store.deleteHistoryJob(id: done.id)
        XCTAssertTrue(deletedDone)
        let removedDone = await store.job(id: done.id)
        XCTAssertNil(removedDone)
    }

    func testJobStoreNextQueuedIsFIFO() async {
        let store = JobStore()
        let first = await store.enqueue(path: "/movies/A.mkv", target: "he")
        _ = await store.enqueue(path: "/movies/B.mkv", target: "he")
        let next = await store.nextQueued()
        XCTAssertEqual(next?.id, first.id, "oldest queued job runs first")
        // Once the first is running, the next queued is B.
        await store.markRunning(first.id, stage: "asr", progress: 0.1)
        let next2 = await store.nextQueued()
        XCTAssertEqual(next2?.path, "/movies/B.mkv")
    }

    // MARK: - SQLite persistence (M1)

    func testSqliteStoreRoundTripsEntities() async throws {
        let store = try makeTempStore()

        try await store.upsertContextualParent(
            ContextualParent(id: "p1", type: .series, tmdbId: 42, bibleId: "b1"))

        let title = Title(
            id: "t1", path: "/m/A.mkv", contentHash: "t1", container: "mkv",
            codec: "h264", durationMs: 1000, contextualParentId: "p1", tmdbId: 42,
            sourcePreference: .embedded, status: "ready")
        try await store.upsertTitle(title)
        // Idempotent upsert: re-inserting the same id doesn't duplicate.
        try await store.upsertTitle(title)
        let titles = try await store.titles()
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.contextualParentId, "p1")
        XCTAssertEqual(titles.first?.sourcePreference, .embedded)
        XCTAssertEqual(titles.first?.durationMs, 1000)

        let bible = CharacterBible(
            id: "b1", contextualParentId: "p1", version: 3, lockedByUser: true,
            characters: [
                BibleCharacter(
                    id: "c1", canonicalName: "Sarah", gender: .f,
                    nameTranslations: ["he": "שרה"], aliases: ["Sare"],
                    relationships: ["sister of David"], confidence: 0.9, userCorrected: true)
            ])
        try await store.upsertBible(bible)
        let loaded = try await store.bible(forContextualParentId: "p1")
        XCTAssertEqual(loaded?.version, 3)
        XCTAssertTrue(loaded?.lockedByUser ?? false)
        XCTAssertEqual(loaded?.characters.count, 1)
        let c = loaded?.characters.first
        XCTAssertEqual(c?.canonicalName, "Sarah")
        XCTAssertEqual(c?.gender, .f)
        XCTAssertEqual(c?.nameTranslations["he"], "שרה")
        XCTAssertEqual(c?.aliases, ["Sare"])
        XCTAssertEqual(c?.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertTrue(c?.userCorrected ?? false)

        // Re-upserting the bible replaces the character set wholesale.
        try await store.upsertBible(CharacterBible(
            id: "b1", contextualParentId: "p1", version: 4,
            characters: [BibleCharacter(id: "c2", canonicalName: "David", gender: .m)]))
        let reloaded = try await store.bible(forContextualParentId: "p1")
        XCTAssertEqual(reloaded?.version, 4)
        XCTAssertEqual(reloaded?.characters.count, 1)
        XCTAssertEqual(reloaded?.characters.first?.canonicalName, "David")

        let artifact = SubtitleArtifact(
            id: "a1", titleId: "t1", lang: "he", format: .srt, source: .embedded,
            engine: "autosub", model: "dictalm", version: "1",
            sidecarPath: "/m/A.he.srt", cpsStats: ["mean": 12.5, "max": 18.0],
            qaFlags: ["fast"], bibleVersionUsed: 3)
        try await store.upsertArtifact(artifact)
        let arts = try await store.artifacts(forTitleId: "t1")
        XCTAssertEqual(arts.count, 1)
        XCTAssertEqual(arts.first?.source, .embedded)
        XCTAssertEqual(arts.first?.cpsStats["mean"] ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(arts.first?.bibleVersionUsed, 3)

        try await store.upsertJob(ProcessingJob(
            id: "j1", titleId: "t1", stage: "Translator", state: .running,
            priority: 5, progress: 0.5, attempts: 1))
        let pjs = try await store.jobs()
        XCTAssertEqual(pjs.first?.state, .running)
        XCTAssertEqual(pjs.first?.priority, 5)

        // SyncRecord has no read accessor in the protocol — just ensure it persists.
        try await store.upsertSyncRecord(SyncRecord(
            id: "s1", artifactId: "a1", transport: .lan, state: .pending,
            checksum: "abc", deviceTargets: ["iphone"]))
    }

    func testJobStoreReloadResetsRunningToQueued() async throws {
        let sqlite = try makeTempStore()

        // First process lifetime: enqueue two jobs, start the first.
        let s1 = JobStore(store: sqlite)
        let a = await s1.enqueue(path: "/m/A.mkv", target: "he")
        let b = await s1.enqueue(path: "/m/B.mkv", target: "he")
        await s1.markRunning(a.id, stage: "asr", progress: 0.3)

        // Simulate crash + restart: a fresh JobStore over the SAME db.
        let s2 = JobStore(store: sqlite)
        await s2.reload()

        let all = await s2.all()
        XCTAssertEqual(all.count, 2, "both jobs survive the restart")
        let ra = all.first { $0.id == a.id }
        let rb = all.first { $0.id == b.id }
        XCTAssertEqual(ra?.state, .queued, "the interrupted running job is reset to queued")
        XCTAssertEqual(ra?.progress ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(rb?.state, .queued)

        // FIFO order (by seq) is preserved across the restart.
        let next = await s2.nextQueued()
        XCTAssertEqual(next?.id, a.id)

        // clearNonRunning deletes rows: a third store sees an empty queue.
        _ = await s2.clearNonRunning()
        let s3 = JobStore(store: sqlite)
        await s3.reload()
        let count = await s3.all().count
        XCTAssertEqual(count, 0, "cleared jobs do not come back after restart")
    }

    func testJobStorePersistsHistoryFieldsAndPrunesAfterThreeDays() async throws {
        let sqlite = try makeTempStore()
        let s1 = JobStore(store: sqlite)
        let fresh = await s1.enqueue(path: "/m/Fresh.mkv", target: "he")
        await s1.markRunning(fresh.id, stage: "translate", progress: 0.5)
        await s1.markDone(
            fresh.id,
            sidecarPath: "/m/Fresh.he.srt",
            rating: JobRating(score: 88, label: "Good", summary: "1 QA flag"))

        let oldEnded = Date().addingTimeInterval(-4 * 24 * 60 * 60).timeIntervalSince1970
        try await sqlite.saveJob(PersistedJob(
            id: "old", path: "/m/Old.mkv", target: "he", state: "done",
            stage: "done", progress: 1.0, sidecarPath: "/m/Old.he.srt",
            priority: 0, seq: 99, createdAt: oldEnded - 60,
            startedAt: oldEnded - 30, endedAt: oldEnded,
            rating: JobRating(score: 91, label: "Great", summary: "Clean QA pass")))

        let s2 = JobStore(store: sqlite)
        await s2.reload()
        let all = await s2.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, fresh.id)
        XCTAssertNotNil(all.first?.startedAtUtcMs)
        XCTAssertNotNil(all.first?.endedAtUtcMs)
        XCTAssertEqual(all.first?.rating?.score, 88)
    }

    // Helper: a SqliteStore over a throwaway temp DB file.
    private func makeTempStore() throws -> SqliteStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosub-test-\(UUID().uuidString).sqlite")
        return SqliteStore(try AppDatabase.open(at: url))
    }

    // Helper: create a real temp dir so ModelPaths.resolve succeeds.
    private func makeTempModelPaths() throws -> ModelPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosub-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ModelPaths.resolve(environment: ["AUTOSUB_MODELS": dir.path])
    }
}

private actor ScriptedChat: LlamaChat {
    private var responses: [String]
    private var seenPrompts: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String {
        seenPrompts.append(user)
        guard !responses.isEmpty else { throw LlamaError.badResponse("no scripted response") }
        return responses.removeFirst()
    }

    func requestCount() -> Int { seenPrompts.count }
    func prompts() -> [String] { seenPrompts }
}
