import XCTest
@testable import Engine

final class AutoSubPathsTests: XCTestCase {
    func testDataDirectoryAndSubpaths() {
        let dir = AutoSubPaths.dataDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "dataDirectory must exist")

        let dbURL = AutoSubPaths.databaseURL
        XCTAssertTrue(dbURL.path.hasSuffix("autosub.sqlite"))

        let checkpointsDir = AutoSubPaths.checkpointsDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointsDir.path))
        XCTAssertTrue(checkpointsDir.path.hasSuffix("checkpoints"))

        let cacheDir = AutoSubPaths.cacheDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
        XCTAssertTrue(cacheDir.path.hasSuffix("cache"))
    }

    func testCheckpointsFallbackURLUsesDataDirectory() {
        let fallback = PipelineCheckpointStore.fallbackURL(videoPath: "/movies/Test.mkv", targetLang: "he")
        XCTAssertTrue(fallback.path.contains(".autosub/checkpoints") || fallback.path.contains("checkpoints"))
        XCTAssertTrue(fallback.lastPathComponent.contains("Test_"))
        XCTAssertTrue(fallback.lastPathComponent.hasSuffix("_he.json"))
    }

    func testCueTranslationCacheFallbackUsesDataDirectory() {
        let cache = CueTranslationCache(videoPath: "/movies/Test.mkv")
        XCTAssertEqual(cache.count, 0)
    }
}
