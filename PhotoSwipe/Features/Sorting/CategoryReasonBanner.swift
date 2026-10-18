import PhotoSwipeCore
import SwiftUI

/// Dans une pile de catégorie, explique pourquoi la photo courante y figure (« Proposée car : … »).
/// Les raisons viennent des mesures enregistrées localement, jamais d'une estimation affichée comme certaine.
struct CategoryReasonBanner: View {
    let itemID: AssetID?
    let scope: SessionScope

    @Environment(AppEnvironment.self) private var environment
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                Label {
                    Text(verbatim: text)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: itemID) {
            await load()
        }
    }

    private func load() async {
        guard case .category(let key) = scope.filter, let itemID else {
            text = nil
            return
        }
        let store = environment.store
        guard let category = try? await store.category(forKey: key),
              let analysis = try? await store.analysis(for: itemID)
        else {
            text = nil
            return
        }
        let reasons = category.rule.reasons(for: analysis).map(Self.describe)
        text = reasons.isEmpty ? nil : String(localized: "Proposée car : \(reasons.joined(separator: ", "))")
    }

    private static func describe(_ reason: MatchReason) -> String {
        switch reason {
        case .utility:
            String(localized: "image utilitaire selon iOS")
        case .textCoverage(let value):
            String(localized: "beaucoup de texte (\(Int((value * 100).rounded())) %)")
        case .label(let name, let confidence):
            String(localized: "\(LabelSearch.displayName(name)) (\(Int((confidence * 100).rounded())) %)")
        case .lowAesthetics:
            String(localized: "peu réussie selon iOS")
        }
    }
}
