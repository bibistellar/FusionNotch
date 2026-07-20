//
//  NotesPanel.swift
//  boringNotch
//
//  The Notes side panel: the most recently edited notes, next to the music player.
//
//  Notes.app has no public API — EventKit covers Calendar and Reminders, nothing covers
//  Notes — so this goes through AppleScript, which has two consequences worth knowing:
//
//  1. Talking to Notes *launches* Notes.app if it isn't running. There is no way around
//     that, so the fetch only happens while the panel is actually on screen.
//  2. It needs Automation permission for Notes, which macOS asks for on first use.
//
//  Only titles and dates are read. The note bodies are the user's private writing and the
//  panel has no use for them, so they never enter this process.
//

import AppKit
import Defaults
import Foundation
import SwiftUI

struct NoteSummary: Identifiable, Equatable {
    let id: String              // Notes' own note id, for `show note id "..."`
    let title: String
    let modifiedAt: Date
}

@MainActor
final class NotesManager: ObservableObject {
    static let shared = NotesManager()

    @Published private(set) var notes: [NoteSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var lastFetch: Date?

    private init() {}

    /// The view polls every five seconds while visible. Keep a little headroom so repeated
    /// SwiftUI task wakeups cannot issue duplicate Apple Events.
    private static let minimumInterval: TimeInterval = 4

    func refreshIfStale(force: Bool = false) {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < Self.minimumInterval {
            return
        }
        guard refreshTask == nil else { return }

        isLoading = notes.isEmpty
        refreshTask = Task { [weak self] in
            defer { Task { @MainActor in self?.refreshTask = nil } }
            await self?.fetch()
        }
    }

    private func fetch() async {
        let limit = Defaults[.notesPanelLimit]

        // One round trip for all three lists, then sort here. A `repeat` loop over the
        // notes in AppleScript is an Apple Event per note per property and gets slow fast;
        // asking for the three lists at once stays flat.
        //
        // Ask `notes` directly. Binding it to a variable first (`set theNotes to notes`)
        // materialises a plain AppleScript list of references, and `name of` a list is an
        // error — the whole-object specifier is what makes this a single bulk query.
        let script = """
        tell application "Notes"
            return {name of notes, id of notes, modification date of notes}
        end tell
        """

        do {
            guard let result = try await AppleScriptHelper.execute(script) else { return }
            let parsed = Self.parse(result, limit: limit)
            notes = parsed
            errorMessage = nil
            lastFetch = Date()
        } catch {
            // The usual cause is a declined Automation prompt. Say so rather than showing
            // an empty panel that looks like "you have no notes".
            errorMessage = "Can't read Notes"
            NSLog("[NotesPanel] fetch failed: \(error.localizedDescription)")
        }
        isLoading = false
    }

    /// The descriptor is a 3-element list of parallel lists: names, ids, dates.
    private nonisolated static func parse(
        _ descriptor: NSAppleEventDescriptor,
        limit: Int
    ) -> [NoteSummary] {
        guard descriptor.numberOfItems >= 3,
              let names = descriptor.atIndex(1),
              let ids = descriptor.atIndex(2),
              let dates = descriptor.atIndex(3) else { return [] }

        let count = min(names.numberOfItems, min(ids.numberOfItems, dates.numberOfItems))
        guard count > 0 else { return [] }

        var summaries: [NoteSummary] = []
        summaries.reserveCapacity(count)

        for index in 1...count {
            guard let title = names.atIndex(index)?.stringValue,
                  let id = ids.atIndex(index)?.stringValue,
                  let modified = dates.atIndex(index)?.dateValue else { continue }
            summaries.append(NoteSummary(id: id, title: title, modifiedAt: modified))
        }

        return summaries
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Reveal a note in Notes.app.
    func open(_ note: NoteSummary) {
        let escaped = note.id.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Notes"
            activate
            show note id "\(escaped)"
        end tell
        """
        Task {
            do {
                try await AppleScriptHelper.executeVoid(script)
            } catch {
                NSLog("[NotesPanel] failed to open note: \(error.localizedDescription)")
            }
        }
    }
}

struct NotesView: View {
    @ObservedObject private var manager = NotesManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        manager.refreshIfStale(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh Notes")
                }
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // `.onAppear` only runs when SwiftUI inserts this panel. The home view can stay
            // mounted while Notes.app is edited, so keep refreshing for exactly as long as
            // the panel remains visible; SwiftUI cancels this task when it disappears.
            manager.refreshIfStale(force: true)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                manager.refreshIfStale()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = manager.errorMessage {
            centered {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Allow FusionNotch to control Notes in Privacy & Security → Automation.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        } else if manager.notes.isEmpty, !manager.isLoading {
            centered {
                Text("No notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(manager.notes) { note in
                        NoteRow(note: note)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func centered<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        VStack(spacing: 3) { body() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoteRow: View {
    let note: NoteSummary
    @State private var isHovering = false

    var body: some View {
        Button {
            NotesManager.shared.open(note)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(note.modifiedAt, format: .relative(presentation: .named))
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(isHovering ? 0.1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
