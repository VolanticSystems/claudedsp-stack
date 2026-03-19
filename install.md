# Installation Guide

Everything here runs locally. No API keys needed beyond your existing Claude Code subscription.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [Node.js](https://nodejs.org) 18 or later
- Git

## Step 1: ClaudeDSP (Session Manager)

### Windows (PowerShell)

1. Open your PowerShell profile:
   ```powershell
   notepad $PROFILE
   ```
   If the file doesn't exist, PowerShell will ask to create it. Say yes.

2. Paste the entire contents of `claudedsp-powershell.ps1` into your profile.

3. Save and open a new PowerShell window. The old window won't see the changes.

4. Type `claudedsp` to launch Claude Code with session management.

### Linux

1. Create a dedicated `claude` user (if you don't already have one):
   ```bash
   sudo useradd -m -s /bin/bash claude
   ```
   Claude Code cannot run as root with `--dangerously-skip-permissions`. The script auto-detects if you're root and re-execs as the `claude` user via `sudo -u claude`. If you always run as a non-root user, you can skip this step and the re-exec will never trigger.

2. Copy the script:
   ```bash
   sudo cp claudedsp-linux.sh /usr/local/bin/claudedsp
   sudo chmod +x /usr/local/bin/claudedsp
   ```

3. If using the `claude` user, make sure Claude Code is installed for that user and the `claude` user has access to your project directories.

4. Type `claudedsp` to launch Claude Code with session management.

## Step 2: Context-Manager (Layer 1, Compaction Insurance)

```bash
# Clone
git clone https://github.com/DxTa/claude-dynamic-context-pruning.git ~/.claude-plugins/context-manager

# Install jq if you don't have it
# Windows: download from https://github.com/jqlang/jq/releases to a folder on your PATH
# Linux: sudo apt install jq (or your package manager)

# Build
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

Claude-Mem requires Bun for its background worker. If you don't have it:
- Windows: `powershell -Command "irm bun.sh/install.ps1 | iex"`
- Linux: `curl -fsSL https://bun.sh/install | bash`

The smart-install hook will also auto-install Bun on first session start if it's missing.

## Step 5: Prompt Booster

Copy the contents of `prompt-booster.txt` into your global Claude config:

```
~/.claude/CLAUDE.md
```

Create the file if it doesn't exist. This loads once per session and applies to all projects.

## Step 6: Verify

Restart Claude Code, then:

1. Run `/mcp` and confirm both `context-manager` and `claude-mem` appear and show connected.
2. Run `cmv hook status` in a terminal to confirm CMV hooks are installed.
3. Start a session and work normally. The tools run automatically in the background.

## What to Expect

- Context-Manager hooks fire automatically before and after compaction. You don't need to do anything.
- CMV auto-trims when context gets heavy. You can also manually run `cmv snapshot` and `cmv trim`.
- Claude-Mem captures observations in the background and injects relevant memories on session start.
- The escalation warnings will appear as advisory messages when your session approaches token thresholds.

## Troubleshooting

**jq not found:** Make sure jq is on your PATH. Context-Manager hooks won't work without it.

**cmv not found:** Run `npm link` again from the cmv directory, then reopen your terminal.

**Claude-Mem worker not starting:** Check that Bun is installed and on your PATH. Run `bun --version` to verify.

**Hooks not firing:** Run `cmv hook status` and check that both PreCompact and PostToolUse show as installed. For Context-Manager, the hooks are registered via the MCP server config.
