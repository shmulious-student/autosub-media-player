// PipelineCheckpoint — durable ASR & source cue checkpointing for restart safety.
//
// Audio decoding and speech recognition (WhisperKit or Cloud ASR) are heavy
// operations that take minutes or consume daily cloud quotas. When an engine
// process restarts or an operation is interrupted before the final .srt sidecar
// is assembled, this checkpoint lets subsequent runs resume from validated source
// cues immediately, skipping ASR completely.
//
// Cleaned up upon successful completion of the full subtitle assembly.

import Foundation
import CryptoKit

public struct PipelineCheckpoint: Codable, Sendable {
    public var videoPath: String
    public var targetLang: String
    public var source: SubtitleSource
    public var sourceLang: String?
    public var sourceQaFlags: [String]
    public var cues: [SubtitleCue]
    public var createdAt: Double

    public init(
        videoPath: String,
        targetLang: String,
        source: SubtitleSource,
        sourceLang: String? = nil,
        sourceQaFlags: [String] = [],
        cues: [SubtitleCue],
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.videoPath = videoPath
        self.targetLang = targetLang
        self.source = source
        self.sourceLang = sourceLang
        self.sourceQaFlags = sourceQaFlags
        self.cues = cues
        self.createdAt = createdAt
    }
}

public struct PipelineCheckpointStore: Sendable {
    public init() {}

    static let fileNamePrefix = ".autosub-checkpoint-"

    /// Primary location: beside the video file.
    public static func primaryURL(videoPath: String, targetLang: String) -> URL {
        URL(fileURLWithPath: videoPath).deletingLastPathComponent()
            .appendingPathComponent("\(fileNamePrefix)\(targetLang).json")
    }

    /// Fallback location in Application Support in case media folder is read-only.
    public static func fallbackURL(videoPath: String, targetLang: String) -> URL {
        let baseDir: URL
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            baseDir = appSupport.appendingPathComponent("AutoSub/checkpoints", isDirectory: true)
        } else {
            baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("autosub-checkpoints", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(videoPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let baseName = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        return baseDir.appendingPathComponent("\(baseName)_\(digest)_\(targetLang).json")
    }

    public func save(_ checkpoint: PipelineCheckpoint) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(checkpoint) else { return }

        let primary = Self.primaryURL(videoPath: checkpoint.videoPath, targetLang: checkpoint.targetLang)
        do {
            try data.write(to: primary, options: .atomic)
        } catch {
            let fb = Self.fallbackURL(videoPath: checkpoint.videoPath, targetLang: checkpoint.targetLang)
            try? data.write(to: fb, options: .atomic)
        }
    }

    public func load(videoPath: String, targetLang: String) -> PipelineCheckpoint? {
        let primary = Self.primaryURL(videoPath: videoPath, targetLang: targetLang)
        let fallback = Self.fallbackURL(videoPath: videoPath, targetLang: targetLang)

        for url in [primary, fallback] {
            if let data = try? Data(contentsOf: url),
               let cp = try? JSONDecoder().decode(PipelineCheckpoint.self, from: data),
               !cp.cues.isEmpty {
                return cp
            }
        }
        return nil
    }

    public func remove(videoPath: String, targetLang: String) {
        let primary = Self.primaryURL(videoPath: videoPath, targetLang: targetLang)
        let fallback = Self.fallbackURL(videoPath: videoPath, targetLang: targetLang)

        try? FileManager.default.removeItem(at: primary)
        try? FileManager.default.removeItem(at: fallback)
    }
}
