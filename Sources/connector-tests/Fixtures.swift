import AudioToolbox
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

struct FixtureError: Error { let message: String }

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw FixtureError(message: "\(what): OSStatus \(status)") }
}

private func pcmFormat(rate: Double, bits: Int, channels: Int = 2) -> AudioStreamBasicDescription {
    let bytes = UInt32(bits / 8)
    let ch = UInt32(channels)
    return AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: ch * bytes, mFramesPerPacket: 1, mBytesPerFrame: ch * bytes,
        mChannelsPerFrame: ch, mBitsPerChannel: UInt32(bits), mReserved: 0)
}

private func writeSine(to file: ExtAudioFileRef, seconds: Double, rate: Double, frequency: Double = 440, channels: Int = 2) throws {
    let ch = UInt32(channels)
    var client = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
        mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
    try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "client format")
    let total = Int(seconds * rate)
    let chunk = 4096
    var written = 0
    var samples = [Float](repeating: 0, count: chunk * channels)
    while written < total {
        let n = min(chunk, total - written)
        for i in 0..<n {
            let v = Float(sin(2 * Double.pi * frequency * Double(written + i) / rate) * 0.5)
            for c in 0..<channels { samples[channels * i + c] = v }
        }
        try samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: ch, mDataByteSize: UInt32(n * 4 * channels), mData: raw.baseAddress))
            try check(ExtAudioFileWrite(file, UInt32(n), &list), "write")
        }
        written += n
    }
}

func makeWAV(at url: URL, seconds: Double, rate: Double, bits: Int, frequency: Double = 440, channels: Int = 2) throws {
    var format = pcmFormat(rate: rate, bits: bits, channels: channels)
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create wav")
    guard let file = ref else { throw FixtureError(message: "wav ref") }
    defer { ExtAudioFileDispose(file) }
    try writeSine(to: file, seconds: seconds, rate: rate, frequency: frequency, channels: channels)
}

func makeAIFF(at url: URL, rate: Double, bits: Int, seconds: Double) throws {
    var format = pcmFormat(rate: rate, bits: bits)
    format.mFormatFlags |= kAudioFormatFlagIsBigEndian
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAIFFType, &format, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create aiff")
    guard let file = ref else { throw FixtureError(message: "aiff ref") }
    defer { ExtAudioFileDispose(file) }
    try writeSine(to: file, seconds: seconds, rate: rate)
}

func makeM4A(at url: URL, alac: Bool, rate: Double, bits: Int, seconds: Double) throws {
    var format = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: alac ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
        mFormatFlags: alac ? (bits == 16 ? 1 : 3) : 0,
        mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
        mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create m4a")
    guard let file = ref else { throw FixtureError(message: "m4a ref") }
    defer { ExtAudioFileDispose(file) }
    try writeSine(to: file, seconds: seconds, rate: rate)
}

func makeFLAC(at url: URL, rate: Double, bits: Int, tags: [String: String], picture: Data?, seconds: Double = 0.5) throws {
    var format = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatFLAC,
        mFormatFlags: bits == 16 ? 1 : 3,
        mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
        mChannelsPerFrame: 2, mBitsPerChannel: UInt32(bits), mReserved: 0)
    var ref: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &format, nil, AudioFileFlags.eraseFile.rawValue, &ref), "create flac")
    guard let file = ref else { throw FixtureError(message: "flac ref") }
    try writeSine(to: file, seconds: seconds, rate: rate)
    try check(ExtAudioFileDispose(file), "dispose")
    try spliceMetadata(url, tags: tags, picture: picture)
}

private func be(_ value: Int, _ n: Int) -> [UInt8] {
    (0..<n).map { UInt8((value >> (8 * (n - 1 - $0))) & 0xFF) }
}

private func le32(_ value: Int) -> [UInt8] { be(value, 4).reversed() }

private func block(type: UInt8, body: [UInt8], last: Bool) -> [UInt8] {
    [type | (last ? 0x80 : 0)] + be(body.count, 3) + body
}

private func spliceMetadata(_ url: URL, tags: [String: String], picture: Data?) throws {
    let bytes = [UInt8](try Data(contentsOf: url))
    guard bytes.count > 8, Array(bytes[0..<4]) == Array("fLaC".utf8) else { throw FixtureError(message: "flac inválido") }
    var offset = 4
    var streamInfo: [UInt8]?
    while true {
        guard offset + 4 <= bytes.count else { throw FixtureError(message: "metadatos truncados") }
        let header = bytes[offset]
        let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        if header & 0x7F == 0 { streamInfo = Array(bytes[offset + 4..<offset + 4 + length]) }
        offset += 4 + length
        if header & 0x80 != 0 { break }
    }
    guard let streamInfo else { throw FixtureError(message: "sin STREAMINFO") }

    let vendor = Array("Connector-tests".utf8)
    var comment = le32(vendor.count) + vendor + le32(tags.count)
    for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
        let entry = Array("\(key)=\(value)".utf8)
        comment += le32(entry.count) + entry
    }
    var out = Array("fLaC".utf8)
    out += block(type: 0, body: streamInfo, last: false)
    out += block(type: 4, body: comment, last: picture == nil)
    if let picture {
        let mime = Array("image/jpeg".utf8)
        var body = be(3, 4) + be(mime.count, 4) + mime + be(0, 4) + be(0, 16)
        body += be(picture.count, 4) + [UInt8](picture)
        out += block(type: 6, body: body, last: true)
    }
    out += bytes[offset...]
    try Data(out).write(to: url)
}

func makeJPEG(size: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}
