import AppKit
import Photos
import SwiftUI

/// Category of content detected in a screenshot.
enum ContentCategory: String, Codable, CaseIterable {
    case article
    case socialPost
    case video
    case movie
    case book
    case music
    case shopping
    case codeDocs
    case recipe
    case chatMessage
    case mapLocation
    case appStore
    case event
    case other

    var label: String {
        switch self {
        case .article: return "Article"
        case .socialPost: return "Social Post"
        case .video: return "Video"
        case .movie: return "Movie / TV"
        case .book: return "Book"
        case .music: return "Music"
        case .shopping: return "Shopping"
        case .codeDocs: return "Code / Docs"
        case .recipe: return "Recipe"
        case .chatMessage: return "Chat"
        case .mapLocation: return "Place"
        case .appStore: return "App"
        case .event: return "Event"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .article: return "doc.text"
        case .socialPost: return "bubble.left.and.bubble.right"
        case .video: return "play.rectangle"
        case .movie: return "film"
        case .book: return "book"
        case .music: return "music.note"
        case .shopping: return "cart"
        case .codeDocs: return "chevron.left.forwardslash.chevron.right"
        case .recipe: return "fork.knife"
        case .chatMessage: return "message"
        case .mapLocation: return "mappin.and.ellipse"
        case .appStore: return "app.badge"
        case .event: return "calendar"
        case .other: return "questionmark.square.dashed"
        }
    }

    var color: Color {
        switch self {
        case .article: return .blue
        case .socialPost: return .purple
        case .video: return .pink
        case .movie: return .indigo
        case .book: return .brown
        case .music: return .pink
        case .shopping: return .orange
        case .codeDocs: return .green
        case .recipe: return .red
        case .chatMessage: return .gray
        case .mapLocation: return .cyan
        case .appStore: return .indigo
        case .event: return .mint
        case .other: return .gray
        }
    }
}

/// What the app concluded a screenshot is about.
struct Interpretation: Equatable {
    enum Source: Equatable {
        case appleIntelligence
        case heuristic
    }

    var category: ContentCategory
    var title: String
    var summary: String
    var source: Source
}

/// One screenshot in the triage queue, with its analysis pipeline state.
@MainActor
@Observable
final class ScreenshotItem: Identifiable {
    enum Phase: Equatable {
        case queued
        case loadingImage(Double)  // 0…1, iCloud download progress
        case analyzing
        case ready
        case failed(String)
    }

    nonisolated let asset: PHAsset
    nonisolated var id: String { asset.localIdentifier }
    nonisolated var date: Date { asset.creationDate ?? .distantPast }

    var image: NSImage?
    var phase: Phase = .queued
    var ocrText: String = ""
    var urls: [URL] = []
    var interpretation: Interpretation?

    nonisolated init(asset: PHAsset) {
        self.asset = asset
    }
}
