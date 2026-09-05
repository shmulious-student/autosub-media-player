// MachineProfile / InferenceConfig — pick the best inference configuration THIS
// Mac can actually sustain, instead of hardcoding one machine's tuning.
//
// The engine's llama-server flags were tuned on a 24 GB M4 Pro. The benchmark
// corpus we inherited was measured on a 16 GB M1. Both are right for their own
// hardware and wrong for the other: an 8192-token context with two warm models is
// comfortable at 24 GB and swaps the machine to death at 16 GB, while capping a
// 64 GB Mac at the 16 GB settings throws away most of its capability.
//
// So the configuration is DERIVED from the machine. `MachineProfile` measures it;
// `InferenceConfig.forMachine` maps it to a policy. Both are plain values with
// injectable inputs, so every tier is unit-testable without owning that Mac.
//
// Two findings are encoded as HARD RULES rather than tuning knobs:
//
//  1. DRAFT-MODEL SPECULATIVE DECODING IS NEVER ENABLED. Loading a target model
//     plus a draft model puts two sets of weights, two KV caches and two Metal
//     graph scratchpads in one process; on 16 GB Apple Silicon macOS refuses the
//     allocation and Metal aborts the command buffer with
//     `kIOGPUCommandBufferCallbackErrorOutOfMemory`. It cost the sister project a
//     full bake-off to establish. `--spec-type ngram-cache` is a DIFFERENT thing —
//     no second model, no extra weights, output identical to greedy — and stays on.
//
//  2. ASR AND LLM ARE SERIALIZED ON CONSTRAINED MACHINES. WhisperKit runs on the
//     ANE and llama.cpp on the GPU, so they *can* overlap — but they compete for
//     the same unified memory bandwidth, and on a 16 GB machine that overlap is
//     what tips the system into swap. Above the threshold, overlap is allowed.

import Foundation

/// What this Mac actually is. Construct with explicit values in tests.
public struct MachineProfile: Sendable, Equatable {
    /// Total physical RAM. On Apple Silicon this is UNIFIED memory: CPU, GPU and
    /// ANE all draw from it, which is why the LLM budget is a fraction of it.
    public let totalRAMBytes: UInt64
    public let performanceCores: Int
    public let isAppleSilicon: Bool
    /// e.g. "Mac16,10". Recorded for diagnostics; policy never keys off it, so a
    /// Mac released after this code was written still gets a sensible tier.
    public let modelIdentifier: String

    public init(totalRAMBytes: UInt64, performanceCores: Int,
                isAppleSilicon: Bool, modelIdentifier: String = "") {
        self.totalRAMBytes = totalRAMBytes
        self.performanceCores = performanceCores
        self.isAppleSilicon = isAppleSilicon
        self.modelIdentifier = modelIdentifier
    }

    public var totalRAMGB: Double { Double(totalRAMBytes) / 1_073_741_824.0 }

    /// Measure the host.
    public static let current: MachineProfile = {
        MachineProfile(
            totalRAMBytes: ProcessInfo.processInfo.physicalMemory,
            performanceCores: sysctlInt("hw.perflevel0.logicalcpu")
                ?? ProcessInfo.processInfo.activeProcessorCount,
            isAppleSilicon: sysctlString("hw.optional.arm64") != nil
                || (sysctlString("hw.machine") ?? "").hasPrefix("arm64"),
            modelIdentifier: sysctlString("hw.model") ?? ""
        )
    }()

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// The inference policy derived from a machine.
public struct InferenceConfig: Sendable, Equatable {
    /// Named tier, for logs and the Settings "Advanced" readout.
    public enum Tier: String, Sendable, Codable {
        /// < 12 GB — draft quality only, everything trimmed.
        case constrained
        /// 12–20 GB (the 16 GB M1 the benchmarks were run on).
        case balanced
        /// 20–28 GB (the 24 GB M4 Pro this engine was tuned on).
        case comfortable
        /// >= 28 GB — headroom for the largest context and both tiers warm.
        case ample
    }

    public let tier: Tier
    /// llama-server `-c`.
    public let contextSize: Int
    /// Quantize the KV cache (`-ctk/-ctv q8_0`). Frees memory for context at
    /// negligible quality cost; only skipped where memory is plentiful.
    public let quantizeKVCache: Bool
    /// `--spec-type ngram-cache`. NO draft model — see the file header.
    public let ngramSpeculation: Bool
    /// May the quality (large) and fast (small) models be resident AT THE SAME TIME?
    /// False forces one warm server, evicting the other tier on switch.
    public let allowsBothModelTiersWarm: Bool
    /// Ceiling for a single model's resident set, in GB.
    public let llmBudgetGB: Double
    /// Serialize ASR and LLM work through `GPUGate` (see header rule 2).
    public let serializeASRAndLLM: Bool
    /// Most accurate WhisperKit tier this machine should load.
    public let maxWhisperTier: String

    /// Draft-model speculative decoding. Always false — a hard rule, not a knob.
    /// Exposed so the value can be asserted in tests and printed in diagnostics.
    public let allowsDraftModelSpeculation = false

    /// Map a machine to its policy. Thresholds are in GB of unified memory, the
    /// binding constraint on every Apple Silicon Mac we support.
    public static func forMachine(_ m: MachineProfile) -> InferenceConfig {
        let gb = m.totalRAMGB
        // Intel Macs have no unified memory and no usable Metal LLM path; treat them
        // as constrained regardless of RAM so we never promise throughput we can't hit.
        guard m.isAppleSilicon else { return constrainedConfig }

        switch gb {
        case ..<12:
            return constrainedConfig
        case ..<20:
            // The 16 GB M1 tier. ~4 GB is macOS, ~1 GB the app, ~1.5 GB ASR — which
            // leaves roughly 6.5 GB for one model and nothing for a second.
            return InferenceConfig(
                tier: .balanced, contextSize: 4_096, quantizeKVCache: true,
                ngramSpeculation: true, allowsBothModelTiersWarm: false,
                llmBudgetGB: 6.5, serializeASRAndLLM: true,
                maxWhisperTier: "large-v3-turbo")
        case ..<28:
            return InferenceConfig(
                tier: .comfortable, contextSize: 8_192, quantizeKVCache: true,
                ngramSpeculation: true, allowsBothModelTiersWarm: true,
                llmBudgetGB: 9.0, serializeASRAndLLM: false,
                maxWhisperTier: "large-v3-turbo")
        default:
            return InferenceConfig(
                tier: .ample, contextSize: 16_384, quantizeKVCache: false,
                ngramSpeculation: true, allowsBothModelTiersWarm: true,
                llmBudgetGB: 14.0, serializeASRAndLLM: false,
                maxWhisperTier: "large-v3-turbo")
        }
    }

    private static let constrainedConfig = InferenceConfig(
        tier: .constrained, contextSize: 2_048, quantizeKVCache: true,
        ngramSpeculation: false, allowsBothModelTiersWarm: false,
        llmBudgetGB: 4.0, serializeASRAndLLM: true,
        maxWhisperTier: "small")

    /// This machine's policy.
    public static let current: InferenceConfig = forMachine(.current)

    /// One-line diagnostic for logs and the Settings readout.
    public var summary: String {
        "\(tier.rawValue): ctx \(contextSize), KV \(quantizeKVCache ? "q8_0" : "f16"), "
            + "\(allowsBothModelTiersWarm ? "both tiers warm" : "one model warm"), "
            + "budget \(String(format: "%.1f", llmBudgetGB)) GB, "
            + "ASR/LLM \(serializeASRAndLLM ? "serialized" : "overlapped")"
    }

    public init(tier: Tier, contextSize: Int, quantizeKVCache: Bool, ngramSpeculation: Bool,
                allowsBothModelTiersWarm: Bool, llmBudgetGB: Double,
                serializeASRAndLLM: Bool, maxWhisperTier: String) {
        self.tier = tier
        self.contextSize = contextSize
        self.quantizeKVCache = quantizeKVCache
        self.ngramSpeculation = ngramSpeculation
        self.allowsBothModelTiersWarm = allowsBothModelTiersWarm
        self.llmBudgetGB = llmBudgetGB
        self.serializeASRAndLLM = serializeASRAndLLM
        self.maxWhisperTier = maxWhisperTier
    }
}

/// Serializes GPU/ANE-heavy stages so ASR and LLM inference never run at once on a
/// machine that cannot afford the overlap.
///
/// This is a *global* gate rather than a per-pipeline one: the daemon can hold more
/// than one pipeline object, and the constraint belongs to the machine, not to any
/// one of them. On a roomy Mac (`serializeASRAndLLM == false`) the gate is a
/// pass-through, so the fast path pays nothing but an await.
public actor GPUGate {
    public static let shared = GPUGate(enabled: InferenceConfig.current.serializeASRAndLLM)

    private let enabled: Bool
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(enabled: Bool) { self.enabled = enabled }

    /// Run `body` with exclusive access to the accelerators (or immediately, when
    /// this machine allows overlap). Access is released even if `body` throws.
    public func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        guard enabled else { return try await body() }
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        while busy {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
        busy = true
    }

    private func release() {
        busy = false
        let resumed = waiters
        waiters.removeAll()
        for c in resumed { c.resume() }
    }
}
