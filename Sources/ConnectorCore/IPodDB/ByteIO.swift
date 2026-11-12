import Foundation

public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public var count: Int { data.count }

    public mutating func u8(_ v: UInt8) { data.append(v) }

    public mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }

    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }

    public mutating func bytes(_ d: Data) { data.append(d) }

    public mutating func zeros(_ n: Int) { data.append(Data(count: n)) }

    public mutating func tag(_ s: String) { data.append(Data(s.utf8)) }
}

public struct ByteReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = Data(data)
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.count else { throw ChunkError.truncated(offset: offset) }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        offset += n
        return slice
    }

    private mutating func uint(_ n: Int) throws -> UInt64 {
        let d = try take(n)
        var v: UInt64 = 0
        for (i, b) in d.enumerated() { v |= UInt64(b) << UInt64(8 * i) }
        return v
    }

    public mutating func u8() throws -> UInt8 { UInt8(try uint(1)) }
    public mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    public mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
    public mutating func u64() throws -> UInt64 { try uint(8) }
    public mutating func bytes(_ n: Int) throws -> Data { try take(n) }
}
