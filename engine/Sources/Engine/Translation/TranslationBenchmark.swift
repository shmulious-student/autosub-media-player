// TranslationBenchmark — head-to-head, instrumented comparison of every translation
// strategy on ONE corpus, with REAL token accounting (SPEC §4: translation is the
// app's core; this is how we prove a change is faster WITHOUT losing gendered quality).
//
// Why real tokens matter: on the 12B Nemotron-H, DECODE (token generation) is the
// memory-bandwidth wall (~22 tok/s); PREFILL (prompt ingest) is ~8x faster (~174
// tok/s). So wall-time ≈ completion_tokens / decode_rate + prompt_tokens / prefill_rate,
// and the decode term dominates. Measuring prompt CHARACTERS (the old proxy) hides
// this; we read llama-server's own `usage` + `timings` instead.
//
// Approaches compared (all on the same sanitized cues, same warm server):
//   legacy      — 3 LLM passes: DialogueAnalyzer (gender map) + SpeakerAttributor
//                 (per-line JSON) + DictaLMTranslator.translateBatch. Emits output 3x.
//   fused-json  — one ScenePacketTranslator pass emitting {i,sg,ag,t} JSON per line.
//   lean        — one ScenePacketTranslator pass emitting only `<n>. <translation>`;
//                 gender/character context pushed into the (cached) prompt. ~half the
//                 output tokens of fused-json for identical scene context.

import Foundation

// MARK: - Real token metrics

public struct LlamaCallMetricsSnapshot: Sendable, Codable {
    public var requests: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var wallSeconds: Double
    /// Pure generation time (Σ completion_tokens / decode_rate) — excludes prefill.
    public var decodeSeconds: Double
    /// Pure prompt-ingest time (Σ prompt_tokens / prefill_rate).
    public var prefillSeconds: Double

    /// Aggregate decode rate actually achieved across the run.
    public var decodeTokensPerSecond: Double {
        decodeSeconds > 0 ? Double(completionTokens) / decodeSeconds : 0
    }
}

public actor LlamaCallMetrics {
    private var requests = 0
    private var promptTokens = 0
    private var completionTokens = 0
    private var wallSeconds = 0.0
    private var decodeSeconds = 0.0
    private var prefillSeconds = 0.0

    public init() {}

    public func record(usage: LlamaUsage?, wallSeconds: Double) {
        requests += 1
        self.wallSeconds += wallSeconds
        guard let u = usage else { return }
        promptTokens += u.promptTokens
        completionTokens += u.completionTokens
        if u.decodeTokensPerSecond > 0 { decodeSeconds += Double(u.completionTokens) / u.decodeTokensPerSecond }
        if u.prefillTokensPerSecond > 0 { prefillSeconds += Double(u.promptTokens) / u.prefillTokensPerSecond }
    }

    public func snapshot() -> LlamaCallMetricsSnapshot {
        LlamaCallMetricsSnapshot(
            requests: requests, promptTokens: promptTokens, completionTokens: completionTokens,
            wallSeconds: wallSeconds, decodeSeconds: decodeSeconds, prefillSeconds: prefillSeconds
        )
    }
}

/// Wraps any LlamaChat to record real server-reported usage per call.
public struct InstrumentedLlamaChat: LlamaChat {
    private let base: any LlamaChat
    private let metrics: LlamaCallMetrics

    public init(base: any LlamaChat, metrics: LlamaCallMetrics) {
        self.base = base
        self.metrics = metrics
    }

    public func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String {
        try await completeDetailed(system: system, user: user, maxTokens: maxTokens, temperature: temperature).text
    }

    public func completeDetailed(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> LlamaResult {
        let start = Date()
        let out = try await base.completeDetailed(system: system, user: user, maxTokens: maxTokens, temperature: temperature)
        await metrics.record(usage: out.usage, wallSeconds: Date().timeIntervalSince(start))
        return out
    }
}

// MARK: - Report

public struct TranslationApproachReport: Sendable, Codable {
    public var name: String
    public var seconds: Double
    public var requests: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var decodeTokensPerSecond: Double
    public var translationsProduced: Int
    /// translationsProduced / sanitizedCueCount — 1.0 means every line was translated.
    public var coverage: Double
    public var secondsPerCue: Double
    /// Linear projection of `seconds` to a full 30-minute video (decode + prefill are
    /// both linear in token count, so wall-time is ~linear in cue count).
    public var projectedSecondsFor30Min: Double
    public var meets7MinTarget: Bool
    public var notes: [String: String]
}

public struct TranslationBenchmarkReport: Sendable, Codable {
    public var corpus: String
    public var targetLang: String
    public var windowSeconds: Int
    public var sourceCueCount: Int
    public var sanitizedCueCount: Int
    public var scenePacketCount: Int
    /// Ground-truth pure decode rate measured by a single controlled generation.
    public var decodeProbeTokensPerSecond: Double
    public var approaches: [TranslationApproachReport]
    /// Speedups vs the legacy 3-pass baseline, keyed by approach name.
    public var speedupVsLegacy: [String: Double]
}

// MARK: - Driver

public enum TranslationBenchmark {
    /// Run the full comparison from a video's embedded subtitle track.
    public static func run(
        videoPath: String,
        targetLang: String,
        durationSeconds: Int = 300,
        modelPaths: ModelPaths,
        sceneMaxLines: Int = 24,
        sceneMaxSourceChars: Int = 2_400,
        approaches: [String]? = nil,
        modelURL: URL? = nil
    ) async throws -> TranslationBenchmarkReport {
        let sourceCues = try firstCues(videoPath: videoPath, targetLang: targetLang, durationSeconds: durationSeconds)
        return try await run(
            corpus: videoPath, sourceCues: sourceCues, targetLang: targetLang,
            windowSeconds: durationSeconds, modelPaths: modelPaths,
            sceneMaxLines: sceneMaxLines, sceneMaxSourceChars: sceneMaxSourceChars,
            approaches: approaches, modelURL: modelURL)
    }

    /// Run the full comparison from a standalone .srt file (repeatable corpus — no
    /// 30-min video needed). `windowSeconds` is taken from the cue timings.
    public static func runFromSRT(
        srtPath: String,
        targetLang: String,
        modelPaths: ModelPaths,
        sceneMaxLines: Int = 24,
        sceneMaxSourceChars: Int = 2_400,
        approaches: [String]? = nil,
        modelURL: URL? = nil
    ) async throws -> TranslationBenchmarkReport {
        let srt = try String(contentsOfFile: srtPath, encoding: .utf8)
        let cues = SubtitleExtractor.parseSRT(srt)
        let windowSeconds = max(1, (cues.map { $0.endMs }.max() ?? 0) / 1_000)
        return try await run(
            corpus: srtPath, sourceCues: cues, targetLang: targetLang,
            windowSeconds: windowSeconds, modelPaths: modelPaths,
            sceneMaxLines: sceneMaxLines, sceneMaxSourceChars: sceneMaxSourceChars,
            approaches: approaches, modelURL: modelURL)
    }

    /// Core: spin up ONE warm server and run every requested approach on the same cues.
    static func run(
        corpus: String,
        sourceCues: [SubtitleCue],
        targetLang: String,
        windowSeconds: Int,
        modelPaths: ModelPaths,
        sceneMaxLines: Int,
        sceneMaxSourceChars: Int,
        approaches requested: [String]?,
        modelURL: URL? = nil
    ) async throws -> TranslationBenchmarkReport {
        let sanitizedCues = PromptTextSanitizer.sanitizedCues(sourceCues)
        let sources = sanitizedCues.map(\.text)
        let packets = ScenePacketer.packets(
            cues: sanitizedCues, maxLines: sceneMaxLines, maxSourceChars: sceneMaxSourceChars)

        let model = try modelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let server = LlamaServer(modelURL: model, contextSize: 8192)
        try await server.start()
        let baseChat = await server.client()

        let wanted = Set(requested ?? ["legacy", "fused-json", "lean"])
        let scale = 1_800.0 / Double(max(windowSeconds, 1)) // window → 30 min

        do {
            // Ground-truth decode rate (one controlled generation), so the report
            // states the wall the approaches are working against.
            let decodeProbe = try await Self.measureDecodeRate(chat: baseChat)

            var reports: [TranslationApproachReport] = []
            if wanted.contains("legacy") {
                reports.append(try await runLegacy(
                    sources: sources, targetLang: targetLang, modelPaths: modelPaths,
                    baseChat: baseChat, sanitizedCount: sources.count, scale: scale))
            }
            if wanted.contains("fused-json") {
                reports.append(try await runScenePacket(
                    name: "fused-json", format: .json, packets: packets, targetLang: targetLang,
                    baseChat: baseChat, sanitizedCount: sources.count, scale: scale))
            }
            if wanted.contains("lean") {
                reports.append(try await runScenePacket(
                    name: "lean", format: .lean, packets: packets, targetLang: targetLang,
                    baseChat: baseChat, sanitizedCount: sources.count, scale: scale))
            }
            await server.stop()

            let legacySeconds = reports.first(where: { $0.name == "legacy" })?.seconds
            var speedups: [String: Double] = [:]
            if let base = legacySeconds, base > 0 {
                for r in reports where r.name != "legacy" {
                    speedups[r.name] = base / max(r.seconds, 0.001)
                }
            }

            return TranslationBenchmarkReport(
                corpus: corpus, targetLang: targetLang, windowSeconds: windowSeconds,
                sourceCueCount: sourceCues.count, sanitizedCueCount: sanitizedCues.count,
                scenePacketCount: packets.count, decodeProbeTokensPerSecond: decodeProbe,
                approaches: reports, speedupVsLegacy: speedups)
        } catch {
            await server.stop()
            throw error
        }
    }

    // MARK: - Approach runners

    private static func runLegacy(
        sources: [String], targetLang: String, modelPaths: ModelPaths,
        baseChat: any LlamaChat, sanitizedCount: Int, scale: Double
    ) async throws -> TranslationApproachReport {
        let metrics = LlamaCallMetrics()
        let chat = InstrumentedLlamaChat(base: baseChat, metrics: metrics)
        let start = Date()
        let characters = (try? await DialogueAnalyzer(chat: chat).characterGenders(lines: sources)) ?? [:]
        let attributions = (try? await SpeakerAttributor(chat: chat)
            .attribute(lines: sources, characters: characters)) ?? []
        let translations = try await DictaLMTranslator(modelPaths: modelPaths, chat: chat)
            .translateBatch(lines: sources, targetLang: targetLang,
                            attributions: attributions, characters: characters)
        let produced = translations.filter { !$0.isEmpty }.count
        return Self.report(
            name: "legacy", seconds: Date().timeIntervalSince(start), snap: await metrics.snapshot(),
            produced: produced, sanitizedCount: sanitizedCount, scale: scale,
            notes: ["characters": "\(characters.count)", "passes": "3"])
    }

    private static func runScenePacket(
        name: String, format: ScenePacketFormat, packets: [ScenePacket], targetLang: String,
        baseChat: any LlamaChat, sanitizedCount: Int, scale: Double
    ) async throws -> TranslationApproachReport {
        let metrics = LlamaCallMetrics()
        let chat = InstrumentedLlamaChat(base: baseChat, metrics: metrics)
        let start = Date()
        let output = try await ScenePacketTranslator(chat: chat, format: format)
            .translate(packets: packets, targetLang: targetLang)
        let produced = output.translationsByCueIndex.values.filter { !$0.isEmpty }.count
        return Self.report(
            name: name, seconds: Date().timeIntervalSince(start), snap: await metrics.snapshot(),
            produced: produced, sanitizedCount: sanitizedCount, scale: scale,
            notes: ["splits": "\(output.stats.splits)",
                    "numberedFallbacks": "\(output.stats.numberedFallbacks)",
                    "fallbackFailures": "\(output.stats.fallbackFailures)",
                    "passes": "1"])
    }

    // MARK: - Tiered (12B infers gender → fast 7B translates with gender applied)

    /// Tiered run: the strong model does the HARD part (per-line speaker/addressee
    /// gender) and the fast model does the bulk translation with that gender handed
    /// to it as input. Proven rationale: the 7B applies given gender correctly (6/6
    /// probe) but infers identity poorly; the 12B infers well but decodes slowly.
    /// Phases run on SEPARATE servers (sequential here to stay inside 24 GB; the
    /// daemon can keep both warm). Time/tokens are the SUM of both phases.
    public static func runTieredFromSRT(
        srtPath: String,
        targetLang: String,
        modelPaths: ModelPaths,
        attributionModelURL: URL? = nil,   // strong model (default: findModel = 12B)
        translationModelURL: URL,          // fast model (7B)
        approaches: [String]? = nil        // accepted for CLI symmetry; ignored
    ) async throws -> TranslationBenchmarkReport {
        let srt = try String(contentsOfFile: srtPath, encoding: .utf8)
        let cues = SubtitleExtractor.parseSRT(srt)
        let windowSeconds = max(1, (cues.map { $0.endMs }.max() ?? 0) / 1_000)
        let sanitized = PromptTextSanitizer.sanitizedCues(cues)
        let sources = sanitized.map(\.text)
        let scale = 1_800.0 / Double(max(windowSeconds, 1))

        // Phase A — gender inference on the strong model.
        let attrModel = try attributionModelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let attrServer = LlamaServer(modelURL: attrModel, contextSize: 8192)
        try await attrServer.start()
        let attrMetrics = LlamaCallMetrics()
        var characters: [String: String] = [:]
        var attributions: [LineAttribution] = []
        let aStart = Date()
        do {
            let chat = InstrumentedLlamaChat(base: await attrServer.client(), metrics: attrMetrics)
            characters = (try? await DialogueAnalyzer(chat: chat).characterGenders(lines: sources)) ?? [:]
            attributions = (try? await SpeakerAttributor(chat: chat)
                .attribute(lines: sources, characters: characters)) ?? []
        }
        let aSeconds = Date().timeIntervalSince(aStart)
        await attrServer.stop()
        let aSnap = await attrMetrics.snapshot()

        // Phase B — fast translation WITH the gender handed in.
        let transServer = LlamaServer(modelURL: translationModelURL, contextSize: 8192)
        try await transServer.start()
        let transMetrics = LlamaCallMetrics()
        let bStart = Date()
        let translations: [String]
        do {
            let chat = InstrumentedLlamaChat(base: await transServer.client(), metrics: transMetrics)
            translations = try await DictaLMTranslator(modelPaths: modelPaths, chat: chat)
                .translateBatch(lines: sources, targetLang: targetLang,
                                attributions: attributions, characters: characters)
        }
        let bSeconds = Date().timeIntervalSince(bStart)
        await transServer.stop()
        let bSnap = await transMetrics.snapshot()

        let produced = translations.filter { !$0.isEmpty }.count
        let totalSeconds = aSeconds + bSeconds
        let report = TranslationApproachReport(
            name: "tiered-12B-attr+7B-trans", seconds: totalSeconds,
            requests: aSnap.requests + bSnap.requests,
            promptTokens: aSnap.promptTokens + bSnap.promptTokens,
            completionTokens: aSnap.completionTokens + bSnap.completionTokens,
            decodeTokensPerSecond: bSnap.decodeTokensPerSecond,
            translationsProduced: produced,
            coverage: sources.isEmpty ? 0 : Double(produced) / Double(sources.count),
            secondsPerCue: sources.isEmpty ? 0 : totalSeconds / Double(sources.count),
            projectedSecondsFor30Min: totalSeconds * scale,
            meets7MinTarget: totalSeconds * scale <= 7 * 60,
            notes: [
                "characters": "\(characters.count)",
                "attr_seconds": String(format: "%.1f", aSeconds),
                "attr_out_tokens": "\(aSnap.completionTokens)",
                "trans_seconds": String(format: "%.1f", bSeconds),
                "trans_out_tokens": "\(bSnap.completionTokens)",
                "attr_proj30_min": String(format: "%.1f", aSeconds * scale / 60),
                "trans_proj30_min": String(format: "%.1f", bSeconds * scale / 60),
            ])
        return TranslationBenchmarkReport(
            corpus: srtPath, targetLang: targetLang, windowSeconds: windowSeconds,
            sourceCueCount: cues.count, sanitizedCueCount: sanitized.count,
            scenePacketCount: 0, decodeProbeTokensPerSecond: bSnap.decodeTokensPerSecond,
            approaches: [report], speedupVsLegacy: [:])
    }

    // MARK: - Two-pass gender refinement (fast translate → flag → strong fix gender)

    /// Pass 1 (fast model) translates everything; lines that need gender resolution
    /// (1st/2nd-person) are flagged; Pass 2 (strong model) re-resolves ONLY those
    /// against scene context. Separate servers, sequential. Time = both passes.
    public static func runRefineFromSRT(
        srtPath: String,
        targetLang: String,
        modelPaths: ModelPaths,
        strongModelURL: URL? = nil,        // pass 2 (default: findModel = 12B)
        fastModelURL: URL,                 // pass 1 (7B)
        sceneMaxLines: Int = 24,
        sceneMaxSourceChars: Int = 2_400,
        dumpPath: String? = nil            // write the final Hebrew SRT for inspection
    ) async throws -> TranslationBenchmarkReport {
        let srt = try String(contentsOfFile: srtPath, encoding: .utf8)
        let cues = SubtitleExtractor.parseSRT(srt)
        let windowSeconds = max(1, (cues.map { $0.endMs }.max() ?? 0) / 1_000)
        let sanitized = PromptTextSanitizer.sanitizedCues(cues)
        let packets = ScenePacketer.packets(
            cues: sanitized, maxLines: sceneMaxLines, maxSourceChars: sceneMaxSourceChars)
        let scale = 1_800.0 / Double(max(windowSeconds, 1))

        // Pass 1 — fast model, gender-naive lean translation of everything.
        let fastServer = LlamaServer(modelURL: fastModelURL, contextSize: 8192)
        try await fastServer.start()
        let p1Metrics = LlamaCallMetrics()
        var pass1: [Int: String] = [:]
        let p1Start = Date()
        do {
            let chat = InstrumentedLlamaChat(base: await fastServer.client(), metrics: p1Metrics)
            pass1 = try await ScenePacketTranslator(chat: chat, format: .lean)
                .translate(packets: packets, targetLang: targetLang).translationsByCueIndex
        }
        let p1Seconds = Date().timeIntervalSince(p1Start)
        await fastServer.stop()
        let p1Snap = await p1Metrics.snapshot()

        // Pass 2 — strong model corrects gender on flagged lines, scene by scene.
        let strongModel = try strongModelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let strongServer = LlamaServer(modelURL: strongModel, contextSize: 8192)
        try await strongServer.start()
        let p2Metrics = LlamaCallMetrics()
        var stats = GenderRefinement.RefineStats()
        stats.totalLines = sanitized.count
        var final = pass1
        let p2Start = Date()
        do {
            let chat = InstrumentedLlamaChat(base: await strongServer.client(), metrics: p2Metrics)
            for packet in packets where !packet.isEmpty {
                let flagged = GenderRefinement.flaggedLocals(packet.lines)
                stats.flaggedLines += flagged.count
                guard !flagged.isEmpty else { continue }
                let pass1He = packet.cueIndices.map { pass1[$0] ?? "" }
                let corrections = try await GenderRefinement.correctPacket(
                    sourceLines: packet.lines, pass1Hebrew: pass1He, flaggedLocals: flagged,
                    targetLang: targetLang, knownCharacters: [:], chat: chat)
                for (local0, text) in corrections {
                    final[packet.cueIndices[local0]] = text
                    stats.correctedLines += 1
                }
            }
        }
        let p2Seconds = Date().timeIntervalSince(p2Start)
        await strongServer.stop()
        let p2Snap = await p2Metrics.snapshot()

        // Optional: write the final translated SRT (source + Hebrew side by side is
        // emitted via the .srt so a human can eyeball quality on real dialogue).
        if let dumpPath {
            var outCues = sanitized
            for i in outCues.indices { outCues[i].text = final[outCues[i].index] ?? outCues[i].text }
            let body = SrtAssembler().render(cues: outCues, lang: targetLang)
            try? body.write(toFile: dumpPath, atomically: true, encoding: .utf8)
        }

        let produced = final.values.filter { !$0.isEmpty }.count
        let totalSeconds = p1Seconds + p2Seconds
        let report = TranslationApproachReport(
            name: "refine-7B-pass1+12B-genderfix", seconds: totalSeconds,
            requests: p1Snap.requests + p2Snap.requests,
            promptTokens: p1Snap.promptTokens + p2Snap.promptTokens,
            completionTokens: p1Snap.completionTokens + p2Snap.completionTokens,
            decodeTokensPerSecond: p1Snap.decodeTokensPerSecond,
            translationsProduced: produced,
            coverage: sanitized.isEmpty ? 0 : Double(produced) / Double(sanitized.count),
            secondsPerCue: sanitized.isEmpty ? 0 : totalSeconds / Double(sanitized.count),
            projectedSecondsFor30Min: totalSeconds * scale,
            meets7MinTarget: totalSeconds * scale <= 7 * 60,
            notes: [
                "pass1_seconds": String(format: "%.1f", p1Seconds),
                "pass1_proj30_min": String(format: "%.1f", p1Seconds * scale / 60),
                "pass2_seconds": String(format: "%.1f", p2Seconds),
                "pass2_proj30_min": String(format: "%.1f", p2Seconds * scale / 60),
                "flagged_lines": "\(stats.flaggedLines)",
                "corrected_lines": "\(stats.correctedLines)",
                "flagged_pct": String(format: "%.0f", Double(stats.flaggedLines) / Double(max(stats.totalLines, 1)) * 100),
                "pass2_out_tokens": "\(p2Snap.completionTokens)",
            ])
        return TranslationBenchmarkReport(
            corpus: srtPath, targetLang: targetLang, windowSeconds: windowSeconds,
            sourceCueCount: cues.count, sanitizedCueCount: sanitized.count,
            scenePacketCount: packets.count, decodeProbeTokensPerSecond: p1Snap.decodeTokensPerSecond,
            approaches: [report], speedupVsLegacy: [:])
    }

    /// Gender gate for the two-pass refine path (pass 1 fast, pass 2 strong fix).
    public static func runRefineGenderGate(
        modelPaths: ModelPaths,
        targetLang: String = "he",
        strongModelURL: URL? = nil,
        fastModelURL: URL
    ) async throws -> GenderGateResult {
        let cues = TranslationQualityGate.sceneCues()
        let packets = ScenePacketer.packets(cues: cues, maxLines: 40, maxSourceChars: 4_000)

        let fastServer = LlamaServer(modelURL: fastModelURL, contextSize: 8192)
        try await fastServer.start()
        var pass1: [Int: String] = [:]
        do {
            pass1 = try await ScenePacketTranslator(chat: await fastServer.client(), format: .lean)
                .translate(packets: packets, targetLang: targetLang).translationsByCueIndex
        }
        await fastServer.stop()

        let strongModel = try strongModelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let strongServer = LlamaServer(modelURL: strongModel, contextSize: 8192)
        try await strongServer.start()
        var final = pass1
        do {
            let chat = await strongServer.client()
            for packet in packets where !packet.isEmpty {
                let flagged = GenderRefinement.flaggedLocals(packet.lines)
                guard !flagged.isEmpty else { continue }
                let pass1He = packet.cueIndices.map { pass1[$0] ?? "" }
                let corrections = try await GenderRefinement.correctPacket(
                    sourceLines: packet.lines, pass1Hebrew: pass1He, flaggedLocals: flagged,
                    targetLang: targetLang, knownCharacters: [:], chat: chat)
                for (local0, text) in corrections { final[packet.cueIndices[local0]] = text }
            }
        }
        await strongServer.stop()
        return TranslationQualityGate.score(approach: "refine-7B+12B-genderfix",
                                            translationsByCueIndex: final)
    }

    private static func report(
        name: String, seconds: Double, snap: LlamaCallMetricsSnapshot,
        produced: Int, sanitizedCount: Int, scale: Double, notes: [String: String]
    ) -> TranslationApproachReport {
        let projected = seconds * scale
        return TranslationApproachReport(
            name: name, seconds: seconds, requests: snap.requests,
            promptTokens: snap.promptTokens, completionTokens: snap.completionTokens,
            decodeTokensPerSecond: snap.decodeTokensPerSecond,
            translationsProduced: produced,
            coverage: sanitizedCount > 0 ? Double(produced) / Double(sanitizedCount) : 0,
            secondsPerCue: sanitizedCount > 0 ? seconds / Double(sanitizedCount) : 0,
            projectedSecondsFor30Min: projected,
            meets7MinTarget: projected <= 7 * 60,
            notes: notes)
    }

    // MARK: - Quality gate

    /// Run the built-in gender-probe scene through each approach and score Hebrew
    /// gender correctness — proves a faster approach didn't trade away the core
    /// promise. Uses one warm server.
    public static func runGenderGate(
        modelPaths: ModelPaths,
        targetLang: String = "he",
        approaches requested: [String]? = nil,
        modelURL: URL? = nil
    ) async throws -> [GenderGateResult] {
        let cues = TranslationQualityGate.sceneCues()
        let sources = cues.map(\.text)
        let packets = ScenePacketer.packets(cues: cues, maxLines: 40, maxSourceChars: 4_000)

        let model = try modelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let server = LlamaServer(modelURL: model, contextSize: 8192)
        try await server.start()
        let chat = await server.client()
        let wanted = Set(requested ?? ["legacy", "fused-json", "lean"])

        do {
            var results: [GenderGateResult] = []
            if wanted.contains("legacy") {
                let characters = (try? await DialogueAnalyzer(chat: chat).characterGenders(lines: sources)) ?? [:]
                let attributions = (try? await SpeakerAttributor(chat: chat)
                    .attribute(lines: sources, characters: characters)) ?? []
                let translations = try await DictaLMTranslator(modelPaths: modelPaths, chat: chat)
                    .translateBatch(lines: sources, targetLang: targetLang,
                                    attributions: attributions, characters: characters)
                var byCue: [Int: String] = [:]
                for (i, t) in translations.enumerated() { byCue[i + 1] = t }
                results.append(TranslationQualityGate.score(approach: "legacy", translationsByCueIndex: byCue))
            }
            for (name, fmt) in [("fused-json", ScenePacketFormat.json), ("lean", .lean)] where wanted.contains(name) {
                let out = try await ScenePacketTranslator(chat: chat, format: fmt)
                    .translate(packets: packets, targetLang: targetLang)
                results.append(TranslationQualityGate.score(
                    approach: name, translationsByCueIndex: out.translationsByCueIndex))
            }
            await server.stop()
            return results
        } catch {
            await server.stop()
            throw error
        }
    }

    /// Tiered gender gate: attribution on the strong model, translation on the fast
    /// model with that gender handed in. Proves the tiered path keeps gender quality.
    public static func runTieredGenderGate(
        modelPaths: ModelPaths,
        targetLang: String = "he",
        attributionModelURL: URL? = nil,
        translationModelURL: URL
    ) async throws -> GenderGateResult {
        let cues = TranslationQualityGate.sceneCues()
        let sources = cues.map(\.text)

        let attrModel = try attributionModelURL ?? LlamaServer.findModel(in: modelPaths.llm)
        let attrServer = LlamaServer(modelURL: attrModel, contextSize: 8192)
        try await attrServer.start()
        var characters: [String: String] = [:]
        var attributions: [LineAttribution] = []
        do {
            let chat = await attrServer.client()
            characters = (try? await DialogueAnalyzer(chat: chat).characterGenders(lines: sources)) ?? [:]
            attributions = (try? await SpeakerAttributor(chat: chat)
                .attribute(lines: sources, characters: characters)) ?? []
        }
        await attrServer.stop()

        let transServer = LlamaServer(modelURL: translationModelURL, contextSize: 8192)
        try await transServer.start()
        let translations: [String]
        do {
            let chat = await transServer.client()
            translations = try await DictaLMTranslator(modelPaths: modelPaths, chat: chat)
                .translateBatch(lines: sources, targetLang: targetLang,
                                attributions: attributions, characters: characters)
        }
        await transServer.stop()

        var byCue: [Int: String] = [:]
        for (i, t) in translations.enumerated() { byCue[i + 1] = t }
        return TranslationQualityGate.score(approach: "tiered-12B-attr+7B-trans",
                                            translationsByCueIndex: byCue)
    }

    /// One controlled generation to read the machine's pure decode rate.
    static func measureDecodeRate(chat: any LlamaChat) async throws -> Double {
        let r = try await chat.completeDetailed(
            system: nil,
            user: "Write 180 words of natural, flowing Hebrew prose describing a quiet morning by the sea.",
            maxTokens: 240, temperature: 0.2)
        return r.usage?.decodeTokensPerSecond ?? 0
    }

    // MARK: - Cue sourcing

    public static func firstCues(
        videoPath: String,
        targetLang: String,
        durationSeconds: Int
    ) throws -> [SubtitleCue] {
        let extractor = SubtitleExtractor()
        guard let track = try extractor.bestTextTrack(videoPath: videoPath, targetLang: targetLang) else {
            throw ScenePacketTranslationError.invalidPacket("no text subtitle track found")
        }
        return try extractor.extractCues(videoPath: videoPath, trackIndex: track.index)
            .filter { $0.startMs < durationSeconds * 1_000 }
            .map { cue in
                var c = cue
                c.endMs = min(c.endMs, durationSeconds * 1_000)
                return c
            }
    }
}
