# ClaudeDSP - Development Lessons Learned

## Date: 2026-03-12

## What ClaudeDSP Is

A PowerShell function that wraps `claude.exe --dangerously-skip-permissions` with session management: named sessions, notes, resume by number. Lives in `$PROFILE`.

## What Went Wrong

### 1. Failed to tell the user to restart PowerShell after editing $PROFILE (Critical)

After editing the user's PowerShell profile to replace the old one-liner `claudedsp` function with the new session-management version, I never told them to open a new PowerShell window. The old function was still loaded in the running session's memory. Every test the user ran used the old function, which just passed arguments straight to Claude. `claudedsp l` became `claude.exe --dangerously-skip-permissions l`, and Claude treated `l` as a prompt.

This single oversight caused the entire debugging spiral that followed. Every "fix" I attempted was solving a problem that didn't exist.

**Lesson:** When editing `$PROFILE`, shell rc files, or anything that loads at session start, always tell the user to open a new terminal.

### 2. Wrote a bash script when the user's shell is PowerShell

Claude Code's environment reports "Shell: bash" because that's Claude Code's own sub-shell. I assumed that was the user's terminal. It's not. The user runs PowerShell. I wrote a bash wrapper script, debugged Git Bash argument passing, researched MSYS2 path conversion — all completely irrelevant.

**Lesson:** Claude Code's reported shell is not the user's shell. Ask, or check `$PROFILE` / `Get-Command` to see what's actually running. The environment line "Shell: bash" describes Claude Code's sandbox, not the user's terminal.

### 3. Claimed "it works" after testing from the wrong environment

I tested `claudedsp l` using `cmd.exe` from within Claude Code's bash shell. It showed the session list. I told the user it worked and to go test it. It didn't work from their actual environment (PowerShell). I did this multiple times.

**Lesson:** Test in the user's actual environment. Use `powershell.exe -Command "..."` to test PowerShell behavior. If you can't fully test something (e.g., nested Claude session), say exactly what you tested and what you couldn't. Never say "it works" based on proxy testing.

### 4. Spent hours debugging a .cmd file that was never being executed

The PowerShell function `claudedsp` in `$PROFILE` took priority over `claudedsp.cmd` in PATH. I never checked what was actually executing. I could have run `(Get-Command claudedsp).CommandType` at any point and seen it was a `Function`, not an `Application`. Instead I:

- Debugged CRLF line endings (LF vs CRLF)
- Rewrote the file multiple times
- Used Python to generate the file to avoid tool escaping issues
- Wrote and deleted a bash wrapper
- Researched Git Bash argument passing on the internet

None of this mattered because the `.cmd` file was never invoked.

**Lesson:** Before debugging why a script doesn't work, verify which file/function is actually executing. `Get-Command <name>` in PowerShell, `which <name>` or `type <name>` in bash.

### 5. Claude Code's Write/Edit tools corrupt batch files

The Write and Edit tools operate through bash, which escapes `!` characters to `\!`. Batch files using delayed expansion (`!VARIABLE!`) get corrupted to `\!VARIABLE\!`. Also `>nul` becomes `>/dev/null`.

**Workaround:** Use a Python script to generate `.cmd` files, writing each line explicitly with `\r\n` line endings.

### 6. CRLF line endings

Claude Code's Write tool creates files with Unix LF line endings. Windows `cmd.exe` requires CRLF. Files written by the Write tool won't parse correctly as batch scripts.

**Workaround:** Same as above — use Python with explicit `\r\n` in binary write mode. Or use `sed` / Python to convert after writing. But this is moot if you write PowerShell instead of batch.

## What Should Have Happened

1. Check `(Get-Command claudedsp).Definition` to see what's actually running
2. See it's a PowerShell function in `$PROFILE`
3. Edit `$PROFILE` to add the session management logic
4. Tell the user to open a new PowerShell window
5. Test from PowerShell using `powershell.exe -Command "claudedsp l"`
6. Done in 15 minutes

## File Locations

- PowerShell function: `%USERPROFILE%\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- Session list: `%USERPROFILE%\.claudedsp\sessions.txt`
- Notes: `%USERPROFILE%\.claudedsp\notes\<GUID>.txt`
- Legacy .cmd (unused): `%USERPROFILE%\.local\bin\claudedsp.cmd`
- Original backup: `%USERPROFILE%\.local\bin\claudedsp.old`
