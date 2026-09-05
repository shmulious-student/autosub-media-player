// ASRService — speech-to-text with word-level timestamps (SPEC §3, §4).
//
// Primary impl is WhisperKit (MIT, ANE-accelerated). We feed it the PCM samples
// produced by our universal AudioDecoder (decode-not-transcode) rather than a
// file path, because WhisperKit's own loader uses AVFoundation and can't open
// MKV. Models load from $AUTOSUB_MODELS/whisperkit (external drive, docs/MODELS.md).

import Foundation
import WhisperKit

/// One recognized word with timing (ms) and model confidence.
public struct ASRWord: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// WhisperKit per-word probability (0…1), nil when the ASR doesn't expose it.
    public var probability: Double?
    public init(text: String, startMs: Int, endMs: Int, probability: Double? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.probability = probability
    }
}

public struct ASRSegment: Codable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var words: [ASRWord]
    /// Mean token log-probability (higher = more confident; ~ -1.0 ≈ p 0.37).
    public var avgLogprob: Double?
    /// No-speech probability (note: unimplemented in the current WhisperKit, always 0).
    public var noSpeechProb: Double?
    /// gzip compression ratio of the segment text — high (>2.4) signals repetition.
    public var compressionRatio: Double?
    public init(text: String, startMs: Int, endMs: Int, words: [ASRWord] = [],
                avgLogprob: Double? = nil, noSpeechProb: Double? = nil,
                compressionRatio: Double? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.words = words
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
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

    /// Pick the most accurate WhisperKit model that is ACTUALLY INSTALLED under
    /// `modelPaths/whisperkit`, by accuracy priority (large-v3-turbo ▸ large-v3 ▸
    /// large ▸ medium ▸ small ▸ base ▸ tiny). Falls back to "openai_whisper-base" so
    /// a fresh install (only base present) still runs — the accuracy win simply waits
    /// until a bigger model is downloaded. (WhisperKit loads local-only: download=false.)
    /// `maxTier` caps the choice for memory-constrained Macs (InferenceConfig):
    /// large-v3-turbo is worth its ~1.6 GB on a 16 GB+ machine and is not on 8 GB.
    public static func resolveBestModel(
        modelPaths: ModelPaths, fileManager: FileManager = .default,
        maxTier: String = InferenceConfig.current.maxWhisperTier
    ) -> String {
        let dir = modelPaths.whisperKit
        let entries = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        let folders = entries.filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fileManager.fileExists(
                atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        func rank(_ name: String) -> Int {
            let n = name.lowercased()
            if n.contains("large-v3"), n.contains("turbo") { return 7 }
            if n.contains("large-v3") { return 6 }
            if n.contains("large") { return 5 }
            if n.contains("medium") { return 4 }
            if n.contains("small") { return 3 }
            if n.contains("base") { return 2 }
            if n.contains("tiny") { return 1 }
            return 0
        }
        let ceiling = rank(maxTier) > 0 ? rank(maxTier) : 7
        let allowed = folders.filter { rank($0) > 0 && rank($0) <= ceiling }
        // Nothing within the ceiling installed → fall back to the smallest present,
        // which is still better than failing to transcribe at all.
        let pick = allowed.max { rank($0) < rank($1) }
            ?? folders.filter { rank($0) > 0 }.min { rank($0) < rank($1) }
        return pick ?? "openai_whisper-base"
    }

    /// Map an ISO-639 audio-track tag (often 639-2/B like "eng", "ger", "heb") to the
    /// 2-letter code Whisper expects, or nil to let WhisperKit auto-detect. Conservative:
    /// only returns a hint we're confident about, so a stray tag never misguides ASR.
    public static func whisperLanguageHint(_ iso: String?) -> String? {
        guard let raw = iso?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              raw != "und" else { return nil }
        let map: [String: String] = [
            "eng": "en", "heb": "he", "iw": "he", "ara": "ar", "rus": "ru", "spa": "es",
            "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it", "por": "pt",
            "nld": "nl", "dut": "nl", "pol": "pl", "tur": "tr", "fas": "fa", "per": "fa",
            "ukr": "uk", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh", "hin": "hi",
        ]
        if let two = map[raw] { return two }
        if raw.count == 2 { return raw }                 // already 2-letter
        return nil
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
            let words: [ASRWord] = (seg.words ?? []).map { w in
                ASRWord(text: w.word.trimmingCharacters(in: .whitespaces),
                        startMs: Int(w.start * 1000), endMs: Int(w.end * 1000),
                        probability: Double(w.probability))
            }
            return ASRSegment(
                text: seg.text.trimmingCharacters(in: .whitespaces),
                startMs: Int(seg.start * 1000),
                endMs: Int(seg.end * 1000),
                words: words,
                avgLogprob: Double(seg.avgLogprob),
                noSpeechProb: Double(seg.noSpeechProb),
                compressionRatio: Double(seg.compressionRatio)
            )
        }
        let language = results.first?.language ?? sourceLanguageHint ?? "en"
        return ASRResult(language: language, segments: segments)
    }
}
