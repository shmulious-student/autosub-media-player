// SceneSynopsis — one or two sentences of situation per scene, generated once and
// cached, then injected into every translation prompt for that scene (handoff §3).
//
// The problem it solves is polysemy that no amount of local context resolves.
// "It's open." is a different Hebrew sentence depending on whether the thing open
// is a door (פתוחה), a shop (פתוחה, different register), or a position that is
// still available (עדיין פנוי). The line itself does not say. The scene does.
//
// Cost is the reason this is a separate, cached pass: a synopsis is ONE small
// completion per ~30-60 s of film, and its text then rides along in the prompt for
// every packet in that scene — where it is prompt-cached and therefore nearly free.
// Re-deriving it per packet would pay the decode cost over and over.
//
// Generation is best-effort by design: a scene whose synopsis fails simply gets
// none, and translation proceeds exactly as it did before.

import Foundation

public enum SceneSynopsis {
    /// Generate a synopsis for each scene, reusing anything already in `cache`.
    ///
    /// Returns scene ordinal (index into `scenes`) → synopsis. Scenes the model
    /// declines or fails on are absent from the map rather than given a placeholder.
    public static func generate(
        scenes: [DialogueScene],
        cues: [SubtitleCue],
        chat: any LlamaChat,
        cache: SceneSynopsisCache? = nil,
        maxLinesPerScene: Int = 40,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async -> [Int: String] {
        var out: [Int: String] = [:]
        let total = max(scenes.count, 1)
        for (i, scene) in scenes.enumerated() {
            let lines = Array(scene.range.map { cues[$0].text }.prefix(maxLinesPerScene))
            guard !lines.isEmpty else { continue }
            let key = cacheKey(lines)
            if let hit = cache?.value(for: key), !hit.isEmpty {
                out[i] = hit
            } else if let text = try? await summarize(lines: lines, chat: chat), !text.isEmpty {
                out[i] = text
                cache?.store(text, for: key)
            }
            onProgress(Double(i + 1) / Double(total))
        }
        cache?.flush()
        return out
    }

    /// Map scene ordinals to a `SubtitleCue.index → sceneId` lookup, the shape
    /// `ScenePacketer.packets` wants.
    public static func sceneIdByCueIndex(scenes: [DialogueScene], cues: [SubtitleCue]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (i, scene) in scenes.enumerated() {
            for c in scene.range { out[cues[c].index] = i }
        }
        return out
    }

    static func summarize(lines: [String], chat: any LlamaChat) async throws -> String {
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Below is one continuous scene from a film or TV episode. In ONE OR TWO short \
        English sentences, state the SITUATION: where the characters plausibly are, \
        what is physically happening, and what they are dealing with. This is used to \
        disambiguate translation, so favour concrete nouns over plot interpretation — \
        say "they are forcing a locked storeroom door at night", not "tension rises".

        Write only the sentences. No preamble, no quotes, no line numbers. If the \
        scene is too short or too vague to describe concretely, output NONE.

        --- SCENE ---
        \(numbered)
        --- SITUATION ---
        """
        let raw = try await chat.complete(system: nil, user: prompt,
                                          maxTokens: 90, temperature: 0.2)
        return clean(raw)
    }

    /// Strip decoration and reject the model's "I don't know" answers.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "^(SITUATION|Situation)\\s*:\\s*", with: "",
                                   options: .regularExpression)
        s = s.split(separator: "\n").prefix(2).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        guard !s.isEmpty, s.uppercased() != "NONE", !s.uppercased().hasPrefix("NONE"),
              s.count >= 12, s.count <= 400 else { return "" }
        return s
    }

    /// Content key for a scene: its own lines, so an unchanged scene reuses its
    /// synopsis across re-runs and across episodes that literally repeat (recaps).
    static func cacheKey(_ lines: [String]) -> String {
        var hasher = Hasher()
        for l in lines { hasher.combine(l) }
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }
}

/// Disk cache of scene synopses, a small JSON sidecar beside the video.
///
/// Kept separate from `BibleCache` (which is shared across a whole SERIES) because
/// a synopsis describes ONE scene of ONE episode and must never leak to another.
public final class SceneSynopsisCache: @unchecked Sendable {
    static let fileName = ".autosub-scenes.json"

    private let url: URL
    private var map: [String: String]
    private var dirty = false
    private let lock = NSLock()

    public init(videoPath: String) {
        self.url = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        let all = Self.readAll(url)
        self.map = all[Self.videoKey(videoPath)] ?? [:]
        self.videoKey = Self.videoKey(videoPath)
    }

    private let videoKey: String

    public func value(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func store(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
        dirty = true
    }

    /// Write back once at the end of a run (never per scene).
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        guard dirty, !map.isEmpty else { return }
        var all = Self.readAll(url)
        all[videoKey] = map
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        dirty = false
    }

    static func videoKey(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func readAll(_ url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }
}
