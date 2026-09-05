// AlassRunner — stage 1 of subtitle sync: remove the GROSS offset with alass.
//
// alass compares the subtitle's on/off pattern against the audio's voice activity
// and finds the global shift that lines them up. It is fast (sub-second on a short
// clip), needs no transcript, and fixes the common case — a subtitle file for a
// different release that is simply N seconds early or late.
//
// Two things about it must be handled explicitly, both learned the hard way:
//
//  1. SPLIT DETECTION MUST BE OFF for our use. By default alass may decide the file
//     contains several independently-shifted blocks and shift them separately. On a
//     short clip with ambient sound and natural pauses it does this wrongly —
//     measured: it split a 90 s clip into arbitrary blocks and shifted the first by
//     -4 s. `--no-split` (`-l`) keeps the timeline continuous.
//
//  2. IT CANNOT FIX AN ARBITRARY STRETCH. alass only tries the standard discrete
//     framerate ratios (24/23.976, 25/24, …). Against a non-standard drift — say a
//     track running 0.5% fast — it can only apply a constant shift, which leaves a
//     residual that grows across the file: measured -350 ms at t=0 drifting to
//     +175 ms at t=90 s, median 154 ms. That residual is exactly what stage 2 (DTW +
//     Theil-Sen) is for. alass is the coarse pass, never the whole answer.

import Foundation

public struct AlassOptions: Sendable {
    /// `--no-split` / `-l`. On by default: see header note 1.
    public var noSplit: Bool
    /// Give up rather than block a job forever if alass wedges.
    public var timeoutSeconds: Int

    public init(noSplit: Bool = true, timeoutSeconds: Int = 120) {
        self.noSplit = noSplit
        self.timeoutSeconds = timeoutSeconds
    }

    public static let `default` = AlassOptions()
}

public enum AlassRunner {
    /// True when an `alass-cli`/`alass` binary is on PATH. Sync degrades gracefully
    /// to the DTW stage alone when it is not.
    public static var isAvailable: Bool { executable() != nil }

    static func executable() -> String? {
        Shell.which("alass-cli") ?? Shell.which("alass")
    }

    /// Align `subtitlePath` against `videoPath`, writing the result to `outputPath`.
    /// Returns false (without throwing) when alass is missing or fails — the caller
    /// then proceeds with the original timings and lets stage 2 do the work.
    @discardableResult
    public static func align(
        videoPath: String,
        subtitlePath: String,
        outputPath: String,
        options: AlassOptions = .default
    ) -> Bool {
        guard let exe = executable() else { return false }
        var args: [String] = []
        if options.noSplit { args.append("--no-split") }
        args += [videoPath, subtitlePath, outputPath]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return false }

        // Bound the wait: a wedged alass must not hold a job forever.
        let deadline = Date().addingTimeInterval(TimeInterval(options.timeoutSeconds))
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
            && FileManager.default.fileExists(atPath: outputPath)
    }
}
