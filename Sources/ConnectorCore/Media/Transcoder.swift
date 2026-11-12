import AudioToolbox
import Foundation

public struct PreparedFile: Sendable {
    public let url: URL
    public let ext: String
    public let filetype: String
    public let sizeBytes: UInt32
    public let sampleRate: UInt32
    public let bitrateKbps: UInt32
    public let durationMs: UInt32

    public init(url: URL, ext: String, filetype: String, sizeBytes: UInt32, sampleRate: UInt32, bitrateKbps: UInt32, durationMs: UInt32) {
        self.url = url
        self.ext = ext
        self.filetype = filetype
        self.sizeBytes = sizeBytes
        self.sampleRate = sampleRate
        self.bitrateKbps = bitrateKbps
        self.durationMs = durationMs
    }
}

public enum Transcoder {
    private static let chunkFrames: UInt32 = 32768
    private static let targetRate = 44100.0

    public static func prepare(_ info: MediaInfo, workDir: URL, progress: (Double) -> Void) async throws -> PreparedFile {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        switch info.kind {
        case .mp3:
            return try copy(info, workDir: workDir, id: id, ext: "mp3", filetype: "MPEG audio file", progress: progress)
        case .aac:
            return try copy(info, workDir: workDir, id: id, ext: "m4a", filetype: "AAC audio file", progress: progress)
        case .flac, .alac, .wav, .aiff:
            let output = workDir.appendingPathComponent("\(id).m4a")
            do {
                let frames = try encode(info, to: output, progress: progress)
                return try describe(output, ext: "m4a", filetype: "Apple Lossless audio file", frames: frames, rate: targetRate)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
    }

    private static func copy(_ info: MediaInfo, workDir: URL, id: String, ext: String, filetype: String, progress: (Double) -> Void) throws -> PreparedFile {
        try Task.checkCancellation()
        let output = workDir.appendingPathComponent("\(id).\(ext)")
        do {
            try FileManager.default.copyItem(at: info.url, to: output)
            progress(1)
            var frames: Int64?
            var rate = info.sampleRate
            if let file = open(output) {
                defer { ExtAudioFileDispose(file) }
                frames = property(file, kExtAudioFileProperty_FileLengthFrames, Int64.self)
                if let format = property(file, kExtAudioFileProperty_FileDataFormat, AudioStreamBasicDescription.self), format.mSampleRate > 0 {
                    rate = format.mSampleRate
                }
            }
            return try describe(output, ext: ext, filetype: filetype, frames: frames, rate: rate, fallbackMs: info.durationMs)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func describe(_ url: URL, ext: String, filetype: String, frames: Int64?, rate: Double, fallbackMs: UInt32 = 0) throws -> PreparedFile {
        let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?.uint64Value ?? 0
        var durationMs = fallbackMs
        if let frames, frames > 0, rate > 0 {
            durationMs = UInt32(min((Double(frames) / rate * 1000).rounded(), Double(UInt32.max)))
        }
        var kbps: UInt32 = 0
        if durationMs > 0 {
            kbps = UInt32(min(Double(size) * 8 / (Double(durationMs) / 1000) / 1000, Double(UInt32.max)))
        }
        return PreparedFile(url: url, ext: ext, filetype: filetype, sizeBytes: UInt32(min(size, UInt64(UInt32.max))), sampleRate: UInt32(rate), bitrateKbps: kbps, durationMs: durationMs)
    }

    private static func open(_ url: URL) -> ExtAudioFileRef? {
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr else { return nil }
        return ref
    }

    private static func property<T>(_ file: ExtAudioFileRef, _ id: ExtAudioFilePropertyID, _ type: T.Type) -> T? {
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard ExtAudioFileGetProperty(file, id, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func maximizeResamplerQuality(_ file: ExtAudioFileRef) {
        guard let converter = property(file, kExtAudioFileProperty_AudioConverter, AudioConverterRef.self) else { return }
        var quality = UInt32(kAudioConverterQuality_Max)
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, UInt32(MemoryLayout<UInt32>.size), &quality)
        var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
        AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity, UInt32(MemoryLayout<UInt32>.size), &complexity)
        var config: CFPropertyList?
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFPropertyList?>.size), &config)
    }

    private static func check(_ status: OSStatus, _ url: URL) throws {
        if status != noErr { throw MediaError.unreadable(url) }
    }

    private static func encode(_ info: MediaInfo, to output: URL, progress: (Double) -> Void) throws -> Int64 {
        guard let input = open(info.url) else { throw MediaError.unreadable(info.url) }
        defer { ExtAudioFileDispose(input) }
        guard let sourceFormat = property(input, kExtAudioFileProperty_FileDataFormat, AudioStreamBasicDescription.self) else {
            throw MediaError.unreadable(info.url)
        }
        let channels = sourceFormat.mChannelsPerFrame
        guard channels == 1 || channels == 2 else {
            throw MediaError.unsupported("\(channels) channels (only mono and stereo are supported)")
        }

        var client = AudioStreamBasicDescription(
            mSampleRate: targetRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileSetProperty(input, kExtAudioFileProperty_ClientDataFormat, clientSize, &client), info.url)
        maximizeResamplerQuality(input)

        var destination = AudioStreamBasicDescription(
            mSampleRate: targetRate, mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: UInt32(kAppleLosslessFormatFlag_16BitSourceData),
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &destination, nil, AudioFileFlags.eraseFile.rawValue, &ref), output)
        guard let out = ref else { throw MediaError.unreadable(output) }
        var disposed = false
        defer { if !disposed { ExtAudioFileDispose(out) } }
        try check(ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat, clientSize, &client), output)

        let sourceFrames = property(input, kExtAudioFileProperty_FileLengthFrames, Int64.self) ?? 0
        let expected = sourceFormat.mSampleRate > 0 ? Double(sourceFrames) * targetRate / sourceFormat.mSampleRate : 0
        var buffer = [Float](repeating: 0, count: Int(chunkFrames * channels))
        var total: Int64 = 0
        var lastFraction = 0.0

        while true {
            try Task.checkCancellation()
            var frames = chunkFrames
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                let read = ExtAudioFileRead(input, &frames, &list)
                if read != noErr || frames == 0 { return read }
                list.mBuffers.mDataByteSize = frames * 4 * channels
                return ExtAudioFileWrite(out, frames, &list)
            }
            try check(status, info.url)
            if frames == 0 { break }
            total += Int64(frames)
            if expected > 0 {
                lastFraction = max(lastFraction, min(Double(total) / expected, 0.999))
                progress(lastFraction)
            }
        }
        try Task.checkCancellation()
        disposed = true
        try check(ExtAudioFileDispose(out), output)
        progress(1)
        return total
    }
}
