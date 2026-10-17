#if DEBUG
import PhotoSwipeCore
import UIKit

/// Images synthétiques du mode démonstration : dégradés déterministes, sans photo réelle.
@MainActor
final class DemoImageProvider: AssetImageProviding {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 16
    }

    func images(for id: AssetID, targetPixelSize: CGSize, allowNetwork: Bool) -> AsyncStream<AssetImageEvent> {
        let image = render(id)
        return AsyncStream { continuation in
            continuation.yield(.image(image, isDegraded: false))
            continuation.finish()
        }
    }

    func updatePrefetch(_ ids: [AssetID], targetPixelSize: CGSize, allowNetwork: Bool) {}

    func reset() {
        cache.removeAllObjects()
    }

    private func render(_ id: AssetID) -> UIImage {
        if let cached = cache.object(forKey: id.rawValue as NSString) {
            return cached
        }
        let seed = id.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = CGFloat(seed % 360) / 360
        let isPortrait = seed % 3 != 0
        let size = isPortrait ? CGSize(width: 600, height: 800) : CGSize(width: 800, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.55, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let label = id.rawValue.split(separator: "-").last.map(String.init) ?? id.rawValue
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let text = label as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        cache.setObject(image, forKey: id.rawValue as NSString)
        return image
    }
}
#endif
