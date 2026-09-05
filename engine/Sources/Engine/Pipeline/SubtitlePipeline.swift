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

/// Result of a successful pipeline run. Carries enough provenance for the daemon
/// to persist a `SubtitleArtifact` without re-inspecting the file.
public struct SubtitleJobResult: Sendable {
    /// Absolute path to the written `.srt` sidecar.
    public let sidecarPath: String
    /// Number of cues written.
    public let cueCount: Int
    /// Where the dialogue came from (embedded text track vs. ASR).
    public let source: SubtitleSource
    /// characters-per-second QA stats (mean/max) for the written cues.
    public let cpsStats: [String: Double]
    /// Bible version used to translate, when a bible was applied (M2+); else nil.
    public let bibleVersionUsed: Int?
    /// QA flags surfaced during the run (e.g. `"unverified@<cue>"` for lines that
    /// failed fidelity validation, `"low-confidence@<cue>"` from the ASR validator).
    public let qaFlags: [String]

    public init(
        sidecarPath: String,
        cueCount: Int,
        source: SubtitleSource = .asr,
        cpsStats: [String: Double] = [:],
        bibleVersionUsed: Int? = nil,
        qaFlags: [String] = []
    ) {
        self.sidecarPath = sidecarPath
        self.cueCount = cueCount
        self.source = source
        self.cpsStats = cpsStats
        self.bibleVersionUsed = bibleVersionUsed
        self.qaFlags = qaFlags
    }
}

/// Identity + bible context the daemon resolves for a title before running the
/// pipeline. M1: built but unused inside `run`; M2 threads the stored bible
/// through it to drive glossary-locked, gender-consistent translation.
public struct TitleContext: Sendable {
    public let titleId: String
    public let contextualParentId: String?
    public var bible: CharacterBible?

    public init(titleId: String, contextualParentId: String? = nil, bible: CharacterBible? = nil) {
        self.titleId = titleId
        self.contextualParentId = contextualParentId
        self.bible = bible
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
    private let whisperModelName: String?

    // Warm DictaLM servers, started lazily and reused, keyed by model path so a
    // strategy that needs BOTH the 12B (quality) and 7B (fast) keeps each loaded
    // once across jobs.
    private var servers: [String: LlamaServer] = [:]
    private var chats: [String: any LlamaChat] = [:]

    // The warm WhisperKit ASR (CoreML load is expensive — keep it across jobs).
    private var asrService: WhisperKitASR?

    /// `whisperModelName` nil ⇒ auto-resolve the best INSTALLED model (turbo ▸ … ▸ base)
    /// at first use, so we get large-v3-turbo accuracy when present without breaking on a
    /// base-only install. Pass an explicit name to pin one.
    public init(modelPaths: ModelPaths, whisperModelName: String? = nil) {
        self.modelPaths = modelPaths
        self.whisperModelName = whisperModelName
    }

    /// The warm WhisperKit instance, created once and reused.
    private func warmASR() -> WhisperKitASR {
        if let asrService { return asrService }
        let name = whisperModelName ?? WhisperKitASR.resolveBestModel(modelPaths: modelPaths)
        let s = WhisperKitASR(modelPaths: modelPaths, modelName: name)
        asrService = s
        return s
    }

    /// Lazily start (once) and return the warm chat client for a given model dir.
    /// Reused across jobs; both tiers can be kept warm for the progressive strategy.
    private func warmChat(in modelDir: URL) async throws -> any LlamaChat {
        let model = try LlamaServer.findModel(in: modelDir)
        if let c = chats[model.path] { return c }
        let server = LlamaServer(modelURL: model, contextSize: 8192)
        try await server.start()
        let client = await server.client()
        servers[model.path] = server
        chats[model.path] = client
        return client
    }

    /// Quality (12B) and fast (7B) chat clients on demand.
    private func qualityChat() async throws -> any LlamaChat { try await warmChat(in: modelPaths.llm) }
    private func fastChat() async throws -> any LlamaChat { try await warmChat(in: modelPaths.llmFast) }

    /// Generate a one-line "role in the plot" for each character, grounded in the
    /// title's plot overview, using the warm fast model. Best-effort and clearly
    /// AI-generated (the Characters view labels it as such): characters the model
    /// can't reliably place get no entry. Returns character name → one sentence.
    public func characterRoles(
        title: String, year: Int?, overview: String, characters: [String]
    ) async throws -> [String: String] {
        let names = characters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(40)
        guard !names.isEmpty else { return [:] }
        let chat = try await fastChat()
        let yearStr = year.map { " (\($0))" } ?? ""
        let numbered = names.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        You are a film and TV reference. For the title "\(title)"\(yearStr), the plot \
        overview is:
        \(overview.isEmpty ? "(no overview available)" : overview)

        For each numbered character below, write ONE concise English sentence describing \
        their role / part in the plot of THIS title. Ground it in the overview and \
        well-known facts. If you do not reliably know the character's role, output an \
        EMPTY line for that number — do not invent specific plot details.

        Output exactly one line per character, in the form "<number>. <one sentence>". \
        No other text.

        Characters:
        \(numbered)
        """
        let raw = try await chat.complete(
            system: nil, user: prompt,
            maxTokens: max(220, names.count * 44 + 80), temperature: 0.3)
        let parsed = DictaLMTranslator.parseNumbered(raw, expected: names.count)
        var out: [String: String] = [:]
        for (i, name) in names.enumerated() {
            let s = i < parsed.count
                ? parsed[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !s.isEmpty { out[name] = s }
        }
        return out
    }

    /// Run the full pipeline for one file and write the sidecar.
    ///
    /// - If a sidecar already exists for (videoPath, targetLang) it is returned
    ///   immediately as done (no re-processing).
    /// - `strategy` picks the speed/quality tier (SPEC §9). `.progressive` writes a
    ///   watchable 7B draft FIRST (firing `onDraftReady`) then upgrades gender in the
    ///   background before returning.
    /// - `onProgress` reports a coarse 0.0…1.0 fraction plus a short stage label
    ///   ("decode", "asr", "translate", "refine", "assemble", "done").
    /// - `onDraftReady(path)` fires once the first watchable sidecar exists (progressive
    ///   only); the file at `path` is playable while the background pass continues.
    public func run(
        videoPath: String,
        targetLang: String,
        strategy: TranslationStrategy = .default,
        titleContext: TitleContext? = nil,
        sourceSubtitlePath: String? = nil,
        sourceSubtitleOverride: Bool = false,
        characters: [String: String] = [:],
        nameGlossary: [String: String] = [:],
        force: Bool = false,
        onProgress: @Sendable (Double, String) -> Void = { _, _ in },
        onDraftReady: @Sendable (String) -> Void = { _ in }
    ) async throws -> SubtitleJobResult {
        // Short-circuit: already produced (unless a re-generate forces a fresh run,
        // which overwrites the existing sidecar at the assemble step).
        if !force, let existing = Self.existingSidecar(videoPath: videoPath, lang: targetLang) {
            let count = Self.cueCount(inSidecar: existing)
            onProgress(1.0, "done")
            return SubtitleJobResult(sidecarPath: existing, cueCount: count)
        }

        // 1. Source: prefer an embedded TEXT subtitle track — exact dialogue +
        //    timing and NO ASR pass (much faster). Fall back to decode + WhisperKit
        //    ASR only when there's no usable text subtitle.
        var cues: [SubtitleCue]
        var source: SubtitleSource = .asr
        // Spoken/source language, declared to the translator so it renders FROM the
        // right language and never re-translates already-target text.
        var sourceLang: String?
        // QA flags from source acquisition (ASR validator); merged into the result.
        var sourceQaFlags: [String] = []
        let extractor = SubtitleExtractor()
        // The spoken/original language from the first tagged audio track — the best
        // signal for "what was actually said". Drives BOTH which embedded track is a
        // faithful source and the ASR language hint.
        let audioLang = (try? AudioTrackProbe().probe(videoPath: videoPath))?
            .first(where: { $0.language != nil })?.language
        let originalHint = WhisperKitASR.whisperLanguageHint(audioLang)

        func fetchedSource() -> (cues: [SubtitleCue], lang: String?)? {
            guard let sp = sourceSubtitlePath, let fetched = extractor.cuesFromFile(path: sp),
                  !fetched.isEmpty else { return nil }
            return (fetched, Self.languageFromSourceSidecar(sp))
        }

        if sourceSubtitleOverride, let fetched = fetchedSource() {
            // User-supplied source file/URL: respect the explicit override even when
            // the container also has a text track.
            onProgress(0.20, "manual-sub")
            cues = fetched.cues
            source = .online
            sourceLang = fetched.lang
        } else if let track = try? extractor.bestTextTrack(
               videoPath: videoPath, targetLang: targetLang, originalLang: originalHint),
           let embedded = try? extractor.extractCues(videoPath: videoPath, trackIndex: track.index),
           !embedded.isEmpty {
            onProgress(0.20, "embedded-sub")
            cues = embedded
            source = .embedded
            sourceLang = track.language
        } else if let fetched = fetchedSource() {
            // A source-language subtitle the app fetched online: exact
            // dialogue + timing, no ASR pass. The original language is encoded in the
            // sidecar name (`<base>.<lang>.src.srt`) so the translator can declare it.
            onProgress(0.20, "online-sub")
            cues = fetched.cues
            source = .online
            sourceLang = fetched.lang
        } else {
            onProgress(0.02, "decode")
            let decoded = try AudioDecoder().decode(videoPath: videoPath)
            onProgress(0.15, "asr")
            // Bias Whisper with the audio track's declared language when we recognize it
            // (else nil ⇒ auto-detect) — fewer mis-detections on short/noisy openings.
            let asr = try await warmASR()
                .transcribe(samples: decoded.samples, sampleRate: decoded.sampleRate,
                            sourceLanguageHint: originalHint)
            onProgress(0.45, "segment")
            // Deterministic validation: collapse ASR repetition loops, drop empties,
            // flag low-confidence / too-fast cues before they become the source text.
            let validated = AsrValidator.validate(cues: Segmenter().segment(asr), asr: asr)
            cues = validated.cues
            sourceQaFlags = validated.qaFlags
            sourceLang = asr.language
        }

        // 2. Translate. ONE lean scene-packet path (gender/scene context in the prompt,
        //    only the Hebrew decoded) drives every strategy — they differ only in which
        //    model runs and whether a background gender pass follows.
        let sanitized = PromptTextSanitizer.sanitizedCues(cues)
        // Regroup sentence-fragment cues (embedded subs / ASR 42-char cues split one
        // sentence across several cues) into whole sentences for translation, so the
        // model produces one stable Hebrew sentence per source sentence. We translate
        // those SENTENCE units and redistribute each translation back across its
        // original cues — every cue keeps its exact timing, so the track can't drift.
        let sentences = SentenceRegrouper.group(sanitized)
        let sentenceCues = sentences.enumerated().map { (i, g) in
            SubtitleCue(index: i, startMs: g.startMs, endMs: g.endMs, text: g.text)
        }
        let packets = ScenePacketer.packets(cues: sentenceCues)
        // Known-character gender glossary: start from any job-supplied map (e.g. seeded
        // from TMDB credits — actor + character names → gender), then let the curated
        // series bible WIN on conflict. Injected into every prompt as KNOWN CHARACTER
        // GENDERS so speaker/addressee inflection is deterministic, not guessed.
        var glossary = characters
        glossary.merge(BibleCache.load(videoPath: videoPath)) { _, bible in bible }

        // [sentence ordinal: Hebrew] → split each sentence across its source cues.
        func applyAndWrite(_ bySentence: [Int: String]) throws -> String {
            let byCue = SentenceRegrouper.redistribute(
                groups: sentences, translationBySentence: bySentence)
            for i in cues.indices where byCue[cues[i].index] != nil {
                cues[i].text = byCue[cues[i].index]!
            }
            return try SrtAssembler().writeSidecar(cues: cues, lang: targetLang, videoPath: videoPath)
        }

        let path: String
        var qaFlags: [String] = []
        switch strategy {
        case .quality, .fast:
            let dir = strategy == .fast ? modelPaths.llmFast : modelPaths.llm
            onProgress(0.55, "translate")
            let chat = try await warmChat(in: dir)
            let out = try await ScenePacketTranslator(chat: chat, format: .lean, sourceLang: sourceLang, nameGlossary: nameGlossary).translate(
                packets: packets, targetLang: targetLang, knownCharacters: glossary,
                onProgress: { frac in onProgress(0.55 + 0.40 * frac, "translate") })
            qaFlags = out.stats.qaFlags
            onProgress(0.97, "assemble")
            path = try applyAndWrite(out.translationsByCueIndex)

        case .progressive:
            // Pass 1 — fast 7B draft, written and announced as soon as it's ready.
            onProgress(0.45, "translate")
            let fast = try await fastChat()
            let pass1 = try await ScenePacketTranslator(chat: fast, format: .lean, sourceLang: sourceLang, nameGlossary: nameGlossary).translate(
                packets: packets, targetLang: targetLang, knownCharacters: glossary,
                onProgress: { frac in onProgress(0.45 + 0.25 * frac, "translate") })
            qaFlags = pass1.stats.qaFlags
            let draftPath = try applyAndWrite(pass1.translationsByCueIndex)
            onDraftReady(draftPath)
            onProgress(0.70, "refine")

            // Pass 2 — strong 12B re-resolves gender ONLY on flagged lines, scene by
            // scene, then the upgraded sidecar is rewritten in place.
            let strong = try await qualityChat()
            var final = pass1.translationsByCueIndex
            let total = max(packets.count, 1)
            for (i, packet) in packets.enumerated() where !packet.isEmpty {
                let flagged = GenderRefinement.flaggedLocals(packet.lines)
                if !flagged.isEmpty {
                    let pass1He = packet.cueIndices.map { pass1.translationsByCueIndex[$0] ?? "" }
                    let fixes = try await GenderRefinement.correctPacket(
                        sourceLines: packet.lines, pass1Hebrew: pass1He, flaggedLocals: flagged,
                        targetLang: targetLang, knownCharacters: glossary, chat: strong)
                    for (local0, text) in fixes { final[packet.cueIndices[local0]] = text }
                }
                onProgress(0.70 + 0.27 * Double(i + 1) / Double(total), "refine")
            }
            onProgress(0.97, "assemble")
            path = try applyAndWrite(final)
        }

        onProgress(1.0, "done")
        return SubtitleJobResult(
            sidecarPath: path,
            cueCount: cues.count,
            source: source,
            cpsStats: SrtAssembler.cpsStats(cues),
            bibleVersionUsed: titleContext?.bible?.version,
            qaFlags: sourceQaFlags + qaFlags
        )
    }

    /// LLM-translate a set of proper names into `targetLang` (the default the user
    /// edits in the per-character name editor). Best-effort; returns SOURCE→TARGET for
    /// the names that parsed. Uses the warm quality model (serialized with jobs).
    public func translateNames(
        _ names: [String], targetLang: String, sourceLang: String? = nil
    ) async throws -> [String: String] {
        let clean = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else { return [:] }
        let chat = try await qualityChat()
        let dir = ScenePacketTranslator.direction(source: sourceLang, target: targetLang)
        let numbered = clean.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Translate each numbered proper name (a character or person name) \(dir). Render \
        each the natural, conventional way that name appears in \(LanguageName.of(targetLang)) \
        (transliterate when there is no established translation). Output exactly one line \
        per name as "<number>. <translated name>", same order. No notes.
        --- NAMES ---
        \(numbered)
        --- TRANSLATIONS ---
        """
        let raw = try await chat.complete(
            system: nil, user: prompt,
            maxTokens: max(120, clean.count * 24 + 60), temperature: 0.2)
        let parsed = DictaLMTranslator.parseNumbered(raw, expected: clean.count)
        var out: [String: String] = [:]
        for (i, name) in clean.enumerated() where i < parsed.count && !parsed[i].isEmpty {
            out[name] = parsed[i]
        }
        return out
    }

    /// Stop all warm llama-servers (idempotent). Call on daemon shutdown.
    public func shutdown() async {
        for server in servers.values { await server.stop() }
        servers = [:]
        chats = [:]
    }

    // MARK: - Sidecar helpers

    /// Extract the original language from a fetched-source sidecar named
    /// `<base>.<lang>.src.srt` (e.g. "Movie.en.src.srt" → "en"). Returns nil for any
    /// other shape so the translator just infers the language.
    static func languageFromSourceSidecar(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path).deletingPathExtension() // drop .srt
        guard url.pathExtension.lowercased() == "src" else { return nil }
        url = url.deletingPathExtension()                            // drop .src
        let lang = url.pathExtension.lowercased()                    // the language token
        let isAlpha = !lang.isEmpty && lang.count <= 3
            && lang.allSatisfy { $0.isLetter }
        return isAlpha ? lang : nil
    }

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
