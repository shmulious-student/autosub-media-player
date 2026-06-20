// ModelPaths — resolve model storage from $AUTOSUB_MODELS (docs/MODELS.md).
//
// HARD RULE: every heavyweight weight + download cache lives on the external
// drive, never on the internal disk or in ~. We resolve all model paths from
// $AUTOSUB_MODELS (default /Volumes/EP2TB/autosub-models) and FAIL LOUDLY if the
// directory is missing (e.g. the drive is unmounted), rather than silently
// re-downloading multi-GB weights to the system volume.

import Foundation

public struct ModelPaths: Sendable {
    public static let defaultRoot = "/Volumes/EP2TB/autosub-models"

    /// Resolved root directory for all model storage.
    public let root: URL

    private init(root: URL) {
        self.root = root
    }

    /// Subdirectories per docs/MODELS.md.
    public var whisper: URL { root.appendingPathComponent("whisper") }
    public var whisperKit: URL { root.appendingPathComponent("whisperkit") }
    public var llm: URL { root.appendingPathComponent("llm") }
    public var hfCache: URL { root.appendingPathComponent("hf-cache") }
    public var ollama: URL { root.appendingPathComponent("ollama") }

    public enum ResolveError: Error, CustomStringConvertible {
        case missing(path: String)

        public var description: String {
            switch self {
            case .missing(let path):
                return """
                FATAL: model storage directory not found at "\(path)".

                AutoSub keeps all AI weights on the external drive and never on \
                the internal disk. Mount the drive (or set $AUTOSUB_MODELS) and \
                retry. See docs/MODELS.md. The engine will NOT download weights \
                to the system volume.
                """
            }
        }
    }

    /// Resolve from the environment, failing loudly if the directory is absent.
    ///
    /// Honors $AUTOSUB_MODELS; otherwise uses `defaultRoot`. Does NOT create the
    /// directory — its absence usually means the external drive is unmounted,
    /// which must surface as an error, not get masked by a fresh empty folder.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ModelPaths {
        let rootPath = environment["AUTOSUB_MODELS"] ?? defaultRoot

        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: rootPath, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            throw ResolveError.missing(path: rootPath)
        }
        return ModelPaths(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    }
}
