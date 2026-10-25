# Perch fork: phased plan

Each phase is one PR-sized slice. Order is by value; R3 quick wins first. All verification runs on the Mac:
`ssh nambouchara@100.64.243.31`, then in `~/Projects/perch`: `swift build --disable-keychain` and `swift test --disable-keychain` (the flag avoids the SSH keychain failure when fetching Sparkle). Anything with UI also needs `cd ui && npm run build` (node is in `/opt/homebrew/bin`, add it to PATH) and `./scripts/run.sh --show` for a look. Useful flags: `--dump` (prints what the scan finds), `PERCH_TRACE=1`.
Conventions to decide once: upstream wants one-line commits, UI shown in `ui/design.html` first, and a PR template with demo. Keep `app.js` ASCII-only and rebuild `ui/dist/ui.css` whenever classes change.

## Phase 1 (R3 quick win): cache the process scan, drop reply latency

- Problem: every reply calls `LiveSessions.all()` (full `proc_listallpids` + `KERN_PROCARGS2`) before typing, and `FocusProbe` scans every second.
- Change: a `LiveSessionsCache` (actor or locked struct) with a 1 s TTL, refreshed by the existing periodic scan and by hook events (`SessionPids`); `reply` uses the cached `Hit` when `pid` still alive (`kill(pid,0)`) and falls back to a rescan. Replace `delay 0.1` with a post-write check only where needed.
- Files: `Sources/Perch/Terminals.swift`, `NotchController.swift` (reply path ~1335-1400), `RealSessionProvider.swift`, new test in `Tests/PerchCoreTests`.
- Verify: `swift test`; on the Mac run Perch with `PERCH_TRACE=1`, send a reply to a Terminal.app session, and compare the logged send-to-type time before and after (add one timing log line, target under 150 ms vs the current scan time).

## Phase 2 (R3): reply without stealing focus

- Problem: `frontForReply(true)` activates Perch fully (plus `NSWorkspace.openApplication`) so the field can type; the previous app is re-activated afterwards, which flickers and moves terminals. Return is sent as a separate key.
- Change: keep the panel `nonactivatingPanel` and make it key without `NSApp.activate` (`NSPanel` with `.nonactivatingPanel` can take key input; only fall back to activation when WKWebView refuses focus). Only restore the previous app when Perch actually activated. Add Cmd+Return = send and Esc = back, shown as hints.
- Files: `NotchController.swift` (`frontForReply`, `setReplyOpen`, ~970-1010, 1565-1590), `NotchPanel.swift`, `ui/app.js` (reply box keys ~600), `docs/behavior/replies.md`, `keyboard.md`.
- Verify: on the Mac `./scripts/run.sh --show`; with Terminal frontmost, open a reply and check via `osascript -e 'tell application "System Events" to name of first process whose frontmost is true'` that the front app stays Terminal while typing works; send and confirm the line reaches the tty.

## Phase 3 (R3): type into more terminals (Warp, VS Code, Orca)

- Problem: only Terminal, iTerm2, Ghostty, cmux, herdr, tmux accept typed replies; Warp, VS Code, Orca fall back to clipboard. Orca is not in `Terminals.keys`.
- Change: add Orca bundle id to `Terminals.keys` and treat its terminal as "bring forward"; use `tty` write fallback for any terminal (`/dev/ttysNNN` write is not allowed for injecting input, so instead use `TIOCSTI` only if permitted, otherwise keep clipboard) and for Warp use its `warp://` URI plus paste via a System Events keystroke into the focused tab (guarded by `Shown.exact`). Document the exact limits in `agents.md`.
- Files: `Terminals.swift`, `Sources/PerchCore/Place.swift`, `Tests/PerchCoreTests/FocusTests.swift`, `docs/behavior/sessions.md`.
- Verify: start `claude` in Orca and Warp on the Mac, run `Perch --dump` and confirm `via` shows the right app; reply from the notch and check the text arrives (or "Reply copied" with the correct session).

## Phase 4 (R1 foundation): snapshot for all sessions plus a todo/last-message field

- Change: extend `Project`/`UISnapshot` with `todos` (parse Claude `TodoWrite` tool_use in `Transcript.swift`, last state), `lastMessage` (already `said`), and a `memory`/`cpu` slot (empty for now). Lift the 15-row cap behind a `bigView` flag. No UI yet.
- Files: `Sources/PerchCore/Transcript.swift`, `Project.swift`, `Sources/Perch/Snapshot.swift`, `RealSessionProvider.swift`, `Tests/PerchCoreTests/TranscriptTests.swift`.
- Verify: `swift test` (new fixtures with a TodoWrite line); `./scripts/run.sh --snapshot /tmp/snaps` then inspect the JSON, or `Perch --dump` showing todos per session.

## Phase 5 (R1): the big view window

- Change: a second window `ManagerWindow` (regular `NSWindow`, resizable, remembers frame) hosting its own `WKWebView` that loads `ui/manager.html` + `ui/manager.js` and receives the same snapshot (add a second `window.manager.apply`). Grid or table of every session: agent icon, project/branch, status ring, current step, todos progress, last message, terminal badge, with Reply (inline field reusing the reply path), Approve/Deny for an `ask`, and Jump (existing `Restorer.resume` / `Terminals.focus`). Open from a status-item menu entry, Cmd+Opt+M, and a "Manage" button in the list. Add a `manager` event channel in `NotchController` (or extract a small `ManagerController` to avoid growing the god object).
- Files: new `Sources/Perch/ManagerController.swift`, `ui/manager.html`, `ui/manager.js`, `input.css`, `scripts/run.sh` (copy new ui files), `main.swift` (menu/hotkey), `ui/design.html` (scenario), `docs/behavior/manager.md`.
- Verify: on the Mac, launch with two or more live agent sessions, open the window with the hotkey, check each row shows its status and that Jump focuses the right tab and an inline reply lands in the right tty (`Perch --dump` for ground truth). Take a `screencapture -x` of the window.

## Phase 6 (R2): per-process resource model

- Change: new `PerchCore/ProcessTree.swift` (pure: tree building and aggregation, testable with fake tables) and `Sources/Perch/ProcessStats.swift` (macOS side): `proc_listpids` / `KERN_PROC_ALL` for pid/ppid, `proc_pid_rusage(RUSAGE_INFO_V4)` for `ri_phys_footprint` (RAM, matches Activity Monitor) and `ri_user_time + ri_system_time` deltas between two samples for CPU%. Aggregate each agent `Hit`'s descendant tree (node, language servers, test runners, dev servers). Sample every 2 s only while the big view or the processes page is visible. Extend scan to include Claude/Codex app helper processes without a tty (flag as "app session").
- Files: new `ProcessTree.swift`, `ProcessStats.swift`, `Terminals.swift` (expose pid per hit), `Snapshot.swift`, `Tests/PerchCoreTests/ProcessTreeTests.swift`.
- Verify: `swift test`; on the Mac start a Claude session that runs `node -e "setInterval(()=>{},1e3)"` and `yes > /dev/null`, run `Perch --dump-procs` (new flag) and compare the printed tree RAM/CPU against `ps -o pid,ppid,rss,%cpu -p <pid>` and Activity Monitor within ~10%.

## Phase 7 (R2): show RAM/CPU in the big view and a Settings "Processes" page

- Change: columns/chips for RAM and CPU per session with a total in the footer; sortable by memory; Settings gets a "Processes" page listing every agent process (including idle sessions and orphaned children) with RAM, for people who do not open the big view.
- Files: `ui/manager.js`, `ui/app.js` (`settingsRender`, `setPage`), `NotchController.swift` (settings state), `docs/behavior/settings.md`; note the panel height budget in AGENTS.md.
- Verify: `./scripts/run.sh --show` on the Mac, open Settings, Processes; compare totals with Activity Monitor; check the page fits the 440 pt panel.

## Phase 8 (R2): safe close and kill

- Change: `ProcessKiller` in `Sources/Perch`: confirm in the UI (shows the tree, "frees about N MB"), then send SIGTERM to the agent pid (and its process group) and wait 3 s; if still alive send SIGKILL; report per-process result. Rules: never kill Perch itself, a pid not owned by the user, or pid <= 1; verify `pid` still matches the original start time (`started`) before each signal to avoid pid reuse; "Close" asks politely (SIGHUP/SIGTERM), "Force quit" goes straight to SIGKILL after a second confirm. The held hook for that session is released (`HookServer.release`). Pure decision logic (which pids, ordering) in `PerchCore` for tests.
- Files: new `ProcessKiller.swift`, `PerchCore/KillPlan.swift`, `ui/manager.js`, `ui/app.js`, `NotchController.swift`, `Tests/PerchCoreTests/KillPlanTests.swift`, `docs/behavior/processes.md`.
- Verify: `swift test`; on the Mac spawn a test agent-like process (`bash -c 'trap "" TERM; sleep 600'`) with a child, kill it from the big view and confirm SIGTERM is ignored, SIGKILL lands after the timeout (`ps` shows gone), RAM total drops, and Perch itself keeps running.

## Phase 9 (R3): animation and panel jank

- Change: stop double-setting values per snapshot (audit `swapText` / `morphText` call sites in `app.js` against the AGENTS.md rule), debounce `size` messages, replace fixed `asyncAfter` constants (0.3 reveal, 0.35 reply menu, 0.8 say) with the `painted`/completion callbacks, and animate the panel by `NSAnimationContext` frame changes instead of a fixed 480x440 when the content is smaller (keeps hover rects accurate).
- Files: `ui/app.js`, `NotchController.swift`, `NotchGeometry.swift`, `Tests/PerchCoreTests/NotchGeometryTests.swift`.
- Verify: on the Mac screen-record (`screencapture -v` or the design page `scripts/record.sh`) opening, replying and closing; compare frame times; `swift test` for geometry.

## Phase 10 (R1/R3 polish): keyboard-first flow

- Change: global shortcut to cycle to the next session needing input and jump straight to its reply (Cmd+Opt+Down/Up while open), number keys to pick a session in the big view, and one-key approve in the big view. Reuse `HotkeyService`/`Shortcut` rules.
- Files: `HotkeyService.swift`, `Preferences.swift`, `Shortcut.swift`, `ui/app.js`, `ui/manager.js`, `docs/behavior/keyboard.md`.
- Verify: on the Mac with two sessions needing input, drive the keys with `osascript` and confirm the reply goes to the intended tty; `swift test` for shortcut conflicts.

## Out of scope for now

Codex or pi approve-from-notch (needs upstream hook support), App Store/notarized distribution and Sparkle feed for the fork (needs own signing identity and appcast), Windows/Linux.
