import SwiftUI

private enum SidebarItem: Hashable {
    case overview, history
    case job(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var store: BackupStore
    @State private var selection: SidebarItem? = .overview
    @State private var editorJob: BackupJob?
    @State private var jobToDelete: BackupJob?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.background)
        }
        .font(.system(size: 13))
        .sheet(item: $editorJob) { job in
            JobEditorView(job: job, isEditing: store.jobs.contains { $0.id == job.id }) { savedJob, password in
                try store.addOrUpdate(savedJob, password: password)
                selection = .job(savedJob.id)
            }
            .environmentObject(store)
        }
        .alert(L10n.text("job.delete_title"), isPresented: Binding(
            get: { jobToDelete != nil },
            set: { if !$0 { jobToDelete = nil } }
        )) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let job = jobToDelete, store.delete(job), selection == .job(job.id) {
                    selection = .overview
                }
                jobToDelete = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { jobToDelete = nil }
        } message: {
            Text(L10n.text("job.delete_message", jobToDelete?.name ?? ""))
        }
        .alert(L10n.text("store.operation_failed"), isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(L10n.text("common.close")) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .createBackupJob)) { _ in createJob() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BackupCron")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)

            List(selection: $selection) {
                Label(L10n.text("common.overview"), systemImage: "house")
                    .tag(SidebarItem.overview)
                Label(L10n.text("common.history"), systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)

                Section(L10n.text("common.jobs")) {
                    ForEach(store.jobs) { job in
                        sidebarRow(job)
                            .tag(SidebarItem.job(job.id))
                            .contextMenu {
                                if store.runningJobIDs.contains(job.id) {
                                    Button(L10n.text("job.stop")) { store.cancel(job) }
                                } else {
                                    Button(L10n.text("common.run_now")) { store.run(job) }
                                }
                                Button(L10n.text("common.edit")) { editorJob = job }
                                Divider()
                                Button(L10n.text("common.delete"), role: .destructive) { jobToDelete = job }
                            }
                    }
                }

                Button(action: createJob) {
                    Label(L10n.text("common.new_job"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
            .listStyle(.sidebar)

        }
        .background(AppTheme.sidebar)
    }

    private func sidebarRow(_ job: BackupJob) -> some View {
        let snapshot = JobSnapshot(jobID: job.id, history: store.history,
                                   isRunning: store.runningJobIDs.contains(job.id))
        return HStack(spacing: 8) {
            Label(job.name, systemImage: job.kind.symbol)
                .lineLimit(1)
            Spacer(minLength: 4)
            if snapshot.health == .running {
                BackupActivityIndicator(size: 14)
            } else if snapshot.health == .failure || snapshot.health == .cancelled {
                Image(systemName: snapshot.health.symbol)
                    .foregroundStyle(snapshot.health.color)
                    .accessibilityLabel(L10n.text(snapshot.health.titleKey))
            }
        }
        .padding(.vertical, 4)
        .help(job.name)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .overview, .none:
            dashboard
        case .history:
            HistoryView()
                .toolbar {
                    Button(L10n.text("common.new_job"), systemImage: "plus", action: createJob)
                }
        case .job(let id):
            if let job = store.jobs.first(where: { $0.id == id }) {
                JobDetailView(job: job, onEdit: { editorJob = job }) {
                    if store.delete(job) { selection = .overview }
                }
                .id(job.id)
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        DashboardView(onCreate: createJob, onSelect: { selection = .job($0) })
    }

    private func createJob() {
        editorJob = BackupJob()
    }
}
