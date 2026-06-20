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
    let modelPaths = resolveModels()

    // 1. Inspect the container's audio tracks (universal codec support).
    do {
        let tracks = try AudioTrackProbe().probe(videoPath: videoPath)
        err("[process] audio tracks: \(tracks.map { "a:\($0.index) \($0.codec ?? "?") \($0.language ?? "")" }.joined(separator: " | "))")
    } catch {
        err("[process] track probe failed: \(error)")
    }

    // 2. Decode audio straight from the container — no intermediate file.
    do {
        let audio = try AudioDecoder().decode(videoPath: videoPath)
        err("[process] decoded \(audio.samples.count) samples @ \(audio.sampleRate)Hz (\(audio.durationMs) ms) — in-memory, no transcode")
    } catch {
        err("[process] decode failed: \(error)")
        exit(EXIT_FAILURE)
    }

    // 3. Build cues + translate.
    var cues: [SubtitleCue]
    do {
        if let transcriptPath {
            let fx = try FixtureTranscript.load(path: transcriptPath)
            let translator = FixtureTranslator(transcript: fx, modelPaths: modelPaths)
            cues = fx.sourceCues()
            for (i, line) in fx.lines.enumerated() {
                let ctx = fx.lineContext(for: line)
                if line.addresseeId != nil {
                    err("\n[prompt — gendered line]\n\(translator.buildPrompt(line: ctx, targetLang: target))\n")
                }
                cues[i].text = try await translator.translate(line: ctx, targetLang: target)
            }
        } else {
            // Production path (real ASR + LLM land in tasks #3/#4).
            let asr = try await WhisperKitASR(modelPaths: modelPaths)
                .transcribe(audioPath: videoPath, sourceLanguageHint: nil)
            cues = Segmenter().segment(asr)
            let translator = DictaLMTranslator(modelPaths: modelPaths)
            for i in cues.indices {
                let ctx = LineContext(sourceText: cues[i].text)
                cues[i].text = try await translator.translate(line: ctx, targetLang: target)
            }
        }
    } catch {
        err("[process] translate failed: \(error)")
        exit(EXIT_FAILURE)
    }

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
