import CoreGraphics
import Foundation
import Photos
import PhotoSwipeCore
import UIKit
import Vision

/// Analyse locale d'une photo avec les API Vision du système : étiquettes de contenu,
/// jugement « utilitaire » et score d'esthétique, couverture de texte.
///
/// Tout se passe sur l'appareil, à partir d'une version réduite de la photo. Le texte reconnu
/// n'est ni conservé ni journalisé, seule sa quantité est mesurée. Le réseau n'est jamais utilisé :
/// une photo uniquement présente dans iCloud est ignorée.
struct VisionImageAnalyzer: ImageAnalyzing {
    /// Plus grande dimension de l'image analysée (suffisant pour classer et mesurer le texte).
    private static let analysisPixelSize: CGFloat = 1024
    private static let minimumLabelConfidence: Float = 0.1
    private static let maximumLabelCount = 15

    func analyze(_ id: AssetID) async throws -> ImageAnalysis? {
        guard let image = await Self.loadImage(for: id) else { return nil }
        try Task.checkCancellation()

        let observations = try await ClassifyImageRequest().perform(on: image)
        let labels = observations
            .filter { $0.confidence >= Self.minimumLabelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(Self.maximumLabelCount)
            .map { ImageLabel(name: $0.identifier.lowercased(), confidence: Double($0.confidence)) }

        // L'esthétique est un complément : son échec ne doit pas faire perdre l'analyse.
        let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image)
        let text = await Task.detached(priority: .utility) { Self.measureText(in: image) }.value

        return ImageAnalysis(
            labels: Array(labels),
            textCoverage: text.coverage,
            textCharacterCount: text.characters,
            isUtility: aesthetics?.isUtility ?? false,
            aestheticsScore: Double(aesthetics?.overallScore ?? 0)
        )
    }

    /// Part de la surface couverte par du texte reconnu (rapide, sans correction linguistique).
    private static func measureText(in image: CGImage) -> (coverage: Double, characters: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else {
            return (0, 0)
        }
        var area = 0.0
        var characters = 0
        for observation in results {
            area += Double(observation.boundingBox.width * observation.boundingBox.height)
            characters += observation.topCandidates(1).first?.string.count ?? 0
        }
        return (min(area, 1), characters)
    }

    private static func loadImage(for id: AssetID) async -> CGImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let size = CGSize(width: analysisPixelSize, height: analysisPixelSize)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let gate = OnceGate()
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard gate.claim() else { return }
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}

/// Garantit qu'une continuation n'est reprise qu'une fois, même si PhotoKit rappelle plusieurs fois.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

#if DEBUG
/// Analyse factice déterministe pour le mode démonstration (le simulateur ne peut pas exécuter Vision).
struct DemoImageAnalyzer: ImageAnalyzing {
    func analyze(_ id: AssetID) async throws -> ImageAnalysis? {
        try? await Task.sleep(for: .milliseconds(30))
        let index = Int(id.rawValue.split(separator: "-").last.flatMap { Int($0) } ?? 0)
        switch index % 6 {
        case 0:
            return ImageAnalysis(labels: [ImageLabel(name: "document", confidence: 0.9)], textCoverage: 0.5, textCharacterCount: 600, isUtility: true, aestheticsScore: -0.5)
        case 1:
            return ImageAnalysis(labels: [ImageLabel(name: "cat", confidence: 0.92), ImageLabel(name: "animal", confidence: 0.88)], textCoverage: 0, textCharacterCount: 0, isUtility: false, aestheticsScore: 0.6)
        case 2:
            return ImageAnalysis(labels: [ImageLabel(name: "food", confidence: 0.8)], textCoverage: 0.02, textCharacterCount: 12, isUtility: false, aestheticsScore: 0.4)
        case 3:
            return ImageAnalysis(labels: [ImageLabel(name: "beach", confidence: 0.85), ImageLabel(name: "sky", confidence: 0.7)], textCoverage: 0, textCharacterCount: 0, isUtility: false, aestheticsScore: 0.7)
        case 4:
            return ImageAnalysis(labels: [ImageLabel(name: "people", confidence: 0.9)], textCoverage: 0, textCharacterCount: 0, isUtility: false, aestheticsScore: -0.6)
        default:
            return ImageAnalysis(labels: [ImageLabel(name: "car", confidence: 0.75)], textCoverage: 0, textCharacterCount: 0, isUtility: false, aestheticsScore: 0.1)
        }
    }
}
#endif
