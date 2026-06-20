// AudioTrackProbe — enumerate a container's audio tracks via ffprobe (SPEC §5).
//
// Backs Title.audio_tracks[] and the per-title "pick track when multiple"
// decision. Read-only inspection of the original file — no decode, no rewrite.

import Foundation

/// One audio stream inside a container.
public struct AudioTrackInfo: Codable, Sendable, Identifiable {
    /// 0-based index among AUDIO streams (maps to ffmpeg `-map 0:a:<index>`).
    public var index: Int
    public var codec: String?
    /// ISO language tag from stream metadata, if present (e.g. "eng", "heb").
    public var language: String?
    public var channels: Int?
    /// Human label from the stream title tag (e.g. "Director's commentary").
    public var label: String?

    public var id: Int { index }

    public init(index: Int, codec: String? = nil, language: String? = nil,
                channels: Int? = nil, label: String? = nil) {
        self.index = index
        self.codec = codec
        self.language = language
        self.channels = channels
        self.label = label
    }
}

public struct AudioTrackProbe: Sendable {
    public init() {}

    public func probe(videoPath: String) throws -> [AudioTrackInfo] {
        let args = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries",
            "stream=index,codec_name,channels:stream_tags=language,title",
            "-of", "json",
            videoPath,
        ]
        let json = try Shell.run("ffprobe", args)
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(FFProbeOutput.self, from: data)

        // ffprobe `stream.index` is the GLOBAL stream index; renumber to the
        // 0-based audio-only index that `-map 0:a:<n>` expects.
        return decoded.streams.enumerated().map { audioIndex, s in
            AudioTrackInfo(
                index: audioIndex,
                codec: s.codecName,
                language: s.tags?.language,
                channels: s.channels,
                label: s.tags?.title
            )
        }
    }

    // ffprobe JSON shape (subset).
    private struct FFProbeOutput: Codable { let streams: [Stream] }
    private struct Stream: Codable {
        let codecName: String?
        let channels: Int?
        let tags: Tags?
        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case channels, tags
        }
    }
    private struct Tags: Codable {
        let language: String?
        let title: String?
    }
}
