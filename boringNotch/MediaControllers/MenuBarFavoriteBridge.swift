//
//  MenuBarFavoriteBridge.swift
//  boringNotch
//
//  "Like" for players that expose no scripting interface.
//
//  Apple Music and Spotify hand out an AppleScript dictionary, so favoriting is a
//  one-liner. NetEase Cloud Music and SPlayer offer neither a scripting dictionary nor a
//  MediaRemote "like" command. What they do have is a native AppKit menu — NetEase in its
//  menu bar (控制 → 喜欢歌曲), SPlayer in its tray menu — and a menu item can be pressed
//  from another process without stealing focus.
//
//  The two differ in one way that matters to the UI:
//
//  - NetEase's item is always titled 喜欢歌曲, whatever the track's state. We can press it
//    but we cannot read the state, so its heart is a toggle, not an indicator.
//  - SPlayer's item flips between 添加到我喜欢 and 从我喜欢中移除, so its state *is*
//    readable and its heart can be filled honestly.
//
//  Neither needs Chromium's accessibility tree forced on (AXManualAccessibility): both
//  menus are native NSMenus and are in the tree already. That matters — forcing it makes
//  the player build a full a11y tree for its web UI, which costs it memory and CPU for
//  nothing.
//

import AppKit
import ApplicationServices

enum MenuBarFavoriteBridge {
    /// A player's like control, described by the menu-item titles to look for.
    struct Player {
        /// Titles shown when the current track is already liked. Pressing un-likes it.
        let likedTitles: [String]
        /// Titles shown when it is not. Pressing likes it.
        let notLikedTitles: [String]
        /// Titles of a control that toggles but never says which way it will go.
        let statelessTitles: [String]

        var readsState: Bool { !likedTitles.isEmpty || !notLikedTitles.isEmpty }

        var allTitles: [String] { likedTitles + notLikedTitles + statelessTitles }
    }

    private static let players: [String: Player] = [
        // 控制 → 喜欢歌曲 (⌘L). Same title whether or not the track is liked.
        "com.netease.163music": Player(
            likedTitles: [],
            notLikedTitles: [],
            statelessTitles: ["喜欢歌曲", "Like Song"]
        ),
        // Tray menu. Matched on the full title: a bare "喜欢" would also match the
        // sidebar's 我喜欢的音乐 nav item, and pressing *that* just navigates the UI
        // while looking, from here, exactly like a successful like.
        "com.imsyy.splayer": Player(
            likedTitles: ["从我喜欢中移除", "Remove from My Favorites"],
            notLikedTitles: ["添加到我喜欢", "Add to My Favorites"],
            statelessTitles: []
        ),
        "com.tencent.QQMusicMac": Player(
            likedTitles: [],
            notLikedTitles: [],
            statelessTitles: ["喜欢", "红心", "Like"]
        ),
    ]

    static func supportsFavorite(bundleIdentifier: String) -> Bool {
        players[bundleIdentifier] != nil
    }

    /// Whether the player tells us if the current track is liked. When it does not, the
    /// UI must not pretend to know: a filled heart on a track we never checked is a lie.
    static func readsFavoriteState(bundleIdentifier: String) -> Bool {
        players[bundleIdentifier]?.readsState ?? false
    }

    /// Pressing another app's menu items is what Accessibility gates. Without the grant
    /// every call below fails in a way that is indistinguishable from "no such menu item".
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// `true` liked, `false` not liked, `nil` unknown (player not supported, not running,
    /// no Accessibility grant, or a player whose control carries no state).
    static func favoriteState(bundleIdentifier: String) -> Bool? {
        guard let player = players[bundleIdentifier], player.readsState, isTrusted,
              let (_, title) = findLikeItem(bundleIdentifier: bundleIdentifier, player: player)
        else { return nil }

        if player.likedTitles.contains(title) { return true }
        if player.notLikedTitles.contains(title) { return false }
        return nil
    }

    /// Toggle the like state of whatever the player is currently playing.
    ///
    /// Deliberately not `setFavorite(_:)`: the menu item is a toggle, and for the players
    /// that hide their state there is no way to honour an absolute value.
    @discardableResult
    static func toggleFavorite(bundleIdentifier: String) -> Bool {
        guard let player = players[bundleIdentifier] else { return false }
        guard isTrusted else {
            requestTrust()
            return false
        }
        guard let (item, _) = findLikeItem(bundleIdentifier: bundleIdentifier, player: player)
        else { return false }

        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    // MARK: - Accessibility plumbing

    private static func findLikeItem(
        bundleIdentifier: String,
        player: Player
    ) -> (AXUIElement, String)? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return findMenuItem(in: axApp, titles: player.allTitles, depth: 0)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return "" }
        return title
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return "" }
        return role
    }

    /// Depth-limited walk. Depth matters: menus nest, and an unbounded walk over a live
    /// menu tree is a good way to hang on an app that builds its items lazily.
    private static func findMenuItem(
        in element: AXUIElement,
        titles: [String],
        depth: Int
    ) -> (AXUIElement, String)? {
        guard depth < 16 else { return nil }

        if role(of: element) == kAXMenuItemRole as String {
            let name = title(of: element)
            if titles.contains(name) { return (element, name) }
        }

        for child in children(of: element) {
            if let found = findMenuItem(in: child, titles: titles, depth: depth + 1) {
                return found
            }
        }

        return nil
    }
}
