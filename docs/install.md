# Installation Guide

Everything here runs locally. No API keys needed beyond your existing Claude Code subscription.

## Prerequisites

All of these must be installed before you start:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [Node.js](https://nodejs.org) 18 or later (check with `node --version`)
- [Bun](https://bun.sh) (required by Claude-Mem's worker for its built-in SQLite engine)
  - Windows: `powershell -Command "irm bun.sh/install.ps1 | iex"`
  - Linux/macOS: `curl -fsSL https://bun.sh/install | bash`
  - Verify: `bun --version`
- [jq](https://github.com/jqlang/jq/releases) (required by Context-Manager hooks)
  - Windows: download the binary from the releases page and put it on your PATH
  - Linux: `sudo apt install jq` (or your package manager)
  - Verify: `jq --version`
- Git

### A note on Bun

Bun is a JavaScript runtime (like Node.js) that Claude-Mem uses for one reason: its built-in SQLite engine (`bun:sqlite`). Only the Claude-Mem background worker requires Bun; the MCP server and hooks run under Node.js.

**Security:** The worker listens on `127.0.0.1:37777` (localhost only) by default. External connections are impossible at the OS level. No firewall changes are needed. Do not change `CLAUDE_MEM_WORKER_HOST` to `0.0.0.0` unless you have a specific reason and understand the implications.

## Step 1: Claude Context Manager (Session Manager)

### Windows (PowerShell)

1. Open your PowerShell profile:
   ```powershell
   notepad $PROFILE
   ```
   If the file doesn't exist, PowerShell will ask to create it. Say yes.

2. Paste the entire contents of `claudecm-powershell.ps1` into your profile.

3. Save and open a new PowerShell window. The old window won't see the changes.

4. Type `claudecm` to launch Claude Code with session management.

### Linux

1. Create a dedicated `claude` user (if you don't already have one):
   ```bash
   sudo useradd -m -s /bin/bash claude
   ```
   Claude Code cannot run as root with `--dangerously-skip-permissions`. The script auto-detects if you're root and re-execs as the `claude` user via `sudo -u claude`. If you always run as a non-root user, you can skip this step and the re-exec will never trigger.

2. Copy the script:
   ```bash
   sudo cp claudecm-linux.sh /usr/local/bin/claudecm
   sudo chmod +x /usr/local/bin/claudecm
   ```

3. If using the `claude` user, make sure Claude Code is installed for that user and the `claude` user has access to your project directories.

4. Type `claudecm` to launch Claude Code with session management.

## Step 2: Context-Manager (Layer 1, Compaction Insurance)

```bash
# Clone
git clone https://github.com/DxTa/claude-dynamic-context-pruning.git ~/.claude-plugins/context-manager

# Build (requires jq, installed in Prerequisites above)
cd ~/.claude-plugins/context-manager && ./setup.sh

# Register the MCP server globally
claude mcp add context-manager --transport stdio -s user -- \
  node ~/.claude-plugins/context-manager/server/build/index.mjs
```

### Custom enhancement: Immutable store

After installing, edit `~/.claude-plugins/context-manager/hooks/pre-compact-save.sh`. Before the final `echo` line, add:

```bash
# Immutable store: append checkpoint to append-only log (never overwritten)
IMMUTABLE_LOG="$STATE_DIR/immutable-${CLAUDE_SESSION_ID:-current}.jsonl"
echo "$CHECKPOINT" >> "$IMMUTABLE_LOG"
```

### Custom enhancement: Deterministic escalation

Edit `~/.claude-plugins/context-manager/hooks/track-tool-usage.sh`. Before the final "Emit combined additionalContext" block, add:

```bash
# Deterministic compaction escalation
TOTAL_TOKENS=$(jq '[.tool_token_costs // {} | .[]] | add // 0' "$STATE_FILE" 2>/dev/null || echo "0")
TOTAL_TOKENS=${TOTAL_TOKENS:-0}

SOFT_THRESHOLD=120000
HARD_THRESHOLD=160000

if [[ "$TOTAL_TOKENS" -ge "$HARD_THRESHOLD" ]]; then
  ESCALATION_MSG="[CONTEXT-CRITICAL] Estimated tool output tokens: ${TOTAL_TOKENS}. Hard threshold (${HARD_THRESHOLD}) exceeded. Run 'cmv trim' NOW or context quality will degrade. Consider saving a checkpoint first: 'cmv snapshot \"pre-trim\"'."
  if [[ -n "$CONTEXT_MSG" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG} ${ESCALATION_MSG}"
  else
    CONTEXT_MSG="$ESCALATION_MSG"
  fi
elif [[ "$TOTAL_TOKENS" -ge "$SOFT_THRESHOLD" ]]; then
  ESCALATION_MSG="[CONTEXT-WARNING] Estimated tool output tokens: ${TOTAL_TOKENS}. Approaching capacity. Consider running 'cmv snapshot' to preserve state, then 'cmv trim' to free space."
  if [[ -n "$CONTEXT_MSG" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG} ${ESCALATION_MSG}"
  else
    CONTEXT_MSG="$ESCALATION_MSG"
  fi
fi
```

## Step 3: CMV (Layer 2, Virtual Memory for Context)

```bash
# Clone and build
git clone https://github.com/CosmoNaught/claude-code-cmv.git ~/.claude-plugins/cmv
cd ~/.claude-plugins/cmv
npm install && npm run build
npm link

# Verify
cmv --version
cmv hook status
```

Windows note: if `cmv` isn't found after `npm link`, reopen your terminal and check that `%APPDATA%\npm` is on your PATH.

## Step 4: Claude-Mem (Layer 3, Cross-Session Memory)

```bash
# Clone and build
git clone https://github.com/thedotmack/claude-mem.git ~/.claude-plugins/claude-mem
cd ~/.claude-plugins/claude-mem
npm install
npm run build

# Register MCP server globally
claude mcp add claude-mem --transport stdio -s user -- \
  node ~/.claude-plugins/claude-mem/plugin/scripts/mcp-server.cjs
```

Claude-Mem's background worker requires Bun (installed in Prerequisites above). Verify it's available before proceeding:
```bash
bun --version
```

## Step 5: Prompt Booster

Copy the contents of `prompt-booster.txt` into your global Claude config:

```
~/.claude/CLAUDE.md
```

Create the file if it doesn't exist. This loads once per session and applies to all projects.

## Step 6: Verify

Restart Claude Code, then:

1. Run `/mcp` and confirm both `context-manager` and `claude-mem` appear and show connected. (CMV is a CLI tool, not an MCP server; it won't appear in this list.)
2. Run `cmv hook status` in a terminal to confirm CMV hooks are installed.
3. Run `cmv --version` to confirm it's accessible.
4. Start a session with `claudecm` and work normally. The tools run automatically in the background.
5. When you exit the session, ClaudeCM will prompt you to:
   - Add/edit notes for next time
   - **Trim** the session (strips tool output bloat, keeps your conversation)
   - **Refresh** the session (starts completely fresh, old session preserved and accessible)

## What to Expect

- Context-Manager hooks fire automatically before and after compaction. You don't need to do anything.
- CMV auto-trims when context gets heavy. You can also manually run `cmv snapshot` and `cmv trim`.
- Claude-Mem captures observations in the background and injects relevant memories on session start.
- The escalation warnings will appear as advisory messages when your session approaches token thresholds.

## Troubleshooting

**jq not found:** Make sure jq is on your PATH. Context-Manager hooks won't work without it.

**cmv not found:** Run `npm link` again from the cmv directory, then reopen your terminal.

**PostToolUse:Write hook error (cmv):** Claude Code hooks run in non-interactive shells that don't source `.bashrc`, so custom PATH entries (like `~/.npm-global/bin`) aren't available. Fix: rebuild and re-run postinstall to write the absolute path into the hooks:
```bash
cd ~/.claude-plugins/cmv && npm run build && node dist/postinstall.js
```
Verify with: `cat ~/.claude/settings.json` (the hook commands should show a full path, not bare `cmv`).

**Claude-Mem worker not starting:** Check that Bun is installed and on your PATH. Run `bun --version` to verify.

**Hooks not firing:** Run `cmv hook status` and check that both PreCompact and PostToolUse show as installed. For Context-Manager, the hooks are registered via the MCP server config.
