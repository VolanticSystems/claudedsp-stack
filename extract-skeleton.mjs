#!/usr/bin/env node
/**
 * ClaudeCM Skeleton Extractor
 *
 * Reads a Claude Code JSONL session file and produces:
 *   1. A structured markdown skeleton (mechanical facts)
 *   2. A filtered transcript (user/assistant text + tool call summaries)
 *
 * Usage:
 *   node extract-skeleton.mjs <jsonl-path> [session-description] [output-dir]
 */

import { readFileSync, writeFileSync, statSync } from 'fs';
import { basename, join, dirname } from 'path';

// ─── Benign error detection ────────────────────────────────────────

const BENIGN_CONTENT_PATTERNS = [
  "the user doesn't want to proceed",
  "the user denied",
  "tool use was rejected",
];

function isBenignError(toolName, target, content) {
  const lower = content.toLowerCase();
  for (const pattern of BENIGN_CONTENT_PATTERNS) {
    if (lower.includes(pattern)) return true;
  }
  return false;
}

// ─── Structure validation ──────────────────────────────────────────

function validateStructure(entries) {
  const issues = [];
  const seenTypes = new Set();
  let foundToolUse = false;
  let foundToolResult = false;

  for (const e of entries) {
    seenTypes.add(e.type || '');

    if (e.type === 'assistant' && e.message) {
      const content = e.message.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'tool_use') {
            for (const field of ['name', 'input', 'id']) {
              if (!(field in block)) {
                issues.push(`tool_use block missing '${field}' field`);
                return { ok: false, issues };
              }
            }
            if (['Write', 'Edit', 'Read'].includes(block.name)) {
              if (!block.input || !('file_path' in block.input)) {
                issues.push(`${block.name} tool_use missing 'file_path' in input`);
                return { ok: false, issues };
              }
            }
            foundToolUse = true;
          }
        }
      }
    }

    if (e.type === 'user' && e.message) {
      const content = e.message.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'tool_result') {
            if (!('tool_use_id' in block)) {
              issues.push("tool_result missing 'tool_use_id' field");
              return { ok: false, issues };
            }
            foundToolResult = true;
          }
        }
      }
    }
  }

  for (const required of ['user', 'assistant']) {
    if (!seenTypes.has(required)) {
      issues.push(`Missing expected entry type: ${required}`);
      return { ok: false, issues };
    }
  }

  if (!foundToolUse) {
    issues.push('No tool_use blocks found (conversation-only session)');
  }

  return { ok: true, issues };
}

// ─── Tool call summarizer ──────────────────────────────────────────

function summarizeToolCall(name, input) {
  if (['Read', 'Write', 'Edit'].includes(name)) {
    return `${name}: ${input.file_path || '?'}`;
  }
  if (name === 'Bash') {
    if (input.description) return `Bash: ${input.description}`;
    return `Bash: ${(input.command || '?').slice(0, 120)}`;
  }
  if (name === 'Grep') {
    const p = input.pattern || '?';
    return input.path ? `Grep: "${p}" in ${input.path}` : `Grep: "${p}"`;
  }
  if (name === 'Glob') {
    const p = input.pattern || '?';
    return input.path ? `Glob: ${p} in ${input.path}` : `Glob: ${p}`;
  }
  if (name === 'Agent') {
    return `Agent: ${input.description || (input.prompt || '?').slice(0, 80)}`;
  }
  if (name === 'ToolSearch') {
    return `ToolSearch: ${input.query || '?'}`;
  }
  if (name.startsWith('mcp__')) {
    const short = name.split('__').pop();
    return `MCP ${short}: ${JSON.stringify(input).slice(0, 100)}`;
  }
  return `${name}: ${JSON.stringify(input).slice(0, 100)}`;
}

// ─── Text extraction helpers ───────────────────────────────────────

function getTextFromContent(content) {
  if (typeof content === 'string') return content.trim();
  if (Array.isArray(content)) {
    return content
      .filter(b => b.type === 'text')
      .map(b => b.text || '')
      .join('\n')
      .trim();
  }
  return '';
}

function isSystemNoise(text) {
  const prefixes = [
    '<local-command',
    '<command-name>',
    '<command-message>',
    '<local-command-stdout>',
    '<local-command-caveat>',
    '<task-notification>',
    '<system-reminder>',
  ];
  const stripped = text.trim();
  return prefixes.some(p => stripped.startsWith(p));
}

function isCompactionPreamble(text) {
  const markers = [
    'This session is being continued from a previous conversation',
    'Summary:\n1. Primary Request',
    'ran out of context',
  ];
  const head = text.slice(0, 500);
  return markers.some(m => head.includes(m));
}

// ─── [important] marker scanner ────────────────────────────────────

function scanImportantMarkers(text) {
  const results = [];
  const regex = /^[ \t]*\[important\]\s*(.+?)$/gim;
  let match;
  while ((match = regex.exec(text)) !== null) {
    results.push(match[1].trim().slice(0, 500));
  }
  return results;
}

// ─── Main extraction ───────────────────────────────────────────────

function extract(jsonlPath, sessionDesc = 'Unknown') {
  const raw = readFileSync(jsonlPath, 'utf-8');
  const entries = [];
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      entries.push(JSON.parse(trimmed));
    } catch {
      continue;
    }
  }

  if (entries.length === 0) {
    return { error: 'Empty or unreadable JSONL file' };
  }

  const { ok, issues } = validateStructure(entries);
  if (!ok) {
    return { error: `JSONL structure validation failed: ${issues.join('; ')}` };
  }

  // --- Data collectors ---
  const filesModified = new Map();   // path -> Set of operations
  const filesRead = new Set();
  const errors = [];                 // { toolName, target, content }
  const toolUseById = new Map();
  let firstUserMessage = null;
  const importantMarkers = [];
  const lastExchanges = [];          // { role, text }
  const transcriptEntries = [];      // { role, text }

  for (const e of entries) {
    // --- Assistant messages ---
    if (e.type === 'assistant' && e.message) {
      const content = e.message.content;
      if (!Array.isArray(content)) continue;

      const textParts = [];
      const toolSummaries = [];

      for (const block of content) {
        if (block.type === 'tool_use') {
          const toolName = block.name || '';
          const toolInput = block.input || {};
          toolUseById.set(block.id || '', block);

          if (toolName === 'Write' || toolName === 'Edit') {
            const fp = toolInput.file_path || '';
            if (fp) {
              if (!filesModified.has(fp)) filesModified.set(fp, new Set());
              filesModified.get(fp).add(toolName);
            }
          } else if (toolName === 'Read') {
            const fp = toolInput.file_path || '';
            if (fp) filesRead.add(fp);
          }

          toolSummaries.push(summarizeToolCall(toolName, toolInput));

        } else if (block.type === 'text') {
          textParts.push(block.text || '');
        }
      }

      const fullText = textParts.join('\n').trim();
      if (fullText) {
        lastExchanges.push({ role: 'assistant', text: fullText });
        transcriptEntries.push({ role: 'assistant', text: fullText });
        importantMarkers.push(...scanImportantMarkers(fullText));
      }

      for (const summary of toolSummaries) {
        transcriptEntries.push({ role: 'tool', text: summary });
      }
    }

    // --- User messages ---
    if (e.type === 'user' && e.message) {
      const content = e.message.content;

      // Scan for error tool_results
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'tool_result' && block.is_error) {
            let errorContent = block.content || '';
            if (Array.isArray(errorContent)) {
              errorContent = errorContent
                .filter(b => b.type === 'text')
                .map(b => b.text || '')
                .join(' ');
            }

            const matchingUse = toolUseById.get(block.tool_use_id || '') || {};
            const toolName = matchingUse.name || 'unknown';
            const inp = matchingUse.input || {};
            let target = '';
            if (inp.file_path) target = inp.file_path;
            else if (inp.command) target = inp.command.slice(0, 120);
            else if (inp.pattern) target = `pattern: ${inp.pattern}`;

            if (!isBenignError(toolName, target, errorContent)) {
              errors.push({ toolName, target, content: errorContent.slice(0, 300) });
            }
          }
        }
      }

      const text = getTextFromContent(content);
      if (!text || isSystemNoise(text)) continue;

      if (firstUserMessage === null && !isCompactionPreamble(text)) {
        firstUserMessage = text.slice(0, 500);
      }

      importantMarkers.push(...scanImportantMarkers(text));
      lastExchanges.push({ role: 'user', text });
      transcriptEntries.push({ role: 'user', text });
    }
  }

  // --- Post-processing ---

  // Group repeated errors
  const errorGroups = new Map();
  for (const { toolName, target, content } of errors) {
    const key = `${toolName}|||${target}`;
    if (!errorGroups.has(key)) errorGroups.set(key, { toolName, target, contents: [] });
    errorGroups.get(key).contents.push(content);
  }

  // Files read but not modified
  const filesReadOnly = new Set([...filesRead].filter(f => !filesModified.has(f)));

  // Consolidate consecutive same-role exchanges
  const consolidated = [];
  for (const { role, text } of lastExchanges) {
    if (consolidated.length > 0 && consolidated[consolidated.length - 1].role === role) {
      consolidated[consolidated.length - 1].text += '\n\n' + text;
    } else {
      consolidated.push({ role, text });
    }
  }
  const recent = consolidated.slice(-10);

  // --- Build skeleton ---
  const guid = basename(jsonlPath, '.jsonl');
  const now = new Date().toISOString().replace('T', ' ').slice(0, 16);
  const lines = [];

  lines.push(`# Session Refresh: ${sessionDesc}`);
  lines.push(`Extracted from session ${guid} on ${now}`);
  lines.push('');

  lines.push('## Original Intent');
  lines.push(firstUserMessage || '(Could not determine original intent; session may start with compaction)');
  lines.push('');

  lines.push(`## Files Modified (${filesModified.size})`);
  if (filesModified.size > 0) {
    for (const fp of [...filesModified.keys()].sort()) {
      const ops = [...filesModified.get(fp)].sort().join(', ');
      lines.push(`- ${fp} (${ops})`);
    }
  } else {
    lines.push('(none)');
  }
  lines.push('');

  lines.push(`## Files Read (${filesReadOnly.size})`);
  if (filesReadOnly.size > 0) {
    for (const fp of [...filesReadOnly].sort()) {
      lines.push(`- ${fp}`);
    }
  } else {
    lines.push('(none)');
  }
  lines.push('');

  if (importantMarkers.length > 0) {
    lines.push(`## Marked Important (${importantMarkers.length})`);
    for (const content of importantMarkers) {
      lines.push(`- ${content}`);
    }
    lines.push('');
  }

  const realErrorCount = [...errorGroups.values()].reduce((sum, g) => sum + g.contents.length, 0);
  lines.push(`## Errors Encountered (${realErrorCount})`);
  if (errorGroups.size > 0) {
    for (const { toolName, target, contents } of errorGroups.values()) {
      const count = contents.length;
      const status = count >= 2
        ? `${count} occurrences, potentially unresolved`
        : '1 occurrence';
      const displayTarget = target || '(no target)';
      lines.push(`- \`${toolName}\` on ${displayTarget}: ${contents[0].slice(0, 150)} (${status})`);
    }
  } else {
    lines.push('(none)');
  }
  lines.push('');

  lines.push('## Recent Context');
  if (recent.length > 0) {
    for (const { role, text } of recent) {
      const label = role === 'user' ? '**User:**' : '**Assistant:**';
      const display = text.length > 400 ? text.slice(0, 400) + '...' : text;
      lines.push('');
      lines.push(label);
      lines.push(display);
    }
  } else {
    lines.push('(no exchanges found)');
  }
  lines.push('');

  lines.push('---');
  lines.push(
    `*Structure validated. ${entries.length} entries processed. ` +
    `${toolUseById.size} tool calls, ${realErrorCount} real errors ` +
    `(benign errors filtered). Validation issues: ${issues.length > 0 ? issues.join('; ') : 'none'}.*`
  );

  const skeleton = lines.join('\n');

  // --- Build filtered transcript ---
  const txLines = [];
  txLines.push(`# Filtered Transcript: ${sessionDesc}`);
  txLines.push(`Session ${guid}`);
  txLines.push('User and assistant text with tool call summaries. Tool results stripped.');
  txLines.push('');

  for (const { role, text } of transcriptEntries) {
    if (role === 'tool') {
      txLines.push(`**Tool: ${text}**`);
      txLines.push('');
    } else {
      txLines.push(role === 'user' ? '## User' : '## Assistant');
      txLines.push(text);
      txLines.push('');
    }
  }

  const transcript = txLines.join('\n');

  return { skeleton, transcript, issues };
}

// ─── CLI ───────────────────────────────────────────────────────────

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error('Usage: node extract-skeleton.mjs <jsonl-path> [session-description] [output-dir]');
  process.exit(1);
}

const jsonlPath = args[0];
const desc = args[1] || 'Unknown';
const outputDir = args[2] || dirname(jsonlPath);
const guid = basename(jsonlPath, '.jsonl');

const result = extract(jsonlPath, desc);

if (result.error) {
  console.error(`ERROR: ${result.error}`);
  process.exit(1);
}

const skelPath = join(outputDir, `${guid}-skeleton.md`);
const txPath = join(outputDir, `${guid}-transcript.md`);

writeFileSync(skelPath, result.skeleton, 'utf-8');
writeFileSync(txPath, result.transcript, 'utf-8');

const origSize = statSync(jsonlPath).size;
const skelSize = statSync(skelPath).size;
const txSize = statSync(txPath).size;
const combined = skelSize + txSize;

console.log(`Original JSONL:       ${origSize.toLocaleString().padStart(12)} bytes`);
console.log(`Skeleton:             ${skelSize.toLocaleString().padStart(12)} bytes`);
console.log(`Filtered transcript:  ${txSize.toLocaleString().padStart(12)} bytes`);
console.log(`Combined output:      ${combined.toLocaleString().padStart(12)} bytes (${(combined / origSize * 100).toFixed(1)}% of original)`);
console.log('');
console.log('Files written:');
console.log(`  ${skelPath}`);
console.log(`  ${txPath}`);
