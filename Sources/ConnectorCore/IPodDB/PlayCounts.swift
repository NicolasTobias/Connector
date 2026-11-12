import Foundation

public enum PlayCountsError: Error, Equatable {
    case missingHeader, headerTooShort, entryTooShort, truncated
}

public struct PlayCountEntry: Equatable {
    public var playCount: UInt32
    public var lastPlayed: UInt32
    public var bookmark: UInt32
    public var rating: UInt32?
    public var skipCount: UInt32?

    public init(playCount: UInt32 = 0, lastPlayed: UInt32 = 0, bookmark: UInt32 = 0, rating: UInt32? = nil, skipCount: UInt32? = nil) {
        self.playCount = playCount
        self.lastPlayed = lastPlayed
        self.bookmark = bookmark
        self.rating = rating
        self.skipCount = skipCount
    }
}

public enum PlayCounts {
    public static func parse(_ data: Data) throws -> [PlayCountEntry] {
        guard data.count >= 4, data.prefix(4) == Data("mhdp".utf8) else { throw PlayCountsError.missingHeader }
        var header = ByteReader(data, offset: 4)
        let headerLength = Int(try header.u32())
        let entryLength = Int(try header.u32())
        let count = Int(try header.u32())
        guard headerLength >= 16 else { throw PlayCountsError.headerTooShort }
        guard entryLength >= 12 else { throw PlayCountsError.entryTooShort }
        guard headerLength <= data.count, count <= (data.count - headerLength) / entryLength else {
            throw PlayCountsError.truncated
        }
        return try (0..<count).map { i in
            let start = headerLength + i * entryLength
            func field(_ offset: Int) throws -> UInt32 {
                var r = ByteReader(data, offset: start + offset)
                return try r.u32()
            }
            return PlayCountEntry(
                playCount: try field(0),
                lastPlayed: try field(4),
                bookmark: try field(8),
                rating: entryLength >= 16 ? try field(12) : nil,
                skipCount: entryLength >= 28 ? try field(20) : nil
            )
        }
    }
}

extension ITunesDB {
    public func merge(_ entries: [PlayCountEntry]) {
        for (mhit, entry) in zip(mhits, entries) {
            mhit.setIfFits(mhit.rawU32(MhitOffset.playCount) &+ entry.playCount, at: MhitOffset.playCount)
            mhit.setIfFits(mhit.rawU32(MhitOffset.skipCount) &+ (entry.skipCount ?? 0), at: MhitOffset.skipCount)
            if entry.lastPlayed != 0 { mhit.setIfFits(entry.lastPlayed, at: MhitOffset.lastPlayed) }
            if let rating = entry.rating, rating != 0, mhit.header.count > MhitOffset.rating {
                mhit.header[MhitOffset.rating] = UInt8(truncatingIfNeeded: rating)
            }
        }
    }
}
