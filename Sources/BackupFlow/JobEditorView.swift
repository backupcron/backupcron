import AppKit
import SwiftUI

struct JobEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: BackupStore
    @State private var draft: BackupJob
    @State private var password = ""
    @State private var isLoadingPassword = false
    @State private var passwordWasEdited = false
    @State private var passwordLoadToken = UUID()
    @State private var sourceIsDirectory = false
    @State private var activeStep: JobSetupStep = .source
    @State private var furthestStep: JobSetupStep = .source
    @State private var destinationOptionsExpanded = false
    @State private var projectOptionsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isEditing: Bool
    @State private var advancedExpanded = false
    @State private var connectionTestState: ConnectionTestState = .idle
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var databaseCatalog: DatabaseCatalog?
    @State private var catalogTask: Task<Void, Never>?
    @State private var catalogToken = UUID()
    @State private var catalogLoading = false
    @State private var catalogError: String?
    @State private var tableSearch = ""
    @State private var tablesBySize = true
    @State private var selectionDraft = DatabaseSelectionDraft()
    @State private var spaceRequirements: [DatabaseSpaceRequirement] = []
    private let originalJob: BackupJob?

    let onSave: (BackupJob, String?) throws -> Void

    init(job: BackupJob, isEditing: Bool = false, onSave: @escaping (BackupJob, String?) throws -> Void) {
        _draft = State(initialValue: job)
        self.onSave = onSave
        self.isEditing = isEditing
        originalJob = isEditing ? job : nil
    }

    private var isDatabase: Bool {
        draft.kind == .postgres || draft.kind == .mysql
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.border)

            stepRail
            Divider().overlay(AppTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch activeStep {
                    case .source:
                        sourceSection
                        if isDatabase { connectionSection }
                        if draft.hasDatabaseSource { databaseTablesSection }
                    case .destination:
                        destinationSection
                    case .schedule:
                        scheduleSection
                        scheduleReview
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(activeStep)
            .background(AppTheme.background)

            Divider().overlay(AppTheme.border)
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 570, idealHeight: 650)
        .font(.system(size: 13))
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .alert(L10n.text("store.operation_failed"), isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(L10n.text("common.close")) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onAppear {
            loadStoredPassword()
        }
        .task(id: draft.sourcePath) {
            sourceIsDirectory = false
            let path = draft.sourcePath
            let bookmark = draft.sourceBookmark
            guard !path.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let isDirectory = await Task.detached(priority: .utility) {
                let source = bookmark?.resolve(matching: path) ?? URL(fileURLWithPath: path)
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                return (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.value
            guard !Task.isCancelled else { return }
            sourceIsDirectory = isDirectory
        }
        .onChange(of: draft.kind) { previous, current in
            if previous != current {
                if current == .mysql && draft.port == 5432 { draft.port = 3306 }
                if current == .postgres && draft.port == 3306 { draft.port = 5432 }
            }
        }
        .onChange(of: draft) { previous, current in
            if previous.databaseConnectionIdentity != current.databaseConnectionIdentity {
                resetConnectionTest()
                resetDatabaseCatalog()
            }
            if previous.databaseTargetIdentity != current.databaseTargetIdentity {
                draft.excludedDatabaseTables = selectionDraft.move(from: previous, to: current)
            }
        }
        .task(id: SpacePreviewInput(job: draft, catalog: databaseCatalog)) {
            spaceRequirements = []
            guard draft.hasDatabaseSource, !draft.destinationPath.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let job = draft
            let catalog = databaseCatalog
            let result = await Task.detached(priority: .utility) {
                try? BackupEngine().databaseSpacePlan(job: job, catalog: catalog)
            }.value
            guard !Task.isCancelled else { return }
            spaceRequirements = result ?? []
        }
        .onChange(of: password) { _, _ in
            resetConnectionTest()
            resetDatabaseCatalog()
        }
        .onDisappear {
            passwordLoadToken = UUID()
            connectionTestTask?.cancel()
            resetDatabaseCatalog()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Text(
                !isEditing
                    ? L10n.text("common.new_job")
                    : L10n.text("editor.configure_title", draft.name)
            )
            .font(.system(size: 21, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(AppTheme.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("common.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(AppTheme.toolbar)
    }

    private var stepRail: some View {
        HStack(spacing: 16) {
            ForEach(JobSetupStep.allCases) { step in
                Button {
                    activeStep = step
                } label: {
                    VStack(spacing: 12) {
                        Text("\(step.rawValue + 1). \(step.title)")
                            .font(.system(size: 13, weight: activeStep == step ? .semibold : .regular))
                            .foregroundStyle(activeStep == step ? AppTheme.accent : AppTheme.secondaryText)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(activeStep == step ? AppTheme.accent : AppTheme.border)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditing && step.rawValue > furthestStep.rawValue)
                .accessibilityAddTraits(activeStep == step ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var sourceSection: some View {
        EditorSection(title: L10n.text("ux.source_title"), symbol: "tray.full.fill") {
            HStack(alignment: .top, spacing: 16) {
                EditorField(title: L10n.text("editor.name")) {
                    TextField(L10n.text("editor.name_placeholder"), text: $draft.name)
                }
                EditorField(title: L10n.text("editor.data_type")) {
                    Picker(L10n.text("editor.data_type"), selection: $draft.kind) {
                        ForEach(BackupKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 250)
            }

            if draft.kind == .files || draft.kind == .project || draft.kind == .sqlite {
                EditorField(title: sourceFieldTitle) {
                    PathField(text: $draft.sourcePath, placeholder: L10n.text("editor.choose_source"), action: chooseSource)
                }
            }

            if draft.kind == .project {
                EditorToggle(title: L10n.text("editor.include_git"),
                             hint: L10n.text("editor.include_git_hint"), isOn: $draft.includesGitMetadata)
                if !draft.includesGitMetadata {
                    Label(L10n.text("editor.git_excluded_warning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("editor.git_scope_note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.text("editor.project_exclusions"), isExpanded: $projectOptionsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.text("editor.project_exclusions_hint"), text: $draft.projectExclusions)
                            .accessibilityLabel(L10n.text("editor.project_exclusions"))
                        Text(L10n.text("editor.project_exclusions_note"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }
            }
        }
    }

    private var connectionSection: some View {
        EditorSection(title: L10n.text("common.connection"), symbol: "link") {
            EditorField(title: L10n.text("editor.connection_mode")) {
                Picker(L10n.text("common.connection"), selection: $draft.connectionMode) {
                    ForEach(DatabaseConnectionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if draft.connectionMode == .docker {
                EditorField(title: L10n.text("editor.container")) {
                    TextField(L10n.text("editor.container_placeholder"), text: $draft.dockerContainer)
                }
            }

            if draft.connectionMode == .ssh {
                HStack(alignment: .top, spacing: 16) {
                    EditorField(title: L10n.text("editor.ssh_server")) {
                        TextField("server.example.com", text: $draft.sshHost)
                    }
                    EditorField(title: L10n.text("editor.ssh_port")) {
                        TextField("22", value: $draft.sshPort, format: .number.grouping(.never))
                    }
                    .frame(width: 150)
                }
                HStack(alignment: .top, spacing: 16) {
                    EditorField(title: L10n.text("editor.ssh_user")) {
                        TextField("deploy", text: $draft.sshUsername)
                    }
                    EditorField(title: L10n.text("editor.ssh_key")) {
                        PathField(text: $draft.sshIdentityPath, placeholder: L10n.text("common.optional"), action: chooseSSHKey)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                EditorField(title: L10n.text("editor.db_host")) {
                    TextField("localhost", text: $draft.host)
                }
                EditorField(title: L10n.text("editor.db_port")) {
                    TextField(L10n.text("editor.port"), value: $draft.port, format: .number.grouping(.never))
                }
                EditorField(title: L10n.text("editor.database")) {
                    TextField(L10n.text("editor.database_name"), text: $draft.databaseName)
                }
                EditorField(title: L10n.text("editor.db_user")) {
                    TextField(L10n.text("editor.username"), text: $draft.username)
                }
            }

            HStack(alignment: .bottom, spacing: 20) {
                if draft.connectionMode != .ssh {
                    EditorField(title: L10n.text("editor.password")) {
                        HStack(spacing: 8) {
                            SecureField(L10n.text("editor.keychain_hint"), text: passwordBinding)
                            if isLoadingPassword {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                } else {
                    Label(L10n.text("editor.ssh_auth_hint"), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(L10n.text("editor.require_secure_connection"), isOn: $draft.useSSL)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                    .fixedSize()
            }

            if draft.connectionMode == .direct {
                Divider().overlay(AppTheme.border)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        advancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("editor.advanced_options"))
                                .font(.system(size: 11, weight: .medium))
                            Text(L10n.text("editor.advanced_hint"))
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if advancedExpanded {
                    EditorField(title: draft.kind == .postgres ? L10n.text("editor.pg_dump_path") : L10n.text("editor.mysqldump_path")) {
                        PathField(text: $draft.clientExecutablePath, placeholder: L10n.text("editor.automatic_search"), action: chooseClientExecutable)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Divider().overlay(AppTheme.border)
            connectionTestControls
        }
    }

    private var connectionTestControls: some View {
        HStack(spacing: 12) {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 7) {
                    if connectionTestState.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(
                        connectionTestState.isRunning
                            ? L10n.text("editor.testing_connection")
                            : L10n.text("editor.test_connection")
                    )
                }
            }
            .disabled(connectionValidationMessage != nil || connectionTestState.isRunning
                      || (isLoadingPassword && draft.connectionMode != .ssh))

            switch connectionTestState {
            case .idle, .running:
                if let connectionValidationMessage {
                    Label(connectionValidationMessage, systemImage: "info.circle")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.success)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.danger)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    private var destinationSection: some View {
        EditorSection(title: L10n.text("ux.destination_title"), symbol: "folder") {
            EditorField(title: L10n.text("editor.backup_folder")) {
                PathField(text: $draft.destinationPath, placeholder: L10n.text("editor.choose_folder"), action: chooseDestination)
            }
            EditorToggle(title: L10n.text("editor.create_archive"),
                         hint: L10n.text("editor.create_archive_hint"), isOn: $draft.archiveOutput)
            if draft.hasDatabaseSource { databaseSpaceSection }

            DisclosureGroup(isExpanded: $destinationOptionsExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    EditorField(title: L10n.text("editor.output_name_mask")) {
                        TextField(BackupJob.defaultNameMask, text: $draft.nameMask)
                            .font(.system(size: 13, design: .monospaced))
                            .accessibilityLabel(L10n.text("editor.output_name_mask"))
                    }
                    Text(L10n.text("editor.name_mask_hint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    EditorToggle(title: L10n.text("editor.retention"),
                                 hint: L10n.text("editor.retention_hint"), isOn: retentionEnabledBinding)
                    if draft.retentionCount > 0 {
                        Stepper(value: $draft.retentionCount, in: 1...100) {
                            Text(L10n.text("editor.keep_last_count", draft.retentionCount))
                        }
                        Text(L10n.text("editor.retention_safety_note"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 16)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("ux.output_options")).fontWeight(.medium)
                    Text(L10n.text("ux.output_options_hint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)

            Text(L10n.text("editor.name_preview", outputNamePreview))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var databaseTablesSection: some View {
        EditorSection(title: L10n.text("database.tables_title"), symbol: "tablecells") {
            HStack(spacing: 12) {
                Button(action: loadDatabaseCatalog) {
                    Label(L10n.text(databaseCatalog == nil ? "database.load" : "database.refresh"),
                          systemImage: "arrow.clockwise")
                }
                .disabled(catalogLoading || JobSetupStep.source.validationKey(for: draft) != nil ||
                          (isDatabase && isLoadingPassword && draft.connectionMode != .ssh))
                if catalogLoading {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("database.loading")).foregroundStyle(.secondary)
                    Button(L10n.text("common.cancel"), action: resetDatabaseCatalog)
                }
                Spacer()
            }
            if let catalogError {
                Text(catalogError).foregroundStyle(AppTheme.danger)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let catalog = databaseCatalog {
                HStack(alignment: .top, spacing: 24) {
                    databaseSizeLabel("database.total_size", bytes: catalog.sizeBytes)
                    databaseSizeLabel("database.selected_size", bytes: catalog.selectedSize(excluding: draft.excludedDatabaseTables))
                }
                Text(L10n.text("database.size_note"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(L10n.text("database.search"), text: $tableSearch)
                        .textFieldStyle(.roundedBorder)
                    Picker(L10n.text("database.sort"), selection: $tablesBySize) {
                        Text(L10n.text("database.sort_size")).tag(true)
                        Text(L10n.text("database.sort_name")).tag(false)
                    }.labelsHidden().frame(width: 160)
                    Button(L10n.text("database.include_all")) { draft.excludedDatabaseTables = [] }
                        .disabled(draft.excludedDatabaseTables.isEmpty)
                }
                if catalog.tables.isEmpty {
                    Text(L10n.text("database.empty")).foregroundStyle(.secondary)
                } else {
                    let excluded = catalog.effectiveExclusions(draft.excludedDatabaseTables)
                    Text(L10n.text("database.selected_count", catalog.tables.filter { !excluded.contains($0.id) }.count,
                                   catalog.tables.count))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleDatabaseTables) { table in
                                databaseTableRow(table, excluded: excluded)
                                Divider()
                            }
                        }
                    }.frame(height: min(260, CGFloat(max(1, visibleDatabaseTables.count)) * 45))
                    if visibleDatabaseTables.isEmpty {
                        Text(L10n.text("database.no_matches")).foregroundStyle(.secondary)
                    }
                }
                let missing = draft.excludedDatabaseTables.filter { reference in
                    !catalog.tables.contains { $0.id == reference }
                }
                ForEach(missing, id: \.self) { reference in
                    HStack {
                        Text(L10n.text("database.missing_exclusion", reference.displayName))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("database.include")) {
                            draft.excludedDatabaseTables.removeAll { $0 == reference }
                        }
                    }
                }
                if !draft.excludedDatabaseTables.isEmpty {
                    Text(L10n.text("database.exclusion_note"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = catalog.selectionError(excluding: draft.excludedDatabaseTables) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.warning).fixedSize(horizontal: false, vertical: true)
                }
            } else if !catalogLoading {
                Text(L10n.text(requiresDatabaseInspection ? "database.load_hint" : "database.offline_edit"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !draft.excludedDatabaseTables.isEmpty {
                    Text(L10n.text("database.excluded_tables") + ": " + draft.excludedDatabaseTables.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let originalJob, draft.databaseTargetIdentity != originalJob.databaseTargetIdentity,
               !originalJob.excludedDatabaseTables.isEmpty {
                Text(L10n.text("database.source_changed"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct SpacePreviewInput: Equatable {
        var job: BackupJob
        var catalog: DatabaseCatalog?
    }

    private var requiresDatabaseInspection: Bool {
        DatabaseSelectionDraft.requiresInspection(original: originalJob, draft: draft, passwordChanged: passwordWasEdited)
    }

    private var databaseSpaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("database.space_title")).fontWeight(.medium)
            ForEach(spaceRequirements) { requirement in
                Text(L10n.text("database.space_summary", L10n.text(requirement.locationKey),
                    formattedDatabaseSize(requirement.requiredBytes), formattedDatabaseSize(requirement.disk.availableBytes)))
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(requirement.isInsufficient ? AppTheme.warning : AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text(draft.kind == .sqlite ? "database.space_sqlite_note" : "database.space_sql_note"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func databaseSizeLabel(_ key: String, bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(key)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(formattedDatabaseSize(bytes)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedDatabaseSize(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.text("database.unknown_size")
    }

    private var visibleDatabaseTables: [DatabaseTableInfo] {
        (databaseCatalog?.tables ?? []).filter {
            tableSearch.isEmpty || $0.id.displayName.localizedCaseInsensitiveContains(tableSearch)
        }.sorted {
            if tablesBySize && $0.sizeBytes != $1.sizeBytes { return ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
            return $0.id.displayName.localizedStandardCompare($1.id.displayName) == .orderedAscending
        }
    }

    private func databaseTableRow(_ table: DatabaseTableInfo, excluded: Set<DatabaseTableReference>) -> some View {
        let inherited = excluded.contains(table.id) && !draft.excludedDatabaseTables.contains(table.id)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { !excluded.contains(table.id) }, set: { included in
                draft.excludedDatabaseTables.removeAll { $0 == table.id }
                if !included { draft.excludedDatabaseTables.append(table.id) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.id.displayName).font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).help(table.id.displayName)
                    if inherited {
                        Text(L10n.text("database.excluded_parent")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.toggleStyle(.checkbox).disabled(inherited)
            Spacer()
            if table.objectType == "view" {
                Text(L10n.text("database.view")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(formattedDatabaseSize(table.sizeBytes)).monospacedDigit()
                .foregroundStyle(.secondary).frame(minWidth: 80, alignment: .trailing)
        }.frame(height: 44).padding(.horizontal, 4)
    }

    private func loadDatabaseCatalog() {
        resetDatabaseCatalog()
        catalogLoading = true
        let token = catalogToken
        let job = draft
        let secret = password
        catalogTask = Task {
            do {
                let result = try await BackupEngine().inspectDatabase(job: job, password: secret)
                try Task.checkCancellation()
                guard catalogToken == token else { return }
                databaseCatalog = result
                catalogLoading = false
            } catch {
                guard catalogToken == token else { return }
                catalogLoading = false
                if !(error is CancellationError) { catalogError = error.localizedDescription }
            }
        }
    }

    private func resetDatabaseCatalog() {
        catalogToken = UUID()
        catalogTask?.cancel()
        catalogTask = nil
        databaseCatalog = nil
        catalogLoading = false
        catalogError = nil
    }

    private var scheduleSection: some View {
        EditorSection(title: L10n.text("ux.schedule_title"), symbol: "clock") {
            HStack(alignment: .bottom, spacing: 16) {
                EditorField(title: L10n.text("editor.repeat")) {
                    Picker(L10n.text("editor.repeat"), selection: $draft.schedule) {
                        ForEach(ScheduleKind.allCases) { schedule in
                            Text(schedule.title).tag(schedule)
                        }
                    }
                    .labelsHidden()
                }

                if draft.schedule != .manual {
                    Toggle(L10n.text("editor.job_active"), isOn: $draft.isEnabled)
                        .toggleStyle(.switch)
                        .fixedSize()
                        .padding(.bottom, 4)
                }
            }

            HStack(alignment: .bottom, spacing: 24) {
                if draft.schedule == .interval {
                    EditorField(title: L10n.text("editor.interval")) {
                        Stepper(
                            value: $draft.intervalMinutes,
                            in: BackupJob.minimumIntervalMinutes...BackupJob.maximumIntervalMinutes,
                            step: 5
                        ) {
                            Text(L10n.text("schedule.every_minutes", draft.intervalMinutes))
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 230)
                }

                if draft.schedule == .daily || draft.schedule == .weekly {
                    EditorField(title: L10n.text("editor.time")) {
                        DatePicker(L10n.text("editor.time"), selection: $draft.scheduledTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if draft.schedule == .weekly {
                    EditorField(title: L10n.text("editor.weekday")) {
                        Picker(L10n.text("editor.weekday"), selection: $draft.weekday) {
                            ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, title in
                                Text(title.capitalized).tag(index + 1)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var scheduleReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("settings.schedule_note"), systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            MetadataRow(title: L10n.text("editor.name"), value: draft.name)
            MetadataRow(title: L10n.text("job.destination_folder"), value: draft.destinationPath)
            MetadataRow(title: L10n.text("job.output_format"),
                        value: L10n.text(draft.archiveOutput ? "job.archive_enabled" : "job.archive_disabled"))
            MetadataRow(title: L10n.text("job.next_run"),
                        value: BackupScheduleState(job: draft, schedulerEnabled: store.schedulerEnabled, isRunning: false).text)
            if draft.hasDatabaseSource && !draft.excludedDatabaseTables.isEmpty {
                MetadataRow(title: L10n.text("database.excluded_tables"),
                            value: draft.excludedDatabaseTables.map(\.displayName).joined(separator: ", "))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L10n.text("common.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 270, alignment: .trailing)
            }
            if activeStep != .source {
                Button(L10n.text("ux.back")) {
                    activeStep = JobSetupStep(rawValue: activeStep.rawValue - 1) ?? .source
                }
            }
            Button(L10n.text(activeStep == .schedule ? "common.save" : "ux.next")) {
                if activeStep != .schedule {
                    activeStep = JobSetupStep(rawValue: activeStep.rawValue + 1) ?? .schedule
                    if activeStep.rawValue > furthestStep.rawValue { furthestStep = activeStep }
                } else {
                    do {
                        try onSave(draft, passwordWasEdited ? password : nil)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(validationMessage != nil)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(AppTheme.toolbar)
    }

    private var validationMessage: String? {
        let key = activeStep == .schedule
            ? JobSetupStep.allCases.compactMap { $0.validationKey(for: draft) }.first
            : activeStep.validationKey(for: draft)
        if let key { return L10n.text(key) }
        if draft.hasDatabaseSource && (activeStep == .source || activeStep == .schedule) {
            if let databaseCatalog {
                if let error = databaseCatalog.selectionError(excluding: draft.excludedDatabaseTables) { return error }
            } else if requiresDatabaseInspection { return L10n.text("database.load_hint") }
        }
        if draft.kind == .sqlite && (activeStep == .destination || activeStep == .schedule),
           let requirement = spaceRequirements.first(where: \.isInsufficient) {
            return L10n.text("database.space_insufficient", requirement.disk.path,
                formattedDatabaseSize(requirement.requiredBytes), formattedDatabaseSize(requirement.disk.availableBytes))
        }
        return nil
    }

    private var connectionValidationMessage: String? {
        guard isDatabase else { return nil }
        return JobSetupStep.source.validationKey(for: draft).map { L10n.text($0) }
    }

    private func testConnection() {
        guard connectionValidationMessage == nil else { return }
        connectionTestTask?.cancel()
        connectionTestState = .running
        let job = draft
        let password = password
        connectionTestTask = Task {
            do {
                let message = try await BackupEngine().testConnection(job: job, password: password)
                try Task.checkCancellation()
                connectionTestState = .success(message)
            } catch is CancellationError {
                connectionTestState = .idle
            } catch {
                connectionTestState = .failure(
                    L10n.text("editor.connection_failed", error.localizedDescription)
                )
            }
        }
    }

    private func resetConnectionTest() {
        guard !connectionTestState.isRunning else {
            connectionTestTask?.cancel()
            connectionTestState = .idle
            return
        }
        connectionTestState = .idle
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { password },
            set: { newValue in
                passwordWasEdited = true
                passwordLoadToken = UUID()
                isLoadingPassword = false
                password = newValue
            }
        )
    }

    private var retentionEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.retentionCount > 0 },
            set: { enabled in
                draft.retentionCount = enabled ? max(draft.retentionCount, 5) : 0
            }
        )
    }

    private func loadStoredPassword() {
        let token = UUID()
        let jobID = draft.id
        passwordLoadToken = token
        passwordWasEdited = false
        isLoadingPassword = true

        Task.detached(priority: .userInitiated) {
            let storedPassword = KeychainStore.password(for: jobID)
            await MainActor.run {
                guard passwordLoadToken == token else { return }
                if !passwordWasEdited {
                    password = storedPassword
                }
                isLoadingPassword = false
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard passwordLoadToken == token else { return }
            isLoadingPassword = false
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = draft.kind == .files || draft.kind == .project
        panel.canChooseFiles = draft.kind != .project
        panel.prompt = L10n.text("picker.choose")
        if panel.runModal() == .OK, let url = panel.url {
            draft.sourcePath = url.path
            draft.sourceBookmark = SecurityScopedBookmark.create(for: url)
        }
    }

    private var sourceFieldTitle: String {
        switch draft.kind {
        case .files: L10n.text("editor.file_or_folder")
        case .project: L10n.text("editor.project_folder")
        case .sqlite: L10n.text("editor.database_file")
        case .postgres, .mysql: L10n.text("common.source")
        }
    }

    private var outputNamePreview: String {
        let baseName = BackupNaming.render(mask: draft.nameMask, job: draft)
        let pathExtension = BackupNaming.outputExtension(for: draft, sourceIsDirectory: sourceIsDirectory)
        return pathExtension.isEmpty ? baseName : baseName + "." + pathExtension
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("picker.choose_folder")
        if panel.runModal() == .OK, let url = panel.url {
            draft.destinationPath = url.path
            draft.destinationBookmark = SecurityScopedBookmark.create(for: url)
        }
    }

    private func chooseClientExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L10n.text("picker.choose_utility")
        if panel.runModal() == .OK, let url = panel.url {
            draft.clientExecutablePath = url.path
            draft.clientExecutableBookmark = SecurityScopedBookmark.create(for: url)
        }
    }

    private func chooseSSHKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = L10n.text("picker.choose_key")
        if panel.runModal() == .OK, let url = panel.url {
            draft.sshIdentityPath = url.path
            draft.sshIdentityBookmark = SecurityScopedBookmark.create(for: url)
        }
    }
}

private enum ConnectionTestState: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)

    var isRunning: Bool {
        self == .running
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 8)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditorField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
            content
                .font(.system(size: 13))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PathField: View {
    @Binding var text: String
    let placeholder: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .font(.system(size: 11, design: .monospaced))
            Button(L10n.text("picker.choose"), action: action)
                .frame(minWidth: 78)
        }
    }
}

private struct EditorToggle: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13))
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityHint(hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
