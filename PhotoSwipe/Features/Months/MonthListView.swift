import PhotoSwipeCore
import SwiftUI

/// Navigation par période : un mois = une session courte.
struct MonthListView: View {
    let open: (Route) -> Void
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let months = environment.overview.months
        List {
            ForEach(months) { summary in
                NavigationLink(value: Route.sort(SessionScope(filter: summary.filter))) {
                    MonthRow(summary: summary)
                }
                .contextMenu {
                    if summary.kept > 0 {
                        reviewKeptButton(for: summary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if summary.kept > 0 {
                        reviewKeptButton(for: summary)
                            .tint(.indigo)
                    }
                }
            }
        }
        .overlay {
            if months.isEmpty {
                ContentUnavailableView(
                    "Aucun mois à afficher",
                    systemImage: "calendar",
                    description: Text("Les mois apparaîtront ici dès que vos photos auront été lues.")
                )
            }
        }
        .navigationTitle("Trier par mois")
        .task(id: environment.sync.revision) {
            await environment.overview.refreshMonths()
        }
    }

    private func reviewKeptButton(for summary: MonthSummary) -> some View {
        Button {
            open(.sort(SessionScope(filter: summary.filter, pool: .keptReview)))
        } label: {
            Label("Revoir les conservées", systemImage: "arrow.counterclockwise")
        }
    }
}

struct MonthRow: View {
    let summary: MonthSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayFormat.monthTitle(summary.month))
                    .font(.body.weight(.semibold))
                Text("\(summary.total) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if summary.remaining == 0 {
                Label {
                    Text("Trié")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            } else {
                Text("\(summary.remaining) à trier")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
