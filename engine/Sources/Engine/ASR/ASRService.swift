// ASRService — speech-to-text with word-level timestamps (SPEC §3).
//
// Primary impl is WhisperKit (MIT, ANE-accelerated), with a forced-alignment
// refinement pass (WhisperX-style, ±50 ms target). whisper.cpp sits behind the
// same protocol as a fallback.
//
// v0 status: protocol + WhisperKitASR stub. No real WhisperKit dep yet (TODO in
// Package.swift). The stub returns an empty transcript so the pipeline compiles.

import Foundation

/// One recognized segment with word-level timing.
public struct ASRWord: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct ASRSegment: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var words: [ASRWord]
    public init(text: String, startMs: Int, endMs: Int, words: [ASRWord] = []) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.words = words
    }
}

public struct ASRResult: Codable, Sendable {
    public var language: String
    public var segments: [ASRSegment]
    public init(language: String, segments: [ASRSegment]) {
        self.language = language
        self.segments = segments
    }
}

/// Transcribes an audio file. Implementations must produce word-level timestamps
/// (critical for the timing/CPS + forced-alignment stages, SPEC §4).
public protocol ASRService: Sendable {
    func transcribe(audioPath: String, sourceLanguageHint: String?) async throws -> ASRResult
}

/// WhisperKit-backed ASR. v0: STUB.
public struct WhisperKitASR: ASRService {
    private let modelPaths: ModelPaths

    public init(modelPaths: ModelPaths) {
        self.modelPaths = modelPaths
    }

    public func transcribe(audioPath: String, sourceLanguageHint: String?) async throws -> ASRResult {
        // TODO(v0): load WhisperKit with its model folder set to
        // modelPaths.whisperKit (docs/MODELS.md — never the default app-support
        // dir), run transcription with word timestamps, then a forced-alignment
        // refinement pass for ±50 ms accuracy.
        _ = modelPaths.whisperKit
        return ASRResult(language: sourceLanguageHint ?? "en", segments: [])
    }
}
