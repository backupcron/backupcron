import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: BackupStore
    @State private var filter: BackupStatus?

    private var runs: [BackupRun] {
        guard let filter else { return store.history }
        return store.history.filter { $0.status == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L10n.text("history.filter"), selection: $filter) {
                Text(L10n.text("history.all")).tag(Optional<BackupStatus>.none)
                Text(L10n.text("history.successful")).tag(Optional(BackupStatus.success))
                Text(L10n.text("history.failed")).tag(Optional(BackupStatus.failure))
                Text(L10n.text("history.cancelled")).tag(Optional(BackupStatus.cancelled))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            if runs.isEmpty {
                ContentUnavailableView(
                    L10n.text("history.empty"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.text("history.empty_description"))
                )
            } else {
                List(runs) { run in RunRow(run: run) }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
            }
        }
        .font(.system(size: 13))
        .background(AppTheme.background)
        .navigationTitle(L10n.text("common.history"))
    }
}
