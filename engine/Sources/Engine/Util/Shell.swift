// Shell — minimal helper to run external CLI tools (ffmpeg, llama.cpp, …).
//
// The engine shells out to ffmpeg for demux/audio-extract (decode only, no GPL
// encoders) and later to local-LLM runtimes. Keep this dependency-free.

import Foundation

public enum ShellError: Error, CustomStringConvertible {
    case toolNotFound(String)
    case nonZeroExit(tool: String, code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .toolNotFound(let name):
            return "Required tool '\(name)' not found on PATH or known install dirs."
        case .nonZeroExit(let tool, let code, let stderr):
            return "\(tool) exited with code \(code):\n\(stderr)"
        }
    }
}

public enum Shell {
    /// Common install locations to probe before falling back to PATH lookup.
    private static let knownBinDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Resolve an executable by name, checking known dirs then PATH.
    public static func which(_ name: String,
                             fileManager: FileManager = .default) -> String? {
        for dir in knownBinDirs {
            let candidate = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Fall back to PATH via /usr/bin/env.
        let env = Process()
        env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        env.arguments = ["which", name]
        let pipe = Pipe()
        env.standardOutput = pipe
        env.standardError = Pipe()
        do {
            try env.run()
            env.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    /// Run a tool to completion, returning stdout as text. Throws on missing tool
    /// or non-zero exit (with captured stderr).
    @discardableResult
    public static func run(_ tool: String, _ args: [String]) throws -> String {
        let data = try runData(tool, args)
        return String(decoding: data, as: UTF8.self)
    }

    /// Run a tool to completion, returning raw stdout bytes (for binary output
    /// such as decoded PCM piped from ffmpeg). Reads stdout incrementally so a
    /// large stream doesn't deadlock on a full pipe buffer.
    @discardableResult
    public static func runData(_ tool: String, _ args: [String]) throws -> Data {
        guard let exe = which(tool) else { throw ShellError.toolNotFound(tool) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Drain stdout on a background queue to avoid pipe-buffer deadlock on
        // large outputs (a 2h decode is hundreds of MB of PCM).
        var outData = Data()
        let outHandle = out.fileHandleForReading
        let drain = DispatchQueue(label: "shell.stdout.drain")
        let done = DispatchSemaphore(value: 0)
        drain.async {
            outData = outHandle.readDataToEndOfFile()
            done.signal()
        }

        try proc.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        done.wait()

        if proc.terminationStatus != 0 {
            throw ShellError.nonZeroExit(
                tool: tool,
                code: proc.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return outData
    }
}
