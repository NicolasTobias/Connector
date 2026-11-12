import AppKit
import ConnectorCore
import SwiftUI

struct TrackList: View {
    var model: AppModel

    private func duration(_ ms: UInt64) -> String {
        let s = Int((Double(ms) / 1000).rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        S7ScrollList(count: model.rows.count, emptyText: model.device == nil ? "Connect your iPod" : "The iPod has no songs") { index in
            if index < model.rows.count {
                switch model.rows[index] {
                case .album(let group, let expanded):
                    albumRow(group, expanded: expanded)
                case .track(let track, _):
                    trackRow(track)
                }
            }
        }
    }

    private func albumRow(_ group: AlbumGroup, expanded: Bool) -> some View {
        let selected = !group.tracks.isEmpty && group.trackIDs.isSubset(of: model.selection)
        return HStack(spacing: 6) {
            Disclosure(open: expanded)
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleExpanded(group.id) }
            Text("\(group.album) — \(group.artist)").lineLimit(1)
            Spacer(minLength: 8)
            Text("\(group.tracks.count) · \(duration(group.durationMs))")
        }
        .font(S7.text(11))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selected ? S7.paper : S7.ink)
        .background(selected ? S7.ink : S7.paper)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleExpanded(group.id) }
        .onTapGesture { model.clickAlbum(group.id, command: NSEvent.modifierFlags.contains(.command)) }
    }

    private func trackRow(_ track: Track) -> some View {
        let selected = model.selection.contains(track.id)
        let number = track.trackNumber > 0 ? "\(track.trackNumber). " : ""
        let extra = track.artist != Library.artist(of: track) && !track.artist.isEmpty ? " — \(track.artist)" : ""
        return HStack {
            Text("\(number)\(track.title)\(extra)").lineLimit(1)
            Spacer(minLength: 8)
            Text(duration(UInt64(track.durationMs)))
        }
        .font(S7.text(11))
        .padding(.leading, 30)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(selected ? S7.paper : S7.ink)
        .background(selected ? S7.ink : S7.paper)
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.clickTrack(track.id, shift: flags.contains(.shift), command: flags.contains(.command))
        }
    }
}

private struct Disclosure: View {
    var open: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let cx = size.width / 2, cy = size.height / 2
            if open {
                path.move(to: CGPoint(x: cx - 4, y: cy - 2)); path.addLine(to: CGPoint(x: cx + 4, y: cy - 2)); path.addLine(to: CGPoint(x: cx, y: cy + 3))
            } else {
                path.move(to: CGPoint(x: cx - 2, y: cy - 4)); path.addLine(to: CGPoint(x: cx - 2, y: cy + 4)); path.addLine(to: CGPoint(x: cx + 3, y: cy))
            }
            path.closeSubpath()
            context.fill(path, with: .foreground)
        }
    }
}
