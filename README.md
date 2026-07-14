# FusionNotch

**Your MacBook notch, but it also watches your AI coding agents.**

FusionNotch merges two GPL-3.0 projects — [boring.notch](https://github.com/TheBoredTeam/boring.notch)
and [Open Island](https://github.com/Octane0411/open-vibe-island) — into a single app.

Both upstreams fight over the same pixels (the MacBook notch) while doing completely
complementary things: boring.notch handles media controls, calendar, a file shelf and HUDs;
Open Island tracks AI coding-agent sessions. Running both means two overlays wrestling for
the same strip of screen, so Open Island is folded into boring.notch as one more tab.

[中文说明见下方](#中文说明)

---

## What it adds

A new **Agents** tab inside the notch:

- **Live session list** for Claude Code and Codex — which agent, which workspace, what it's doing.
- **The notch pops open when an agent needs you**, and you can hit **Allow / Deny** right there.
  No tabbing back to the terminal to unblock a permission prompt.
- **Jump back to the terminal** running a session — one click focuses the right window / tmux pane.
- **Dead sessions are culled** automatically by watching the agent processes.
- Per-agent hook toggles in Settings.

Everything boring.notch already did (music, calendar, shelf, HUDs, battery) still works.

| | |
|---|---|
| Host | boring.notch — notch window, CGS Spaces, tab bar |
| Payload | Open Island — agent session tracking, hooks, bridge |
| Agents | Claude Code, Codex |
| License | GPL-3.0 (both upstreams are GPL-3.0; a merge has to stay that way) |
| Requires | macOS 14+, a Mac with a notch |

## Install

Grab the latest zip from [**Releases**](../../releases), or build it yourself (below).

The release build is **ad-hoc signed** — there is no Apple Developer ID behind it — so
Gatekeeper will refuse to open it until you clear the quarantine flag:

```sh
unzip FusionNotch-*.zip
mv FusionNotch.app /Applications/
xattr -dr com.apple.quarantine /Applications/FusionNotch.app
open /Applications/FusionNotch.app
```

On first launch it installs the agent hooks (see below). The jump-to-terminal feature asks
for Apple Events permission the first time you use it.

> **Do not re-sign the app with `codesign --force --deep --sign -`.** That strips the
> entitlements — including `automation.apple-events` — and the jump feature then fails
> silently. Copy the bundle with `ditto` instead.

## Hooks are the whole ballgame

**Without hooks the Agents panel stays empty.** Nothing writes to the bridge socket except
the agents' own hook processes.

The `OpenIslandHooks` helper is compiled by the *Embed OpenIslandHooks* build phase and
shipped inside `Contents/Helpers/`. On first launch it is installed into the agents' configs:

| Agent | Config file | Backup taken |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `settings.json.pre-fusionnotch.bak` |
| Codex | `~/.codex/hooks.json` | `hooks.json.pre-fusionnotch.bak` |

Installation **merges** into the existing config — other tools' hooks are left alone — and the
original file is backed up next to it first. You can turn either agent off in Settings → Agents.

**Known limitation:** Claude Code does not fire the `PermissionRequest` hook for the
Agent/Task (sub-agent) tool, so those approvals never reach the notch. Bash / Edit / Write
work fine. This is upstream behaviour and cannot be fixed from here.

## Build

```sh
xcodebuild -project FusionNotch.xcodeproj -scheme FusionNotch \
  -configuration Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" build
```

`ENABLE_USER_SCRIPT_SANDBOXING` is deliberately off: the build phase that embeds the hook
helper runs a nested `swift build` and cannot read `Vendor/` from inside the script sandbox.

CI builds every push; tagging `v*` builds a Release, verifies the bundle and publishes the
zip to GitHub Releases (`.github/workflows/`).

## Architecture

```
FusionNotch.xcodeproj
├── boringNotch/                 upstream boring.notch, 5 seams touched
│   ├── enums/generic.swift          NotchViews gains `case agents`
│   ├── components/Tabs/…            tab array gains an Agents entry
│   ├── ContentView.swift            switch gains `case .agents`
│   ├── boringNotchApp.swift         starts the bridge; opens the notch on attention
│   └── components/Settings/…        settings sidebar gains an Agents pane
├── AgentsIsland/                new code (file-system-synchronized group)
│   ├── AgentSessionsModel.swift     bridge lifecycle + SessionState reduction
│   ├── AgentsView.swift             session rows, approval cards
│   ├── AgentsSettings.swift         settings pane
│   ├── AgentToolMark.swift          vendor brand marks
│   └── 6 more files                 ported verbatim from OpenIslandApp
└── Vendor/OpenIslandCore/       local SwiftPM package carved out of Open Island,
                                 plus the OpenIslandHooks CLI
```

Open Island's own notch-window implementation (`OverlayPanelController`, `NotchShape`,
`IslandSurface` — roughly 1,750 lines) is **dropped entirely**; it duplicates what
boring.notch already does.

**The bridge loopback.** `BridgeServer` exposes no callback or delegate — it only broadcasts
onto a Unix socket. The host app has to connect back to *its own* socket as a
`LocalBridgeClient` and send `registerClient(role: .observer)` to see anything. That loopback
is the crux of the integration; see `AgentSessionsModel.connect()`. The bridge starts in
`applicationDidFinishLaunching` rather than when the Agents tab first appears — events that
arrive while the notch is shut are exactly the ones worth raising.

**The sandbox is off.** `com.apple.security.app-sandbox` is `false`. The bridge binds a Unix
socket in Application Support, liveness detection shells out to `ps`/`lsof`, and jumping uses
`osascript`/`tmux` — none of that is expressible as a sandbox entitlement. The only cost is
the Mac App Store, which boring.notch was already locked out of by its three private-API
dependencies (CGS Spaces, SkyLight, MediaRemote).

**Auto-update is this fork's own.** Upstream's Sparkle feed is left in place in most forks by
accident, which would cheerfully "upgrade" the app back into stock boring.notch and delete the
Agents tab. FusionNotch points at its own appcast and its own EdDSA signing key, so only an
archive signed by this repo's release workflow will ever be installed. Tagging a release
builds it, signs the archive, and commits the new item to `appcast.xml` on `main`, which is
what the app reads.

## Not ported

- Replying to the terminal from inside the notch (`TerminalTextSender`).
- Notification suppression when the terminal is already frontmost (`ForegroundTerminalSessionProbe`).
- Hook installers for Cursor / Gemini / Kimi / OpenCode — they exist in Core, but only
  Claude Code and Codex are wired into the settings pane.

## Credits & license

- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) — GPL-3.0
- [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island) — GPL-3.0

FusionNotch is a derivative work of both and is released under the **GPL-3.0** as well; see
[LICENSE](LICENSE). The app icon comes from open-vibe-island (`Assets/Brand/`). The Anthropic
and OpenAI marks are used nominatively, to identify whose session a row belongs to; they are
their owners' trademarks and this project is not affiliated with or endorsed by either.

---

## 中文说明

FusionNotch 把 [boring.notch](https://github.com/TheBoredTeam/boring.notch) 和
[Open Island](https://github.com/Octane0411/open-vibe-island) 两个 GPL-3.0 项目合并成了一个刘海应用。

两者都在抢同一块屏幕空间（MacBook 刘海），功能却完全互补：前者管媒体控制、日历、文件暂存和 HUD，
后者管 AI coding agent 的会话状态。同时装两个会 UI 打架，所以把后者作为一个标签页并进前者。

刘海里新增 **Agents** 标签页：

- 实时列出正在跑的 Claude Code / Codex 会话
- agent 请求权限时**自动弹开刘海**，可直接 **Allow / Deny**，不用切回终端
- 一键**跳回**该会话所在的终端窗口或 tmux 分屏
- 进程存活检测，自动剔除已结束的会话
- 设置页可分别开关每个 agent 的 hook

boring.notch 原有功能（音乐、日历、Shelf、HUD、电池）全部保留。

**安装**：从 [Releases](../../releases) 下载 zip，解压后拖进 `/Applications`，然后**必须**去掉隔离标记
（应用是 ad-hoc 签名，没有 Apple 开发者证书）：

```sh
xattr -dr com.apple.quarantine /Applications/FusionNotch.app
```

**没有 hook，面板就是空的**——socket 上的事件只由 agent 自己的 hook 进程写入。首次启动会自动安装，
合并写入 `~/.claude/settings.json` 和 `~/.codex/hooks.json`，不影响其他工具已有的 hook，并且会先备份原文件。

已知限制：Claude Code **不为 Agent（子任务）工具触发 `PermissionRequest` hook**，那类审批不会出现在
刘海里；Bash / Edit / Write 正常。这是上游行为，本项目无法绕过。
