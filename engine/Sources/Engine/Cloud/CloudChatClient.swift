// CloudChatClient — LlamaChat implementation multiplexing Groq, Gemini, and Cloudflare.
//
// Automatically manages:
//   - Task routing (Gemini for quality Hebrew translation, Groq 8B for fast synopsis/roles)
//   - Rate limit permits via CloudRateLimiter
//   - Automatic failover if a provider is rate limited, exhausted, or encounters 429
//   - Timing & token accounting (returning LlamaUsage)

import Foundation

public enum CloudModelTier: Sendable {
    case quality
    case fast
}

public enum CloudInferenceError: Error, CustomStringConvertible {
    case noKeysConfigured
    case noAvailableProvider(reasons: [String])
    case badResponse(provider: String, status: Int, message: String)

    public var description: String {
        switch self {
        case .noKeysConfigured:
            return "No cloud API keys configured. Set GROQ_API_KEY or GEMINI_API_KEY in Settings."
        case .noAvailableProvider(let reasons):
            return "All cloud providers unavailable or rate limited: \(reasons.joined(separator: " | "))"
        case .badResponse(let p, let s, let msg):
            return "[\(p)] HTTP \(s): \(msg)"
        }
    }
}

public struct CloudChatClient: LlamaChat, Sendable {
    public let config: CloudConfig
    public let tier: CloudModelTier
    private let rateLimiter: CloudRateLimiter

    public init(
        config: CloudConfig,
        tier: CloudModelTier = .quality,
        rateLimiter: CloudRateLimiter = .shared
    ) {
        self.config = config
        self.tier = tier
        self.rateLimiter = rateLimiter
    }

    public func complete(
        system: String?, user: String, maxTokens: Int = 256, temperature: Double = 0.2
    ) async throws -> String {
        let res = try await completeDetailed(system: system, user: user, maxTokens: maxTokens, temperature: temperature)
        return res.text
    }

    public func completeDetailed(
        system: String?, user: String, maxTokens: Int = 256, temperature: Double = 0.2
    ) async throws -> LlamaResult {
        guard config.hasAnyCloudKey else {
            throw CloudInferenceError.noKeysConfigured
        }

        let candidates = providerCandidates()
        var failureReasons: [String] = []

        for candidate in candidates {
            let provider = candidate.provider
            let model = candidate.model

            let hasPermit = await rateLimiter.acquirePermit(for: provider, estimatedTokens: maxTokens)
            guard hasPermit else {
                failureReasons.append("\(provider.rawValue) [rate-limited/cooling-down]")
                continue
            }

            let startTime = Date()
            do {
                let result: (text: String, promptTokens: Int, completionTokens: Int)
                switch provider {
                case .gemini:
                    result = try await callOpenAICompatible(
                        url: config.geminiBaseURL.appendingPathComponent("chat/completions"),
                        apiKey: config.geminiApiKey ?? "",
                        model: model,
                        system: system,
                        user: user,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                case .groq:
                    result = try await callOpenAICompatible(
                        url: config.groqBaseURL.appendingPathComponent("chat/completions"),
                        apiKey: config.groqApiKey ?? "",
                        model: model,
                        system: system,
                        user: user,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                case .cloudflare:
                    result = try await callCloudflare(
                        model: model,
                        system: system,
                        user: user,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )
                }

                await rateLimiter.recordSuccess(
                    provider: provider,
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens
                )

                let duration = max(0.001, Date().timeIntervalSince(startTime))
                let decodeRate = Double(result.completionTokens) / duration

                let usage = LlamaUsage(
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens,
                    prefillTokensPerSecond: Double(result.promptTokens) / max(0.001, duration * 0.2),
                    decodeTokensPerSecond: decodeRate
                )

                return LlamaResult(text: result.text, usage: usage)
            } catch let err as CloudInferenceError {
                failureReasons.append("\(provider.rawValue): \(err)")
                continue
            } catch {
                failureReasons.append("\(provider.rawValue): \(error.localizedDescription)")
                continue
            }
        }

        throw CloudInferenceError.noAvailableProvider(reasons: failureReasons)
    }

    private struct Candidate {
        let provider: CloudProvider
        let model: String
    }

    /// Provider preference order according to task tier and strengths
    private func providerCandidates() -> [Candidate] {
        var list: [Candidate] = []
        switch tier {
        case .quality:
            // Quality translation: Gemini 3.6 Flash is SOTA for Hebrew gender agreement; Groq 120B / Qwen 27B fast fallback.
            if config.hasGemini {
                list.append(Candidate(provider: .gemini, model: "gemini-3.6-flash"))
            }
            if config.hasGroq {
                list.append(Candidate(provider: .groq, model: "openai/gpt-oss-120b"))
                list.append(Candidate(provider: .groq, model: "qwen/qwen3.8-27b"))
            }
            if config.hasCloudflare {
                list.append(Candidate(provider: .cloudflare, model: "@cf/meta/llama-3.1-8b-instruct"))
            }
        case .fast:
            // Fast operations: Groq 20B is ultra-fast (~500 tok/s), high limits; Qwen 27B / Gemini / CF fallback.
            if config.hasGroq {
                list.append(Candidate(provider: .groq, model: "openai/gpt-oss-20b"))
                list.append(Candidate(provider: .groq, model: "qwen/qwen3.6-27b"))
            }
            if config.hasGemini {
                list.append(Candidate(provider: .gemini, model: "gemini-3.6-flash"))
            }
            if config.hasCloudflare {
                list.append(Candidate(provider: .cloudflare, model: "@cf/meta/llama-3.1-8b-instruct"))
            }
        }
        return list
    }

    // MARK: - OpenAI-Compatible Endpoint (Groq & Gemini)

    private func callOpenAICompatible(
        url: URL,
        apiKey: String,
        model: String,
        system: String?,
        user: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        var messages: [[String: String]] = []
        if let s = system, !s.isEmpty {
            messages.append(["role": "system", "content": s])
        }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "stop": ["\nEND", "\n<END>", "<|im_end|>"]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CloudInferenceError.badResponse(provider: url.host ?? "api", status: -1, message: error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 500

        if code == 429 {
            let retryAfterStr = http?.value(forHTTPHeaderField: "Retry-After")
            let retryAfter = retryAfterStr.flatMap(Double.init)
            let provider: CloudProvider = url.host?.contains("groq") == true ? .groq : .gemini
            await rateLimiter.record429(provider: provider, retryAfterSeconds: retryAfter)
            throw CloudInferenceError.badResponse(provider: provider.rawValue, status: 429, message: "Rate limit reached")
        }

        guard code == 200 else {
            let msg = String(decoding: data.prefix(300), as: UTF8.self)
            throw CloudInferenceError.badResponse(provider: url.host ?? "api", status: code, message: msg)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let messageObj = firstChoice["message"] as? [String: Any],
            let content = messageObj["content"] as? String
        else {
            throw CloudInferenceError.badResponse(provider: url.host ?? "api", status: code, message: "Invalid JSON response shape")
        }

        var pTokens = 0
        var cTokens = 0
        if let usage = json["usage"] as? [String: Any] {
            pTokens = (usage["prompt_tokens"] as? Int) ?? 0
            cTokens = (usage["completion_tokens"] as? Int) ?? 0
        }
        if cTokens == 0 { cTokens = max(1, content.count / 4) }

        return (content.trimmingCharacters(in: .whitespacesAndNewlines), pTokens, cTokens)
    }

    // MARK: - Cloudflare Workers AI Endpoint

    private func callCloudflare(
        model: String,
        system: String?,
        user: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard let accountId = config.cloudflareAccountId, let token = config.cloudflareApiToken else {
            throw CloudInferenceError.noAvailableProvider(reasons: ["Cloudflare credentials missing"])
        }

        let endpoint = config.cloudflareBaseURL
            .appendingPathComponent(accountId)
            .appendingPathComponent("ai/run")
            .appendingPathComponent(model)

        var messages: [[String: String]] = []
        if let s = system, !s.isEmpty {
            messages.append(["role": "system", "content": s])
        }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 500

        if code == 429 {
            await rateLimiter.record429(provider: .cloudflare)
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: 429, message: "Rate limit reached")
        }

        guard code == 200 else {
            let msg = String(decoding: data.prefix(300), as: UTF8.self)
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: code, message: msg)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let responseText = result["response"] as? String
        else {
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: code, message: "Unexpected response shape")
        }

        let cTokens = max(1, responseText.count / 4)
        return (responseText.trimmingCharacters(in: .whitespacesAndNewlines), max(1, user.count / 4), cTokens)
    }
}
