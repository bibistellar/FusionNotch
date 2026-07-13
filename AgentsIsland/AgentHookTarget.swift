//
//  AgentHookTarget.swift
//  boringNotch
//
//  The agents whose hooks we can install. Core ships installers for Cursor, Gemini,
//  Kimi and OpenCode too — add cases here as they're wired up.
//

import Foundation
import OpenIslandCore

enum AgentHookTarget: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Where the agent keeps its config. Absent means the agent isn't installed, and
    /// there is nothing to hook into.
    private var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return ClaudeConfigDirectory.resolved()
        case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    var isAgentPresent: Bool {
        FileManager.default.fileExists(atPath: configDirectory.path)
    }

    /// The file we merge our hooks into — shown in Settings so the change is not a secret.
    var configFilePath: String {
        switch self {
        case .claudeCode:
            (try? ClaudeHookInstallationManager().status().settingsURL.path) ?? ""
        case .codex:
            (try? CodexHookInstallationManager().status().hooksURL.path) ?? ""
        }
    }

    /// `managedHooksPresent`, i.e. "our hook command is in the config file".
    ///
    /// Deliberately not Claude's `hasClaudeIslandHooks`: that one tests for a legacy
    /// `claude-island-state.py` script and is false even when our hooks are installed.
    func isInstalled() -> Bool {
        switch self {
        case .claudeCode:
            (try? ClaudeHookInstallationManager().status().managedHooksPresent) ?? false
        case .codex:
            (try? CodexHookInstallationManager().status().managedHooksPresent) ?? false
        }
    }

    func install(binary: URL) throws {
        switch self {
        case .claudeCode:
            let manager = ClaudeHookInstallationManager()
            if let settings = try? manager.status().settingsURL {
                Self.backUpConfig(at: settings)
            }
            _ = try manager.install(hooksBinaryURL: binary)
        case .codex:
            let manager = CodexHookInstallationManager()
            if let hooks = try? manager.status().hooksURL {
                Self.backUpConfig(at: hooks)
            }
            _ = try manager.install(hooksBinaryURL: binary)
        }
    }

    func uninstall() throws {
        switch self {
        case .claudeCode: _ = try ClaudeHookInstallationManager().uninstall()
        case .codex: _ = try CodexHookInstallationManager().uninstall()
        }
    }

    /// Keep one copy of the file as it was before we ever touched it.
    private static func backUpConfig(at url: URL) {
        let backup = url.appendingPathExtension("pre-fusionnotch.bak")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
