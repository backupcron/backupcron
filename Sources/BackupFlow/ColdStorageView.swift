import AppKit
import SwiftUI

private struct ColdStorageEditorRequest: Identifiable {
    let id = UUID()
    var destination: ColdStorageDestination?
}

struct ColdStorageView: View {
    @EnvironmentObject private var store: BackupStore
    @State private var editor: ColdStorageEditorRequest?
    @State private var deleting: ColdStorageDestination?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L10n.text("cold.title")).font(.largeTitle.weight(.semibold))
                    Spacer()
                    Button(L10n.text("cold.add"), systemImage: "plus") { editor = .init() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("cold-add")
                }
                ForEach(store.coldStorages) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(item.name, systemImage: "externaldrive").font(.headline)
                            Spacer()
                            Toggle(L10n.text("editor.job_active"), isOn: Binding(get: { item.isEnabled }, set: { enabled in
                                var updated = item; updated.isEnabled = enabled
                                do { try store.saveColdStorage(updated) } catch { store.errorMessage = error.localizedDescription }
                            })).toggleStyle(.switch).controlSize(.small).labelsHidden().help(L10n.text("editor.job_active")).disabled(store.runningJobIDs.contains(item.id))
                        }
                        Text(item.volume.name).foregroundStyle(.secondary)
                        Text(store.coldStatus(item)).foregroundStyle(store.coldTrayState(item) == .error ? .red : .primary)
                            .accessibilityIdentifier("cold-status-\(item.id)")
                        if store.runningJobIDs.contains(item.id) { ProgressView(value: store.progress(for: item.id)) }
                        Text(store.jobs.filter { item.jobIDs.contains($0.id) }.map(\.name).joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                        if let last = store.history.first(where: { $0.jobID == item.id && $0.status == .success }) {
                            Text(L10n.text("ux.last_success") + ": " + last.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if store.runningJobIDs.contains(item.id) {
                                Button(L10n.text("job.stop")) { store.cancelColdStorage(item.id) }
                            } else {
                                Button(L10n.text("cold.copy")) { store.runColdStorage(item.id) }
                                    .disabled(item.volume.destination(in: store.mountedVolumes) == nil || item.jobIDs.isEmpty || item.jobIDs.contains(where: { store.runningJobIDs.contains($0) }))
                                Button(L10n.text("common.edit")) { editor = .init(destination: item) }
                                Spacer()
                                Button(L10n.text("common.delete"), role: .destructive) { deleting = item }
                            }
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                }
            }.padding(24)
        }
        .navigationTitle(L10n.text("cold.title"))
        .sheet(item: $editor) { request in ColdStorageEditor(destination: request.destination).environmentObject(store) }
        .alert(L10n.text("common.delete"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let item = deleting {
                    do { try store.deleteColdStorage(item.id) } catch { store.errorMessage = error.localizedDescription }
                }
                deleting = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { deleting = nil }
        } message: { Text(L10n.text("cold.delete_message")) }
    }
}

private struct ColdStorageEditor: View {
    @EnvironmentObject private var store: BackupStore
    @Environment(\.dismiss) private var dismiss
    private let original: ColdStorageDestination?
    @State private var name: String
    @State private var volume: BackupVolumeBinding?
    @State private var bookmark: SecurityScopedBookmark?
    @State private var members: Set<UUID>
    @State private var error: String?

    init(destination: ColdStorageDestination?) {
        original = destination
        _name = State(initialValue: destination?.name ?? "")
        _volume = State(initialValue: destination?.volume)
        _bookmark = State(initialValue: destination?.bookmark)
        _members = State(initialValue: Set(destination?.jobIDs ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(original == nil ? "cold.add" : "common.edit")).font(.title2.weight(.semibold))
            TextField(L10n.text("cold.name"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("cold-name")
            HStack {
                if let volume {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name)
                        Text(volume.configuredPath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
                Button(L10n.text("cold.choose_disk")) { chooseDisk() }.accessibilityIdentifier("cold-choose-disk")
            }
            Text(L10n.text("common.jobs")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.jobs) { job in
                        Toggle(job.name, isOn: Binding(get: { members.contains(job.id) }, set: { if $0 { members.insert(job.id) } else { members.remove(job.id) } }))
                            .toggleStyle(.checkbox).accessibilityIdentifier("cold-job-\(job.id)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(maxHeight: 220)
            Text(L10n.text("cold.copy_note")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("common.save")) {
                    guard let volume else { return }
                    do {
                        _ = try store.saveColdStorage(.init(id: original?.id ?? UUID(), name: name, volume: volume,
                            jobIDs: store.jobs.filter { members.contains($0.id) }.map(\.id), bookmark: bookmark, isEnabled: original?.isEnabled ?? true))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(volume == nil || members.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cold-save")
            }
        }.padding(24).frame(width: 470)
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.prompt = L10n.text("cold.choose_disk")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let binding = BackupVolumeBinding.capture(for: url) else { error = L10n.text("disk.choose_external"); return }
        volume = binding; bookmark = SecurityScopedBookmark.create(for: url); error = nil
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = binding.name }
    }
}
