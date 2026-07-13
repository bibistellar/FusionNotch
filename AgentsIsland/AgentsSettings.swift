//
//  AgentsSettings.swift
//  boringNotch
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    static let agentsAutoOpenNotch = Key<Bool>("agentsAutoOpenNotch", default: true)
    /// Which agents' hooks the user wants installed. Read on every launch, so turning
    /// one off sticks instead of being undone by the next start.
    static let agentsEnabledHooks = Key<[String]>(
        "agentsEnabledHooks",
        default: AgentHookTarget.allCases.map(\.rawValue)
    )
}

struct AgentsSettings: View {
    @ObservedObject private var model = AgentSessionsModel.shared
    @Default(.agentsAutoOpenNotch) var autoOpenNotch
    @Default(.agentsEnabledHooks) var enabledHooks

    private var presentAgents: [AgentHookTarget] {
        AgentHookTarget.allCases.filter(\.isAgentPresent)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle()
                        .fill(model.isBridgeReady ? .green : .red)
                        .frame(width: 7, height: 7)
                    Text(model.isBridgeReady ? "Bridge running" : "Bridge offline")
                    Spacer()
                    Text("\(model.runningCount) running · \(model.attentionCount) waiting")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            Section {
                Toggle("Open the notch when an agent needs you", isOn: $autoOpenNotch)
            } footer: {
                Text("Pops the notch open on the Agents tab when a permission request or question arrives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if presentAgents.isEmpty {
                    Text("No supported agents found on this Mac.")
                        .foregroundStyle(.secondary)
                }

                ForEach(presentAgents) { agent in
                    hookRow(agent)
                }

                if let error = model.hooksError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Hooks")
            } footer: {
                Text("Without hooks the panel stays empty: agents only report sessions, permission requests and questions through them. Installing merges into the agent's existing config and leaves other tools' hooks alone; the original file is backed up next to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHookStatus() }
    }

    @ViewBuilder
    private func hookRow(_ agent: AgentHookTarget) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Bound to the stored preference, not to the on-disk result: the install is
            // async, and binding the switch to it would snap it back on every tap.
            Toggle(agent.displayName, isOn: binding(for: agent))

            HStack(spacing: 4) {
                if model.isHookBusy(agent) {
                    Text("Working…")
                } else {
                    Image(systemName: model.isHookInstalled(agent) ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(model.isHookInstalled(agent) ? .green : .secondary)
                    Text(model.isHookInstalled(agent) ? "Installed" : "Not installed")
                    if !agent.configFilePath.isEmpty {
                        Text("· \(agent.configFilePath)")
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func binding(for agent: AgentHookTarget) -> Binding<Bool> {
        Binding(
            get: { enabledHooks.contains(agent.rawValue) },
            set: { enabled in
                if enabled {
                    if !enabledHooks.contains(agent.rawValue) { enabledHooks.append(agent.rawValue) }
                } else {
                    enabledHooks.removeAll { $0 == agent.rawValue }
                }
                model.setHookEnabled(agent, enabled)
            }
        )
    }
}
