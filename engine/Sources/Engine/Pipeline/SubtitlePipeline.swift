// SubtitlePipeline — the reusable end-to-end subtitle generation pipeline.
//
// Runs the production vertical slice for one media file:
//   decode → WhisperKit ASR → Segmenter → SpeakerAttributor → DictaLMTranslator
//   → SrtAssembler.writeSidecar → "<base>.<lang>.srt".
//
// This is the single source of truth shared by BOTH the `process` CLI subcommand
// and the loopback daemon's job worker. The daemon owns ONE long-lived instance
// so the (multi-GB) DictaLM model is loaded ONCE into a warm llama-server and
// reused across every job — never one server per job (SPEC §3, §4).
//
// Models resolve from $AUTOSUB_MODELS (external drive only, docs/MODELS.md).

import Foundation

/// Result of a successful pipeline run.
public struct SubtitleJobResult: Sendable {
    /// Absolute path to the written `.srt` sidecar.
    public let sidecarPath: String
    /// Number of cues written.
    public let cueCount: Int

    public init(sidecarPath: String, cueCount: Int) {
        self.sidecarPath = sidecarPath
        self.cueCount = cueCount
    }
}

/// Drives one media file through the production pipeline, keeping a WARM
/// llama-server (DictaLM) alive across calls.
///
/// `run` is serialized by the actor, so callers MUST queue jobs externally if
/// they want true one-at-a-time processing across distinct awaits — the daemon's
/// JobQueue does exactly that. The warm server is started lazily on the first run
/// that needs it and reused thereafter until `shutdown()`.
public actor SubtitlePipeline {
    private let modelPaths: ModelPaths
    private let whisperModelName: String

    // The warm DictaLM server, started lazily and reused.
    private var llamaServer: LlamaServer?
    private var chatClient: (any LlamaChat)?

    public init(modelPaths: ModelPaths, whisperModelName: String = "openai_whisper-base") {
        self.modelPaths = modelPaths
        self.whisperModelName = whisperModelName
    }

    /// Lazily start (once) and return the warm DictaLM chat client.
    private func warmChat() async throws -> any LlamaChat {
        if let chatClient { return chatClient }
        let model = try LlamaServer.findModel(in: modelPaths.llm)
        let server = LlamaServer(modelURL: model)
        try await server.start()
        let client = await server.client()
        self.llamaServer = server
        self.chatClient = client
        return client
    }

    /// Run the full pipeline for one file and write the sidecar.
    ///
    /// - If a sidecar already exists for (videoPath, targetLang) it is returned
    ///   immediately as done (no re-processing).
    /// - `onProgress` reports a coarse 0.0…1.0 fraction plus a short stage label
    ///   ("decode", "asr", "attribute", "translate", "assemble", "done").
    public func run(
        videoPath: String,
        targetLang: String,
        onProgress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> SubtitleJobResult {
        // Short-circuit: already produced.
        if let existing = Self.existingSidecar(videoPath: videoPath, lang: targetLang) {
            let count = Self.cueCount(inSidecar: existing)
            onProgress(1.0, "done")
            return SubtitleJobResult(sidecarPath: existing, cueCount: count)
        }

        // 1. Source: prefer an embedded TEXT subtitle track — exact dialogue +
        //    timing and NO ASR pass (much faster). Fall back to decode + WhisperKit
        //    ASR only when there's no usable text subtitle.
        var cues: [SubtitleCue]
        let extractor = SubtitleExtractor()
        if let track = try? extractor.bestTextTrack(videoPath: videoPath, targetLang: targetLang),
           let embedded = try? extractor.extractCues(videoPath: videoPath, trackIndex: track.index),
           !embedded.isEmpty {
            onProgress(0.20, "embedded-sub")
            cues = embedded
        } else {
            onProgress(0.02, "decode")
            let decoded = try AudioDecoder().decode(videoPath: videoPath)
            onProgress(0.15, "asr")
            let asr = try await WhisperKitASR(modelPaths: modelPaths, modelName: whisperModelName)
                .transcribe(samples: decoded.samples, sampleRate: decoded.sampleRate,
                            sourceLanguageHint: nil)
            onProgress(0.45, "segment")
            cues = Segmenter().segment(asr)
        }

        // 2. Warm DictaLM + BATCH translation (many lines per call; the model
        //    infers speaker/addressee gender from each chunk's context).
        onProgress(0.50, "translate")
        let chat = try await warmChat()
        let translator = DictaLMTranslator(modelPaths: modelPaths, chat: chat)
        let translations = try await translator.translateBatch(
            lines: cues.map { $0.text }, targetLang: targetLang,
            onProgress: { frac in onProgress(0.50 + 0.45 * frac, "translate") }
        )
        for i in cues.indices where i < translations.count { cues[i].text = translations[i] }

        // 3. Assemble + write the RTL .srt sidecar.
        onProgress(0.97, "assemble")
        let path = try SrtAssembler().writeSidecar(cues: cues, lang: targetLang, videoPath: videoPath)

        onProgress(1.0, "done")
        return SubtitleJobResult(sidecarPath: path, cueCount: cues.count)
    }

    /// Stop the warm llama-server (idempotent). Call on daemon shutdown.
    public func shutdown() async {
        await llamaServer?.stop()
        llamaServer = nil
        chatClient = nil
    }

    // MARK: - Sidecar helpers

    /// The sidecar path for (videoPath, lang): `<dir>/<base>.<lang>.srt`.
    public static func sidecarPath(videoPath: String, lang: String) -> String {
        let video = URL(fileURLWithPath: videoPath)
        let base = video.deletingPathExtension().lastPathComponent
        return video.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(lang).srt").path
    }

    /// Returns the existing sidecar path if present, else nil.
    static func existingSidecar(videoPath: String, lang: String) -> String? {
        let p = sidecarPath(videoPath: videoPath, lang: lang)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Best-effort cue count of an existing .srt (counts blank-line-separated blocks).
    static func cueCount(inSidecar path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        // A cue block starts with a numeric index line followed by a timecode line.
        return text.split(separator: "\n").filter { $0.contains("-->") }.count
    }
}
