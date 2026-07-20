import Foundation

/// Read-only adapter for the user's local Messages database. It deliberately uses the
/// system sqlite3 executable instead of linking a writable database connection into the app.
/// Full Disk Access is still required by macOS for ~/Library/Messages/chat.db.
final class AppleMessagesProvider: MessageProvider, @unchecked Sendable {
    let kind: MessageProviderKind = .appleMessages
    var onSnapshot: (@Sendable ([UnifiedMessage]) -> Void)?
    var onStatusChange: (@Sendable (MessageProviderStatus) -> Void)?

    private let queue = DispatchQueue(label: "fusionnotch.messages.apple", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isQueryRunning = false

    private var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.query()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.query() }
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

    private func query() {
        guard !isQueryRunning else { return }
        isQueryRunning = true
        defer { isQueryRunning = false }

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            // TCC commonly makes a protected path look absent to an unauthorized process.
            onStatusChange?(.permissionRequired)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, Self.query]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            onStatusChange?(.unavailable(error.localizedDescription))
            return
        }

        // Drain both pipes while sqlite3 is running. Waiting first can deadlock when message
        // bodies fill the pipe buffer.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8) ?? "Unable to read Messages"
            if detail.localizedCaseInsensitiveContains("authorization denied") ||
                detail.localizedCaseInsensitiveContains("permission denied") {
                onStatusChange?(.permissionRequired)
            } else {
                onStatusChange?(.unavailable(detail.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return
        }

        do {
            // sqlite3's JSON mode writes no bytes (rather than `[]`) for an empty result.
            // An unused Messages database is valid and should render the normal empty state.
            let rows = outputData.isEmpty
                ? []
                : try JSONDecoder().decode([Row].self, from: outputData)
            onStatusChange?(.ready)
            onSnapshot?(rows.compactMap(\.message))
        } catch {
            onStatusChange?(.unavailable("Messages returned an unsupported database format"))
        }
    }

    private struct Row: Decodable {
        let rowID: Int64
        let guid: String?
        let sender: String?
        let conversationID: String?
        let conversationName: String?
        let body: String?
        let unixTimestamp: Double
        let isRead: Int
        let isFromMe: Int

        enum CodingKeys: String, CodingKey {
            case rowID = "row_id"
            case guid, sender
            case conversationID = "conversation_id"
            case conversationName = "conversation_name"
            case body
            case unixTimestamp = "unix_timestamp"
            case isRead = "is_read"
            case isFromMe = "is_from_me"
        }

        var message: UnifiedMessage? {
            let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let senderName = sender?.isEmpty == false ? sender! : "Unknown sender"
            return UnifiedMessage(
                id: guid ?? "apple-messages:\(rowID)",
                provider: .appleMessages,
                conversationID: conversationID ?? senderName,
                senderName: senderName,
                conversationName: conversationName,
                body: text,
                timestamp: Date(timeIntervalSince1970: unixTimestamp),
                isUnread: isRead == 0 && isFromMe == 0,
                isFromMe: isFromMe != 0
            )
        }
    }

    private static let query = """
    SELECT
        m.ROWID AS row_id,
        m.guid AS guid,
        h.id AS sender,
        c.chat_identifier AS conversation_id,
        c.display_name AS conversation_name,
        m.text AS body,
        (CASE WHEN m.date > 1000000000000 THEN m.date / 1000000000.0 ELSE m.date END) + 978307200 AS unix_timestamp,
        m.is_read AS is_read,
        m.is_from_me AS is_from_me
    FROM message m
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE m.text IS NOT NULL AND length(trim(m.text)) > 0
    ORDER BY m.date DESC
    LIMIT 100;
    """
}
