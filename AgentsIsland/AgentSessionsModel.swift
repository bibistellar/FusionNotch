//
//  AgentSessionsModel.swift
//  boringNotch
//
//  Bridges OpenIslandCore's agent session tracking into the notch.
//

import Combine
import Defaults
import Foundation
import OpenIslandCore

extension Notification.Name {
    /// An agent just started waiting on the user (permission request or question).
    static let agentNeedsAttention = Notification.Name("agentNeedsAttention")
}

extension Bundle {
    /// Shipped by the "Embed OpenIslandHooks" build phase.
    var builtInHooksBinaryURL: URL? {
        let url = bundleURL.appendingPathComponent("Contents/Helpers/OpenIslandHooks")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

@MainActor
class AgentSessionsModel: ObservableObject {
    static let shared = AgentSessionsModel()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var isBridgeReady: Bool = false
    @Published private(set) var hooksInstalled: [AgentHookTarget: Bool] = [:]
    @Published private(set) var hooksBusy: Set<AgentHookTarget> = []
    @Published private(set) var hooksError: String?

    private let server = BridgeServer()
    private var client = LocalBridgeClient()
    private var state = SessionState() {
        didSet { server.updateStateSnapshot(state) }
    }

    /// Polls `ps`/`lsof` and culls sessions whose agent process is gone, so the
    /// list doesn't accumulate dead rows. Also keeps jump targets from going stale.
    private let monitoring = ProcessMonitoringCoordinator()

    private var streamTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 2

    /// Sessions worth putting in front of the user: a permission request or a
    /// pending question. Drives the tab's attention badge.
    var attentionCount: Int { state.liveAttentionCount }
    var runningCount: Int { state.liveRunningCount }

    private init() {}

    func start() {
        guard streamTask == nil else { return }

        installHooksIfNeeded()
        startMonitoring()

        do {
            try server.start()
        } catch {
            NSLog("[AgentsIsland] bridge server failed to start: \(error.localizedDescription)")
            return
        }
        connect()
    }

    /// Namespaces sessions the monitor synthesizes from `ps` output, so they can be
    /// told apart from hook-reported ones. Must not be empty: `isSyntheticClaudeSession`
    /// tests `id.hasPrefix(prefix)`, and every string has the empty prefix — leaving it
    /// blank makes every Claude session look synthetic and breaks deduplication.
    private static let syntheticClaudeSessionPrefix = "claude-process:"

    private func startMonitoring() {
        monitoring.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        monitoring.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        monitoring.stateUpdater = { [weak self] in self?.state = $0 }
        monitoring.onSessionsReconciled = { [weak self] in
            guard let self else { return }
            self.sessions = self.state.sessions
        }

        monitoring.reconcileSessionAttachments()
        monitoring.startMonitoringIfNeeded()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        client.disconnect()
        server.stop()
        isBridgeReady = false
    }

    // MARK: - Bridge

    private func connect() {
        streamTask?.cancel()
        client.disconnect()

        let client = LocalBridgeClient()
        self.client = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()
        } catch {
            scheduleReconnect()
            return
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The server only forwards events to registered observers.
                try await client.send(.registerClient(role: .observer))
                self.isBridgeReady = true
                self.reconnectDelay = 2

                for try await event in stream {
                    let before = self.attentionIDs()
                    self.state.apply(event)

                    // Mark liveness straight from the event rather than waiting up to
                    // 60s for the next poll to notice the session is alive.
                    self.monitoring.markSessionAttached(for: event)
                    self.monitoring.markSessionProcessAlive(for: event)

                    self.sessions = self.state.sessions

                    // A session that has just started waiting on the user is the whole
                    // point of the tab — surface it instead of waiting to be looked at.
                    if !self.attentionIDs().subtracting(before).isEmpty {
                        NotificationCenter.default.post(name: .agentNeedsAttention, object: nil)
                    }
                }
            } catch {
                // falls through to reconnect
            }

            self.isBridgeReady = false
            if !Task.isCancelled {
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(delay * 2, 30)
        streamTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.streamTask = nil
            self.connect()
        }
    }

    // MARK: - Acting on a session

    /// Unblocks the agent's hook process, which is sitting on a socket read waiting
    /// for exactly this answer.
    func resolvePermission(sessionID: String, approve: Bool) {
        let resolution: PermissionResolution = approve ? .allowOnce() : .deny()
        let client = self.client

        // Reflect the decision immediately; the server echoes an event back that
        // lands on the same state, so this only removes the round-trip flicker.
        state.resolvePermission(sessionID: sessionID, resolution: resolution)
        sessions = state.sessions

        Task {
            do {
                try await client.send(.resolvePermission(sessionID: sessionID, resolution: resolution))
            } catch {
                NSLog("[AgentsIsland] failed to resolve permission: \(error.localizedDescription)")
            }
        }
    }

    func answerQuestion(sessionID: String, option: String) {
        let response = QuestionPromptResponse(rawAnswer: option)
        let client = self.client

        state.answerQuestion(sessionID: sessionID, response: response)
        sessions = state.sessions

        Task {
            do {
                try await client.send(.answerQuestion(sessionID: sessionID, response: response))
            } catch {
                NSLog("[AgentsIsland] failed to answer question: \(error.localizedDescription)")
            }
        }
    }

    /// Focus the terminal window/pane this session is running in.
    func jump(to session: AgentSession) {
        guard let target = session.jumpTarget,
              target.terminalApp.lowercased() != "unknown" else { return }

        // jump(to:) shells out to osascript/tmux and can block for over a second —
        // it must never run on the main actor.
        Task.detached(priority: .userInitiated) {
            do {
                _ = try TerminalJumpService().jump(to: target)
            } catch {
                NSLog("[AgentsIsland] jump failed: \(error.localizedDescription)")
            }
        }
    }

    func canJump(to session: AgentSession) -> Bool {
        guard let target = session.jumpTarget else { return false }
        return target.terminalApp.lowercased() != "unknown"
    }

    private func attentionIDs() -> Set<String> {
        Set(state.sessions.filter { $0.phase.requiresAttention }.map(\.id))
    }

    // MARK: - Hooks

    /// Nothing writes to the bridge socket except the agents' own hooks, so without
    /// these installed the panel stays empty and no permission events ever arrive.
    ///
    /// Respects the stored preference: a user who turned an agent off in Settings must
    /// not have its hooks silently reinstated on the next launch.
    private func installHooksIfNeeded() {
        refreshHookStatus()

        guard let binary = Bundle.main.builtInHooksBinaryURL else {
            NSLog("[AgentsIsland] OpenIslandHooks missing from app bundle; live events disabled")
            return
        }

        let wanted = Set(Defaults[.agentsEnabledHooks])
        for target in AgentHookTarget.allCases
        where target.isAgentPresent && wanted.contains(target.rawValue) && hooksInstalled[target] != true {
            Task { await performHookChange(target, install: true, binary: binary) }
        }
    }

    func refreshHookStatus() {
        var states: [AgentHookTarget: Bool] = [:]
        for target in AgentHookTarget.allCases {
            states[target] = target.isInstalled()
        }
        hooksInstalled = states
    }

    func isHookInstalled(_ target: AgentHookTarget) -> Bool { hooksInstalled[target] == true }
    func isHookBusy(_ target: AgentHookTarget) -> Bool { hooksBusy.contains(target) }

    /// Make the filesystem agree with the preference. The caller owns the preference.
    func setHookEnabled(_ target: AgentHookTarget, _ enabled: Bool) {
        guard let binary = Bundle.main.builtInHooksBinaryURL else {
            hooksError = "OpenIslandHooks is missing from the app bundle."
            return
        }
        Task { await performHookChange(target, install: enabled, binary: binary) }
    }

    private func performHookChange(_ target: AgentHookTarget, install: Bool, binary: URL) async {
        hooksBusy.insert(target)
        hooksError = nil

        let message: String? = await Task.detached(priority: .userInitiated) {
            do {
                if install {
                    try target.install(binary: binary)
                } else {
                    try target.uninstall()
                }
                return nil
            } catch {
                return "\(target.displayName): \(error.localizedDescription)"
            }
        }.value

        if let message {
            NSLog("[AgentsIsland] hook \(install ? "install" : "uninstall") failed — \(message)")
        }
        hooksError = message
        hooksBusy.remove(target)
        refreshHookStatus()
        NSLog("[AgentsIsland] \(target.displayName) hooks now \(isHookInstalled(target) ? "installed" : "not installed")")
    }

}
