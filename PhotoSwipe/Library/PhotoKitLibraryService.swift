import Foundation
import OSLog
import Photos
import PhotosUI
import PhotoSwipeCore
import UIKit

/// Capacité propre à PhotoKit : modifier la sélection en accès limité.
protocol LimitedSelectionManaging {
    @MainActor func presentLimitedLibraryPicker() async
}

/// Implémentation PhotoKit de `PhotoLibraryService`.
///
/// Périmètre V1 : images de la photothèque de l'utilisateur uniquement. Les vidéos, les
/// photos masquées, les albums partagés et les photos synchronisées depuis un ordinateur
/// (non supprimables depuis l'iPhone) sont exclus.
final class PhotoKitLibraryService: NSObject, PhotoLibraryService, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    // État protégé par `lock` : `photoLibraryDidChange` est appelé sur une file arbitraire.
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isRegistered = false

    deinit {
        if isRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: Autorisation

    func authorizationStatus() -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .full
        case .limited: .limited
        @unknown default: .denied
        }
    }

    // MARK: Énumération

    static func enumerationOptions(order: SortOrder = .newestFirst) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: order == .oldestFirst)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = false
        return options
    }

    func assetBatches(batchSize: Int, order: SortOrder) -> AsyncThrowingStream<[AssetSummary], any Error> {
        let size = max(1, batchSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let result = PHAsset.fetchAssets(with: .image, options: Self.enumerationOptions(order: order))
                let total = result.count
                var start = 0
                while start < total {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let end = min(start + size, total)
                    let assets = result.objects(at: IndexSet(integersIn: start..<end))
                    continuation.yield(assets.map(AssetSummary.init(photoKitAsset:)))
                    start = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func existingAssetIDs(among ids: [AssetID]) async -> Set<AssetID> {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.includeAllBurstAssets = true
            var found = Set<AssetID>()
            var start = 0
            while start < ids.count {
                let end = min(start + 500, ids.count)
                let identifiers = ids[start..<end].map(\.rawValue)
                let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options)
                result.enumerateObjects { asset, _, _ in
                    found.insert(AssetID(asset.localIdentifier))
                }
                start = end
            }
            return found
        }.value
    }

    // MARK: Changements

    func changeNotifications() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        let shouldRegister = lock.withLock { () -> Bool in
            continuations[token] = continuation
            guard !isRegistered else { return false }
            isRegistered = true
            return true
        }
        // Enregistré seulement après autorisation : l'appelant ne s'abonne qu'avec un accès accordé.
        if shouldRegister {
            PHPhotoLibrary.shared().register(self)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock {
                self.continuations.removeValue(forKey: token)
            }
        }
        return stream
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current {
            continuation.yield()
        }
    }
}

extension PhotoKitLibraryService: LimitedSelectionManaging {
    @MainActor
    func presentLimitedLibraryPicker() async {
        guard let presenter = UIApplication.shared.topMostViewController() else {
            Logger.library.error("Aucun contrôleur pour présenter le sélecteur de photos")
            return
        }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { identifiers in
                continuation.resume(returning: identifiers)
            }
        }
    }
}

extension PhotoKitLibraryService: AssetDeleting {
    /// Supprime via PhotoKit : iOS affiche sa propre alerte de confirmation, et les photos
    /// vont dans « Supprimés récemment ».
    func deleteAssets(_ ids: [AssetID]) async throws -> Bool {
        let identifiers = ids.map(\.rawValue)
        guard !identifiers.isEmpty else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            if (error as? PHPhotosError)?.code == .userCancelled || (error as? CocoaError)?.code == .userCancelled {
                return false
            }
            throw error
        }
    }
}

extension AssetSummary {
    init(photoKitAsset asset: PHAsset) {
        var subtypes: AssetSubtypes = []
        let media = asset.mediaSubtypes
        if media.contains(.photoScreenshot) { subtypes.insert(.screenshot) }
        if media.contains(.photoLive) { subtypes.insert(.livePhoto) }
        if media.contains(.photoHDR) { subtypes.insert(.hdr) }
        if media.contains(.photoPanorama) { subtypes.insert(.panorama) }
        if media.contains(.photoDepthEffect) { subtypes.insert(.depthEffect) }
        if asset.representsBurst { subtypes.insert(.burst) }
        self.init(
            id: AssetID(asset.localIdentifier),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            subtypes: subtypes,
            burstIdentifier: asset.burstIdentifier,
            isFavorite: asset.isFavorite
        )
    }
}

extension UIApplication {
    /// Contrôleur au sommet de la scène active (y compris une feuille SwiftUI présentée).
    func topMostViewController() -> UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
