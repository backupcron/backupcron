import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: BackupStore
    let onCreate: () -> Void
    let onSelect: (UUID) -> Void

    private func snapshot(_ job: BackupJob) -> JobSnapshot {
        JobSnapshot(jobID: job.id, history: store.history, isRunning: store.runningJobIDs.contains(job.id))
    }

    private var attention: [BackupJob] {
        store.jobs.filter { snapshot($0).health.needsAttention }
    }

    private var otherJobs: [BackupJob] {
        store.jobs.filter { !snapshot($0).health.needsAttention }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("dashboard.subtitle"))
                        .font(.system(size: 26, weight: .semibold))
                    Text(L10n.text("ux.overview_hint"))
                        .foregroundStyle(.secondary)
                }

                if store.jobs.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("dashboard.no_jobs"), systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text(L10n.text("dashboard.create_first_job"))
                    } actions: {
                        Button(L10n.text("dashboard.create_job"), action: onCreate)
                            .buttonStyle(PrimaryActionButtonStyle())
                    }
                    .frame(minHeight: 300)
                } else {
                    if !attention.isEmpty {
                        jobSection(L10n.text("ux.attention"), jobs: attention)
                    }
                    if !otherJobs.isEmpty {
                        jobSection(L10n.text("ux.backups"), jobs: otherJobs)
                    }
                    if store.jobs.contains(where: { $0.schedule != .manual }) {
                        Label(store.schedulerEnabled ? L10n.text("settings.schedule_note")
                              : L10n.text("status.scheduler_paused"), systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if !store.history.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("dashboard.recent_runs"))
                                .font(.system(size: 15, weight: .semibold))
                            ForEach(store.history.prefix(3)) { run in
                                RunRow(run: run)
                                if run.id != store.history.prefix(3).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.background)
        .navigationTitle(L10n.text("common.overview"))
        .toolbar {
            Button(L10n.text("common.new_job"), systemImage: "plus", action: onCreate)
                .labelStyle(.titleAndIcon)
                .buttonStyle(PrimaryActionButtonStyle())
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
                        successSummary(status)
                        scheduleSummary(job)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        successSummary(status)
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

    private func successSummary(_ status: JobSnapshot) -> some View {
        summary(L10n.text("ux.last_success"),
                value: status.latestSuccess?.finishedAt.formatted(date: .abbreviated, time: .shortened)
                    ?? L10n.text("ux.no_success"))
    }

    private func scheduleSummary(_ job: BackupJob) -> some View {
        summary(L10n.text("job.next_run"), value: BackupScheduleState(
            job: job, schedulerEnabled: store.schedulerEnabled,
            isRunning: store.runningJobIDs.contains(job.id)
        ).text)
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
