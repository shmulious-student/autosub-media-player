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

    // MARK: - Daemon JobStore

    func testJobStoreStateTransitions() async {
        let store = JobStore()
        let job = await store.enqueue(path: "/movies/A.mkv", target: "he")
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.progress, 0.0)
        XCTAssertNil(job.sidecarPath)

        // queued → running with stage/progress.
        await store.markRunning(job.id, stage: "asr", progress: 0.1)
        var cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.state, .running)
        XCTAssertEqual(cur?.stage, "asr")

        // progress update keeps it running.
        await store.updateProgress(job.id, stage: "translate", progress: 0.7)
        cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.progress ?? 0, 0.7, accuracy: 1e-9)

        // running → done sets sidecar + 1.0.
        await store.markDone(job.id, sidecarPath: "/movies/A.he.srt")
        cur = await store.job(id: job.id)
        XCTAssertEqual(cur?.state, .done)
        XCTAssertEqual(cur?.sidecarPath, "/movies/A.he.srt")
        XCTAssertEqual(cur?.progress ?? 0, 1.0, accuracy: 1e-9)

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

        // A failed job does NOT block a fresh enqueue for the same path+target.
        let b = await store.enqueue(path: "/movies/A.mkv", target: "he")
        XCTAssertNotEqual(b.id, a.id)
        XCTAssertEqual(b.state, .queued)
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

    // Helper: create a real temp dir so ModelPaths.resolve succeeds.
    private func makeTempModelPaths() throws -> ModelPaths {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosub-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ModelPaths.resolve(environment: ["AUTOSUB_MODELS": dir.path])
    }
}
