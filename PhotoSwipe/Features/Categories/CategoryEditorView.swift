import PhotoSwipeCore
import SwiftUI

/// Création d'une catégorie : un nom et une ou plusieurs étiquettes parmi celles que l'analyse
/// a réellement trouvées dans les photos de l'utilisateur.
struct CategoryEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var query = ""
    @State private var statistics: [LabelStatistic] = []
    @State private var selected: Set<String> = []
    @State private var matchCount = 0
    @State private var isLoading = true
    @State private var isSaving = false

    private static let maximumRows = 200

    var body: some View {
        Form {
            Section("Nom") {
                TextField("Ex. : Animaux, Repas, Voyages", text: $name)
                    .textInputAutocapitalization(.sentences)
            }

            Section {
                TextField("Rechercher (chat, plage, voiture…)", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isLoading {
                    ProgressView()
                } else if statistics.isEmpty {
                    Text("Aucune étiquette pour l'instant : laissez l'analyse lire quelques photos, puis revenez ici.")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("Aucune étiquette ne correspond.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { statistic in
                    Button {
                        toggle(statistic.label)
                    } label: {
                        HStack {
                            Text(LabelSearch.displayName(statistic.label))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(statistic.count, format: .number)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: selected.contains(statistic.label) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(statistic.label) ? Color.accentColor : Color.secondary)
                        }
                    }
                    .accessibilityAddTraits(selected.contains(statistic.label) ? .isSelected : [])
                }
            } header: {
                Text("Ce que l'analyse reconnaît")
            } footer: {
                Text("Les noms viennent d'iOS (en anglais) ; la recherche comprend quelques mots français courants. Choisissez une ou plusieurs étiquettes.")
            }

            Section {
                LabeledContent("Photos correspondantes") {
                    Text(matchCount, format: .number)
                        .monospacedDigit()
                }
            } footer: {
                Text("Vous pourrez les trier une par une, ou tout marquer « à supprimer » puis revoir la sélection.")
            }
        }
        .navigationTitle("Nouvelle catégorie")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Créer") {
                    Task { await save() }
                }
                .disabled(!canSave)
            }
        }
        .task {
            statistics = (try? await environment.store.labelStatistics()) ?? []
            isLoading = false
        }
        .onChange(of: selected) {
            Task { await recount() }
        }
    }

    private var filtered: [LabelStatistic] {
        let matches = statistics.filter { LabelSearch.matches(label: $0.label, query: query) }
        return Array(matches.prefix(Self.maximumRows))
    }

    private var canSave: Bool {
        !isSaving && !selected.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggle(_ label: String) {
        if selected.contains(label) {
            selected.remove(label)
        } else {
            selected.insert(label)
        }
    }

    private func recount() async {
        guard !selected.isEmpty else {
            matchCount = 0
            return
        }
        matchCount = (try? await environment.store.matchCount(rule: .custom(labels: selected))) ?? 0
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard (try? await environment.store.addCategory(name: name, labels: selected, at: Date())) != nil else { return }
        await environment.overview.refresh()
        dismiss()
    }
}
