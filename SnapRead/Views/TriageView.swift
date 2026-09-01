import AppKit
import SwiftUI

/// Top-level view: switches between authorization, scanning, review,
/// and terminal states.
struct TriageView: View {
    @Environment(TriageStore.self) private var store

    var body: some View {
        Group {
            switch store.phase {
            case .launching, .scanning:
                ProgressView("Scanning screenshots…")
            case .requestingAuthorization:
                ProgressView("Waiting for Photos access…")
            case .denied:
                AccessDeniedView()
            case .reviewing:
                ReviewView()
            case .finished, .empty:
                FinishedView()
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}

/// The one-at-a-time review screen.
struct ReviewView: View {
    @Environment(TriageStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let item = store.currentItem {
                HStack(spacing: 0) {
                    ScreenshotPane(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.04))
                    Divider()
                    InterpretationPanel(item: item)
                        .frame(width: 340)
                }
                Divider()
                ActionBar(item: item)
            }
        }
    }
}

/// Large screenshot preview with loading states.
struct ScreenshotPane: View {
    let item: ScreenshotItem

    var body: some View {
        Group {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 4)
                    .padding(20)
            } else {
                switch item.phase {
                case .loadingImage(let fraction) where fraction > 0:
                    VStack(spacing: 10) {
                        ProgressView(value: fraction)
                            .frame(width: 180)
                        Text("Downloading from iCloud…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                default:
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar: counter, pending deletions, and the triage actions
/// with their keyboard shortcuts.
struct ActionBar: View {
    @Environment(TriageStore.self) private var store
    let item: ScreenshotItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(store.currentIndex + 1) of \(store.queue.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if !store.pendingDeletions.isEmpty {
                Label("\(store.pendingDeletions.count) to delete", systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                openFirstURL()
            } label: {
                Label("Open", systemImage: "safari")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(item.urls.isEmpty)
            .help("Open the first link in your browser (Return)")

            Button {
                copyToPasteboard(item.urls.first?.absoluteString ?? item.ocrText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [])
            .disabled(item.urls.isEmpty && item.ocrText.isEmpty)
            .help("Copy the first link, or the text if there is none (C)")

            Divider().frame(height: 16)

            Button {
                store.goBack()
            } label: {
                Label("Newer", systemImage: "arrow.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(store.currentIndex == 0)
            .help("Go back to the newer screenshot (←)")

            Button {
                store.skip()
            } label: {
                Label("Older", systemImage: "arrow.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Move on to the older screenshot — this one stays in the inbox (→ or Space)")

            Button {
                store.archive()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .keyboardShortcut("a", modifiers: [])
            .help("Done with it, keep the photo (A)")

            Button(role: .destructive) {
                store.markForDeletion()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help("Mark for deletion from Photos — applied in one batch at the end (⌫)")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(12)
        .background {
            // Extra shortcuts that duplicate button actions.
            Group {
                Button("") { store.skip() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { openFirstURL() }
                    .keyboardShortcut("o", modifiers: [])
                Button("") { copyToPasteboard(item.ocrText) }
                    .keyboardShortcut("c", modifiers: .shift)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private func openFirstURL() {
        guard let url = item.urls.first else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ string: String) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Shown when Photos access was denied.
struct AccessDeniedView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("SnapRead needs access to your Photos library")
                .font(.title3.bold())
            Text("Grant Full Access in System Settings → Privacy & Security → Photos, then relaunch SnapRead.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(40)
    }
}
