import Foundation

public enum SourceKind: Sendable {
    case flac, alac, wav, aiff, mp3, aac

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff: return true
        case .mp3, .aac: return false
        }
    }
}

public enum MediaError: Error {
    case unsupported(String)
    case unreadable(URL)
}

public struct MediaInfo: Sendable {
    public let url: URL
    public let kind: SourceKind
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    public var trackNumber: Int
    public var trackCount: Int
    public var discNumber: Int
    public var discCount: Int
    public var year: Int
    public var durationMs: UInt32
    public var sampleRate: Double
    public var bitsPerChannel: Int
    public var channels: Int
    public var bitrateKbps: UInt32
    public var cover: Data?

    public init(url: URL, kind: SourceKind, title: String = "", artist: String = "", album: String = "", albumArtist: String = "", genre: String = "", trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 0, discCount: Int = 0, year: Int = 0, durationMs: UInt32 = 0, sampleRate: Double = 0, bitsPerChannel: Int = 0, channels: Int = 0, bitrateKbps: UInt32 = 0, cover: Data? = nil) {
        self.url = url
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.year = year
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.bitsPerChannel = bitsPerChannel
        self.channels = channels
        self.bitrateKbps = bitrateKbps
        self.cover = cover
    }

    static func fallbackTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let stripped = base.replacingOccurrences(of: #"^\d+[ .-]+"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? base : stripped
    }

    static func parsePair(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: "/", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        let first = parts.first.flatMap { $0 } ?? 0
        let second = parts.count > 1 ? (parts[1] ?? 0) : 0
        return (max(first, 0), max(second, 0))
    }

    static func parseYear(_ text: String) -> Int {
        let digits = text.trimmingCharacters(in: .whitespaces).prefix(4)
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return 0 }
        return Int(digits) ?? 0
    }

    static func bitrate(url: URL, durationMs: UInt32) -> UInt32 {
        guard durationMs > 0,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return 0 }
        let kbps = size.doubleValue * 8 / (Double(durationMs) / 1000) / 1000
        return UInt32(max(0, min(kbps, Double(UInt32.max))))
    }
}

public enum MediaReader {
    public static func read(_ url: URL) async throws -> MediaInfo {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac":
            return try FLACMetadata.read(url)
        case "m4a", "wav", "aif", "aiff", "mp3":
            return try await AVMediaReader.read(url, ext: ext)
        default:
            throw MediaError.unsupported(ext)
        }
    }
}
