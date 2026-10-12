import ServiceManagement
import SwiftUI
import UserNotifications

enum NotificationPermissionState: Equatable {
    case unknown
    case allowed
    case denied
    case unavailable
}

protocol NotificationPermissionProviding {
    func authorizationState() async -> NotificationPermissionState
    func requestAuthorization() async throws -> Bool
}

struct SystemNotificationPermissionProvider: NotificationPermissionProviding {
    func authorizationState() async -> NotificationPermissionState {
        guard let center = BackupNotifications.center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .allowed
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard let center = BackupNotifications.center else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
}

@MainActor
final class BackupNotificationSettingsController: ObservableObject {
    @Published private(set) var notifyOnSuccess: Bool
    @Published private(set) var notifyOnFailure: Bool
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var permissionUnavailable = false
    @Published private(set) var errorMessage: String?

    private let permissionProvider: NotificationPermissionProviding
    private let defaults: UserDefaults

    init(
        permissionProvider: NotificationPermissionProviding = SystemNotificationPermissionProvider(),
        defaults: UserDefaults = .standard
    ) {
        self.permissionProvider = permissionProvider
        self.defaults = defaults
        notifyOnSuccess = defaults.bool(forKey: BackupNotifications.notifyOnSuccessKey)
        notifyOnFailure = defaults.bool(forKey: BackupNotifications.notifyOnFailureKey)
    }

    func refresh() async {
        let state = await permissionProvider.authorizationState()
        permissionDenied = state == .denied && (notifyOnSuccess || notifyOnFailure)
        permissionUnavailable = state == .unavailable
    }

    func setNotifyOnSuccess(_ enabled: Bool) async {
        await set(enabled, key: BackupNotifications.notifyOnSuccessKey)
    }

    func setNotifyOnFailure(_ enabled: Bool) async {
        await set(enabled, key: BackupNotifications.notifyOnFailureKey)
    }

    private func set(_ enabled: Bool, key: String) async {
        guard !isRequestingPermission else { return }
        errorMessage = nil
        if !enabled {
            updatePreference(false, key: key)
            permissionDenied = permissionDenied && (notifyOnSuccess || notifyOnFailure)
            return
        }

        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            let state = await permissionProvider.authorizationState()
            permissionUnavailable = state == .unavailable
            let allowed: Bool
            switch state {
            case .allowed:
                allowed = true
            case .denied, .unavailable:
                allowed = false
            case .unknown:
                allowed = try await permissionProvider.requestAuthorization()
            }

            permissionDenied = !allowed && !permissionUnavailable
            updatePreference(allowed, key: key)
        } catch {
            updatePreference(false, key: key)
            errorMessage = L10n.text("settings.notifications_error", error.localizedDescription)
        }
    }

    private func updatePreference(_ enabled: Bool, key: String) {
        defaults.set(enabled, forKey: key)
        if key == BackupNotifications.notifyOnSuccessKey {
            notifyOnSuccess = enabled
        } else {
            notifyOnFailure = enabled
        }
    }
}

enum BackupNotifications {
    static let notifyOnSuccessKey = "notifyOnBackupSuccess"
    static let notifyOnFailureKey = "notifyOnBackupFailure"
    private static let foregroundDelegate = BackupNotificationForegroundDelegate()
    // Foreground result audio has already been handled by BackupAudioFeedback.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner]

    // UserNotifications raises an Objective-C exception for unbundled SwiftPM
    // executables. Check before every entry point, including startup/settings.
    static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    static func configure() {
        center?.delegate = foregroundDelegate
    }

    static func shouldNotify(
        status: BackupStatus,
        successEnabled: Bool,
        failureEnabled: Bool
    ) -> Bool {
        switch status {
        case .success:
            return successEnabled
        case .failure:
            return failureEnabled
        case .cancelled:
            return false
        }
    }

    static func post(_ run: BackupRun, defaults: UserDefaults = .standard, suppressSound: Bool = false) {
        guard shouldNotify(
            status: run.status,
            successEnabled: defaults.bool(forKey: notifyOnSuccessKey),
            failureEnabled: defaults.bool(forKey: notifyOnFailureKey)
        ) else { return }
        guard let center else { return }

        Task.detached(priority: .utility) {
            let content = makeContent(for: run, defaults: defaults, suppressSound: suppressSound)
            let request = UNNotificationRequest(
                identifier: "BackupCron.\(run.id.uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    static func makeContent(
        for run: BackupRun,
        defaults: UserDefaults,
        suppressSound: Bool,
        soundDirectory: URL? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = run.status == .success
            ? L10n.text("notification.success_title")
            : L10n.text("notification.failure_title")
        content.body = L10n.text("notification.result_body", run.jobName, run.message)
        let directory = soundDirectory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Sounds", isDirectory: true)
        if let directory,
           let file = try? BackupSoundSynthesis.notificationFile(
            for: run.status, preferences: BackupSoundPreferences(defaults: defaults),
            suppressSound: suppressSound, directory: directory
           ) {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(file.lastPathComponent))
        }
        // On sound preparation failure, still deliver the visual notification.
        // Never substitute a louder system sound or request critical alerts.
        return content
    }
}

private final class BackupNotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(BackupNotifications.foregroundPresentationOptions)
    }
}

protocol LaunchAtLoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginService {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service: LaunchAtLoginService

    init(service: LaunchAtLoginService = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            errorMessage = L10n.text("settings.launch_change_failed", error.localizedDescription)
        }
        refresh()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: BackupStore
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var notifications = BackupNotificationSettingsController()
    @ObservedObject private var audio = BackupAudioFeedback.shared

    var body: some View {
        Form {
            Section(L10n.text("common.schedule")) {
                Toggle(L10n.text("settings.run_automatically"), isOn: $store.schedulerEnabled)
                Text(L10n.text("settings.schedule_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    L10n.text("settings.launch_at_login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                Text(L10n.text("settings.launch_at_login_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if launchAtLogin.requiresApproval {
                    HStack {
                        Label(L10n.text("settings.launch_requires_approval"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.warning)
                        Spacer()
                        Button(L10n.text("settings.open_login_items")) {
                            launchAtLogin.openApprovalSettings()
                        }
                    }
                    .font(.caption)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                }
            }

            Section(L10n.text("settings.notifications")) {
                Toggle(
                    L10n.text("settings.notify_success"),
                    isOn: Binding(
                        get: { notifications.notifyOnSuccess },
                        set: { enabled in
                            Task { await notifications.setNotifyOnSuccess(enabled) }
                        }
                    )
                )
                .disabled(notifications.isRequestingPermission || notifications.permissionUnavailable)
                Toggle(
                    L10n.text("settings.notify_failure"),
                    isOn: Binding(
                        get: { notifications.notifyOnFailure },
                        set: { enabled in
                            Task { await notifications.setNotifyOnFailure(enabled) }
                        }
                    )
                )
                .disabled(notifications.isRequestingPermission || notifications.permissionUnavailable)

                Text(L10n.text("settings.notifications_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if notifications.isRequestingPermission {
                    Label(L10n.text("settings.notifications_requesting"), systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(AppTheme.accent)
                }
                if notifications.permissionDenied {
                    Label(L10n.text("settings.notifications_denied"), systemImage: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
                if notifications.permissionUnavailable {
                    Label(L10n.text("settings.notifications_unavailable"), systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage = notifications.errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.danger)
                }
            }

            Section(L10n.text("sound.title")) {
                Toggle(L10n.text("sound.enabled"), isOn: Binding(
                    get: { audio.enabled }, set: { audio.setEnabled($0) }
                ))

                HStack(spacing: 12) {
                    Slider(value: Binding(get: { audio.volume }, set: { audio.setVolume($0) }),
                           in: 0...1, step: 0.05) {
                        Text(L10n.text("sound.volume"))
                    }
                    Text(audio.volume.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .disabled(!audio.enabled)

                HStack(spacing: 12) {
                    Button(L10n.text("sound.preview_success"), systemImage: "play.circle") {
                        audio.preview(.success)
                    }
                    Button(L10n.text("sound.preview_failure"), systemImage: "play.circle") {
                        audio.preview(.failure)
                    }
                }
                .disabled(!audio.enabled || audio.volume == 0)

                Text(L10n.text("sound.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if audio.previewFailed {
                    Label(L10n.text("sound.preview_failed"), systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
            }

            Section(L10n.text("settings.storage")) {
                LabeledContent(L10n.text("settings.settings_history"), value: "Application Support/BackupCron")
                LabeledContent(L10n.text("settings.passwords"), value: L10n.text("settings.keychain"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .frame(width: 560, height: 620)
        .padding()
        .onAppear { launchAtLogin.refresh() }
        .task { await notifications.refresh() }
    }
}
