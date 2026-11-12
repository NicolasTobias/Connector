import Foundation

public struct Track: Equatable, Sendable {
    public var id: UInt32
    public var dbid: UInt64
    public var title, artist, album, albumArtist, genre, filetype: String
    public var location: String
    public var trackNumber, trackCount, discNumber, discCount, year: Int
    public var durationMs: UInt32
    public var size: UInt32
    public var bitrate: UInt32
    public var sampleRate: UInt32
    public var artworkId: UInt32?
    public var playCount: UInt32
    public var lastPlayed: Date?
    public var rating: UInt8
    public var skipCount: UInt32
    public var timeAdded: UInt32

    public init(
        id: UInt32 = 0, dbid: UInt64 = 0, title: String = "", artist: String = "", album: String = "",
        albumArtist: String = "", genre: String = "", filetype: String = "", location: String = "",
        trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 0, discCount: Int = 0, year: Int = 0,
        durationMs: UInt32 = 0, size: UInt32 = 0, bitrate: UInt32 = 0, sampleRate: UInt32 = 0,
        artworkId: UInt32? = nil, playCount: UInt32 = 0, lastPlayed: Date? = nil, rating: UInt8 = 0,
        skipCount: UInt32 = 0, timeAdded: UInt32 = 0
    ) {
        self.timeAdded = timeAdded
        self.id = id; self.dbid = dbid; self.title = title; self.artist = artist; self.album = album
        self.albumArtist = albumArtist; self.genre = genre; self.filetype = filetype; self.location = location
        self.trackNumber = trackNumber; self.trackCount = trackCount; self.discNumber = discNumber
        self.discCount = discCount; self.year = year; self.durationMs = durationMs; self.size = size
        self.bitrate = bitrate; self.sampleRate = sampleRate; self.artworkId = artworkId
        self.playCount = playCount; self.lastPlayed = lastPlayed; self.rating = rating; self.skipCount = skipCount
    }
}

public struct NewTrack: Equatable {
    public var title, artist, album, albumArtist, genre, filetype: String
    public var location: String
    public var trackNumber, trackCount, discNumber, discCount, year: Int
    public var durationMs: UInt32
    public var size: UInt32
    public var bitrate: UInt32
    public var sampleRate: UInt32
    public var artworkId: UInt32?
    public var rating: UInt8

    public init(
        title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
        genre: String = "", filetype: String = "", location: String = "",
        trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 0, discCount: Int = 0, year: Int = 0,
        durationMs: UInt32 = 0, size: UInt32 = 0, bitrate: UInt32 = 0, sampleRate: UInt32 = 0,
        artworkId: UInt32? = nil, rating: UInt8 = 0
    ) {
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.genre = genre; self.filetype = filetype; self.location = location
        self.trackNumber = trackNumber; self.trackCount = trackCount; self.discNumber = discNumber
        self.discCount = discCount; self.year = year; self.durationMs = durationMs; self.size = size
        self.bitrate = bitrate; self.sampleRate = sampleRate; self.artworkId = artworkId; self.rating = rating
    }
}

enum MacTime {
    static let epochOffset: Double = 2_082_844_800

    static func date(_ v: UInt32) -> Date? {
        v == 0 ? nil : Date(timeIntervalSince1970: Double(v) - epochOffset)
    }

    static func seconds(_ d: Date) -> UInt32 {
        UInt32(truncatingIfNeeded: Int(d.timeIntervalSince1970 + epochOffset))
    }
}

enum MhitOffset {
    static let id = 0x10, visible = 0x14, marker = 0x18, type1 = 0x1C, type2 = 0x1D, rating = 0x1F
    static let timeModified = 0x20, size = 0x24, length = 0x28, trackNr = 0x2C, trackCount = 0x30
    static let year = 0x34, bitrate = 0x38, sampleRate = 0x3C, playCount = 0x50, lastPlayed = 0x58
    static let discNr = 0x5C, discCount = 0x60, timeAdded = 0x68, dbid = 0x70, artworkCount = 0x7C
    static let unk126 = 0x7E, artworkSize = 0x80, sampleRateFloat = 0x88, unk144 = 0x90, skipCount = 0x9C
    static let hasArtwork = 0xA4, dbid2 = 0xA8, markUnplayed = 0xB2, mediaType = 0xD0
    static let albumId = 0x120, fileSizeCopy = 0x12C, mhiiLink = 0x160, artistId = 0x1E0
}

extension Chunk {
    func rawU8(_ o: Int) -> UInt8 { o < header.count ? header[header.startIndex + o] : 0 }
    func rawU16(_ o: Int) -> UInt16 { o + 2 <= header.count ? u16(at: o) : 0 }
    func rawU32(_ o: Int) -> UInt32 { o + 4 <= header.count ? u32(at: o) : 0 }
    func setIfFits(_ v: UInt32, at o: Int) { if o + 4 <= header.count { setU32(v, at: o) } }
}

extension Track {
    init(mhit c: Chunk) {
        let s = MhodString.strings(in: c)
        let rateFloat = Float(bitPattern: c.rawU32(MhitOffset.sampleRateFloat))
        let rate: UInt32 = rateFloat > 0 && rateFloat < 4_000_000 ? UInt32(rateFloat) : c.rawU32(MhitOffset.sampleRate) >> 16
        let link = c.rawU32(MhitOffset.mhiiLink)
        self.init(
            id: c.rawU32(MhitOffset.id),
            dbid: c.header.count >= MhitOffset.dbid + 8 ? c.u64(at: MhitOffset.dbid) : 0,
            title: s[MhodType.title] ?? "", artist: s[MhodType.artist] ?? "", album: s[MhodType.album] ?? "",
            albumArtist: s[MhodType.albumArtist] ?? "", genre: s[MhodType.genre] ?? "",
            filetype: s[MhodType.filetype] ?? "", location: s[MhodType.path] ?? "",
            trackNumber: Int(c.rawU32(MhitOffset.trackNr)), trackCount: Int(c.rawU32(MhitOffset.trackCount)),
            discNumber: Int(c.rawU32(MhitOffset.discNr)), discCount: Int(c.rawU32(MhitOffset.discCount)),
            year: Int(c.rawU32(MhitOffset.year)),
            durationMs: c.rawU32(MhitOffset.length), size: c.rawU32(MhitOffset.size),
            bitrate: c.rawU32(MhitOffset.bitrate), sampleRate: rate,
            artworkId: link == 0 ? nil : link,
            playCount: c.rawU32(MhitOffset.playCount), lastPlayed: MacTime.date(c.rawU32(MhitOffset.lastPlayed)),
            rating: c.rawU8(MhitOffset.rating), skipCount: c.rawU32(MhitOffset.skipCount),
            timeAdded: c.rawU32(MhitOffset.timeAdded)
        )
    }
}

enum MhitBuilder {
    static let headerSize = 0x248

    static func marker(for location: String, filetype: String) -> (marker: UInt32, isMP3: Bool, isAAC: Bool) {
        let ext = (location as NSString).pathExtension.lowercased()
        let letters = ext.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 }
        var m: UInt32 = 0
        for i in 0..<4 { m = (m << 8) | UInt32(i < letters.count ? letters[i] : 0x20) }
        let lower = filetype.lowercased()
        let isMP3 = ext == "mp3" || lower.contains("mpeg") || lower.contains("mp3")
        let isAAC = ["m4a", "m4b", "aac", "mp4"].contains(ext) || lower.contains("aac")
        return (m, isMP3, isAAC)
    }

    static func u32(_ v: Int) -> UInt32 { UInt32(truncatingIfNeeded: max(0, v)) }

    static func make(_ t: NewTrack, id: UInt32, dbid: UInt64, albumId: UInt32, artistId: UInt32,
                     dbMarker: UInt64, now: Date) -> Chunk {
        var h = Data(count: headerSize)
        h.replaceSubrange(0..<4, with: Data("mhit".utf8))
        let c = Chunk(tag: "mhit", header: h)
        c.setU32(UInt32(headerSize), at: 4)
        let kind = marker(for: t.location, filetype: t.filetype)
        let stamp = MacTime.seconds(now)
        c.setU32(id, at: MhitOffset.id)
        c.setU32(1, at: MhitOffset.visible)
        c.setU32(kind.marker, at: MhitOffset.marker)
        c.header[MhitOffset.type2] = kind.isMP3 ? 1 : 0
        c.header[MhitOffset.rating] = t.rating
        c.setU32(stamp, at: MhitOffset.timeModified)
        c.setU32(t.size, at: MhitOffset.size)
        c.setU32(t.durationMs, at: MhitOffset.length)
        c.setU32(u32(t.trackNumber), at: MhitOffset.trackNr)
        c.setU32(u32(t.trackCount), at: MhitOffset.trackCount)
        c.setU32(u32(t.year), at: MhitOffset.year)
        c.setU32(t.bitrate, at: MhitOffset.bitrate)
        c.setU32(min(t.sampleRate, 0xFFFF) << 16, at: MhitOffset.sampleRate)
        c.setU32(u32(t.discNumber), at: MhitOffset.discNr)
        c.setU32(u32(t.discCount), at: MhitOffset.discCount)
        c.setU32(stamp, at: MhitOffset.timeAdded)
        c.setU64(dbid, at: MhitOffset.dbid)
        c.setU16(kind.isMP3 || kind.isAAC ? 0xFFFF : 0, at: MhitOffset.unk126)
        c.setU32(Float(t.sampleRate).bitPattern, at: MhitOffset.sampleRateFloat)
        c.setU16(kind.isMP3 ? 0x0C : (kind.isAAC ? 0x33 : 0), at: MhitOffset.unk144)
        c.setU64(dbid, at: MhitOffset.dbid2)
        c.header[MhitOffset.markUnplayed] = 1
        c.setU32(1, at: MhitOffset.mediaType)
        c.setU32(albumId, at: MhitOffset.albumId)
        c.setU64(dbMarker, at: MhitOffset.albumId + 4)
        c.setU32(t.size, at: MhitOffset.fileSizeCopy)
        c.setU64(0x808080808080, at: 0x134)
        c.setU32(1, at: 0x168)
        c.setU32(artistId, at: MhitOffset.artistId)
        let strings: [(UInt32, String)] = [
            (MhodType.title, t.title), (MhodType.artist, t.artist), (MhodType.album, t.album),
            (MhodType.filetype, t.filetype), (MhodType.path, t.location), (MhodType.genre, t.genre),
            (MhodType.albumArtist, t.albumArtist),
        ]
        c.children = strings.filter { !$0.1.isEmpty }.map { MhodString.make(type: $0.0, $0.1) }
        c.setU32(UInt32(c.children.count), at: 12)
        if let art = t.artworkId { applyArtwork(c, artworkId: art, size: 0) }
        return c
    }

    static func applyArtwork(_ c: Chunk, artworkId: UInt32, size: UInt32) {
        guard c.header.count >= MhitOffset.hasArtwork + 1, c.header.count >= MhitOffset.mhiiLink + 4 else { return }
        c.setU32(artworkId, at: MhitOffset.mhiiLink)
        c.setU16(1, at: MhitOffset.artworkCount)
        c.setU32(size, at: MhitOffset.artworkSize)
        c.header[MhitOffset.hasArtwork] = 1
    }
}
