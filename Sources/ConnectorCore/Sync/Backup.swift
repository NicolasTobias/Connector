import Foundation

enum Backup {
    static let keep = 20

    static func perform(controlDir: URL, backupsRoot: URL, guidHex: String, now: Date = Date()) throws {
        let fm = FileManager.default
        let guidDir = backupsRoot.appendingPathComponent(guidHex, isDirectory: true)
        try fm.createDirectory(at: guidDir, withIntermediateDirectories: true)

        let initial = guidDir.appendingPathComponent("inicial", isDirectory: true)
        if !fm.fileExists(atPath: initial.path) {
            let staging = guidDir.appendingPathComponent("inicial.tmp", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                for entry in try fm.contentsOfDirectory(at: controlDir, includingPropertiesForKeys: nil) where entry.lastPathComponent != "Music" {
                    try fm.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent))
                }
                try fm.moveItem(at: staging, to: initial)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var stamp = guidDir.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: stamp.path) {
            stamp = guidDir.appendingPathComponent("\(formatter.string(from: now))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: stamp, withIntermediateDirectories: true)
        let sources = [
            controlDir.appendingPathComponent("iTunes/iTunesDB"),
            controlDir.appendingPathComponent("Artwork/ArtworkDB"),
            controlDir.appendingPathComponent("iTunes/Play Counts"),
        ]
        for source in sources where fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: stamp.appendingPathComponent(source.lastPathComponent))
        }

        let stamps = try fm.contentsOfDirectory(atPath: guidDir.path)
            .filter { $0 != "inicial" && $0 != "inicial.tmp" && !$0.hasPrefix(".") }
            .sorted()
        for old in stamps.dropLast(keep) {
            try? fm.removeItem(at: guidDir.appendingPathComponent(old))
        }
    }
}
