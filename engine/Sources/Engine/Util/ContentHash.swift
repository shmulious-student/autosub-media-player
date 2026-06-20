// ContentHash — a cheap, stable content id for a media file.
//
// Full-file hashing is a non-starter: library files are tens of GB. Instead we
// hash SHA256 over (fileSize ‖ first 64 KiB ‖ last 64 KiB), which is O(1) IO and
// stable across a move/rename of identical bytes — good enough to dedup a Title
// and survive re-imports (SPEC §5 content_hash).

import Foundation
import CryptoKit

public enum ContentHash {
    /// 64 KiB head + 64 KiB tail.
    private static let window = 64 * 1024

    /// SHA256 over fileSize ‖ head ‖ tail, hex-encoded. Throws on unreadable file.
    public static func compute(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        var hasher = SHA256()
        var sizeLE = UInt64(size).littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(data: Data($0)) }

        let head = (try handle.read(upToCount: window)) ?? Data()
        hasher.update(data: head)

        // Only add a tail window when the file is larger than the head we already
        // read — otherwise head already covers the whole file.
        if size > window {
            try handle.seek(toOffset: UInt64(size - window))
            let tail = (try handle.read(upToCount: window)) ?? Data()
            hasher.update(data: tail)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
