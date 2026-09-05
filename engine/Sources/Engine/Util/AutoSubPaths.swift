// AutoSubPaths — centralized non-affected user data directory.
//
// Resolves ~/.autosub (or $AUTOSUB_DATA_DIR) for the SQLite store, checkpoints,
// and translation caches, surviving app restarts, uninstalls, reinstalls,
// updates, and code changes.

import Foundation

public enum AutoSubPaths {
    /// Root data directory for AutoSub persistent user data.
    public static var dataDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["AUTOSUB_DATA_DIR"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".autosub", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Primary location for the SQLite database.
    public static var databaseURL: URL {
        migrateFromLegacySupportIfNeeded()
        return dataDirectory.appendingPathComponent("autosub.sqlite")
    }

    /// Checkpoints directory for pipeline resume artifacts.
    public static var checkpointsDirectory: URL {
        let dir = dataDirectory.appendingPathComponent("checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Cache directory for incremental translations and scene synopses.
    public static var cacheDirectory: URL {
        let dir = dataDirectory.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let migrationLock = NSLock()
    private static var didMigrate = false

    /// Migrates existing files from ~/Library/Application Support/AutoSub if needed.
    public static func migrateFromLegacySupportIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didMigrate else { return }
        didMigrate = true

        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }

        let legacyDir = appSupport.appendingPathComponent("AutoSub", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyDir.path) else { return }

        let targetDir = dataDirectory

        // 1. Migrate database files if target does not exist
        let targetDB = targetDir.appendingPathComponent("autosub.sqlite")
        let legacyDB = legacyDir.appendingPathComponent("autosub.sqlite")
        if FileManager.default.fileExists(atPath: legacyDB.path) && !FileManager.default.fileExists(atPath: targetDB.path) {
            try? FileManager.default.copyItem(at: legacyDB, to: targetDB)
            // Also copy WAL and SHM if they exist
            let legacyWAL = legacyDir.appendingPathComponent("autosub.sqlite-wal")
            let targetWAL = targetDir.appendingPathComponent("autosub.sqlite-wal")
            if FileManager.default.fileExists(atPath: legacyWAL.path) && !FileManager.default.fileExists(atPath: targetWAL.path) {
                try? FileManager.default.copyItem(at: legacyWAL, to: targetWAL)
            }
            let legacySHM = legacyDir.appendingPathComponent("autosub.sqlite-shm")
            let targetSHM = targetDir.appendingPathComponent("autosub.sqlite-shm")
            if FileManager.default.fileExists(atPath: legacySHM.path) && !FileManager.default.fileExists(atPath: targetSHM.path) {
                try? FileManager.default.copyItem(at: legacySHM, to: targetSHM)
            }
        }

        // 2. Migrate checkpoints
        let legacyCheckpoints = legacyDir.appendingPathComponent("checkpoints", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyCheckpoints.path) {
            let targetCheckpoints = checkpointsDirectory
            if let files = try? FileManager.default.contentsOfDirectory(atPath: legacyCheckpoints.path) {
                for file in files {
                    let src = legacyCheckpoints.appendingPathComponent(file)
                    let dst = targetCheckpoints.appendingPathComponent(file)
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            }
        }

        // 3. Migrate cache
        let legacyCache = legacyDir.appendingPathComponent("cache", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyCache.path) {
            let targetCache = cacheDirectory
            if let files = try? FileManager.default.contentsOfDirectory(atPath: legacyCache.path) {
                for file in files {
                    let src = legacyCache.appendingPathComponent(file)
                    let dst = targetCache.appendingPathComponent(file)
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            }
        }
    }
}
