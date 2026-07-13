# agent-ram-monitor

**Find out which coding agent is eating your RAM — and kill it without losing the session.**

If you run coding agents all day — Claude Code, Codex CLI, Copilot CLI, several at once, some overnight — you eventually hit the problem this tool was built for: one session quietly balloons to 10 GB. Not because agents are inherently heavy, but because of the long tail underneath them: an MCP server that leaks, a headless Chrome someone forgot to close, a jest run that left 13 half-gigabyte workers behind, an orphaned subprocess whose parent died days ago.

Activity Monitor is useless here. It shows you a wall of anonymous `node` processes and can't answer the questions that matter:

- **Which session is this?** (So I know what work I'd be interrupting.)
- **What inside it is actually fat?** (The agent? An MCP? A test runner?)
- **How do I get the session back after I kill it?**

agent-ram-monitor answers all three, as a CLI and a macOS menu bar app.

```
TOOL    PID    TTY      RAM    CPU%  UP     STATE  HOST  PROJECT   SESSION   TITLE
claude  10153  ttys005  1.66G  7     18m    busy   c11   web-app   38037263  Add search filters to results page
   └─ 1.16G  cmd     npm run lint  [50951]
   └─ 0.10G  mcp     chrome-devtools-mcp  [10212]
claude  7747   ttys002  0.74G  3     19m    shell  c11   api       d387a661  Fix flaky auth integration test
   └─ 0.33G  agent   codex exec  [29634]
      └─ 0.09G  mcp     some-db-mcp  [29949]

kill + resume:
  [1.7G] kill 10153  # then: cd '/Users/you/Projects/web-app' && claude --resume 38037263-…
```

## What it does

**Sessions, not processes.** Every running Claude Code / Codex / Copilot CLI session, with RAM aggregated over its *whole process tree* — subagents, MCP servers, spawned shells and browsers all count toward the session that owns them.

**Kill + resume, precomputed.** Each session is mapped back to its resumable session ID, so the fix for a bloated session is one paste: kill the process, `claude --resume <id>` (or `codex resume` / `copilot --resume`), and the agent picks up where it left off with a fresh memory footprint.

**Subprocess breakdown.** Children are classified (`mcp`, `browser`, nested `agent`, `lsp`, big `cmd`s) with per-subtree RAM, so "is it a bad MCP?" is answered at a glance. Worker pools collapse into one line — `5.2G  13× node …/jest-worker/processChild.js` — with a single kill action that reaps the pool and tells you how much it frees.

**A flight recorder, because blowups happen while you're not looking.** The menu bar app logs every 10-second scan to a ring buffer (`~/.agent-ram-monitor/history.jsonl`, rotating at 20 MB into one backup file — roughly weeks of history in ≤40 MB total). After an incident, `agent-ram-monitor blame` reconstructs it:

```
9217befb  claude · web-app · Investigate slow dashboard query
   ▁▁▂▂▁▁▁▁▁▂▁▁▅▁▆▆▆▇▇█  now 0.42G
   0.34G → 9.36G between Sat 23:10 and 23:11  (+9.01G)
     +9.05G  cmd     npm test
```

**A menu bar app** (native AppKit, single Swift file):

- Status item shows total agent RAM; turns **red when any session crosses 3 GB** (configurable).
- A memory gauge on open: total RAM / in use / the agents' slice as a stacked bar, plus a **Memory by App** fan-out of system-wide usage grouped by app bundle.
- Two-line session rows with live titles, state dots (busy/idle), host app, and RAM sparklines for the last hour.
- Per-session submenu: **Kill & Copy Resume Command (frees ~X G)**, per-subprocess kills, **Bring to Front**.

## Install

Requirements: macOS, Python 3.8+ (stdlib only — no pip installs), Xcode Command Line Tools (to compile the menu bar app).

```bash
git clone https://github.com/MdMxMyr/agent-ram-monitor && cd agent-ram-monitor
./install.sh     # builds the menu bar app, installs a login LaunchAgent, links the CLI
```

`./uninstall.sh` removes the menu bar app, its LaunchAgent, and the CLI symlink (recorded history in `~/.agent-ram-monitor/` is kept). The CLI works standalone without the menu bar app (`./agent-ram-monitor`), but without the app's polling you don't get the flight recorder unless you run `agent-ram-monitor --json --log` from your own cron/loop.

## CLI usage

```
agent-ram-monitor                    # one-shot table
agent-ram-monitor -w [SECS]          # live view (default 3s refresh)
agent-ram-monitor -d                 # show ALL children, not just MCPs/browsers/big ones
agent-ram-monitor --min-gb 2         # only sessions using ≥ 2 GB
agent-ram-monitor --json             # {"sessions": [...], "apps": [...]}
agent-ram-monitor --log              # also record the scan to the history ring buffer
agent-ram-monitor blame [prefix] [--since 4h]   # attribute RAM growth from history
```

Configuration (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_RAM_MONITOR_ALERT_GB` | `3` | Red threshold for the menu bar app |
| `AGENT_RAM_MONITOR_PATH` | repo-relative | CLI path used by the menu bar app |
| `AGENT_RAM_MONITOR_HISTORY` | `~/.agent-ram-monitor/history.jsonl` | Flight-recorder location |

## How it works (the interesting bits)

**PID → resumable session.** Claude Code writes `~/.claude/sessions/<pid>.json` (exact mapping, plus live busy/idle state); older versions fall back to `--session-id` in argv, then to pairing session-file *creation times* against process start times — a greedy 1:1 assignment per project directory, so ten sessions in the same repo each resolve to their own ID instead of "newest file wins". Codex sessions match via the start timestamp embedded in rollout filenames; Copilot via `workspace.yaml`.

**Session titles.** The tab title your terminal shows is emitted as an escape sequence and never persisted by the agent CLIs. For Claude Code sessions hosted in [c11](https://github.com/Stage-11-Agentics/c11) or cmux, agent-ram-monitor reads the multiplexer's continuously-persisted state files to recover the exact live tab title (and user-set custom names). Everything else falls back to the session's first prompt (Copilot keeps a real generated name on disk, which is used directly).

**Attribution across churn.** MCP servers restart, `npm exec` wrappers respawn, worker pids rotate. Both the live breakdown and `blame` group children by *(kind, label)* rather than pid, so a pool that grew from 8 to 13 workers between samples still reads as one line.

**Host detection.** Each session's ancestor chain is walked to the hosting app (c11, cmux, Terminal, iTerm2, Cursor, tmux, …), so you know which window to look for.

**Bring to Front.** Activates the hosting app; for Terminal/iTerm2 it selects the exact tab by tty via AppleScript. For c11, tab-level focus uses the control socket, which by default only answers processes launched inside c11 — pair with c11's socket access settings (a scoped focus-only mode is proposed upstream).

## Caveats

- macOS only (uses `ps`, `lsof`, launchd, and AppKit).
- RAM figures are RSS sums; shared memory means totals can over-count somewhat. Treat them as attribution, not accounting.
- Extension-based browser automation (e.g. Claude's Chrome extension) lives in your existing browser's processes and can't be attributed to a session — only spawned browsers (chrome-devtools-mcp and friends) roll up.
- Session-ID fallbacks are heuristic where noted; IDs read from pid files or argv are exact, time-matched ones are marked `~` in the table.

## License

MIT
