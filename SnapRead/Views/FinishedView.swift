import SwiftUI

/// End-of-queue and empty-inbox state: session summary, apply pending
/// deletions, review skipped items, or rescan.
struct FinishedView: View {
    @Environment(TriageStore.self) private var store
    @State private var committing = false

    private var skippedCount: Int { store.queue.count }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: store.phase == .empty ? "tray" : "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(store.phase == .empty ? Color.secondary : .green)

            Text(store.phase == .empty ? "No new screenshots" : "Inbox reviewed")
                .font(.title2.bold())

            if store.phase == .empty {
                Text("No untriaged screenshots in the last \(store.lookbackDays) days.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    if store.sessionArchived > 0 {
                        Text("\(store.sessionArchived) archived")
                    }
                    if store.sessionDeleted > 0 {
                        Text("\(store.sessionDeleted) deleted from Photos")
                    }
                    if skippedCount > 0 {
                        Text("\(skippedCount) skipped — still in the inbox")
                    }
                }
                .foregroundStyle(.secondary)
            }

            if !store.pendingDeletions.isEmpty {
                Button {
                    committing = true
                    Task {
                        await store.commitDeletions()
                        committing = false
                    }
                } label: {
                    Label(
                        "Delete \(store.pendingDeletions.count) from Photos…",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(committing)

                Text("They'll move to Recently Deleted and sync to your iPhone.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                if skippedCount > 0 {
                    Button("Review Skipped") { store.reviewSkipped() }
                }
                Button("Rescan") {
                    Task { await store.scan() }
                }
                .disabled(!store.pendingDeletions.isEmpty)
                .help("Apply or undo pending deletions before rescanning")
            }
            .padding(.top, 4)
        }
        .padding(40)
        .background {
            Button("") { store.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}
