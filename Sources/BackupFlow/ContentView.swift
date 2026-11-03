import SwiftUI

private enum SidebarItem: Hashable {
    case overview, history, coldStorage
    case job(UUID)
    case group(UUID)
}

private struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: BackupGroup?
}

struct ContentView: View {
    @EnvironmentObject private var store: BackupStore
    @EnvironmentObject private var menuNavigation: BackupMenuNavigation
    @State private var selection: SidebarItem? = .overview
    @State private var editorJob: BackupJob?
    @State private var jobToDelete: BackupJob?
    @State private var groupEditor: GroupEditorRequest?
    @State private var groupToDelete: BackupGroup?
    @State private var collapsedGroups: Set<UUID> = []

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
        .sheet(item: $groupEditor) { request in
            BackupGroupEditor(group: request.group, jobs: store.jobs) { group in
                selection = .group(group.id)
                collapsedGroups.remove(group.id)
            }
            .environmentObject(store)
        }
        .alert(L10n.text("group.delete"), isPresented: Binding(
            get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }
        )) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let group = groupToDelete {
                    do {
                        try store.deleteGroup(group.id)
                        if selection == .group(group.id) { selection = .overview }
                    } catch { store.errorMessage = error.localizedDescription }
                }
                groupToDelete = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { groupToDelete = nil }
        } message: { Text(L10n.text("group.delete_message")) }
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
        .onChange(of: menuNavigation.destination, initial: true) { _, destination in
            guard let destination else { return }
            menuNavigation.destination = nil
            switch destination {
            case .job(let id, let edit):
                guard let job = store.jobs.first(where: { $0.id == id }) else { return }
                if let groupID = job.groupID { collapsedGroups.remove(groupID) }
                selection = .job(id)
                if edit { editorJob = job }
            case .newJob:
                createJob()
            case .coldStorage:
                selection = .coldStorage
            }
        }
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

                Button { editGroup(nil) } label: {
                    HStack {
                        Text(L10n.text("group.plural"))
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .help(L10n.text("group.new"))
                .accessibilityLabel(L10n.text("group.new"))
                .accessibilityIdentifier("new-group")
                ForEach(store.groups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedGroups.contains(group.id) },
                        set: { if $0 { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) } }
                    )) {
                        ForEach(store.jobs.filter { $0.groupID == group.id }) { job in jobEntry(job) }
                    } label: {
                        Label(group.name, systemImage: "folder")
                            .lineLimit(1)
                            .help(group.name)
                    }
                    .tag(SidebarItem.group(group.id))
                    .contextMenu { groupActions(group) }
                }
                if store.jobs.contains(where: { $0.groupID == nil }) {
                    Section(L10n.text("group.none")) {
                        ForEach(store.jobs.filter { $0.groupID == nil }) { job in jobEntry(job) }
                    }
                }

                Button(action: createJob) {
                    Label(L10n.text("common.new_job"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
            }
            .listStyle(.sidebar)

            Divider()
                .padding(.horizontal, 18)

            Button { selection = .coldStorage } label: {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .frame(width: 18)
                    Text(L10n.text("cold.title"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .foregroundStyle(selection == .coldStorage ? Color.white : Color.primary)
                .background(selection == .coldStorage ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("cold.title"))
            .accessibilityIdentifier("nav-cold-storage")
            .accessibilityAddTraits(selection == .coldStorage ? .isSelected : [])
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(AppTheme.sidebar)
    }

    private func jobEntry(_ job: BackupJob) -> some View {
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

    @ViewBuilder private func groupActions(_ group: BackupGroup) -> some View {
        Button(L10n.text("group.run")) { store.runGroup(group.id) }
            .disabled(store.runnableJobs(in: group.id).isEmpty)
        Button(L10n.text("group.edit")) { editGroup(group) }
        Button(L10n.text("common.delete"), role: .destructive) { groupToDelete = group }
    }

    private func editGroup(_ group: BackupGroup?) {
        groupEditor = GroupEditorRequest(group: group)
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
        case .coldStorage:
            ColdStorageView()
        case .history:
            HistoryView()
                .toolbar {
                    Button(L10n.text("common.new_job"), systemImage: "plus", action: createJob)
                }
        case .group(let id):
            if let group = store.groups.first(where: { $0.id == id }) {
                DashboardView(onCreate: { createJob(in: id) }, onSelect: { selection = .job($0) }, group: group)
                    .toolbar {
                        Menu { groupActions(group) } label: { Label(L10n.text("group.edit"), systemImage: "ellipsis") }
                    }
            } else { dashboard }
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
        if case .group(let id) = selection { createJob(in: id) }
        else { createJob(in: nil) }
    }

    private func createJob(in groupID: UUID?) {
        var job = BackupJob()
        job.groupID = groupID
        editorJob = job
    }
}

private struct BackupGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: BackupStore
    let group: BackupGroup?
    let onSave: (BackupGroup) -> Void
    @State private var name: String
    @State private var members: Set<UUID>
    @State private var error: String?

    init(group: BackupGroup?, jobs: [BackupJob], onSave: @escaping (BackupGroup) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _members = State(initialValue: Set(jobs.filter { group != nil && $0.groupID == group?.id }.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(group == nil ? "group.new" : "group.edit")).font(.title2.weight(.semibold))
            TextField(L10n.text("group.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("group-name")
            if !store.jobs.isEmpty {
                Text(L10n.text("common.jobs")).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.jobs) { job in
                            Toggle(isOn: Binding(
                                get: { members.contains(job.id) },
                                set: { if $0 { members.insert(job.id) } else { members.remove(job.id) } }
                            )) {
                                HStack {
                                    Label(job.name, systemImage: job.kind.symbol)
                                    Spacer()
                                    if let other = store.groups.first(where: { $0.id == job.groupID && $0.id != group?.id }) {
                                        Text(other.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 240)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("common.save")) {
                    do {
                        let saved = try store.saveGroup(name: name, id: group?.id, jobIDs: members)
                        onSave(saved)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("group-save")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
