import ConnectorCore
import SwiftUI

struct DropZone: View {
    var model: AppModel
    @State private var targeted = false

    var body: some View {
        let active = targeted && model.canAdd
        ZStack {
            Rectangle().fill(active ? S7.ink : S7.paper)
            Text("Drop FLAC, ALAC or MP3 here")
                .font(S7.title(12))
                .foregroundStyle(active ? S7.paper : S7.ink)
                .opacity(model.canAdd ? 1 : 0.4)
            Rectangle()
                .strokeBorder(active ? S7.paper : S7.ink, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .padding(4)
        }
        .frame(height: 56)
        .overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAdd else { return false }
            Task { await model.add(urls) }
            return true
        } isTargeted: { targeted = $0 }
    }
}
