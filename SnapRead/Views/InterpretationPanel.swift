import AppKit
import SwiftUI

/// Right-hand panel: what the screenshot is, its links, and the raw OCR text.
struct InterpretationPanel: View {
    @Environment(TriageStore.self) private var store
    let item: ScreenshotItem
    @State private var showOCRText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let interpretation = item.interpretation {
                    CategoryBadge(category: interpretation.category)

                    Text(interpretation.title)
                        .font(.title3.bold())
                        .textSelection(.enabled)

                    Text(interpretation.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if interpretation.source == .heuristic {
                        Label("Basic analysis (Apple Intelligence unavailable)", systemImage: "gearshape.2")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    switch item.phase {
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Analysis failed", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                store.retry(item)
                            }
                        }
                    case .analyzing, .loadingImage, .queued:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(item.phase == .analyzing ? "Interpreting…" : "Preparing screenshot…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    case .ready:
                        EmptyView()
                    }
                }

                if !item.urls.isEmpty {
                    Divider()
                    Text("Links")
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    ForEach(item.urls, id: \.absoluteString) { url in
                        LinkRow(url: url)
                    }
                }

                if !item.ocrText.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showOCRText) {
                        Text(item.ocrText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Recognized text")
                            .font(.caption.smallCaps())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CategoryBadge: View {
    let category: ContentCategory

    var body: some View {
        Label(category.label, systemImage: category.systemImage)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(category.color, in: Capsule())
    }
}

struct LinkRow: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Open in browser")

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy link")
        }
    }
}
