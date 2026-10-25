# Perch fork: architecture notes

Fork of asafofer/perch (MIT) at upstream 0.4.8 (`3f03128`). Read upstream `AGENTS.md` and `docs/behavior/*.md` for the owner's rules; this file is the short map for our work.

## Layout and build

- **SwiftPM only: no Xcode project, no XcodeGen.** `Package.swift` (tools 6.2, macOS 15+, Swift 5 mode). Targets: `PerchCore` (pure logic, tested), `Perch` (AppKit shell, executable), `PerchCoreTests` (swift-testing, 309 tests). One dependency: Sparkle 2.10 (binary artifact).
- The UI is **not SwiftUI**. It is one `WKWebView` (`ui/index.html`, `ui/app.js` ~4.1k lines of plain JS, Tailwind v3 compiled into the committed `ui/dist/ui.css`). Swift builds a `UISnapshot` (`Snapshot.swift`) and calls `window.perch.apply(json)`; the page posts events back via `webkit.messageHandlers.perch`, handled in `NotchController.userContentController`. The page never decides anything.
- `scripts/run.sh` = `npm run build` (CSS) + `swift build` + hand-assembled signed `build/Perch.app` (Info.plist, Sparkle framework, ui files) + launch. `scripts/make-dev-cert.sh` makes a stable signing identity (Accessibility grants are tied to the signature). `package.sh` / `make-dmg.sh` for release. CI: `swift test`, UI checks (app.js ASCII-only, dist/ui.css fresh), PR-body check.
- About 10k lines of Swift; `NotchController.swift` is 2286 lines and owns almost everything.
- `ui/design.html` is a browser-only design page with sample data (`window.perchDev`); upstream wants new UI shown there first.

## Detecting agents and terminals

Three sources, merged per session in `RealSessionProvider.parkedProjects()` / `placeTerminalSessions`:

1. **Session files (which sessions exist).** `SessionScanner` reads Claude `~/.claude/projects/*/*.jsonl` plus the Claude app's `claude-code-sessions` dir, Codex `~/.codex/sessions/**/rollout-*.jsonl`, OpenCode's SQLite db (read only), pi's jsonl, Conductor's SQLite, and (read only) claude.ai tasks/chats from the Claude app's IndexedDB. FSEvents on those dirs triggers a rescan (0.5 s while the card is up, 3 s idle).
2. **Process scan (what runs, and where).** `LiveSessions.scan()` in `Terminals.swift` walks `proc_listallpids`, filters by executable (`Agent.mayBe` / `recognise`: claude native or npm, codex, opencode, pi, node/bun by argv[0]), then reads the tty, cwd (`PROC_PIDVNODEPATHINFO`), argv + env (`KERN_PROCARGS2`) and the parent chain (`terminalApp(above:)` via `NSRunningApplication`). Env vars name the host: `HERDR_*`, `TMUX`/`TMUX_PANE`, `CMUX_SURFACE_ID`, `WARP_FOCUS_URL`. `Running.match` ties a process to a session (id in argv, else newest session in that cwd).
3. **Hooks (live status and approvals).** `HookInstaller` writes entries into `~/.claude/settings.json` / `~/.codex/hooks.json` (plugin files for OpenCode and pi). They POST to `HookServer`, a Unix socket at `~/.config/perch/perch.sock`. Events: UserPromptSubmit, PostToolUse, PermissionRequest, PreToolUse(AskUserQuestion), Stop, StopFailure, Interrupt. A permission or question request is held open until the notch answers (`HookServer.answer`). Hooks send the agent pid (`SessionPids`).

Agents: Claude Code, Codex, OpenCode, pi (plus Claude tasks/chats from the Claude app). Answer-from-notch (allow, deny, choose) only for Claude and OpenCode.

Terminals (`Terminals.keys`): Terminal, iTerm2, Ghostty, cmux, Warp (first-class); WezTerm, kitty, VS Code, Cursor, Zed (icon only). Multiplexers: herdr, tmux, cmux. **Orca is not recognised**: it falls under "any other terminal: bring forward", and typing into it fails (the reply stays on the clipboard).
Typing support: Terminal.app (`do script`), iTerm2 (`write text`), Ghostty/cmux (AppleScript, only when exactly one terminal has that cwd), herdr/tmux/cmux (their CLIs). Warp, VS Code and the rest: clipboard only.
`LiveSessions` only sees agents **with a tty**; sessions started by the Claude/Codex/OpenCode apps are not in it.

## Session and state model

- `Project` (`PerchCore/Project.swift`) is the session row: id, name, branch, `agents: [AgentStatus]` (done / needsYou / idle / running), `ask` (pending question or permission), `now` (current tool step), `said` / `asked` (last messages), `pid`, `spot`, `via` (terminal bundle id), `host`, `terminal`, `lastActive`, `waiting`, `toolOpen`.
- Status precedence: hooks > herdr status > transcript heuristics (`LiveStatus`, `Transcript`, `Project.settled` / `agentGone`). `Recap` builds the headline and next text.
- `NotchMachine` (pure) phases: idle, open (one card), switcher (list), restoring, onboarding, settings, whatsNew, newSession. The list is capped at 15 rows, about 5 visible.
- Persistent state is UserDefaults (`Prefs`): seen, places, shortcuts, sources, idleMinutes, questionSeconds, showOn, notifyOff. Drafts are in memory.
- There is no todo model: `now` is the single current step; TodoWrite is not parsed.

## Notch window and UI

- `NotchPanel`: borderless `.nonactivatingPanel`, level mainMenu+3, canJoinAllSpaces + fullScreenAuxiliary, **one fixed transparent 480x440 window** (+10 pt overscan) placed by `NotchGeometry.panelFrame` on the screen `ScreenChooser` picks. `ignoresMouseEvents = true` at rest; hover is a rect check (`hoverTask`) and the pointer is passed to the page.
- Card width 400, list tabs 148. States drawn in `app.js`: card, list, reply, live-activity wings, settings pages, new session, onboarding. `size` messages report content size back to Swift.
- Hotkeys: Cmd+Option tap (needs Accessibility, `ModifierTap`) or a recorded combo; Opt+Cmd+N new session; Cmd+Opt+O open; Cmd+Opt+. dismiss (`HotkeyService`: Carbon + event tap).

## Reply and approve, end to end

- **Approve / answer:** hook request held in `HookServer` -> `onEvent` -> `Project.ask` -> wings or card buttons (or number keys) -> page posts `answer` -> `HookServer.answer(askId, body)` writes the reply JSON to the held socket -> agent proceeds -> "Sent" line.
- **Reply to a terminal session:** page posts `reply` -> `NotchController.reply` -> background queue: `LiveSessions.all()` (a full process scan) -> `Terminals.type` (AppleScript or CLI; paste, then Return as a separate key) -> card flies the words up. If the process is not recognised, `Restorer.reopen` runs `claude --resume` in a new tab, then `Thread.sleep(1.5)` and restores focus. Otherwise clipboard plus "Reply copied".
- **Reply to a Claude app session:** `ClaudeComposer` drives the Claude window through Accessibility (ProseMirror field) with the window left behind; falls back to paste. Needs Accessibility.
- Opening the reply box calls `frontForReply(true)`: `NSApp.activate` + `NSWorkspace.openApplication` so the panel can become key; `WhereYouWere` restores the previous app and window afterwards.

## Settings

Drawn by the page (`settingsRender`), values from `settingsState`, changes through `setting` / `source` / `notify` / `hooks` messages. Pages: Shortcuts, Agents (per-agent toggle, Live status hook install), Notifications (`NotifyKind` switches, welcome-back minutes, question seconds), Character, General (login item, Show on display, hover on external), Version (Sparkle), Send feedback (Vercel function). No process or resource page.

## Rough edges seen in the code

- **Latency:** every terminal reply runs a full `proc_listallpids` + `KERN_PROCARGS2` scan (`LiveSessions.all()`) and often spawns osascript before typing; the scan result is not cached. Fixed sleeps: `delay 0.1` (Ghostty/cmux), `Thread.sleep(1.5)` on reopen, `asyncAfter` 0.35 s (reply menu) and 0.8 s (`say`).
- **Focus stealing:** opening a reply activates the whole app, then re-activates the old app on close (`frontForReply`); hover-opened cards `makeKey` when `cardTakesKeys`; `chooseFolder` and feedback also activate. Pick up drives Terminal/Warp tabs with AppleScript and synthesized Cmd+1..9 keystrokes.
- **Text input:** the reply field is an HTML input in a WKWebView, so IME, paste, drafts and attachments are custom; attachments go in as pasted paths.
- **Animation:** the panel never resizes, so the page resizes itself via `size` messages and a `reveal(token)` / `painted` handshake with 0.3 s fallbacks; the `swapText` / `morphText` transitions replay if a value is set twice per snapshot (upstream warns about it).
- **Structure:** `NotchController` is a 2.3k-line god object mixing `DispatchQueue.global` and `MainActor.assumeIsolated`; everything flows through one snapshot JSON, so a second window needs its own snapshot channel.
- **Coverage gaps:** Orca, VS Code and Warp typing; Codex and pi cannot be answered from the notch; no CPU/RAM anywhere; todos not surfaced; list capped at 15, five visible.
- **Upstream conventions to decide on:** one-line commits with no AI mention, UI shown in `design.html` first, PR template with a filmed demo (a hook blocks `gh pr create` without it). The fork may keep or relax these.
- **Mac build trap:** over SSH, `swift build` fails fetching Sparkle ("Failed to find credentials in keychain, -25308"); use `swift build --disable-keychain` / `swift test --disable-keychain`.
