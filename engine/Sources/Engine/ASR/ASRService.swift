// ASRService — speech-to-text with word-level timestamps (SPEC §3, §4).
//
// Primary impl is WhisperKit (MIT, ANE-accelerated). We feed it the PCM samples
// produced by our universal AudioDecoder (decode-not-transcode) rather than a
// file path, because WhisperKit's own loader uses AVFoundation and can't open
// MKV. Models load from $AUTOSUB_MODELS/whisperkit (external drive, docs/MODELS.md).

import Foundation
import WhisperKit

/// One recognized word with timing (ms).
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

/// Transcribes decoded PCM samples. Implementations must produce word-level
/// timestamps (critical for the timing/CPS + alignment stages, SPEC §4).
public protocol ASRService: Sendable {
    func transcribe(samples: [Float], sampleRate: Int,
                    sourceLanguageHint: String?) async throws -> ASRResult
}

/// WhisperKit-backed ASR (CoreML/ANE on Apple Silicon).
///
/// An `actor` so the loaded `WhisperKit` pipeline is kept WARM and reused across
/// jobs. Building `WhisperKit(config)` loads the CoreML model (seconds) — doing it
/// per call wasted that load on every file. The daemon's SubtitlePipeline holds one
/// instance for the engine's lifetime. (ASR runs on the ANE; the translation LLM on
/// the GPU — different silicon, so the two stages can overlap.)
public actor WhisperKitASR: ASRService {
    private let modelPaths: ModelPaths
    private let modelName: String
    private var pipe: WhisperKit?   // warm, reused across calls

    /// `modelName` is a whisperkit-coreml folder name, e.g. "openai_whisper-base"
    /// or "openai_whisper-large-v3" (production default).
    public init(modelPaths: ModelPaths, modelName: String = "openai_whisper-base") {
        self.modelPaths = modelPaths
        self.modelName = modelName
    }

    /// Lazily load (once) and return the warm WhisperKit pipeline.
    private func warmPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        let folder = modelPaths.whisperKit.appendingPathComponent(modelName).path
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelPaths.hfCache,  // any aux download (tokenizer) → external drive
            modelFolder: folder,
            download: false                    // load locally; never the system volume
        )
        let p = try await WhisperKit(config)
        self.pipe = p
        return p
    }

    public func transcribe(samples: [Float], sampleRate: Int,
                           sourceLanguageHint: String?) async throws -> ASRResult {
        let pipe = try await warmPipe()

        var options = DecodingOptions()
        options.wordTimestamps = true                 // needed by the Segmenter
        options.language = sourceLanguageHint          // nil ⇒ auto-detect

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        let segments: [ASRSegment] = results.flatMap { $0.segments }.map { seg in
            ASRSegment(
                text: seg.text.trimmingCharacters(in: .whitespaces),
                startMs: Int(seg.start * 1000),
                endMs: Int(seg.end * 1000),
                words: (seg.words ?? []).map {
                    ASRWord(text: $0.word.trimmingCharacters(in: .whitespaces),
                            startMs: Int($0.start * 1000), endMs: Int($0.end * 1000))
                }
            )
        }
        let language = results.first?.language ?? sourceLanguageHint ?? "en"
        return ASRResult(language: language, segments: segments)
    }
}
