import AppKit
import ConnectorCore
import SwiftUI

@MainActor
func renderSnapshot(to path: String, empty: Bool, scroll: CGFloat = 0, showLog: Bool = false, showAbout: Bool = false) {
    let model = AppModel(volumesRoot: URL(fileURLWithPath: "/nonexistent"))
    if !empty {
        let names = ["Queendom", "Forgotten Love", "Gentle Earthquakes", "All Is Soft Inside", "It Happened Quiet", "Churchyard", "Soft Universe", "Runaway", "Conqueror", "Running With The Wolves", "Lucky", "Winter Bird", "Home", "Murder Song", "Under The Water", "Cure For Me", "Heathens", "The Seed"]
        let albumNames = ["Infections Of A Different Kind", "The Gods We Can Touch", "What Happened To The Heart"]
        let tracks = (names + names + names).enumerated().map { i, n in
            Track(id: UInt32(i + 1), dbid: UInt64(i + 1), title: n, artist: "AURORA", album: albumNames[i / names.count], albumArtist: "AURORA", genre: "", filetype: "", location: "", trackNumber: i % names.count + 1, trackCount: 0, discNumber: 1, discCount: 1, year: 2018, durationMs: UInt32(180_000 + i * 7_300), size: 0, bitrate: 0, sampleRate: 44100, artworkId: nil, playCount: 0, lastPlayed: nil, rating: 0, skipCount: 0, timeAdded: UInt32(1000 * (i / names.count)))
        }
        let device = IPodDevice(volume: URL(fileURLWithPath: "/Volumes/iPod"), name: "iPod", modelNumber: nil, capacityBytes: 123_490_000_000, freeBytes: 108_700_000_000)
        var entries: [LogEntry] = []
        func add(_ kind: LogEntry.Kind, _ text: String) { entries.append(LogEntry(id: entries.count + 1, kind: kind, text: text)) }
        add(.info, "Adding 1 item")
        for (i, n) in names.prefix(8).enumerated() { add(.info, "Converting \(i + 1)/8: \(String(format: "%02d", i + 1)). \(n).flac") }
        for (i, n) in names.prefix(6).enumerated() { add(.info, "Copying \(i + 1)/8: \(String(format: "%02d", i + 1)). \(n).flac") }
        for n in names.prefix(5) { add(.ok, "Added: AURORA — \(n)") }
        add(.skip, "Duplicate, skipped: 03. Gentle Earthquakes.flac")
        add(.error, "Failed: 07. Soft Universe.flac — unreadable")
        add(.info, "Done. Added: 5 · Duplicates skipped: 1 · Failed: 1")
        model.setPreview(device: device, tracks: tracks, selection: [2, 3, 4], progress: SyncProgress(phase: "Converting", current: 3, total: 8, fraction: 0.4), report: nil, log: entries, deviceName: "My iPod")
    }
    let ui = UIState()
    ui.showingLog = showLog
    ui.showingAbout = showAbout
    let view = MainWindow(model: model, ui: ui).frame(width: 560, height: 560)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    if scroll > 0, let scrollView = findScrollView(in: host) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

@MainActor
private func findScrollView(in view: NSView) -> NSScrollView? {
    if let found = view as? NSScrollView { return found }
    for sub in view.subviews { if let found = findScrollView(in: sub) { return found } }
    return nil
}
