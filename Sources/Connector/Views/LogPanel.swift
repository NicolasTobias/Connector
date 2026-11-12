import AppKit
import ConnectorCore
import SwiftUI

struct LogButton: View {
    var active: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            LogGlyph()
                .foregroundStyle(active ? S7.paper : S7.ink)
                .frame(width: 22, height: 22)
                .background(active ? S7.ink : S7.paper)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(S7.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help("Last batch log")
    }
}

private struct LogGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w: CGFloat = 10, h: CGFloat = 14
            let x = (size.width - w) / 2, y = (size.height - h) / 2
            var page = Path()
            page.move(to: CGPoint(x: x, y: y))
            page.addLine(to: CGPoint(x: x + w - 3, y: y))
            page.addLine(to: CGPoint(x: x + w, y: y + 3))
            page.addLine(to: CGPoint(x: x + w, y: y + h))
            page.addLine(to: CGPoint(x: x, y: y + h))
            page.closeSubpath()
            context.stroke(page, with: .foreground, lineWidth: 1)
            var fold = Path()
            fold.move(to: CGPoint(x: x + w - 3, y: y))
            fold.addLine(to: CGPoint(x: x + w - 3, y: y + 3))
            fold.addLine(to: CGPoint(x: x + w, y: y + 3))
            context.stroke(fold, with: .foreground, lineWidth: 1)
            for line in 0..<4 {
                let ly = y + 6 + CGFloat(line) * 2
                context.fill(Path(CGRect(x: x + 2, y: ly, width: line == 3 ? 4 : w - 4, height: 1)), with: .foreground)
            }
        }
    }
}

struct LogPanel: View {
    var model: AppModel
    var close: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        S7Dialog {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.busy ? "Log · in progress" : "Last batch log")
                    .font(S7.title(12)).foregroundStyle(S7.ink)
                S7ScrollList(count: model.log.count, rowHeight: 16, emptyText: "No activity yet", followTail: true) { index in
                    if index < model.log.count {
                        let entry = model.log[index]
                        let inverted = entry.kind == .error
                        HStack(spacing: 8) {
                            Text(Self.time.string(from: entry.date))
                            Text(entry.text).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(S7.text(11))
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .foregroundStyle(inverted ? S7.paper : S7.ink)
                        .background(inverted ? S7.ink : S7.paper)
                        .help(entry.text)
                    }
                }
                .frame(width: 470, height: 256)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logText, forType: .string)
                    }
                    .buttonStyle(S7ButtonStyle()).disabled(model.log.isEmpty)
                    Spacer()
                    Button("Close", action: close).buttonStyle(S7ButtonStyle(isDefault: true))
                }
            }
            .frame(width: 470)
        }
    }
}
