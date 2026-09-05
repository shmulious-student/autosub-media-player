import XCTest
@testable import Engine

final class PipelineCheckpointTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosub-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testCheckpointSaveLoadAndRemove() {
        let videoPath = tempDir.appendingPathComponent("sample_movie.mkv").path
        let targetLang = "he"
        let store = PipelineCheckpointStore()

        let cues = [
            SubtitleCue(index: 0, startMs: 1000, endMs: 2500, text: "Good morning."),
            SubtitleCue(index: 1, startMs: 2600, endMs: 4000, text: "How are you today?"),
            SubtitleCue(index: 2, startMs: 4100, endMs: 6000, text: "I am doing well, thank you.")
        ]

        let checkpoint = PipelineCheckpoint(
            videoPath: videoPath,
            targetLang: targetLang,
            source: .asr,
            sourceLang: "en",
            sourceQaFlags: ["low-conf@1"],
            cues: cues
        )

        // Save
        store.save(checkpoint)

        // Load
        let loaded = store.load(videoPath: videoPath, targetLang: targetLang)
        XCTAssertNotNil(loaded, "Checkpoint should be loaded from disk")
        XCTAssertEqual(loaded?.videoPath, videoPath)
        XCTAssertEqual(loaded?.targetLang, targetLang)
        XCTAssertEqual(loaded?.source, .asr)
        XCTAssertEqual(loaded?.sourceLang, "en")
        XCTAssertEqual(loaded?.sourceQaFlags, ["low-conf@1"])
        XCTAssertEqual(loaded?.cues.count, 3)
        XCTAssertEqual(loaded?.cues[0].text, "Good morning.")
        XCTAssertEqual(loaded?.cues[1].startMs, 2600)
        XCTAssertEqual(loaded?.cues[2].endMs, 6000)

        // Remove
        store.remove(videoPath: videoPath, targetLang: targetLang)
        let afterRemove = store.load(videoPath: videoPath, targetLang: targetLang)
        XCTAssertNil(afterRemove, "Checkpoint should be nil after removal")
    }

    func testCheckpointFallbackURL() {
        let videoPath = "/Volumes/ReadOnlyDrive/Media/movie.mp4"
        let targetLang = "he"
        let fallback = PipelineCheckpointStore.fallbackURL(videoPath: videoPath, targetLang: targetLang)

        XCTAssertTrue(fallback.path.contains("movie_"), "Fallback filename should contain video basename")
        XCTAssertTrue(fallback.path.hasSuffix("_he.json"), "Fallback filename should end with language and .json")
    }

    func testIncrementalTranslationCacheSurvivesRestart() async throws {
        let videoPath = tempDir.appendingPathComponent("test_series_s01e01.mkv").path
        let targetLang = "he"

        // 1. First run: translates packet 1, then gets interrupted
        var cache1 = CueTranslationCache(videoPath: videoPath)
        let key0 = CueTranslationCache.key(source: "Hello world.", targetLang: targetLang, binding: nil, synopsis: nil, glossary: [:])
        let key1 = CueTranslationCache.key(source: "Welcome back.", targetLang: targetLang, binding: nil, synopsis: nil, glossary: [:])

        cache1.store("שלום עולם.", for: key0)
        cache1.store("ברוך שובך.", for: key1)
        cache1.save()

        // 2. Simulate restart: create fresh CueTranslationCache instance (as a new process would)
        let cache2 = CueTranslationCache(videoPath: videoPath)
        XCTAssertEqual(cache2.value(for: key0), "שלום עולם.")
        XCTAssertEqual(cache2.value(for: key1), "ברוך שובך.")

        // 3. Test ScenePacketTranslator skips cached packet without calling LLM
        final class CountingMockChat: LlamaChat, @unchecked Sendable {
            var callCount = 0
            func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String {
                callCount += 1
                return "1. תרגום חדש."
            }
        }

        let mockChat = CountingMockChat()
        let translator = ScenePacketTranslator(chat: mockChat, format: .lean, sourceLang: "en")

        let packet1 = ScenePacket(cueIndices: [0, 1], lines: ["Hello world.", "Welcome back."])
        let packet2 = ScenePacket(cueIndices: [2], lines: ["A completely new line."])

        let cachedMap = [0: "שלום עולם.", 1: "ברוך שובך."]

        var packetCallbackCount = 0
        let output = try await translator.translate(
            packets: [packet1, packet2],
            targetLang: targetLang,
            cached: cachedMap,
            onPacketTranslated: { _ in packetCallbackCount += 1 }
        )

        // Packet 1 should be completely served from cache (0 LLM calls)
        // Packet 2 should be translated via LLM (1 LLM call)
        XCTAssertEqual(mockChat.callCount, 1, "Mock LLM should only be called for the uncached packet")
        XCTAssertEqual(output.stats.cachedLines, 2, "Two lines should be counted as served from cache")
        XCTAssertEqual(output.translationsByCueIndex[0], "שלום עולם.")
        XCTAssertEqual(output.translationsByCueIndex[1], "ברוך שובך.")
        XCTAssertEqual(output.translationsByCueIndex[2], "תרגום חדש.")
        XCTAssertEqual(packetCallbackCount, 1, "Callback should be invoked for the newly translated packet")
    }

    func testSceneSynopsisFlushesPerScene() {
        let videoPath = tempDir.appendingPathComponent("synopsis_test.mkv").path
        let cache = SceneSynopsisCache(videoPath: videoPath)

        let key = SceneSynopsis.cacheKey(["They walk down the dark alley.", "Rain pours heavily."])
        cache.store("They are navigating a rainy backstreet at night.", for: key)
        cache.flush()

        // New cache instance recovers the synopsis immediately
        let cache2 = SceneSynopsisCache(videoPath: videoPath)
        XCTAssertEqual(cache2.value(for: key), "They are navigating a rainy backstreet at night.")
    }
}
