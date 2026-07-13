### Install

1. Download `FusionNotch-*.zip` below and unzip it.
2. Move `FusionNotch.app` to `/Applications`.
3. The build is **ad-hoc signed** (no Apple Developer ID), so Gatekeeper refuses to open it
   until you clear the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/FusionNotch.app
   ```

4. Launch it. On first run it installs the agent hooks for Claude Code and Codex (merging
   into your existing config, with a backup taken first). Jump-to-terminal will ask for
   Apple Events permission the first time you use it.

**Without hooks the Agents panel stays empty** — nothing else writes to the bridge socket.

Requires macOS 14+ on a Mac with a notch.
