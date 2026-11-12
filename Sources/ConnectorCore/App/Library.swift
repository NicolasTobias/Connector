import Foundation

public enum LibrarySort: String, Sendable, CaseIterable {
    case album
    case recent
}

public struct AlbumGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let album: String
    public let artist: String
    public let unnamed: Bool
    public let tracks: [Track]
    public let latest: UInt64

    public var durationMs: UInt64 { tracks.reduce(0) { $0 + UInt64($1.durationMs) } }
    public var trackIDs: Set<UInt32> { Set(tracks.map(\.id)) }
}

public enum LibraryRow: Identifiable, Sendable, Equatable {
    case album(AlbumGroup, expanded: Bool)
    case track(Track, albumID: String)

    public var id: String {
        switch self {
        case .album(let group, _): return "a:" + group.id
        case .track(let track, _): return "t:\(track.id)"
        }
    }
}

public enum Library {
    public static let unnamedAlbum = "Unknown Album"

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func artist(of track: Track) -> String {
        track.albumArtist.isEmpty ? track.artist : track.albumArtist
    }

    public static func key(of track: Track) -> String {
        fold(artist(of: track)) + "\u{0}" + fold(track.album)
    }

    public static func groups(from tracks: [Track]) -> [AlbumGroup] {
        var buckets: [String: [Track]] = [:]
        var order: [String] = []
        for track in tracks {
            let k = key(of: track)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(track)
        }
        return order.map { k in
            let members = buckets[k]!.sorted { a, b in
                let da = max(1, a.discNumber), db = max(1, b.discNumber)
                if da != db { return da < db }
                if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            let first = members[0]
            let latest = members.map { UInt64($0.timeAdded) << 32 | UInt64($0.id) }.max() ?? 0
            return AlbumGroup(
                id: k, album: first.album.isEmpty ? unnamedAlbum : first.album, artist: artist(of: first),
                unnamed: first.album.isEmpty, tracks: members, latest: latest)
        }
    }

    public static func sorted(_ groups: [AlbumGroup], by sort: LibrarySort) -> [AlbumGroup] {
        func byName(_ a: AlbumGroup, _ b: AlbumGroup) -> Bool {
            if a.unnamed != b.unnamed { return !a.unnamed }
            let order = a.album.localizedStandardCompare(b.album)
            if order != .orderedSame { return order == .orderedAscending }
            return a.artist.localizedStandardCompare(b.artist) == .orderedAscending
        }
        switch sort {
        case .album:
            return groups.sorted(by: byName)
        case .recent:
            return groups.sorted { a, b in a.latest != b.latest ? a.latest > b.latest : byName(a, b) }
        }
    }

    public static func rows(groups: [AlbumGroup], collapsed: Set<String>) -> [LibraryRow] {
        var rows: [LibraryRow] = []
        for group in groups {
            let open = !collapsed.contains(group.id)
            rows.append(.album(group, expanded: open))
            if open { rows.append(contentsOf: group.tracks.map { .track($0, albumID: group.id) }) }
        }
        return rows
    }
}
