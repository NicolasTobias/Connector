import AppKit
import ConnectorCore
import SwiftUI

struct PixelHeart: View {
    private static let rows = [
        ".XX.XX.",
        "XXXXXXX",
        "XXXXXXX",
        ".XXXXX.",
        "..XXX..",
        "...X...",
    ]

    var scale: CGFloat = 3

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for (y, row) in Self.rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "X" {
                    path.addRect(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale))
                }
            }
            context.fill(path, with: .foreground)
        }
        .frame(width: 7 * scale, height: 6 * scale)
        .accessibilityLabel("love")
    }
}

struct AboutPanel: View {
    var close: () -> Void

    var body: some View {
        S7Dialog {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text("Connector").font(S7.title(14))
                Text("Version \(connectorVersion)").font(S7.text(11))
                Rectangle().fill(S7.ink).frame(height: 1)
                HStack(spacing: 6) {
                    Text("Made in Spain with")
                    PixelHeart()
                }
                .font(S7.title(12))
                Text("Your iPod Classic, the old-school way.").font(S7.text(11))
                Button("OK", action: close).buttonStyle(S7ButtonStyle(isDefault: true))
            }
            .foregroundStyle(S7.ink)
            .frame(width: 320)
        }
    }
}
