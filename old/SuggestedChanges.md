# Suggested Changes

## Changes to bring FROM Linux TO PowerShell

### 1. New project from list

Currently in list mode, typing anything that isn't a number or "E" shows "Invalid selection." On KC3 Linux, typing a name creates a new project and launches Claude there.

**What it should do:**
- In the list mode loop, after checking for E and for a number, treat any other non-empty input as a new project title
- Derive a directory name from the title: lowercase, spaces to hyphens, strip non-alphanumeric characters (keep hyphens and underscores)
- Create the directory under the user's current working directory (Linux uses `$HOME`, but PowerShell should use the current location or a configurable base)
- If the directory already exists, append `(1)`, `(2)`, etc.
- `mkdir` the directory, `Set-Location` into it, launch Claude with DSP
- After Claude exits, find the session GUID (newest .jsonl in the project dir)
- Save it to the top of sessions.txt using the typed title as the description
- Skip the normal `Do-PostExit` flow since we already have the title
- Return to original directory

**Where in the code:**
- In the `# List mode` section, after the `if ($pick -match '^\d+$')` block, add an `else` branch before the "Invalid selection" line

### 2. Auto-resume on launch

Currently plain `claudedsp` always starts a fresh Claude session. On KC3 Linux, it checks if the current directory matches a session in the list and offers to resume it.

**What it should do:**
- In the `# Normal mode` section, after determining the working directory (either from `--proj` or current location), check sessions.txt for a matching directory
- If a match is found and no extra args were passed, display: `Found existing session: <description>`
- Prompt: `Continue with this session? [Y/n]:`
- If Y (default): launch Claude with `--resume <GUID>`, then run `Do-PostExit` with the known GUID, then return
- If N: fall through to normal fresh launch
- If multiple sessions match the same directory, use the first match (which is the most recently used due to sort order)

**Where in the code:**
- In the `# Normal mode` section, after the `Set-Location` block and before the `& $claudeExe` call

---

## Changes to bring FROM PowerShell TO Linux

### 1. Yellow highlight on direct resume

Currently `claudedsp 3` shows the list with no indication of which session was picked. The PowerShell version highlights the selected line in yellow with `*** N. Description  [Selected] ***`.

**What it should do:**
- `show_list` should accept an optional highlight parameter (e.g., `show_list $highlight_num`)
- When displaying each line, if the line number matches the highlight parameter, print it with ANSI color codes and the `[Selected]` suffix
- Yellow ANSI: `\033[1;33m` before the line, `\033[0m` after

**Where in the code:**
- Modify `show_list()` to accept a parameter
- In the `# Direct resume by number` section, call `show_list "$1"` instead of plain `show_list`

### 2. Known GUID passing to post_exit

Currently `post_exit` always calls `find_session_guid` which looks for the newest `.jsonl` file in the project directory. This is wrong when multiple sessions share the same directory — it finds the wrong GUID.

**What it should do:**
- `post_exit` should accept an optional GUID parameter
- If a GUID is passed, use it directly instead of calling `find_session_guid`
- If no GUID is passed (plain `claudedsp` launch), fall back to `find_session_guid` as before
- `do_resume` should pass `$SEL_GUID` to `post_exit`

**Where in the code:**
- Change `post_exit()` to `post_exit() { local known_guid="${1:-}" ... }`
- If `known_guid` is set, use it as `SESSION_GUID`; otherwise call `find_session_guid`
- In `do_resume`, change `post_exit` to `post_exit "$SEL_GUID"`
- In the auto-resume block (normal mode), change `post_exit` to `post_exit "$MATCH_GUID"`

### 3. Delete archiving

Currently `D#` in edit mode deletes the session entry from sessions.txt but any associated notes file is silently left behind (or lost track of). The PowerShell version moves notes to a `deleted/` subfolder.

**What it should do:**
- When deleting a session, check if a notes file exists at `$NOTES_DIR/<GUID>.txt`
- If it exists, create `$NOTES_DIR/deleted/` if needed
- Derive a safe filename from the session description (replace `/` and other unsafe chars with `_`)
- Move the notes file to `$NOTES_DIR/deleted/<description>.txt`
- If that filename already exists, append `(1)`, `(2)`, etc. until unique
- Print: `Notes archived to deleted/<filename>.txt`

**Where in the code:**
- In `do_edit`, inside the `d` command handler, after the confirmation prompt and before removing the line from sessions.txt

### 4. Path change copies .jsonl

Currently `P#` updates the path in sessions.txt but doesn't move the session file. Claude Code looks up sessions by project key derived from the directory path, so the session won't be found at the new path.

**What it should do:**
- When changing a path, compute the old and new project keys (path with `/` replaced by `-`, leading `-` stripped)
- Locate the session file at `~/.claude/projects/<old-key>/<GUID>.jsonl`
- If it exists, create `~/.claude/projects/<new-key>/` if needed
- Copy (not move) the .jsonl file to the new project directory
- Print confirmation: `Session file copied to new project directory.`
- If the old file doesn't exist, warn: `Warning: Session file not found at old path. Resume may not work.`

**Where in the code:**
- In `do_edit`, inside the `p` command handler, after reading the new path and before writing the updated sessions.txt

### 5. Blank notes file creation

Currently the editor is opened on `$NOTES_DIR/$SESSION_GUID.txt` which may not exist. Some editors handle this gracefully, some don't.

**What it should do:**
- Before opening the editor, check if the notes file exists
- If not, `touch` it to create a blank file
- Then open the editor

**Where in the code:**
- In `post_exit`, before the `$EDITOR` call
- In `do_resume`, this is already handled (notes are only shown if the file exists)
