// Tests for Cloud backend environment: CloudConfig, WavEncoder, CloudRateLimiter, and failover logic.

import XCTest
@testable import Engine

final class CloudBackendTests: XCTestCase {
    func testCloudConfigFromEnvironment() {
        let env: [String: String] = [
            "AUTOSUB_BACKEND_ENV": "cloud",
            "GROQ_API_KEY": "gsk_test123",
            "GEMINI_API_KEY": "AIzaSyTest456",
            "CLOUDFLARE_ACCOUNT_ID": "cf_acc_789",
            "CLOUDFLARE_API_TOKEN": "cf_tok_abc"
        ]
        let cfg = CloudConfig.fromEnvironment(env)
        XCTAssertEqual(cfg.environment, .cloud)
        XCTAssertTrue(cfg.hasGroq)
        XCTAssertTrue(cfg.hasGemini)
        XCTAssertTrue(cfg.hasCloudflare)
        XCTAssertTrue(cfg.hasAnyCloudKey)
        XCTAssertEqual(cfg.groqApiKey, "gsk_test123")
    }

    func testWavEncoderProducesValidHeader() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let wav = WavEncoder.encode(samples: samples, sampleRate: 16_000)

        // 44 bytes header + 5 * 2 bytes = 54 bytes
        XCTAssertEqual(wav.count, 54)

        // Verify RIFF and WAVE magic headers
        let riff = String(decoding: wav[0..<4], as: UTF8.self)
        let wave = String(decoding: wav[8..<12], as: UTF8.self)
        let fmt = String(decoding: wav[12..<16], as: UTF8.self)
        let data = String(decoding: wav[36..<40], as: UTF8.self)

        XCTAssertEqual(riff, "RIFF")
        XCTAssertEqual(wave, "WAVE")
        XCTAssertEqual(fmt, "fmt ")
        XCTAssertEqual(data, "data")
    }

    func testCloudRateLimiterPermitsAndCooldown() async {
        let limiter = CloudRateLimiter()

        // Initial check: has capacity
        let hasCap = await limiter.hasCapacity(for: .gemini)
        XCTAssertTrue(hasCap)

        // Acquire permit
        let permit = await limiter.acquirePermit(for: .gemini, estimatedTokens: 500)
        XCTAssertTrue(permit)

        // Record 429
        await limiter.record429(provider: .gemini, retryAfterSeconds: 10.0)
        let coolingDown = await limiter.isCoolingDown(.gemini)
        XCTAssertTrue(coolingDown)

        // Next permit for gemini should fail while cooling down
        let permitBlocked = await limiter.acquirePermit(for: .gemini, maxWaitSeconds: 0.1)
        XCTAssertFalse(permitBlocked)

        // Groq should still be available
        let groqAvailable = await limiter.hasCapacity(for: .groq)
        XCTAssertTrue(groqAvailable)
    }

    func testCloudQuotaSnapshot() async {
        let limiter = CloudRateLimiter()
        await limiter.recordGroqAudio(seconds: 120.5)

        let snap = await limiter.snapshot()
        XCTAssertEqual(snap.groqAudioSecondsToday, 120.5)
        XCTAssertEqual(snap.maxGroqAudioSecondsDaily, 7200.0)
        XCTAssertEqual(snap.providers.count, 3)
    }

    func testCloudChatClientThrowsWithoutKeys() async {
        let cfg = CloudConfig(environment: .cloud)
        let client = CloudChatClient(config: cfg)

        do {
            _ = try await client.complete(system: nil, user: "test")
            XCTFail("Should throw without keys")
        } catch let err as CloudInferenceError {
            switch err {
            case .noKeysConfigured:
                // expected
                break
            default:
                XCTFail("Unexpected error: \(err)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
