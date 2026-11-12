import AppKit
import ConnectorCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ConnectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var ui = UIState()

    init() {
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[flag + 1]
            let empty = CommandLine.arguments.contains("--empty")
            let showLog = CommandLine.arguments.contains("--log")
            let showAbout = CommandLine.arguments.contains("--about")
            var scroll: CGFloat = 0
            if let i = CommandLine.arguments.firstIndex(of: "--scroll"), i + 1 < CommandLine.arguments.count { scroll = CGFloat(Double(CommandLine.arguments[i + 1]) ?? 0) }
            MainActor.assumeIsolated { renderSnapshot(to: path, empty: empty, scroll: scroll, showLog: showLog, showAbout: showAbout) }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Connector") {
            MainWindow(model: model, ui: ui)
                .onAppear {
                    if let raw = UserDefaults.standard.string(forKey: "LibrarySort"), let saved = LibrarySort(rawValue: raw) { model.setSort(saved) }
                    model.refreshDevice()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.refreshDevice() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                    model.refreshDevice()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 560)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Connector") { ui.showingAbout = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add…") { presentAddPanel(model) }
                    .keyboardShortcut("o")
                    .disabled(!model.canAdd)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Select All") { model.selection = Set(model.tracks.map(\.id)) }
                    .keyboardShortcut("a")
                    .disabled(model.tracks.isEmpty)
                Button("Delete") { ui.requestDelete(model) }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.canRemove)
            }
            CommandMenu("iPod") {
                Button("Last Batch Log") { ui.showingLog.toggle() }
                    .keyboardShortcut("l")
                    .disabled(model.log.isEmpty)
                Button("Eject") { Task { await model.eject() } }
                    .keyboardShortcut("e")
                    .disabled(!model.canEject)
            }
        }
    }
}
