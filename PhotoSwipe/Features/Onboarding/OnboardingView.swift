import PhotoSwipeCore
import SwiftUI
import UIKit

/// Première ouverture : trois principes, puis demande d'accès au moment où l'utilisateur commence.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Faites le tri dans vos photos")
                        .font(.largeTitle.bold())
                    Text("Retrouvez ce qui vous encombre, gardez le contrôle sur vos souvenirs.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                OnboardingPoint(
                    systemImage: "hand.draw",
                    title: "Un geste par photo",
                    message: "Glissez vers la droite pour conserver, vers la gauche pour mettre de côté à supprimer. Des boutons font la même chose, et vous pouvez passer ou annuler."
                )
                OnboardingPoint(
                    systemImage: "lock.iphone",
                    title: "Tout reste sur votre iPhone",
                    message: "Vos photos ne sont jamais envoyées sur un serveur et aucun compte n'est nécessaire."
                )
                OnboardingPoint(
                    systemImage: "checkmark.shield",
                    title: "Rien n'est supprimé sans vous",
                    message: "Un swipe ne supprime rien. Vous revoyez votre sélection, la validez, puis iOS vous demande une dernière confirmation."
                )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: start) {
                    Text("Commencer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                if let problem {
                    Text(verbatim: problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Ouvrir les Réglages") {
                            openURL(url)
                        }
                        .font(.footnote)
                    }
                } else {
                    Text("PhotoSwipe vous demandera ensuite l'accès à vos photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func start() {
        isRequesting = true
        problem = nil
        Task {
            if await environment.requestAuthorization() {
                environment.settings.hasCompletedOnboarding = true
            } else {
                problem = diagnostic()
            }
            isRequesting = false
        }
    }

    /// Informations de diagnostic affichées quand iOS ne répond pas à la demande d'accès.
    private func diagnostic() -> String {
        let hasUsageText = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
        return "iOS n'a pas répondu à la demande d'accès aux photos. "
            + "État : \(environment.library.authorizationStatus()), "
            + "texte d'autorisation : \(hasUsageText ? "présent" : "absent"), "
            + "identifiant : \(Bundle.main.bundleIdentifier ?? "inconnu")."
    }
}

private struct OnboardingPoint: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Accès refusé ou restreint : expliquer, sans culpabiliser, et proposer le seul recours possible.
struct PhotoAccessDeniedView: View {
    let authorization: LibraryAuthorization
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "photo.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if authorization == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Ouvrir les Réglages") {
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var title: LocalizedStringKey {
        authorization == .restricted ? "Accès aux photos restreint" : "PhotoSwipe n'a pas accès à vos photos"
    }

    private var message: LocalizedStringKey {
        if authorization == .restricted {
            return "L'accès aux photos est bloqué sur cet appareil (contrôle parental ou gestion par une organisation). PhotoSwipe ne peut pas fonctionner sans cet accès."
        }
        return "Pour trier votre photothèque, autorisez l'accès à toutes vos photos ou à une sélection dans Réglages > PhotoSwipe > Photos."
    }
}
