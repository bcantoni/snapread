import AppKit
import Photos

enum PhotoLibraryError: LocalizedError {
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .imageUnavailable: return "Could not load this screenshot from Photos."
        }
    }
}

/// Sanctioned PhotoKit access: fetch screenshot assets, load their images
/// (downloading from iCloud when needed), and delete them.
final class PhotoLibraryService: Sendable {
    static let shared = PhotoLibraryService()

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// All screenshots created after `cutoff`, newest first.
    func fetchScreenshots(since cutoff: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0 AND creationDate > %@",
            PHAssetMediaSubtype.photoScreenshot.rawValue, cutoff as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Loads a high-quality image for the asset, downloading from iCloud if necessary.
    func loadImage(
        for asset: PHAsset,
        maxDimension: CGFloat = 2200,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> NSImage {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        if let progress {
            options.progressHandler = { fraction, _, _, _ in progress(fraction) }
        }

        let target = CGSize(width: maxDimension, height: maxDimension)
        final class ResumeGuard: @unchecked Sendable { var resumed = false }
        let guardBox = ResumeGuard()

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: options
            ) { image, info in
                guard !guardBox.resumed else { return }
                // highQualityFormat delivers exactly one result, but guard anyway
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guardBox.resumed = true
                if let image {
                    continuation.resume(returning: image)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryError.imageUnavailable)
                }
            }
        }
    }

    /// Deletes assets from the Photos library (moves them to Recently Deleted).
    /// Presents a single system confirmation dialog for the whole batch.
    func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}
