import AppKit
import Photos
import SwiftUI

/// Owns the triage queue, the persisted record of what's been triaged,
/// and the pending-deletion batch.
@MainActor
@Observable
final class TriageStore {
    enum AppPhase: Equatable {
        case launching
        case requestingAuthorization
        case denied
        case scanning
        case reviewing
        case finished
        case empty
    }

    struct TriageRecord: Codable {
        var status: String  // "archived" | "deleted"
        var date: Date
    }

    private enum UndoAction {
        case archive(ScreenshotItem, index: Int)
        case markDelete(ScreenshotItem, index: Int)
    }

    var phase: AppPhase = .launching
    var queue: [ScreenshotItem] = []
    var currentIndex = 0
    var pendingDeletions: [ScreenshotItem] = []
    var sessionArchived = 0
    var sessionDeleted = 0
    var lastError: String?

    private var records: [String: TriageRecord] = [:]
    private var undoStack: [UndoAction] = []
    private let prefetchDepth = 3

    var currentItem: ScreenshotItem? {
        guard phase == .reviewing, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var canUndo: Bool { !undoStack.isEmpty }

    var lookbackDays: Int {
        UserDefaults.standard.object(forKey: "lookbackDays") as? Int ?? 30
    }

    // MARK: - Lifecycle

    func start() async {
        let service = PhotoLibraryService.shared
        switch service.authorizationStatus() {
        case .notDetermined:
            phase = .requestingAuthorization
            handleAuthorization(await service.requestAuthorization())
        case let status:
            handleAuthorization(status)
        }
    }

    private func handleAuthorization(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            Task { await scan() }
        default:
            phase = .denied
        }
    }

    func scan() async {
        phase = .scanning
        loadRecords()
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: .now) ?? .now
        let assets = PhotoLibraryService.shared.fetchScreenshots(since: cutoff)
        queue = assets
            .filter { records[$0.localIdentifier] == nil }
            .map { ScreenshotItem(asset: $0) }
        currentIndex = 0
        pendingDeletions = []
        undoStack = []
        sessionArchived = 0
        sessionDeleted = 0
        phase = queue.isEmpty ? .empty : .reviewing
        prefetch()
    }

    // MARK: - Triage actions

    func skip() {
        guard currentItem != nil else { return }
        currentIndex += 1
        finishIfPastEnd()
        prefetch()
    }

    /// Step back to the previous item still in the queue. From the
    /// end-of-queue screen this re-enters review at the last item.
    func goBack() {
        switch phase {
        case .reviewing:
            guard currentIndex > 0 else { return }
            currentIndex -= 1
        case .finished:
            guard !queue.isEmpty else { return }
            currentIndex = queue.count - 1
            phase = .reviewing
        default:
            return
        }
        prefetch()
    }

    func archive() {
        guard let item = currentItem else { return }
        queue.remove(at: currentIndex)
        records[item.id] = TriageRecord(status: "archived", date: .now)
        saveRecords()
        sessionArchived += 1
        undoStack.append(.archive(item, index: currentIndex))
        finishIfPastEnd()
        prefetch()
    }

    func markForDeletion() {
        guard let item = currentItem else { return }
        queue.remove(at: currentIndex)
        pendingDeletions.append(item)
        undoStack.append(.markDelete(item, index: currentIndex))
        finishIfPastEnd()
        prefetch()
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .archive(let item, let index):
            records.removeValue(forKey: item.id)
            saveRecords()
            sessionArchived -= 1
            reinsert(item, at: index)
        case .markDelete(let item, let index):
            pendingDeletions.removeAll { $0.id == item.id }
            reinsert(item, at: index)
        }
    }

    private func reinsert(_ item: ScreenshotItem, at index: Int) {
        let clamped = min(index, queue.count)
        queue.insert(item, at: clamped)
        currentIndex = clamped
        if phase == .finished || phase == .empty { phase = .reviewing }
    }

    /// Restart review of items that were skipped this session.
    func reviewSkipped() {
        guard !queue.isEmpty else { return }
        currentIndex = 0
        phase = .reviewing
        prefetch()
    }

    // MARK: - Deletion commit

    /// Deletes all marked screenshots from Photos in one batch
    /// (single system confirmation dialog).
    func commitDeletions() async {
        guard !pendingDeletions.isEmpty else { return }
        let items = pendingDeletions
        do {
            try await PhotoLibraryService.shared.delete(items.map(\.asset))
            for item in items {
                records[item.id] = TriageRecord(status: "deleted", date: .now)
            }
            saveRecords()
            sessionDeleted += items.count
            pendingDeletions.removeAll()
            undoStack.removeAll {
                if case .markDelete = $0 { return true } else { return false }
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            // User dismissed the system confirmation; keep the marks.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func finishIfPastEnd() {
        if queue.isEmpty || currentIndex >= queue.count {
            phase = .finished
        }
    }

    // MARK: - Analysis pipeline

    /// Kick off image load + OCR + interpretation for the current item and the next few.
    func prefetch() {
        guard phase == .reviewing else { return }
        let window = currentIndex..<min(currentIndex + prefetchDepth, queue.count)
        for item in queue[window] where item.phase == .queued {
            item.phase = .loadingImage(0)
            Task { await Self.process(item) }
        }
    }

    private static func process(_ item: ScreenshotItem) async {
        do {
            let image = try await PhotoLibraryService.shared.loadImage(for: item.asset) { fraction in
                Task { @MainActor in
                    if case .loadingImage = item.phase {
                        item.phase = .loadingImage(fraction)
                    }
                }
            }
            item.image = image
            item.phase = .analyzing
            let text = try await OCRService.recognizeText(in: image)
            item.ocrText = text
            item.urls = OCRService.extractURLs(from: text)
            item.interpretation = await InterpretationService.shared.interpret(
                ocrText: text, urls: item.urls
            )
            item.phase = .ready
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private var recordsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SnapRead", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("triage.json")
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([String: TriageRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }
}
