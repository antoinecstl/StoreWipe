import PhotoSwipeCore
import SwiftUI
import UIKit

/// Réglages : confidentialité, accès aux photos, iCloud, réinitialisation.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingReset = false
    @State private var isConfirmingErase = false
    @State private var isWorking = false
    @State private var failureMessage: LocalizedStringKey?

    var body: some View {
        @Bindable var settings = environment.settings
        NavigationStack {
            Form {
                Section {
                    Label("Vos photos sont traitées uniquement sur cet iPhone.", systemImage: "lock.iphone")
                    Label("Aucun compte, aucune publicité, aucune mesure d'audience.", systemImage: "person.crop.circle.badge.xmark")
                    NavigationLink("Détails sur vos données") {
                        PrivacyDetailView()
                    }
                } header: {
                    Text("Confidentialité")
                }

                Section {
                    LabeledContent("Accès actuel") {
                        Text(accessDescription)
                    }
                    if environment.canManageLimitedSelection {
                        Button("Choisir les photos autorisées") {
                            Task { await environment.manageLimitedSelection() }
                        }
                    }
                    if let url = URL(string: UIApplication.openSettingsURLString), !environment.isDemoMode {
                        Button("Modifier l'accès dans Réglages") {
                            openURL(url)
                        }
                    }
                } header: {
                    Text("Accès aux photos")
                } footer: {
                    Text("En accès limité, PhotoSwipe ne travaille que sur les photos que vous avez autorisées. Retirer une photo de l'accès ne la supprime pas et conserve votre décision.")
                }

                Section {
                    Toggle("Inclure les vidéos", isOn: $settings.includesVideos)
                        .onChange(of: settings.includesVideos) {
                            Task { await environment.applyMediaSettings() }
                        }
                    Picker("Ordre du tri", selection: $settings.sortOrder) {
                        Text("Plus anciennes d'abord").tag(PresentationOrder.oldestFirst)
                        Text("Plus récentes d'abord").tag(PresentationOrder.newestFirst)
                    }
                } header: {
                    Text("Tri")
                } footer: {
                    Text("S'applique aux nouvelles sessions. Une session déjà commencée garde son ordre.")
                }

                Section {
                    Toggle("Télécharger depuis iCloud pour afficher", isOn: $settings.allowsNetworkForDisplay)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Si une photo n'est pas présente sur cet iPhone, Photos peut la télécharger depuis iCloud pour l'afficher. Cela peut utiliser des données mobiles. Désactivé, la photo est proposée avec un bouton de téléchargement.")
                }

                Section {
                    Button("Réinitialiser les décisions", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(isWorking)
                    Button("Effacer les données de l'application", role: .destructive) {
                        isConfirmingErase = true
                    }
                    .disabled(isWorking)
                } header: {
                    Text("Données")
                } footer: {
                    Text("Ces actions ne suppriment aucune photo de votre photothèque.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionDescription)
                    if environment.isDemoMode {
                        LabeledContent("Mode", value: "Démonstration")
                    }
                } header: {
                    Text("À propos")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog("Réinitialiser toutes les décisions ?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Réinitialiser", role: .destructive) {
                    run { try await environment.resetDecisions() }
                }
            } message: {
                Text("Les photos conservées, passées et sélectionnées pour suppression redeviendront non triées. Vos photos ne sont pas modifiées.")
            }
            .confirmationDialog("Effacer les données de PhotoSwipe ?", isPresented: $isConfirmingErase, titleVisibility: .visible) {
                Button("Effacer", role: .destructive) {
                    run {
                        try await environment.eraseAllData()
                        dismiss()
                    }
                }
            } message: {
                Text("Décisions, progression, index et réglages seront effacés de cet iPhone. Aucune photo n'est supprimée.")
            }
            .alert("Opération impossible", isPresented: failureIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
        }
    }

    private var accessDescription: LocalizedStringKey {
        switch environment.authorization {
        case .full: "Toutes les photos"
        case .limited: "Photos sélectionnées"
        case .denied: "Refusé"
        case .restricted: "Restreint"
        case .notDetermined: "Non demandé"
        }
    }

    private var failureIsPresented: Binding<Bool> {
        Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await operation()
            } catch {
                failureMessage = "Vos données n'ont pas pu être modifiées. Réessayez."
            }
            isWorking = false
        }
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Explication détaillée des flux de données, en langage clair.
struct PrivacyDetailView: View {
    var body: some View {
        List {
            Section("Ce qui reste sur cet iPhone") {
                Text("Les décisions (conserver, à supprimer, passer), la progression des sessions et un index technique des photos (identifiant local, dates, dimensions, type) sont enregistrés dans le stockage privé de l'app.")
                Text("Ces données sont exclues de la sauvegarde iCloud : les identifiants des photos sont propres à cet appareil.")
                Text("Aucune copie complète de vos photos n'est conservée : les images sont affichées à la taille de l'écran et gardées brièvement en mémoire.")
            }
            Section("Ce qui peut utiliser Internet") {
                Text("Uniquement la récupération par Photos d'une image stockée dans iCloud, si vous l'autorisez. PhotoSwipe n'envoie jamais vos photos ni vos décisions à un serveur.")
            }
            Section("Suppression") {
                Text("Un swipe ne supprime rien. La suppression n'a lieu qu'après validation de votre sélection et confirmation par iOS. Les photos supprimées passent dans l'album « Supprimés récemment » de Photos et, si Photos iCloud est activé, sur vos autres appareils.")
            }
            Section("Effacer les données") {
                Text("« Effacer les données de l'application », dans les Réglages de PhotoSwipe, supprime l'index, les décisions, la progression et les réglages, sans toucher à vos photos.")
            }
        }
        .navigationTitle("Vos données")
        .navigationBarTitleDisplayMode(.inline)
    }
}
