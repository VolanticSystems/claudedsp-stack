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
- `C:\Users\alice\projects\my-app` → `C--Users-alice-projects-my-app`
- `C:\Users\alice\Documents\Some App 8` → `C--Users-alice-Documents-Some-App-8`
- `C:\Users\alice\Documents\GitHub\WPF-Connector.Thing` → `C--Users-alice-Documents-GitHub-WPF-Connector-Thing`
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
   - Run Do-OrphanScan. If it returns `select`, launch the picked GUID via the platform's launch path (Section 11.6), then run Do-PostExit on the resulting SessionId.
   - Print `  Session found: <DESC>`.
   - Prompt: `  Rename? (Enter to keep): `. If non-empty, update DESC and save.
   - Prompt: `  Resume this session? [Y/n]: `. If `n`, fall through to fresh launch.
   - If yes:
     - If session's Dir doesn't exist, error and return.
     - `cd` to session's Dir.
     - Run Resolve-ResumeOrRecover.
     - Branch on action: `cancel` returns; `fresh` (after dropping the dead entry from sessions.txt) launches `claude` without `--resume`; `primed` launches `claude --resume <new-guid>`; otherwise `claude --resume <original-guid>`.
     - All launches go through the platform's launch path (Section 11.6).
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
   - Launch via the platform's launch path (Section 11.6).
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

### 11.6 Launch path

The two implementations launch `claude` differently. Same observable behavior, different mechanisms because the platforms have different constraints. This asymmetry is intentional.

#### PowerShell: direct positional invocation wrapped in two helpers

Each call site uses one of two helpers (Section 11.6.1 for resumes, Section 11.6.2 for fresh launches). Both helpers ultimately call `claude` with direct positional arguments:

```
& $claudeExe --dangerously-skip-permissions [--resume <guid>] -n $displayName [@passArgs]
```

No splatting of an array variable. PowerShell 5.1's native-command argument passing is unreliable when an array containing strings with spaces is splatted via `@var` — Windows process creation flattens argv into a single command-line string and the receiving process re-splits it. Display names like `desktop - My Project` get mangled, with the bare `-` between "desktop" and "My" interpreted by Claude as `--print` mode entry. Direct positional `& $claudeExe ...` lays each argument out inline and PowerShell quotes them correctly.

After a successful launch, the helper infers the new session ID from the project key directory's JSONL state via set-diff snapshot (see 11.6.2). For resume-by-known-GUID launches, the helper starts with the passed GUID and detects forks via set-diff (see 11.6.1).

#### Bash: `invoke_claude_launch` helper with belt-and-suspenders

Bash properly preserves array elements as separate args when quoted with `"${args[@]}"`. So bash safely uses an array-based helper:

```bash
invoke_claude_launch --dir "$session_dir" -- --dangerously-skip-permissions [--resume <guid>] -n "$display_name"
```

Inside the helper:
1. **Layer 2 setup:** snapshot the set of UUID-named JSONL basenames in the project key directory before launch.
2. Launch claude as a child process: `"$CLAUDE_EXE" "${args[@]}" &; pid=$!`. Capture the PID.
3. **Layer 1:** poll `~/.claude/sessions/<pid>.json` for up to 5 seconds (250 ms intervals). Extract `sessionId`. This is ground truth from claude itself.
4. `wait $pid` until claude exits.
5. **Layer 2:** snapshot again. The new GUID is in the diff.
6. Cross-check Layer 1 vs Layer 2. If they disagree, warn yellow.
7. Return `{ pid, session_id, exit_code }`.

**Layer 3 fallback:** if both layers fail, the caller (Do-PostExit) falls back to the most recent JSONL in the current project key directory. Never scans across project keys.

#### Why the asymmetry is OK

Both paths achieve the same goal: launch claude, get back the session ID it ended up using, never confuse it with a session in a different project. The PowerShell path achieves it without a helper because the launch is direct and the project-scoped inference is sufficient. The bash path uses a helper because bash can safely splat arrays AND can capture a child PID for the manifest cross-check, both of which are wins. Forcing one mechanism on both platforms loses something on whichever platform doesn't fit.

#### Linux platform notes

**Root re-exec.** The bash script must re-exec as the `claude` user when run as root. Without this, `$HOME` resolves to `/root/` and all state goes to the wrong location. Add at the top of the script, before any variable initialization:

```bash
if [[ $(id -u) -eq 0 ]]; then
    exec sudo -u claude "$0" "$@"
fi
```

**User prompts: do not use `read -rp`.** Bash's `read -p` sends the prompt string to stderr. When the script runs through `exec sudo -u claude`, stderr may not be connected to the terminal, causing prompts to vanish. The user sees what looks like a hang (the script is waiting for input, but no prompt is visible). Use `printf` to stdout followed by `read -r` instead:

```bash
# Wrong (prompt invisible under sudo re-exec):
read -rp "  Trim this session? [y/N]: " do_trim

# Correct:
printf '  Trim this session? [y/N]: '; read -r do_trim
```

This applies to every user-facing prompt in the script. The PowerShell implementation is unaffected; `Read-Host` always writes to the console.

**Display name flag (`-n`).** The `-n` flag for setting a session display name in the Claude mobile/remote UI is not supported on all Claude Code versions. The Linux implementation omits it. If a future Claude Code update adds support, it can be re-enabled.

**Direct execution vs sourcing.** The script is structured as a function (`claudecm()`) for compatibility with sourcing from `.bashrc`. When executed directly (not sourced), a guard at the bottom invokes the function:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    claudecm "$@"
fi
```

---

### 11.6.1 Resume with fork detection

Inputs: `originalGuid`, `projectDir`, `displayName`. **PowerShell:** sets `$script:lastResumeExit` and `$script:lastResumeGuid`; **bash:** sets `__cm_resume_exit` and `__cm_resume_effective_guid` globals. **Does not return a value.** See Section 14.2 for why.

A thin wrapper around the Section 11.6 launch path, used for every `--resume` invocation. It exists because Claude Code can fork a resumed session into a new JSONL file under several conditions observed in the wild (version upgrades between resumes, deferred-tool recovery, state transitions). When that happens, the post-resume "live" file is not the one we asked to resume — the old file is effectively abandoned, and if we treat it as still current, we orphan the new file and misreport tokens against the dead one.

Steps:

1. Compute `projDirClaude` from `projectDir` via `Get-ProjectKey`.
2. Pre-snapshot the newest JSONL in `projDirClaude` (call it `beforeNewest`). May be null.
3. Launch claude (Section 11.6) with `--resume <originalGuid> -n <displayName>`. Capture exit code.
3a. **Clean-exit retry.** If exit code is non-zero AND `<originalGuid>.jsonl` exists on disk AND its tail shows a trailing `/exit` user command (grep the last ~10 lines for `/exit</command-name>`), this is a known Claude Code quirk: Claude's resume scans the JSONL tail for a completed exchange and refuses when the last entry is a user command with no assistant response. Offer recovery. Print two explanatory lines, then prompt `  Would you like to retry with a prompt that says "please continue"? [Y/n]:` (default Y). On Y, re-launch with an appended `"please continue"` positional argument and update the captured exit code. On N, fall through with the original non-zero exit code and let the caller show its usual refused-resume message. Do this BEFORE the fork-detect block in step 4 so fork detection also sees the effects of a successful retry.
4. If exit code is 0 and `projDirClaude` exists:
   - Re-scan for the newest JSONL.
   - If the newest differs from `originalGuid` AND (no pre-snapshot existed OR its basename differs from `beforeNewest.BaseName`), treat this as a fork:
     - Load sessions.txt.
     - Find the entry whose guid equals `originalGuid`. If found, swap its guid to the newest basename and reset tokens to empty. Save.
     - Set `effectiveGuid` to the newest basename.
     - Quarantine the predecessor: move `<originalGuid>.jsonl` (and its sidecar dir if present) from `projDirClaude` into `<backupDir>/<projectLeaf>/`. Then call `Sync-SessionIndex` on `projectDir`. The predecessor is wholly subsumed by the fork (Claude Code copies its history forward), so leaving it on disk would only produce a spurious orphan warning on the next launch.
   - Otherwise `effectiveGuid` stays equal to `originalGuid`.
5. Set the script-scoped/global outcome variables. Caller reads them and runs Do-PostExit on the effective guid.

**Single-source rule:** every `--resume` call in the codebase routes through this helper. Bare `claude --resume ...` calls followed by `Do-PostExit <original-guid>` are forbidden — they are the exact shape that produces fork-orphans.

### 11.6.2 Fresh launch with set-diff detection

Inputs: `projectDir`, `displayName`, `passArgs` (array). **PowerShell:** sets `$script:lastFreshExit` and `$script:lastFreshNewGuid`; **bash:** sets equivalent globals. **Does not return a value.** See Section 14.2 for why.

A wrapper around the Section 11.6 launch path, used for every fresh (non-resume) interactive launch. It detects the new session's GUID via set-diff instead of "newest-by-mtime" to survive concurrent writers racing in the same project key directory.

Steps:

1. Compute `projDirClaude` from `projectDir` via `Get-ProjectKey`.
2. Build `beforeSet` = set of UUID-basename JSONLs currently in `projDirClaude`. Filter basenames against `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
3. Launch claude (Section 11.6) with `-n <displayName>` plus any `passArgs`. Capture exit code.
4. If exit code is 0 and `projDirClaude` exists:
   - List UUID-basename JSONLs again.
   - Compute `newFiles` = those NOT present in `beforeSet`.
   - If 1 element, return its basename as `NewGuid`.
   - If >1 elements, return the newest-by-mtime as `NewGuid` (residual heuristic case; occurs only when two fresh launches race in the same project key dir within one ClaudeCM invocation).
   - If 0 elements, `NewGuid` stays null (user exited at splash, launch aborted, etc).
5. Set the script-scoped/global outcome variables. Caller reads them and decides how to register in sessions.txt.

**Why set-diff, not "newest-by-mtime":** a concurrent writer in another window can touch an existing JSONL mid-launch, making it appear newer than the file our launch created. "Newest by mtime" picks the wrong one. Set-diff picks only files that did not exist before the launch, so concurrent writers that merely touch existing files are invisible to it. This is race site #4/#5/#6 in `private/how my lazy ass created a bunch of race conditions, and how I plan to unfuckit.md`, validated in `private/meta-prompt-playground/race-4-5-6-sandbox/`.

**Single-source rule:** every fresh (non-resume) interactive launch routes through this helper. Bare `claude -n <name>` calls followed by "newest-in-project-key" inference are forbidden — they are the exact shape that mis-registers the wrong session during concurrent writes.

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

**Critical design note.** Earlier versions of this template framed the LLM's task as "write a recovery prompt that will be saved to recovery-prompt.md." That framing primed the LLM to produce a confirmation-style summary about the file (e.g. "Recovery prompt written to recovery-prompt.md. It covers the four memory files...") instead of the actual directives. The fix was to replace freeform instructions with a fill-in-the-blank template the LLM completes verbatim. The "saved to file" wording was removed entirely. Validated in `private/meta-prompt-playground/`. Both implementations use the template below.

Template (verbatim, with substitutions):

```
Context: a Claude Code session was deleted. You need to produce orientation text for a future Claude Code session that will read this text as its first input. Produce the text. That text goes directly into the next session. It is NOT a summary, NOT a description, NOT a report about what you did. It is the directives themselves.

Read these artifacts:
* Memory files in <memory_dir>
* Subagent transcripts in <subagents_dir> (2-3 most recent; total on disk: <subagent_count>, latest dated <subagent_latest>)
* The project code at <dir>

Session metadata (for reference when you write):
* Session name: <desc>
* Project path: <dir>
* Last activity: <date_str>
* Conversation size when lost: <tok_str>

Now replace every <PLACEHOLDER> below and OUTPUT the completed template. Start your output with "This is a recovery session." and end with "ask before assuming." Output nothing else. No preamble, no confirmation, no summary of what you did.

This is a recovery session. The previous conversation transcript for "<desc>" was deleted. The project lives at <dir>. Memory, subagent state, and source code all survived.

Read these files in this order:

<NUMBERED LIST. Format: "1. <filename>: <one-line description of what this file contains, based on what you read in it>". Use actual file paths from the memory directory.>

Then skim these subagent transcripts for context on in-flight work:

<BULLETED LIST using "*" not "-". Format: "* <filename>: <what this subagent was doing>". Use 2-3 of the most recently modified subagent transcripts. If there are zero subagent transcripts, replace this whole list with the single line: "No surviving subagent transcripts.">

Open questions or in-flight work visible from the artifacts:

<BULLETED LIST using "*" not "-". One line per item. If nothing specific is identifiable, replace this whole list with: "None identified from the artifacts.">

Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming.
```

**Why this works.** The template includes both the meta-instructions AND the document body the LLM is supposed to complete. The placeholder syntax (`<NUMBERED LIST. Format: ...>`) gives the LLM specific structure to fill rather than a freeform task to interpret. The "OUTPUT the completed template" framing leaves no room for confirmation messages because there's no place to write one without breaking the requested format. The "no preamble, no confirmation, no summary" prohibition is reinforced by the structural requirement to start with literal text "This is a recovery session." and end with literal text "ask before assuming."

**Why we use `*` not `-` for bullets.** Claude Code's input parser interprets a line starting with `-` as a CLI flag attempt. When recovery-prompt.md is later fed to a new Claude session, any `- bullet` line would break the parse. Using `*` avoids the problem.

### 11.8 New project from list mode

If user types non-numeric, non-special input at the list mode prompt, treat it as a new project title:

1. Sanitize directory name: lowercase, spaces → `-`, strip non-alphanumeric/underscore/dash chars.
2. Choose a unique directory under cwd: `<safe_name>`, `<safe_name>(1)`, ...
3. Create the directory.
4. Print: blank line, `  Starting new session: <title>`, `  Project dir: <newProjDir>`.
5. `cd` into it.
6. Display name = `<machine> - <title>`.
7. Launch via the platform's launch path (Section 11.6).
8. After exit, if SessionId was resolved, register at top of sessions.txt with empty tokens, dir = newProjDir, desc = title.
9. Restore original directory.

### 11.9 Do-Resume

Inputs: `pick`, `sessions`.

1. Range-check pick. If `sel.Dir` doesn't exist, error and return.
2. Save original location, `cd` to `sel.Dir`.
3. Run Do-OrphanScan. If user selected an orphan to resume:
   - Display name = `<machine> - <sel.Desc>`
   - Launch via the resume-with-fork-detection helper (Section 11.6.1) with `--resume <orphan-guid>`.
   - On exit code 0, Do-PostExit with the EFFECTIVE guid returned by the helper.
   - Restore directory, return.
4. Run Resolve-ResumeOrRecover:
   - cancel → restore, return
   - fresh → launch via Section 11.6 (no `--resume`). On successful launch with new SessionId, swap the dead entry's GUID for the new one in place (preserving desc and dir, resetting tokens). Then Do-PostExit. **Critical:** do NOT delete the dead entry before launching — if launch fails, the entry would be unrecoverable.
   - primed → launch via resume-with-fork-detection (11.6.1) with `--resume <recover.Guid>`, Do-PostExit with effective guid.
   - normal → launch via resume-with-fork-detection (11.6.1) with `--resume <sel.Guid>`, Do-PostExit with effective guid.
5. If the normal-resume launch exits non-zero, distinguish by whether the target JSONL is on disk:
   - JSONL exists but Claude refused to load it: print a yellow note that the most common causes are an interrupted tool call or stale deferred-tool marker, and that the entry has NOT been deleted. Do not prompt.
   - JSONL is missing from disk: prompt `  Session JSONL is missing. Delete this entry? [Y/n]: ` (default Y). If not `n`, remove the entry from sessions.txt.
6. Restore directory.

**Critical:** the recovery `fresh` branch must NOT delete the old sessions.txt entry before launching. If the launch fails (Claude crashes, arg passing breaks, anything), the entry would be gone with no JSONL to fall back to. Instead, launch first; if the launch succeeds and produces a new SessionId, swap the old GUID for the new one in place (preserving desc and dir, resetting tokens). If the launch fails, the entry stays put and the user can retry.

**Critical:** every `--resume` invocation must go through the resume-with-fork-detection helper (Section 11.6.1). Claude Code can fork a resumed session to a new JSONL file (version upgrades across a resume, deferred-tool recovery, etc.), and the live file's basename then differs from the GUID we asked to resume. Calling `--resume <guid>` directly and then running Do-PostExit on the original guid leaves the new file orphaned — it is the real session going forward, but sessions.txt still points at the pre-fork file that Claude has abandoned.

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
7. Prompt: `  Would you like to view/edit the compaction prompt and skeleton before proceeding? (Save and close when done) [y/N]: `. If `y`, open in editor (notepad on Windows, $EDITOR/nano on Linux), wait for editor to close.
8. Read the (possibly edited) prompt, delete temp file.
9. `cd` to session directory.
10. Print `  Creating fresh session, please wait...`
11. Pipe the prompt text to claude via **stdin**, not as a command-line argument. Command shape: `<prompt-text> | claude --dangerously-skip-permissions -p --output-format json`. Capture stdout. **IMPORTANT — do not pass the prompt as `-p <prompt-text>`:** Windows' CreateProcess command-line length limit (~32,767 chars) is exceeded by any realistic compaction prompt that includes a skeleton and filtered transcript. Passing as an argument fails silently on Windows with `"The filename or extension is too long"`, produces no output, and breaks the whole refresh flow. Stdin has no length limit. This was discovered on 2026-04-14 after a full day of debugging a different hypothesis.
12. Print `  Done.`
13. Restore directory.
14. Find the new session GUID: **parse `session_id` from the captured JSON stdout of step 11**. Never scan the project directory for "newest JSONL" — that approach races against other concurrent sessions writing to the same project dir, and the wrong file gets picked (see `private/how my lazy ass created a bunch of race conditions, and how I plan to unfuckit.md` for the full cautionary tale). If the JSON parse fails or has no `session_id`, print a warning and return; do NOT fall back to filesystem scanning.
15. Build new sessions list:
    - Identify the old entry. Compute new DESC by stripping any trailing ` (old)` or ` (old N)` suffix to get a base description, then scanning the sessions list for all entries with the same base description AND the same Dir (excluding the session being renamed itself). Collect every `(old N)` number already in use (treat bare `(old)` as N=1). Assign the next unused positive integer: if N=1 is free, the new DESC is `<base> (old)`; otherwise `<base> (old <next>)`. This prevents duplicate `(old)` labels that arise when repeated refreshes on the same project pick the same increment each time.
    - All other sessions stay in place (relative order).
    - Get token count for new session: `cmv benchmark -s <freshGuid> --json`, parse `preTrimTokens`. Never `--latest`.
    - Build new entry: `{Guid=<new>, Dir=<curDir>, Desc=<newName>, Tokens=<tokens>}`.
    - Final list: `[new entry] + [other sessions in original order] + [old entry]`.
16. Print `  Fresh session created: <newName>` and `  Old session moved to bottom of list.`
17. Best-effort cleanup: remove `<refresh-temp-dir>` recursively.

### 11.15 Do-PostExit

Runs after every interactive Claude session that exited cleanly. Argument: `knownGuid` (required in practice; every caller passes one via the set-diff detection in Sections 11.6.1 and 11.6.2).

1. Print blank line, `  Session ended.`, blank line.
2. **Resolve GUID.** Use `knownGuid`. If unset or empty, return immediately without running snapshot, token update, sync, or trim/refresh prompts. The prior fallback that scanned the project key dir for "newest non-agent-* JSONL" was removed: it picked stale pre-existing files when the caller legitimately had no new session (user bailed at claude splash, launch produced nothing), mis-registering the wrong session in sessions.txt. Callers that can't produce a GUID must skip Do-PostExit entirely rather than call it with null hoping the fallback saves them.
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
4. **Always resolve session ID before running cmv operations.** Use the GUID the caller knows (resume case), or the launch helper's belt-and-suspenders (bash), or post-launch project-scoped inference (PowerShell). Never run cmv against an unidentified "current" session.
5. **All sessions.txt mutations hold the lock and write atomically.**
6. **All scratch directories are per-operation scoped** (refresh-temp).

Violating any of these can corrupt sessions across projects.

### 14.1 Accepted residual concurrency limitations

The following known races are documented and left unfixed because the mitigation cost exceeds the demonstrated impact. If any of these ever produce a real incident in the field, revisit.

1. **sessions.txt reads are unlocked.** `Get-Sessions` / `Get-ArchivedSessions` do not acquire a shared lock. Writes use atomic rename (write to `.tmp`, then rename over the target), which is observably-atomic on both NTFS and POSIX: readers see either the old file or the new one, never a partial state. Adding a shared reader lock would add complexity to every read path (including the read-modify-write patterns in Do-EditList and Do-ViewArchived) with no observable benefit as long as the atomic-rename contract holds. If a future Windows/NTFS edge case breaks rename atomicity, revisit.

2. **Sync-SessionIndex during live writes.** `Sync-SessionIndex` scans all JSONLs in a project dir to rebuild `sessions-index.json`. If a Claude session is actively writing during the scan, the index could miss entries or capture pre-write state. The index is disposable metadata that Claude Code's `/resume` picker uses for display only; wrong entries fix themselves on the next sync call. Not worth locking the index rebuild against live writes.

3. **recovery-prompt.md rotation is unlocked.** If two ClaudeCM windows concurrently generate recovery prompts for different sessions in the same project directory within milliseconds of each other, the `.old` / `.oldN` rotation can clobber. Extremely unlikely in practice (recovery generation is user-initiated and takes ~60s of wall time during which the user is engaged with a single window). Accepted.

4. **Backup file rotation race.** Backups of sessions.txt are rotated by keeping the 20 most recent and deleting older ones. If two ClaudeCM windows rotate in the same second, one could delete a backup the other just created. Worst case: one fewer historical backup than intended. No data loss from the live system. Accepted.

---

### 14.2 Critical PowerShell pattern: helpers that launch interactive children must NOT return values

**This rule exists because violating it cost an entire day of debugging on 2026-04-15/16.**

**The trap.** When you write a PowerShell function that calls an interactive native process (`& $claudeExe ...`) and you assign that function's return value to a variable in the caller (`$r = MyHelper ...`), PowerShell wraps the entire function call in an output-capturing pipeline. The native process's stdout is no longer the console — it's a pipe back into the capture. The native process's TTY-detection check (`process.stdout.isTTY`) returns false, and the process degrades to non-interactive mode (`-p`-equivalent for Claude Code).

**The symptom.** The user picks a session in `claudecm`. ClaudeCM calls `& claude.exe --resume <guid> -n <name>` inside `Invoke-ResumeWithForkDetection`. Claude Code falls into `-p --resume` mode despite no `-p` flag, fires `Error: No deferred tool marker found in the resumed session...`, and exits 1. The interactive TUI never appears. From outside the helper, calling the same `& claude.exe --resume <guid> -n <name>` works perfectly — the difference is that the outside call doesn't have its output stream captured.

**The rule.** Helpers that invoke interactive `claude.exe` (or any native interactive process) MUST communicate results to the caller through script-scoped variables. They MUST NOT use `return @{ ... }` or any pattern the caller would consume with `$x = HelperName ...`. Specifically:

- `Invoke-ResumeWithForkDetection` sets `$script:lastResumeExit` and `$script:lastResumeGuid`.
- `Invoke-FreshLaunchWithDetection` sets `$script:lastFreshExit` and `$script:lastFreshNewGuid`.
- Callers invoke the helper without an `=` assignment, then read the script-scoped variables directly.

**Bash equivalence.** The same pattern (output capture) applies in bash if you use command substitution: `r=$(my_helper ...)`. Bash helpers in `claudecm-linux.sh` use module-level globals (`__cm_resume_exit`, `__cm_resume_effective_guid`) for the same reason and are safe.

**Test guard.** `private/meta-prompt-playground/test-cwd-launch.ps1` and the historical writeup in `private/today-was-a-shitshow-output-capture-bug.md` (2026-04-16) preserve the diagnostic approach used to bisect this. Re-run those if a regression is suspected.

**Why this isn't fixable inside Claude Code.** Claude Code's TTY-detection-driven mode switch is by design — `-p` mode is supposed to fire when stdout isn't a terminal, so headless callers (Python `subprocess.run`, CI pipelines, etc.) get well-defined non-interactive behavior. The bug is on our side: capturing a function's output stream in a context where the function spawns an interactive child is a mistake, full stop.

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
