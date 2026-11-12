import ConnectorCore
import SwiftUI

struct StatusPanel<Accessory: View>: View {
    var model: AppModel
    @ViewBuilder var accessory: Accessory

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let device = model.device {
                Text("\(model.displayName) — \(gb(device.capacityBytes)) GB").font(S7.title(12))
                HStack(spacing: 10) { S7ProgressBar(fraction: model.usedFraction); accessory }
                Text("Used \(gb(model.usedBytes)) of \(gb(device.capacityBytes)) GB").font(S7.text(11))
            } else {
                Text("No iPod").font(S7.title(12))
                HStack(spacing: 10) { S7ProgressBar(fraction: 0); accessory }
                Text(" ").font(S7.text(11))
            }
        }
        .foregroundStyle(S7.ink)
    }
}
