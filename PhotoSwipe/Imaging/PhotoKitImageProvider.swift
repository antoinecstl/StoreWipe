import Photos
import PhotoSwipeCore
import UIKit

/// Chargement d'images via `PHCachingImageManager`.
///
/// - Résolution adaptée à la zone d'affichage (pas d'original en mémoire).
/// - Préchargement limité aux quelques photos suivantes de la pile.
/// - Téléchargement iCloud uniquement si l'utilisateur l'autorise, avec progression visible.
@MainActor
final class PhotoKitImageProvider: AssetImageProviding {
    private let manager = PHCachingImageManager()
    private var assetCache: [AssetID: PHAsset] = [:]
    private var assetCacheOrder: [AssetID] = []
    private var prefetchedAssets: [PHAsset] = []
    private var prefetchConfiguration: PrefetchConfiguration?

    private static let assetCacheLimit = 64

    private struct PrefetchConfiguration: Equatable {
        let size: CGSize
        let allowNetwork: Bool
    }

    func images(for id: AssetID, targetPixelSize: CGSize, allowNetwork: Bool) -> AsyncStream<AssetImageEvent> {
        guard let asset = asset(for: id) else {
            return AsyncStream { continuation in
                continuation.yield(.unavailable)
                continuation.finish()
            }
        }
        let options = Self.requestOptions(allowNetwork: allowNetwork)
        let manager = self.manager
        return AsyncStream { continuation in
            options.progressHandler = { progress, _, _, _ in
                continuation.yield(.progress(progress))
            }
            let requestID = RequestIDBox()
            continuation.onTermination = { _ in
                if let id = requestID.value {
                    manager.cancelImageRequest(id)
                }
            }
            requestID.value = manager.requestImage(
                for: asset,
                targetSize: targetPixelSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                if let image {
                    continuation.yield(.image(image, isDegraded: isDegraded))
                    if !isDegraded {
                        continuation.finish()
                    }
                    return
                }
                guard !isCancelled else {
                    continuation.finish()
                    return
                }
                if isInCloud && !allowNetwork {
                    continuation.yield(.requiresNetwork)
                } else {
                    continuation.yield(.failed)
                }
                continuation.finish()
            }
        }
    }

    func updatePrefetch(_ ids: [AssetID], targetPixelSize: CGSize, allowNetwork: Bool) {
        guard targetPixelSize != .zero else { return }
        let configuration = PrefetchConfiguration(size: targetPixelSize, allowNetwork: allowNetwork)
        if configuration != prefetchConfiguration {
            manager.stopCachingImagesForAllAssets()
            prefetchedAssets = []
            prefetchConfiguration = configuration
        }
        let assets = ids.compactMap { asset(for: $0) }
        let wanted = Set(assets.map(\.localIdentifier))
        let current = Set(prefetchedAssets.map(\.localIdentifier))
        let toStop = prefetchedAssets.filter { !wanted.contains($0.localIdentifier) }
        let toStart = assets.filter { !current.contains($0.localIdentifier) }
        let options = Self.requestOptions(allowNetwork: allowNetwork)
        if !toStop.isEmpty {
            manager.stopCachingImages(for: toStop, targetSize: targetPixelSize, contentMode: .aspectFit, options: options)
        }
        if !toStart.isEmpty {
            manager.startCachingImages(for: toStart, targetSize: targetPixelSize, contentMode: .aspectFit, options: options)
        }
        prefetchedAssets = assets
    }

    func reset() {
        manager.stopCachingImagesForAllAssets()
        prefetchedAssets = []
        prefetchConfiguration = nil
        assetCache = [:]
        assetCacheOrder = []
    }

    // MARK: - Privé

    private static func requestOptions(allowNetwork: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = allowNetwork
        return options
    }

    private func asset(for id: AssetID) -> PHAsset? {
        if let cached = assetCache[id] {
            return cached
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else {
            return nil
        }
        assetCache[id] = asset
        assetCacheOrder.append(id)
        if assetCacheOrder.count > Self.assetCacheLimit {
            let evicted = assetCacheOrder.removeFirst()
            assetCache[evicted] = nil
        }
        return asset
    }
}

/// Identifiant de requête partagé entre le lancement et l'annulation (appelée sur une file quelconque).
private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PHImageRequestID?

    var value: PHImageRequestID? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
