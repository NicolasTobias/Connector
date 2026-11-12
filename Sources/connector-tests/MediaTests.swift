import Foundation
import ConnectorCore

enum MediaTests {
    static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map { $0.value } }

    static let all: [TestCase] = [
        TestCase(name: "media: flac 24/96 con etiquetas") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("01 Airbag.flac")
            try makeFLAC(at: url, rate: 96000, bits: 24, tags: ["TITLE": "Airbag", "ARTIST": "Radiohead", "TRACKNUMBER": "1/12", "date": "1997-05-21", "DISCNUMBER": "2/3"], picture: nil)
            let info = try await MediaReader.read(url)
            expect(info.kind == .flac)
            expect(info.kind.isLossless)
            expectEqual(info.sampleRate, 96000)
            expectEqual(info.bitsPerChannel, 24)
            expectEqual(info.channels, 2)
            expectEqual(info.trackNumber, 1)
            expectEqual(info.trackCount, 12)
            expectEqual(info.discNumber, 2)
            expectEqual(info.discCount, 3)
            expectEqual(info.year, 1997)
            expectEqual(info.title, "Airbag")
            expectEqual(info.artist, "Radiohead")
            expect(abs(Int(info.durationMs) - 500) <= 5, "duración \(info.durationMs)")
            expect(info.bitrateKbps > 0)
        },
        TestCase(name: "media: carátula incrustada") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.flac")
            let jpeg = makeJPEG(size: 64)
            try makeFLAC(at: url, rate: 44100, bits: 16, tags: ["TITLE": "A"], picture: jpeg)
            let info = try await MediaReader.read(url)
            expect(info.cover == jpeg, "bytes de la carátula")
            expect(CoverLocator.cover(for: info) == jpeg)
        },
        TestCase(name: "media: carátula de carpeta") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.flac")
            let jpeg = makeJPEG(size: 32)
            try makeFLAC(at: url, rate: 44100, bits: 16, tags: ["TITLE": "A"], picture: nil)
            try jpeg.write(to: dir.appendingPathComponent("Folder.JPG"))
            let info = try await MediaReader.read(url)
            expect(info.cover == nil)
            expect(CoverLocator.cover(for: info) == jpeg)
        },
        TestCase(name: "media: sin etiquetas usa el nombre de fichero") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("03 - Mysterons.wav")
            try makeWAV(at: url, seconds: 0.2, rate: 44100, bits: 16)
            let info = try await MediaReader.read(url)
            expectEqual(info.title, "Mysterons")
            expect(info.kind == .wav)
        },
        TestCase(name: "media: ogg rechazado") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("x.ogg")
            try Data([1, 2, 3]).write(to: url)
            do {
                _ = try await MediaReader.read(url)
                expect(false, "se esperaba un error")
            } catch MediaError.unsupported(let ext) {
                expectEqual(ext, "ogg")
            }
        },
        TestCase(name: "media: flac truncado lanza error") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.flac")
            try makeFLAC(at: url, rate: 44100, bits: 16, tags: ["TITLE": "A"], picture: makeJPEG(size: 32))
            let full = try Data(contentsOf: url)
            for cut in [0, 3, 4, 6, 20, 60, 120] {
                let broken = dir.appendingPathComponent("b\(cut).flac")
                try full.prefix(cut).write(to: broken)
                await expectThrows({ _ = try await MediaReader.read(broken) }, "corte en \(cut)")
            }
            var bad = full
            bad[0] = 0x58
            let badURL = dir.appendingPathComponent("bad.flac")
            try bad.write(to: badURL)
            await expectThrows({ _ = try await MediaReader.read(badURL) }, "marcador")
        },
        TestCase(name: "media: wav 16/44.1 estéreo") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.wav")
            try makeWAV(at: url, seconds: 1, rate: 44100, bits: 16)
            let info = try await MediaReader.read(url)
            expectEqual(info.sampleRate, 44100)
            expectEqual(info.bitsPerChannel, 16)
            expectEqual(info.channels, 2)
            expect(abs(Int(info.durationMs) - 1000) <= 5, "duración \(info.durationMs)")
            expect(info.bitrateKbps >= 1400 && info.bitrateKbps <= 1460, "bitrate \(info.bitrateKbps)")
        },
        TestCase(name: "media: etiquetas con acentos en NFD se conservan") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.flac")
            let nfd = "Cafe\u{301} del Mar \u{4E2D}"
            try makeFLAC(at: url, rate: 44100, bits: 16, tags: ["TITLE": nfd, "ARTIST": "Beyonce\u{301}"], picture: nil)
            let info = try await MediaReader.read(url)
            expectEqual(scalars(info.title), scalars(nfd))
            expectEqual(scalars(info.artist), scalars("Beyonce\u{301}"))
        },
        TestCase(name: "media: m4a aac") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.m4a")
            try makeM4A(at: url, alac: false, rate: 44100, bits: 16, seconds: 0.5)
            let info = try await MediaReader.read(url)
            expect(info.kind == .aac)
            expect(!info.kind.isLossless)
            expectEqual(info.sampleRate, 44100)
            expectEqual(info.channels, 2)
        },
        TestCase(name: "media: m4a alac 16 y 24 bits") {
            let dir = try tempDir()
            for bits in [16, 24] {
                let url = dir.appendingPathComponent("a\(bits).m4a")
                try makeM4A(at: url, alac: true, rate: 48000, bits: bits, seconds: 0.5)
                let info = try await MediaReader.read(url)
                expect(info.kind == .alac, "kind \(bits)")
                expectEqual(info.bitsPerChannel, bits)
                expectEqual(info.sampleRate, 48000)
            }
        },
        TestCase(name: "media: aiff") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.aiff")
            try makeAIFF(at: url, rate: 44100, bits: 16, seconds: 0.5)
            let info = try await MediaReader.read(url)
            expect(info.kind == .aiff)
            expectEqual(info.bitsPerChannel, 16)
            expectEqual(info.channels, 2)
            expect(abs(Int(info.durationMs) - 500) <= 5, "duración \(info.durationMs)")
        },
        TestCase(name: "media: m4a truncado lanza error") {
            let dir = try tempDir()
            let url = dir.appendingPathComponent("a.m4a")
            try makeM4A(at: url, alac: false, rate: 44100, bits: 16, seconds: 0.5)
            let broken = dir.appendingPathComponent("b.m4a")
            try Data(contentsOf: url).prefix(20).write(to: broken)
            do {
                _ = try await MediaReader.read(broken)
                expect(false, "se esperaba un error")
            } catch MediaError.unreadable {
            }
        },
    ]
}
