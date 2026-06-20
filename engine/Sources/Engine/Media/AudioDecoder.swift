// AudioDecoder — universal, streaming audio decode for ASR (SPEC §4).
//
// DESIGN: decode, don't transcode. We never write a per-video intermediate WAV.
// We stream-decode the chosen audio track straight out of the ORIGINAL container
// (MKV, MP4, …) into in-memory 16 kHz mono float PCM and hand those samples to
// WhisperKit. libav (ffmpeg) is the decoder so every common container/codec works
// out of the box — AVFoundation alone can't open MKV.
//
// LICENSING: this is DECODE only (no GPL encoders, no `--enable-gpl`); libav's
// decoders are LGPL and safe for a commercial closed-source app (SPEC §3). For
// shipping we bundle an LGPL ffmpeg/libav build rather than the system binary.

import Foundation

public struct DecodedAudio: Sendable {
    /// Mono PCM samples in [-1, 1].
    public let samples: [Float]
    /// Always 16_000 for Whisper-class ASR.
    public let sampleRate: Int

    public var durationMs: Int { Int(Double(samples.count) / Double(sampleRate) * 1000.0) }
}

public struct AudioDecoder: Sendable {
    /// Whisper-class models expect 16 kHz mono.
    public static let targetSampleRate = 16_000

    public init() {}

    /// Stream-decode `videoPath`'s audio to 16 kHz mono float PCM in memory.
    ///
    /// - Parameter trackIndex: 0-based index INTO THE AUDIO STREAMS (maps to
    ///   ffmpeg `-map 0:a:<n>`); nil = the container's default/primary audio.
    ///
    /// ffmpeg writes raw `f32le` to stdout (`-`), which we read directly — no file
    /// is created. This is the "no transcode per video" path.
    public func decode(videoPath: String, trackIndex: Int? = nil) throws -> DecodedAudio {
        let map = "0:a:\(trackIndex ?? 0)"
        let args = [
            "-v", "error",
            "-i", videoPath,
            "-map", map,
            "-ac", "1",                      // downmix to mono
            "-ar", String(Self.targetSampleRate), // resample to 16 kHz
            "-f", "f32le",                   // raw 32-bit float little-endian
            "-acodec", "pcm_f32le",
            "-",                              // stdout — stream, don't write a file
        ]

        let data = try Shell.runData("ffmpeg", args)
        return DecodedAudio(samples: Self.floats(from: data),
                            sampleRate: Self.targetSampleRate)
    }

    /// Reinterpret little-endian f32 bytes as [Float].
    static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float32.self)
            // On Apple Silicon the host is little-endian, matching `f32le`.
            return Array(buf.prefix(count))
        }
    }
}
