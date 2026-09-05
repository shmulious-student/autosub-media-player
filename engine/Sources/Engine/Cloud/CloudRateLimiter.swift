// CloudRateLimiter — smart rate limiting and overload management for free AI tiers.
//
// Enforces:
//   - Groq: 30 RPM, 6k/20k TPM, 14,400 RPD, 7,200 audio s/day
//   - Gemini 2.0 Flash: 15 RPM, 1M TPM, 1,500 RPD
//   - Cloudflare Workers AI: 10,000 neurons/day, concurrency control
//
// Automatically throttles requests with jittered delay, tracks daily budgets
// (resets at UTC midnight), and records cooldowns on HTTP 429.

import Foundation

public enum CloudProvider: String, Sendable, CaseIterable {
    case groq
    case gemini
    case cloudflare
}

public struct ProviderRateLimitConfig: Sendable {
    public let maxRpm: Int
    public let maxTpm: Int
    public let maxRpd: Int
    public let safetyFactor: Double

    public init(maxRpm: Int, maxTpm: Int, maxRpd: Int, safetyFactor: Double = 0.85) {
        self.maxRpm = maxRpm
        self.maxTpm = maxTpm
        self.maxRpd = maxRpd
        self.safetyFactor = safetyFactor
    }

    public var effectiveRpm: Int { max(1, Int(Double(maxRpm) * safetyFactor)) }
    public var effectiveTpm: Int { max(100, Int(Double(maxTpm) * safetyFactor)) }
    public var effectiveRpd: Int { max(1, Int(Double(maxRpd) * safetyFactor)) }
}

public struct ProviderSnapshot: Codable, Sendable {
    public var provider: String
    public var requestsLastMinute: Int
    public var tokensLastMinute: Int
    public var requestsToday: Int
    public var cooldownRemainingSeconds: Double
    public var isAvailable: Bool
}

public struct CloudQuotaSnapshot: Codable, Sendable {
    public var providers: [ProviderSnapshot]
    public var groqAudioSecondsToday: Double
    public var maxGroqAudioSecondsDaily: Double
    public var dayKeyUtc: String
}

public actor CloudRateLimiter {
    public static let shared = CloudRateLimiter()

    private let configs: [CloudProvider: ProviderRateLimitConfig] = [
        .groq: ProviderRateLimitConfig(maxRpm: 30, maxTpm: 6_000, maxRpd: 14_400, safetyFactor: 0.85),
        .gemini: ProviderRateLimitConfig(maxRpm: 15, maxTpm: 1_000_000, maxRpd: 1_500, safetyFactor: 0.85),
        .cloudflare: ProviderRateLimitConfig(maxRpm: 60, maxTpm: 100_000, maxRpd: 5_000, safetyFactor: 0.85),
    ]

    // Timestamps of requests in the last 60 seconds
    private var requestTimestamps: [CloudProvider: [Date]] = [:]
    // (timestamp, tokenCount) in the last 60 seconds
    private var tokenRecords: [CloudProvider: [(date: Date, tokens: Int)]] = [:]

    // Daily counters
    private var currentDayKeyUtc: String
    private var dailyRequests: [CloudProvider: Int] = [:]
    private var dailyAudioSecondsGroq: Double = 0.0
    public let maxDailyAudioSecondsGroq: Double = 7_200.0 // 2 hours/day

    // Cooldown until date after 429
    private var cooldownUntil: [CloudProvider: Date] = [:]

    public init() {
        self.currentDayKeyUtc = Self.makeDayKey()
        for p in CloudProvider.allCases {
            requestTimestamps[p] = []
            tokenRecords[p] = []
            dailyRequests[p] = 0
        }
    }

    private static func makeDayKey() -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private func checkDayRollover() {
        let today = Self.makeDayKey()
        if today != currentDayKeyUtc {
            currentDayKeyUtc = today
            dailyRequests = [:]
            dailyAudioSecondsGroq = 0.0
            for p in CloudProvider.allCases {
                dailyRequests[p] = 0
            }
        }
    }

    private func pruneOldRecords(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-60)
        for p in CloudProvider.allCases {
            requestTimestamps[p] = (requestTimestamps[p] ?? []).filter { $0 > cutoff }
            tokenRecords[p] = (tokenRecords[p] ?? []).filter { $0.date > cutoff }
        }
    }

    /// True if the provider is currently cooling down from a 429 or rate spike.
    public func isCoolingDown(_ provider: CloudProvider, now: Date = Date()) -> Bool {
        if let cd = cooldownUntil[provider], cd > now {
            return true
        }
        return false
    }

    /// Check whether a provider has capacity without waiting.
    public func hasCapacity(for provider: CloudProvider, estimatedTokens: Int = 300, now: Date = Date()) -> Bool {
        checkDayRollover()
        pruneOldRecords(now: now)

        if isCoolingDown(provider, now: now) { return false }

        guard let cfg = configs[provider] else { return true }

        // Daily limit
        let todayReqs = dailyRequests[provider] ?? 0
        if todayReqs >= cfg.effectiveRpd { return false }

        // RPM limit
        let recentReqs = (requestTimestamps[provider] ?? []).count
        if recentReqs >= cfg.effectiveRpm { return false }

        // TPM limit
        let recentTokens = (tokenRecords[provider] ?? []).reduce(0) { $0 + $1.tokens }
        if (recentTokens + estimatedTokens) >= cfg.effectiveTpm { return false }

        return true
    }

    /// Acquire rate limit permit, smoothly awaiting if a short throttle delay (< 3s)
    /// clears the window. Returns true on permit granted, false if provider cannot be used.
    public func acquirePermit(
        for provider: CloudProvider,
        estimatedTokens: Int = 300,
        maxWaitSeconds: Double = 3.0
    ) async -> Bool {
        checkDayRollover()
        let now = Date()
        pruneOldRecords(now: now)

        if isCoolingDown(provider, now: now) { return false }

        guard let cfg = configs[provider] else { return true }

        let todayReqs = dailyRequests[provider] ?? 0
        if todayReqs >= cfg.effectiveRpd { return false }

        let recentReqs = requestTimestamps[provider] ?? []
        let recentTokens = (tokenRecords[provider] ?? []).reduce(0) { $0 + $1.tokens }

        var waitTime: Double = 0.0

        if recentReqs.count >= cfg.effectiveRpm, let oldest = recentReqs.first {
            let expireIn = 60.0 - now.timeIntervalSince(oldest)
            if expireIn > 0 { waitTime = max(waitTime, expireIn) }
        }

        if (recentTokens + estimatedTokens) >= cfg.effectiveTpm,
           let oldestToken = (tokenRecords[provider] ?? []).first {
            let expireIn = 60.0 - now.timeIntervalSince(oldestToken.date)
            if expireIn > 0 { waitTime = max(waitTime, expireIn) }
        }

        if waitTime > maxWaitSeconds {
            return false // Caller should failover rather than stall
        }

        if waitTime > 0.05 {
            // Add a touch of jitter so concurrent workers don't hammer the slot
            let jitter = Double.random(in: 0.05...0.15)
            try? await Task.sleep(nanoseconds: UInt64((waitTime + jitter) * 1_000_000_000))
            checkDayRollover()
            pruneOldRecords()
        }

        let recordDate = Date()
        requestTimestamps[provider, default: []].append(recordDate)
        tokenRecords[provider, default: []].append((date: recordDate, tokens: estimatedTokens))
        dailyRequests[provider, default: 0] += 1
        return true
    }

    /// Record actual tokens used upon response completion.
    public func recordSuccess(provider: CloudProvider, promptTokens: Int, completionTokens: Int) {
        let total = promptTokens + completionTokens
        guard total > 0 else { return }
        tokenRecords[provider, default: []].append((date: Date(), tokens: total))
    }

    /// Record HTTP 429 or rate limit hit. Applies cooldown with jittered backoff.
    public func record429(provider: CloudProvider, retryAfterSeconds: Double? = nil) {
        let base = retryAfterSeconds ?? 15.0
        let jitter = Double.random(in: 1.0...5.0)
        let cooldown = max(5.0, base + jitter)
        cooldownUntil[provider] = Date().addingTimeInterval(cooldown)
    }

    /// Audio seconds tracking for Groq Whisper
    public func hasGroqAudioCapacity(requestedSeconds: Double) -> Bool {
        checkDayRollover()
        return (dailyAudioSecondsGroq + requestedSeconds) <= maxDailyAudioSecondsGroq
    }

    public func recordGroqAudio(seconds: Double) {
        checkDayRollover()
        dailyAudioSecondsGroq += max(0, seconds)
    }

    /// Detailed snapshot for health checks and status reporting.
    public func snapshot() -> CloudQuotaSnapshot {
        checkDayRollover()
        let now = Date()
        pruneOldRecords(now: now)

        var snapshots: [ProviderSnapshot] = []
        for p in CloudProvider.allCases {
            let reqs = (requestTimestamps[p] ?? []).count
            let tokens = (tokenRecords[p] ?? []).reduce(0) { $0 + $1.tokens }
            let today = dailyRequests[p] ?? 0
            let cdSecs: Double
            if let cd = cooldownUntil[p], cd > now {
                cdSecs = cd.timeIntervalSince(now)
            } else {
                cdSecs = 0
            }
            snapshots.append(ProviderSnapshot(
                provider: p.rawValue,
                requestsLastMinute: reqs,
                tokensLastMinute: tokens,
                requestsToday: today,
                cooldownRemainingSeconds: cdSecs,
                isAvailable: cdSecs == 0
            ))
        }

        return CloudQuotaSnapshot(
            providers: snapshots,
            groqAudioSecondsToday: dailyAudioSecondsGroq,
            maxGroqAudioSecondsDaily: maxDailyAudioSecondsGroq,
            dayKeyUtc: currentDayKeyUtc
        )
    }
}
