import AppKit
import ConnectorCore
import SwiftUI

@MainActor
@Observable
final class UIState {
    var confirmingDelete = false
    var showingLog = false
    var showingAbout = false

    func requestDelete(_ model: AppModel) {
        if model.canRemove { confirmingDelete = true }
    }
}

@MainActor
func presentAddPanel(_ model: AppModel) {
    guard model.canAdd else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.prompt = "Add"
    if panel.runModal() == .OK { Task { await model.add(panel.urls) } }
}

struct MainWindow: View {
    var model: AppModel
    var ui: UIState

    var body: some View {
        WindowChrome(title: "Connector") {
            VStack(spacing: 10) {
                StatusPanel(model: model) {
                    LogButton(active: model.busy, enabled: !model.log.isEmpty) { ui.showingLog.toggle() }
                }
                DropZone(model: model)
                if let progress = model.progress { ProgressPanel(progress: progress) }
                if model.device != nil {
                    HStack {
                        Text("\(model.albums.count) \(model.albums.count == 1 ? "album" : "albums") · \(model.tracks.count) \(model.tracks.count == 1 ? "song" : "songs")")
                            .font(S7.text(11)).foregroundStyle(S7.ink)
                        Spacer()
                        Button(model.collapsed.count == model.albums.count && !model.albums.isEmpty ? "Expand" : "Collapse") {
                            if model.collapsed.count == model.albums.count { model.expandAll() } else { model.collapseAll() }
                        }
                        .buttonStyle(S7ButtonStyle()).disabled(model.albums.isEmpty)
                        S7Segmented(options: [("A–Z", LibrarySort.album), ("Recent", LibrarySort.recent)], selection: model.sort) { value in
                            model.setSort(value)
                            UserDefaults.standard.set(value.rawValue, forKey: "LibrarySort")
                        }
                    }
                }
                TrackList(model: model)
                if let text = model.error ?? model.reportText {
                    Text(text).font(S7.text(11)).foregroundStyle(S7.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                }
                HStack {
                    Button("Delete") { ui.requestDelete(model) }
                        .buttonStyle(S7ButtonStyle()).disabled(!model.canRemove)
                    Button("Eject") { Task { await model.eject() } }
                        .buttonStyle(S7ButtonStyle()).disabled(!model.canEject)
                    Spacer()
                    Button("Add…") { presentAddPanel(model) }
                        .buttonStyle(S7ButtonStyle(isDefault: true)).disabled(!model.canAdd)
                }
            }
            .padding(12)
        }
        .overlay {
            if ui.showingAbout {
                ZStack {
                    Color.white.opacity(0.6)
                    AboutPanel { ui.showingAbout = false }
                }
            }
        }
        .overlay {
            if ui.showingLog {
                ZStack {
                    Color.white.opacity(0.6)
                    LogPanel(model: model) { ui.showingLog = false }
                }
            }
        }
        .overlay {
            if ui.confirmingDelete {
                ZStack {
                    Color.white.opacity(0.6)
                    S7Dialog {
                        VStack(spacing: 14) {
                            Text("Delete \(model.selection.count) \(model.selection.count == 1 ? "song" : "songs") from the iPod?")
                                .font(S7.title(12)).foregroundStyle(S7.ink)
                            HStack(spacing: 12) {
                                Button("Cancel") { ui.confirmingDelete = false }.buttonStyle(S7ButtonStyle())
                                Button("Delete") {
                                    ui.confirmingDelete = false
                                    Task { await model.removeSelected() }
                                }
                                .buttonStyle(S7ButtonStyle(isDefault: true))
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
    }
}
