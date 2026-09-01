import SwiftUI

@MainActor
final class SnapReadAppDelegate: NSObject, NSApplicationDelegate {
    var store: TriageStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.pendingDeletions.isEmpty else {
            return .terminateNow
        }

        Task {
            await store.commitDeletions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct SnapReadApp: App {
    @NSApplicationDelegateAdaptor(SnapReadAppDelegate.self) private var appDelegate
    @State private var store = TriageStore()

    var body: some Scene {
        WindowGroup {
            TriageView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.store = store }
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
