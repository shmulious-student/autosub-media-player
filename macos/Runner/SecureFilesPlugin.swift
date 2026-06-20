import Cocoa
import FlutterMacOS

/// Native bridge for production-correct, sandbox-safe file access.
///
/// Under the App Sandbox the app can only read files the user explicitly grants
/// via the system file picker (powerbox). To keep that access across launches we
/// mint an *app-scoped security-scoped bookmark* for each picked file/folder and
/// hand the base64 bookmark blob back to Dart. The caller persists it; on the
/// next launch it is passed to `resolveBookmark` to regain access.
///
/// MethodChannel: `autosub/secure_files`
///   - `pickFile`        -> { "path": String, "bookmark": String(base64) } | nil
///   - `pickFolder`      -> { "path": String, "bookmark": String(base64) } | nil
///   - `resolveBookmark` (arg: { "bookmark": String(base64) }) -> String(path) | nil
final class SecureFilesPlugin: NSObject {
    static let channelName = "autosub/secure_files"

    /// URLs we've called `startAccessingSecurityScopedResource()` on. We retain
    /// them for the process lifetime so access isn't released prematurely while
    /// the engine/player is still reading the media.
    private var accessing: [URL] = []

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
        let instance = SecureFilesPlugin()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickFile":
            pick(directories: false, result: result)
        case "pickFolder":
            pick(directories: true, result: result)
        case "resolveBookmark":
            guard let args = call.arguments as? [String: Any],
                  let bookmark = args["bookmark"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "resolveBookmark requires a `bookmark` string",
                                    details: nil))
                return
            }
            result(resolveBookmark(base64: bookmark))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Open an NSOpenPanel, mint a security-scoped bookmark for the chosen URL,
    /// and return `{ path, bookmark }` (or nil if the user cancelled).
    private func pick(directories: Bool, result: @escaping FlutterResult) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            result(nil)
            return
        }

        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            result([
                "path": url.path,
                "bookmark": data.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(code: "bookmark_failed",
                                message: "Could not create bookmark: \(error.localizedDescription)",
                                details: nil))
        }
    }

    /// Resolve a base64 security-scoped bookmark, begin accessing the resource,
    /// and return its filesystem path (or nil on failure). The resource stays
    /// accessed for the process lifetime (tracked in `accessing`).
    private func resolveBookmark(base64: String) -> String? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            // Even if stale, the resolved URL is usable now; the caller should
            // re-pick to refresh the persisted bookmark when convenient.
            guard url.startAccessingSecurityScopedResource() else { return nil }
            accessing.append(url)
            return url.path
        } catch {
            return nil
        }
    }
}
