import AppKit
import ApplicationServices
import Foundation

/// Reads visible WeChat notification cards through macOS Accessibility. There is no public
/// API for one app to fetch another app's delivered notifications, so this adapter observes
/// only what Notification Center already exposes to the user.
final class CommunicationNotificationProvider: MessageProvider, @unchecked Sendable {
    let kind: MessageProviderKind
    let applicationBundleIdentifiers: [String]
    var onSnapshot: (@Sendable ([UnifiedMessage]) -> Void)?
    var onStatusChange: (@Sendable (MessageProviderStatus) -> Void)?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var messagesByID: [String: UnifiedMessage] = [:]

    private struct ScanDiagnostic: Codable {
        let timestamp: Date
        let accessibilityTrusted: Bool
        let hosts: [HostDiagnostic]
        let cardsFound: Int
        let messagesParsed: Int
    }

    private struct HostDiagnostic: Codable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let nodesVisited: Int
        let nonemptyStringAttributes: Int
        let weChatMarkers: Int
        let cardsFound: Int
    }

    private struct TraversalStats {
        var nodesVisited = 0
        var nonemptyStringAttributes = 0
        var weChatMarkers = 0
    }

    private struct NotificationCard {
        let metadata: [String]
        let visibleText: [String]
    }

    init(kind: MessageProviderKind, applicationBundleIdentifiers: [String]) {
        self.kind = kind
        self.applicationBundleIdentifiers = applicationBundleIdentifiers
        queue = DispatchQueue(label: "fusionnotch.messages.\(kind.rawValue)", qos: .utility)
    }

    func start() {
        writeStage("provider-start-called")
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.writeStage("provider-queue-entered")
            self.scan()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func scan() {
        writeStage("scan-entered")
        guard AXIsProcessTrusted() else {
            onStatusChange?(.permissionRequired)
            writeDiagnostic(.init(
                timestamp: Date(), accessibilityTrusted: false, hosts: [],
                cardsFound: 0, messagesParsed: 0
            ))
            return
        }

        let notificationCenters = Self.notificationCenterApplications()
        guard !notificationCenters.isEmpty else {
            onStatusChange?(.unavailable("Notification Center is not running"))
            return
        }

        var cards: [NotificationCard] = []
        var hostDiagnostics: [HostDiagnostic] = []
        for notificationCenter in notificationCenters {
            let root = AXUIElementCreateApplication(notificationCenter.processIdentifier)
            var remainingNodes = 1_200
            var stats = TraversalStats()
            let hostCards = notificationCards(
                in: root, depth: 0, remainingNodes: &remainingNodes, stats: &stats
            )
            cards.append(contentsOf: hostCards)
            hostDiagnostics.append(.init(
                bundleIdentifier: notificationCenter.bundleIdentifier ?? notificationCenter.localizedName ?? "unknown",
                processIdentifier: notificationCenter.processIdentifier,
                nodesVisited: stats.nodesVisited,
                nonemptyStringAttributes: stats.nonemptyStringAttributes,
                weChatMarkers: stats.weChatMarkers,
                cardsFound: hostCards.count
            ))
        }
        var parsedCount = 0
        for (index, card) in cards.enumerated() {
            guard var message = makeMessage(from: card.visibleText) else { continue }
            if let existing = messagesByID[message.id] {
                message = existing
            } else {
                // Cards are exposed newest-first by Notification Center. Tiny offsets make
                // multiple cards discovered in one pass sort deterministically.
                message = message.withTimestamp(Date().addingTimeInterval(-Double(index) / 1_000))
            }
            messagesByID[message.id] = message
            parsedCount += 1
        }

        writeDiagnostic(.init(
            timestamp: Date(), accessibilityTrusted: true, hosts: hostDiagnostics,
            cardsFound: cards.count, messagesParsed: parsedCount
        ))

        // Notification Center is a transient source. Keep a small in-memory history for the
        // panel, while preventing a long-running process from accumulating private content.
        if messagesByID.count > 100 {
            let retained = messagesByID.values.sorted { $0.timestamp > $1.timestamp }.prefix(100)
            messagesByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        }

        onStatusChange?(.ready)
        onSnapshot?(Array(messagesByID.values))
    }

    /// Returns the deepest accessibility containers that carry a WeChat marker. Choosing the
    /// deepest card avoids reporting the same banner again through every ancestor group.
    private func notificationCards(
        in element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int,
        stats: inout TraversalStats
    ) -> [NotificationCard] {
        guard depth < 14, remainingNodes > 0 else { return [] }
        remainingNodes -= 1
        stats.nodesVisited += 1

        let children = Self.children(of: element)
        var childCards: [NotificationCard] = []
        for child in children {
            childCards.append(contentsOf: notificationCards(
                in: child,
                depth: depth + 1,
                remainingNodes: &remainingNodes,
                stats: &stats
            ))
        }
        if !childCards.isEmpty { return childCards }

        let strings = Self.strings(
            in: element, depth: 0, remainingNodes: &remainingNodes, stats: &stats
        )
        let hasMarker = containsSourceMarker(strings)
        if hasMarker { stats.weChatMarkers += 1 }
        guard hasMarker else { return [] }
        var textBudget = 400
        let visibleText = Self.visibleText(
            in: element, depth: 0, remainingNodes: &textBudget
        )
        return visibleText.count >= 2
            ? [NotificationCard(metadata: strings, visibleText: visibleText)]
            : []
    }

    private static func strings(
        in element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int,
        stats: inout TraversalStats
    ) -> [String] {
        guard depth < 8, remainingNodes > 0 else { return [] }
        remainingNodes -= 1

        var result: [String] = []
        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXIdentifierAttribute as CFString,
            kAXRoleDescriptionAttribute as CFString
        ]
        for attribute in attributes {
            if let value = stringAttribute(attribute, of: element) {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty, !result.contains(normalized) {
                    result.append(normalized)
                    stats.nonemptyStringAttributes += 1
                }
            }
        }
        for child in children(of: element) {
            for value in strings(
                in: child, depth: depth + 1, remainingNodes: &remainingNodes, stats: &stats
            )
                where !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Extract only user-visible static text. Accessibility identifiers, button labels,
    /// role descriptions and other card metadata are useful for source detection but must
    /// never leak into the sender or body fields.
    private static func visibleText(
        in element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int
    ) -> [String] {
        guard depth < 10, remainingNodes > 0 else { return [] }
        remainingNodes -= 1

        var result: [String] = []
        if stringAttribute(kAXRoleAttribute as CFString, of: element) == kAXStaticTextRole as String {
            for attribute in [kAXValueAttribute as CFString, kAXTitleAttribute as CFString] {
                guard let value = stringAttribute(attribute, of: element)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, !result.contains(value) else { continue }
                result.append(value)
            }
        }

        for child in children(of: element) {
            for value in visibleText(
                in: child, depth: depth + 1, remainingNodes: &remainingNodes
            ) where !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func notificationCenterApplications() -> [NSRunningApplication] {
        let bundleIDs = [
            "com.apple.notificationcenterui",
            "com.apple.NotificationCenter",
            "com.apple.UserNotificationCenter"
        ]
        var applications: [NSRunningApplication] = []
        for bundleID in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                where !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                applications.append(app)
            }
        }
        for app in NSWorkspace.shared.runningApplications where !applications.contains(where: {
            $0.processIdentifier == app.processIdentifier
        }) {
            let name = app.localizedName?.lowercased() ?? ""
            if name.contains("notificationcenter") || name.contains("notification center") || name == "通知中心" {
                applications.append(app)
            }
        }
        return applications
    }

    private func containsSourceMarker(_ strings: [String]) -> Bool {
        strings.contains { value in
            let lower = value.lowercased()
            switch kind {
            case .wechat:
                return !value.contains("企业微信") && (
                    lower.contains("com.tencent.xinwechat") || lower == "wechat" || value == "微信" ||
                    lower.contains("wechat notification") || value.contains("微信通知")
                )
            case .wecom:
                return lower.contains("com.tencent.weworkmac") || lower.contains("wecom") ||
                    lower.contains("wework") || value.contains("企业微信")
            case .telegram:
                return lower.contains("ru.keepcoder.telegram") || lower.contains("telegram")
            case .appleMessages:
                return false
            }
        }
    }

    private func makeMessage(from rawStrings: [String]) -> UnifiedMessage? {
        let ignored: Set<String> = [
            "WeChat", "微信", "Close", "关闭", "Options", "选项", "Show", "显示",
            "Reply", "回复", "Notification", "通知", "WeCom", "企业微信", "Telegram"
        ]
        let content = rawStrings.filter { value in
            guard !ignored.contains(value) else { return false }
            guard !containsSourceMarker([value]) else { return false }
            guard value.range(of: #"^\d+\s*(s|m|h|min|秒|分钟|小时)$"#,
                              options: [.regularExpression, .caseInsensitive]) == nil else { return false }
            return true
        }

        guard content.count >= 2 else { return nil }
        let sender = content[0]
        let body = content[1]
        guard !sender.isEmpty, !body.isEmpty else { return nil }

        let fingerprint = Self.stableFingerprint([sender, body].joined(separator: "\u{1F}"))
        return UnifiedMessage(
            id: "\(kind.rawValue)-notification:\(fingerprint)",
            provider: kind,
            conversationID: sender,
            senderName: sender,
            conversationName: nil,
            body: body,
            timestamp: Date(),
            isUnread: true,
            isFromMe: false
        )
    }

    private static func stableFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func writeDiagnostic(_ diagnostic: ScanDiagnostic) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(diagnostic) else { return }
        try? data.write(to: URL(fileURLWithPath: "/private/tmp/fusionnotch-\(kind.rawValue)-diagnostic.json"),
                        options: .atomic)
    }

    private func writeStage(_ stage: String) {
        try? Data(stage.utf8).write(
            to: URL(fileURLWithPath: "/private/tmp/fusionnotch-\(kind.rawValue)-stage.txt"),
            options: .atomic
        )
    }
}
