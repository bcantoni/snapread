import SwiftUI

@main
struct SnapReadApp: App {
    @State private var store = TriageStore()

    var body: some Scene {
        WindowGroup {
            TriageView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 560)
                .task { await store.start() }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Triage") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
