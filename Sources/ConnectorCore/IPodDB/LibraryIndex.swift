import Foundation

struct SortInfo {
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var composer = ""
    var trackNumber: Int32 = 0
    var discNumber: Int32 = 0

    init() {}

    init(mhit: Chunk) {
        let s = MhodString.strings(in: mhit)
        func pick(_ sortType: UInt32?, _ type: UInt32) -> String {
            if let sortType, let v = s[sortType], !v.isEmpty { return v }
            return s[type] ?? ""
        }
        title = pick(MhodType.sortTitle, MhodType.title)
        album = pick(MhodType.sortAlbum, MhodType.album)
        composer = pick(MhodType.sortComposer, MhodType.composer)
        genre = pick(nil, MhodType.genre)
        let rawArtist = s[MhodType.artist] ?? ""
        if let sa = s[MhodType.sortArtist], !sa.isEmpty {
            artist = sa
        } else if rawArtist.utf8.count >= 4, rawArtist.prefix(4).lowercased() == "the " {
            artist = String(rawArtist.dropFirst(4)) + ", The\u{1}\u{1}\u{1}\u{1}\u{1}"
        } else {
            artist = rawArtist
        }
        trackNumber = Int32(bitPattern: mhit.rawU32(0x2C))
        discNumber = Int32(bitPattern: mhit.rawU32(0x5C))
    }
}

enum LibraryIndex {
    static let sortTypes: [UInt32] = [3, 5, 4, 7, 0x12]

    private static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func letter(_ s: String) -> UInt16 {
        for ch in s where ch.isLetter || ch.isNumber {
            if ch.isLetter, let unit = String(ch).uppercased().utf16.first { return unit }
            return 0x30
        }
        return 0x30
    }

    private struct Entry {
        var index: Int
        var info: SortInfo
        var title: String, artist: String, album: String, genre: String, composer: String
    }

    static func chunks(for infos: [SortInfo]) -> [Chunk] {
        let entries = infos.enumerated().map { i, info in
            Entry(index: i, info: info, title: key(info.title), artist: key(info.artist),
                  album: key(info.album), genre: key(info.genre), composer: key(info.composer))
        }
        var out: [Chunk] = []
        for sortType in sortTypes {
            let sorted = entries.sorted { a, b in order(a, b, sortType) }
            out.append(indexChunk(sorted, sortType))
            out.append(jumpChunk(sorted, sortType))
        }
        return out
    }

    private static func order(_ a: Entry, _ b: Entry, _ sortType: UInt32) -> Bool {
        func cmp(_ x: String, _ y: String) -> Int { x == y ? 0 : (x < y ? -1 : 1) }
        func cmp(_ x: Int32, _ y: Int32) -> Int { x == y ? 0 : (x < y ? -1 : 1) }
        var chain: [Int]
        switch sortType {
        case 3:
            chain = [cmp(a.title, b.title)]
        case 4:
            chain = [cmp(a.album, b.album), cmp(a.info.discNumber, b.info.discNumber),
                     cmp(a.info.trackNumber, b.info.trackNumber), cmp(a.title, b.title)]
        case 5:
            chain = [cmp(a.artist, b.artist), cmp(a.album, b.album), cmp(a.info.discNumber, b.info.discNumber),
                     cmp(a.info.trackNumber, b.info.trackNumber), cmp(a.title, b.title)]
        case 7:
            chain = [cmp(a.genre, b.genre), cmp(a.artist, b.artist), cmp(a.album, b.album),
                     cmp(a.info.discNumber, b.info.discNumber), cmp(a.info.trackNumber, b.info.trackNumber),
                     cmp(a.title, b.title)]
        default:
            chain = [cmp(a.composer, b.composer), cmp(a.album, b.album), cmp(a.info.discNumber, b.info.discNumber),
                     cmp(a.info.trackNumber, b.info.trackNumber), cmp(a.title, b.title)]
        }
        for c in chain where c != 0 { return c < 0 }
        return a.index < b.index
    }

    private static func letter(_ e: Entry, _ sortType: UInt32) -> UInt16 {
        switch sortType {
        case 3: return letter(e.info.title)
        case 4: return letter(e.info.album)
        case 5: return letter(e.info.artist)
        case 7: return letter(e.info.genre)
        default: return letter(e.info.composer)
        }
    }

    private static func indexChunk(_ sorted: [Entry], _ sortType: UInt32) -> Chunk {
        var w = ByteWriter()
        w.u32(sortType); w.u32(UInt32(sorted.count)); w.zeros(40)
        for e in sorted { w.u32(UInt32(e.index)) }
        return MhodString.blankMhod(type: MhodType.libraryIndex, payload: w.data)
    }

    private static func jumpChunk(_ sorted: [Entry], _ sortType: UInt32) -> Chunk {
        var groups: [(letter: UInt16, start: Int, count: Int)] = []
        var last: UInt16 = 0
        for (position, e) in sorted.enumerated() {
            let l = letter(e, sortType)
            if l != last {
                groups.append((l, position, 0))
                last = l
            }
            groups[groups.count - 1].count += 1
        }
        var w = ByteWriter()
        w.u32(sortType); w.u32(UInt32(groups.count)); w.zeros(8)
        for g in groups {
            w.u16(g.letter); w.u16(0); w.u32(UInt32(g.start)); w.u32(UInt32(g.count))
        }
        return MhodString.blankMhod(type: MhodType.jumpTable, payload: w.data)
    }
}
