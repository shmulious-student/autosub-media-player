// AutoSubEngine — executable entry (SPEC §3).
//
// Subcommands:
//   process <video> [--transcript <json>] [--target <lang>]
//       Run the v0 vertical slice on one file: decode audio → (ASR or fixture
//       transcript) → segment → bible-aware translate → write an RTL .srt sidecar.
//   daemon  (default)
//       Resolve model storage and start the loopback sidecar daemon (stub).
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
    var cues: [SubtitleCue]
    do {
        if let transcriptPath {
            let fx = try FixtureTranscript.load(path: transcriptPath)
            cues = fx.sourceCues()
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
        } else {
            // Production path: real WhisperKit ASR over the decoded samples.
            let asr = try await WhisperKitASR(modelPaths: modelPaths)
                .transcribe(samples: decoded.samples, sampleRate: decoded.sampleRate,
                            sourceLanguageHint: nil)
            err("[process] ASR: \(asr.segments.count) segments, lang=\(asr.language)")
            cues = Segmenter().segment(asr)

            // No character bible on the prod path → infer per-line speaker/
            // addressee gender from dialogue context so translation is gendered.
            var attributions: [Int: LineAttribution] = [:]
            if let chatClient {
                attributions = (try? await SpeakerAttributor(chat: chatClient)
                    .attribute(cues: cues)) ?? [:]
                err("[process] speaker attribution: \(attributions.count)/\(cues.count) lines")
            }

            let translator = DictaLMTranslator(modelPaths: modelPaths, chat: chatClient)
            for i in cues.indices {
                let attr = attributions[cues[i].index]
                let speaker = attr.flatMap { $0.speakerGender == .unknown ? nil
                    : Engine.Character(id: "spk", canonicalName: "Speaker", gender: $0.speakerGender) }
                let addressee = attr.flatMap { $0.addresseeGender == .unknown ? nil
                    : Engine.Character(id: "adr", canonicalName: "Addressee", gender: $0.addresseeGender) }
                let ctx = LineContext(sourceText: cues[i].text, speaker: speaker, addressee: addressee)
                cues[i].text = try await translator.translate(line: ctx, targetLang: target)
            }
        }
    } catch {
        err("[process] translate failed: \(error)")
        await server?.stop()
        exit(EXIT_FAILURE)
    }
    await server?.stop()

    // 4. Assemble + write the RTL .srt sidecar.
    do {
        let assembler = SrtAssembler()
        let path = try assembler.writeSidecar(cues: cues, lang: target, videoPath: videoPath)
        let stats = SrtAssembler.cpsStats(cues)
        err("[process] wrote \(cues.count) cues → \(path)")
        err("[process] CPS  mean=\(String(format: "%.1f", stats["mean"] ?? 0)) max=\(String(format: "%.1f", stats["max"] ?? 0))")
        err("\n----- \(URL(fileURLWithPath: path).lastPathComponent) -----")
        print(assembler.render(cues: cues, lang: target))
    } catch {
        err("[process] assemble failed: \(error)")
        exit(EXIT_FAILURE)
    }
}

func optionValue(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - daemon (stub)

func daemonCommand() async {
    let modelPaths = resolveModels()
    let queue = JobQueue()
    let orchestrator = PipelineOrchestrator(queue: queue, modelPaths: modelPaths)
    _ = InMemoryStore()
    let server = DaemonServer(config: DaemonConfig(), orchestrator: orchestrator, queue: queue)
    do {
        try await server.start()
    } catch {
        err("[AutoSubEngine] daemon failed: \(error)")
        exit(EXIT_FAILURE)
    }
    err("[AutoSubEngine] STUB daemon up. (No socket bound yet — see DaemonServer TODO.)")
}

// MARK: - dispatch

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "process":
    await processCommand(Array(argv.dropFirst()))
default:
    await daemonCommand()
}
