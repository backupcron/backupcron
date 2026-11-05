import AppKit
import Combine
import SwiftUI

@main
struct BackupCronApp: App {
    @NSApplicationDelegateAdaptor(BackupCronAppDelegate.self) private var appDelegate
    @StateObject private var store = BackupStore()
    @StateObject private var statusItem = BackupCronStatusItem()
    @StateObject private var menuNavigation = BackupMenuNavigation()

    init() {
        BackupNotifications.configure()
    }

    var body: some Scene {
        Window("BackupCron", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(menuNavigation)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    statusItem.configure(store: store, navigation: menuNavigation)
                    store.startScheduler()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("common.new_job")) {
                    NotificationCenter.default.post(name: .createBackupJob, object: nil)
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

@MainActor
final class BackupMenuNavigation: ObservableObject {
    enum Destination: Equatable {
        case job(UUID, edit: Bool)
        case newJob
        case coldStorage
    }

    @Published var destination: Destination?
}

private final class BackupCronAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
private final class BackupCronStatusItem: NSObject, ObservableObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var store: BackupStore?
    private var navigation: BackupMenuNavigation?
    private var observation: AnyCancellable?
    private var displayedState: BackupTrayState?
    private var knownRunIDs: Set<UUID> = []
    private var animation = BackupTrayAnimation()
    private var animationTimer: Timer?
    private var displayedFrame: String?

    override init() {
        let autosaveName = "BackupCron"
        // AppKit measures the saved position from the right edge; a new item can otherwise land behind the camera notch.
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position " + autosaveName: 180])
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = autosaveName
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        refresh()
    }

    func configure(store: BackupStore, navigation: BackupMenuNavigation) {
        self.store = store
        self.navigation = navigation
        popover.contentViewController = NSHostingController(rootView: BackupCronMenuView(
            store: store,
            onOpen: { [weak self] in self?.openMainWindow() },
            onNavigate: { [weak self] destination in self?.openMainWindow(destination) },
            onQuit: { NSApp.terminate(nil) },
            onDismiss: { [weak self] in self?.popover.performClose(nil) }
        ))
        if observation == nil {
            knownRunIDs = Set(store.history.map(\.id))
            observation = store.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        let state = store?.trayState ?? .notRun
        if let store {
            for run in store.history.reversed() where !knownRunIDs.contains(run.id) {
                animation.completed(run.status)
            }
            knownRunIDs = Set(store.history.map(\.id))
        }
        let now = ProcessInfo.processInfo.systemUptime
        animation.update(state: state, at: now)
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let needsTimer = animation.mode == .success || (animation.mode == .copying && !reducedMotion)
        if needsTimer && animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            animationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !needsTimer {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        if animation.mode != .idle {
            let frames = animation.mode == .copying ? Self.rotationFrames : Self.successFrames
            let progress = reducedMotion ? (animation.mode == .success ? 1.0 : 0.0) : animation.progress(at: now)
            let index = min(frames.count - 1, Int(progress * Double(frames.count)))
            let frame = "\(animation.mode)-\(index)"
            if displayedFrame != frame { item.button?.image = frames[index]; displayedFrame = frame }
        } else if displayedState != state || displayedFrame != nil {
            item.button?.image = Self.menuBarIcon(for: state)
            displayedFrame = nil
        }
        displayedState = state
        let title = "BackupCron — " + state.title
        if item.button?.toolTip != title {
            item.button?.toolTip = title
            item.button?.setAccessibilityLabel(title)
        }
    }

    deinit { animationTimer?.invalidate() }

    private static let rotationFrames = (0..<36).map { frame in
        BackupTrayIconRenderer.rotation(progress: Double(frame) / 36)
    }
    private static let successFrames = (0..<42).map { frame in
        BackupTrayIconRenderer.success(progress: Double(frame) / 41)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button, popover.contentViewController != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    private func openMainWindow(_ destination: BackupMenuNavigation.Destination? = nil) {
        if let destination { navigation?.destination = destination }
        popover.performClose(nil)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async { NSApp.presentError(error) }
            }
        }
    }

    private static func menuBarIcon(for state: BackupTrayState) -> NSImage {
        let badge: String
        switch state {
        case .ready, .notRun, .copying: return menuBarIcon
        case .error: badge = "exclamationmark.circle.fill"
        case .waitingForDisk: badge = "questionmark.circle.fill"
        case .waitingForSource: badge = "clock.fill"
        case .cancelled: badge = "stop.circle.fill"
        case .paused: badge = "pause.circle.fill"
        }
        let image = NSImage(size: menuBarIcon.size, flipped: false) { rect in
            menuBarIcon.draw(in: rect)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 10, height: 10)).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .draw(in: NSRect(x: 12, y: 1, width: 8, height: 8))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 2.75, y: 2))
            folder.curve(to: NSPoint(x: 1, y: 3.75), controlPoint1: NSPoint(x: 1.8, y: 2), controlPoint2: NSPoint(x: 1, y: 2.8))
            folder.line(to: NSPoint(x: 1, y: 14.25))
            folder.curve(to: NSPoint(x: 2.75, y: 16), controlPoint1: NSPoint(x: 1, y: 15.2), controlPoint2: NSPoint(x: 1.8, y: 16))
            folder.line(to: NSPoint(x: 7.5, y: 16))
            folder.curve(to: NSPoint(x: 8.5, y: 15.5), controlPoint1: NSPoint(x: 8, y: 16), controlPoint2: NSPoint(x: 8.2, y: 15.8))
            folder.line(to: NSPoint(x: 9.8, y: 14))
            folder.line(to: NSPoint(x: 17.25, y: 14))
            folder.curve(to: NSPoint(x: 19, y: 12.25), controlPoint1: NSPoint(x: 18.2, y: 14), controlPoint2: NSPoint(x: 19, y: 13.2))
            folder.line(to: NSPoint(x: 19, y: 3.75))
            folder.curve(to: NSPoint(x: 17.25, y: 2), controlPoint1: NSPoint(x: 19, y: 2.8), controlPoint2: NSPoint(x: 18.2, y: 2))
            folder.close()
            NSColor.black.setFill()
            folder.fill()

            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 8, y: 10.8))
            arrow.line(to: NSPoint(x: 10.4, y: 10.8))
            arrow.curve(to: NSPoint(x: 14, y: 7.4), controlPoint1: NSPoint(x: 12.4, y: 10.8), controlPoint2: NSPoint(x: 14, y: 9.4))
            arrow.curve(to: NSPoint(x: 10.4, y: 4), controlPoint1: NSPoint(x: 14, y: 5.4), controlPoint2: NSPoint(x: 12.4, y: 4))
            arrow.curve(to: NSPoint(x: 6.8, y: 7.4), controlPoint1: NSPoint(x: 8.4, y: 4), controlPoint2: NSPoint(x: 6.8, y: 5.4))
            arrow.move(to: NSPoint(x: 9, y: 12.5))
            arrow.line(to: NSPoint(x: 7.2, y: 10.8))
            arrow.line(to: NSPoint(x: 9, y: 9.1))
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private struct BackupCronMenuView: View {
    @ObservedObject var store: BackupStore
    let onOpen: () -> Void
    let onNavigate: (BackupMenuNavigation.Destination) -> Void
    let onQuit: () -> Void
    let onDismiss: () -> Void

    private var isEmpty: Bool { store.jobs.isEmpty && store.coldStorages.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 24))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BackupCron").font(.system(size: 15, weight: .semibold))
                    if !isEmpty || store.errorMessage != nil {
                        Label(store.trayState.title, systemImage: store.trayState.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(store.trayState.menuColor)
                    }
                }
                Spacer(minLength: 0)
                Button { onNavigate(.newJob) } label: {
                    Label(L10n.text("common.new_job"), systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 16, weight: .medium))
                .help(L10n.text("common.new_job"))
                .accessibilityIdentifier("tray-new-job")
            }
            .padding(18)

            HStack {
                Text(L10n.text("common.schedule"))
                Spacer()
                Toggle(L10n.text("settings.run_automatically"), isOn: $store.schedulerEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(L10n.text("settings.run_automatically"))
                    .accessibilityIdentifier("tray-scheduler")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()

            if isEmpty {
                Label(L10n.text("dashboard.no_jobs"), systemImage: "tray")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ViewThatFits(in: .vertical) {
                    entries.fixedSize(horizontal: false, vertical: true)
                    ScrollView { entries }
                        .frame(height: 360)
                }
                .frame(maxHeight: 360)
            }

            Divider()

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.danger)
                    .lineLimit(3)
                    .help(error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }

            VStack(spacing: 10) {
                Button(action: onOpen) {
                    Text(L10n.text("menu.open"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("tray-open")

                Button(L10n.text("menu.quit"), action: onQuit)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
                    .accessibilityIdentifier("tray-quit")
            }
            .padding(14)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: onDismiss)
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.jobs.isEmpty {
                sectionTitle(L10n.text("common.jobs"), count: store.jobs.count)
                ForEach(store.jobs) { job in
                    jobEntry(job)
                    if job.id != store.jobs.last?.id { Divider().padding(.leading, 38) }
                }
            }
            if !store.coldStorages.isEmpty {
                sectionTitle(L10n.text("cold.title"), count: store.coldStorages.count)
                    .padding(.top, store.jobs.isEmpty ? 0 : 14)
                ForEach(store.coldStorages) { item in
                    coldEntry(item)
                    if item.id != store.coldStorages.last?.id { Divider().padding(.leading, 38) }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func jobEntry(_ job: BackupJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button { onNavigate(.job(job.id, edit: false)) } label: {
                    statusRow(job.name, symbol: job.kind.symbol, state: store.trayState(for: job))
                }
                .buttonStyle(.plain)
                .help(L10n.text("ux.open_job"))
                .accessibilityIdentifier("tray-job-\(job.id)")

                Button { onNavigate(.job(job.id, edit: true)) } label: {
                    Label(L10n.text("common.edit"), systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(L10n.text("common.edit") + " — " + job.name)
                .accessibilityLabel(L10n.text("common.edit") + " — " + job.name)
                .accessibilityIdentifier("tray-edit-\(job.id)")
            }
            jobTiming(job)
            HStack {
                let running = store.runningJobIDs.contains(job.id)
                let diskUnavailable = job.schedule == .onVolumeMount
                    && job.destinationVolume?.destination(in: store.mountedVolumes) == nil
                Button {
                    if running { store.cancel(job) } else { store.run(job) }
                } label: {
                    Label(L10n.text(running ? "job.stop" : "job.run"),
                          systemImage: running ? "stop.fill" : "play.fill")
                }
                .disabled(!running && diskUnavailable)
                .help(L10n.text(diskUnavailable && !running ? "disk.waiting" : running ? "job.stop" : "common.run_now"))
                .accessibilityIdentifier("tray-run-\(job.id)")
                Spacer(minLength: 8)
                Toggle(L10n.text("job.active"), isOn: Binding(
                    get: { job.isEnabled },
                    set: { store.setEnabled($0, for: job.id) }
                ))
                .toggleStyle(.switch)
                .disabled(running)
                .accessibilityLabel(L10n.text("editor.job_active") + " — " + job.name)
                .accessibilityIdentifier("tray-enabled-\(job.id)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11))
            .padding(.leading, 38)
            .padding(.top, 3)
        }
        .padding(.vertical, 10)
    }

    private func jobTiming(_ job: BackupJob) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let running = store.runningJobIDs.contains(job.id)
            let snapshot = JobSnapshot(jobID: job.id, history: store.history, isRunning: running)
            let lastSuccess = store.folderSyncStates[job.id]?.checkpoint.lastSuccess
                ?? snapshot.latestSuccess?.finishedAt
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("ux.last_success") + ": "
                     + (lastSuccess?.formatted(date: .abbreviated, time: .shortened)
                        ?? L10n.text("ux.no_success")))
                if job.isFolderSync && job.schedule == .onVolumeMount {
                    Text(L10n.text("sync.pending") + ": " + store.syncPendingText(for: job))
                } else {
                    Text(L10n.text("job.next_run") + ": " + BackupScheduleState(
                        job: job, schedulerEnabled: store.schedulerEnabled,
                        isRunning: running, now: context.date
                    ).text)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 38)
        }
    }

    private func coldEntry(_ item: ColdStorageDestination) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { onNavigate(.coldStorage) } label: {
                statusRow(item.name, symbol: "externaldrive", state: store.coldTrayState(item),
                          status: store.coldStatus(item))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tray-cold-\(item.id)")
            HStack {
                let running = store.runningJobIDs.contains(item.id)
                Button {
                    if running { store.cancelColdStorage(item.id) } else { store.runColdStorage(item.id) }
                } label: {
                    Label(L10n.text(running ? "job.stop" : "cold.copy"),
                          systemImage: running ? "stop.fill" : "play.fill")
                }
                .disabled(!running && (item.volume.destination(in: store.mountedVolumes) == nil
                    || item.jobIDs.isEmpty || store.coldTrayState(item) == .waitingForSource))
                .accessibilityIdentifier("tray-cold-run-\(item.id)")
                Spacer(minLength: 8)
                Toggle(L10n.text("job.active"), isOn: Binding(
                    get: { item.isEnabled },
                    set: { enabled in
                        var updated = item
                        updated.isEnabled = enabled
                        do { try store.saveColdStorage(updated) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                ))
                .toggleStyle(.switch)
                .disabled(running)
                .accessibilityLabel(L10n.text("job.active") + " — " + item.name)
                .accessibilityIdentifier("tray-cold-enabled-\(item.id)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 11))
            .padding(.leading, 38)
        }
        .padding(.vertical, 10)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count, format: .number).monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private func statusRow(_ name: String, symbol: String, state: BackupTrayState, status: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .help(name)
                Label(status ?? state.title, systemImage: state.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(state.menuColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension BackupTrayState {
    var menuColor: Color {
        switch self {
        case .copying: AppTheme.accent
        case .ready: AppTheme.success
        case .error: AppTheme.danger
        case .waitingForSource, .waitingForDisk, .cancelled: AppTheme.warning
        case .notRun, .paused: .secondary
        }
    }
}

extension Notification.Name {
    static let createBackupJob = Notification.Name("BackupCron.createBackupJob")
}

enum BackupTrayIconRenderer {
    static func rotation(progress: Double) -> NSImage {
        template { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: 10, yBy: 9)
            transform.rotate(byDegrees: -360 * progress)
            transform.translateX(by: -10, yBy: -9)
            transform.concat()
            NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
                .draw(in: NSRect(x: 2, y: 1, width: 16, height: 16))
        }
    }

    static func success(progress: Double) -> NSImage {
        template { _ in
            let seconds = progress * BackupTrayAnimation.successDuration
            let drawn = min(1, seconds / 0.3)
            let scale = seconds < 0.3 ? 0.9 + 0.1 * drawn : 1 + 0.08 * sin(min(1, (seconds - 0.3) / 0.6) * .pi)
            let transform = NSAffineTransform()
            transform.translateX(by: 10, yBy: 9)
            transform.scale(by: scale)
            transform.translateX(by: -10, yBy: -9)
            transform.concat()
            let points = [NSPoint(x: 4, y: 9), NSPoint(x: 8, y: 5), NSPoint(x: 16, y: 13)]
            let path = NSBezierPath()
            path.move(to: points[0])
            let first = min(1, drawn * 3)
            path.line(to: NSPoint(x: points[0].x + 4 * first, y: points[0].y - 4 * first))
            if drawn > 1.0 / 3 {
                let second = (drawn - 1.0 / 3) * 1.5
                path.line(to: NSPoint(x: points[1].x + 8 * second, y: points[1].y + 8 * second))
            }
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
