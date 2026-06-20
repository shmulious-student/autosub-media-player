// AutoSubEngine — executable entry for the Mac sidecar daemon (SPEC §3).
//
// Resolves model storage (fails loudly if the external drive is unmounted),
// wires up the queue + orchestrator + store, and starts the loopback daemon.
//
// v0 status: starts a STUB daemon (no socket bound yet). It still performs the
// real $AUTOSUB_MODELS check so an unmounted drive surfaces immediately.

import Foundation
import Engine

func runEngine() async {
    // 1. Resolve model storage — hard-fail if the external drive is missing.
    let modelPaths: ModelPaths
    do {
        modelPaths = try ModelPaths.resolve()
        FileHandle.standardError.write(
            Data("[AutoSubEngine] models root: \(modelPaths.root.path)\n".utf8)
        )
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(EXIT_FAILURE)
    }

    // 2. Wire core services.
    let queue = JobQueue()
    let orchestrator = PipelineOrchestrator(queue: queue, modelPaths: modelPaths)
    let store: Store = InMemoryStore()
    _ = store // TODO: pass into orchestrator stages once they read/write.

    // 3. Start the loopback daemon (stub).
    let server = DaemonServer(
        config: DaemonConfig(),
        orchestrator: orchestrator,
        queue: queue
    )
    do {
        try await server.start()
    } catch {
        FileHandle.standardError.write(Data("[AutoSubEngine] daemon failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }

    FileHandle.standardError.write(
        Data("[AutoSubEngine] STUB daemon up. (No socket bound yet — see DaemonServer TODO.)\n".utf8)
    )
    // TODO(v0): keep the process alive on the real event loop. For the stub we
    // just return so `swift run` exits cleanly.
}

await runEngine()
