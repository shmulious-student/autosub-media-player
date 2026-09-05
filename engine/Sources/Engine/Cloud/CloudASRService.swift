// CloudASRService — ASRService implementation using Groq Whisper Large V3 & Cloudflare.
//
// Automatically:
//   - Encodes float samples to 16-bit 16kHz mono WAV in memory (no intermediate file)
//   - Chunks longer audio (>10 min) to stay safely below Groq's 25MB limit
//   - Requests verbose_json with word- and segment-level timestamps
//   - Tracks daily audio seconds against Groq's free quota (7,200s/day)
//   - Fails over to Cloudflare Workers AI Whisper if Groq is exhausted or rate limited

import Foundation

public struct WavEncoder {
    /// Encode 16kHz float samples ([-1.0, 1.0]) into standard 16-bit PCM WAV Data.
    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(samples.count) * UInt32(bitsPerSample / 8)
        let chunkSize: UInt32 = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: UInt32 = 16
        withUnsafeBytes(of: subchunk1Size.littleEndian) { data.append(contentsOf: $0) }
        let audioFormat: UInt16 = 1 // PCM
        withUnsafeBytes(of: audioFormat.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }

        // data chunk
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }

        // 16-bit integer PCM samples
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let intSample = Int16(clamped * 32767.0)
            withUnsafeBytes(of: intSample.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }
}

public actor CloudASRService: ASRService {
    private let config: CloudConfig
    private let rateLimiter: CloudRateLimiter

    public init(config: CloudConfig, rateLimiter: CloudRateLimiter = .shared) {
        self.config = config
        self.rateLimiter = rateLimiter
    }

    public func transcribe(
        samples: [Float], sampleRate: Int, sourceLanguageHint: String?
    ) async throws -> ASRResult {
        guard config.hasAnyCloudKey else {
            throw CloudInferenceError.noKeysConfigured
        }

        let durationSeconds = Double(samples.count) / Double(max(1, sampleRate))

        // Check if we should chunk (Groq max file size is 25MB, ~13 min of 16kHz mono 16-bit WAV)
        // We chunk at 8-minute intervals (~7.68M samples @ 16kHz).
        let chunkSamples = 8 * 60 * sampleRate
        if samples.count > chunkSamples {
            return try await transcribeChunked(
                samples: samples, sampleRate: sampleRate,
                chunkSize: chunkSamples, sourceLanguageHint: sourceLanguageHint
            )
        }

        return try await transcribeSingle(
            samples: samples, sampleRate: sampleRate,
            sourceLanguageHint: sourceLanguageHint, timeOffsetMs: 0
        )
    }

    private func transcribeChunked(
        samples: [Float], sampleRate: Int, chunkSize: Int, sourceLanguageHint: String?
    ) async throws -> ASRResult {
        var allSegments: [ASRSegment] = []
        var detectedLang = sourceLanguageHint ?? "en"
        var offset = 0

        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let slice = Array(samples[offset ..< end])
            let offsetMs = Int((Double(offset) / Double(sampleRate)) * 1000.0)

            let chunkResult = try await transcribeSingle(
                samples: slice, sampleRate: sampleRate,
                sourceLanguageHint: sourceLanguageHint, timeOffsetMs: offsetMs
            )

            detectedLang = chunkResult.language
            allSegments.append(contentsOf: chunkResult.segments)
            offset += chunkSize
        }

        return ASRResult(language: detectedLang, segments: allSegments)
    }

    private func transcribeSingle(
        samples: [Float], sampleRate: Int, sourceLanguageHint: String?, timeOffsetMs: Int
    ) async throws -> ASRResult {
        let durationSeconds = Double(samples.count) / Double(max(1, sampleRate))
        let wavData = WavEncoder.encode(samples: samples, sampleRate: sampleRate)

        // 1. Try Groq Whisper (if configured and has daily budget)
        if config.hasGroq, await rateLimiter.hasGroqAudioCapacity(requestedSeconds: durationSeconds) {
            let hasPermit = await rateLimiter.acquirePermit(for: .groq, estimatedTokens: 100)
            if hasPermit {
                do {
                    let result = try await transcribeGroq(
                        wavData: wavData, duration: durationSeconds,
                        sourceLanguageHint: sourceLanguageHint, timeOffsetMs: timeOffsetMs
                    )
                    await rateLimiter.recordGroqAudio(seconds: durationSeconds)
                    return result
                } catch {
                    // Groq failed or 429 → fall through to Cloudflare
                }
            }
        }

        // 2. Fallback to Cloudflare Workers AI Whisper
        if config.hasCloudflare {
            let hasPermit = await rateLimiter.acquirePermit(for: .cloudflare, estimatedTokens: 100)
            if hasPermit {
                do {
                    return try await transcribeCloudflare(
                        wavData: wavData, sourceLanguageHint: sourceLanguageHint,
                        timeOffsetMs: timeOffsetMs
                    )
                } catch {
                    // Fall through
                }
            }
        }

        throw CloudInferenceError.noAvailableProvider(reasons: ["No cloud ASR provider available or audio quota exceeded."])
    }

    // MARK: - Groq Whisper API Call

    private func transcribeGroq(
        wavData: Data, duration: Double, sourceLanguageHint: String?, timeOffsetMs: Int
    ) async throws -> ASRResult {
        guard let apiKey = config.groqApiKey else {
            throw CloudInferenceError.noKeysConfigured
        }

        let endpoint = config.groqBaseURL.appendingPathComponent("audio/transcriptions")
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        func addFormField(named name: String, value: String) {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(value)\r\n".utf8)
        }

        addFormField(named: "model", value: "whisper-large-v3")
        addFormField(named: "response_format", value: "verbose_json")
        addFormField(named: "timestamp_granularities[]", value: "word")
        addFormField(named: "timestamp_granularities[]", value: "segment")

        if let lang = sourceLanguageHint, !lang.isEmpty {
            addFormField(named: "language", value: lang)
        }

        // Audio file part
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: audio/wav\r\n\r\n".utf8)
        body.append(wavData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 500

        if code == 429 {
            await rateLimiter.record429(provider: .groq)
            throw CloudInferenceError.badResponse(provider: "groq", status: 429, message: "Groq Whisper rate limited")
        }

        guard code == 200 else {
            let msg = String(decoding: data.prefix(300), as: UTF8.self)
            throw CloudInferenceError.badResponse(provider: "groq", status: code, message: msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudInferenceError.badResponse(provider: "groq", status: code, message: "Failed to parse JSON")
        }

        let detectedLang = (json["language"] as? String) ?? sourceLanguageHint ?? "en"
        let segmentsArray = (json["segments"] as? [[String: Any]]) ?? []

        var segments: [ASRSegment] = []
        for seg in segmentsArray {
            let text = ((seg["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let startSec = (seg["start"] as? Double) ?? 0.0
            let endSec = (seg["end"] as? Double) ?? 0.0
            let startMs = Int(startSec * 1000.0) + timeOffsetMs
            let endMs = Int(endSec * 1000.0) + timeOffsetMs

            var words: [ASRWord] = []
            if let wordsArray = seg["words"] as? [[String: Any]] {
                for w in wordsArray {
                    let wText = ((w["word"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    let wStart = Int(((w["start"] as? Double) ?? 0.0) * 1000.0) + timeOffsetMs
                    let wEnd = Int(((w["end"] as? Double) ?? 0.0) * 1000.0) + timeOffsetMs
                    let prob = (w["probability"] as? Double)
                    words.append(ASRWord(text: wText, startMs: wStart, endMs: wEnd, probability: prob))
                }
            }

            segments.append(ASRSegment(
                text: text,
                startMs: startMs,
                endMs: endMs,
                words: words,
                avgLogprob: seg["avg_logprob"] as? Double,
                noSpeechProb: seg["no_speech_prob"] as? Double,
                compressionRatio: seg["compression_ratio"] as? Double
            ))
        }

        return ASRResult(language: detectedLang, segments: segments)
    }

    // MARK: - Cloudflare Whisper API Call

    private func transcribeCloudflare(
        wavData: Data, sourceLanguageHint: String?, timeOffsetMs: Int
    ) async throws -> ASRResult {
        guard let accountId = config.cloudflareAccountId, let token = config.cloudflareApiToken else {
            throw CloudInferenceError.noAvailableProvider(reasons: ["Cloudflare credentials missing"])
        }

        let endpoint = config.cloudflareBaseURL
            .appendingPathComponent(accountId)
            .appendingPathComponent("ai/run/@cf/openai/whisper")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = wavData

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 500

        if code == 429 {
            await rateLimiter.record429(provider: .cloudflare)
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: 429, message: "Cloudflare Whisper rate limited")
        }

        guard code == 200 else {
            let msg = String(decoding: data.prefix(300), as: UTF8.self)
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: code, message: msg)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any]
        else {
            throw CloudInferenceError.badResponse(provider: "cloudflare", status: code, message: "Unexpected response shape")
        }

        let text = (result["text"] as? String) ?? ""
        var segments: [ASRSegment] = []

        if let vttArray = result["vtt"] as? [[String: Any]] {
            for item in vttArray {
                let segText = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                let startMs = Int(((item["start"] as? Double) ?? 0.0) * 1000.0) + timeOffsetMs
                let endMs = Int(((item["end"] as? Double) ?? 0.0) * 1000.0) + timeOffsetMs
                segments.append(ASRSegment(text: segText, startMs: startMs, endMs: endMs))
            }
        } else if !text.isEmpty {
            segments.append(ASRSegment(text: text, startMs: timeOffsetMs, endMs: timeOffsetMs + 5000))
        }

        return ASRResult(language: sourceLanguageHint ?? "en", segments: segments)
    }
}
