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

    func testClearQueuedRemovesOnlyQueuedJobs() async {
        let store = JobStore()
        let a = await store.enqueue(path: "/movies/A.mkv", target: "he")
        _ = await store.enqueue(path: "/movies/B.mkv", target: "he")
        _ = await store.enqueue(path: "/movies/C.mkv", target: "he")
        // A is running; B and C are still queued.
        await store.markRunning(a.id, stage: "asr", progress: 0.1)

        let cleared = await store.clearQueued()
        XCTAssertEqual(cleared, 2, "both queued jobs removed")

        let all = await store.all()
        XCTAssertEqual(all.count, 1, "the running job is retained")
        XCTAssertEqual(all.first?.id, a.id)
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

        // clearQueued deletes rows: a third store sees an empty queue.
        _ = await s2.clearQueued()
        let s3 = JobStore(store: sqlite)
        await s3.reload()
        let count = await s3.all().count
        XCTAssertEqual(count, 0, "cleared jobs do not come back after restart")
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
