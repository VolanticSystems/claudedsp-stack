# ClaudeDSP

A wrapper for Claude Code that adds session management: named sessions, notes, and resume by number.

## Usage

```
claudedsp                       Launch Claude normally
claudedsp l  (or L)             List saved sessions, pick to resume
claudedsp 3                     Resume session #3 directly
claudedsp --proj C:\myproject   Launch in a specific project directory
```

## Features

### Session tracking
On exit from Claude, you're prompted to name the session. Named sessions are saved to a list. If you hit Enter, the session is not tracked (for quick one-offs).

### Resume by list
`claudedsp l` shows a numbered list. Pick a number to resume that session. Sessions you use get moved to the top of the list (most recent first).

### Notes
After each session, you're offered to add/edit notes in Notepad (Windows) or your `$EDITOR` (Linux). When resuming, notes are displayed before Claude starts (default: yes).

### Rename
When exiting an existing session, you can rename it.

### Edit list
From the list view, type `E` to open the raw session file in a text editor for manual cleanup.

## Session storage

```
~/.claudedsp/
  sessions.txt          Ordered index: GUID|PROJECT_DIR|DESCRIPTION
  notes/
    <GUID>.txt          Free-form notes per session
```

GUID detection works by finding the newest `.jsonl` file in `~/.claude/projects/<project-key>/`.

## Platforms

### Windows (PowerShell)

The function lives in `$PROFILE` (`Microsoft.PowerShell_profile.ps1`). See `claudedsp-powershell.ps1` for the full source.

**Important:** After editing `$PROFILE`, open a new PowerShell window for changes to take effect.

### Linux (bash)

Install `claudedsp` to `/usr/local/bin/` or `~/.local/bin/`. See `claudedsp-linux.sh` for the full source.

Runs as the current user by default. To run as a dedicated `claude` user, wrap with `sudo -u claude`.

## Prerequisites

- Claude Code installed and in PATH
- Windows: PowerShell 5.1+
- Linux: bash 4+, `jq` not required
