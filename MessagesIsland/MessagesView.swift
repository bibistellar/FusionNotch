import SwiftUI

struct MessagesView: View {
    @ObservedObject private var model = MessageCenterModel.shared

    var body: some View {
        Group {
            if !model.messages.isEmpty {
                messageList
            } else if [.wechat, .wecom, .telegram].contains(where: {
                model.providerStatus[$0] == .permissionRequired
            }) {
                accessibilityPermissionState
            } else if model.providerStatus[.appleMessages] == .permissionRequired {
                permissionState
            } else if case .unavailable(let detail) = firstNotificationProviderError {
                errorState(detail)
            } else if case .unavailable(let detail) = model.providerStatus[.appleMessages] {
                errorState(detail)
            } else if model.providerStatus[.appleMessages] == .stopped {
                disabledState
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var firstNotificationProviderError: MessageProviderStatus? {
        [.wechat, .wecom, .telegram]
            .compactMap { model.providerStatus[$0] }
            .first { if case .unavailable = $0 { true } else { false } }
    }

    private var messageList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(model.messages) { message in
                    MessageRow(message: message) { model.open(message) }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "message.fill")
                .font(.system(size: 20))
                .foregroundStyle(.gray)
            Text("No messages yet")
                .font(.caption)
                .foregroundStyle(.gray)
            Text("Waiting for Messages, WeChat, WeCom and Telegram")
                .font(.caption2)
                .foregroundStyle(.gray.opacity(0.6))
        }
    }

    private var accessibilityPermissionState: some View {
        VStack(spacing: 7) {
            Label("Accessibility access required", systemImage: "accessibility")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            Text("Allow FusionNotch to read visible communication notification previews.")
                .font(.caption2)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Grant Access") { model.requestAccessibilityAccess() }
                Button("Retry") { model.retry() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var permissionState: some View {
        VStack(spacing: 7) {
            Label("Full Disk Access required", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            Text("Allow FusionNotch to read your local Messages database, then retry.")
                .font(.caption2)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Open Settings") { model.openFullDiskAccessSettings() }
                Button("Retry") { model.retry() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func errorState(_ detail: String) -> some View {
        VStack(spacing: 7) {
            Label("Messages unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("Retry") { model.retry() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var disabledState: some View {
        VStack(spacing: 7) {
            Image(systemName: "message.badge.filled.fill")
                .foregroundStyle(.gray)
            Text("Apple Messages is disabled")
                .font(.caption)
                .foregroundStyle(.gray)
            Button("Enable") { model.appleMessagesEnabled = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct MessageRow: View {
    let message: UnifiedMessage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(providerColor.opacity(0.2))
                    Image(systemName: message.provider.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(providerColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(message.displayName)
                            .font(.system(size: 11, weight: message.isUnread ? .semibold : .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if message.isUnread {
                            Circle().fill(.blue).frame(width: 5, height: 5)
                        }
                    }
                    Text(message.body)
                        .font(.system(size: 10))
                        .foregroundStyle(message.isUnread ? .white.opacity(0.8) : .gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(message.timestamp, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .secondarySystemFill).opacity(message.isUnread ? 0.8 : 0.5))
            }
        }
        .buttonStyle(.plain)
    }

    private var providerColor: Color {
        switch message.provider {
        case .appleMessages, .wechat: .green
        case .wecom: .blue
        case .telegram: .cyan
        }
    }
}
