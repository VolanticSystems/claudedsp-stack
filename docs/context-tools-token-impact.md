# Context Tools: Token Impact and How They Actually Work

A detailed breakdown of how the three-layer context stack (Context-Manager, CMV, Claude-Mem) interacts with Claude Code sessions, what triggers each component, and the real token cost.

## The Short Answer

The three tools are designed to be lightweight. Most of their work happens outside the session via shell hooks and background processes that never touch the conversation context. The MCP tools that do live inside the session are deferred by default (since Claude Code v2.1.69) and only load their schemas when actually called.

## Two Execution Layers

Every component in the stack operates through one or both of these layers:

### Layer A: Shell Hooks (Zero Token Cost)

Shell hooks are bash/PowerShell commands configured in `~/.claude/settings.json`. Claude Code's harness runs them as external processes. They communicate via stdin/stdout JSON with the harness, not with Claude's conversation. Claude never sees them execute and they never appear in the transcript.

### Layer B: MCP Tools (Token Cost Only When Called)

MCP tools are registered with Claude Code and available for Claude to call within a conversation. Since v2.1.69, all MCP tools are deferred by default: Claude sees only the tool name until it actually needs to call one, at which point the full schema is fetched via ToolSearch.

## Context-Manager

**Architecture:** Shell hooks + MCP server

### Shell Hooks (Layer A, zero token cost)

| Hook | Event | What It Does |
|------|-------|-------------|
| pre-tool-dedup.sh | PreToolUse (Read/Write/Edit) | Tracks how many times each file is read. 1st: silent. 2nd: warning. 3rd: truncates to 50 lines. 4th+: blocks. Write resets the counter. |
| track-tool-usage.sh | PostToolUse (Read/Write/Edit/Bash/Grep/Glob/WebFetch/WebSearch) | Estimates token cost per tool output (response bytes / 4). Accumulates total. Emits advisory at 120K (soft) and 160K (hard) thresholds. |
| pre-compact-save.sh | PreCompact | Reads the conversation transcript. Extracts files modified, task state, decisions, errors. Saves structured checkpoint to JSON and appends to immutable log. |
| post-compact-restore.sh | SessionStart (after compaction) | Reads the most recent checkpoint. Injects a human-readable recovery summary into the fresh post-compaction context. |
| post-tool-failure.sh | PostToolUseFailure | Tracks repeated command failures. 2nd failure: "try something different." 3rd+: blocks retries. |

These hooks operate entirely through filesystem I/O using jq. They do not call MCP tools. They do not load tool schemas. They add zero tokens to the conversation, except for the advisory messages they inject via the hook framework's `additionalContext` field (typically a single sentence).

### MCP Tools (Layer B, deferred, loaded only on demand)

| Tool | When Claude Calls It | Typical Trigger |
|------|---------------------|----------------|
| save_checkpoint | When Claude wants to explicitly save state | User asks, or Claude decides to before a risky operation |
| load_checkpoint | After compaction, to retrieve full checkpoint data | Post-compaction recovery (Claude reads the hook's summary and may want more detail) |
| get_context_stats | When Claude wants to check session health | User asks about context size, or Claude is prompted by a threshold advisory |
| mark_complete | When a subtask is done | Claude marks progress |
| list_checkpoints | When Claude wants to see what checkpoints exist | User asks, or during recovery |
| track_tool_usage | Manual duplicate of what the hook does | Rarely used; the hook handles this automatically |
| generate_compact_instructions | When generating targeted /compact guidance | During high context pressure |

None of these tools load automatically. They are fetched via ToolSearch only when Claude decides to call one. In a session where compaction never happens and the user never asks about context stats, these tools are never loaded and cost zero tokens.

### Token Impact

- **Per-turn overhead from hooks:** Effectively zero. Hook scripts run externally.
- **Advisory messages from hooks:** A few tokens when thresholds are crossed (a sentence or two injected into context).
- **MCP tool schemas if loaded:** ~200-300 tokens per tool, only for tools actually called.
- **Typical session where compaction doesn't happen:** Near zero total impact.
- **Session where compaction fires:** Maybe 500-800 tokens for the 2-3 tools involved in checkpoint save/restore.

## CMV (Contextual Memory Virtualisation)

**Architecture:** CLI tool + shell hooks. No MCP server at all.

### Shell Hooks (Layer A, zero token cost)

| Hook | Event | What It Does |
|------|-------|-------------|
| cmv auto-trim --check-size | PostToolUse (all tools) | Checks if the session JSONL file exceeds ~600KB. If not, exits immediately (~1ms). If yes, trims tool output bloat from the JSONL on disk. |
| cmv auto-trim | PreCompact | Trims the session JSONL before compaction fires, so compaction operates on a leaner transcript. |

CMV's hooks are completely silent. They modify the session JSONL file on disk but inject nothing into the conversation. Claude has no idea they ran. There is no MCP server, no tool schemas, no ToolSearch interaction.

### What Trimming Removes

- Tool result bodies longer than 500 characters (replaced with summary placeholders)
- Thinking block cryptographic signatures
- File history snapshots
- Image blocks
- Orphaned tool results
- API metadata

### What Trimming Preserves

- All user messages (verbatim)
- All Claude responses (verbatim)
- Tool call requests (the arguments Claude sent)
- Thinking text (the reasoning, not the signatures)

### Backup System

Before every trim, CMV saves a backup in `~/.cmv/auto-backups/`. Keeps up to 5 per session. Restorable via `cmv hook restore <session-id>`.

### Token Impact

- **Per-turn overhead:** Zero. No MCP tools, no schema loading, no conversation injection.
- **Cache miss cost after a trim:** One-time penalty on the next turn (the prompt prefix changed, so Claude's API cache misses). For subscription users, this has no cost impact. For API users, the break-even is 3-10 turns for tool-heavy sessions.
- **Context savings from trimming:** Median 12% reduction, mean 20%. Tool-heavy sessions can see up to 86% reduction.

## Claude-Mem

**Architecture:** MCP server + shell hooks + background worker process.

### Background Worker

A Bun process that runs on `127.0.0.1:37777`. Started on demand by the SessionStart hook, not always running. Manages a SQLite database of observations and provides an HTTP API for storing and querying them.

### Shell Hooks (Layer A, zero token cost to conversation)

| Hook | Event | What It Does |
|------|-------|-------------|
| smart-install.js | SessionStart | Ensures Bun is installed |
| worker-service.cjs start | SessionStart | Spawns the background worker daemon |
| context handler | SessionStart | Fetches relevant past observations from the worker and injects them as context |
| session-init.ts | UserPromptSubmit | Creates a session record in the worker's database |
| observation.ts | PostToolUse (all tools) | Sends tool usage data to the worker for storage |
| summarize.ts | Stop | Generates an AI-compressed summary of the session |
| session-complete.ts | Stop / SessionEnd | Closes the session record in the database |

The SessionStart context injection is the one hook that does add tokens to the conversation. It fetches compressed observations from previous sessions and injects them so Claude has cross-session memory. The size depends on how many relevant past observations exist, but Claude-Mem's design compresses aggressively (AI-generated semantic summaries, not raw transcripts).

The PostToolUse hook (observation.ts) sends data to the worker via HTTP but does not inject anything into the conversation. It's fire-and-forget capture.

### MCP Tools (Layer B, deferred, loaded only on demand)

| Tool | Purpose | When Called |
|------|---------|------------|
| __IMPORTANT | Displays workflow instructions for the 3-layer search pattern | Only if Claude fetches it via ToolSearch. Passive. No side effects. Empty input schema. |
| search | Step 1: lightweight index search, returns IDs | When Claude or user wants to search past memories |
| timeline | Step 2: chronological context around a result | After search, to get surrounding context |
| get_observations | Step 3: full details for specific IDs | After filtering, to get complete observation data |
| smart_search | Tree-sitter AST search for code symbols | When Claude wants structural code search |
| smart_unfold | Expand a specific code symbol | After smart_search, to see full source |
| smart_outline | Get folded structural outline of a file | When Claude wants a file overview |

None of these load automatically. The `__IMPORTANT` tool, despite its name, is completely passive. It has no parameters and no side effects. It only returns instructions if Claude explicitly calls it.

### Token Impact

- **SessionStart context injection:** Variable. Depends on relevant past observations. Could be a few hundred tokens for a project with minimal history, or a few thousand for a project with extensive past sessions. This is the primary token cost of Claude-Mem, and it's the whole point of the tool (cross-session memory).
- **PostToolUse observation capture:** Zero conversation tokens. Data goes to the worker via HTTP.
- **MCP tool schemas if loaded:** ~200-300 tokens per tool, only for tools actually called. In sessions where the user never asks Claude to search memory, these are never loaded.
- **Typical session:** Only the SessionStart context injection costs tokens. Everything else is external.

## Summary: Total Token Impact

### System Prompt Overhead (every turn)

With deferred loading (default since v2.1.69):

| Component | Tools in Deferred List | System Prompt Cost |
|-----------|----------------------|-------------------|
| Context-Manager | 7 tool names | ~50-70 tokens |
| Claude-Mem | 6 tool names | ~40-60 tokens |
| CMV | None (no MCP tools) | 0 tokens |
| **Total** | **13 tool names** | **~90-130 tokens** |

Without deferred loading (if the bug at [anthropics/claude-code#36914](https://github.com/anthropics/claude-code/issues/36914) is triggered):

| Component | Full Schema Cost |
|-----------|-----------------|
| Context-Manager | ~1,500-2,000 tokens |
| Claude-Mem | ~1,500-2,000 tokens |
| CMV | 0 tokens |
| **Total** | **~3,000-4,000 tokens per turn** |

### Per-Session One-Time Costs

| Source | Tokens | When |
|--------|--------|------|
| Claude-Mem SessionStart context injection | Variable (hundreds to low thousands) | Session start |
| Post-compaction recovery summary | 200-500 tokens | After compaction |
| Threshold advisory messages | 50-100 tokens each | When soft/hard thresholds crossed |

### Tool Schema Loading (only when used)

| Scenario | Tools Loaded | Added Cost Per Turn |
|----------|-------------|-------------------|
| Normal session, no compaction, no memory search | 0 tools | 0 tokens |
| Compaction fires | 2-3 tools (save/load checkpoint, maybe generate_compact) | 400-800 tokens |
| User asks to search memory | 1-3 tools (search, maybe timeline, get_observations) | 200-800 tokens |
| User asks about context stats | 1 tool (get_context_stats) | 200-300 tokens |

### Over a Week (20 sessions, 75 turns average)

Assuming deferred loading works correctly:

- **Deferred tool names:** ~100 tokens x 1,500 turns = 150K tokens (0.15% of a weekly budget)
- **SessionStart injections:** ~1,000 tokens x 20 sessions = 20K tokens
- **Occasional tool schema loads:** Maybe 5 compactions, 10 memory searches = ~8K tokens
- **Total stack overhead:** ~178K tokens per week

Compare to total tokens exchanged in a week (rough estimate 60-100M tokens): the three-layer stack adds about **0.2-0.3%** overhead when deferred loading is working.

If deferred loading breaks and all schemas load eagerly, that jumps to roughly **5-7%** overhead, driven almost entirely by the ~4,000 tokens of tool definitions repeated on every turn.

## How to Verify Your Setup

Check whether your MCP tools are deferred in a session. At the start of any session, the system will list deferred tools. If you see entries like:

```
mcp__context-manager__save_checkpoint
mcp__context-manager__load_checkpoint
...
mcp__claude-mem__search
mcp__claude-mem__timeline
...
```

in the deferred tools list, deferred loading is working and your per-turn overhead is minimal.

If those tools don't appear in the deferred list but instead show up as full tool definitions in the system prompt, deferred loading isn't working for your MCP servers and you're paying the full schema cost every turn.
