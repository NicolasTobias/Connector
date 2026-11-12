import Foundation

public enum ChunkError: Error, Equatable {
    case truncated(offset: Int)
    case badTag(String, offset: Int)
}

public final class Chunk {
    public var tag: String
    public var header: Data
    public var children: [Chunk]
    public var payload: Data

    public init(tag: String, header: Data, children: [Chunk] = [], payload: Data = Data()) {
        self.tag = tag
        self.header = header
        self.children = children
        self.payload = payload
    }

    private var isList: Bool { tag.hasPrefix("mhl") }
    private var isLeaf: Bool { tag == "mhod" }

    public static func parse(_ data: Data) throws -> Chunk {
        let bytes = Data(data)
        return try parse(bytes, at: 0, end: bytes.count).chunk
    }

    private static func parse(_ data: Data, at start: Int, end: Int) throws -> (chunk: Chunk, next: Int) {
        guard start + 12 <= end else { throw ChunkError.truncated(offset: start) }
        let tagBytes = data.subdata(in: start..<(start + 4))
        guard tagBytes.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) }),
              let tag = String(data: tagBytes, encoding: .ascii), tag.hasPrefix("mh")
        else {
            throw ChunkError.badTag(String(decoding: tagBytes, as: UTF8.self), offset: start)
        }
        func le32(_ o: Int) -> Int {
            var v = 0
            for i in 0..<4 { v |= Int(data[start + o + i]) << (8 * i) }
            return v
        }
        let headerLen = le32(4)
        let field8 = le32(8)
        guard headerLen >= 12, start + headerLen <= end else { throw ChunkError.truncated(offset: start) }
        let header = data.subdata(in: start..<(start + headerLen))
        let chunk = Chunk(tag: tag, header: header)
        var pos = start + headerLen
        if chunk.isList {
            for _ in 0..<field8 {
                let r = try parse(data, at: pos, end: end)
                chunk.children.append(r.chunk)
                pos = r.next
            }
            return (chunk, pos)
        }
        guard field8 >= headerLen, start + field8 <= end else { throw ChunkError.truncated(offset: start) }
        let total = start + field8
        if chunk.isLeaf {
            chunk.payload = data.subdata(in: pos..<total)
            return (chunk, total)
        }
        while pos < total {
            let r = try parse(data, at: pos, end: total)
            chunk.children.append(r.chunk)
            pos = r.next
        }
        return (chunk, total)
    }

    public func serialize() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    @discardableResult
    private func write(into out: inout Data) -> Int {
        let start = out.count
        out.append(header)
        if isList {
            for c in children { c.write(into: &out) }
            return out.count - start
        }
        out.append(payload)
        for c in children { c.write(into: &out) }
        let total = out.count - start
        let v = UInt32(truncatingIfNeeded: total)
        for i in 0..<4 { out[start + 8 + i] = UInt8(truncatingIfNeeded: v >> UInt32(8 * i)) }
        return total
    }

    public func u16(at o: Int) -> UInt16 { UInt16(read(o, 2)) }
    public func u32(at o: Int) -> UInt32 { UInt32(read(o, 4)) }
    public func u64(at o: Int) -> UInt64 { read(o, 8) }
    public func setU16(_ v: UInt16, at o: Int) { write(UInt64(v), o, 2) }
    public func setU32(_ v: UInt32, at o: Int) { write(UInt64(v), o, 4) }
    public func setU64(_ v: UInt64, at o: Int) { write(v, o, 8) }

    private func read(_ o: Int, _ n: Int) -> UInt64 {
        precondition(o >= 0 && o + n <= header.count, "lectura fuera de la cabecera de \(tag)")
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(header[header.startIndex + o + i]) << UInt64(8 * i) }
        return v
    }

    private func write(_ v: UInt64, _ o: Int, _ n: Int) {
        precondition(o >= 0 && o + n <= header.count, "escritura fuera de la cabecera de \(tag)")
        for i in 0..<n { header[header.startIndex + o + i] = UInt8(truncatingIfNeeded: v >> UInt64(8 * i)) }
    }
}
