// BibleCache — reuse a show's character→gender map across its episodes.
//
// The DialogueAnalyzer pass reads the WHOLE script through the 12B LLM just to
// build one character→gender map. For a TV series that map is essentially stable
// across episodes, so re-deriving it every episode is wasted LLM time (the single
// slowest, bandwidth-bound stage). This cache lets episodes 2..N of a show skip the
// analysis pass entirely and reuse episode 1's map.
//
// SAFETY: gender correctness is the product's core differentiator, so we only share
// a map between files we're confident belong to the SAME show. The signal is a
// season/episode marker in the filename (S01E02, 1x02, "Season 1"…). Files WITHOUT
// such a marker (standalone movies, a mixed "Movies" folder) get no shared map and
// are always analyzed fresh — never cross-contaminated. The map for a show is keyed
// by (folder + normalized series name) and stored in a small JSON sidecar in the
// same folder. This is the v0 precursor to the persisted, user-lockable bible.

import Foundation

public enum BibleCache {
    /// Sidecar file holding every series map for one folder:
    /// `{ "<seriesKey>": {"David":"m","Sarah":"f"} }`.
    static let fileName = ".autosub-bibles.json"

    /// The cached character→gender map for this video's show, or `[:]` if the file
    /// isn't episodic (so it must be analyzed fresh) or nothing is cached yet.
    public static func load(videoPath: String) -> [String: String] {
        guard let key = seriesKey(videoPath: videoPath) else { return [:] }
        let all = readAll(dir: cacheURL(videoPath: videoPath))
        return all[key] ?? [:]
    }

    /// Persist this video's map under its show key (merged with anything already
    /// there). No-op for non-episodic files or an empty map — we never write junk
    /// that a later episode would blindly trust.
    public static func save(videoPath: String, characters: [String: String]) {
        guard let key = seriesKey(videoPath: videoPath), !characters.isEmpty else { return }
        let url = cacheURL(videoPath: videoPath)
        var all = readAll(dir: url)
        var merged = all[key] ?? [:]
        for (name, g) in characters where g == "m" || g == "f" {
            // A known gender wins over a missing/unknown one; keep the first known.
            if let existing = merged[name], existing == "m" || existing == "f" { continue }
            merged[name] = g
        }
        all[key] = merged
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Internals

    private static func cacheURL(videoPath: String) -> URL {
        URL(fileURLWithPath: videoPath).deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    private static func readAll(dir url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }

    /// A stable identifier for the show this file belongs to, or nil if the
    /// filename doesn't look episodic. Derived from the series name BEFORE the
    /// season/episode marker, so "The.Show.S01E02.1080p.mkv" and
    /// "The Show - S01E05.mkv" map to the same key.
    static func seriesKey(videoPath: String) -> String? {
        let name = URL(fileURLWithPath: videoPath).deletingPathExtension()
            .lastPathComponent.lowercased()
        // Markers: s01e02 / s1e2, 1x02, "season 1".
        let patterns = ["s\\d{1,2}e\\d{1,2}", "\\b\\d{1,2}x\\d{2}\\b", "season\\s*\\d{1,2}"]
        var markerStart: String.Index?
        for p in patterns {
            if let r = name.range(of: p, options: .regularExpression),
               markerStart == nil || r.lowerBound < markerStart! {
                markerStart = r.lowerBound
            }
        }
        guard let start = markerStart else { return nil }
        // Series name = everything before the marker, separators collapsed to spaces.
        let base = name[name.startIndex ..< start]
            .replacingOccurrences(of: "[._\\-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        return base
    }
}
