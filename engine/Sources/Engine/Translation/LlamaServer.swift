// LlamaServer — manage a persistent llama.cpp server for local LLM inference.
//
// We load the (multi-GB) model ONCE into a long-lived `llama-server` process and
// translate every line via its OpenAI-compatible /v1/chat/completions endpoint.
// Spawning `llama-cli` per line would reload the whole model each time — fatal for
// throughput. In production the daemon owns this server's lifecycle and keeps it
// warm; the v0 CLI starts/stops it around a batch.
//
// Models are resolved from $AUTOSUB_MODELS (external drive only, docs/MODELS.md).

import Foundation

/// Real server-reported token accounting for one completion. Lets the benchmark
/// measure the ACTUAL bottleneck (output tokens + decode rate) instead of guessing
/// from prompt character counts. `nil` rates mean the transport didn't report them
/// (e.g. a scripted test mock).
public struct LlamaUsage: Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Prompt ingest rate (tokens/sec) — "prefill". Cheap, compute-bound.
    public var prefillTokensPerSecond: Double
    /// Token generation rate (tokens/sec) — "decode". The memory-bandwidth wall.
    public var decodeTokensPerSecond: Double

    public init(promptTokens: Int = 0, completionTokens: Int = 0,
                prefillTokensPerSecond: Double = 0, decodeTokensPerSecond: Double = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }
}

public struct LlamaResult: Sendable {
    public var text: String
    public var usage: LlamaUsage?
    public init(text: String, usage: LlamaUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Minimal chat interface so translators don't depend on transport details.
public protocol LlamaChat: Sendable {
    func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String

    /// Like `complete`, but also surfaces server-reported token counts + rates so
    /// the benchmark can attribute time to prefill vs decode. Has a default
    /// implementation that delegates to `complete` (no usage), so existing mocks
    /// keep working unchanged.
    func completeDetailed(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> LlamaResult
}

public extension LlamaChat {
    func completeDetailed(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> LlamaResult {
        let text = try await complete(system: system, user: user, maxTokens: maxTokens, temperature: temperature)
        return LlamaResult(text: text, usage: nil)
    }
}

public enum LlamaError: Error, CustomStringConvertible {
    case noModelFound(dir: String)
    case serverDidNotStart(lastError: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .noModelFound(let dir): return "No .gguf model found in \(dir) (see docs/MODELS.md)."
        case .serverDidNotStart(let e): return "llama-server did not become healthy: \(e)"
        case .badResponse(let s): return "Unexpected llama-server response: \(s)"
        }
    }
}

/// Owns a `llama-server` subprocess and vends a chat client to it.
public actor LlamaServer {
    private var process: Process?
    private let host = "127.0.0.1"
    private let port: Int
    private let modelURL: URL
    private let gpuLayers: Int
    private let contextSize: Int
    private let config: InferenceConfig

    // Dedicated, uncommon port so we never collide with (and accidentally talk
    // to) some other local dev server on 8080. The engine daemon itself uses 8765.
    ///
    /// `contextSize` defaults to whatever THIS machine can sustain (InferenceConfig),
    /// so a 16 GB Mac doesn't inherit the 24 GB machine's 8k window and swap.
    public init(modelURL: URL, port: Int = 8791, gpuLayers: Int = 999,
                contextSize: Int? = nil, config: InferenceConfig = .current) {
        self.modelURL = modelURL
        self.port = port
        self.gpuLayers = gpuLayers
        self.config = config
        self.contextSize = contextSize ?? config.contextSize
    }

    /// Pick a model file from a directory (first .gguf, sorted for determinism).
    public static func findModel(in dir: URL, fileManager: FileManager = .default) throws -> URL {
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let gguf = files.filter({ $0.pathExtension.lowercased() == "gguf" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { throw LlamaError.noModelFound(dir: dir.path) }
        return gguf
    }

    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    /// Launch the server and wait until /health is ok (model load can take 10-30s).
    public func start(timeoutSeconds: Int = 120) async throws {
        guard let exe = Shell.which("llama-server") else {
            throw ShellError.toolNotFound("llama-server")
        }
        // Free our port first. If a previous daemon didn't shut down cleanly its
        // llama-server orphans and keeps the port bound; a fresh launch would then
        // silently fail to bind and we'd reuse that STALE server (wrong config, e.g.
        // the old slot count) instead of this one. Kill it so our config wins.
        Self.killStaleServer(onPort: port)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        // Flags are DERIVED from the machine profile, not hardcoded — see
        // InferenceConfig. Two of them are load-bearing beyond performance:
        //   -np 1  one slot. Extra slots reserve KV cache we never use (the pipeline
        //          awaits serially); on a memory-tight Mac that reservation alone
        //          tips the system into swap and collapses decode (~3 vs ~20 tok/s).
        //   NO --model-draft, EVER. Draft-model speculative decoding puts a second
        //          model's weights, KV cache and Metal scratchpads in this process
        //          and Metal aborts with kIOGPUCommandBufferCallbackErrorOutOfMemory
        //          on 16 GB Apple Silicon. The assert below makes that unmissable if
        //          anyone ever adds the flag.
        var args = [
            "-m", modelURL.path,
            "--host", host, "--port", String(port),
            "-ngl", String(gpuLayers),     // offload all layers to Metal
            "-c", String(contextSize),
            "-np", "1",
            // -fa on: Flash Attention — faster attention, smaller KV cache. Lossless.
            "-fa", "on",
            "--no-webui",
        ]
        if config.ngramSpeculation {
            // n-gram speculative decoding: NO draft model, no extra weights, output
            // identical to greedy; ~1.2x measured on the numbered-batch format.
            args += ["--spec-type", "ngram-cache", "--spec-draft-n-max", "8"]
        }
        if config.quantizeKVCache {
            args += ["-ctk", "q8_0", "-ctv", "q8_0"]
        }
        assert(!args.contains("--model-draft") && !args.contains("-md"),
               "draft-model speculative decoding is unsupported on Apple Silicon "
                   + "(Metal buffer OOM); use --spec-type ngram-cache instead")
        proc.arguments = args
        // llama-server is VERY chatty. Discard its output — piping without
        // draining fills the 64 KB pipe buffer and DEADLOCKS the server (it
        // blocks on write, then stops answering). TODO(daemon): tee to a log file.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc

        // Poll /health.
        let health = baseURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var lastError = ""
        while Date() < deadline {
            if !proc.isRunning {
                throw LlamaError.serverDidNotStart(lastError: "process exited early")
            }
            do {
                let (data, resp) = try await URLSession.shared.data(from: health)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   String(decoding: data, as: UTF8.self).contains("ok") {
                    return
                }
            } catch {
                lastError = "\(error)"
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
        throw LlamaError.serverDidNotStart(lastError: lastError)
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    /// Best-effort: SIGKILL whatever currently holds `port` (an orphaned
    /// llama-server from an unclean previous shutdown). No-op if the port is free
    /// or `lsof` isn't available.
    static func killStaleServer(onPort port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return }
        lsof.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pids = out.split(whereSeparator: { $0 == "\n" })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.3) // let the OS release the socket
    }

    /// A chat client bound to this server (safe to use after `start`).
    public func client() -> LlamaServerClient { LlamaServerClient(baseURL: baseURL) }
}

/// Stateless chat client for a running llama-server.
public struct LlamaServerClient: LlamaChat {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }

    public func complete(system: String?, user: String,
                         maxTokens: Int = 256, temperature: Double = 0.2) async throws -> String {
        try await completeDetailed(system: system, user: user,
                                   maxTokens: maxTokens, temperature: temperature).text
    }

    /// Every request passes through `GPUGate`, so on a machine that cannot afford
    /// ASR and LLM running at once they interleave at REQUEST granularity rather
    /// than one stage blocking the other for minutes. On a roomier Mac the gate is
    /// a pass-through and this costs nothing but an await.
    public func completeDetailed(system: String?, user: String,
                                 maxTokens: Int = 256, temperature: Double = 0.2) async throws -> LlamaResult {
        try await GPUGate.shared.withExclusiveAccess {
            try await self.post(system: system, user: user,
                                maxTokens: maxTokens, temperature: temperature)
        }
    }

    private func post(system: String?, user: String,
                      maxTokens: Int, temperature: Double) async throws -> LlamaResult {
        var messages: [[String: String]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "stop": ["\nEND", "\n<END>", "<|im_end|>"],
            // Reuse the KV of the shared prompt prefix across calls. Every chunk in a
            // pass repeats the same instruction + character list; without this the
            // server re-processes that prefix on every request.
            "cache_prompt": true,
            // Ask llama-server to attach its prompt/predicted timings to the response
            // so the benchmark reads the REAL decode rate, not a wall-clock estimate.
            "timings_per_token": false,
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard !data.isEmpty else { throw LlamaError.badResponse("empty body (http \(code))") }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LlamaError.badResponse(String(decoding: data, as: UTF8.self).prefix(200).description) }
        return LlamaResult(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            usage: Self.parseUsage(json)
        )
    }

    /// Pull token counts from OpenAI-style `usage` and rates from llama.cpp's
    /// `timings` (present on both the native and OAI-compatible endpoints).
    static func parseUsage(_ json: [String: Any]) -> LlamaUsage {
        var u = LlamaUsage()
        if let usage = json["usage"] as? [String: Any] {
            u.promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
            u.completionTokens = (usage["completion_tokens"] as? Int) ?? 0
        }
        if let t = json["timings"] as? [String: Any] {
            u.prefillTokensPerSecond = (t["prompt_per_second"] as? Double) ?? 0
            u.decodeTokensPerSecond = (t["predicted_per_second"] as? Double) ?? 0
            if u.promptTokens == 0, let n = t["prompt_n"] as? Int { u.promptTokens = n }
            if u.completionTokens == 0, let n = t["predicted_n"] as? Int { u.completionTokens = n }
        }
        return u
    }
}
