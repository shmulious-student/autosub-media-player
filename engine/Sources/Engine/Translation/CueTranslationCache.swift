// CueTranslationCache — keep the translation you already paid for.
//
// Translating a feature film is the single most expensive thing this app does:
// minutes of GPU decode, the whole reason titles are prepared in advance. Today
// that work is thrown away wholesale whenever anything changes — correcting ONE
// character's gender in the bible means re-translating every line in the film,
// silently, and waiting for it all again.
//
// That is the wrong granularity. A line's translation depends on a small, knowable
// set of inputs:
//
//     source text · target language · resolved speaker · resolved addressee ·
//     scene synopsis · the genders of the characters THIS line actually mentions
//
// Hash exactly those into a per-cue key and the invalidation question answers
// itself: fixing Sarah's gender changes the key of the lines involving Sarah and
// nothing else. The rest are cache hits, and the re-translation is seconds rather
// than minutes.
//
// The glossary is deliberately NOT hashed wholesale. Hashing the entire
// character→gender map would make every line depend on every character, which is
// the all-or-nothing behaviour this exists to remove.

import Foundation
import CryptoKit

public struct CueTranslationCache: Sendable {
    /// cacheKey → translated line.
    private var entries: [String: String]
    private let url: URL
    private let videoKey: String

    public init(videoPath: String) {
        self.url = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
            .appendingPathComponent(Self.fileName)
        self.videoKey = URL(fileURLWithPath: videoPath).lastPathComponent
        self.entries = Self.readAll(url)[self.videoKey] ?? [:]
    }

    static let fileName = ".autosub-translations.json"

    public var count: Int { entries.count }

    public func value(for key: String) -> String? { entries[key] }

    public mutating func store(_ translation: String, for key: String) {
        guard !translation.isEmpty else { return }
        entries[key] = translation
    }

    /// Persist, dropping any entry not in `keep` so the file cannot grow forever
    /// as a title is re-translated with different bibles.
    public func save(keeping keep: Set<String>? = nil) {
        var pruned = entries
        if let keep { pruned = pruned.filter { keep.contains($0.key) } }
        guard !pruned.isEmpty else { return }
        var all = Self.readAll(url)
        all[videoKey] = pruned
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Keys

    /// The cache key for one line: everything that can change its translation, and
    /// nothing that cannot.
    public static func key(
        source: String,
        targetLang: String,
        binding: DialogueBinding?,
        synopsis: String?,
        glossary: [String: String]
    ) -> String {
        var parts: [String] = [
            source.trimmingCharacters(in: .whitespacesAndNewlines),
            targetLang,
            synopsis ?? "",
        ]
        if let b = binding {
            parts.append("s:\(b.speaker ?? "")/\(b.speakerGender.rawValue)")
            parts.append("a:\(b.addressee ?? "")/\(b.addresseeGender.rawValue)/"
                + "\(b.addresseeNumber.rawValue)/\(b.method.rawValue)")
        } else {
            parts.append("s:")
            parts.append("a:")
        }
        // Only the characters this line is actually about: the speaker, the
        // addressee, and anyone named in the text. Editing an unrelated character
        // must not invalidate this line.
        for (name, gender) in relevantCharacters(source: source, binding: binding,
                                                 glossary: glossary) {
            parts.append("c:\(name)=\(gender)")
        }
        let joined = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The glossary entries that bear on this line, sorted for a stable key.
    static func relevantCharacters(
        source: String, binding: DialogueBinding?, glossary: [String: String]
    ) -> [(String, String)] {
        let haystack = source.lowercased()
        var names = Set<String>()
        if let speaker = binding?.speaker { names.insert(speaker) }
        if let addressee = binding?.addressee { names.insert(addressee) }
        for name in glossary.keys where haystack.contains(name.lowercased()) {
            names.insert(name)
        }
        return names.compactMap { name in
            let hit = glossary.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }
            guard let hit else { return nil }
            return (hit.key, hit.value)
        }.sorted { $0.0 < $1.0 }
    }

    private static func readAll(_ url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }
}
