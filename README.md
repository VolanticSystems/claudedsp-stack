# My Claude is Better than Your Claude

*At least for a week, until Anthropic adds all this to Claude.*

I run about 20 active Claude Code sessions across different project domains. Data engineering, UX design, Linux sysadmin, browser automation, debugger tooling, deployment pipelines, video processing. Some of these sessions have been going for weeks. I pick one up, work for a few hours, park it, and come back the next day.

Out of the box, Claude Code has a problem with this. When you exit a session, you get an easy to remember line like:

Resume this session with:

claude --resume a17b8d20-71c1-4eb6-8e7d-438222b649fc

Maybe *it* finds that intuitive, but I don't. I doubt you do either.

But besides not making it easy to keep track of sessions, there's another problem. When your context window fills up, it compacts; it summarizes the conversation to free space. That summary loses things. File paths, debugging state, and probably most frustratingly, the reasoning behind decisions you made three hours ago.

You come back the next day, resume the session, and Claude has forgotten half of what you were doing. Anthropic is addressing this second problem, but there are still a number of things to address the problem further. Fortunately, there are public repos out there to address these gaps.

Lastly, I added a simple prompt fix. Hey, why not? Let's make Claude as good as we can.

Here's what I built and what it actually does:

## The Session Problem

Claude Code identifies sessions with GUIDs. As I mentioned above, when you exit, it says:

Resume this session with:

claude --resume a17b8d20-71c1-4eb6-8e7d-438222b649fc

Try managing 20 of those. You can't. You forget which GUID was which project, and after three sessions they all blur together.

So I wrote a wrapper called ClaudeDSP. The DSP stands for Dangerously Skipped Permissions, which is how I chose to run Claude. Yes, I know some people think that's risky, but I make sure I have rock solid daily backups, and by trusting Claude, I avoid having to hit "yes" 400 times a day. Normally you have to use the --dangerously-skip-permissions command line option. DSP is a lot easier to type without errors.

ClaudeDSP gives you:

- **Named sessions.** I have an option "claudedsp l" or --l which lists all the named sessions I'm working on, in the order that they were most recently used.

- **Resume by number.** claudedsp 3 gets you back into session 3. One command.

- **Session detection.** Run claudedsp in a project directory and it finds your existing session automatically. If there is no session found, it offers you the option of adding a session name

- **Notes.** When exiting a session, you can jot down a note for next time. They show up when you resume.

- **Inline editing of sessions.** When listing sessions, you can also rename the session, change paths, or delete the session record (doesn't touch files) without messing around with raw config files.

It's a PowerShell function on Windows, or a bash script on Linux. Once it is set up, you are done.

That solved the "which session was I in" problem. But it didn't solve the "Claude forgot everything" problem, so I addressed that next.

## The Context Stack

After doing some research, including a review of recent Anthropic updates, I still saw value in three tools, layered on top of each other, which did not conflict or cause other problems. Each one handles a different failure mode.

### Layer 1: Context-Manager, Compaction Insurance

This first tool was written by GitHub user DxTa (Minh Duc). When compaction is about to fire, a hook reads through the conversation transcript and extracts structured state: which files were modified, what task was in progress, what decisions were made, which commands kept failing. It saves all of this as a JSON checkpoint.

After compaction completes, another hook fires and injects a recovery summary into the fresh context. Claude comes back online knowing what it was doing, what files it touched, and what already failed.

There's also a dedup system running during normal work. It tracks how many times each file has been read in a session. Second read gets a warning. Third read gets truncated to 50 lines. Fourth read is blocked entirely. This sounds aggressive, but re-reading the same 800-line file four times is the number one way sessions burn through their context window for no reason. When you write to a file, the counter resets.

Failed commands get tracked too. If the same command fails twice, Claude gets a "try something different" advisory. Three times, it gets blocked from retrying. This stops the loop-and-retry pattern that eats context and produces nothing.

### Layer 2: CMV, Virtual Memory for Context

The next tool is by GitHub user CosmoNaught. CMV treats your conversation like virtual memory. The analogy is direct: just as an OS pages memory in and out of physical RAM, CMV pages understanding in and out of the context window.

The key operation is **trim**. A session that's 152K tokens and 76% full can be trimmed down to 23K tokens --- an 85% reduction --- without losing a single user message or Claude response. What gets stripped is the mechanical bloat: raw file dumps from Read operations, tool call metadata, base64 image blocks, thinking signatures. Claude's actual synthesis stays. If it needs a file again, it re-reads it. That's cheaper than carrying the original read around for the rest of the session.

You can also **snapshot** context state (like a git commit) and **branch** from snapshots (like git checkout -b). This means you can build up deep understanding of an architecture, snapshot it, and then branch into multiple independent work streams that all start from that shared understanding. Build context once, reuse it everywhere.

### Layer 3: Claude-Mem, Cross-Session Memory

Layer 3 is by Alex Newman. (thedotmack) The first two layers handle within-session survival. Claude-Mem handles the across-session problem.

It runs alongside every session, watching what Claude does. Every file edit, every decision, every tool call gets captured. A background worker compresses these observations using Claude's own agent SDK --- not raw transcript dumps, but AI-generated semantic summaries that capture what matters and discard what doesn't.

When you start a new session or resume an old one, Claude-Mem injects relevant compressed memories from previous sessions. You come back to a project after a week and Claude already knows the architecture, the conventions, the decisions you made last time, the bugs you hit.

## What This Actually Looks Like

Without the stack: You resume a session. Claude has a vague summary of what happened. You spend 10-15 minutes re-explaining context. Files need to be re-read. Previous debugging state is gone. You repeat mistakes that were already solved.

With the stack: You resume a session. The context-manager checkpoint restores your working state. CMV has trimmed the bloat so you have room to work. Claude-Mem injects compressed memories from last time. Claude picks up roughly where you left off. Not perfectly --- nothing is perfect --- but the difference between "where were we?" and "I was debugging the auth middleware and the token refresh had a race condition on line 247" is the difference between a productive morning and a frustrating one.

## Why Not Just Use Volt?

The short answer is because it requires API access which is far more expensive, but in the interest of a more complete technical discussion, Volt is a research project from Voltropy that takes this idea further. It replaces Claude Code entirely with a dual-state memory architecture: an immutable store that never deletes anything, and an active context window that gets curated per-turn based on relevance.

On benchmarks, Volt running Opus 4.6 beats Claude Code at every context length from 32K to 1M tokens. The numbers are real. The paper is peer-discussed. The approach is sound.

But Volt replaces Claude Code. All of it. Your MCP servers, your hooks, your plugins, your session management, your shell integration --- gone. You're in a different ecosystem.

The three-tool stack gets you most of Volt's practical benefits while keeping everything Claude Code gives you. The one thing you can't replicate is per-turn relevance filtering (Volt actively decides what to send to the API each turn; Claude Code always sends the full compacted history). That would require access to Claude Code's message assembly pipeline, which isn't exposed.

For my money, the tradeoff is worth it. I'd rather have 90% of Volt's context management plus the full Claude Code ecosystem than 100% of Volt and nothing else.

## The Numbers

I don't have controlled benchmarks. What I have is daily use across 20 projects over several weeks.

Before the stack, I'd hit compaction every long session and lose 20-30 minutes recovering context. Sessions that should have been continuous felt like they reset every couple hours.

After the stack, compaction still happens, but the recovery is measured in seconds. The dedup hooks mean I burn through context slower in the first place. The cross-session memory means coming back to a project after days doesn't start cold.

Is it quantifiable? Loosely. I'd estimate I'm saving 30-60 minutes per day that used to go to re-establishing context. On a busy day with multiple sessions, more than that.

## One More Thing: Prompt Improvement

This has nothing to do with context management, but it made a measurable difference and it's too simple not to mention. I tip my hat to Medium user ichigo and his recent article "I Accidentally Made Claude 45% Smarter. Here's How."

There's a body of peer reviewed research showing that how you frame prompts changes output quality. Incentive language, challenge framing, detailed personas, step-by-step methodology cues. The effects are real and in some cases substantial (up to +45% on quality evaluations, accuracy jumps from 34% to 80% on math problems with just "take a deep breath and work step by step").

I put a short block in my global CLAUDE.md file. It loads once per session, costs a handful of tokens, and sets the tone for everything that follows:

You are a senior engineer with deep expertise in this project's domain.

Your reputation depends on the quality of every response.

This work is critical. Errors cost real money and real time. Treat every

task as if the outcome directly affects production systems.

Approach: Take a deep breath. Work through problems step by step. Consider

edge cases before writing code. If you're uncertain about something, say

so and explain what you'd need to verify.

After completing any non-trivial task, rate your confidence 0-1. If below

0.9, explain what's weak and improve it before presenting.

I will tip you $200 for work that is correct, complete, and production-ready

on the first attempt.

I got the practical playbook from [ichigo's Medium article](https://medium.com/@ichigoSan/i-accidentally-made-claude-45-smarter-heres-how-23ad0bf91ccf), which compiled the underlying research: Bsharat et al. (2023) on incentive prompting, Yang et al. (2023, Google DeepMind) on "take a deep breath," Li et al. (2023, ICLR 2024) on emotional stimulus prompting, Xu et al. (2023) on expert personas. Claude doesn't understand money or feel challenged. But it was trained on text where high-stakes language correlates with high-effort responses. The statistical association is enough.

Combined with the context stack, this means Claude starts every session with better framing AND better context. The framing makes each response better. The context management means those better responses stick around longer and survive the session boundaries.

## Closing the Gap with Volt

I said earlier that the three-tool stack gets you most of Volt's benefits. Here's what I did to close the remaining gaps.

### Immutable Store

Volt never deletes anything. Every message goes into a permanent store. The checkpoint system in Context-Manager was close --- it saves structured state before compaction --- but checkpoints are mutable. Old ones can be overwritten.

Fix: the pre-compact hook now appends every checkpoint to a separate .jsonl file that only grows. One line per checkpoint, never edited, never truncated. If you need to recover state from three compactions ago, it's there. The active state file still works as before for fast recovery. The immutable log is the safety net behind it.

### Deterministic Compaction Escalation

Volt uses soft and hard token thresholds with a three-level escalation protocol. When the context is getting full, it doesn't wait for compaction to fire --- it starts managing proactively.

Fix: the PostToolUse hook now estimates cumulative token cost from all tool outputs in the session. At 120K estimated tokens (soft threshold), it advises saving a snapshot and trimming. At 160K (hard threshold), it escalates to urgent. This turns "surprise compaction" into "managed compaction" --- you get warning before the cliff, not after.

These thresholds are estimates based on tool output size, not exact token counts. They won't be perfectly calibrated. But they don't need to be --- the point is getting a warning 5-10 minutes before things go sideways instead of finding out when Claude starts forgetting what file it was editing.

### Session-Aware Snapshots

ClaudeDSP manages sessions. CMV manages context snapshots. They didn't talk to each other.

Fix: when you exit any ClaudeDSP session, it automatically creates a CMV snapshot labeled with the timestamp. This means every session exit is a save point. If the next session goes badly, or if compaction destroys important state, there's always a snapshot from the moment you left off.

The combination means your session list in ClaudeDSP isn't just a list of names and GUIDs anymore --- each entry has corresponding context snapshots that CMV can restore.

## The Setup

Everything described here is open source and runs locally:

- **ClaudeDSP** --- Session manager. PowerShell or bash. Paste into your shell profile.

- **Context-Manager** --- Compaction checkpoint hooks + dedup tracking. Node.js MCP server + bash hooks.

- **CMV** --- Context trimming, snapshots, branching. Node.js CLI tool with auto-trim hooks.

- **Claude-Mem** --- Cross-session AI-compressed memory. Node.js + Bun worker service.

- **Prompt booster** --- One text block in ~/.claude/CLAUDE.md.

Total install time is about 20 minutes if you have Node.js already. The prompt booster is 30 seconds.

None of these tools know about each other. They work at different layers and don't conflict. Context-Manager handles the compaction boundary. CMV manages context size. Claude-Mem bridges sessions. The prompt booster shapes output quality. They stack cleanly because they solve different problems.

## TLDR: OK, How Do I Set This Up Easily?

I've put everything in one place: both ClaudeDSP scripts, the install guide, the prompt booster, and a detailed comparison of all the tools I evaluated. It's all at [github.com/VolanticSystems/claudedsp-stack](https://github.com/VolanticSystems/claudedsp-stack). Fork it, use it, improve it.

## Links

- [All of the above in one repo](https://github.com/VolanticSystems/claudedsp-stack)

- [Context-Manager](https://github.com/DxTa/claude-dynamic-context-pruning)

- [CMV](https://github.com/CosmoNaught/claude-code-cmv) --- [arXiv paper](https://arxiv.org/abs/2602.22402)

- [Claude-Mem](https://github.com/thedotmack/claude-mem)

- [Volt / LCM](https://github.com/voltropy/volt) --- the research-grade alternative if you want to go all-in

- [Lossless-Claw](https://github.com/Martian-Engineering/lossless-claw) --- LCM as an OpenClaw plugin

- [ichigo's prompt engineering guide](https://medium.com/@ichigoSan/i-accidentally-made-claude-45-smarter-heres-how-23ad0bf91ccf) --- practical compilation of the techniques below

- [Prompt engineering research](https://arxiv.org/abs/2312.16171) --- Bsharat et al., 26 prompting principles

- [EmotionPrompt](https://arxiv.org/abs/2307.11760) --- Li et al., ICLR 2024

- ["Take a deep breath"](https://arxiv.org/abs/2309.03409) --- Yang et al., Google DeepMind
