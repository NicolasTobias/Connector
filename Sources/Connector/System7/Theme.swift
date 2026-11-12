import AppKit
import SwiftUI

enum S7 {
    static let ink = Color.black
    static let paper = Color.white

    static let defaultTitleFont = "Geneva"

    static var titleFontName: String {
        UserDefaults.standard.string(forKey: "TitleFont") ?? defaultTitleFont
    }

    static func title(_ size: CGFloat) -> Font {
        let name = titleFontName
        if NSFont(name: name, size: size) != nil {
            return name == "Geneva" ? .custom(name, size: size).bold() : .custom(name, size: size)
        }
        return .system(size: size, weight: .bold, design: .monospaced)
    }

    static func text(_ size: CGFloat) -> Font {
        let name = titleFontName
        if name != defaultTitleFont, NSFont(name: name, size: 12) != nil { return .custom(name, size: 12) }
        return geneva(size)
    }

    static func geneva(_ size: CGFloat) -> Font {
        NSFont(name: "Geneva", size: size) != nil ? .custom("Geneva", size: size) : .system(size: size, design: .monospaced)
    }
}

struct Dither: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
            for y in 0..<h {
                for x in stride(from: y % 2, to: w, by: 2) {
                    path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.fill(path, with: .color(.black))
        }
        .allowsHitTesting(false)
    }
}

struct Stripes: View {
    var horizontal = false
    var spacing: CGFloat = 3
    var body: some View {
        Canvas { context, size in
            var path = Path()
            if horizontal {
                var y: CGFloat = 0
                while y < size.height {
                    path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                    y += 2
                }
            } else {
                var x: CGFloat = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += spacing
                }
                context.stroke(path, with: .color(.black), lineWidth: 1)
                return
            }
            context.fill(path, with: .color(.black))
        }
        .allowsHitTesting(false)
    }
}

struct S7ButtonStyle: ButtonStyle {
    var isDefault = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(S7.title(12))
            .foregroundStyle(pressed ? S7.paper : S7.ink)
            .padding(.horizontal, 14)
            .frame(minWidth: 72, minHeight: 22)
            .background(pressed ? S7.ink : S7.paper)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(S7.ink, lineWidth: 1))
            .padding(isDefault ? 3 : 0)
            .overlay {
                if isDefault { RoundedRectangle(cornerRadius: 9).stroke(S7.ink, lineWidth: 1) }
            }
            .opacity(enabled ? 1 : 0.4)
    }
}

struct S7ProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                S7.paper
                Stripes()
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
                    .clipped()
                    .overlay(alignment: .trailing) { Rectangle().fill(S7.ink).frame(width: 1) }
            }
            .overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
        }
        .frame(height: 14)
    }
}

struct S7Dialog<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .background { Rectangle().fill(S7.paper).shadow(color: .black, radius: 0, x: 2, y: 2) }
            .overlay(Rectangle().stroke(S7.ink, lineWidth: 2))
            .overlay(Rectangle().stroke(S7.ink, lineWidth: 1).padding(4))
    }
}

struct S7Segmented<Value: Hashable>: View {
    var options: [(label: String, value: Value)]
    var selection: Value
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.value == selection
                Text(option.label)
                    .font(S7.title(11))
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .foregroundStyle(active ? S7.paper : S7.ink)
                    .background(active ? S7.ink : S7.paper)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(option.value) }
                if index < options.count - 1 { Rectangle().fill(S7.ink).frame(width: 1, height: 20) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(S7.ink, lineWidth: 1))
    }
}
