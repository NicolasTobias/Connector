import Foundation

struct ByteCursor {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, n <= remaining else { return nil }
        let start = data.startIndex + offset
        offset += n
        return data.subdata(in: start..<start + n)
    }

    mutating func u8() -> Int? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return Int(data[data.startIndex + offset])
    }

    mutating func bigEndian(_ n: Int) -> Int? {
        guard let bytes = take(n) else { return nil }
        return bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func littleEndian(_ n: Int) -> Int? {
        guard let bytes = take(n) else { return nil }
        return bytes.reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}

enum FLACMetadata {
    static func read(_ url: URL) throws -> MediaInfo {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw MediaError.unreadable(url) }
        return try parse(data, url: url)
    }

    static func parse(_ data: Data, url: URL) throws -> MediaInfo {
        let bad = MediaError.unreadable(url)
        var cursor = ByteCursor(data)
        guard let marker = cursor.take(4), marker == Data("fLaC".utf8) else { throw bad }

        var streamInfo: (rate: Int, channels: Int, bits: Int, samples: Int)?
        var comments: [String: String] = [:]
        var pictures: [(type: Int, data: Data)] = []
        var isLast = false
        while !isLast {
            guard let header = cursor.u8(), let length = cursor.bigEndian(3) else { throw bad }
            isLast = header & 0x80 != 0
            guard let body = cursor.take(length) else { throw bad }
            switch header & 0x7F {
            case 0:
                guard let info = parseStreamInfo(body) else { throw bad }
                streamInfo = info
            case 4:
                guard let parsed = parseVorbisComment(body) else { throw bad }
                for (key, value) in parsed where comments[key] == nil { comments[key] = value }
            case 6:
                guard let picture = parsePicture(body) else { throw bad }
                pictures.append(picture)
            default:
                break
            }
        }
        guard let stream = streamInfo, stream.rate > 0 else { throw bad }

        var info = MediaInfo(url: url, kind: .flac)
        info.sampleRate = Double(stream.rate)
        info.channels = stream.channels
        info.bitsPerChannel = stream.bits
        let ms = Double(stream.samples) / Double(stream.rate) * 1000
        info.durationMs = UInt32(max(0, min(ms.rounded(), Double(UInt32.max))))
        info.bitrateKbps = MediaInfo.bitrate(url: url, durationMs: info.durationMs)

        let title = comments["TITLE"] ?? ""
        info.title = title.isEmpty ? MediaInfo.fallbackTitle(for: url) : title
        info.artist = comments["ARTIST"] ?? ""
        info.album = comments["ALBUM"] ?? ""
        info.albumArtist = comments["ALBUMARTIST"] ?? ""
        info.genre = comments["GENRE"] ?? ""
        let track = MediaInfo.parsePair(comments["TRACKNUMBER"] ?? "")
        info.trackNumber = track.0
        info.trackCount = Int(comments["TRACKTOTAL"] ?? comments["TOTALTRACKS"] ?? "") ?? track.1
        let disc = MediaInfo.parsePair(comments["DISCNUMBER"] ?? "")
        info.discNumber = disc.0
        info.discCount = Int(comments["DISCTOTAL"] ?? comments["TOTALDISCS"] ?? "") ?? disc.1
        info.year = MediaInfo.parseYear(comments["DATE"] ?? comments["YEAR"] ?? "")
        info.cover = (pictures.first { $0.type == 3 } ?? pictures.first)?.data
        return info
    }

    private static func parseStreamInfo(_ body: Data) -> (rate: Int, channels: Int, bits: Int, samples: Int)? {
        guard body.count >= 18 else { return nil }
        var cursor = ByteCursor(body, offset: 10)
        guard let packed = cursor.bigEndian(8) else { return nil }
        let rate = packed >> 44 & 0xFFFFF
        let channels = (packed >> 41 & 0x7) + 1
        let bits = (packed >> 36 & 0x1F) + 1
        let samples = packed & 0xF_FFFF_FFFF
        return (rate, channels, bits, samples)
    }

    private static func parseVorbisComment(_ body: Data) -> [String: String]? {
        var cursor = ByteCursor(body)
        guard let vendorLength = cursor.littleEndian(4), cursor.take(vendorLength) != nil,
              let count = cursor.littleEndian(4) else { return nil }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let length = cursor.littleEndian(4), let raw = cursor.take(length) else { return nil }
            guard let text = String(data: raw, encoding: .utf8), let eq = text.firstIndex(of: "=") else { continue }
            let key = text[..<eq].uppercased()
            if result[key] == nil { result[key] = String(text[text.index(after: eq)...]) }
        }
        return result
    }

    private static func parsePicture(_ body: Data) -> (type: Int, data: Data)? {
        var cursor = ByteCursor(body)
        guard let type = cursor.bigEndian(4),
              let mimeLength = cursor.bigEndian(4), cursor.take(mimeLength) != nil,
              let descLength = cursor.bigEndian(4), cursor.take(descLength) != nil,
              cursor.take(16) != nil,
              let dataLength = cursor.bigEndian(4), let bytes = cursor.take(dataLength) else { return nil }
        return (type, bytes)
    }
}
