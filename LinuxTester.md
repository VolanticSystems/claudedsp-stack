# LinuxTester.md

Read me before running `claudecm-linux.sh`. This is a port from the PowerShell
implementation; it conforms to `claudecm-project-spec.md` but has never been
executed on a real Linux system. Expect to shake out bugs.

Your job: test it, flag bugs, don't get bitten by the ones I already know about.

---

## Install

1. Place `claudecm-linux.sh` somewhere persistent (e.g. `~/.local/share/claudecm/`).
2. Place `extract-skeleton.mjs` alongside it (or at `~/.claudecm/extract-skeleton.mjs`).
3. Source from `~/.bashrc` or `~/.zshrc`:
   ```bash
   source ~/.local/share/claudecm/claudecm-linux.sh
   ```
4. Open a new shell. `claudecm` should be a defined function.

## Required dependencies

- `claude` (Claude Code CLI, on `$PATH` or at `~/.local/bin/claude`)
- `bash` 4.0+ (script uses `mapfile`, `[[ ]]`, `${var,,}` lowercase expansion)
- `node` (used for JSON parsing, `Sync-SessionIndex`, settings patching)
- `flock` from util-linux
- GNU coreutils (`date -d`, `stat -c`). If on macOS, the script has BSD
  fallbacks for `date -r` and `stat -f` but is untested there.
- `jq` (optional; preferred over node for simple JSON field extraction)

## Optional

- `cmv` (Claude Memory Vault) for snapshot/trim/refresh/benchmark. Without it,
  those operations degrade with a notice but everything else runs.

---

## Things that are most likely to bite you

### 1. First run: cleanupPeriodDays patch
On first invocation, if `~/.claude/settings.json` has `cleanupPeriodDays`
unset or below 1000, the script rewrites it to 100000 and prints a cyan
notice. It backs up the original to `~/.claudecm/backup/settings.json.<ts>`
first. If you don't see this once and don't want it to happen, set the
value to something >= 1000 manually before first run.

### 2. Machine name prompt
First invocation asks for a machine name (for display in the Claude mobile
app and remote UI). Default falls back to lowercase `hostname`. Stored in
`~/.claudecm/machine-name.txt`. Change anytime via the `M` command in list
mode.

### 3. Interactive claude + PID-based session ID
The bash port does NOT implement Layer 1 (polling
`~/.claude/sessions/<pid>.json`) of the belt-and-suspenders launch helper.
Reason: bash can't cleanly capture a foreground PID without TTY tricks
that would break interactive input to Claude. The spec allows silent
Layer 1 fallback. The port relies on Layer 2 (JSONL-directory snapshot
diff before/after launch) and Layer 3 (newest JSONL in project-key dir).

**Watch for:** if the snapshot diff ever picks the wrong file because
another ClaudeCM window was writing concurrently, you'll see wrong-session
registration in `sessions.txt`. Repro: launch two ClaudeCM sessions in
the same project dir within seconds. Layer 2/3 can race.

### 4. Refresh: stdin vs argv
Every `claude -p` call goes through stdin (`< "$prompt_file"`), never
`-p <big-string>`. On Linux argv limits are usually much higher than
Windows' 32K, but the spec standardizes on stdin. Don't "optimize" this
back to an argument. The 2026-04-14 writeup explains the cost of doing
that wrong (one full day of debugging).

### 5. Fork-on-resume quarantine
If Claude Code forks a resumed session into a new JSONL file (we've seen
this on Claude version upgrades between a resume and the next launch),
the helper detects the fork, swaps the GUID in `sessions.txt`, and moves
the predecessor JSONL + sidecar dir into `~/.claudecm/backup/<leaf>/`.

**Watch for:** if you see files accumulating in the backup dir after
resumes, that's the helper working. If you see orphan warnings on the
NEXT launch after a resume, the quarantine didn't fire and that's a bug.

### 6. Lock file
`~/.claudecm/sessions.txt.lock` uses `flock -n` on fd 9. 10s retry with
200ms intervals. Timeout warns and proceeds unlocked (last-write-wins).
**Watch for:** lock file never being released on script crash. `flock`
releases on process exit, so this should be fine, but if you see the
lock held after no ClaudeCM processes exist, that's a bug.

### 7. Date formatting
GNU `date -d "@$epoch"` is primary. BSD fallback `date -r $epoch` is
present. Tested on neither. If you see malformed dates in the session
list on your KC3 box, report which `date` implementation is in use
(`date --version` vs `man date | head`).

### 8. Sort for move command (`M#,#` in edit list)
The move logic rebuilds the array in place. Verify by doing `M2,5` on a
list of 6 sessions and confirming position 2 goes to position 5 with
others shifting correctly. Fragile logic, easy to off-by-one.

### 9. `title case` fallback uses awk
The spec says folder default = "dashes → spaces, title-cased". PowerShell
uses `TextInfo.ToTitleCase`. Bash port uses an awk one-liner:
`awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}'`
This capitalizes the first letter of each space-separated word. It will
NOT handle Unicode correctly. Mostly fine for ASCII project names.

### 10. Subshell scope in PID capture (spin animation during snapshot)
`Do-PostExit`'s snapshot-in-progress spinner runs in a backgrounded
subshell. Its `kill $pid; wait $pid` pattern is known-fragile. If you see
residual `\`, `|`, `/`, `-` characters lingering after snapshot completes,
that's a visual-only bug. If you see an orphaned background process,
that's a real bug.

---

## How to smoke test (suggested order)

1. **Fresh directory, new session.** `cd /tmp/smoke-test && mkdir proj1 &&
   cd proj1 && claudecm`. Give it a name. Exit immediately. Verify a
   session appears in `claudecm l`.

2. **Resume.** `claudecm l`, pick number 1. Verify it resumes, exit, verify
   the entry moves to top of list.

3. **Orphan detection.** Manually drop a bogus file:
   `touch ~/.claude/projects/<your-proj-key>/fake-12345678-90ab-cdef-1234-567890abcdef.jsonl`
   Then `claudecm` from the project dir. You should see the multiple-files
   menu. Use `q N` to quarantine and confirm the file moves to
   `~/claude-conversation-backup/<leaf>/`.

4. **Edit list.** `claudecm l`, press `E`. Try rename (`R1`), path change
   (`P1`), archive (`A1`), delete (`D1` with `delete` confirmation).

5. **Archive roundtrip.** Archive a session, `V` to view archived,
   unarchive with `U1`. Confirm it reappears at top of main list.

6. **Concurrent launches.** Open two terminals. `claudecm l` in each,
   pick different sessions. Do work. Exit both. Verify `sessions.txt`
   has both with correct mtimes at top and no corruption.

7. **Refresh (compaction).** In a session with ≥10k tokens, answer `y` to
   refresh on exit. Verify:
   - A new JSONL is created in the project dir.
   - The new entry is at top of `sessions.txt`.
   - The old entry is at bottom with `(old)` suffix.
   - No duplicate `(old)` labels if you refresh twice on the same chain.

8. **Resume with fork.** After a refresh, resume the new session. If
   Claude Code forks on resume, the helper should swap the GUID in
   `sessions.txt` and move the predecessor to backup. No orphan warning
   on the following `claudecm` invocation.

9. **Lock contention.** In one terminal, run
   `flock -x ~/.claudecm/sessions.txt.lock sleep 12`. In another,
   immediately run `claudecm l`. Should wait ~10s, print a yellow
   warning, then proceed.

---

## What to look for that indicates a real bug (not just unimplemented)

- `sessions.txt` contents corrupted, truncated, or missing entries after a
  normal exit.
- An entry points to a GUID whose JSONL doesn't exist anywhere on disk.
- Cross-project contamination: a session from project A shows up under
  project B's key directory.
- The orphan scan warns on every invocation despite you never having
  made any orphans.
- `Do-Trim` reports success but the new GUID isn't in the expected
  project-key directory and no red error fires. That'd be the silent
  cross-project copy bug reappearing; it MUST fail loudly per spec 11.13
  step 8.
- `claude -p` during refresh produces a non-JSON stdout and the script
  falls back to filesystem scanning. Per spec 11.14 step 14, this path
  is explicitly forbidden. If you see a new entry appear without a
  JSON-parsed `session_id`, that's a bug.
- `flock` doesn't actually lock (another shell acquires it while yours
  holds it). Would indicate NFS or odd filesystem; reconfirm filesystem
  type.

---

## What I'd like to know back

- Which bash version (`bash --version`).
- Which distro (`lsb_release -a` or `cat /etc/os-release`).
- Which `date` (GNU coreutils vs BSD).
- Whether `node` or `jq` or both were available when you tested.
- Any command that produced output you didn't expect, with the exact
  input you gave.
- Whether the smoke tests above passed in order.

If it's a real bug, include the relevant chunk of `sessions.txt` (with
any identifying paths redacted), the line number of the failing code
block, and what you expected instead.

---

## Reference material

- `claudecm-project-spec.md` — contract this script conforms to
- `claudecm-powershell.ps1` — working PowerShell implementation, known-good behavior
- `private/how my lazy ass created a bunch of race conditions, and how I plan to unfuckit.md`
  — history of the race conditions we already caught, patterns to avoid
