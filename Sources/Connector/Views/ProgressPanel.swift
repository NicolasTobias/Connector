import ConnectorCore
import SwiftUI

struct ProgressPanel: View {
    var progress: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(progress.phase) \(progress.current) of \(progress.total)\(progress.phase == "Converting" ? " · FLAC → ALAC 16/44" : "")")
                .font(S7.title(11))
            S7ProgressBar(fraction: progress.fraction)
        }
        .foregroundStyle(S7.ink)
    }
}
