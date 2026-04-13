# Claude Code Context Management Tools — Comparison & Recommendations

## The Problem

Claude Code sessions run in a fixed context window. When it fills up, compaction fires — the conversation gets summarized and compressed, freeing ~60-70% of the context. But summaries lose detail. File paths, debugging state, key decisions, error patterns — all of it can vanish. The longer and more complex the session, the worse the loss.

Several tools have emerged to address this from different angles. Some prevent context loss during compaction, some preserve memory across sessions, some reduce token waste, and some restructure how context is managed entirely.

---

## 1. Context-Manager (DxTa/claude-dynamic-context-pruning)

**What it does:** Checkpoint-based compaction protection. Hooks fire before and after compaction to save and restore structured session state.

**How it works:**
- PreCompact hook extracts state from the transcript: files modified, task state, decisions (marked with `[DECISION]`/`[PRESERVE]`), repeated failed commands
- PostCompact hook injects a structured recovery summary into the new context
- PreToolUse hook tracks duplicate file reads with graduated enforcement: warn at 2, truncate at 3, block at 4 (resets on Write/Edit)
- PostToolUse hook tracks all tool usage for dedup and token cost estimation
- PostToolUseFailure hook detects repeated failures and escalates: strategy-shift at 2, hard block at 3

**Storage:** `.claude/context-state/session-<GUID>.json` per project

**Tech:** Bash hook scripts + Node.js MCP server. Requires `jq`.

**Repo:** https://github.com/DxTa/claude-dynamic-context-pruning

---

## 2. MCP Memory Keeper (mkreyman/mcp-memory-keeper)

**What it does:** Persistent context management across sessions using SQLite. Tracks work history, decisions, progress, and file changes with git integration.

**How it works:**
- SQLite database (context.db) for persistent storage, auto-created per project
- Session management with start/end tracking
- File content caching with change detection
- Checkpoint system for complete context snapshots
- Intelligent compaction to prevent critical information loss
- Git integration for automatic context correlation
- Full-text and semantic search across stored context

**Storage:** `~/mcp-data/memory-keeper/`

**Tech:** Node.js MCP server with SQLite backend

**Compatibility:** Claude Code, Gemini CLI, VS Code Copilot, OpenCode, Codex CLI

**Repo:** https://github.com/mkreyman/mcp-memory-keeper

---

## 3. Claude-Mem (thedotmack/claude-mem)

**What it does:** Automatic session capture and AI-compressed memory injection. Captures everything Claude does, compresses it into dense summaries, and injects relevant context into future sessions.

**How it works:**
- Runs alongside Claude Code, observing all tool usage
- Captures observations (file modifications, decisions, tool calls)
- Uses Claude's agent-sdk to compress observations into semantic summaries (not raw transcripts)
- Token-efficient 3-layer workflow: capture -> compress -> inject
- Intelligent memory search through 4 MCP tools
- Beta "Endless Mode" — biomimetic memory architecture for extended sessions that would normally hit context limits after ~50 tool uses

**Storage:** Local per-project

**Tech:** Node.js, Claude agent-sdk for compression

**Repo:** https://github.com/thedotmack/claude-mem

---

## 4. Claude Memory MCP (randall-gross/claude-memory-mcp)

**What it does:** Local knowledge graph database. Stores entities, relationships, and observations in a SQLite-backed graph structure.

**How it works:**
- Entities (files, concepts, decisions, people) stored as graph nodes
- Relations between entities stored as edges
- Observations attached to entities over time
- Graph traversal for exploring connections
- Search for specific nodes by content or relationship
- Persistent across all sessions

**Storage:** Local SQLite graph database

**Tech:** Node.js MCP server with SQLite

**Repo:** https://github.com/randall-gross/claude-memory-mcp (via LobeHub)

---

## 5. Memory Store Plugin (julep-ai/memory-store-plugin)

**What it does:** Automatic development workflow tracking. Categorizes and stores file changes, session metrics, and architectural decisions.

**How it works:**
- Auto-tracks session start (project state, git branch, file count)
- Auto-tracks session end (duration, files changed, commits, quality score)
- Auto-loads context from previous sessions on startup
- Tracks Write/Edit operations with language and pattern detection
- Categorizes changes (feature, bugfix, refactor, config)
- Remembers architectural decisions and team conventions

**Storage:** Via Memory Store MCP server

**Tech:** Node.js MCP plugin

**Repo:** https://github.com/julep-ai/memory-store-plugin

---

## 6. Claude Context (zilliztech/claude-context)

**What it does:** Semantic code search across your entire codebase. Indexes code into a vector database and serves contextually relevant snippets.

**How it works:**
- Indexes entire codebase into embeddings
- Hybrid search: BM25 (keyword) + dense vector (semantic)
- Natural language queries like "find functions that handle user authentication"
- ~40% token reduction vs naive file reading at equivalent retrieval quality
- Multiple embedding providers: OpenAI, VoyageAI, Ollama, Gemini
- Multiple vector DB backends: Milvus or Zilliz Cloud
- Also available as VS Code extension

**Storage:** Vector database (Milvus/Zilliz Cloud or local)

**Tech:** Node.js MCP server, monorepo with core engine + VSCode ext + MCP server

**Repo:** https://github.com/zilliztech/claude-context

---

## 7. Volt / LCM — Lossless Context Management (Voltropy/volt)

**What it does:** A complete alternative coding agent (not a plugin) built around a dual-state memory architecture that eliminates lossy compaction entirely.

**How it works:**
- **Immutable Store:** Every message persisted verbatim — nothing is ever deleted
- **Active Context:** A curated window of what's actually sent to the LLM each turn
- Compaction happens asynchronously between turns using a deterministic control loop
- Soft/hard token thresholds with three-level escalation protocol
- DAG-based summarization instead of flat transcript compression
- Forked from OpenCode (TypeScript, provider-agnostic, terminal UI)

**Benchmarks:** On OOLONG long-context benchmark, Volt + Opus 4.6 beat Claude Code at every context length from 32K to 1M tokens (+29.2 vs +24.7 average improvement)

**Paper:** "Lossless Context Management" by Clint Ehrlich and Theodore Blackman at Voltropy PBC, published February 14, 2026

**Repo:** https://github.com/voltropy/volt (mirrored at Martian-Engineering/volt)

---

## 8. Lossless-Claw (Martian-Engineering/lossless-claw)

**What it does:** An OpenClaw plugin that replaces the built-in sliding-window compaction with DAG-based summarization from the LCM paper.

**How it works:**
- Drop-in replacement for OpenClaw's compaction system
- Uses the same DAG-based summarization as Volt/LCM
- Maintains structural relationships between conversation elements
- Lossless — preserves all semantic content while reducing token count

**Relevance:** Directly applicable if using OpenClaw/Claude Code ecosystem

**Repo:** https://github.com/Martian-Engineering/lossless-claw

---

## 9. CMV — Contextual Memory Virtualisation (CosmoNaught/claude-code-cmv)

**What it does:** Virtual memory for Claude Code sessions. Models session history as a DAG with snapshot, branch, and trim primitives.

**How it works:**
- Treats context like virtual memory — pages understanding in and out of the active window
- Named snapshots you can return to, branch from, and trim down
- DAG-based state management with formally defined primitives
- Trimming preserves every user message and assistant response verbatim
- Strips mechanical bloat (raw tool outputs, base64 images, metadata)
- Benchmarked: mean 20% reduction, up to 86% for tool-heavy sessions
- Real-world validation: ~50% context reduction with zero conversation loss across 33 sessions
- Enables parallel session branching — teammates can import snapshots and branch independently

**Paper:** Published on arXiv (2602.22402)

**Feature request:** https://github.com/anthropics/claude-code/issues/27293

**Repo:** https://github.com/CosmoNaught/claude-code-cmv

---

## Comparison Table

| Tool | Domain | Approach | Persistence | Within-Session | Cross-Session | Requires |
|------|--------|----------|-------------|----------------|---------------|----------|
| Context-Manager | Compaction protection | Checkpoint hooks | JSON files | Yes | No | jq, bash, Node.js |
| Memory Keeper | Full context management | SQLite + git | SQLite DB | Yes | Yes | Node.js |
| Claude-Mem | Auto memory capture | AI compression | Local files | Yes | Yes | Node.js, agent-sdk |
| Claude Memory MCP | Knowledge graph | Graph DB | SQLite graph | No | Yes | Node.js |
| Memory Store | Dev workflow tracking | Auto-tracking | Memory Store | Yes | Yes | Node.js |
| Claude Context | Code search | Vector embeddings | Vector DB | Yes | Yes | Node.js, embedding API |
| Volt/LCM | Full agent replacement | Dual-state memory | Immutable store | Yes | Yes | TypeScript runtime |
| Lossless-Claw | Compaction replacement | DAG summarization | DAG store | Yes | Partial | OpenClaw |
| CMV | Context virtualisation | DAG + snapshots | DAG snapshots | Yes | Yes (via snapshots) | Node.js |

---

## Pros and Cons

### Context-Manager
- **Pros:** Simple, lightweight, already installed. Hooks are automatic — no manual work needed. Dedup tracking prevents context waste. Graduated read-blocking is clever.
- **Cons:** Checkpoint quality depends on transcript parsing. No cross-session memory. Bash scripts may be fragile on some setups.

### Memory Keeper
- **Pros:** SQLite is rock-solid storage. Git integration is natural for dev workflows. Search capabilities are strong. Multi-tool compatibility.
- **Cons:** Heavier footprint than checkpoint-based tools. Another database to manage. May overlap with Claude's built-in memory system.

### Claude-Mem
- **Pros:** AI-compressed summaries are smarter than mechanical extraction. Endless Mode addresses the ~50 tool-use wall. Fully automatic capture.
- **Cons:** Uses Claude API calls for compression (cost). Agent-sdk dependency. Beta features may be unstable. AGPL license.

### Claude Memory MCP
- **Pros:** Graph structure captures relationships that flat storage misses. Good for complex multi-project knowledge. Queryable.
- **Cons:** Requires manual entity/relation management or additional tooling. Overkill for single-session work. More about "what do I know" than "what was I doing."

### Memory Store Plugin
- **Pros:** Fully automatic tracking. Good metrics (duration, quality score, commit correlation). Categorizes changes intelligently.
- **Cons:** Newer, less battle-tested. Depends on Memory Store MCP server. Less focused on compaction survival.

### Claude Context
- **Pros:** 40% token reduction is significant. Semantic search beats grep for understanding intent. Scales to large codebases.
- **Cons:** Requires embedding API (cost, unless using Ollama). Vector DB setup. Solves code discovery, not context preservation. Different problem domain.

### Volt/LCM
- **Pros:** The only truly lossless solution. Benchmark-proven improvements. Immutable store means nothing is ever lost. Deterministic compaction.
- **Cons:** Replaces Claude Code entirely — not a plugin. Different tool, different ecosystem. Provider-agnostic but you lose Claude Code's specific integrations.

### Lossless-Claw
- **Pros:** Drop-in compaction replacement. DAG-based is fundamentally better than sliding-window. Direct LCM paper implementation.
- **Cons:** OpenClaw-specific. May not work with standard Claude Code without adaptation.

### CMV
- **Pros:** Strongest theoretical foundation (arXiv paper). Snapshot/branch model enables team workflows. Up to 86% reduction with zero loss. Virtual memory metaphor is intuitive.
- **Cons:** Relatively new. DAG management adds complexity. Branching features may be overkill for solo work.

---

## Domain Classification

| Domain | Best Tools |
|--------|-----------|
| **Surviving compaction (within-session)** | Context-Manager, CMV, Claude-Mem (Endless Mode) |
| **Cross-session memory** | Memory Keeper, Claude-Mem, Memory Store, Claude Memory MCP |
| **Knowledge management** | Claude Memory MCP (graph), Memory Keeper (SQLite) |
| **Code discovery / search** | Claude Context (semantic), built-in Grep/Glob |
| **Fundamental architecture change** | Volt/LCM, Lossless-Claw, CMV |
| **Team / parallel workflows** | CMV (branching), Memory Keeper (git integration) |
| **Token efficiency** | Claude Context (-40%), CMV (-20 to -86%), Claude-Mem (compression) |

---

## Recommendations

Tools that complement each other well can be stacked. The table below is ordered by overall value for a power user running multiple Claude Code sessions across projects.

| Rank | Tool | Why | Install Effort | Stacks With |
|------|------|-----|---------------|-------------|
| 1 | **Context-Manager** | Already installed. Automatic compaction protection with zero manual work. The dedup and failure-tracking hooks prevent context waste before it happens. Foundation layer. | Done | Everything |
| 2 | **CMV** | Best-in-class context reduction with formal guarantees. Snapshot/restore model fits naturally with Claude Context Manager's session management. The virtual memory metaphor matches how you already think about sessions. | Medium | Context-Manager, Memory Keeper |
| 3 | **Claude-Mem** | AI-compressed cross-session memory without manual work. Endless Mode directly addresses the "runs out of context right when you're about to code" problem. | Low | Context-Manager, CMV |
| 4 | **Memory Keeper** | Solid cross-session persistence with git integration. Good for projects where you return weeks later and need to remember architectural decisions. SQLite is reliable. | Low | Context-Manager, Claude-Mem |
| 5 | **Claude Context** | Worth it for large codebases where semantic search beats grep. The 40% token reduction is real savings. Not a context-preservation tool but reduces how much context you need in the first place. | Medium (needs embedding API) | Everything |
| 6 | **Volt/LCM** | The theoretically correct solution, but requires abandoning Claude Code. Worth watching as the research matures. Consider if Claude Code's compaction continues to be a pain point. | High (different tool) | N/A (replacement) |
| 7 | **Memory Store** | Good automatic tracking but overlaps with Memory Keeper and Claude-Mem. Pick this if you specifically want dev-workflow metrics. | Low | Context-Manager |
| 8 | **Claude Memory MCP** | Graph database is powerful but manual. Best for long-running projects with complex entity relationships. Not worth it for typical session work. | Low | Everything |
| 9 | **Lossless-Claw** | Great concept but OpenClaw-specific. Watch for a Claude Code port. | Low (if using OpenClaw) | OpenClaw only |

### Recommended Stack for Your Setup

Given that you run 20+ projects, switch between them constantly via Claude Context Manager, and hit compaction regularly:

1. **Context-Manager** (already installed) — baseline compaction protection
2. **CMV** — add snapshot/restore that integrates with your session management workflow
3. **Claude-Mem** — automatic cross-session memory so returning to a project after days doesn't start cold

This three-layer stack covers: within-session survival (Context-Manager), structured state management (CMV), and cross-session continuity (Claude-Mem).

---

## Sources

- [Context-Manager (DxTa)](https://github.com/DxTa/claude-dynamic-context-pruning)
- [MCP Memory Keeper](https://github.com/mkreyman/mcp-memory-keeper)
- [Claude-Mem](https://github.com/thedotmack/claude-mem)
- [Claude Memory MCP](https://lobehub.com/mcp/randall-gross-claude-memory-mcp)
- [Memory Store Plugin](https://github.com/julep-ai/memory-store-plugin)
- [Claude Context (Zilliz)](https://github.com/zilliztech/claude-context)
- [Volt/LCM](https://github.com/voltropy/volt)
- [Lossless-Claw](https://github.com/Martian-Engineering/lossless-claw)
- [CMV - Contextual Memory Virtualisation](https://github.com/CosmoNaught/claude-code-cmv)
- [CMV arXiv Paper](https://arxiv.org/abs/2602.22402)
- [Claude Code Feature Request #27293](https://github.com/anthropics/claude-code/issues/27293)
- [LCM Paper Discussion (Hacker News)](https://news.ycombinator.com/item?id=47074246)
