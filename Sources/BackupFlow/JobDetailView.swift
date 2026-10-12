import AppKit
import SwiftUI

struct JobDetailView: View {
    @EnvironmentObject private var store: BackupStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let job: BackupJob
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirmation = false
    @State private var parametersExpanded = false
    @State private var activityExpanded = false

    private var isRunning: Bool { store.runningJobIDs.contains(job.id) }
    private var runs: [BackupRun] {
        store.history.filter { $0.jobID == job.id }.sorted { $0.finishedAt > $1.finishedAt }
    }
    private var snapshot: JobSnapshot {
        JobSnapshot(jobID: job.id, history: store.history, isRunning: isRunning)
    }
    private var activityLogs: [String] {
        let logs = store.logs(for: job.id)
        if !logs.isEmpty { return logs }
        return snapshot.latestAttempt.map { [$0.message] } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: job.kind.symbol)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.name).font(.system(size: 26, weight: .semibold))
                            .textSelection(.enabled)
                        Text((job.kind == .postgres || job.kind == .mysql)
                             ? "\(job.kind.title) · \(job.connectionMode.title)" : job.kind.title)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                result
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        lastSuccess
                        nextRun
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        lastSuccess
                        nextRun
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("dashboard.recent_runs")).font(.system(size: 15, weight: .semibold))
                    if runs.isEmpty {
                        Text(L10n.text("job.history_empty"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(runs.prefix(5)) { run in
                            RunRow(run: run)
                            if run.id != runs.prefix(5).last?.id { Divider() }
                        }
                    }
                }

                Divider()
                DisclosureGroup(isExpanded: $parametersExpanded) {
                    configuration.padding(.top, 16)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("ux.backup_parameters"))
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(URL(fileURLWithPath: job.destinationPath).lastPathComponent) · \(job.archiveOutput ? L10n.text("job.archive_enabled") : L10n.text("job.archive_disabled"))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .background(AppTheme.background)
        .navigationTitle(job.name)
        .toolbar {
            Button(L10n.text("common.edit"), action: onEdit)
            Button {
                if isRunning { store.cancel(job) } else { store.run(job) }
            } label: {
                Label(L10n.text(isRunning ? "job.stop" : "ux.create_backup"),
                      systemImage: isRunning ? "stop.fill" : "play.fill")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(PrimaryActionButtonStyle())
            Menu {
                Button(L10n.text("job.delete_action"), role: .destructive) {
                    showDeleteConfirmation = true
                }
            } label: {
                Label(L10n.text("ux.more_actions"), systemImage: "ellipsis")
            }
        }
        .alert(L10n.text("job.delete_title"), isPresented: $showDeleteConfirmation) {
            Button(L10n.text("common.delete"), role: .destructive, action: onDelete)
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("job.delete_message", job.name))
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                BackupHealthIndicator(health: snapshot.health)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text(snapshot.health.titleKey))
                        .font(.system(size: 17, weight: .semibold))
                        .id(snapshot.health)
                        .transition(.opacity)
                    if isRunning {
                        Text(store.currentMessage(for: job.id))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let start = store.startedAtByJob[job.id] {
                            HStack(spacing: 6) {
                                Text(L10n.text("ux.elapsed"))
                                Text(start, style: .timer).monospacedDigit()
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                        }
                    } else if let run = snapshot.latestAttempt {
                        Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        if run.status != .success {
                            Text(run.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(L10n.text("ux.first_backup_hint")).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            // The activity ring deliberately has no percentage: dump sizes
            // are unknown and engine fractions are only diagnostic checkpoints.
            if isRunning || !activityLogs.isEmpty || snapshot.latestAttempt?.outputPath != nil {
                HStack(spacing: 12) {
                    if isRunning || !activityLogs.isEmpty {
                        Button {
                            withAnimation(BackupMotion.transition(reduceMotion: reduceMotion)) {
                                activityExpanded.toggle()
                            }
                        } label: {
                            Label(L10n.text(activityExpanded ? "ux.hide_log" : "ux.show_log"),
                                  systemImage: "terminal")
                        }
                        .accessibilityValue(L10n.text(activityExpanded ? "ux.expanded" : "ux.collapsed"))
                    }
                    if !isRunning, let run = snapshot.latestAttempt, run.outputPath != nil {
                        Button(L10n.text("common.show_in_finder"), systemImage: "folder") { store.reveal(run) }
                    }
                }
                .controlSize(.regular)
            }
            if activityExpanded {
                LogOutput(lines: activityLogs, isLive: isRunning)
                    .frame(height: 200)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(snapshot.health.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .animation(BackupMotion.transition(reduceMotion: reduceMotion), value: snapshot.health)
    }

    private var lastSuccess: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("ux.last_success")).font(.system(size: 13, weight: .semibold))
            if let run = snapshot.latestSuccess {
                Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                if let size = run.outputSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.text("ux.no_success")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var nextRun: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("job.next_run")).font(.system(size: 13, weight: .semibold))
            Text(BackupScheduleState(job: job, schedulerEnabled: store.schedulerEnabled,
                                     isRunning: isRunning).text)
            if job.schedule != .manual {
                Text(job.scheduleDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(L10n.text("ux.schedule_open"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var configuration: some View {
        VStack(spacing: 16) {
            DetailRow(title: L10n.text("common.source"), value: sourceDescription, monospaced: true)
            DetailRow(title: L10n.text("job.destination_folder"), value: job.destinationPath, monospaced: true)
            DetailRow(title: L10n.text("job.output_format"),
                      value: L10n.text(job.archiveOutput ? "job.archive_enabled" : "job.archive_disabled"))
            DetailRow(title: L10n.text("job.name_mask"), value: job.nameMask, monospaced: true)
            DetailRow(title: L10n.text("job.retention"), value: job.retentionCount > 0
                      ? L10n.text("job.retention_count", job.retentionCount) : L10n.text("job.retention_all"))
            if job.kind == .project {
                DetailRow(title: L10n.text("job.project_exclusions"), value: job.projectExclusions, monospaced: true)
            }
            if job.hasDatabaseSource && !job.excludedDatabaseTables.isEmpty {
                DetailRow(title: L10n.text("database.excluded_tables"),
                          value: job.excludedDatabaseTables.map(\.displayName).joined(separator: ", "), monospaced: true)
                Text(L10n.text("database.exclusion_note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if job.kind == .postgres || job.kind == .mysql {
                DetailRow(title: L10n.text("common.connection"), value: job.connectionMode.title)
                if job.connectionMode == .direct {
                    DetailRow(title: L10n.text("job.client"), value: job.clientExecutablePath.isEmpty
                              ? L10n.text("editor.automatic_search") : job.clientExecutablePath, monospaced: true)
                }
            }
            HStack {
                Button(L10n.text("common.edit"), action: onEdit)
                Spacer()
            }
        }
    }

    private var sourceDescription: String {
        switch job.kind {
        case .files, .project, .sqlite: job.sourcePath
        case .postgres, .mysql: job.connectionDescription
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        MetadataRow(title: title, value: value, monospaced: monospaced)
    }
}

struct RunRow: View {
    @EnvironmentObject private var store: BackupStore
    @State private var showLog = false
    let run: BackupRun

    private var health: BackupHealth {
        switch run.status {
        case .success: .success
        case .failure: .failure
        case .cancelled: .cancelled
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: health.symbol)
                .font(.system(size: 20))
                .foregroundStyle(health.color)
                .frame(width: 24, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(run.jobName).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(L10n.text("status.\(run.status.rawValue)")).foregroundStyle(health.color)
                    Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                Text(run.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Button { showLog = true } label: {
                        Label(L10n.text("activity.log"), systemImage: "terminal")
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 28)
                    }
                    .help(L10n.text("activity.log"))
                    if run.outputPath != nil {
                        Button { store.reveal(run) } label: {
                            Label(L10n.text("common.show_in_finder"), systemImage: "folder")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                        }
                        .help(L10n.text("common.show_in_finder"))
                    }
                }
                .buttonStyle(.borderless)
                if let size = run.outputSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showLog) { RunLogSheet(run: run) }
    }
}

private struct LogOutput: View {
    let lines: [String]
    var isLive = false
    @State private var followLatest = true

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 6) {
                            if lines.isEmpty {
                                Text(L10n.text("activity.waiting")).foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line).textSelection(.enabled)
                                }
                            }
                            Color.clear.frame(height: 1).id("latest-log-line")
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    // Never animate a stream of log lines or keep pulling the
                    // reader back when they turn following off.
                    .onAppear { if isLive && followLatest { proxy.scrollTo("latest-log-line", anchor: .bottomLeading) } }
                    .onChange(of: lines.last) { _, _ in
                        if isLive && followLatest { proxy.scrollTo("latest-log-line", anchor: .bottomLeading) }
                    }
                    .onChange(of: followLatest) { _, follow in
                        if isLive && follow { proxy.scrollTo("latest-log-line", anchor: .bottomLeading) }
                    }
                    .transaction { $0.animation = nil }
                }
            }
            if isLive {
                Divider()
                Toggle(L10n.text("activity.follow_log"), isOn: $followLatest)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border) }
    }
}

private struct RunLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: BackupRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("activity.log")).font(.system(size: 20, weight: .semibold))
                    Text("\(run.jobName) · \(run.finishedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            LogOutput(lines: run.logs?.isEmpty == false ? run.logs! : [run.message])
            if let path = run.outputPath {
                Text(path).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).lineLimit(2)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 400, idealHeight: 460)
        .background(AppTheme.background)
    }
}
