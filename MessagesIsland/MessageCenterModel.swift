import AppKit
import ApplicationServices
import Defaults
import Foundation

enum MessageProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleMessages
    case wechat
    case wecom
    case telegram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMessages: "Messages"
        case .wechat: "WeChat"
        case .wecom: "WeCom"
        case .telegram: "Telegram"
        }
    }

    var symbolName: String {
        switch self {
        case .appleMessages: "message.fill"
        case .wechat: "message.fill"
        case .wecom: "building.2.fill"
        case .telegram: "paperplane.fill"
        }
    }
}

struct UnifiedMessage: Identifiable, Hashable, Sendable {
    let id: String
    let provider: MessageProviderKind
    let conversationID: String
    let senderName: String
    let conversationName: String?
    let body: String
    let timestamp: Date
    let isUnread: Bool
    let isFromMe: Bool

    var displayName: String {
        let conversation = conversationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversation?.isEmpty == false ? conversation! : senderName
    }

    func withTimestamp(_ timestamp: Date) -> UnifiedMessage {
        UnifiedMessage(
            id: id,
            provider: provider,
            conversationID: conversationID,
            senderName: senderName,
            conversationName: conversationName,
            body: body,
            timestamp: timestamp,
            isUnread: isUnread,
            isFromMe: isFromMe
        )
    }
}

enum MessageProviderStatus: Equatable, Sendable {
    case stopped
    case loading
    case ready
    case permissionRequired
    case unavailable(String)
}

protocol MessageProvider: AnyObject {
    var kind: MessageProviderKind { get }
    var onSnapshot: (@Sendable ([UnifiedMessage]) -> Void)? { get set }
    var onStatusChange: (@Sendable (MessageProviderStatus) -> Void)? { get set }
    func start()
    func stop()
}

extension Notification.Name {
    static let communicationMessageReceived = Notification.Name("communicationMessageReceived")
}

@MainActor
final class MessageCenterModel: ObservableObject {
    static let shared = MessageCenterModel()

    @Published private(set) var messages: [UnifiedMessage] = []
    @Published private(set) var providerStatus: [MessageProviderKind: MessageProviderStatus] = [:]
    @Published var appleMessagesEnabled = true {
        didSet { appleMessagesEnabled ? startProvider() : stopProvider() }
    }

    private let appleMessagesProvider = AppleMessagesProvider()
    private let notificationProviders: [CommunicationNotificationProvider] = [
        .init(
            kind: .wechat,
            applicationBundleIdentifiers: ["com.tencent.xinWeChat", "com.tencent.WeChat", "com.tencent.wechat"]
        ),
        .init(
            kind: .wecom,
            applicationBundleIdentifiers: ["com.tencent.WeWorkMac"]
        ),
        .init(
            kind: .telegram,
            applicationBundleIdentifiers: ["ru.keepcoder.Telegram"]
        )
    ]
    private var providerMessages: [MessageProviderKind: [UnifiedMessage]] = [:]
    private var initializedProviders = Set<MessageProviderKind>()
    private var knownMessageIDs: [MessageProviderKind: Set<String>] = [:]

    private init() {
        appleMessagesProvider.onStatusChange = { status in
            Task { @MainActor in
                MessageCenterModel.shared.providerStatus[.appleMessages] = status
            }
        }
        appleMessagesProvider.onSnapshot = { snapshot in
            Task { @MainActor in
                MessageCenterModel.shared.apply(snapshot, from: .appleMessages)
            }
        }
        for provider in notificationProviders {
            let kind = provider.kind
            provider.onStatusChange = { status in
                Task { @MainActor in
                    MessageCenterModel.shared.providerStatus[kind] = status
                }
            }
            provider.onSnapshot = { snapshot in
                Task { @MainActor in
                    MessageCenterModel.shared.apply(snapshot, from: kind)
                }
            }
        }
    }

    var unreadCount: Int { messages.lazy.filter(\.isUnread).count }

    func start() {
        guard Defaults[.messagesPanelEnabled] else { return }
        if appleMessagesEnabled { startProvider() }
        for provider in notificationProviders {
            providerStatus[provider.kind] = .loading
            provider.start()
        }
    }

    func stop() {
        appleMessagesProvider.stop()
        notificationProviders.forEach { $0.stop() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
            providerMessages.removeAll()
            knownMessageIDs.removeAll()
            initializedProviders.removeAll()
            providerStatus = Dictionary(
                uniqueKeysWithValues: MessageProviderKind.allCases.map { ($0, .stopped) }
            )
            messages.removeAll()
        }
    }

    func retry() {
        initializedProviders.removeAll()
        knownMessageIDs[.appleMessages] = nil
        appleMessagesProvider.stop()
        notificationProviders.forEach { $0.stop() }
        startProvider()
        for provider in notificationProviders {
            providerStatus[provider.kind] = .loading
            provider.start()
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func open(_ message: UnifiedMessage) {
        if message.provider != .appleMessages {
            openCommunicationApp(for: message.provider)
            return
        }
        let target = message.senderName == "Unknown sender" ? message.conversationID : message.senderName
        let address = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "sms:\(address)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Messages.app"),
                                               configuration: .init())
        }
    }

    private func startProvider() {
        providerStatus[.appleMessages] = .loading
        appleMessagesProvider.start()
    }

    private func stopProvider() {
        appleMessagesProvider.stop()
        providerStatus[.appleMessages] = .stopped
        messages.removeAll { $0.provider == .appleMessages }
        knownMessageIDs.removeAll()
        initializedProviders.remove(.appleMessages)
        providerMessages[.appleMessages] = nil
        rebuildMessages()
    }

    private func apply(_ snapshot: [UnifiedMessage], from provider: MessageProviderKind) {
        let sorted = snapshot.sorted { $0.timestamp > $1.timestamp }
        let snapshotIDs = Set(sorted.map(\.id))

        if initializedProviders.contains(provider) {
            let known = knownMessageIDs[provider] ?? []
            let newIncoming = sorted.filter {
                !known.contains($0.id) && !$0.isFromMe
            }
            if let newest = newIncoming.first {
                NotificationCenter.default.post(
                    name: .communicationMessageReceived,
                    object: newest
                )
            }
        } else {
            initializedProviders.insert(provider)
        }

        knownMessageIDs[provider] = snapshotIDs
        providerMessages[provider] = sorted
        rebuildMessages()
    }

    private func rebuildMessages() {
        messages = providerMessages.values.flatMap { $0 }.sorted { $0.timestamp > $1.timestamp }
    }

    private func openCommunicationApp(for kind: MessageProviderKind) {
        guard let provider = notificationProviders.first(where: { $0.kind == kind }) else { return }
        let bundleIDs = provider.applicationBundleIdentifiers
        if let running = bundleIDs.lazy.compactMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }).first {
            running.activate()
            return
        }
        if let url = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
