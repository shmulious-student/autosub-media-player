// AutoSubEngine — executable entry (SPEC §3).
//
// Subcommands:
//   process <video> [--transcript <json>] [--target <lang>]
//       Run the v0 vertical slice on one file: decode audio → (ASR or fixture
//       transcript) → segment → bible-aware translate → write an RTL .srt sidecar.
//   daemon  (default)
//       Resolve model storage and start the loopback HTTP job server (blocks).
//
// Every path first resolves $AUTOSUB_MODELS so an unmounted external drive
// surfaces immediately (docs/MODELS.md).

import Foundation
import Engine

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func resolveModels() -> ModelPaths {
    do {
        let mp = try ModelPaths.resolve()
        err("[AutoSubEngine] models root: \(mp.root.path)")
        return mp
    } catch {
        err("\(error)")
        exit(EXIT_FAILURE)
    }
}

// MARK: - process

func processCommand(_ args: [String]) async {
    guard let videoPath = args.first(where: { !$0.hasPrefix("--") }) else {
        err("usage: AutoSubEngine process <video> [--transcript <json>] [--target <lang>]")
        exit(EXIT_FAILURE)
    }
    let transcriptPath = optionValue(args, "--transcript")
    let target = optionValue(args, "--target") ?? "he"
    let useDictaLM = (optionValue(args, "--translator") ?? "fixture") == "dictalm"
    let modelPaths = resolveModels()

    // 1. Inspect the container's audio tracks (universal codec support).
    do {
        let tracks = try AudioTrackProbe().probe(videoPath: videoPath)
        err("[process] audio tracks: \(tracks.map { "a:\($0.index) \($0.codec ?? "?") \($0.language ?? "")" }.joined(separator: " | "))")
    } catch {
        err("[process] track probe failed: \(error)")
    }

    // 2. Decode audio straight from the container — no intermediate file.
    let decoded: DecodedAudio
    do {
        decoded = try AudioDecoder().decode(videoPath: videoPath)
        err("[process] decoded \(decoded.samples.count) samples @ \(decoded.sampleRate)Hz (\(decoded.durationMs) ms) — in-memory, no transcode")
    } catch {
        err("[process] decode failed: \(error)")
        exit(EXIT_FAILURE)
    }

    // 3. Optionally load the real DictaLM model into a persistent llama-server.
    var server: LlamaServer?
    var chatClient: LlamaChat?
    if useDictaLM {
        do {
            let model = try LlamaServer.findModel(in: modelPaths.llm)
            err("[process] loading \(model.lastPathComponent) into llama-server …")
            let s = LlamaServer(modelURL: model)
            try await s.start()
            chatClient = await s.client()
            server = s
            err("[process] llama-server ready")
        } catch {
            err("[process] llama-server start failed: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    // 4. Build cues + translate (through the real BibleAwareTranslator interface).
    do {
        if let transcriptPath {
            let fx = try FixtureTranscript.load(path: transcriptPath)
            var cues = fx.sourceCues()
            let translator: any BibleAwareTranslator = useDictaLM
                ? DictaLMTranslator(modelPaths: modelPaths, chat: chatClient)
                : FixtureTranslator(transcript: fx, modelPaths: modelPaths)
            for (i, line) in fx.lines.enumerated() {
                let ctx = fx.lineContext(for: line)
                if line.addresseeId != nil {
                    err("\n[prompt — gendered line]\n\(translator.buildPrompt(line: ctx, targetLang: target))\n")
                }
                cues[i].text = try await translator.translate(line: ctx, targetLang: target)
                err("[translate] \(line.text)  →  \(cues[i].text)")
            }
            // 5. Assemble + write the RTL .srt sidecar (fixture path).
            let assembler = SrtAssembler()
            let path = try assembler.writeSidecar(cues: cues, lang: target, videoPath: videoPath)
            let stats = SrtAssembler.cpsStats(cues)
            err("[process] wrote \(cues.count) cues → \(path)")
            err("[process] CPS  mean=\(String(format: "%.1f", stats["mean"] ?? 0)) max=\(String(format: "%.1f", stats["max"] ?? 0))")
            err("\n----- \(URL(fileURLWithPath: path).lastPathComponent) -----")
            print(assembler.render(cues: cues, lang: target))
            await server?.stop()
        } else {
            // Production path: drive the SAME SubtitlePipeline the daemon uses.
            await server?.stop() // the pipeline owns its own warm llama-server
            let strategy = TranslationStrategy(wire: optionValue(args, "--strategy"))
            err("[process] strategy: \(strategy.rawValue)")
            let pipeline = SubtitlePipeline(modelPaths: modelPaths)
            let result = try await pipeline.run(
                videoPath: videoPath, targetLang: target, strategy: strategy,
                onProgress: { p, stage in err("[process] \(stage) \(String(format: "%.0f%%", p * 100))") },
                onDraftReady: { draft in err("[process] DRAFT READY (watchable) → \(draft)") }
            )
            await pipeline.shutdown()
            err("[process] wrote \(result.cueCount) cues → \(result.sidecarPath)")
            if let text = try? String(contentsOfFile: result.sidecarPath, encoding: .utf8) {
                err("\n----- \(URL(fileURLWithPath: result.sidecarPath).lastPathComponent) -----")
                print(text)
            }
        }
    } catch {
        err("[process] failed: \(error)")
        await server?.stop()
        exit(EXIT_FAILURE)
    }
}

func optionValue(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - benchmark

func benchmarkCommand(_ args: [String]) async {
    let srtPath = optionValue(args, "--srt")
    let videoPath = args.first(where: { !$0.hasPrefix("--") })
    guard srtPath != nil || videoPath != nil else {
        err("""
        usage: AutoSubEngine benchmark (<video> | --srt <file.srt>) \
        [--target he] [--duration 300] [--scene-lines 24] [--scene-chars 2400] \
        [--approaches legacy,fused-json,lean]
        """)
        exit(EXIT_FAILURE)
    }
    let target = optionValue(args, "--target") ?? "he"
    let duration = optionValue(args, "--duration").flatMap(Int.init) ?? 300
    let sceneLines = optionValue(args, "--scene-lines").flatMap(Int.init) ?? 24
    let sceneChars = optionValue(args, "--scene-chars").flatMap(Int.init) ?? 2_400
    let approaches = optionValue(args, "--approaches")?
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    let modelURL = optionValue(args, "--model").map { URL(fileURLWithPath: $0) }
    let modelPaths = resolveModels()

    do {
        let report: TranslationBenchmarkReport
        if let srtPath {
            report = try await TranslationBenchmark.runFromSRT(
                srtPath: srtPath, targetLang: target, modelPaths: modelPaths,
                sceneMaxLines: sceneLines, sceneMaxSourceChars: sceneChars,
                approaches: approaches, modelURL: modelURL)
        } else {
            report = try await TranslationBenchmark.run(
                videoPath: videoPath!, targetLang: target, durationSeconds: duration,
                modelPaths: modelPaths, sceneMaxLines: sceneLines,
                sceneMaxSourceChars: sceneChars, approaches: approaches, modelURL: modelURL)
        }
        let data = try JSONEncoder.prettySorted.encode(report)
        print(String(decoding: data, as: UTF8.self))
        err("[benchmark] decode wall: \(String(format: "%.1f", report.decodeProbeTokensPerSecond)) tok/s")
        for a in report.approaches.sorted(by: { $0.projectedSecondsFor30Min < $1.projectedSecondsFor30Min }) {
            let mark = a.meets7MinTarget ? "✓" : "✗"
            err(String(format: "[benchmark] %-11@ 30-min≈%5.1fmin %@  out=%d tok  cover=%.0f%%",
                       a.name as NSString, a.projectedSecondsFor30Min / 60, mark as NSString,
                       a.completionTokens, a.coverage * 100))
        }
        for (name, sp) in report.speedupVsLegacy.sorted(by: { $0.value > $1.value }) {
            err("[benchmark] \(name): \(String(format: "%.2fx", sp)) vs legacy")
        }
    } catch {
        err("[benchmark] failed: \(error)")
        exit(EXIT_FAILURE)
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - gender-gate

func genderGateCommand(_ args: [String]) async {
    let target = optionValue(args, "--target") ?? "he"
    let approaches = optionValue(args, "--approaches")?
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    let modelURL = optionValue(args, "--model").map { URL(fileURLWithPath: $0) }
    let modelPaths = resolveModels()
    do {
        let results = try await TranslationBenchmark.runGenderGate(
            modelPaths: modelPaths, targetLang: target, approaches: approaches, modelURL: modelURL)
        let data = try JSONEncoder.prettySorted.encode(results)
        print(String(decoding: data, as: UTF8.self))
        for r in results {
            err(String(format: "[gender-gate] %-11@ %d/%d correct (%.0f%%)",
                       r.approach as NSString, r.correct, r.total, r.accuracy * 100))
            for f in r.failures { err("    ✗ \(f)") }
        }
    } catch {
        err("[gender-gate] failed: \(error)")
        exit(EXIT_FAILURE)
    }
}

// MARK: - tiered (12B attribution + fast translation model)

func tieredCommand(_ args: [String]) async {
    guard let srtPath = optionValue(args, "--srt"),
          let transModel = optionValue(args, "--translate-model") else {
        err("usage: AutoSubEngine tiered --srt <file.srt> --translate-model <gguf> [--model <attr-gguf>] [--target he]")
        exit(EXIT_FAILURE)
    }
    let target = optionValue(args, "--target") ?? "he"
    let attrModel = optionValue(args, "--model").map { URL(fileURLWithPath: $0) }
    let transURL = URL(fileURLWithPath: transModel)
    let modelPaths = resolveModels()
    do {
        err("[tiered] gender gate …")
        let gate = try await TranslationBenchmark.runTieredGenderGate(
            modelPaths: modelPaths, targetLang: target,
            attributionModelURL: attrModel, translationModelURL: transURL)
        err(String(format: "[tiered] gender-gate %d/%d correct (%.0f%%)",
                   gate.correct, gate.total, gate.accuracy * 100))
        for f in gate.failures { err("    ✗ \(f)") }

        err("[tiered] full benchmark …")
        let report = try await TranslationBenchmark.runTieredFromSRT(
            srtPath: srtPath, targetLang: target, modelPaths: modelPaths,
            attributionModelURL: attrModel, translationModelURL: transURL)
        print(String(decoding: try JSONEncoder.prettySorted.encode(report), as: UTF8.self))
        if let a = report.approaches.first {
            let mark = a.meets7MinTarget ? "✓" : "✗"
            err(String(format: "[tiered] 30-min≈%.1fmin %@ (attr %@min + trans %@min) cover=%.0f%%",
                       a.projectedSecondsFor30Min / 60, mark,
                       a.notes["attr_proj30_min"] ?? "?", a.notes["trans_proj30_min"] ?? "?",
                       a.coverage * 100))
        }
    } catch {
        err("[tiered] failed: \(error)")
        exit(EXIT_FAILURE)
    }
}

// MARK: - refine (two-pass: fast translate → flag → strong gender fix)

func refineCommand(_ args: [String]) async {
    guard let srtPath = optionValue(args, "--srt"),
          let fastModel = optionValue(args, "--fast-model") else {
        err("usage: AutoSubEngine refine --srt <file.srt> --fast-model <7B.gguf> [--model <strong-gguf>] [--target he]")
        exit(EXIT_FAILURE)
    }
    let target = optionValue(args, "--target") ?? "he"
    let strongModel = optionValue(args, "--model").map { URL(fileURLWithPath: $0) }
    let fastURL = URL(fileURLWithPath: fastModel)
    let dumpPath = optionValue(args, "--dump")
    let skipGate = args.contains("--no-gate")
    let modelPaths = resolveModels()
    do {
        if !skipGate {
        err("[refine] gender gate …")
        let gate = try await TranslationBenchmark.runRefineGenderGate(
            modelPaths: modelPaths, targetLang: target,
            strongModelURL: strongModel, fastModelURL: fastURL)
        err(String(format: "[refine] gender-gate %d/%d correct (%.0f%%)",
                   gate.correct, gate.total, gate.accuracy * 100))
        for f in gate.failures { err("    ✗ \(f)") }
        }

        err("[refine] full benchmark …")
        let report = try await TranslationBenchmark.runRefineFromSRT(
            srtPath: srtPath, targetLang: target, modelPaths: modelPaths,
            strongModelURL: strongModel, fastModelURL: fastURL, dumpPath: dumpPath)
        print(String(decoding: try JSONEncoder.prettySorted.encode(report), as: UTF8.self))
        if let a = report.approaches.first {
            let mark = a.meets7MinTarget ? "✓" : "✗"
            err(String(format: "[refine] 30-min≈%.1fmin %@  (pass1 %@min + pass2 %@min)  flagged=%@%% corrected=%@ cover=%.0f%%",
                       a.projectedSecondsFor30Min / 60, mark,
                       a.notes["pass1_proj30_min"] ?? "?", a.notes["pass2_proj30_min"] ?? "?",
                       a.notes["flagged_pct"] ?? "?", a.notes["corrected_lines"] ?? "?",
                       a.coverage * 100))
        }
    } catch {
        err("[refine] failed: \(error)")
        exit(EXIT_FAILURE)
    }
}

// MARK: - daemon

func daemonCommand(_ args: [String] = []) {
    let isCloud = args.contains("--cloud") || (ProcessInfo.processInfo.environment["AUTOSUB_BACKEND_ENV"] ?? "").lowercased() == "cloud"
    var cloudConfig = CloudConfig.fromEnvironment()
    if isCloud {
        cloudConfig.environment = .cloud
    }

    let modelPaths: ModelPaths
    if cloudConfig.environment == .cloud {
        modelPaths = ModelPaths.resolveOptional() ?? ModelPaths.cloudPlaceholder()
        err("[AutoSubEngine] backend: CLOUD (Groq + Gemini + Cloudflare) — no external drive required")
    } else {
        modelPaths = resolveModels()
        err("[AutoSubEngine] backend: LOCAL (On-Device Apple Silicon)")
    }

    // Default 8770 (8765 commonly collides with Unity's Mono-HTTPAPI on dev
    // machines); $AUTOSUB_DAEMON_PORT overrides it. Host stays loopback-only.
    let port = ProcessInfo.processInfo.environment["AUTOSUB_DAEMON_PORT"].flatMap(Int.init) ?? 8770
    let pipeline = SubtitlePipeline(modelPaths: modelPaths, cloudConfig: cloudConfig)
    // SQLite source of truth (internal disk). If it can't open, run without
    // persistence rather than refusing to start — a non-persisted queue still works.
    let sqlite: SqliteStore?
    do {
        sqlite = try SqliteStore.open()
        err("[AutoSubEngine] store: \((try? AppDatabase.appSupportURL())?.path ?? "?")")
    } catch {
        err("[AutoSubEngine] WARNING: SQLite store unavailable (\(error)) — running without persistence")
        sqlite = nil
    }
    let server = DaemonServer(config: DaemonConfig(port: port), pipeline: pipeline, sqlite: sqlite)
    do {
        try server.start()
    } catch {
        err("[AutoSubEngine] daemon failed: \(error)")
        exit(EXIT_FAILURE)
    }
    err("[AutoSubEngine] daemon up on 127.0.0.1:\(port) [\(cloudConfig.environment.rawValue)] — POST /jobs to enqueue.")
    // Keep the process alive forever (Swifter serves on its own GCD queue and the
    // worker runs on a detached Task).
    dispatchMain()
}

// MARK: - dispatch

let argv = Array(CommandLine.arguments.dropFirst())
let firstArg = argv.first ?? ""
switch firstArg {
case "process":
    await processCommand(Array(argv.dropFirst()))
case "benchmark":
    await benchmarkCommand(Array(argv.dropFirst()))
case "gender-gate":
    await genderGateCommand(Array(argv.dropFirst()))
case "tiered":
    await tieredCommand(Array(argv.dropFirst()))
case "refine":
    await refineCommand(Array(argv.dropFirst()))
case "daemon":
    daemonCommand(Array(argv.dropFirst()))
default:
    daemonCommand(argv)
}
