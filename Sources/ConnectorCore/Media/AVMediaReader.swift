import AVFoundation
import AudioToolbox
import Foundation

enum AVMediaReader {
    static func read(_ url: URL, ext: String) async throws -> MediaInfo {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaError.unreadable(url) }
        let format = try audioFormat(url)
        let kind: SourceKind
        switch ext {
        case "wav": kind = .wav
        case "aif", "aiff": kind = .aiff
        case "mp3": kind = .mp3
        default: kind = format.mFormatID == kAudioFormatAppleLossless ? .alac : .aac
        }

        let asset = AVURLAsset(url: url)
        let items: [AVMetadataItem]
        let seconds: Double
        do {
            items = try await asset.load(.metadata)
            seconds = try await asset.load(.duration).seconds
        } catch {
            throw MediaError.unreadable(url)
        }

        var info = MediaInfo(url: url, kind: kind)
        info.sampleRate = format.mSampleRate
        info.channels = Int(format.mChannelsPerFrame)
        info.bitsPerChannel = bits(of: format)
        info.durationMs = seconds.isFinite && seconds > 0 ? UInt32(min(seconds * 1000, Double(UInt32.max)).rounded()) : 0
        info.bitrateKbps = MediaInfo.bitrate(url: url, durationMs: info.durationMs)

        info.title = try await string(items, [.commonIdentifierTitle])
        info.artist = try await string(items, [.commonIdentifierArtist])
        info.album = try await string(items, [.commonIdentifierAlbumName])
        info.albumArtist = try await string(items, [.iTunesMetadataAlbumArtist, .id3MetadataBand])
        info.genre = try await string(items, [.iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre])
        if info.title.isEmpty { info.title = MediaInfo.fallbackTitle(for: url) }

        let creation = try await string(items, [.commonIdentifierCreationDate, .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate])
        info.year = MediaInfo.parseYear(creation)

        let track = try await pair(items, text: [.id3MetadataTrackNumber], blob: [.iTunesMetadataTrackNumber])
        (info.trackNumber, info.trackCount) = track
        let disc = try await pair(items, text: [.id3MetadataPartOfASet], blob: [.iTunesMetadataDiscNumber])
        (info.discNumber, info.discCount) = disc

        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                info.cover = data
                break
            }
        }
        return info
    }

    private static func audioFormat(_ url: URL) throws -> AudioStreamBasicDescription {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { throw MediaError.unreadable(url) }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr else {
            throw MediaError.unreadable(url)
        }
        return format
    }

    private static func bits(of format: AudioStreamBasicDescription) -> Int {
        if format.mFormatID == kAudioFormatAppleLossless {
            switch format.mFormatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return 16
            }
        }
        return format.mBitsPerChannel > 0 ? Int(format.mBitsPerChannel) : 16
    }

    private static func string(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async throws -> String {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
            }
        }
        return ""
    }

    private static func pair(_ items: [AVMetadataItem], text: [AVMetadataIdentifier], blob: [AVMetadataIdentifier]) async throws -> (Int, Int) {
        let textual = try await string(items, text)
        if !textual.isEmpty { return MediaInfo.parsePair(textual) }
        for identifier in blob {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let data = try? await item.load(.dataValue), data.count >= 6 {
                    let bytes = [UInt8](data)
                    return (Int(bytes[2]) << 8 | Int(bytes[3]), Int(bytes[4]) << 8 | Int(bytes[5]))
                }
                if let value = try? await item.load(.stringValue) { return MediaInfo.parsePair(value) }
            }
        }
        return (0, 0)
    }
}
