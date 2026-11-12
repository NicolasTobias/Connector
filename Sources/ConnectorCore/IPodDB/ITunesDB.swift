import Foundation

public enum ITunesDBError: Error {
    case notITunesDB, missingTrackList, missingMasterPlaylist
}

public final class ITunesDB {
    let root: Chunk

    public init(data: Data) throws {
        guard let parsed = try? Chunk.parse(data), parsed.tag == "mhbd" else { throw ITunesDBError.notITunesDB }
        guard Self.headersAreSane(parsed) else { throw ITunesDBError.notITunesDB }
        root = parsed
        guard trackList != nil else { throw ITunesDBError.missingTrackList }
        guard !masters(inType: 2).isEmpty else { throw ITunesDBError.missingMasterPlaylist }
    }

    private static let minimumHeader: [String: Int] = [
        "mhbd": 16, "mhsd": 16, "mhit": 16, "mhyp": 20, "mhip": 28, "mhod": 24, "mhia": 20, "mhii": 20,
    ]

    private static func headersAreSane(_ c: Chunk) -> Bool {
        if let min = minimumHeader[c.tag], c.header.count < min { return false }
        return c.children.allSatisfy(headersAreSane)
    }

    public func serialize() -> Data { root.serialize() }

    public var tracks: [Track] { (trackList?.children ?? []).filter { $0.tag == "mhit" }.map { Track(mhit: $0) } }

    func section(_ type: UInt32) -> Chunk? {
        root.children.first { $0.tag == "mhsd" && $0.rawU32(12) == type }
    }

    var trackList: Chunk? { section(1)?.children.first { $0.tag == "mhlt" } }

    func masters(inType type: UInt32) -> [Chunk] {
        guard let list = section(type)?.children.first(where: { $0.tag == "mhlp" }) else { return [] }
        return list.children.filter { $0.tag == "mhyp" && $0.rawU8(0x14) == 1 }
    }

    var masters: [Chunk] { masters(inType: 2) + masters(inType: 3) }

    public var deviceName: String? {
        for master in masters {
            if let name = MhodString.strings(in: master)[MhodType.title], !name.isEmpty { return name }
        }
        return nil
    }

    var allPlaylists: [Chunk] {
        ([2, 3, 5] as [UInt32]).flatMap { type -> [Chunk] in
            guard let list = section(type)?.children.first(where: { $0.tag == "mhlp" }) else { return [] }
            return list.children.filter { $0.tag == "mhyp" }
        }
    }

    var mhits: [Chunk] { (trackList?.children ?? []).filter { $0.tag == "mhit" } }

    @discardableResult
    public func add(_ t: NewTrack) -> Track {
        let existing = mhits
        let id = (existing.map { $0.rawU32(MhitOffset.id) }.max() ?? 0) + 1
        let used = Set(existing.map { $0.header.count >= MhitOffset.dbid + 8 ? $0.u64(at: MhitOffset.dbid) : 0 })
        var dbid: UInt64
        repeat { dbid = UInt64.random(in: 1...UInt64.max) } while used.contains(dbid)
        let albumId = albumIdFor(t, existing: existing)
        let artistId = artistIdFor(t, existing: existing)
        let marker = root.header.count >= 0x2C ? root.u64(at: 0x24) : 0
        let mhit = MhitBuilder.make(t, id: id, dbid: dbid, albumId: albumId, artistId: artistId, dbMarker: marker, now: Date())
        guard let list = trackList else { return Track(mhit: mhit) }
        list.children.append(mhit)
        list.setU32(UInt32(list.children.count), at: 8)
        for master in masters { appendMhip(trackId: id, to: master) }
        refreshIndexes()
        return Track(mhit: mhit)
    }

    public func remove(ids: Set<UInt32>) {
        guard let list = trackList, !ids.isEmpty else { return }
        let removed = list.children.filter { $0.tag == "mhit" && ids.contains($0.rawU32(MhitOffset.id)) }
        guard !removed.isEmpty else { return }
        let removedIds = Set(removed.map { $0.rawU32(MhitOffset.id) })
        let albumIds = Set(removed.map { $0.rawU32(MhitOffset.albumId) }).subtracting([0])
        let artistIds = Set(removed.map { $0.rawU32(MhitOffset.artistId) }).subtracting([0])
        list.children.removeAll { $0.tag == "mhit" && removedIds.contains($0.rawU32(MhitOffset.id)) }
        list.setU32(UInt32(list.children.count), at: 8)
        for pl in allPlaylists {
            let before = pl.children.count
            pl.children.removeAll { $0.tag == "mhip" && removedIds.contains($0.rawU32(24)) }
            if pl.children.count != before {
                pl.setU32(UInt32(pl.children.filter { $0.tag == "mhip" }.count), at: 16)
            }
        }
        dropUnreferenced(section: 4, listTag: "mhla", itemTag: "mhia", ids: albumIds, field: MhitOffset.albumId)
        dropUnreferenced(section: 8, listTag: "mhli", itemTag: "mhii", ids: artistIds, field: MhitOffset.artistId)
        refreshIndexes()
    }

    public func setArtwork(trackId: UInt32, artworkId: UInt32, size: UInt32) {
        guard let mhit = mhits.first(where: { $0.rawU32(MhitOffset.id) == trackId }) else { return }
        MhitBuilder.applyArtwork(mhit, artworkId: artworkId, size: size)
    }

    private func appendMhip(trackId: UInt32, to master: Chunk) {
        let mhips = master.children.filter { $0.tag == "mhip" }
        let nextPosition = (mhips.compactMap { mhip -> UInt32? in
            guard let pos = mhip.children.first(where: { $0.tag == "mhod" && $0.rawU32(12) == MhodType.playlistItem }),
                  pos.payload.count >= 4 else { return nil }
            return pos.payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }.max()).map { $0 + 1 } ?? 0
        var h = ByteWriter()
        h.tag("mhip"); h.u32(76); h.u32(0); h.u32(1); h.u32(0); h.u32(0); h.u32(trackId); h.u32(0); h.u32(0); h.zeros(40)
        var p = ByteWriter()
        p.u32(nextPosition); p.zeros(16)
        let mhip = Chunk(tag: "mhip", header: h.data, children: [MhodString.blankMhod(type: MhodType.playlistItem, payload: p.data)])
        master.children.append(mhip)
        master.setU32(UInt32(mhips.count + 1), at: 16)
    }

    private func refreshIndexes() {
        let byId = Dictionary(mhits.map { ($0.rawU32(MhitOffset.id), $0) }, uniquingKeysWith: { a, _ in a })
        for master in masters {
            let infos = master.children.filter { $0.tag == "mhip" }.compactMap { byId[$0.rawU32(24)] }.map { SortInfo(mhit: $0) }
            let isIndex: (Chunk) -> Bool = { $0.tag == "mhod" && [52, 53].contains($0.rawU32(12)) }
            let insertAt = master.children.firstIndex(where: isIndex)
            master.children.removeAll(where: isIndex)
            if !infos.isEmpty {
                let at = insertAt ?? (master.children.firstIndex { $0.tag != "mhod" } ?? master.children.count)
                master.children.insert(contentsOf: LibraryIndex.chunks(for: infos), at: at)
            }
            master.setU32(UInt32(master.children.filter { $0.tag == "mhod" }.count), at: 12)
        }
    }

    private func albumKey(album: String, albumArtist: String, artist: String) -> String {
        album + "\u{0}" + (albumArtist.isEmpty ? artist : albumArtist)
    }

    private func albumIdFor(_ t: NewTrack, existing: [Chunk]) -> UInt32 {
        guard !t.album.isEmpty, let list = section(4)?.children.first(where: { $0.tag == "mhla" }) else { return 0 }
        let key = albumKey(album: t.album, albumArtist: t.albumArtist, artist: t.artist)
        for item in list.children where item.tag == "mhia" {
            let s = MhodString.strings(in: item)
            if albumKey(album: s[MhodType.albumName] ?? "", albumArtist: s[MhodType.albumArtistName] ?? "", artist: "") == key {
                return item.rawU32(16)
            }
        }
        let newId = nextId(list: list, existing: existing, field: MhitOffset.albumId)
        var h = ByteWriter()
        h.tag("mhia"); h.u32(88); h.u32(0); h.u32(0); h.u32(newId); h.u64(UInt64.random(in: 1...UInt64.max)); h.u32(2); h.zeros(56)
        var kids = [MhodString.make(type: MhodType.albumName, t.album)]
        let aa = t.albumArtist.isEmpty ? t.artist : t.albumArtist
        if !aa.isEmpty { kids.append(MhodString.make(type: MhodType.albumArtistName, aa)) }
        let item = Chunk(tag: "mhia", header: h.data, children: kids)
        item.setU32(UInt32(kids.count), at: 12)
        list.children.append(item)
        list.setU32(UInt32(list.children.count), at: 8)
        return newId
    }

    private func artistIdFor(_ t: NewTrack, existing: [Chunk]) -> UInt32 {
        guard !t.artist.isEmpty, let list = section(8)?.children.first(where: { $0.tag == "mhli" }) else { return 0 }
        for item in list.children where item.tag == "mhii" {
            if MhodString.strings(in: item)[MhodType.artistName] == t.artist { return item.rawU32(16) }
        }
        let newId = nextId(list: list, existing: existing, field: MhitOffset.artistId)
        var h = ByteWriter()
        h.tag("mhii"); h.u32(80); h.u32(0); h.u32(1); h.u32(newId); h.u64(UInt64.random(in: 1...UInt64.max)); h.u32(2); h.zeros(48)
        let item = Chunk(tag: "mhii", header: h.data, children: [MhodString.make(type: MhodType.artistName, t.artist)])
        list.children.append(item)
        list.setU32(UInt32(list.children.count), at: 8)
        return newId
    }

    private func nextId(list: Chunk, existing: [Chunk], field: Int) -> UInt32 {
        let fromList = list.children.map { $0.rawU32(16) }.max() ?? 0
        let fromTracks = existing.map { $0.rawU32(field) }.max() ?? 0
        return max(fromList, fromTracks) + 1
    }

    private func dropUnreferenced(section type: UInt32, listTag: String, itemTag: String, ids: Set<UInt32>, field: Int) {
        guard !ids.isEmpty, let list = section(type)?.children.first(where: { $0.tag == listTag }) else { return }
        let referenced = Set(mhits.map { $0.rawU32(field) })
        let before = list.children.count
        list.children.removeAll { $0.tag == itemTag && ids.contains($0.rawU32(16)) && !referenced.contains($0.rawU32(16)) }
        if list.children.count != before { list.setU32(UInt32(list.children.count), at: 8) }
    }
}

extension ITunesDB {
    private static func blank(_ tag: String, _ length: Int) -> Chunk {
        var h = Data(count: length)
        h.replaceSubrange(0..<4, with: Data(tag.utf8))
        let c = Chunk(tag: tag, header: h)
        c.setU32(UInt32(length), at: 4)
        return c
    }

    private static func section(_ type: UInt32, _ list: Chunk) -> Chunk {
        let sd = blank("mhsd", 96)
        sd.setU32(type, at: 12)
        sd.children = [list]
        return sd
    }

    private static func masterPlaylist(now: Date) -> Chunk {
        let mhyp = blank("mhyp", 108)
        mhyp.setU32(2, at: 12)
        mhyp.header[0x14] = 1
        mhyp.setU32(MacTime.seconds(now), at: 24)
        mhyp.setU64(UInt64.random(in: 1...UInt64.max), at: 28)
        mhyp.setU16(1, at: 40)
        mhyp.setU32(1, at: 44)
        let words: [UInt32] = [0, 0, 0, 0, 0, 0, 0x010084, 5, 9, 3, 0x120001, 0, 0, 0, 0xc80002, 0, 0, 0, 0x3c000d, 0, 0, 0,
                               0x7d0004, 0, 0, 0, 0x7d0003, 0, 0, 0, 0x640008, 0, 0, 0, 0x640017, 1, 0, 0, 0x500014, 1, 0, 0,
                               0x7d0015, 1]
        var w = ByteWriter()
        for v in words.dropFirst(2) { w.u32(v) }
        w.zeros(114 * 4)
        mhyp.children = [
            MhodString.make(type: MhodType.title, "iPod"),
            MhodString.blankMhod(type: MhodType.playlistItem, payload: w.data),
        ]
        return mhyp
    }

    public static func makeEmpty() -> ITunesDB {
        let now = Date()
        func list(_ tag: String, _ count: UInt32 = 0, _ children: [Chunk] = []) -> Chunk {
            let l = blank(tag, 92)
            l.setU32(count, at: 8)
            l.children = children
            return l
        }
        let bd = blank("mhbd", 244)
        bd.setU32(1, at: 12)
        bd.setU32(0x30, at: 16)
        bd.setU64(UInt64.random(in: 1...UInt64.max), at: 24)
        bd.setU16(1, at: 0x20)
        bd.setU64(UInt64.random(in: 1...UInt64.max), at: 0x24)
        bd.setU16(0x6E65, at: 0x46)
        bd.setU64(UInt64.random(in: 1...UInt64.max), at: 0x48)
        let playlists = { list("mhlp", 1, [masterPlaylist(now: now)]) }
        bd.children = [
            section(1, list("mhlt")),
            section(3, playlists()),
            section(2, playlists()),
            section(4, list("mhla")),
            section(8, list("mhli")),
            section(6, list("mhlt")),
            section(10, list("mhlt")),
        ]
        bd.setU32(UInt32(bd.children.count), at: 20)
        do {
            return try ITunesDB(data: bd.serialize())
        } catch {
            preconditionFailure("the empty database is not valid: \(error)")
        }
    }
}
