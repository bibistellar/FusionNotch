//
//  AgentsView.swift
//  boringNotch
//
//  The "Agents" tab: live AI coding agent sessions, rendered in the open notch.
//

import OpenIslandCore
import SwiftUI

struct AgentsView: View {
    @ObservedObject var model = AgentSessionsModel.shared

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(model.sessions) { session in
                            AgentSessionRow(session: session)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(.gray)
            Text("No agent sessions")
                .font(.caption)
                .foregroundStyle(.gray)
            Text(model.isBridgeReady ? "Waiting for activity" : "Bridge offline")
                .font(.caption2)
                .foregroundStyle(.gray.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentSessionRow: View {
    let session: AgentSession
    @ObservedObject private var model = AgentSessionsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentToolMark(tool: session.tool, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.jumpTarget?.workspaceName ?? session.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(session.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if model.canJump(to: session), let app = session.jumpTarget?.terminalApp {
                    Button {
                        model.jump(to: session)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.forward.app")
                            Text(app)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(.white.opacity(0.08)) }
                    }
                    .buttonStyle(.plain)
                    .help("Jump to \(app)")
                }

                PhaseBadge(phase: session.phase)

                // Only Claude exposes switchable permission modes.
                if session.claudeMetadata != nil {
                    PermissionModeMenu(session: session)
                }
            }

            if let request = session.permissionRequest {
                PermissionCard(session: session, request: request, model: model)
            } else if let prompt = session.questionPrompt {
                QuestionCard(session: session, prompt: prompt, model: model)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(session.phase.requiresAttention
                      ? Color.orange.opacity(0.18)
                      : Color(nsColor: .secondarySystemFill).opacity(0.5))
        }
    }
}

struct PermissionCard: View {
    let session: AgentSession
    let request: PermissionRequest
    let model: AgentSessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !request.affectedPath.isEmpty {
                Text(request.affectedPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if request.requiresTerminalApproval {
                // Claude can only take this one back in the terminal it came from;
                // pretending otherwise with a button here would just silently do nothing.
                Label("Approve in the terminal", systemImage: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ActionButton(title: request.primaryActionTitle, tint: .green) {
                            model.resolvePermission(sessionID: session.id, approve: true)
                        }
                        ActionButton(title: request.secondaryActionTitle, tint: .red) {
                            model.resolvePermission(sessionID: session.id, approve: false)
                        }
                    }

                    // Claude's own "always allow / switch mode" options, which it ships
                    // with the request and the panel used to drop. Clicking one hands the
                    // exact update back for Claude to apply — the app never decides on its
                    // own, so Claude's safety controls stay in charge.
                    ForEach(Array(request.suggestedUpdates.prefix(3).enumerated()), id: \.offset) { _, update in
                        ActionButton(title: update.displayLabel, tint: .blue) {
                            model.allow(sessionID: session.id, applying: [update])
                        }
                    }
                }
            }
        }
        .padding(.leading, 32)
    }
}

struct QuestionCard: View {
    let session: AgentSession
    let prompt: QuestionPrompt
    let model: AgentSessionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(prompt.title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)

            HStack(spacing: 6) {
                ForEach(prompt.options.prefix(3), id: \.self) { option in
                    ActionButton(title: option, tint: .blue) {
                        model.answerQuestion(sessionID: session.id, option: option)
                    }
                }
            }
        }
        .padding(.leading, 32)
    }
}

struct ActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(tint.opacity(0.18))
                }
        }
        .buttonStyle(.plain)
    }
}

/// Per-session switch for Claude's built-in permission modes. Picking a mode
/// doesn't change anything itself — it queues a `setMode` that gets handed to
/// Claude on the next request the user approves, so Claude applies and enforces
/// it. The label shows Claude's current mode, and a clock marks a change that's
/// waiting for that next approval.
struct PermissionModeMenu: View {
    let session: AgentSession
    @ObservedObject private var model = AgentSessionsModel.shared

    /// The modes Claude actually cycles between interactively.
    private let selectable: [ClaudePermissionMode] = [.default, .acceptEdits, .plan, .bypassPermissions]

    private var current: ClaudePermissionMode? { session.claudeMetadata?.permissionMode }
    private var pending: ClaudePermissionMode? { model.pendingModeChange[session.id] }

    var body: some View {
        Menu {
            ForEach(selectable, id: \.self) { mode in
                Button {
                    // Picking the current mode clears any pending change instead.
                    model.requestModeChange(sessionID: session.id, to: mode == current ? nil : mode)
                } label: {
                    if mode == (pending ?? current) {
                        Label(mode.shortLabel, systemImage: "checkmark")
                    } else {
                        Text(mode.shortLabel)
                    }
                }
            }
            if pending != nil {
                Divider()
                Button("Cancel pending change") {
                    model.requestModeChange(sessionID: session.id, to: nil)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "lock.shield")
                Text((pending ?? current)?.shortLabel ?? "Mode")
                if pending != nil {
                    Image(systemName: "clock")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(pending != nil ? .orange : .white.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background { Capsule().fill(.white.opacity(0.08)) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(pending != nil
              ? "Switches to \(pending!.shortLabel) when you next approve a request in this session"
              : "Claude permission mode")
    }
}

extension ClaudePermissionMode {
    var shortLabel: String {
        switch self {
        case .default: "Default"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .bypassPermissions, .dontAsk: "Bypass"
        case .auto: "Auto"
        }
    }
}

struct PhaseBadge: View {
    let phase: SessionPhase

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(phase.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch phase {
        case .running: .green
        case .waitingForApproval: .orange
        case .waitingForAnswer: .yellow
        case .completed: .gray
        }
    }
}

extension Color {
    /// OpenIslandCore hands out brand colors as hex strings.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}
