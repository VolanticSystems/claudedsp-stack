# ClaudeCM Project Specification

This document is the single source of truth for ClaudeCM's behavior. Both the PowerShell and bash implementations conform to this spec exactly. When the spec and an implementation disagree, fix one or the other; never let them drift.

Last revised after the April 2026 cross-project contamination incident, which surfaced a class of `--latest`-based race conditions that ClaudeCM now structurally prevents.

---

## 1. Purpose

ClaudeCM (Claude Context Manager) is a thin wrapper around the `claude` CLI that solves problems Anthropic's tool does not:

- Sessions identified by GUID are unmemorable and visually indistinguishable across windows. ClaudeCM gives every session a human-readable name that follows it through the terminal tab title, the Claude mobile app, and the session list.
- Resuming a session by GUID is impractical. ClaudeCM stores a numbered list and resumes by number.
- Claude Code auto-deletes session transcripts after 30 days by default. ClaudeCM disables this on first launch and provides a fallback recovery flow when transcripts have already been lost.
- Claude Code's internal `sessions-index.json` is undocumented and frequently broken. ClaudeCM keeps it in sync so the built-in `/resume` picker still works.
- Multiple JSONL files for the same project directory cause silent confusion. ClaudeCM detects them on every operation and offers to quarantine.
- CMV's `--latest` selector is unsafe in the presence of concurrent Claude sessions: it selects globally across all projects, not within the current project. ClaudeCM never uses `--latest` and instead always identifies a specific session by GUID.
- ClaudeCM never infers "the session" from filesystem heuristics that span multiple projects. All session resolution is project-key-scoped.

ClaudeCM is intentionally a thin wrapper. It does not replace, fork, or modify Claude Code. Anything that touches the running session itself (memory, hooks, MCP servers) is Claude Code's responsibility.

---

## 2. External dependencies

| Tool | Purpose | Required? |
|---|---|---|
| `claude` | The Claude Code CLI being wrapped | Required |
| `cmv` | Snapshots, trim, benchmark for token counts | Required for snapshot/trim/refresh; ClaudeCM degrades gracefully if missing |
| `node` | JSON parsing in helpers; runs `extract-skeleton.mjs` during refresh | Required for refresh and `Sync-SessionIndex` |
| Editor (`$EDITOR`, default `notepad` on Windows / `nano` on Linux) | Editing the refresh prompt | Optional |

Default executable paths (the implementation should detect on PATH first):

- `claude`: `~/.local/bin/claude` (Windows: `claude.exe`)
- `cmv`: Windows uses `~/AppData/Roaming/npm/cmv.cmd`; Linux uses `~/.npm-global/bin/cmv`

---

## 3. Storage layout

All ClaudeCM state lives under `~/.claudecm/`:

```
~/.claudecm/
  sessions.txt              # Session registry (Section 5)
  sessions.txt.lock         # Lock file for atomic writes (Section 5.1)
  sessions.txt.tmp          # Transient; only present during atomic write
  machine-name.txt          # Single-line machine identifier for display names
  backup/                   # Backups of sessions.txt and settings.json (timestamped)
  refresh-temp/             # Per-operation scratch dirs for skeleton extraction
    <yyyyMMdd-HHmmss>-<guid>/
```

ClaudeCM also reads (and selectively writes) Claude Code's own state:

```
~/.claude/settings.json                     # Read on startup; cleanupPeriodDays may be set
~/.claude/sessions/<pid>.json               # Per-running-process session manifest. Read-only for ClaudeCM.
~/.claude/projects/<project-key>/           # Per-project Claude Code state
  <GUID>.jsonl                              # Conversation transcript (Claude owns)
  <GUID>/                                   # Subagent state (Claude owns)
  memory/                                   # Memory files (Claude owns)
  sessions-index.json                       # Picker index (ClaudeCM keeps in sync)
```

Other directories ClaudeCM creates or uses:

- `~/documents/github/claude-conversation-backup/<project-leaf>/` (Windows) or `~/claude-conversation-backup/<project-leaf>/` (Linux): destination for orphan quarantine and explicit user-initiated quarantine.
- `<project-dir>/recovery-prompt.md`: recovery primer file written into the user's project. Rotated to `.old`, `.old2`, etc. on regeneration.

---

## 4. Bootstrap (runs on every invocation, in order)

1. Set environment variable `CLAUDE_CODE_REMOTE_SEND_KEEPALIVES=1` for the duration of this process. Partial mitigation for a known Claude Code idle-timeout bug. Silent; not advertised.
2. Create `~/.claudecm/` and `~/.claudecm/backup/` if missing.
3. Touch `~/.claudecm/sessions.txt` so subsequent reads do not fail.
4. **Ensure cleanup period days.** Read `~/.claude/settings.json`. If file or parse fails, skip silently. If `cleanupPeriodDays` is unset, missing, or less than 1000:
   - Back up settings.json to `~/.claudecm/backup/settings.json.<yyyyMMdd-HHmmss>`.
   - Set `cleanupPeriodDays` to `100000` (preserves transcripts ~274 years; do **not** use 0, which disables persistence entirely).
   - Write the file back, pretty-printed JSON.
   - Print a single cyan-colored line: `  Protected session transcripts from Claude Code's 30-day auto-delete.`
   - Failures must be silent. Never block ClaudeCM on settings issues.
5. **Machine name bootstrap.** If `~/.claudecm/machine-name.txt` does not exist:
   - Print blank line.
   - Prompt: `  Machine name for remote display (e.g. desktop, laptop): `
   - If empty, fall back to the machine's hostname (lowercased).
   - Write the value to the file. Print: `  Saved: <name>`
   - Read the value back. If empty, fall back to hostname.

---

## 5. The sessions.txt format

Plain text, line-based, pipe-delimited, one session per line:

```
<GUID>|<DIR>|<DESC>|<TOKENS>
```

| Field | Meaning |
|---|---|
| GUID | Claude Code's session ID. Matches `<GUID>.jsonl` under `~/.claude/projects/<project-key>/`. |
| DIR | The project directory the session belongs to (the `cwd` at launch). Native OS format. |
| DESC | Human-readable session name chosen by the user. Used in display name `<machine> - <DESC>`, in menus, in remote/mobile UI. |
| TOKENS | Last captured `preTrimTokens` value from `cmv benchmark -s <guid> --json`. Empty if the session has never exited cleanly through ClaudeCM. **Empty does not mean the session has no tokens; it means we never measured.** |

Order in the file is order in the menu. Top of file = `#1`.

A literal line `[archived]` separates main sessions from archived ones. Sessions below the marker are hidden from the main list, accessible via the `V` command in list mode.

DESC may end with `(old)` or `(old N)` to mark a prior session after a refresh (Section 11.14).

Empty lines are ignored on read.

### 5.0 Auto-backup on every launch

Every ClaudeCM invocation, after bootstrap, copies `sessions.txt` to `~/.claudecm/backup/sessions.txt.<yyyyMMdd-HHmmss>`. Old backups beyond the most recent 20 are pruned. Best-effort and silent. Reason: any operation that mutates the registry is one bad code path away from data loss; a rolling backup makes recovery trivial.

### 5.1 Concurrency: locking and atomic writes

`sessions.txt` is shared across all running ClaudeCM operations on the same machine. Every operation that modifies it must:

1. **Acquire** an exclusive file lock at `~/.claudecm/sessions.txt.lock` before reading. Retry up to 10 seconds (200 ms intervals). On timeout, print a warning and proceed without the lock.
2. **Read** the current state (so you don't blindly overwrite changes another operation made between your last read and your write).
3. **Write atomically**: serialize the new content to `~/.claudecm/sessions.txt.tmp`, then rename (move) it over `~/.claudecm/sessions.txt`. Rename is atomic on NTFS and POSIX. This protects against partial-write corruption from a killed process.
4. **Release** the lock (close and dispose the file handle).

Reads alone do not need the lock; partial reads return whatever is on disk at that instant. Read-modify-write operations must hold the lock through the entire sequence.

---

## 6. Project key encoding

Convert any directory path to Claude Code's project-key format. Rule: replace **every** non-alphanumeric character with `-`.

Examples:
- `C:\Users\Bob\documents\github\claudecm-stack` → `C--Users-Bob-documents-github-claudecm-stack`
- `C:\Users\Bob\Documents\NinjaTrader 8` → `C--Users-Bob-Documents-NinjaTrader-8`
- `C:\Users\Bob\Documents\GitHub\WPF-Connector.Claude` → `C--Users-Bob-Documents-GitHub-WPF-Connector-Claude`
- `/home/user/projects/foo` → `-home-user-projects-foo`

The project key is used as the directory name under `~/.claude/projects/`.

**Critical:** every path-to-key conversion in the script MUST go through one canonical helper (`Get-ProjectKey` / `get_proj_key`). Inline regex variations that handle only a subset of separators (`:`, `\`, ` `) are bugs because they miss `.`, `/`, `_` and others, producing keys that don't match disk.

---

## 7. Display formatting helpers

### Format-Tokens (numeric value → string)
- `""` or unset → `--`
- `>= 1,000,000` → `1.2M tok` (one decimal)
- `>= 1,000` → `155K tok` (no decimals)
- otherwise → `<n> tok`

### Format-Size (bytes → string)
- `>= 1 MB` → `1.5 MB`
- `>= 1 KB` → `512 KB`
- otherwise → `<n> B`

### Format-DateShort (datetime → string)
- If year < current year → `Mar 13, 2026`
- Else → `Mar 13`

---

## 8. Get-SessionInfo

Inputs: `guid`, `dir`, `tokens`. Returns: `Size`, `Date`, `Tokens`, `Status`.

Compute project key. JSONL path is `~/.claude/projects/<key>/<guid>.jsonl`.

Always compute `tokens_str` via Format-Tokens.

If JSONL exists:
- size = Format-Size of file size
- date = Format-DateShort of LastWriteTime
- status = `ok`

If JSONL is missing, walk fallback chain for date in this order, taking the first that exists:
1. mtime of `~/.claude/projects/<key>/<guid>/` (the subagent subdirectory)
2. mtime of `~/.claude/projects/<key>/memory/`
3. `created` field in `~/.claude/projects/<key>/sessions-index.json` for this GUID

If a fallback was found, format via Format-DateShort and append `*` to mark it as a fallback. If no fallback, date string is `--`.

Return:
- size = `(missing)`
- date = (the fallback string or `--`)
- tokens = (whatever Format-Tokens produced; the historical token snapshot is still meaningful even if the file is gone)
- status = `missing`

---

## 9. Show-List

Header: blank line, then `  === Saved Sessions ===`, then blank line.

For each session, in file order:
- Get session info via Section 8.
- Number column wide enough for total count; description padded to longest description in list (min 10).
- Right-pad number with `.` and trailing space.
- Right-pad description.
- Left-pad size to width 9.
- Left-pad tokens to width 10.
- Date and path are not padded.
- Format: `  <num> <desc> <size>  <tokens>   <date>\t<path>`
- The `highlight` argument is the 1-based row to highlight, or `0` for none. When `highlight == i+1` for a row, prefix with `*** ` and suffix with ` [Selected] ***`, render in yellow.

Footer:
- Blank line.
- `  E. Edit this list`
- If archived count > 0, `  V. View archived (<count>)`
- `  M. Machine name (<machine_name>)`

---

## 10. Sync-SessionIndex

Inputs: `project_dir`. Best-effort, always wrap in try/catch. Never block ClaudeCM operations on sync failure.

1. Compute project key. Path = `~/.claude/projects/<key>/`. If missing, return.
2. Find UUID-named JSONL files (regex `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` on basename without extension). If none, return.
3. Read existing `sessions-index.json` if present. Capture `entries` and `originalPath`. On parse fail, treat as empty entries.
4. Default `originalPath` is the input project directory in **native OS format**. Do NOT convert separators; native is correct on Windows and Linux.
5. Build a lookup of disk GUIDs (basename → file info).
6. Filter existing entries: keep only those whose sessionId is on disk. For kept entries, refresh `fileMtime` and `modified` from actual file mtime.
7. For each disk GUID not represented in the kept entries, build a new entry:
   ```json
   {
     "sessionId": "<guid>",
     "fullPath": "<full path to JSONL, native separators>",
     "fileMtime": <ms since epoch>,
     "firstPrompt": "<sessions.txt DESC if registered, else ''>",
     "messageCount": 0,
     "created": "<ISO 8601 UTC, from file CreationTimeUtc>",
     "modified": "<ISO 8601 UTC, from file LastWriteTimeUtc>",
     "gitBranch": "",
     "projectPath": "<sessions.txt DIR if registered, else originalPath>",
     "isSidechain": false
   }
   ```
8. Combine kept + new entries.
9. Write the index file with structure `{ "version": 1, "entries": [...], "originalPath": "..." }`. Pretty-printed JSON, UTF-8.

---

## 11. Top-level command dispatch

The function takes positional arguments via `$args` / `$@`.

### 11.1 List mode

Triggered when first arg is `l`, `L`, `-l`, or `-L`.

Loop:
1. Read sessions. If empty, print `  No saved sessions.` and return.
2. Show-List (no highlight).
3. Print blank line.
4. Prompt: `  Pick a session (Enter to quit): `
5. Empty input → return.
6. `e` or `E` → Do-EditList; loop.
7. `v` or `V` → Do-ViewArchived; loop.
8. `m` or `M`:
   - Print current machine name.
   - Prompt: `  New name (Enter to keep): `
   - If non-empty, write to file, update in-memory variable, print confirmation.
   - Loop.
9. Numeric → Do-Resume; return.
10. Anything else → treat as new project title (Section 11.8).

### 11.2 Direct resume by number

Triggered when first arg matches `^\d+$` (and is not list mode).

1. Read sessions. If empty, print `  No saved sessions.` and return.
2. Show-List with highlight = the number.
3. Do-Resume with that number.

### 11.3 Argument parsing for normal mode

Walk `$args`:
- `--proj <dir>` consumes two args, sets `projDir`.
- Anything else accumulates into `passArgs[]` (passed through to `claude` on launch).

### 11.4 Normal mode

1. Save original location.
2. If `projDir` was specified: validate it exists, then `cd` into it.
3. Read sessions. Find one whose `Dir` exactly matches current directory.
4. **If a match exists and `passArgs` is empty:**
   - Run Do-OrphanScan. If it returns `select`, launch the picked GUID via Invoke-ClaudeLaunch, then run Do-PostExit on the resolved SessionId.
   - Print `  Session found: <DESC>`.
   - Prompt: `  Rename? (Enter to keep): `. If non-empty, update DESC and save.
   - Prompt: `  Resume this session? [Y/n]: `. If `n`, fall through to fresh launch.
   - If yes:
     - If session's Dir doesn't exist, error and return.
     - `cd` to session's Dir.
     - Run Resolve-ResumeOrRecover.
     - Branch on action: `cancel` returns; `fresh` (after dropping the dead entry from sessions.txt) launches `claude` without `--resume`; `primed` launches `claude --resume <new-guid>`; otherwise `claude --resume <original-guid>`.
     - All launches go through Invoke-ClaudeLaunch (Section 11.6).
     - On exit code 0, run Do-PostExit with the resolved SessionId.
     - On non-zero exit, prompt to delete the entry.
5. **If no match and `passArgs` is empty:**
   - Print `  No session entry found for this directory.`
   - Folder default = leaf of cwd, dashes → spaces, title-cased.
   - Prompt: `  Create a name for this session (Enter for '<default>', 'skip' to skip): `
   - `skip` → preNamed = null. Empty → preNamed = default. Otherwise → preNamed = input.
6. **Fresh launch (any branch that fell through):**
   - Display name = `<machine> - <preNamed or match.Desc or cwd leaf>`
   - Build args: `--dangerously-skip-permissions -n <displayName> [<passArgs>...]`
   - Launch via Invoke-ClaudeLaunch.
   - On non-zero exit, restore directory and return.
   - **If preNamed was set and SessionId resolved:** register new entry at top of sessions.txt with empty tokens; run Do-PostExit with that SessionId.
   - **Otherwise** run Do-PostExit with the resolved SessionId.

### 11.5 Do-OrphanScan

Inputs: `scan_dir`, `registered_guid`. Returns either `{ Action='select', Guid=<guid> }` or null.

1. Combine main + archived sessions for the registered-set check.
2. List `*.jsonl` in `~/.claude/projects/<key>/`, sorted by mtime descending.
3. If 1 or fewer files, return null.
4. Determine if any file is an actual problem: not in the registered set, OR in the set but with a different `Dir` than `scan_dir`. If no problems, return null.
5. Print yellow "Multiple conversation files found (<n>):" header and a numbered table with mtime, padded size, name (DESC if registered, `(orphan)` if not, suffix ` (wrong directory)` if dir mismatch), and ` *` suffix if GUID matches `registered_guid`.
6. Print legend and `  Actions: [number] to select, [q number] to quarantine to backup, [Enter] to continue with registered session`.
7. Parse:
   - `^\d+$` → return `{ Action='select', Guid=<basename of that JSONL> }`.
   - `^[qQ]\s*(\d+)$` → quarantine: refuse if the GUID matches `registered_guid`. Otherwise move JSONL and (if present) the GUID subdirectory to `<backup-root>/<scan_dir leaf>/`. Run Sync-SessionIndex. Print `  Quarantined to backup: <leaf>/<guid>` in green.
8. Return null in all other cases.

### 11.6 Invoke-ClaudeLaunch (the only sanctioned launch path)

This is the **only** function that may invoke `claude` interactively. Direct `& claude ...` or `claude ...` calls outside this function are forbidden, because they cannot capture the resulting session ID safely.

Inputs: `ClaudeArgs[]`, `SessionDir`. Returns: `{ Pid; SessionId; ExitCode }`.

#### Belt-and-suspenders session ID resolution

Three layers, in this order:

**Layer 1 (preferred where available): PID + manifest.**
- Launch claude as a child process and capture the PID. After up to 5 seconds (poll every 250 ms), read `~/.claude/sessions/<pid>.json`. Extract `sessionId`. This is **ground truth** because it's claude.exe's own self-reported session ID.
- **Bash:** launches with `& ... ; pid=$!`, fully working.
- **PowerShell:** Layer 1 is currently **disabled**. The natural way to capture a child PID is `Start-Process -PassThru`, but its `-ArgumentList` parameter mangles string arguments containing spaces (e.g. display names like `stang - Brooks Scrape` become two separate args). Until we have a launch mechanism that both preserves TTY and captures PID without arg mangling, PowerShell relies on Layers 2 and 3 alone. A future enhancement could use `Start-Job` to monitor `Get-Process claude` while `& $claudeExe` runs synchronously.

**Layer 2: project-scoped JSONL snapshot diff.**
- Before launch, snapshot the set of UUID-named JSONL basenames in the current project key directory.
- After launch, snapshot again. The new GUID is in the difference.
- If multiple new GUIDs appear (rare), pick the most recently modified.

**Layer 3 (fallback): newest in current project key.**
- If both layers above fail, fall back to whatever JSONL has the most recent mtime in the current project key directory. Never scan across project keys.

#### Cross-check

If Layer 1 and Layer 2 disagree, print a yellow warning showing both values and prefer Layer 1 (the manifest). This disagreement signals a CMV or Claude Code bug writing files cross-project, and the user should know.

If only one layer produced a value, use it. If none did, return SessionId = null (caller may fall back to Layer 3 inference inside Do-PostExit).

#### Exit handling

Wait for the child to exit. Capture exit code. Return all three values.

### 11.7 Resolve-ResumeOrRecover (recovery primer flow)

Inputs: `guid`, `dir`, `desc`, `tokens`. Returns: `{ Action='normal'|'fresh'|'primed'|'cancel', Guid=<guid or null> }`.

1. Compute project key. Check JSONL existence at `~/.claude/projects/<key>/<guid>.jsonl`.
2. If JSONL exists, return `{ Action='normal', Guid=guid }`.
3. JSONL missing. Print yellow header explaining the transcript was lost (likely the 30-day auto-cleanup) and that memory + subagent state are intact. Then offer three options:
   - 1. Start a fresh Claude session in that directory
   - 2. Create a recovery-prompt.md file in the project directory, that you can prompt Claude to read and execute, with optional edits.
   - 3. Cancel
4. Parse choice:
   - `1` → `{ Action='fresh', Guid=null }`
   - `3` (or anything not `1`/`2`) → `{ Action='cancel', Guid=null }`
   - `2` → recovery prompt generation:
     a. If `dir` doesn't exist, error and return cancel.
     b. **Rotate existing recovery prompt files.** If `<dir>/recovery-prompt.md` exists, find existing `recovery-prompt.md.old*` files, determine highest N suffix, then rename in descending order so each gets bumped: `.old<N>` → `.old<N+1>`, `.old` → `.old<max+1>`. Then `recovery-prompt.md` → `recovery-prompt.md.old`.
     c. Print `  Generating recovery prompt (this may take a minute)...` in cyan.
     d. Build the meta-prompt (Section 11.7.1).
     e. Save current location, `cd` into `dir`.
     f. Write meta-prompt to a temp file. Run `claude -p --output-format json --dangerously-skip-permissions` with the meta-prompt on stdin. Capture stdout. Delete temp file. Parse JSON. Extract `result` and `session_id`.
     g. **Cleanup the throwaway -p session immediately.** The `-p` call created a real JSONL at `~/.claude/projects/<key>/<session_id>.jsonl`. Delete it AND any matching `<session_id>/` subdirectory. Run Sync-SessionIndex on the project. This is critical; without cleanup, every recovery generation leaves an orphan.
     h. If `result` is empty/missing, print `  Recovery prompt generation failed.` in red and return cancel.
     i. Write `result` to `<dir>/recovery-prompt.md` (UTF-8).
     j. Print success message in green and `  Edit it if you want, or just tell Claude to use it as the first message of the conversation.` in default + `  Opening a fresh Claude session in that directory now...` in cyan.
     k. Restore location.
     l. Return `{ Action='fresh', Guid=null }`.

#### 11.7.1 Build-RecoveryMetaPrompt

Inputs: `dir`, `desc`, `tokens`, `lastDate` (string).

Computed values:
- `proj_key`, `proj_dir = ~/.claude/projects/<proj_key>`
- `memory_dir = <proj_dir>/memory`
- `subagents_dir = <proj_dir>/<guid>/subagents`
- `memory_list`: bullet list of `*.md` files in memory_dir using `*` prefix (NOT `-`; Claude Code's input parser treats lines starting with `-` as CLI flags). Format: `  * <name> (<KB> KB, modified <YYYY-MM-DD>)`. If none, `  (none)`.
- `subagent_count`: count of `*.jsonl` files in subagents_dir.
- `subagent_latest`: most recent mtime in subagents_dir, formatted `YYYY-MM-DD`. If none, `unknown`.
- `tok_str`: `<tokens> tokens` if tokens, else `unknown token count`.
- `date_str`: `lastDate` if set, else `unknown`.

Template (verbatim, with substitutions):

```
You are helping the user rebuild a lost Claude Code session. The conversation transcript was deleted by Claude Code's 30-day auto-cleanup. Surviving artifacts: memory files, subagent transcripts, and the project code itself.

Your task is to write a recovery prompt. It will be saved to recovery-prompt.md in the project directory. The user will edit it if they want, then start a fresh Claude Code session and tell that new Claude instance to read recovery-prompt.md and follow it. Your output is only that prompt text, ready to be saved as a file.

Project context:
  Session name: <desc>
  Project path: <dir>
  Last activity: <date_str>
  Conversation size when lost: <tok_str>

Surviving memory files in <memory_dir>:
<memory_list>

Surviving subagent transcripts: <subagent_count> files in <subagents_dir>, most recent dated <subagent_latest>.

Read the surviving memory files. Look at 2-3 of the most recently modified subagent transcripts. Look at the current state of the project directory. From this, write the recovery prompt.

The recovery prompt you write must:

* Open by telling future-Claude what happened: the transcript is gone, these specific artifacts survived, this is a recovery orientation session.
* List the specific memory files worth reading, with one-line notes on what each contains.
* List the specific subagent transcripts worth skimming, with one-line notes on what work they represent.
* Note any in-flight work, open questions, or decisions visible from the surviving artifacts.
* End with this exact instruction, verbatim: "Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming."

Output only the recovery prompt itself, as plain prose. No preamble, no commentary, no markdown formatting. CRITICAL: do not start any line with the character '-'. Use '*' or numeric prefixes for any lists. Lines starting with '-' are interpreted as CLI flags by Claude Code's input parser and will break the recovery flow.
```

### 11.8 New project from list mode

If user types non-numeric, non-special input at the list mode prompt, treat it as a new project title:

1. Sanitize directory name: lowercase, spaces → `-`, strip non-alphanumeric/underscore/dash chars.
2. Choose a unique directory under cwd: `<safe_name>`, `<safe_name>(1)`, ...
3. Create the directory.
4. Print: blank line, `  Starting new session: <title>`, `  Project dir: <newProjDir>`.
5. `cd` into it.
6. Display name = `<machine> - <title>`.
7. Launch via Invoke-ClaudeLaunch.
8. After exit, if SessionId was resolved, register at top of sessions.txt with empty tokens, dir = newProjDir, desc = title.
9. Restore original directory.

### 11.9 Do-Resume

Inputs: `pick`, `sessions`.

1. Range-check pick. If `sel.Dir` doesn't exist, error and return.
2. Save original location, `cd` to `sel.Dir`.
3. Run Do-OrphanScan. If user selected an orphan to resume:
   - Display name = `<machine> - <sel.Desc>`
   - Launch via Invoke-ClaudeLaunch with `--resume <orphan-guid>`.
   - On exit code 0, Do-PostExit with the resolved SessionId (preferring Layer 1, falling back to the orphan-guid we asked for).
   - Restore directory, return.
4. Run Resolve-ResumeOrRecover:
   - cancel → restore, return
   - fresh → drop the dead entry from sessions.txt, launch via Invoke-ClaudeLaunch (no `--resume`), Do-PostExit with the resolved SessionId
   - primed → launch via Invoke-ClaudeLaunch with `--resume <recover.Guid>`, Do-PostExit with resolved SessionId (preferring Layer 1)
   - normal → launch via Invoke-ClaudeLaunch with `--resume <sel.Guid>`, Do-PostExit with resolved SessionId (preferring Layer 1)
5. If the normal-resume launch exits non-zero (session not found):
   - Prompt: `  Session not found. Delete this entry? [Y/n]: ` (default Y)
   - If not `n`, remove the entry from sessions.txt.
6. Restore directory.

**Critical:** the recovery `fresh` branch must NOT delete the old sessions.txt entry before launching. If the launch fails (Claude crashes, arg passing breaks, anything), the entry would be gone with no JSONL to fall back to. Instead, launch first; if the launch succeeds and produces a new SessionId, swap the old GUID for the new one in place (preserving desc and dir, resetting tokens). If the launch fails, the entry stays put and the user can retry.

### 11.10 Do-EditList

Loop:
1. Read sessions.
2. Print `  === Edit Sessions ===` and a numbered list of `  <n>. <desc>  [<dir>]`.
3. Print menu line: `  R# = Rename   P# = Path   A# = Archive   D# = Delete   M#,# = Move   Q = Done`.
4. Prompt `  >: `.
5. Empty/`q`/`Q` → return.
6. `^[rR](\d+)$` → rename: validate index, prompt for new name, if non-empty update DESC and save.
7. `^[pP](\d+)$` → change path:
   - Print current path. Prompt for new path.
   - If non-empty: validate it exists, compute old key and new key (BOTH via the canonical `Get-ProjectKey` helper, never inline regex), copy old JSONL to new project dir if it exists, update DIR, save, run Sync-SessionIndex on both old and new project dirs.
8. `^[aA](\d+)$` → archive: remove from main, append to archived, print `  Archived: <desc>` in green.
9. `^[dD](\d+)$` → delete (destructive):
   - Print red warning lines.
   - Prompt: `  Type 'delete' to confirm: ` (case-insensitive).
   - If confirmed: run Do-DeleteSession, remove from sessions list, save, print `  Deleted: <desc>` in green.
   - Otherwise: `  Cancelled.`
10. `^[mM](\d+),(\d+)$` → move: validate both indices, move list[from] to position `to`, save.
11. Anything else → `  Unknown command.`

### 11.11 Do-ViewArchived

Loop:
1. Read archived sessions. If empty, print `  No archived sessions.` and return.
2. Print `  === Archived Sessions ===` and a numbered list with size: `  <n>. <desc>  [<dir>]  <size>`.
3. Print menu line: `  U# = Unarchive   D# = Delete permanently   Q = Back`.
4. Prompt `  >: `.
5. Empty/`q`/`Q` → return.
6. `^[uU](\d+)$` → unarchive: remove from archived, prepend to main. Print `  Unarchived: <desc>` in green.
7. `^[dD](\d+)$` → destructive delete (same confirmation flow as edit list).
8. Anything else → `  Unknown command.`

### 11.12 Do-DeleteSession (helper)

Inputs: `guid`, `dir`.

Compute project key. Path to JSONL = `~/.claude/projects/<key>/<guid>.jsonl`. Path to subagent dir = `~/.claude/projects/<key>/<guid>/`.

- If JSONL exists, delete it.
- If subagent dir exists, delete it recursively.
- Run Sync-SessionIndex on `dir`.

Does NOT touch `sessions.txt`. Caller is responsible for removing the entry.

### 11.13 Do-Trim

1. If `cmv` not found, print `  cmv not found. Skipping trim.` and return.
2. **Pre-trim cleanup.** Find the entry for `currentGuid` in sessions.txt, compute its project key. In that project key's directory, scan for `*.cmv-trim-tmp` files older than 5 minutes. Delete each, print `  Cleaned stale CMV temp file: <name>` in dark gray.
3. Print `  Trimming session...` Record `trimStartedAt = now`.
4. **Run with explicit session ID, never --latest:** `cmv trim -s <currentGuid> --skip-launch`. Capture output.
5. Search output for `Session ID: <guid>` pattern. If not found, print `  Trim failed or no new session ID found.`, dump first 5 lines, return.
6. New GUID found. Update sessions.txt: replace the old GUID with the new one (preserving DIR, DESC, TOKENS).
7. Look up the entry by new GUID. Compute expected JSONL path under its project key.
8. **If file isn't there but exists in another project key, FAIL LOUDLY.** Print red error showing expected vs actual path. Tell the user to investigate. **Do NOT silently copy across project directories.** This was the source of the April 2026 cross-project contamination.
9. Print remaining output lines (first 10, excluding Session ID line).
10. **Post-trim cleanup.** Scan for `*.cmv-trim-tmp` files in the project key dir whose mtime >= `trimStartedAt`. Delete each (CMV failed to clean up after itself), print `  CMV left a temp file behind: <name>; removing.` in dark gray.
11. Print `  Session trimmed. New ID: <new-guid>`.
12. Set `script:trimNewGuid = <new-guid>` so the caller can use it.

### 11.14 Do-Refresh

Deeper compaction. Starts a new session, carries forward a structured skeleton + filtered transcript instead of the full old conversation.

1. Look up current session by GUID. Use its DESC (default `Unnamed`) and DIR (default current location).
2. Prompt: `  Name for new session (Enter for '<curDesc>'): `. Default to curDesc.
3. **Per-operation temp dir.** Create `~/.claudecm/refresh-temp/<yyyyMMdd-HHmmss>-<currentGuid>/`. Before creating, scan `refresh-temp/` for any subdirs older than 24 hours and remove them (best-effort).
4. **Skeleton extraction:**
   - Compute project key, project dir, old JSONL path.
   - Locate `extract-skeleton.mjs`: try (in order) `<script-dir>/extract-skeleton.mjs`, `$CLAUDECM_HOME/extract-skeleton.mjs`, `~/.claudecm/extract-skeleton.mjs`, `~/.local/share/claudecm/extract-skeleton.mjs`. **Never hardcode a personal path.**
   - If old JSONL and extract script both exist and `node` is available:
     - Run `node extract-skeleton.mjs <old-jsonl> <cur-desc> <refresh-temp-dir>`.
     - Read `<refresh-temp-dir>/<old-guid>-skeleton.md` if present.
     - Read `<refresh-temp-dir>/<old-guid>-transcript.md` if present.
   - Otherwise print warnings about what's missing.
5. **Build the refresh prompt.** Multi-section template:

```
Read your memories. This is a fresh session replacing a long previous conversation
on this project. Everything you need to know is in:

1) Your memory files (MEMORY.md and all linked files)
2) Any documentation in the project directory
3) The codebase itself (git log for history)
4) project_current_state.md in your memory if it exists
```

If skeleton/transcript present, append:

```
5) The structured extraction below, produced by mechanical analysis of the
   conversation log
```

If transcript present, append:

```
6) A filtered transcript of the previous session (conversation text and tool call
   summaries, no tool output) at:
   <transcriptPath>
   Read this file and identify any key decisions, user corrections, or reasoning
   that the skeleton below does not capture.
```

Then unconditionally append:

```

IMPORTANT:
- The files listed below reflect the state at the end of the previous session.
  Re-read any file before modifying it, as it may have changed since then.
- The errors listed may or may not still be relevant. Verify before acting on them.
- Do not start any development until the user tells you to.
- Tell the user what you understand about the current state of the project,
  what works, what is pending, and what your behavioral rules are.
```

If skeleton present, append:

```


--- ADD YOUR NOTES HERE (context, decisions, corrections, anything the skeleton missed) ---



--- SKELETON START (review and edit as needed) ---

<skeletonContent>

--- SKELETON END ---
```

6. Write to `<cmDir>/refresh-prompt.tmp`.
7. Prompt: `  Edit the compaction prompt and skeleton? (Save and close when done) [y/N]: `. If `y`, open in editor (notepad on Windows, $EDITOR/nano on Linux), wait for editor to close.
8. Read the (possibly edited) prompt, delete temp file.
9. `cd` to session directory.
10. Print `  Creating fresh session, please wait...`
11. Run `claude --dangerously-skip-permissions -p <prompt-text>`. Discard output. (This is the one place where `claude -p` is invoked outside Invoke-ClaudeLaunch; it's headless and one-shot.)
12. Print `  Done.`
13. Restore directory.
14. Find the new session GUID: newest JSONL under project key directory whose basename ≠ old GUID. If none, print warning and return.
15. Build new sessions list:
    - Identify the old entry. Compute new DESC: append ` (old)` if not already old, or bump `(old N)` → `(old N+1)`.
    - All other sessions stay in place (relative order).
    - Get token count for new session: `cmv benchmark -s <freshGuid> --json`, parse `preTrimTokens`. Never `--latest`.
    - Build new entry: `{Guid=<new>, Dir=<curDir>, Desc=<newName>, Tokens=<tokens>}`.
    - Final list: `[new entry] + [other sessions in original order] + [old entry]`.
16. Print `  Fresh session created: <newName>` and `  Old session moved to bottom of list.`
17. Best-effort cleanup: remove `<refresh-temp-dir>` recursively.

### 11.15 Do-PostExit

Runs after every interactive Claude session that exited cleanly. Argument: `knownGuid` (optional but strongly recommended; the new launch helper always provides it).

1. Print blank line, `  Session ended.`, blank line.
2. **Resolve GUID.** If `knownGuid` provided, use it. Otherwise scan **only** the current project key directory for the most recently modified non-`agent-*` JSONL. Never scan across project keys. If none found, return.
3. **Auto-snapshot via CMV (using -s <guid>, never --latest).** Snapshot label = `auto-exit-<yyyyMMdd-HHmmss>`. Run `cmv snapshot <label> -s <guid>` in a background job with a spinner: `  - Saving snapshot...` rotating `- \ | /`. When done, replace with `  Done.`
4. Look up entry in sessions.txt by GUID.
5. **If found:**
   - Update tokens via `cmv benchmark -s <guid> --json`, parse `preTrimTokens`.
   - Move entry to top of sessions list. Save.
6. **If not found:**
   - Compute folder default (leaf of cwd, dashes → spaces, title-cased).
   - Prompt: `  Describe this session (Enter for '<default>', 'skip' to skip): `
   - `skip` → return without registering.
   - Otherwise register at top of sessions.txt with empty tokens.
7. Sync-SessionIndex on the entry's Dir.
8. Show session size: `  Current session: <size> (<tokens>)`.
9. Prompt: `  Trim this session? [y/N]: `. If `y`, run Do-Trim. If trim returned a new GUID, update local `guid`.
10. Prompt: `  Create a new compacted session, built from a structured rebuild of this one? [y/N]: `. If `y`, run Do-Refresh.

---

## 12. Failure modes and degradation

ClaudeCM must remain usable even when its dependencies are partially broken:

- `cmv` missing → snapshot, trim, refresh, and token backfill skip with a single notice. Other operations continue.
- `node` missing → skeleton extraction during refresh skips with a notice. Sync-SessionIndex on bash skips silently.
- `~/.claude/settings.json` missing or unparseable → cleanupPeriodDays bootstrap skips silently.
- `~/.claude/projects/<key>/` missing → orphan scan returns empty; sync_session_index returns; get_session_info returns missing status.
- Recovery prompt generation failure → falls back to cancel.
- Sync-SessionIndex failure → silent. Never blocks anything.
- Lock acquisition timeout → warning only; proceeds without lock (last-write-wins).
- Layer 1 (manifest read) timeout → silent fallback to Layer 2.
- Layer 2 (snapshot diff) ambiguous → silent fallback to Layer 3.

---

## 13. Display conventions

Two-space leading indent on user-facing output. Empty lines for visual separation. Color used sparingly:

- **Yellow:** warnings, multiple files found, selection highlight, Layer-disagreement notices.
- **Red:** errors, destructive-action warnings, fail-loud cross-project messages.
- **Green:** success confirmations (archived, deleted, quarantined, recovery prompt saved).
- **Cyan:** in-progress notices (generating, protecting transcripts).
- **DarkGray:** low-priority cleanup notices (stale CMV temp files removed).

Default color elsewhere.

---

## 14. Concurrency invariants

ClaudeCM users routinely run multiple sessions in parallel windows. Every operation must hold to these rules:

1. **Never use `cmv --latest`.** It selects globally across projects. Always pass `-s <specific-guid>`.
2. **Never scan `~/.claude/projects/*/` for "newest JSONL".** Always scope to the current project key directory.
3. **Never silently copy JSONLs between project directories.** If CMV writes to the wrong location, fail loudly.
4. **Always resolve session ID via Invoke-ClaudeLaunch's belt-and-suspenders before running cmv operations.** No inference based on file mtimes alone.
5. **All sessions.txt mutations hold the lock and write atomically.**
6. **All scratch directories are per-operation scoped** (refresh-temp).

Violating any of these can corrupt sessions across projects.

---

## 15. Script-scoped state

PowerShell-style script-scoped variables used to communicate between functions:

- `$script:trimNewGuid` — Set by `Do-Trim` after a successful trim. Read by `Do-PostExit` to update its working `$guid` after the user accepts the trim prompt.
- `$script:lastGuid` — Set by `Resolve-ResumeOrRecover` before calling `Build-RecoveryMetaPrompt`, so the meta-prompt builder can locate the session's subagent directory.

The bash port uses regular shell variables for the same purpose (no script scope needed).

---

## 16. What this spec does NOT cover

- The `extract-skeleton.mjs` script. Self-contained tool with its own contract: `(jsonl, desc, out-dir) → writes <guid>-skeleton.md and <guid>-transcript.md`.
- CMV's snapshot/trim/branch/benchmark internals.
- Claude Code's session model, hook system, MCP servers, memory files. ClaudeCM observes and reads, never modifies.
- The Telegram channel integration (evaluated and removed; see `private/get-the-bug-fixed.md` if revisiting).
