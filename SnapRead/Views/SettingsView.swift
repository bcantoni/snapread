import SwiftUI

struct SettingsView: View {
    @Environment(TriageStore.self) private var store
    @AppStorage("lookbackDays") private var lookbackDays = 30

    var body: some View {
        Form {
            Stepper(value: $lookbackDays, in: 1...365) {
                Text("Scan the last \(lookbackDays) days")
            }
            Text("Screenshots you've already archived or deleted won't reappear.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Rescan Now") {
                Task { await store.scan() }
            }
            .disabled(!store.pendingDeletions.isEmpty)
            .help("Apply or undo pending deletions before rescanning")
        }
        .padding(20)
        .frame(width: 340)
    }
}
