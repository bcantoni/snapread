import AppKit
import Vision

/// Text recognition (Apple Vision) and link extraction from OCR text.
enum OCRService {
    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: cgImage)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Extracts web links, including scheme-less ones like `x.com/user/status/…`
    /// that iOS UIs typically display. Bare-domain matches are upgraded to https.
    static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var urls: [URL] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard var url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            if scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                url = components.url ?? url
            }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}
