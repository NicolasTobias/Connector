import AppKit
import SwiftUI

struct ScrollObserver: NSViewRepresentable {
    var onChange: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ObserverView: NSView {
        var onChange: ((CGFloat, CGFloat) -> Void)?
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
        private weak var observed: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        private func attach() {
            guard observed == nil else { return }
            guard let clip = enclosingScrollView?.contentView else {
                DispatchQueue.main.async { [weak self] in self?.attach() }
                return
            }
            observed = clip
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        func report() {
            guard let clip = observed else { return }
            onChange?(clip.bounds.origin.y, clip.bounds.height)
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct S7ScrollList<Row: View>: View {
    var count: Int
    var rowHeight: CGFloat
    var emptyText: String?
    var followTail: Bool
    var row: (Int) -> Row

    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var scrollTarget: Int?

    init(count: Int, rowHeight: CGFloat = 16, emptyText: String? = nil, followTail: Bool = false, @ViewBuilder row: @escaping (Int) -> Row) {
        self.count = count
        self.rowHeight = rowHeight
        self.emptyText = emptyText
        self.followTail = followTail
        self.row = row
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(0..<count), id: \.self) { index in
                            row(index).frame(height: rowHeight).id(index)
                        }
                    }
                    .background(ScrollObserver { newOffset, newViewport in
                        if offset != newOffset { offset = newOffset }
                        if viewport != newViewport { viewport = newViewport }
                    })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: scrollTarget) { _, target in
                    if let target { proxy.scrollTo(target, anchor: .top) }
                }
                .onChange(of: count) { _, new in
                    if followTail && new > 0 { proxy.scrollTo(new - 1, anchor: .bottom) }
                }
                .overlay {
                    if count == 0, let emptyText {
                        Text(emptyText).font(S7.title(13)).foregroundStyle(S7.ink)
                    }
                }
            }
            .background(S7.paper)
            Rectangle().fill(S7.ink).frame(width: 1)
            ScrollBar(count: count, rowHeight: rowHeight, offset: offset, viewport: viewport) { scrollTarget = $0 }
                .frame(width: 16)
        }
        .overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
    }
}

struct ScrollBar: View {
    var count: Int
    var rowHeight: CGFloat
    var offset: CGFloat
    var viewport: CGFloat
    var scrollTo: (Int) -> Void

    private var content: CGFloat { CGFloat(count) * rowHeight }
    private var maxOffset: CGFloat { max(0, content - viewport) }
    private var visibleRows: Int { Int(viewport / rowHeight) }
    private var topRow: Int { Int((offset / rowHeight).rounded()) }

    private func arrow(_ up: Bool) -> some View {
        ZStack {
            S7.paper
            Path { p in
                if up {
                    p.move(to: CGPoint(x: 8, y: 4)); p.addLine(to: CGPoint(x: 3, y: 10)); p.addLine(to: CGPoint(x: 13, y: 10))
                } else {
                    p.move(to: CGPoint(x: 8, y: 10)); p.addLine(to: CGPoint(x: 3, y: 4)); p.addLine(to: CGPoint(x: 13, y: 4))
                }
                p.closeSubpath()
            }
            .fill(S7.ink)
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .onTapGesture { scrollTo(max(0, min(max(0, count - visibleRows), topRow + (up ? -1 : 1)))) }
    }

    var body: some View {
        VStack(spacing: 0) {
            arrow(true)
            Rectangle().fill(S7.ink).frame(height: 1)
            GeometryReader { geo in
                let track = geo.size.height
                let enabled = maxOffset > 0
                let thumb = enabled ? max(16, track * viewport / content) : 0
                let y = enabled ? (track - thumb) * min(1, max(0, offset / maxOffset)) : 0
                ZStack(alignment: .top) {
                    S7.paper
                    Dither().opacity(enabled ? 1 : 0)
                    if enabled {
                        Rectangle().fill(S7.paper).overlay(Rectangle().stroke(S7.ink, lineWidth: 1))
                            .frame(height: thumb).offset(y: y)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard enabled else { return }
                    let fraction = min(1, max(0, (value.location.y - thumb / 2) / max(1, track - thumb)))
                    scrollTo(Int((fraction * Double(max(0, count - visibleRows))).rounded()))
                })
            }
            Rectangle().fill(S7.ink).frame(height: 1)
            arrow(false)
        }
    }
}
