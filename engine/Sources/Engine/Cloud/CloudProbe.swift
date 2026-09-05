// CloudProbe — "is this key actually going to work?", answered before a job runs.
//
// A wrong or expired key is otherwise discovered the worst possible way: an
// overnight batch that produced nothing. So each provider gets a cheap, read-only
// request (list models) whose answer separates the three cases a user cares about
// — the key is good, the key is rejected, or the network/service is down — and
// reports how long the round trip took, since latency is the whole reason someone
// chose cloud in the first place.
//
// Nothing here consumes generation quota: model listings are not metered against
// the free-tier token budgets, so testing keys is free and can be done as often
// as the user likes.

import Foundation

public struct CloudProbeResult: Codable, Sendable {
    public var provider: String
    public var configured: Bool
    public var ok: Bool
    public var latencyMs: Int?
    public var status: Int?
    public var error: String?

    public static func notConfigured(_ provider: String) -> CloudProbeResult {
        CloudProbeResult(
            provider: provider, configured: false, ok: false,
            latencyMs: nil, status: nil, error: nil
        )
    }
}

public struct CloudProbeReport: Codable, Sendable {
    public var providers: [CloudProbeResult]
    public var quota: CloudQuotaSnapshot
}

public enum CloudProbe {
    /// How long to wait before calling a provider unreachable. Short on purpose:
    /// this runs while someone watches a spinner in Settings.
    public static let timeout: TimeInterval = 8

    public static func verify(
        config: CloudConfig,
        session: URLSession = .shared
    ) async -> [CloudProbeResult] {
        var results: [CloudProbeResult] = []

        if config.hasGroq {
            results.append(await bearerProbe(
                provider: "groq",
                url: config.groqBaseURL.appendingPathComponent("models"),
                token: config.groqApiKey ?? "",
                session: session
            ))
        } else {
            results.append(.notConfigured("groq"))
        }

        if config.hasGemini {
            results.append(await bearerProbe(
                provider: "gemini",
                url: config.geminiBaseURL.appendingPathComponent("models"),
                token: config.geminiApiKey ?? "",
                session: session
            ))
        } else {
            results.append(.notConfigured("gemini"))
        }

        if config.hasCloudflare {
            let url = config.cloudflareBaseURL
                .appendingPathComponent(config.cloudflareAccountId ?? "")
                .appendingPathComponent("ai/models/search")
            results.append(await bearerProbe(
                provider: "cloudflare",
                url: url,
                token: config.cloudflareApiToken ?? "",
                session: session
            ))
        } else {
            results.append(.notConfigured("cloudflare"))
        }

        return results
    }

    private static func bearerProbe(
        provider: String,
        url: URL,
        token: String,
        session: URLSession
    ) async -> CloudProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return CloudProbeResult(
                provider: provider,
                configured: true,
                ok: (200..<300).contains(status),
                latencyMs: ms,
                status: status,
                error: (200..<300).contains(status) ? nil : Self.explain(status)
            )
        } catch {
            return CloudProbeResult(
                provider: provider,
                configured: true,
                ok: false,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                status: nil,
                error: error.localizedDescription
            )
        }
    }

    /// Turn a status code into something a person can act on — the difference
    /// between "retype your key" and "wait until tomorrow" matters.
    private static func explain(_ status: Int) -> String {
        switch status {
        case 401, 403: return "Key rejected — check it was copied in full."
        case 404: return "Endpoint not found — check the account ID."
        case 429: return "Rate limited right now; the key itself looks valid."
        case 500...599: return "Provider is having problems; try again later."
        default: return "Unexpected HTTP \(status)."
        }
    }
}
