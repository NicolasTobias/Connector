import AudioToolbox
import Foundation
import ConnectorCore

enum TranscoderTests {
    struct Output {
        var format: AudioStreamBasicDescription
        var frames: Int64
    }

    static func inspect(_ url: URL) throws -> Output {
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr, let file = ref else { throw FixtureError(message: "no se abre \(url.lastPathComponent)") }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        return Output(format: format, frames: frames)
    }

    static func checkALAC(_ prepared: PreparedFile, channels: UInt32, seconds: Double, file: StaticString = #file, line: UInt = #line) throws {
        let out = try inspect(prepared.url)
        expect(out.format.mFormatID == kAudioFormatAppleLossless, "formato", file: file, line: line)
        expectEqual(out.format.mSampleRate, 44100, file: file, line: line)
        expectEqual(out.format.mFormatFlags, UInt32(kAppleLosslessFormatFlag_16BitSourceData), file: file, line: line)
        expectEqual(out.format.mChannelsPerFrame, channels, file: file, line: line)
        let ms = Double(out.frames) / 44100 * 1000
        expect(abs(ms - seconds * 1000) <= 20, "duración \(ms) ms", file: file, line: line)
        expect(abs(Double(prepared.durationMs) - ms) <= 1, "durationMs \(prepared.durationMs)", file: file, line: line)
        expectEqual(prepared.ext, "m4a", file: file, line: line)
        expectEqual(prepared.filetype, "Apple Lossless audio file", file: file, line: line)
        expectEqual(prepared.sampleRate, 44100, file: file, line: line)
        let size = (try FileManager.default.attributesOfItem(atPath: prepared.url.path))[.size] as? NSNumber
        expectEqual(prepared.sizeBytes, size?.uint32Value ?? 0, file: file, line: line)
        expect(prepared.bitrateKbps > 0, "bitrate", file: file, line: line)
    }

    static func peak(of url: URL, skippingFrames skip: Int) throws -> Float {
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr, let file = ref else { throw FixtureError(message: "no se abre \(url.lastPathComponent)") }
        defer { ExtAudioFileDispose(file) }
        var client = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        var buffer = [Float](repeating: 0, count: 8192 * 2)
        var index = 0
        var result: Float = 0
        while true {
            var frames: UInt32 = 8192
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileRead(file, &frames, &list)
            }
            if status != noErr || frames == 0 { break }
            for i in 0..<Int(frames) where index + i >= skip {
                result = max(result, abs(buffer[2 * i]))
            }
            index += Int(frames)
        }
        return result
    }

    final class Collector: @unchecked Sendable {
        var values: [Double] = []
    }

    static let all: [TestCase] = [
        TestCase(name: "transcode: flac 24/96 a alac 16/44.1") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.flac")
            try makeFLAC(at: url, rate: 96000, bits: 24, tags: [:], picture: nil, seconds: 1)
            let info = try await MediaReader.read(url)
            let prepared = try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in })
            try checkALAC(prepared, channels: 2, seconds: 1)
        },
        TestCase(name: "transcode: la banda de paso llega hasta 21 kHz") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("tone.wav")
            try makeWAV(at: url, seconds: 1, rate: 96000, bits: 24, frequency: 21000)
            let info = try await MediaReader.read(url)
            let prepared = try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in })
            let level = try peak(of: prepared.url, skippingFrames: 4410)
            let db = 20 * log10(Double(max(level, 1e-9)) / 0.5)
            expect(db > -3, "21 kHz atenuado a \(db) dB")
        },
        TestCase(name: "transcode: mono se mantiene mono") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("m.wav")
            try makeWAV(at: url, seconds: 1, rate: 48000, bits: 24, channels: 1)
            let info = try await MediaReader.read(url)
            let prepared = try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in })
            try checkALAC(prepared, channels: 1, seconds: 1)
        },
        TestCase(name: "transcode: alac 24/48 también se reduce") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.m4a")
            try makeM4A(at: url, alac: true, rate: 48000, bits: 24, seconds: 1)
            let info = try await MediaReader.read(url)
            expect(info.kind == .alac)
            let prepared = try await Transcoder.prepare(info, workDir: dir, progress: { _ in })
            try checkALAC(prepared, channels: 2, seconds: 1)
        },
        TestCase(name: "transcode: aac se copia sin cambios") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.m4a")
            try makeM4A(at: url, alac: false, rate: 44100, bits: 16, seconds: 1)
            let info = try await MediaReader.read(url)
            expect(info.kind == .aac)
            let prepared = try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in })
            expect(try Data(contentsOf: prepared.url) == Data(contentsOf: url))
            expect(prepared.url != url)
            expectEqual(prepared.ext, "m4a")
            expectEqual(prepared.filetype, "AAC audio file")
            expectEqual(prepared.sampleRate, 44100)
            expect(abs(Int(prepared.durationMs) - 1000) <= 20, "duración \(prepared.durationMs)")
            expect(prepared.bitrateKbps > 0)
        },
        TestCase(name: "transcode: mp3 se copia sin cambios") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.mp3")
            let bytes = Data((0..<4000).map { UInt8($0 % 251) })
            try bytes.write(to: url)
            let info = MediaInfo(url: url, kind: .mp3, durationMs: 1000, sampleRate: 44100, channels: 2)
            let prepared = try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in })
            expect(try Data(contentsOf: prepared.url) == bytes)
            expectEqual(prepared.ext, "mp3")
            expectEqual(prepared.filetype, "MPEG audio file")
            expectEqual(prepared.sizeBytes, 4000)
            expectEqual(prepared.sampleRate, 44100)
            expectEqual(prepared.durationMs, 1000)
            expectEqual(prepared.bitrateKbps, 32)
        },
        TestCase(name: "transcode: estéreo se mantiene estéreo") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.wav")
            try makeWAV(at: url, seconds: 0.5, rate: 44100, bits: 16)
            let info = try await MediaReader.read(url)
            expectEqual(info.channels, 2)
            let prepared = try await Transcoder.prepare(info, workDir: dir, progress: { _ in })
            let out = try inspect(prepared.url)
            expectEqual(out.format.mChannelsPerFrame, 2)
        },
        TestCase(name: "transcode: progreso monótono y termina en 1") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.wav")
            try makeWAV(at: url, seconds: 3, rate: 44100, bits: 16)
            let info = try await MediaReader.read(url)
            let collector = Collector()
            _ = try await Transcoder.prepare(info, workDir: dir, progress: { collector.values.append($0) })
            let values = collector.values
            expect(values.count >= 3, "llamadas \(values.count)")
            expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "monótono")
            expect(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "rango")
            expectEqual(values.last ?? 0, 1.0)
        },
        TestCase(name: "transcode: cancelar borra el parcial") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.wav")
            try makeWAV(at: url, seconds: 5, rate: 44100, bits: 16)
            let info = try await MediaReader.read(url)
            let work = dir.appendingPathComponent("work")
            let task = Task {
                try await Transcoder.prepare(info, workDir: work, progress: { _ in withUnsafeCurrentTask { $0?.cancel() } })
            }
            do {
                _ = try await task.value
                expect(false, "se esperaba cancelación")
            } catch is CancellationError {
            }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            expectEqual(left, [], "restos")
        },
        TestCase(name: "transcode: nombres iguales no colisionan") {
            let dir = try tempDir()
            var preparedURLs: [URL] = []
            for sub in ["a", "b"] {
                let folder = dir.appendingPathComponent(sub)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("01 Same.wav")
                try makeWAV(at: url, seconds: 0.3, rate: 44100, bits: 16)
                let info = try await MediaReader.read(url)
                preparedURLs.append(try await Transcoder.prepare(info, workDir: dir.appendingPathComponent("work"), progress: { _ in }).url)
            }
            expect(preparedURLs[0] != preparedURLs[1])
            expect(preparedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        },
        TestCase(name: "transcode: más de dos canales no se admite") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.wav")
            try makeWAV(at: url, seconds: 0.2, rate: 44100, bits: 16, channels: 6)
            let info = try await MediaReader.read(url)
            do {
                _ = try await Transcoder.prepare(info, workDir: dir, progress: { _ in })
                expect(false, "se esperaba un error")
            } catch MediaError.unsupported(let reason) {
                expect(reason.contains("6 channels"), "motivo: \(reason)")
            }
        },
    ]
}
