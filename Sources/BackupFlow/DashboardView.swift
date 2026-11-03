import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: BackupStore
    let onCreate: () -> Void
    let onSelect: (UUID) -> Void
    var group: BackupGroup? = nil

    private var visibleJobs: [BackupJob] {
        store.jobs.filter { group == nil || $0.groupID == group?.id }
    }
    private var visibleHistory: [BackupRun] {
        let ids = Set(visibleJobs.map(\.id))
        return store.history.filter { group == nil || ids.contains($0.jobID) }
    }

    private func snapshot(_ job: BackupJob) -> JobSnapshot {
        JobSnapshot(jobID: job.id, history: store.history, isRunning: store.runningJobIDs.contains(job.id))
    }

    private var attention: [BackupJob] {
        visibleJobs.filter { snapshot($0).health.needsAttention }
    }

    private var otherJobs: [BackupJob] {
        visibleJobs.filter { !snapshot($0).health.needsAttention }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group?.name ?? L10n.text("dashboard.subtitle"))
                        .font(.system(size: 26, weight: .semibold))
                    if group == nil {
                        Text(L10n.text("ux.overview_hint")).foregroundStyle(.secondary)
                    }
                }

                if visibleJobs.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text(group == nil ? "dashboard.no_jobs" : "group.empty"), systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text(L10n.text("dashboard.create_first_job"))
                    } actions: {
                        Button(L10n.text("dashboard.create_job"), action: onCreate)
                            .buttonStyle(PrimaryActionButtonStyle())
                    }
                    .frame(minHeight: 300)
                } else {
                    if group == nil && !store.groups.isEmpty {
                        ForEach(store.groups) { group in
                            let jobs = visibleJobs.filter { $0.groupID == group.id }
                            if !jobs.isEmpty { jobSection(group.name, jobs: jobs) }
                        }
                        let ungrouped = visibleJobs.filter { $0.groupID == nil }
                        if !ungrouped.isEmpty { jobSection(L10n.text("group.none"), jobs: ungrouped) }
                    } else {
                        if !attention.isEmpty { jobSection(L10n.text("ux.attention"), jobs: attention) }
                        if !otherJobs.isEmpty { jobSection(L10n.text("ux.backups"), jobs: otherJobs) }
                    }
                    if !store.schedulerEnabled && visibleJobs.contains(where: { $0.schedule != .manual }) {
                        Label(L10n.text("status.scheduler_paused"), systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if !visibleHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("dashboard.recent_runs"))
                                .font(.system(size: 15, weight: .semibold))
                            ForEach(visibleHistory.prefix(3)) { run in
                                RunRow(run: run)
                                if run.id != visibleHistory.prefix(3).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.background)
        .navigationTitle(group?.name ?? L10n.text("common.overview"))
        .toolbar {
            if let group {
                Button(L10n.text("group.run"), systemImage: "play.fill") { store.runGroup(group.id) }
                    .disabled(store.runnableJobs(in: group.id).isEmpty)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            if group == nil {
            Button(L10n.text("common.new_job"), systemImage: "plus", action: onCreate)
                .labelStyle(.titleAndIcon)
                .buttonStyle(PrimaryActionButtonStyle())
            } else {
                Button(L10n.text("common.new_job"), systemImage: "plus", action: onCreate)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private func jobSection(_ title: String, jobs: [BackupJob]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(jobs) { job in
                    if job.id != jobs.first?.id { Divider().padding(.horizontal, 16) }
                    jobRow(job)
                }
            }
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func jobRow(_ job: BackupJob) -> some View {
        let status = snapshot(job)
        return Button { onSelect(job.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: job.kind.symbol)
                        .font(.system(size: 22))
                        .frame(width: 30)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name).font(.system(size: 15, weight: .semibold))
                        Label(L10n.text(status.health.titleKey), systemImage: status.health.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(status.health.color)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        successSummary(status, job: job)
                        scheduleSummary(job)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        successSummary(status, job: job)
                        scheduleSummary(job)
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.text("ux.open_job"))
    }

    private func successSummary(_ status: JobSnapshot, job: BackupJob) -> some View {
        summary(L10n.text("ux.last_success"),
                value: (store.folderSyncStates[job.id]?.checkpoint.lastSuccess ?? status.latestSuccess?.finishedAt)?.formatted(date: .abbreviated, time: .shortened)
                    ?? L10n.text("ux.no_success"))
    }

    @ViewBuilder
    private func scheduleSummary(_ job: BackupJob) -> some View {
        if job.isFolderSync && job.schedule == .onVolumeMount {
            summary(L10n.text("sync.pending"), value: store.syncPendingText(for: job) + " · " + store.trayState(for: job).title)
        } else {
        summary(L10n.text("job.next_run"), value: BackupScheduleState(
            job: job, schedulerEnabled: store.schedulerEnabled,
            isRunning: store.runningJobIDs.contains(job.id)
        ).text)
        }
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
