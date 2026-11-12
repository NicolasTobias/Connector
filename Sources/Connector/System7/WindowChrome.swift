import AppKit
import SwiftUI

struct WindowChrome<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: title)
            Rectangle().fill(S7.ink).frame(height: 1)
            content
        }
        .background(S7.paper)
        .overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) { ResizeCorner() }
        .background(WindowConfigurator())
    }
}

private struct TitleBar: View {
    var title: String

    var body: some View {
        ZStack {
            Stripes(horizontal: true).padding(.vertical, 3)
            Text(title)
                .font(S7.title(12))
                .padding(.horizontal, 8)
                .background(S7.paper)
            HStack {
                Box { NSApp.keyWindow?.close() }
                Spacer()
                Box(zoom: true) { NSApp.keyWindow?.zoom(nil) }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 22)
        .background(S7.paper)
    }

    private struct Box: View {
        var zoom = false
        var action: () -> Void
        @State private var pressed = false

        var body: some View {
            ZStack {
                Rectangle().fill(pressed ? S7.ink : S7.paper)
                Rectangle().stroke(S7.ink, lineWidth: 1)
                if zoom {
                    Rectangle().stroke(pressed ? S7.paper : S7.ink, lineWidth: 1).frame(width: 5, height: 5).offset(x: -1.5, y: 1.5)
                }
            }
            .frame(width: 13, height: 13)
            .background(S7.paper)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false; action() }
            )
        }
    }
}

private struct ResizeCorner: View {
    var body: some View {
        ZStack {
            S7.paper
            Rectangle().stroke(S7.ink, lineWidth: 1).frame(width: 9, height: 9).offset(x: -2, y: -2)
            Rectangle().fill(S7.paper).stroke(S7.ink, lineWidth: 1).frame(width: 6, height: 6).offset(x: 2, y: 2)
        }
        .frame(width: 15, height: 15)
        .overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.hasShadow = true
        window.appearance = NSAppearance(named: .aqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}
