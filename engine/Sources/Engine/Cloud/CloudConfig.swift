// CloudConfig — backend environment and cloud provider credentials.
//
// Supports switching between `local` (offline on-device Apple Silicon models) and
// `cloud` (Groq, Google AI Studio Gemini, and Cloudflare Workers AI free tiers).

import Foundation

public enum BackendEnvironment: String, Codable, Sendable {
    case local
    case cloud
}

public struct CloudConfig: Codable, Sendable {
    public var environment: BackendEnvironment
    public var groqApiKey: String?
    public var geminiApiKey: String?
    public var cloudflareAccountId: String?
    public var cloudflareApiToken: String?

    public var groqBaseURL: URL
    public var geminiBaseURL: URL
    public var cloudflareBaseURL: URL

    public init(
        environment: BackendEnvironment = .local,
        groqApiKey: String? = nil,
        geminiApiKey: String? = nil,
        cloudflareAccountId: String? = nil,
        cloudflareApiToken: String? = nil,
        groqBaseURL: URL = URL(string: "https://api.groq.com/openai/v1")!,
        geminiBaseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
        cloudflareBaseURL: URL = URL(string: "https://api.cloudflare.com/client/v4/accounts")!
    ) {
        self.environment = environment
        self.groqApiKey = groqApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.geminiApiKey = geminiApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cloudflareAccountId = cloudflareAccountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cloudflareApiToken = cloudflareApiToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.groqBaseURL = groqBaseURL
        self.geminiBaseURL = geminiBaseURL
        self.cloudflareBaseURL = cloudflareBaseURL
    }

    public var hasGroq: Bool {
        guard let k = groqApiKey else { return false }
        return !k.isEmpty
    }

    public var hasGemini: Bool {
        guard let k = geminiApiKey else { return false }
        return !k.isEmpty
    }

    public var hasCloudflare: Bool {
        guard let a = cloudflareAccountId, let t = cloudflareApiToken else { return false }
        return !a.isEmpty && !t.isEmpty
    }

    public var hasAnyCloudKey: Bool {
        hasGroq || hasGemini || hasCloudflare
    }

    /// Read config from the runtime environment.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> CloudConfig {
        let envVal = (env["AUTOSUB_BACKEND_ENV"] ?? "").lowercased()
        let backend: BackendEnvironment = (envVal == "cloud" || env["AUTOSUB_CLOUD"] == "1") ? .cloud : .local

        let groqKey = env["GROQ_API_KEY"]
        let geminiKey = env["GEMINI_API_KEY"] ?? env["GOOGLE_AI_API_KEY"]
        let cfAccount = env["CLOUDFLARE_ACCOUNT_ID"]
        let cfToken = env["CLOUDFLARE_API_TOKEN"]

        return CloudConfig(
            environment: backend,
            groqApiKey: groqKey,
            geminiApiKey: geminiKey,
            cloudflareAccountId: cfAccount,
            cloudflareApiToken: cfToken
        )
    }

    public func jsonObject() -> [String: Any] {
        [
            "environment": environment.rawValue,
            "hasGroq": hasGroq,
            "hasGemini": hasGemini,
            "hasCloudflare": hasCloudflare,
        ]
    }
}
