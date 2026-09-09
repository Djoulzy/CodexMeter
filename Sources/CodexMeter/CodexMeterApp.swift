import SwiftUI
import AppKit

@main
struct CodexMeterApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Codex Meter") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear { NSApplication.shared.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Exporter la sélection en CSV…") { model.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Actualiser") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}
