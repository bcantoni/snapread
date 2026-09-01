import Foundation
import FoundationModels

/// Structured output the on-device model fills in from OCR text.
@Generable
struct GeneratedInterpretation {
    @Guide(description: "The category that best matches the main content of the screenshot")
    var category: GeneratedCategory

    @Guide(description: "A short title for the main content: the article headline, movie or book name, product, place, or the social post's author")
    var title: String

    @Guide(description: "One sentence describing what the screenshot's content is about, ignoring phone UI chrome like the status bar")
    var summary: String
}

@Generable
enum GeneratedCategory {
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

    var contentCategory: ContentCategory {
        switch self {
        case .article: return .article
        case .socialPost: return .socialPost
        case .video: return .video
        case .movie: return .movie
        case .book: return .book
        case .music: return .music
        case .shopping: return .shopping
        case .codeDocs: return .codeDocs
        case .recipe: return .recipe
        case .chatMessage: return .chatMessage
        case .mapLocation: return .mapLocation
        case .appStore: return .appStore
        case .event: return .event
        case .other: return .other
        }
    }
}

/// Turns OCR text into an Interpretation, preferring the on-device
/// Apple Intelligence model and falling back to regex heuristics.
final class InterpretationService: Sendable {
    static let shared = InterpretationService()

    var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var modelUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    func interpret(ocrText: String, urls: [URL]) async -> Interpretation {
        if isModelAvailable, !ocrText.isEmpty {
            do {
                return try await interpretWithModel(ocrText: ocrText)
            } catch {
                // Guardrail refusals, context overflow, etc. — fall back silently.
            }
        }
        return heuristicInterpretation(ocrText: ocrText, urls: urls)
    }

    private func interpretWithModel(ocrText: String) async throws -> Interpretation {
        let session = LanguageModelSession(instructions: """
            You analyze text extracted via OCR from iPhone screenshots. The user \
            screenshots things they want to remember or act on: articles, social media \
            posts, movies, books, products, recipes, places, apps, and events. \
            Identify the main content, ignoring phone UI chrome such as the status bar, \
            clock, battery indicator, and app navigation buttons.
            """)
        let trimmed = String(ocrText.prefix(1600))
        let response = try await session.respond(
            to: "OCR text of the screenshot:\n\(trimmed)",
            generating: GeneratedInterpretation.self
        )
        let generated = response.content
        return Interpretation(
            category: generated.category.contentCategory,
            title: generated.title,
            summary: generated.summary,
            source: .appleIntelligence
        )
    }

    // MARK: - Heuristic fallback (ported from snapread.py CLASSIFIERS)

    private static let classifiers: [(ContentCategory, NSRegularExpression)] = {
        let table: [(ContentCategory, String)] = [
            (.appStore, #"\bApp Store\b|\bGet\b.*\b(Free|Ratings?)\b|ratings and reviews"#),
            (.codeDocs, #"github\.com|stackoverflow\.com|def |function |class |import |```"#),
            (.mapLocation, #"maps\.apple\.com|maps\.google\.com|\bDirections\b|\bETA\b|\bmi away\b|miles away"#),
            (.recipe, #"\btsp\b|\btbsp\b|\bcups?\b|\bservings?\b|\bingredients?\b|\bprep time\b|\bcook time\b"#),
            (.shopping, #"\$\d+[.,]\d{2}|\bAdd to (Cart|Bag)\b|\bBuy Now\b|\bCheckout\b|\bamazon\.com\b"#),
            (.chatMessage, #"\biMessage\b|\bSlack\b|\bTeams\b|\bWhatsApp\b|\bTelegram\b|\bDelivered\b"#),
            (.socialPost, #"twitter\.com|\bx\.com|instagram\.com|reddit\.com|tiktok\.com|\bLikes?\b|\bRetweets?\b|\bReposts?\b|\bFollowers?\b"#),
            (.article, #"\bmin read\b|\bSubscribe\b|\bRead more\b|\bSign (in|up)\b"#),
        ]
        return table.compactMap { category, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return (category, regex)
        }
    }()

    private func heuristicInterpretation(ocrText: String, urls: [URL]) -> Interpretation {
        let combined = ocrText + " " + urls.map(\.absoluteString).joined(separator: " ")
        let range = NSRange(combined.startIndex..., in: combined)
        var category: ContentCategory = .other
        for (candidate, regex) in Self.classifiers {
            if regex.firstMatch(in: combined, options: [], range: range) != nil {
                category = candidate
                break
            }
        }

        let title = Self.firstMeaningfulLine(of: ocrText) ?? "Screenshot"
        let summary = ocrText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(140)
        return Interpretation(
            category: category,
            title: title,
            summary: String(summary),
            source: .heuristic
        )
    }

    /// First OCR line that looks like content rather than status-bar chrome.
    private static func firstMeaningfulLine(of text: String) -> String? {
        let chrome = try? NSRegularExpression(
            pattern: #"^\d{1,2}:\d{2}$|^\d{1,3}%$|^(LTE|5G|4G|Wi-?Fi)$"#,
            options: .caseInsensitive
        )
        for line in text.split(separator: "\n") {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.count >= 12 else { continue }
            if let chrome,
               chrome.firstMatch(in: candidate, options: [],
                                 range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                continue
            }
            return candidate
        }
        return nil
    }
}
