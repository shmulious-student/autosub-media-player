// SubtitleExtractor — pull an embedded TEXT subtitle track out of a container and
// parse it into cues (SPEC §4 "embedded sub" source).
//
// Translating an existing subtitle track is FAR faster and more accurate than
// running ASR over the whole runtime: no Whisper pass, exact dialogue, exact
// timing. Only TEXT subs (subrip/ass/mov_text/webvtt) can be converted to SRT —
// image-based tracks (PGS/VobSub) are skipped (they'd need OCR).

import Foundation

/// One embedded subtitle stream.
public struct SubtitleTrackInfo: Sendable {
    /// 0-based index among SUBTITLE streams (maps to ffmpeg `-map 0:s:<index>`).
    public var index: Int
    public var codec: String?
    public var language: String?

    /// Whether ffmpeg can convert this to SRT (text-based only).
    public var isTextBased: Bool {
        guard let c = codec?.lowercased() else { return false }
        return ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"].contains(c)
    }
}

public struct SubtitleExtractor: Sendable {
    public init() {}

    /// Enumerate subtitle streams via ffprobe.
    public func tracks(videoPath: String) throws -> [SubtitleTrackInfo] {
        let args = [
            "-v", "error", "-select_streams", "s",
            "-show_entries", "stream=index,codec_name:stream_tags=language",
            "-of", "json", videoPath,
        ]
        let json = try Shell.run("ffprobe", args)
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: Data(json.utf8))
        return decoded.streams.enumerated().map { i, s in
            SubtitleTrackInfo(index: i, codec: s.codecName, language: s.tags?.language)
        }
    }

    /// Pick the best text track to translate FROM: prefer one whose language is
    /// NOT the target (we want the source dialogue), else the first text track.
    public func bestTextTrack(videoPath: String, targetLang: String) throws -> SubtitleTrackInfo? {
        let text = (try tracks(videoPath: videoPath)).filter { $0.isTextBased }
        if text.isEmpty { return nil }
        let target = String(targetLang.prefix(2)).lowercased()
        return text.first { $0.language?.prefix(2).lowercased() != target } ?? text.first
    }

    /// Extract a text subtitle track to SRT and parse it into cues.
    public func extractCues(videoPath: String, trackIndex: Int) throws -> [SubtitleCue] {
        let args = [
            "-v", "error", "-i", videoPath,
            "-map", "0:s:\(trackIndex)", "-f", "srt", "-",
        ]
        let srt = try Shell.run("ffmpeg", args)
        return Self.parseSRT(srt)
    }

    // MARK: - SRT parsing

    /// Parse SubRip text into cues (strips simple formatting tags).
    static func parseSRT(_ srt: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        // Normalize newlines, split into blank-line-separated blocks.
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrowLine = lines.first(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimecodes(arrowLine) else { continue }
            guard let arrowIdx = lines.firstIndex(of: arrowLine) else { continue }
            let textLines = lines[(arrowIdx + 1)...]
            let text = stripTags(textLines.joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(index: cues.count + 1, startMs: start, endMs: end, text: text))
        }
        return cues
    }

    /// "00:00:01,000 --> 00:00:03,500" → (1000, 3500) ms.
    static func parseTimecodes(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let s = parseTimecode(parts[0]), let e = parseTimecode(parts[1]) else { return nil }
        return (s, e)
    }

    static func parseTimecode(_ s: String) -> Int? {
        // HH:MM:SS,mmm (also tolerate '.' as the ms separator).
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        let hmsAndMs = t.components(separatedBy: ",")
        guard hmsAndMs.count == 2, let ms = Int(hmsAndMs[1]) else { return nil }
        let hms = hmsAndMs[0].components(separatedBy: ":")
        guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let sec = Int(hms[2])
        else { return nil }
        return ((h * 3600 + m * 60 + sec) * 1000) + ms
    }

    /// Strip SRT/ASS inline tags like <i>…</i> or {\an8}.
    static func stripTags(_ s: String) -> String {
        var out = s
        for pattern in ["<[^>]+>", "\\{[^}]*\\}"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out
    }

    // ffprobe JSON (subset).
    private struct FFProbeOutput: Codable { let streams: [Stream] }
    private struct Stream: Codable {
        let codecName: String?
        let tags: Tags?
        enum CodingKeys: String, CodingKey { case codecName = "codec_name", tags }
    }
    private struct Tags: Codable { let language: String? }
}
