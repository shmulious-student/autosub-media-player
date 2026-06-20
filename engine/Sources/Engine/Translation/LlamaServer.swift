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

/// Minimal chat interface so translators don't depend on transport details.
public protocol LlamaChat: Sendable {
    func complete(system: String?, user: String, maxTokens: Int, temperature: Double) async throws -> String
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

    // Dedicated, uncommon port so we never collide with (and accidentally talk
    // to) some other local dev server on 8080. The engine daemon itself uses 8765.
    public init(modelURL: URL, port: Int = 8791, gpuLayers: Int = 999, contextSize: Int = 4096) {
        self.modelURL = modelURL
        self.port = port
        self.gpuLayers = gpuLayers
        self.contextSize = contextSize
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
        proc.arguments = [
            "-m", modelURL.path,
            "--host", host, "--port", String(port),
            "-ngl", String(gpuLayers),     // offload all layers to Metal
            "-c", String(contextSize),
            // ONE slot. The pipeline sends chunks serially (one await at a time), so
            // extra slots are never used — but `-np` auto reserves ~4 slots' worth of
            // KV cache, which on a 24 GB Mac running the 12B alongside the app tips the
            // system into SWAP and collapses decode (~3 tok/s vs ~20). One slot keeps
            // the footprint lean; concurrency wouldn't help anyway (measured 1.13x).
            "-np", "1",
            // Throughput knobs — measured on M4 Pro / DictaLM-12B Q4_K_M. The 12B
            // decode is memory-bandwidth-bound (~19 tok/s single-stream, ~134 GB/s
            // of a ~273 GB/s bus), so request-level parallelism barely helps (1.13x).
            // What DOES help, losslessly:
            //   -fa on            force Flash Attention (faster attn, less KV memory).
            //   --spec-type ngram-cache  n-gram speculative decoding — NO draft model,
            //                     output is identical to greedy; ~1.2x measured on the
            //                     numbered-batch translation format.
            //   -ctk/-ctv q8_0    quantize the KV cache — frees memory for context with
            //                     negligible quality impact.
            "-fa", "on",
            "--spec-type", "ngram-cache",
            "--spec-draft-n-max", "8",
            "-ctk", "q8_0", "-ctv", "q8_0",
            "--no-webui",
        ]
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
        var messages: [[String: String]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            // Reuse the KV of the shared prompt prefix across calls. Every chunk in a
            // pass repeats the same instruction + character list; without this the
            // server re-processes that prefix on every request.
            "cache_prompt": true,
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
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
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
