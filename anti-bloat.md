# Anti-Bloat Strategy for ClaudeDSP Sessions

## The Problem

Long-running ClaudeDSP sessions accumulate context that costs tokens on every resume. Sources of bloat:

1. **Conversation history**: debugging sessions, monitoring runs, repeated tool outputs, arguments, dead-end explorations. Most of this is noise after the work is done.

2. **System reminders**: Claude Code injects the full source of every modified file as system-reminder blocks on each resume. A project with 15 modified files can add 30,000+ tokens of file content that gets loaded every time.

3. **Context plugins** (context-manager, claude-mem, CMV): each adds data that persists across resumes. context-manager restores checkpoints after compaction (2,000-5,000 tokens per cycle). claude-mem accumulates compressed memories that only grow (100-300 tokens per session interaction). CMV adds snapshot metadata (500-1,500 tokens). Net effect over weeks: 3,000-8,000 tokens of plugin overhead per session.

4. **Cron jobs resuming conversations**: a cron job that resumes a large Opus session every 15 minutes burns thousands of tokens per invocation, even when nothing is happening. This was the single biggest token drain observed in the zoom-away project.

## Measured Impact

In the zoom-away project, a cron monitoring job resuming a large Opus conversation every 15 minutes consumed roughly half of the weekly token allocation in two days. Most invocations found nothing to do but still paid the full context loading cost.

## Solutions

### 1. Session Trimming at Exit (add to claudedsp-linux.sh)

After Claude exits and the notes prompt completes, add a trim prompt:

```
Would you like to trim this session? (y/N):
```

If yes:
- Run `cmv trim --latest --skip-launch`
- Capture the new (trimmed) session GUID from the output line `Session ID: <guid>`
- Replace the old GUID with the new one in `sessions.txt`
- The snapshot preserves the full history (recoverable via `cmv list`)
- Next resume loads the trimmed version automatically

What trim removes:
- Tool result outputs (file contents, command outputs, search results)
- Thinking signatures
- File history entries
- Image blocks (base64 screenshots)
- Tool use input blocks above a configurable threshold

What trim keeps:
- All user messages
- All assistant responses (the actual conversation)
- Tool use requests (what was done, not the verbose output)

Expected reduction: 60-85% for development sessions with heavy file reading and debugging.

### 2. Lightweight Cron Monitoring (avoid resuming heavy sessions)

For automated monitoring (e.g., checking if recordings are running):

**Do not** resume a development session on a cron job. Instead:

- Use a bash wrapper that checks preconditions first (e.g., `docker ps`). If nothing needs attention, exit without invoking Claude at all.
- If Claude is needed, use a separate session dedicated to monitoring, on Haiku (not Opus). Fresh context, minimal history.
- Store the monitoring prompt in a file (e.g., `cronjob.md`) and pass it with `--file`. The prompt is the only context; no conversation history accumulates.

Pattern for `claudedsp-headless`:
```bash
# Check if there's anything to monitor
if ! docker ps --filter "name=zoom-away" --quiet | grep -q .; then
    exit 0  # Nothing running, zero tokens spent
fi

# Only now invoke Claude, on the cheap model
claude --model haiku -p "$(cat /path/to/cronjob.md)"
```

Note: this uses a fresh invocation (`-p`), not a resumed session (`--resume`). No conversation history, no plugin overhead, no system reminders from previous work.

### 3. Periodic Fresh Starts for Active Projects

For projects with heavy daily development (like zoom-away):

- Every 1-2 weeks, start a new session
- All knowledge persists in: memory files (MEMORY.md), code (git), documentation (QA reviews, project spec), and git history
- The conversation history is the only thing lost, and after a trim + fresh start, 90% of it was noise

For dormant sessions (sysadmin, one-off fixes):

- Leave them as-is. They're small, infrequently resumed, and the context they preserve is genuinely valuable when you need it 6 months later
- Trim them once if they've accumulated debugging noise, then let them sit

### 4. Plugin Hygiene

**context-manager**: Use `save_checkpoint` at meaningful milestones, not constantly. Each checkpoint adds to the post-compaction restore payload. Use `mark_complete` to signal that a subtask's detailed context can be dropped.

**claude-mem**: Observations accumulate forever. Periodically review what's stored and prune stale entries. No automatic cleanup exists; this is manual.

**CMV**: The trim feature is the main anti-bloat tool. Snapshots are cheap (stored on disk, not in context). Use snapshots freely, trim when context gets heavy.

### 5. Instrumentation Gap

Currently, there is no way to see the actual token count of a conversation from inside the session. The `get_context_stats` tool from context-manager only tracks what it instruments (checkpoints, subtasks), not the actual conversation size.

Desired instrumentation:
- Token count of the current conversation (input tokens on next resume)
- Breakdown: conversation history vs system reminders vs plugin data
- Trend over time (is this session growing? by how much per interaction?)

This would require either Claude Code exposing token metrics, or building an approximation by measuring the JSONL transcript file size and estimating tokens (roughly 4 chars per token).

## Feature Request: "New Session" Option in claudedsp

Currently, after Claude exits, claudedsp only offers to rename the session. It should also offer the option to start a new session in the same project directory, for cases where a conversation has become bloated and the user wants a fresh start while keeping all project files, memories, and documentation intact.

Proposed flow after Claude exits:
```
Session saved.
  (r) Rename this session
  (n) Start a new session in the same directory (fresh context, same project)
  (Enter) Done
```

If the user picks (n):
- The current session stays in sessions.txt (accessible for reference)
- A new Claude session is launched in the same working directory
- The new session gets a new GUID and clean context
- After the new session exits, it's saved to sessions.txt as a new entry
- The user can provide a name like "Zoom Away v2"

This complements the trim feature: trim reduces an existing session's bloat, while "new session" starts completely fresh when the bloat is beyond trimming.

## Implementation Priority

1. **Add trim prompt to claudedsp exit flow** (immediate, biggest impact)
2. **Rewrite cron jobs to use fresh Haiku invocations** (immediate, stops the bleed)
3. **Fresh session for zoom-away** (immediate, this session is bloated beyond recovery)
4. **Add token estimation from transcript file size** (nice to have, helps make informed decisions)
5. **Plugin hygiene review across all 22 sessions** (periodic, low priority)
