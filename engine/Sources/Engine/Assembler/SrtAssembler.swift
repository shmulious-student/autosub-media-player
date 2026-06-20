// SrtAssembler — render translated cues to a portable, RTL-aware .srt sidecar.
//
// Output is UTF-8 SubRip written NEXT TO the media (e.g. movie.mkv → movie.he.srt)
// so any player can use it, plus we return a SubtitleArtifact for the internal
// index (SPEC §: "portable sidecar + internal"). RTL targets get bidi controls so
// the line renders right-to-left in players that honor them.

import Foundation

public struct SrtAssembler: Sendable {
    /// Languages that should be wrapped in RTL embedding controls.
    public static let rtlLanguages: Set<String> = ["he", "iw", "ar", "fa", "ur"]

    public init() {}

    /// Build the .srt text from cues.
    public func render(cues: [SubtitleCue], lang: String) -> String {
        let rtl = Self.rtlLanguages.contains(lang)
        var out = ""
        for (i, cue) in cues.enumerated() {
            let line = rtl ? "\u{202B}\(cue.text)\u{202C}" : cue.text // RLE…PDF
            out += "\(i + 1)\n"
            out += "\(Self.timecode(cue.startMs)) --> \(Self.timecode(cue.endMs))\n"
            out += "\(line)\n\n"
        }
        return out
    }

    /// Write the sidecar next to `videoPath` and return its path.
    /// e.g. /movies/Show.mkv + lang "he" → /movies/Show.he.srt
    @discardableResult
    public func writeSidecar(cues: [SubtitleCue], lang: String, videoPath: String) throws -> String {
        let video = URL(fileURLWithPath: videoPath)
        let base = video.deletingPathExtension().lastPathComponent
        let sidecar = video.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(lang).srt")
        try render(cues: cues, lang: lang).write(to: sidecar, atomically: true, encoding: .utf8)
        return sidecar.path
    }

    /// SubRip timecode: HH:MM:SS,mmm
    public static func timecode(_ ms: Int) -> String {
        let ms = max(0, ms)
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }

    /// CPS stats across cues, for the SubtitleArtifact QA fields.
    public static func cpsStats(_ cues: [SubtitleCue]) -> [String: Double] {
        guard !cues.isEmpty else { return [:] }
        let values = cues.map { $0.cps }.filter { $0.isFinite }
        guard !values.isEmpty else { return [:] }
        return [
            "max": values.max() ?? 0,
            "mean": values.reduce(0, +) / Double(values.count),
        ]
    }
}
