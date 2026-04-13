# Claude Context Manager (ClaudeCM)

A wrapper for Claude Code that adds session management: named sessions, resume by number, and structured session refresh.

## Usage

```
claudecm                       Launch Claude normally
claudecm l  (or L)             List saved sessions, pick to resume
claudecm 3                     Resume session #3 directly
claudecm --proj C:\myproject   Launch in a specific project directory
```

## Features

### Session tracking
On exit from Claude, you're prompted to name the session. Named sessions are saved to a list. If you hit Enter, the session is not tracked (for quick one-offs).

### Resume by list
`claudecm l` shows a numbered list. Pick a number to resume that session. Sessions you use get moved to the top of the list (most recent first).

### Rename
When exiting an existing session, you can rename it.

### Edit list
From the list view, type `E` to edit sessions. Commands: `R#` rename, `P#` change path, `A#` archive, `D#` delete permanently, `M#,#` reorder.

### Archive
`A#` from the edit list moves a session off the active list into the `[archived]` section of `sessions.txt`. All files stay on disk. Archived sessions don't appear in the main list or trigger orphan detection.

From the main list, `V` opens the archive viewer. `U#` unarchives (moves back to the top of the active list). `D#` permanently deletes from archive.

### Delete
`D#` from either the edit list or archive viewer permanently deletes a session. This removes:
- The entry from `sessions.txt`
- The JSONL conversation file from `~/.claude/projects/<key>/`
- The associated subdirectory (agent data)
- The entry from `sessions-index.json`

Requires typing "delete" (case insensitive) to confirm. This cannot be undone.

### Orphan conversation detection
On every resume (both directory-match and menu-selection), the script scans the `.claude/projects/` subdirectory for extra JSONL files beyond the registered session. If extras are found, a table is displayed showing each file's date, size, and status:
- Sessions registered to a different directory are flagged `(wrong directory)`
- Sessions not in sessions.txt are shown as `(orphan)`
- The registered session is marked with `*`

Actions: select a different conversation by number, quarantine strays to backup with `q <number>`, or press Enter to continue with the registered session. Quarantine moves files to `claude-conversation-backup/` under the github directory; nothing is deleted.

### Structured refresh

When a session has accumulated too much history for trim alone, refresh starts a fresh session and carries forward what matters. Unlike a naive approach where Claude reads the entire old transcript (expensive, slow, unreliable), refresh uses a hybrid extraction informed by [Factory.ai's research](https://factory.ai/news/evaluating-compression) on 36,000+ production coding agent messages.

**Phase 1 (mechanical, no AI):** A Node.js script reads the old session JSONL and extracts a structured skeleton: every file modified, every file read, errors encountered, and the most recent exchanges. This is guaranteed accurate because it's pulled directly from tool call records. A separate filtered transcript is produced containing only conversation text and one-line tool call summaries (e.g., `Read: path/to/file.py`, `Bash: run tests`), with all tool output stripped. Supporting research from [Chroma](https://www.trychroma.com/research/context-rot) shows that focused inputs outperform full context dumps regardless of window size. [Zylos](https://zylos.ai/research/2026-02-28-ai-agent-context-compression-strategies) found that context drift degrades reasoning beyond 30K tokens.

**Phase 2 (AI, guided by skeleton):** The new session starts with the skeleton injected into the recovery prompt and a reference to the filtered transcript file. Claude reads the transcript and identifies decisions, corrections, and reasoning that the mechanical skeleton doesn't capture. No external API call is needed; Claude does this as part of its normal startup.

The user can edit the prompt before it runs. The prompt includes a clearly marked section for adding your own notes (decisions, context, corrections) above the skeleton. Review the skeleton, delete irrelevant items, add whatever the extraction missed.

Before extraction runs, the script validates that the JSONL file has the expected structure (entry types, tool_use fields, file_path in inputs). If Anthropic changes the format in a future update, the validation catches it and falls back gracefully instead of producing a bad skeleton.

The old session is preserved at the bottom of the session list with "(old)" appended to the name. Repeated refreshes increment: "(old)", "(old 2)", "(old 3)". Nothing is deleted.

### The `[important]` marker

Type `[important]` at the start of a line in any message to flag something for the skeleton extractor. For example:

```
[important] We chose React + Ant Design for the frontend rebuild
[important] The auth middleware must not store session tokens in cookies (legal requirement)
```

These are captured verbatim in the skeleton's "Marked Important" section. Use them before a planned refresh or compaction to ensure critical decisions and context survive.

Case insensitive. Must be at the start of a line (not inline). Content after the tag to end of line is captured.

### Machine name (remote display)

Every session is launched with a display name in the format `machine - project` (e.g., `desktop - YouTube processor`). This shows up in the Claude Code app when viewing sessions remotely.

On first launch, you're prompted for a machine name. It's stored in `~/.claudecm/machine-name.txt`. To change it later, use `M` from the session list menu.

## Session storage

```
~/.claudecm/
  sessions.txt          Ordered index: GUID|PROJECT_DIR|DESCRIPTION
  machine-name.txt      Machine name for remote display
  refresh-temp/         Temporary skeleton and transcript files from refresh
```

GUID detection works by finding the newest `.jsonl` file in `~/.claude/projects/<project-key>/`.

Backups from quarantined orphans are stored in `~/documents/github/claude-conversation-backup/`, organized by source project.

## Platforms

### Windows (PowerShell)

The function lives in `$PROFILE` (`Microsoft.PowerShell_profile.ps1`). See `claudecm-powershell.ps1` for the full source.

**Important:** After editing `$PROFILE`, open a new PowerShell window for changes to take effect.

### Linux (bash)

Install `claudecm` to `/usr/local/bin/` or `~/.local/bin/`. See `claudecm-linux.sh` for the full source.

Runs as the current user by default. To run as a dedicated `claude` user, wrap with `sudo -u claude`.

## Prerequisites

- Claude Code installed and in PATH
- Node.js (for skeleton extraction during refresh)
- Windows: PowerShell 5.1+
- Linux: bash 4+, `jq` not required
