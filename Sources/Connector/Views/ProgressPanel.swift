import ConnectorCore
import SwiftUI

struct ProgressPanel: View {
    var progress: SyncProgress
    var queued = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(progress.phase) \(progress.current) of \(progress.total)\(progress.phase == "Converting" ? " · FLAC → ALAC 16/44" : "")\(queued > 0 ? " · \(queued) more queued" : "")")
                .font(S7.title(11))
            S7ProgressBar(fraction: progress.fraction)
        }
        .foregroundStyle(S7.ink)
    }
}
