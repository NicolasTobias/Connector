import CoreGraphics
import Foundation

public enum ArtworkDBError: Error, Equatable {
    case notArtworkDB
    case missingImageList
    case idOverflow
    case ithmbTooLarge(String)
}

public struct ArtworkFormat: Equatable, Sendable {
    public let id: UInt32
    public let side: Int

    public init(id: UInt32, side: Int) {
        self.id = id
        self.side = side
    }

    public var byteCount: Int { side * side * 2 }

    public static let classicFormats = [
        ArtworkFormat(id: 1061, side: 56),
        ArtworkFormat(id: 1055, side: 128),
        ArtworkFormat(id: 1068, side: 128),
        ArtworkFormat(id: 1060, side: 320),
    ]
}

public final class ArtworkDB {
    static let ithmbLimit: UInt64 = 256_000_000

    private let root: Chunk

    public init(data: Data) throws {
        let parsed: Chunk
        do { parsed = try Chunk.parse(data) } catch { throw ArtworkDBError.notArtworkDB }
        guard parsed.tag == "mhfd", Self.headersAreSane(parsed) else { throw ArtworkDBError.notArtworkDB }
        root = parsed
        guard imageList != nil else { throw ArtworkDBError.missingImageList }
    }

    private init(root: Chunk) { self.root = root }

    private static let minimumHeader: [String: Int] = [
        "mhfd": 32, "mhsd": 16, "mhli": 12, "mhla": 12, "mhlf": 12, "mhii": 52, "mhni": 36, "mhif": 24, "mhod": 24,
    ]

    private static func headersAreSane(_ c: Chunk) -> Bool {
        if let min = minimumHeader[c.tag], c.header.count < min { return false }
        return c.children.allSatisfy(headersAreSane)
    }

    private static func chunk(_ tag: String, header: Int, fields: [(Int, UInt32)] = []) -> Chunk {
        var h = Data(count: header)
        h.replaceSubrange(0..<4, with: Data(tag.utf8))
        let c = Chunk(tag: tag, header: h)
        c.setU32(UInt32(header), at: 4)
        for (offset, value) in fields { c.setU32(value, at: offset) }
        return c
    }

    private static func section(_ type: UInt16, _ list: Chunk) -> Chunk {
        let s = chunk("mhsd", header: 0x60)
        s.setU16(type, at: 12)
        s.children = [list]
        return s
    }

    public static func makeEmpty() -> ArtworkDB {
        let mhfd = chunk("mhfd", header: 0x84, fields: [(16, 2), (20, 3), (28, 100)])
        mhfd.header[48] = 2
        let files = chunk("mhlf", header: 0x5c)
        files.children = ArtworkFormat.classicFormats.map(makeMhif)
        files.setU32(UInt32(files.children.count), at: 8)
        mhfd.children = [
            section(1, chunk("mhli", header: 0x5c)),
            section(2, chunk("mhla", header: 0x5c)),
            section(3, files),
        ]
        return ArtworkDB(root: mhfd)
    }

    private static func makeMhif(_ format: ArtworkFormat) -> Chunk {
        let c = chunk("mhif", header: 0x7c, fields: [(16, format.id), (20, UInt32(format.byteCount))])
        c.setU32(0x7c, at: 8)
        return c
    }

    public func serialize() -> Data { root.serialize() }

    private func list(inSection type: UInt16, tag: String) -> Chunk? {
        root.children.first { $0.tag == "mhsd" && $0.u16(at: 12) == type }?.children.first { $0.tag == tag }
    }

    private var imageList: Chunk? { list(inSection: 1, tag: "mhli") }
    private var fileList: Chunk? { list(inSection: 3, tag: "mhlf") }

    public var imageIds: [UInt32] {
        (imageList?.children ?? []).filter { $0.tag == "mhii" }.map { $0.u32(at: 16) }
    }

    private struct Appended {
        let url: URL
        let previousSize: UInt64?
    }

    public func add(cover: CGImage, sourceByteCount: UInt32, songDbId: UInt64, artworkDir: URL) throws -> (imageId: UInt32, sourceSize: UInt32) {
        guard let images = imageList else { throw ArtworkDBError.missingImageList }
        let last = max(imageIds.max() ?? 99, 99)
        guard last < UInt32.max else { throw ArtworkDBError.idOverflow }
        let imageId = last + 1
        let fm = FileManager.default
        try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        var appended: [Appended] = []
        do {
            let mhii = Self.chunk("mhii", header: 0x98, fields: [(16, imageId)])
            mhii.setU64(songDbId, at: 20)
            for format in ArtworkFormat.classicFormats {
                let pixels = ArtworkRenderer.rgb565LE(cover, side: format.side)
                let (name, offset) = try append(pixels, format: format, dir: artworkDir, log: &appended)
                mhii.children.append(Self.thumbnailMhod(format: format, offset: offset, fileName: ":" + name))
            }
            mhii.setU32(UInt32(mhii.children.count), at: 12)
            mhii.setU32(sourceByteCount, at: 48)
            images.children.append(mhii)
            images.setU32(UInt32(images.children.count), at: 8)
            registerFormats()
            if root.header.count >= 32, root.u32(at: 28) <= imageId { root.setU32(imageId + 1, at: 28) }
            return (imageId, sourceByteCount)
        } catch {
            for entry in appended.reversed() { Self.rollback(entry) }
            throw error
        }
    }

    private func append(_ pixels: Data, format: ArtworkFormat, dir: URL, log: inout [Appended]) throws -> (String, UInt32) {
        let fm = FileManager.default
        var index = 1
        var url: URL
        var size: UInt64?
        while true {
            url = dir.appendingPathComponent("F\(format.id)_\(index).ithmb")
            size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
            if let s = size, s >= Self.ithmbLimit { index += 1 } else { break }
        }
        log.append(Appended(url: url, previousSize: size))
        if size == nil, !fm.createFile(atPath: url.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        guard offset <= UInt64(UInt32.max) else { throw ArtworkDBError.ithmbTooLarge(url.lastPathComponent) }
        try handle.write(contentsOf: pixels)
        return (url.lastPathComponent, UInt32(offset))
    }

    private static func rollback(_ entry: Appended) {
        if let size = entry.previousSize {
            if let h = try? FileHandle(forWritingTo: entry.url) {
                try? h.truncate(atOffset: size)
                try? h.close()
            }
        } else {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private static func thumbnailMhod(format: ArtworkFormat, offset: UInt32, fileName: String) -> Chunk {
        let mhni = chunk("mhni", header: 0x4c, fields: [
            (12, 1), (16, format.id), (20, offset), (24, UInt32(format.byteCount)),
        ])
        mhni.setU16(UInt16(format.side), at: 32)
        mhni.setU16(UInt16(format.side), at: 34)
        mhni.children = [stringMhod(type: 3, fileName)]
        let container = chunk("mhod", header: 24)
        container.setU16(2, at: 12)
        container.payload = mhni.serialize()
        return container
    }

    private static func stringMhod(type: UInt16, _ string: String) -> Chunk {
        let utf16 = Data(string.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
        let padding = (4 - (36 + utf16.count) % 4) % 4
        let c = chunk("mhod", header: 24)
        c.setU16(type, at: 12)
        c.header[15] = UInt8(padding)
        var w = ByteWriter()
        w.u32(UInt32(utf16.count))
        w.u8(2)
        w.zeros(3)
        w.u32(0)
        w.bytes(utf16)
        w.zeros(padding)
        c.payload = w.data
        return c
    }

    private func registerFormats() {
        guard let files = fileList else { return }
        let present = Set(files.children.filter { $0.tag == "mhif" }.map { $0.u32(at: 16) })
        for format in ArtworkFormat.classicFormats where !present.contains(format.id) {
            files.children.append(Self.makeMhif(format))
        }
        files.setU32(UInt32(files.children.count), at: 8)
    }

    public func remove(imageIds: Set<UInt32>) {
        guard let images = imageList else { return }
        images.children.removeAll { $0.tag == "mhii" && imageIds.contains($0.u32(at: 16)) }
        images.setU32(UInt32(images.children.count), at: 8)
    }
}
