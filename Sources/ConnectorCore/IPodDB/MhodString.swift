import Foundation

public enum MhodType {
    public static let title: UInt32 = 1
    public static let path: UInt32 = 2
    public static let album: UInt32 = 3
    public static let artist: UInt32 = 4
    public static let genre: UInt32 = 5
    public static let filetype: UInt32 = 6
    public static let composer: UInt32 = 12
    public static let albumArtist: UInt32 = 22
    public static let sortArtist: UInt32 = 23
    public static let sortTitle: UInt32 = 27
    public static let sortAlbum: UInt32 = 28
    public static let sortComposer: UInt32 = 30
    public static let libraryIndex: UInt32 = 52
    public static let jumpTable: UInt32 = 53
    public static let playlistItem: UInt32 = 100
    public static let albumName: UInt32 = 200
    public static let albumArtistName: UInt32 = 201
    public static let artistName: UInt32 = 300
}

public enum MhodString {
    static let stringTypes: Set<UInt32> = [
        1, 2, 3, 4, 5, 6, 8, 9, 12, 13, 14, 18, 19, 20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 200, 201, 202, 300,
    ]

    static func blankMhod(type: UInt32, payload: Data) -> Chunk {
        var w = ByteWriter()
        w.tag("mhod"); w.u32(24); w.u32(0); w.u32(type); w.u32(0); w.u32(0)
        return Chunk(tag: "mhod", header: w.data, payload: payload)
    }

    static func make(type: UInt32, _ value: String) -> Chunk {
        var utf16 = Data()
        for unit in value.utf16 {
            utf16.append(UInt8(truncatingIfNeeded: unit))
            utf16.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        var w = ByteWriter()
        w.u32(1); w.u32(UInt32(utf16.count)); w.u32(1); w.u32(0)
        w.bytes(utf16)
        return blankMhod(type: type, payload: w.data)
    }

    static func decode(_ mhod: Chunk) -> String? {
        guard mhod.tag == "mhod", mhod.header.count >= 16, stringTypes.contains(mhod.rawU32(12)) else { return nil }
        let p = mhod.payload
        guard p.count >= 16 else { return nil }
        func le32(_ o: Int) -> Int {
            var v = 0
            for i in 0..<4 { v |= Int(p[p.startIndex + o + i]) << (8 * i) }
            return v
        }
        let encoding = le32(0)
        let length = le32(4)
        guard length >= 0, 16 + length <= p.count else { return nil }
        let body = p.subdata(in: (p.startIndex + 16)..<(p.startIndex + 16 + length))
        switch encoding {
        case 1:
            var units: [UInt16] = []
            units.reserveCapacity(length / 2)
            var i = body.startIndex
            while i + 1 < body.endIndex {
                units.append(UInt16(body[i]) | (UInt16(body[i + 1]) << 8))
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 2:
            return String(decoding: body, as: UTF8.self)
        default:
            return nil
        }
    }

    static func strings(in parent: Chunk) -> [UInt32: String] {
        var out: [UInt32: String] = [:]
        for child in parent.children where child.tag == "mhod" {
            let type = child.rawU32(12)
            if out[type] == nil, let s = decode(child) { out[type] = s }
        }
        return out
    }
}
