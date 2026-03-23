# ClaudeDSP

A session manager for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that runs with **Dangerously Skipped Permissions** — that's what the DSP stands for.

## What is Claude Code?

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) is Anthropic's command-line tool that lets you work with Claude directly in your terminal. You launch it with:

```
claude
```

It opens an interactive session where Claude can read your files, write code, run commands, and help you build things.

## What are "dangerously skipped permissions"?

By default, Claude Code asks for your approval before doing things like editing files or running commands. That's safe, but slow — you're hitting "yes" constantly. If you trust Claude and want it to just do the work, you can launch it with:

```
claude --dangerously-skip-permissions
```

This lets Claude act without asking permission for every operation. It's called "dangerous" because Claude can modify files and run commands without confirmation. If you're comfortable with that trade-off (and many power users are), it makes the workflow much faster.

**ClaudeDSP always launches Claude Code with `--dangerously-skip-permissions` enabled.** That's its default mode. If you don't want that, this tool isn't for you.

## The session problem

When you exit Claude Code, you see something like this:

```
Resume this session with:
claude --resume a17b8d20-71c1-4eb6-8e7d-438222b649fc
```

That GUID is the only way to get back to your conversation. After a few sessions across different projects, you've got a pile of 36-character hex strings and no idea which is which.

## What ClaudeDSP adds

ClaudeDSP wraps that launch command and adds session management:

1. **Named sessions** — When you exit, it asks what you were working on. Next time you see a list of names instead of GUIDs.
2. **Notes** — Jot down where you left off. Notes are shown before you resume so you can pick up right where you stopped.
3. **Resume by number** — Type `claudedsp 3` to jump back into session 3. No GUIDs, no copy-paste.
4. **Edit list** — Rename sessions, change project paths, delete old ones, reorder — all without touching raw config files.

## Quick start

### Windows (PowerShell)

ClaudeDSP is a PowerShell function that lives in your profile. It's not an installed program — you paste it into your profile and it's available in every PowerShell window.

1. Open your PowerShell profile:
   ```powershell
   notepad $PROFILE
   ```
   If the file doesn't exist, PowerShell will ask if you want to create it. Say yes.

2. Paste the entire contents of `claudedsp-powershell.ps1` into your profile

3. Save the file and **open a new PowerShell window** (the old window won't see the changes)

4. Done. Type `claudedsp` to launch Claude Code with DSP enabled.

### Linux

1. Copy the script:
   ```bash
   sudo cp claudedsp-linux.sh /usr/local/bin/claudedsp
   sudo chmod +x /usr/local/bin/claudedsp
   ```
2. Done. Type `claudedsp` to launch Claude Code with DSP enabled.

## Commands

| Command | What it does |
|---|---|
| `claudedsp` | Launch Claude Code (with `--dangerously-skip-permissions`) |
| `claudedsp l` | Show your saved sessions, pick one to resume |
| `claudedsp 3` | Resume session #3 directly (shows the list with your pick highlighted) |
| `claudedsp --proj /path` | Launch Claude in a specific project directory |

## What a session looks like

### Starting fresh

```
claudedsp
```

Claude Code starts. You do your work. When you exit:

```
  Describe this session (Enter to skip): Fixing the login bug
  Add/edit notes? [y/N]: y
```

A notepad window opens where you can type notes. If you hit Enter to skip the description, nothing is saved — good for quick one-off questions.

### Listing and resuming sessions

```
claudedsp l

  === Saved Sessions ===

  1. Fixing the login bug
  2. Website redesign
  3. New API endpoint
  4. Data migration script

  E. Edit this list

  Pick #, new title, or Enter to quit: 1
```

If the session has notes, you'll be asked if you want to review them before resuming:

```
  Review notes? [Y/n]: y

  --- Notes: Fixing the login bug ---

  Left off at the auth middleware.
  Need to check token refresh logic next.

  --- End of notes ---

  Press Enter to continue...
```

Then Claude Code resumes right where you left off — full conversation history intact.

### Resuming directly

```
claudedsp 2
```

Shows the full list so you can confirm it's the right one, then resumes it. One command.

### Starting a new project from the list

From the session list, type a name instead of a number:

```
  Pick #, new title, or Enter to quit: My New Project
```

This creates a project directory (`~/my-new-project/` on Linux, derived from the title), launches Claude there, and saves the session automatically. If the directory already exists, a suffix is added (`my-new-project(1)`, etc.).

### Editing the list

From the session list, press `E` to enter edit mode:

```
  === Edit Sessions ===

  1. Fixing the login bug  [C:\Users\you\myproject]
  2. Website redesign  [C:\Users\you\website]

  R# = Rename   P# = Path   D# = Delete   M#,# = Move (from,to)   Q = Done

  > R2
  New name for 'Website redesign': Homepage overhaul
```

- `R3` — Rename session 3
- `P3` — Change the project directory path for session 3
- `D3` — Delete session 3 (asks for confirmation)
- `M5,2` — Move session 5 to position 2
- `Q` — Done editing, back to the session list

You never see or touch GUIDs or raw config files.

## How it works under the hood

Claude Code stores each conversation as a `.jsonl` file in `~/.claude/projects/<project-key>/` where the project key is derived from the working directory path. ClaudeDSP finds the most recently modified session file after Claude exits and matches it to your named list.

Sessions are stored in `~/.claudedsp/sessions.txt` as a simple pipe-delimited file:

```
a17b8d20-...|C:\Users\you\myproject|Fixing the login bug
df556d72-...|C:\Users\you\website|Website redesign
```

Notes live in `~/.claudedsp/notes/<GUID>.txt` as plain text files you can edit with any text editor.

Most recently used sessions automatically float to the top of the list.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and in your PATH
- Windows: PowerShell 5.1+
- Linux: bash 4+

## License

Do whatever you want with it.
