import AppKit
import SwiftUI

enum AppTheme {
    static let background = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let toolbar = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .quaternaryLabelColor).opacity(0.25)
    static let border = Color(nsColor: .separatorColor)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let accent = Color.accentColor
    // White text on this blue exceeds 4.5:1 in both appearances.
    static let buttonFill = Color(red: 0.0, green: 0.34, blue: 0.75)
    static let success = adaptive(light: 0x227536, dark: 0x68D585)
    static let warning = adaptive(light: 0x875900, dark: 0xF1BF60)
    static let danger = adaptive(light: 0xB62932, dark: 0xFF858B)
    static let selection = Color.accentColor.opacity(0.15)
    static let card = panel

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

extension BackupKind {
    var tint: Color {
        switch self {
        case .files: .blue
        case .project: .teal
        case .sqlite: .purple
        case .postgres: .indigo
        case .mysql: .orange
        }
    }
}

extension BackupHealth {
    var color: Color {
        switch self {
        case .neverRun: AppTheme.secondaryText
        case .running: AppTheme.accent
        case .success: AppTheme.success
        case .failure: AppTheme.danger
        case .cancelled: AppTheme.warning
        }
    }

    var symbol: String {
        switch self {
        case .neverRun: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle"
        }
    }
}

enum BackupMotion {
    static func shouldAnimate(reduceMotion: Bool, isActive: Bool, isVisible: Bool) -> Bool {
        !reduceMotion && isActive && isVisible
    }

    static func transition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }
}

/// An indeterminate activity ring, not a percentage. The timeline is local to
/// this small view and stops offscreen/in the background. Reduce Motion gets a
/// static hourglass; the adjacent text still explains the operation's state.
struct BackupActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    var size: CGFloat = 30

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: size * 0.8, weight: .medium))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !BackupMotion.shouldAnimate(
                    reduceMotion: reduceMotion, isActive: scenePhase == .active, isVisible: visible
                ))) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.8) / 1.8
                    ZStack {
                        Circle().stroke(AppTheme.accent.opacity(0.16), lineWidth: max(2, size * 0.075))
                        Circle().trim(from: 0, to: 0.28)
                            .stroke(style: StrokeStyle(lineWidth: max(2, size * 0.075), lineCap: .round))
                            .rotationEffect(.degrees(phase * 360 - 90))
                    }
                    .padding(2)
                }
            }
        }
        .foregroundStyle(AppTheme.accent)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("activity.in_progress"))
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

struct BackupHealthIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let health: BackupHealth
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Group {
                if health == .running {
                    BackupActivityIndicator(size: size)
                } else {
                    Image(systemName: health.symbol)
                        .font(.system(size: size))
                        .foregroundStyle(health.color)
                }
            }
            .id(health)
            .transition(.opacity)
        }
        .frame(width: size + 2, height: size + 2)
        .animation(BackupMotion.transition(reduceMotion: reduceMotion), value: health)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(health.titleKey))
    }
}

struct MetadataRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(6, size * 0.2), style: .continuous)
                .fill(color.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct AppCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

struct StatusPill: View {
    let status: BackupStatus

    private var title: String {
        switch status {
        case .success: L10n.text("status.success")
        case .failure: L10n.text("status.failure")
        case .cancelled: L10n.text("status.cancelled")
        }
    }

    private var symbol: String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .success: AppTheme.success
        case .failure: AppTheme.danger
        case .cancelled: AppTheme.warning
        }
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                color.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = AppTheme.buttonFill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(minHeight: 32)
            .background(
                color.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.28),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ToolPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? L10n.text("ux.expanded") : L10n.text("ux.collapsed"))
            .background(AppTheme.toolbar)

            if isExpanded {
                Divider().overlay(AppTheme.border)
                content
            }
        }
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}
