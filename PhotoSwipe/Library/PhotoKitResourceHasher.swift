import CryptoKit
import Foundation
import Photos
import PhotoSwipeCore

/// Empreintes SHA-256 des fichiers d'origine, calculées par lecture progressive via PhotoKit.
///
/// Éligibilité V1 (docs/06) : une seule ressource principale, de type photo ou vidéo. Une photo modifiée,
/// une Live Photo, une rafale ou un RAW+JPEG ont plusieurs ressources et ne sont pas comparées.
/// Rien n'est conservé hors de l'empreinte ; le téléchargement iCloud n'a lieu que si l'utilisateur l'autorise.
struct PhotoKitResourceHasher: ResourceHashing {
    func partialDigest(for id: AssetID, allowsNetwork: Bool) async -> DigestOutcome {
        await digest(for: id, limit: Int64(DigestMethod.partialByteCount), expectedBytes: nil, allowsNetwork: allowsNetwork)
    }

    func fullDigest(for id: AssetID, expectedBytes: Int64, allowsNetwork: Bool) async -> DigestOutcome {
        await digest(for: id, limit: nil, expectedBytes: expectedBytes, allowsNetwork: allowsNetwork)
    }

    private func digest(for id: AssetID, limit: Int64?, expectedBytes: Int64?, allowsNetwork: Bool) async -> DigestOutcome {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else {
            return .unavailable
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first,
              resource.type == .photo || resource.type == .video
        else { return .ineligible }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        return await withCheckedContinuation { (continuation: CheckedContinuation<DigestOutcome, Never>) in
            let state = HashState(limit: limit, expectedBytes: expectedBytes, continuation: continuation)
            let requestID = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in state.consume(data) },
                completionHandler: { error in state.complete(error: error) }
            )
            state.attach(requestID: requestID)
        }
    }
}

/// État d'une lecture : cumule l'empreinte, s'arrête à la limite demandée et ne rend qu'un seul résultat.
private final class HashState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    private var received: Int64 = 0
    private let limit: Int64?
    private let expectedBytes: Int64?
    private var continuation: CheckedContinuation<DigestOutcome, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequested = false

    init(limit: Int64?, expectedBytes: Int64?, continuation: CheckedContinuation<DigestOutcome, Never>) {
        self.limit = limit
        self.expectedBytes = expectedBytes
        self.continuation = continuation
    }

    func attach(requestID id: PHAssetResourceDataRequestID) {
        let shouldCancel = lock.withLock { () -> Bool in
            requestID = id
            return cancelRequested
        }
        if shouldCancel {
            PHAssetResourceManager.default().cancelDataRequest(id)
        }
    }

    func consume(_ data: Data) {
        var cancelID: PHAssetResourceDataRequestID?
        var shouldCancel = false
        var result: (CheckedContinuation<DigestOutcome, Never>, DigestOutcome)?
        lock.withLock {
            guard continuation != nil else { return }
            let remaining = limit.map { $0 - received } ?? Int64(data.count)
            let take = Int(min(Int64(data.count), max(remaining, 0)))
            if take > 0 {
                hasher.update(data: data.prefix(take))
                received += Int64(take)
            }
            if let limit, received >= limit, let pending = continuation {
                continuation = nil
                result = (pending, .digest(Self.hex(hasher.finalize())))
                shouldCancel = true
                cancelID = requestID
                cancelRequested = requestID == nil
            }
        }
        if shouldCancel, let cancelID {
            PHAssetResourceManager.default().cancelDataRequest(cancelID)
        }
        if let (pending, outcome) = result {
            pending.resume(returning: outcome)
        }
    }

    func complete(error: Error?) {
        var result: (CheckedContinuation<DigestOutcome, Never>, DigestOutcome)?
        lock.withLock {
            guard let pending = continuation else { return }
            continuation = nil
            if error != nil {
                result = (pending, .unavailable)
            } else if let expectedBytes, received != expectedBytes {
                // Taille lue différente de la taille annoncée : le résultat n'est pas fiable.
                result = (pending, .unavailable)
            } else {
                result = (pending, .digest(Self.hex(hasher.finalize())))
            }
        }
        if let (pending, outcome) = result {
            pending.resume(returning: outcome)
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
