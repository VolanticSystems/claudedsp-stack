#!/bin/bash
# ClaudeCM - Claude Context Manager (Linux/macOS)
# See claudecm-project-spec.md for the canonical specification.
#
# Install:
#   cp claudecm-linux.sh /usr/local/bin/claudecm
#   chmod +x /usr/local/bin/claudecm
#
# Usage:
#   claudecm                       Launch Claude in the current directory
#   claudecm l                     List saved sessions (interactive picker)
#   claudecm 3                     Resume session #3
#   claudecm --proj /path/to/dir   Operate in a specific project directory

set -u

# --- Bootstrap (Section 4) ---
export CLAUDE_CODE_REMOTE_SEND_KEEPALIVES=1

CM_DIR="$HOME/.claudecm"
SESSIONS_FILE="$CM_DIR/sessions.txt"
SESSIONS_LOCK="$CM_DIR/sessions.txt.lock"
MACHINE_NAME_FILE="$CM_DIR/machine-name.txt"
BACKUP_DIR="$CM_DIR/backup"
REFRESH_TEMP_ROOT="$CM_DIR/refresh-temp"

CLAUDE_EXE="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
CMV_EXE="$(command -v cmv 2>/dev/null || echo "$HOME/.npm-global/bin/cmv")"
NODE_EXE="$(command -v node 2>/dev/null || true)"
EDITOR="${EDITOR:-nano}"

mkdir -p "$CM_DIR" "$BACKUP_DIR"
[[ -f "$SESSIONS_FILE" ]] || touch "$SESSIONS_FILE"

# Color helpers (no-op when not a TTY)
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_GRAY='\033[0;90m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_GRAY=''
fi

# --- Section 4 step 4: Ensure cleanupPeriodDays ---
ensure_cleanup_period_days() {
    local settings="$HOME/.claude/settings.json"
    [[ -f "$settings" ]] || return 0
    [[ -n "$NODE_EXE" ]] || return 0
    "$NODE_EXE" -e "
        const fs = require('fs');
        const p = '$settings';
        try {
            const s = JSON.parse(fs.readFileSync(p, 'utf8'));
            if (!s.cleanupPeriodDays || s.cleanupPeriodDays < 1000) {
                const ts = new Date().toISOString().replace(/[-:T.]/g, '').slice(0,15);
                fs.copyFileSync(p, '$BACKUP_DIR/settings.json.' + ts);
                s.cleanupPeriodDays = 100000;
                fs.writeFileSync(p, JSON.stringify(s, null, 2));
                console.log('  Protected session transcripts from Claude Code\\'s 30-day auto-delete.');
            }
        } catch(e) {}
    " 2>/dev/null
}
ensure_cleanup_period_days

# Auto-backup sessions.txt on every launch (best-effort, silent).
# Keeps a rolling history of the last 20 backups.
auto_backup_sessions() {
    [[ -s "$SESSIONS_FILE" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp "$SESSIONS_FILE" "$BACKUP_DIR/sessions.txt.$ts" 2>/dev/null
    # Prune all but the most recent 20
    ls -1t "$BACKUP_DIR"/sessions.txt.* 2>/dev/null | tail -n +21 | while read -r old; do
        rm -f "$old"
    done
}
auto_backup_sessions

# --- Section 4 step 5: Machine name bootstrap ---
if [[ ! -f "$MACHINE_NAME_FILE" ]]; then
    echo ""
    read -rp "  Machine name for remote display (e.g. desktop, laptop): " mn
    [[ -z "$mn" ]] && mn=$(hostname | tr '[:upper:]' '[:lower:]')
    echo "$mn" > "$MACHINE_NAME_FILE"
    echo "  Saved: $mn"
fi
MACHINE_NAME=$(tr -d '\n' < "$MACHINE_NAME_FILE" 2>/dev/null)
[[ -z "$MACHINE_NAME" ]] && MACHINE_NAME=$(hostname | tr '[:upper:]' '[:lower:]')

# --- Section 6: Project key encoding ---
get_proj_key() {
    # Replace every non-alphanumeric character with dash.
    echo "$1" | sed 's|[^a-zA-Z0-9]|-|g'
}

get_display_name() {
    echo "$MACHINE_NAME - $1"
}

# --- Section 5: sessions.txt I/O ---
get_sessions() {
    # Emit lines: index|guid|dir|desc|tokens (stops at [archived])
    local i=0
    while IFS='|' read -r guid dir desc tokens; do
        [[ -z "$guid" ]] && continue
        [[ "$guid" == "[archived]" ]] && break
        echo "$i|$guid|$dir|$desc|$tokens"
        ((i++))
    done < "$SESSIONS_FILE"
}

get_archived_sessions() {
    local i=0 in_archived=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == "[archived]" ]]; then in_archived=true; continue; fi
        if $in_archived; then
            IFS='|' read -r guid dir desc tokens <<< "$line"
            [[ -z "$guid" ]] && continue
            echo "$i|$guid|$dir|$desc|$tokens"
            ((i++))
        fi
    done < "$SESSIONS_FILE"
}

get_session_count() {
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == "[archived]" ]] && break
        ((count++))
    done < "$SESSIONS_FILE"
    echo "$count"
}

# --- Section 5.1: locking + atomic write ---
acquire_sessions_lock() {
    # Opens FD 9 on the lock file with exclusive lock. Retries up to 10s.
    # Returns 0 if acquired, 1 if not (caller proceeds without lock).
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$SESSIONS_LOCK"
        if flock -w 10 9 2>/dev/null; then
            return 0
        else
            echo "  [warning] Could not acquire sessions.txt lock after 10s; proceeding without lock."
            return 1
        fi
    fi
    return 0
}

release_sessions_lock() {
    if command -v flock >/dev/null 2>&1; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
    fi
}

write_sessions_atomic() {
    # Reads all lines from stdin, writes to .tmp, renames atomically.
    local tmp="$SESSIONS_FILE.tmp"
    cat > "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
}

save_sessions() {
    # Reads main session lines from stdin. Preserves [archived] section.
    acquire_sessions_lock
    local main_tmp arch_tmp
    main_tmp=$(mktemp); arch_tmp=$(mktemp)
    cat > "$main_tmp"
    local in_archived=false
    while IFS= read -r line; do
        if [[ "$line" == "[archived]" ]]; then in_archived=true; continue; fi
        if $in_archived && [[ -n "$line" ]]; then echo "$line" >> "$arch_tmp"; fi
    done < "$SESSIONS_FILE"
    {
        cat "$main_tmp"
        if [[ -s "$arch_tmp" ]]; then
            echo "[archived]"
            cat "$arch_tmp"
        fi
    } | write_sessions_atomic
    rm -f "$main_tmp" "$arch_tmp"
    release_sessions_lock
}

save_archived_sessions() {
    # Reads archived session lines from stdin. Preserves main section.
    acquire_sessions_lock
    local arch_tmp main_tmp
    arch_tmp=$(mktemp); main_tmp=$(mktemp)
    cat > "$arch_tmp"
    while IFS= read -r line; do
        [[ "$line" == "[archived]" ]] && break
        [[ -n "$line" ]] && echo "$line" >> "$main_tmp"
    done < "$SESSIONS_FILE"
    {
        cat "$main_tmp"
        if [[ -s "$arch_tmp" ]]; then
            echo "[archived]"
            cat "$arch_tmp"
        fi
    } | write_sessions_atomic
    rm -f "$arch_tmp" "$main_tmp"
    release_sessions_lock
}

# --- Section 7: formatting helpers ---
format_tokens() {
    local t="$1"
    if [[ -z "$t" ]]; then echo "--"; return; fi
    if (( t >= 1000000 )); then awk "BEGIN{printf \"%.1fM tok\", $t/1000000}"
    elif (( t >= 1000 )); then awk "BEGIN{printf \"%.0fK tok\", $t/1000}"
    else echo "${t} tok"
    fi
}

format_size() {
    local b="$1"
    if (( b >= 1048576 )); then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
    elif (( b >= 1024 )); then awk "BEGIN{printf \"%.0f KB\", $b/1024}"
    else echo "${b} B"
    fi
}

format_date_short() {
    # Input: epoch seconds. Output: "Mar 13" (current year) or "Mar 13, 2026" (older).
    local epoch="$1"
    local cur_year file_year
    cur_year=$(date +%Y)
    file_year=$(date -d "@$epoch" +%Y 2>/dev/null || date -r "$epoch" +%Y 2>/dev/null)
    if [[ "$file_year" -lt "$cur_year" ]]; then
        date -d "@$epoch" "+%b %d, %Y" 2>/dev/null || date -r "$epoch" "+%b %d, %Y"
    else
        date -d "@$epoch" "+%b %d" 2>/dev/null || date -r "$epoch" "+%b %d"
    fi
}

# --- Section 8: get_session_info ---
get_session_info() {
    # Args: guid dir tokens. Output: size|date|tokens|status
    local guid="$1" dir="$2" tokens="$3"
    local proj_key proj_dir jsonl
    proj_key=$(get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    jsonl="$proj_dir/$guid.jsonl"

    local tok_str
    tok_str=$(format_tokens "${tokens:-}")

    if [[ -f "$jsonl" ]]; then
        local bytes mtime size_str date_str
        bytes=$(stat -c%s "$jsonl" 2>/dev/null || stat -f%z "$jsonl" 2>/dev/null)
        mtime=$(stat -c%Y "$jsonl" 2>/dev/null || stat -f%m "$jsonl" 2>/dev/null)
        size_str=$(format_size "$bytes")
        date_str=$(format_date_short "$mtime")
        echo "$size_str|$date_str|$tok_str|ok"
        return
    fi

    # JSONL missing - try fallbacks for date
    local fb_mtime=""
    if [[ -d "$proj_dir/$guid" ]]; then
        fb_mtime=$(stat -c%Y "$proj_dir/$guid" 2>/dev/null || stat -f%m "$proj_dir/$guid" 2>/dev/null)
    elif [[ -d "$proj_dir/memory" ]]; then
        fb_mtime=$(stat -c%Y "$proj_dir/memory" 2>/dev/null || stat -f%m "$proj_dir/memory" 2>/dev/null)
    elif [[ -f "$proj_dir/sessions-index.json" && -n "$NODE_EXE" ]]; then
        fb_mtime=$("$NODE_EXE" -e "
            try {
                const idx = JSON.parse(require('fs').readFileSync('$proj_dir/sessions-index.json', 'utf8'));
                const e = (idx.entries||[]).find(x => x.sessionId === '$guid');
                if (e && e.created) console.log(Math.floor(new Date(e.created).getTime() / 1000));
            } catch(e) {}
        " 2>/dev/null)
    fi

    local date_str="--"
    if [[ -n "$fb_mtime" ]]; then
        date_str="$(format_date_short "$fb_mtime")*"
    fi
    echo "(missing)|$date_str|$tok_str|missing"
}

# --- Section 10: Sync-SessionIndex ---
sync_session_index() {
    local project_dir="$1"
    [[ -z "$project_dir" ]] && return
    [[ -n "$NODE_EXE" ]] || return
    local proj_key proj_dir_claude
    proj_key=$(get_proj_key "$project_dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    [[ -d "$proj_dir_claude" ]] || return

    "$NODE_EXE" -e "
const fs = require('fs');
const path = require('path');
const projDirClaude = process.argv[1];
const projectDir = process.argv[2];
const sessionsFile = process.argv[3];
const indexPath = path.join(projDirClaude, 'sessions-index.json');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$/;

const sessionsMap = {};
try {
  fs.readFileSync(sessionsFile, 'utf8').split('\n').forEach(line => {
    if (!line.trim() || line.startsWith('[')) return;
    const p = line.split('|');
    if (p.length >= 3) sessionsMap[p[0]] = { dir: p[1], desc: p[2] };
  });
} catch(e) {}

let jsonlFiles = [];
try {
  jsonlFiles = fs.readdirSync(projDirClaude)
    .filter(f => f.endsWith('.jsonl') && UUID_RE.test(path.basename(f, '.jsonl')))
    .map(f => {
      const fp = path.join(projDirClaude, f);
      const st = fs.statSync(fp);
      return { guid: path.basename(f, '.jsonl'), fullPath: fp, stat: st };
    });
} catch(e) { return; }
if (jsonlFiles.length === 0) return;

let existing = [];
let originalPath = projectDir;
if (fs.existsSync(indexPath)) {
  try {
    const idx = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
    existing = idx.entries || [];
    if (idx.originalPath) originalPath = idx.originalPath;
  } catch(e) {}
}

const onDisk = {};
for (const f of jsonlFiles) onDisk[f.guid] = f;
const valid = existing.filter(e => onDisk[e.sessionId]);
for (const e of valid) {
  const f = onDisk[e.sessionId];
  e.fileMtime = Math.round(f.stat.mtimeMs);
  e.modified = f.stat.mtime.toISOString();
}
const indexed = new Set(valid.map(e => e.sessionId));
const fresh = [];
for (const f of jsonlFiles) {
  if (indexed.has(f.guid)) continue;
  const info = sessionsMap[f.guid];
  fresh.push({
    sessionId: f.guid,
    fullPath: f.fullPath,
    fileMtime: Math.round(f.stat.mtimeMs),
    firstPrompt: info ? info.desc : '',
    messageCount: 0,
    created: (f.stat.birthtime || f.stat.mtime).toISOString(),
    modified: f.stat.mtime.toISOString(),
    gitBranch: '',
    projectPath: info ? info.dir : originalPath,
    isSidechain: false
  });
}
const out = { version: 1, entries: [...valid, ...fresh], originalPath };
fs.writeFileSync(indexPath, JSON.stringify(out, null, 2));
" "$proj_dir_claude" "$project_dir" "$SESSIONS_FILE" 2>/dev/null
}

# --- Section 9: Show-List ---
show_list() {
    local highlight="${1:-0}"
    echo ""
    echo "  === Saved Sessions ==="
    echo ""
    local i=0 max_desc=0 count
    count=$(get_session_count)
    while IFS='|' read -r guid dir desc tokens; do
        [[ -z "$guid" ]] && continue
        [[ "$guid" == "[archived]" ]] && break
        local len=${#desc}
        (( len > max_desc )) && max_desc=$len
    done < "$SESSIONS_FILE"
    (( max_desc < 10 )) && max_desc=10
    local num_width=${#count}

    while IFS='|' read -r guid dir desc tokens; do
        [[ -z "$guid" ]] && continue
        [[ "$guid" == "[archived]" ]] && break
        ((i++))
        local info size_str date_str tok_str status
        info=$(get_session_info "$guid" "$dir" "${tokens:-}")
        IFS='|' read -r size_str date_str tok_str status <<< "$info"
        local num_str="${i}."
        printf -v line "  %-$((num_width + 2))s %-$((max_desc + 2))s %9s  %10s   %s\t%s" "$num_str" "$desc" "$size_str" "$tok_str" "$date_str" "$dir"
        if [[ "$i" == "$highlight" ]]; then
            printf "${C_YELLOW}  *** %-$((num_width + 2))s %-$((max_desc + 2))s %9s  %10s   %s\t%s  [Selected] ***${C_RESET}\n" "$num_str" "$desc" "$size_str" "$tok_str" "$date_str" "$dir"
        else
            echo "$line"
        fi
    done < "$SESSIONS_FILE"

    echo ""
    local arch_count
    arch_count=$(get_archived_sessions | wc -l)
    echo "  E. Edit this list"
    [[ $arch_count -gt 0 ]] && echo "  V. View archived ($arch_count)"
    echo "  M. Machine name ($MACHINE_NAME)"
}

# --- Section 11.5: Do-OrphanScan ---
ORPHAN_SELECTED_GUID=""
do_orphan_scan() {
    ORPHAN_SELECTED_GUID=""
    local scan_dir="$1" registered_guid="${2:-}"
    local proj_key proj_dir_claude
    proj_key=$(get_proj_key "$scan_dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    [[ -d "$proj_dir_claude" ]] || return 1

    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -t "$proj_dir_claude"/*.jsonl 2>/dev/null)
    [[ ${#files[@]} -le 1 ]] && return 1

    local has_problems=false f guid match_dir
    for f in "${files[@]}"; do
        guid=$(basename "$f" .jsonl)
        local match
        match=$(grep "^$guid|" "$SESSIONS_FILE" 2>/dev/null | head -1)
        if [[ -z "$match" ]]; then has_problems=true; break; fi
        match_dir=$(echo "$match" | cut -d'|' -f2)
        if [[ "$match_dir" != "$scan_dir" ]]; then has_problems=true; break; fi
    done
    $has_problems || return 1

    local backup_root="$HOME/claude-conversation-backup"
    echo ""
    printf "${C_YELLOW}  Multiple conversation files found (%d):${C_RESET}\n" "${#files[@]}"
    echo ""
    echo "  #   Last Modified          Size     Session Name"
    echo "  --- --------------------  --------  ---------------------------"

    local ci=0
    for f in "${files[@]}"; do
        ((ci++))
        guid=$(basename "$f" .jsonl)
        local bytes mtime size_str date_str name_str="(orphan)" match
        bytes=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
        mtime=$(stat -c%Y "$f" 2>/dev/null || stat -f%m "$f" 2>/dev/null)
        size_str=$(format_size "$bytes")
        date_str=$(date -d "@$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "$mtime" "+%Y-%m-%d %H:%M")
        match=$(grep "^$guid|" "$SESSIONS_FILE" 2>/dev/null | head -1)
        if [[ -n "$match" ]]; then
            name_str=$(echo "$match" | cut -d'|' -f3)
            local mdir; mdir=$(echo "$match" | cut -d'|' -f2)
            [[ "$mdir" != "$scan_dir" ]] && name_str="$name_str (wrong directory)"
        fi
        local marker=""
        [[ "$guid" == "$registered_guid" ]] && marker=" *"
        printf "  %-3s %s  %8s  %s%s\n" "${ci}." "$date_str" "$size_str" "$name_str" "$marker"
    done

    echo ""
    echo "  * = registered session for this directory"
    echo ""
    echo "  Actions: [number] to select, [q number] to quarantine to backup, [Enter] to continue with registered session"
    read -rp "  > " orphan_cmd

    if [[ "$orphan_cmd" =~ ^[0-9]+$ ]]; then
        local idx=$((orphan_cmd - 1))
        if (( idx >= 0 && idx < ${#files[@]} )); then
            ORPHAN_SELECTED_GUID=$(basename "${files[$idx]}" .jsonl)
            return 0
        fi
        echo "  Invalid number."
    elif [[ "$orphan_cmd" =~ ^[qQ][[:space:]]*([0-9]+)$ ]]; then
        local idx=$((${BASH_REMATCH[1]} - 1))
        if (( idx >= 0 && idx < ${#files[@]} )); then
            f="${files[$idx]}"
            guid=$(basename "$f" .jsonl)
            if [[ "$guid" == "$registered_guid" ]]; then
                printf "${C_RED}  Cannot quarantine the registered session.${C_RESET}\n"
            else
                local dest_subdir="$backup_root/$(basename "$scan_dir")"
                mkdir -p "$dest_subdir"
                mv "$f" "$dest_subdir/"
                local guid_dir="$proj_dir_claude/$guid"
                [[ -d "$guid_dir" ]] && mv "$guid_dir" "$dest_subdir/"
                sync_session_index "$scan_dir"
                printf "${C_GREEN}  Quarantined to backup: %s/%s${C_RESET}\n" "$(basename "$scan_dir")" "$guid"
            fi
        else
            echo "  Invalid number."
        fi
    fi
    return 1
}

# --- Section 11.6: Invoke-ClaudeLaunch (the only sanctioned launch path) ---
LAUNCH_PID=""
LAUNCH_SESSION_ID=""
LAUNCH_EXIT_CODE=0
invoke_claude_launch() {
    # Args: --dir <session_dir> -- <claude args...>
    LAUNCH_PID=""
    LAUNCH_SESSION_ID=""
    LAUNCH_EXIT_CODE=0

    local session_dir="" args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) session_dir="$2"; shift 2 ;;
            --) shift; args=("$@"); break ;;
            *) args+=("$1"); shift ;;
        esac
    done

    local proj_key proj_dir_claude
    proj_key=$(get_proj_key "$session_dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Layer 2 setup: snapshot existing GUIDs in this project dir
    local before_guids="" g
    if [[ -d "$proj_dir_claude" ]]; then
        for f in "$proj_dir_claude"/*.jsonl; do
            [[ -f "$f" ]] || continue
            g=$(basename "$f" .jsonl)
            [[ "$g" =~ $uuid_re ]] && before_guids+="$g "
        done
    fi

    # Launch claude as a child process; capture PID
    "$CLAUDE_EXE" "${args[@]}" &
    LAUNCH_PID=$!

    # Layer 1: poll for the session manifest written by claude.exe
    local manifest="$HOME/.claude/sessions/$LAUNCH_PID.json"
    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        if [[ -f "$manifest" && -n "$NODE_EXE" ]]; then
            local sid
            sid=$("$NODE_EXE" -e "
                try {
                    const m = JSON.parse(require('fs').readFileSync('$manifest', 'utf8'));
                    if (m.sessionId) console.log(m.sessionId);
                } catch(e) {}
            " 2>/dev/null)
            if [[ -n "$sid" ]]; then
                LAUNCH_SESSION_ID="$sid"
                break
            fi
        fi
        sleep 0.25
    done

    # Block until claude exits
    wait "$LAUNCH_PID"
    LAUNCH_EXIT_CODE=$?

    # Layer 2: snapshot diff
    local new_guid="" after_guids="" delta=()
    if [[ -d "$proj_dir_claude" ]]; then
        for f in "$proj_dir_claude"/*.jsonl; do
            [[ -f "$f" ]] || continue
            g=$(basename "$f" .jsonl)
            [[ "$g" =~ $uuid_re ]] && after_guids+="$g "
        done
        for g in $after_guids; do
            if [[ " $before_guids " != *" $g "* ]]; then
                delta+=("$g")
            fi
        done
        if [[ ${#delta[@]} -eq 1 ]]; then
            new_guid="${delta[0]}"
        elif [[ ${#delta[@]} -gt 1 ]]; then
            # Pick most recently modified
            local newest=""; local newest_mt=0
            for g in "${delta[@]}"; do
                local mt
                mt=$(stat -c%Y "$proj_dir_claude/$g.jsonl" 2>/dev/null || stat -f%m "$proj_dir_claude/$g.jsonl" 2>/dev/null)
                if (( mt > newest_mt )); then newest_mt=$mt; newest=$g; fi
            done
            new_guid=$newest
        fi
    fi

    # Cross-check
    if [[ -n "$LAUNCH_SESSION_ID" && -n "$new_guid" ]]; then
        if [[ "$LAUNCH_SESSION_ID" != "$new_guid" ]]; then
            echo ""
            printf "${C_YELLOW}  [warning] Session manifest says %s${C_RESET}\n" "$LAUNCH_SESSION_ID"
            printf "${C_YELLOW}  [warning] Project file delta says %s${C_RESET}\n" "$new_guid"
            printf "${C_YELLOW}  [warning] Using manifest. CMV or Claude wrote files cross-project.${C_RESET}\n"
        fi
    elif [[ -z "$LAUNCH_SESSION_ID" && -n "$new_guid" ]]; then
        LAUNCH_SESSION_ID="$new_guid"
    fi
}

# --- Section 11.7.1: Build-RecoveryMetaPrompt ---
build_recovery_meta_prompt() {
    # Args: dir desc tokens last_date guid
    local dir="$1" desc="$2" tokens="$3" last_date="$4" guid="$5"
    local proj_key proj_dir memory_dir subagents_dir
    proj_key=$(get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    memory_dir="$proj_dir/memory"
    subagents_dir="$proj_dir/$guid/subagents"

    local memory_list=""
    if [[ -d "$memory_dir" ]]; then
        while IFS= read -r f; do
            local sz mt
            sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
            local kb=$((sz / 1024))
            mt=$(date -r "$f" "+%Y-%m-%d" 2>/dev/null || date -d "@$(stat -c%Y "$f")" "+%Y-%m-%d" 2>/dev/null)
            memory_list+="  * $(basename "$f") (${kb} KB, modified ${mt})"$'\n'
        done < <(find "$memory_dir" -name "*.md" 2>/dev/null)
    fi
    [[ -z "$memory_list" ]] && memory_list="  (none)"

    local agent_count=0
    [[ -d "$subagents_dir" ]] && agent_count=$(find "$subagents_dir" -name "*.jsonl" 2>/dev/null | wc -l)

    local subagent_latest="unknown"
    if [[ -d "$subagents_dir" ]]; then
        local latest
        latest=$(find "$subagents_dir" -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
        if [[ -n "$latest" ]]; then
            subagent_latest=$(date -r "$latest" "+%Y-%m-%d" 2>/dev/null || date -d "@$(stat -c%Y "$latest")" "+%Y-%m-%d" 2>/dev/null)
        fi
    fi

    local tok_str="${tokens:+${tokens} tokens}"
    [[ -z "$tok_str" ]] && tok_str="unknown token count"
    local date_str="${last_date:-unknown}"

    cat <<EOF
Context: a Claude Code session was deleted. You need to produce orientation text for a future Claude Code session that will read this text as its first input. Produce the text. That text goes directly into the next session. It is NOT a summary, NOT a description, NOT a report about what you did. It is the directives themselves.

Read these artifacts:
* Memory files in ${memory_dir}
* Subagent transcripts in ${subagents_dir} (2-3 most recent; total on disk: $agent_count, latest dated $subagent_latest)
* The project code at $dir

Session metadata (for reference when you write):
* Session name: $desc
* Project path: $dir
* Last activity: $date_str
* Conversation size when lost: $tok_str

Now replace every <PLACEHOLDER> below and OUTPUT the completed template. Start your output with "This is a recovery session." and end with "ask before assuming." Output nothing else. No preamble, no confirmation, no summary of what you did.

This is a recovery session. The previous conversation transcript for "$desc" was deleted. The project lives at $dir. Memory, subagent state, and source code all survived.

Read these files in this order:

<NUMBERED LIST. Format: "1. <filename>: <one-line description of what this file contains, based on what you read in it>". Use actual file paths from the memory directory.>

Then skim these subagent transcripts for context on in-flight work:

<BULLETED LIST using "*" not "-". Format: "* <filename>: <what this subagent was doing>". Use 2-3 of the most recently modified subagent transcripts. If there are zero subagent transcripts, replace this whole list with the single line: "No surviving subagent transcripts.">

Open questions or in-flight work visible from the artifacts:

<BULLETED LIST using "*" not "-". One line per item. If nothing specific is identifiable, replace this whole list with: "None identified from the artifacts.">

Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming.
EOF
}

# --- Section 11.7: Resolve-ResumeOrRecover ---
RECOVER_ACTION=""
RECOVER_GUID=""
resolve_resume_or_recover() {
    RECOVER_ACTION=""
    RECOVER_GUID=""
    local guid="$1" dir="$2" desc="$3" tokens="$4"
    local proj_key proj_dir jsonl
    proj_key=$(get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    jsonl="$proj_dir/$guid.jsonl"

    if [[ -f "$jsonl" ]]; then
        RECOVER_ACTION="normal"
        RECOVER_GUID="$guid"
        return
    fi

    echo ""
    printf "${C_YELLOW}  The conversation transcript for '%s' has been lost.${C_RESET}\n" "$desc"
    echo "  Probably due to Claude Code's 30-day auto-cleanup."
    echo "  Memory files and subagent state are intact."
    echo ""
    echo "  You have three options:"
    echo "    1. Start a fresh Claude session in that directory"
    echo "    2. Create a recovery-prompt.md file in the project directory, that you can prompt Claude to read and execute, with optional edits."
    echo "    3. Cancel"
    echo ""
    read -rp "  > " choice

    case "$choice" in
        1) RECOVER_ACTION="fresh"; return ;;
        2) ;;
        *) RECOVER_ACTION="cancel"; return ;;
    esac

    if [[ ! -d "$dir" ]]; then
        printf "${C_RED}  Project directory not found: %s${C_RESET}\n" "$dir"
        RECOVER_ACTION="cancel"; return
    fi

    # Rotate existing recovery-prompt.md files
    local primary="$dir/recovery-prompt.md"
    if [[ -f "$primary" ]]; then
        local max_n=1 f n
        for f in "$dir"/recovery-prompt.md.old*; do
            [[ -e "$f" ]] || continue
            if [[ "$f" =~ \.md\.old([0-9]+)$ ]]; then
                n=${BASH_REMATCH[1]}
                (( n >= max_n )) && max_n=$((n + 1))
            fi
        done
        local i src dst
        for ((i = max_n; i >= 1; i--)); do
            if (( i == 1 )); then
                src="$dir/recovery-prompt.md.old"
            else
                src="$dir/recovery-prompt.md.old$i"
            fi
            dst="$dir/recovery-prompt.md.old$((i + 1))"
            [[ -f "$src" ]] && mv "$src" "$dst" 2>/dev/null
        done
        mv "$primary" "$dir/recovery-prompt.md.old" 2>/dev/null
    fi

    echo ""
    printf "${C_CYAN}  Generating recovery prompt (this may take a minute)...${C_RESET}\n"

    # Get last_date for the meta-prompt context
    local info last_date
    info=$(get_session_info "$guid" "$dir" "$tokens")
    last_date=$(echo "$info" | cut -d'|' -f2)

    local meta_prompt
    meta_prompt=$(build_recovery_meta_prompt "$dir" "$desc" "$tokens" "$last_date" "$guid")

    local orig_dir
    orig_dir=$(pwd)
    cd "$dir" || { RECOVER_ACTION="cancel"; return; }

    local primer_json
    primer_json=$(echo "$meta_prompt" | "$CLAUDE_EXE" -p --output-format json --dangerously-skip-permissions 2>/dev/null)

    local recovery_prompt="" primer_session_id=""
    if [[ -n "$primer_json" && -n "$NODE_EXE" ]]; then
        recovery_prompt=$("$NODE_EXE" -e "
            try { console.log(JSON.parse(process.argv[1]).result) } catch(e) {}
        " "$primer_json" 2>/dev/null)
        primer_session_id=$("$NODE_EXE" -e "
            try { console.log(JSON.parse(process.argv[1]).session_id) } catch(e) {}
        " "$primer_json" 2>/dev/null)
    fi

    # Cleanup the throwaway -p session immediately (Section 11.7 step g)
    if [[ -n "$primer_session_id" ]]; then
        local primer_proj_key="$(get_proj_key "$(pwd)")"
        local primer_proj="$HOME/.claude/projects/$primer_proj_key"
        rm -f "$primer_proj/$primer_session_id.jsonl" 2>/dev/null
        [[ -d "$primer_proj/$primer_session_id" ]] && rm -rf "$primer_proj/$primer_session_id" 2>/dev/null
        sync_session_index "$(pwd)"
    fi

    cd "$orig_dir"

    if [[ -z "$recovery_prompt" ]]; then
        printf "${C_RED}  Recovery prompt generation failed.${C_RESET}\n"
        RECOVER_ACTION="cancel"; return
    fi

    echo "$recovery_prompt" > "$primary"
    echo ""
    printf "${C_GREEN}  Recovery prompt saved to:${C_RESET}\n"
    echo "    $primary"
    echo ""
    echo "  Edit it if you want, or just tell Claude to use it as the first message of the conversation."
    printf "${C_CYAN}  Opening a fresh Claude session in that directory now...${C_RESET}\n"
    echo ""
    RECOVER_ACTION="fresh"
}

# --- Section 11.12: Do-DeleteSession ---
swap_session_guid() {
    # Replace old GUID with new GUID for the matching entry; reset its tokens field.
    # Used by the recovery 'fresh' branch after a successful launch.
    local old_guid="$1" new_guid="$2"
    [[ -z "$old_guid" || -z "$new_guid" ]] && return
    [[ -n "$NODE_EXE" ]] || return
    acquire_sessions_lock
    "$NODE_EXE" -e "
        const fs = require('fs');
        const p = '$SESSIONS_FILE';
        const lines = fs.readFileSync(p, 'utf8').split('\n');
        for (let i = 0; i < lines.length; i++) {
            if (lines[i] === '[archived]') break;
            const parts = lines[i].split('|');
            if (parts[0] === '$old_guid') {
                parts[0] = '$new_guid';
                if (parts.length >= 4) parts[3] = '';
                lines[i] = parts.join('|');
            }
        }
        fs.writeFileSync(p, lines.join('\n'));
    " 2>/dev/null
    release_sessions_lock
}

do_delete_session() {
    local guid="$1" dir="$2"
    local proj_key proj_dir_claude
    proj_key=$(get_proj_key "$dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    [[ -f "$proj_dir_claude/$guid.jsonl" ]] && rm -f "$proj_dir_claude/$guid.jsonl"
    [[ -d "$proj_dir_claude/$guid" ]] && rm -rf "$proj_dir_claude/$guid"
    sync_session_index "$dir"
}

# --- Section 11.13: Do-Trim ---
TRIM_NEW_GUID=""
do_trim() {
    TRIM_NEW_GUID=""
    local current_guid="$1"
    if [[ ! -x "$CMV_EXE" ]] && ! command -v "$CMV_EXE" >/dev/null 2>&1; then
        echo "  cmv not found. Skipping trim."
        return
    fi

    # Pre-trim cleanup of stale .cmv-trim-tmp (older than 5 min)
    local sess_line entry_dir proj_key proj_dir_claude
    sess_line=$(grep "^$current_guid|" "$SESSIONS_FILE" | head -1)
    if [[ -n "$sess_line" ]]; then
        entry_dir=$(echo "$sess_line" | cut -d'|' -f2)
        proj_key=$(get_proj_key "$entry_dir")
        proj_dir_claude="$HOME/.claude/projects/$proj_key"
        if [[ -d "$proj_dir_claude" ]]; then
            local cutoff=$((SECONDS + 0))  # placeholder; use absolute epoch
            local now_epoch
            now_epoch=$(date +%s)
            local fmt
            for fmt in "$proj_dir_claude"/*.cmv-trim-tmp; do
                [[ -f "$fmt" ]] || continue
                local mt
                mt=$(stat -c%Y "$fmt" 2>/dev/null || stat -f%m "$fmt" 2>/dev/null)
                if (( now_epoch - mt > 300 )); then
                    printf "${C_GRAY}  Cleaned stale CMV temp file: %s${C_RESET}\n" "$(basename "$fmt")"
                    rm -f "$fmt"
                fi
            done
        fi
    fi

    echo "  Trimming session..."
    local trim_started_at
    trim_started_at=$(date +%s)
    local trim_output
    trim_output=$("$CMV_EXE" trim -s "$current_guid" --skip-launch 2>&1)
    local new_guid
    new_guid=$(echo "$trim_output" | grep -oE 'Session ID:[[:space:]]*[0-9a-f-]+' | head -1 | grep -oE '[0-9a-f-]{36}')
    if [[ -z "$new_guid" ]]; then
        echo "  Trim failed or no new session ID found."
        echo "$trim_output" | head -5 | sed 's/^/  /'
        return
    fi

    # Update sessions.txt: replace old GUID with new
    acquire_sessions_lock
    sed -i "s|^${current_guid}|${new_guid}|" "$SESSIONS_FILE"
    release_sessions_lock

    # Verify trimmed JSONL is in expected project dir; FAIL LOUDLY if not
    local entry expected_dir expected_file
    entry=$(grep "^$new_guid|" "$SESSIONS_FILE" | head -1)
    if [[ -n "$entry" ]]; then
        local entry_d
        entry_d=$(echo "$entry" | cut -d'|' -f2)
        local pk
        pk=$(get_proj_key "$entry_d")
        expected_dir="$HOME/.claude/projects/$pk"
        expected_file="$expected_dir/$new_guid.jsonl"
        if [[ ! -f "$expected_file" ]]; then
            local actual
            actual=$(find "$HOME/.claude/projects" -maxdepth 2 -name "$new_guid.jsonl" 2>/dev/null | head -1)
            if [[ -n "$actual" ]]; then
                echo ""
                printf "${C_RED}  CMV WROTE THE TRIMMED SESSION TO THE WRONG PROJECT${C_RESET}\n"
                printf "${C_RED}  Expected: %s${C_RESET}\n" "$expected_file"
                printf "${C_RED}  Actual:   %s${C_RESET}\n" "$actual"
                echo "  Investigate before resuming. ClaudeCM will NOT silently copy the file."
            else
                echo ""
                printf "${C_RED}  Trim claimed to create %s but the file is not on disk.${C_RESET}\n" "$new_guid"
            fi
        fi
    fi

    echo "$trim_output" | grep -v 'Session ID:' | grep -v '^[[:space:]]*$' | head -10 | sed 's/^/  /'

    # Post-trim cleanup of .cmv-trim-tmp files modified since trim started
    if [[ -d "$proj_dir_claude" ]]; then
        local fmt mt
        for fmt in "$proj_dir_claude"/*.cmv-trim-tmp; do
            [[ -f "$fmt" ]] || continue
            mt=$(stat -c%Y "$fmt" 2>/dev/null || stat -f%m "$fmt" 2>/dev/null)
            if (( mt >= trim_started_at )); then
                printf "${C_GRAY}  CMV left a temp file behind: %s; removing.${C_RESET}\n" "$(basename "$fmt")"
                rm -f "$fmt"
            fi
        done
    fi

    echo ""
    echo "  Session trimmed. New ID: $new_guid"
    TRIM_NEW_GUID="$new_guid"
}

# --- Section 11.14: Do-Refresh ---
locate_extract_skeleton() {
    local script_dir
    script_dir=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
    local candidates=(
        "$script_dir/extract-skeleton.mjs"
        "${CLAUDECM_HOME:-}/extract-skeleton.mjs"
        "$HOME/.claudecm/extract-skeleton.mjs"
        "$HOME/.local/share/claudecm/extract-skeleton.mjs"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

do_refresh() {
    local current_guid="$1"
    local sess_line cur_desc="Unnamed" cur_dir
    cur_dir=$(pwd)
    sess_line=$(grep "^$current_guid|" "$SESSIONS_FILE" | head -1)
    if [[ -n "$sess_line" ]]; then
        cur_desc=$(echo "$sess_line" | cut -d'|' -f3)
        cur_dir=$(echo "$sess_line" | cut -d'|' -f2)
    fi

    echo ""
    read -rp "  Name for new session (Enter for '$cur_desc'): " new_name
    [[ -z "$new_name" ]] && new_name="$cur_desc"

    # Per-operation temp dir + cleanup of stale ones
    mkdir -p "$REFRESH_TEMP_ROOT"
    find "$REFRESH_TEMP_ROOT" -maxdepth 1 -mindepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null
    local refresh_op_id refresh_temp_dir
    refresh_op_id="$(date +%Y%m%d-%H%M%S)-$current_guid"
    refresh_temp_dir="$REFRESH_TEMP_ROOT/$refresh_op_id"
    mkdir -p "$refresh_temp_dir"

    local proj_key proj_dir_claude old_jsonl extract_script
    proj_key=$(get_proj_key "$cur_dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    old_jsonl="$proj_dir_claude/$current_guid.jsonl"

    local skeleton_content="" transcript_path=""
    if extract_script=$(locate_extract_skeleton); then
        if [[ -f "$old_jsonl" && -n "$NODE_EXE" ]]; then
            echo ""
            echo "  Extracting session skeleton..."
            "$NODE_EXE" "$extract_script" "$old_jsonl" "$cur_desc" "$refresh_temp_dir" >/dev/null 2>&1 || true
            local skel_file="$refresh_temp_dir/$current_guid-skeleton.md"
            local tx_file="$refresh_temp_dir/$current_guid-transcript.md"
            if [[ -f "$skel_file" ]]; then
                skeleton_content=$(cat "$skel_file")
                printf "${C_GREEN}  Skeleton extracted.${C_RESET}\n"
            fi
            if [[ -f "$tx_file" ]]; then
                transcript_path="$tx_file"
                local tx_size
                tx_size=$(awk "BEGIN{printf \"%.0f KB\", $(stat -c%s "$tx_file" 2>/dev/null || stat -f%z "$tx_file")/1024}")
                printf "${C_GREEN}  Filtered transcript: %s${C_RESET}\n" "$tx_size"
            fi
        fi
    else
        printf "${C_YELLOW}  extract-skeleton.mjs not found, skipping skeleton extraction.${C_RESET}\n"
    fi

    # Build refresh prompt
    local refresh_prompt
    refresh_prompt=$(cat <<EOF
Read your memories. This is a fresh session replacing a long previous conversation
on this project. Everything you need to know is in:

1) Your memory files (MEMORY.md and all linked files)
2) Any documentation in the project directory
3) The codebase itself (git log for history)
4) project_current_state.md in your memory if it exists
EOF
)
    if [[ -n "$skeleton_content" || -n "$transcript_path" ]]; then
        refresh_prompt+=$'\n5) The structured extraction below, produced by mechanical analysis of the\n   conversation log'
        if [[ -n "$transcript_path" ]]; then
            refresh_prompt+=$'\n6) A filtered transcript of the previous session (conversation text and tool call'
            refresh_prompt+=$'\n   summaries, no tool output) at:'
            refresh_prompt+=$'\n   '"$transcript_path"
            refresh_prompt+=$'\n   Read this file and identify any key decisions, user corrections, or reasoning'
            refresh_prompt+=$'\n   that the skeleton below does not capture.'
        fi
    fi
    refresh_prompt+=$'\n\nIMPORTANT:\n- The files listed below reflect the state at the end of the previous session.\n  Re-read any file before modifying it, as it may have changed since then.\n- The errors listed may or may not still be relevant. Verify before acting on them.\n- Do not start any development until the user tells you to.\n- Tell the user what you understand about the current state of the project,\n  what works, what is pending, and what your behavioral rules are.'
    if [[ -n "$skeleton_content" ]]; then
        refresh_prompt+=$'\n\n--- ADD YOUR NOTES HERE (context, decisions, corrections, anything the skeleton missed) ---\n\n\n\n--- SKELETON START (review and edit as needed) ---\n\n'"$skeleton_content"$'\n\n--- SKELETON END ---'
    fi

    local prompt_file="$CM_DIR/refresh-prompt.tmp"
    echo "$refresh_prompt" > "$prompt_file"

    read -rp "  Edit the compaction prompt and skeleton? (Save and close when done) [y/N] " edit_prompt
    if [[ "$edit_prompt" =~ ^[yY]$ ]]; then
        "$EDITOR" "$prompt_file"
    fi
    local prompt_text
    prompt_text=$(cat "$prompt_file")
    rm -f "$prompt_file"

    local refresh_orig_dir
    refresh_orig_dir=$(pwd)
    cd "$cur_dir" || return
    echo ""
    echo "  Creating fresh session, please wait..."
    "$CLAUDE_EXE" --dangerously-skip-permissions -p "$prompt_text" >/dev/null 2>&1
    echo "  Done."
    cd "$refresh_orig_dir"

    # Find new session GUID
    local fresh_guid
    fresh_guid=$(ls -t "$proj_dir_claude"/*.jsonl 2>/dev/null | while read -r f; do
        local g; g=$(basename "$f" .jsonl)
        [[ "$g" != "$current_guid" ]] && { echo "$g"; break; }
    done)
    if [[ -z "$fresh_guid" ]]; then
        printf "${C_YELLOW}  Warning: Refresh did not create a new session. The old session is unchanged.${C_RESET}\n"
        rm -rf "$refresh_temp_dir" 2>/dev/null
        return
    fi

    # Get token count for fresh session via cmv -s (never --latest)
    local fresh_tokens=""
    if command -v "$CMV_EXE" >/dev/null 2>&1 || [[ -x "$CMV_EXE" ]]; then
        local bench_out
        bench_out=$("$CMV_EXE" benchmark -s "$fresh_guid" --json 2>&1)
        fresh_tokens=$(echo "$bench_out" | grep -oE '"preTrimTokens"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    fi

    # Rebuild sessions: new entry on top, others in place, old entry at bottom with (old) suffix
    acquire_sessions_lock
    local main_tmp arch_tmp
    main_tmp=$(mktemp); arch_tmp=$(mktemp)
    local in_archived=false
    local old_desc="" had_old=false
    while IFS= read -r line; do
        if [[ "$line" == "[archived]" ]]; then in_archived=true; echo "[archived]" >> "$arch_tmp"; continue; fi
        if $in_archived; then [[ -n "$line" ]] && echo "$line" >> "$arch_tmp"; continue; fi
        [[ -z "$line" ]] && continue
        local g; g=$(echo "$line" | cut -d'|' -f1)
        if [[ "$g" == "$current_guid" ]]; then
            had_old=true
            local d t s
            d=$(echo "$line" | cut -d'|' -f2)
            t=$(echo "$line" | cut -d'|' -f3)
            s=$(echo "$line" | cut -d'|' -f4)
            if [[ "$t" =~ \(old[[:space:]]+([0-9]+)\)$ ]]; then
                local n=$((${BASH_REMATCH[1]} + 1))
                old_desc=$(echo "$t" | sed -E "s/\(old[[:space:]]+[0-9]+\)$/(old $n)/")
            elif [[ "$t" =~ \(old\)$ ]]; then
                old_desc=$(echo "$t" | sed -E 's/\(old\)$/(old 2)/')
            else
                old_desc="$t (old)"
            fi
            # Stash old entry (we'll append later)
            echo "$current_guid|$d|$old_desc|$s" > "$main_tmp.old"
        else
            echo "$line" >> "$main_tmp"
        fi
    done < "$SESSIONS_FILE"

    {
        echo "$fresh_guid|$cur_dir|$new_name|$fresh_tokens"
        cat "$main_tmp"
        $had_old && cat "$main_tmp.old"
        cat "$arch_tmp"
    } | write_sessions_atomic
    rm -f "$main_tmp" "$main_tmp.old" "$arch_tmp"
    release_sessions_lock

    echo ""
    echo "  Fresh session created: $new_name"
    echo "  Old session moved to bottom of list."

    rm -rf "$refresh_temp_dir" 2>/dev/null
}

# --- Section 11.15: Do-PostExit ---
do_post_exit() {
    local known_guid="${1:-}"
    echo ""
    echo "  Session ended."
    echo ""

    # Resolve GUID (project-scoped, NEVER cross-project)
    local guid="$known_guid"
    if [[ -z "$guid" ]]; then
        local proj_key proj_dir_claude
        proj_key=$(get_proj_key "$(pwd)")
        proj_dir_claude="$HOME/.claude/projects/$proj_key"
        [[ -d "$proj_dir_claude" ]] || return
        guid=$(ls -t "$proj_dir_claude"/*.jsonl 2>/dev/null | while read -r f; do
            local n; n=$(basename "$f" .jsonl)
            case "$n" in agent-*) ;; *) echo "$n"; break ;; esac
        done)
        [[ -z "$guid" ]] && return
    fi

    # Auto-snapshot via cmv -s (NEVER --latest)
    if command -v "$CMV_EXE" >/dev/null 2>&1 || [[ -x "$CMV_EXE" ]]; then
        local snap_label="auto-exit-$(date +%Y%m%d-%H%M%S)"
        ("$CMV_EXE" snapshot "$snap_label" -s "$guid" >/dev/null 2>&1) &
        local snap_pid=$!
        local spin=('-' '\' '|' '/')
        local i=0
        while kill -0 "$snap_pid" 2>/dev/null; do
            printf "\r  %s Saving snapshot..." "${spin[$((i % 4))]}"
            sleep 0.1
            ((i++))
        done
        printf "\r  Done.                        \n"
    fi

    # Look up entry, update or register
    local existing
    existing=$(grep "^$guid|" "$SESSIONS_FILE" | head -1)
    if [[ -n "$existing" ]]; then
        local fresh_tokens=""
        if command -v "$CMV_EXE" >/dev/null 2>&1 || [[ -x "$CMV_EXE" ]]; then
            local bench_out
            bench_out=$("$CMV_EXE" benchmark -s "$guid" --json 2>&1)
            fresh_tokens=$(echo "$bench_out" | grep -oE '"preTrimTokens"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
        fi
        local d desc
        d=$(echo "$existing" | cut -d'|' -f2)
        desc=$(echo "$existing" | cut -d'|' -f3)
        # Move to top with updated tokens
        acquire_sessions_lock
        local main_tmp arch_tmp
        main_tmp=$(mktemp); arch_tmp=$(mktemp)
        local in_archived=false
        while IFS= read -r line; do
            if [[ "$line" == "[archived]" ]]; then in_archived=true; echo "[archived]" >> "$arch_tmp"; continue; fi
            if $in_archived; then [[ -n "$line" ]] && echo "$line" >> "$arch_tmp"; continue; fi
            [[ -z "$line" ]] && continue
            local g; g=$(echo "$line" | cut -d'|' -f1)
            [[ "$g" == "$guid" ]] && continue
            echo "$line" >> "$main_tmp"
        done < "$SESSIONS_FILE"
        {
            echo "$guid|$d|$desc|${fresh_tokens:-$(echo "$existing" | cut -d'|' -f4)}"
            cat "$main_tmp"
            cat "$arch_tmp"
        } | write_sessions_atomic
        rm -f "$main_tmp" "$arch_tmp"
        release_sessions_lock
    else
        echo ""
        local folder_default
        folder_default=$(basename "$(pwd)" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
        read -rp "  Describe this session (Enter for '$folder_default', 'skip' to skip): " desc
        [[ "$desc" == "skip" ]] && return
        [[ -z "$desc" ]] && desc="$folder_default"
        acquire_sessions_lock
        local tmp; tmp=$(mktemp)
        echo "$guid|$(pwd)|$desc|" > "$tmp"
        cat "$SESSIONS_FILE" >> "$tmp"
        mv "$tmp" "$SESSIONS_FILE"
        release_sessions_lock
    fi

    # Sync session index
    local cur_line
    cur_line=$(grep "^$guid|" "$SESSIONS_FILE" | head -1)
    if [[ -n "$cur_line" ]]; then
        local sd; sd=$(echo "$cur_line" | cut -d'|' -f2)
        sync_session_index "$sd"
    fi

    # Show size and offer trim/refresh
    if [[ -n "$cur_line" ]]; then
        local d t info size_str tok_str
        d=$(echo "$cur_line" | cut -d'|' -f2)
        t=$(echo "$cur_line" | cut -d'|' -f4)
        info=$(get_session_info "$guid" "$d" "$t")
        size_str=$(echo "$info" | cut -d'|' -f1)
        tok_str=$(echo "$info" | cut -d'|' -f3)
        echo ""
        echo "  Current session: $size_str ($tok_str)"
    fi

    echo ""
    read -rp "  Trim this session? [y/N] " do_trim_ans
    if [[ "$do_trim_ans" =~ ^[yY]$ ]]; then
        do_trim "$guid"
        [[ -n "$TRIM_NEW_GUID" ]] && guid="$TRIM_NEW_GUID"
    fi

    echo ""
    read -rp "  Create a new compacted session, built from a structured rebuild of this one? [y/N] " do_refresh_ans
    if [[ "$do_refresh_ans" =~ ^[yY]$ ]]; then
        do_refresh "$guid"
    fi
}

# --- Section 11.10: Do-EditList ---
do_edit_list() {
    while true; do
        echo ""
        echo "  === Edit Sessions ==="
        echo ""
        local i=0
        while IFS='|' read -r guid dir desc tokens; do
            [[ -z "$guid" ]] && continue
            [[ "$guid" == "[archived]" ]] && break
            ((i++))
            echo "  $i. $desc  [$dir]"
        done < "$SESSIONS_FILE"
        echo ""
        echo "  R# = Rename   P# = Path   A# = Archive   D# = Delete   M#,# = Move   Q = Done"
        echo ""
        read -rp "  > " cmd
        [[ -z "$cmd" || "$cmd" =~ ^[qQ]$ ]] && return

        if [[ "$cmd" =~ ^[rR]([0-9]+)$ ]]; then
            local idx=${BASH_REMATCH[1]}
            local line; line=$(get_sessions | sed -n "${idx}p")
            if [[ -n "$line" ]]; then
                local cur_desc; cur_desc=$(echo "$line" | cut -d'|' -f4)
                read -rp "  New name for '$cur_desc': " new_name
                if [[ -n "$new_name" ]]; then
                    local g d t
                    g=$(echo "$line" | cut -d'|' -f2)
                    d=$(echo "$line" | cut -d'|' -f3)
                    t=$(echo "$line" | cut -d'|' -f5)
                    acquire_sessions_lock
                    local tmp; tmp=$(mktemp)
                    local cnt=0 in_arch=false
                    while IFS= read -r ln; do
                        if [[ "$ln" == "[archived]" ]]; then in_arch=true; echo "$ln" >> "$tmp"; continue; fi
                        if $in_arch || [[ -z "$ln" ]]; then [[ -n "$ln" ]] && echo "$ln" >> "$tmp"; continue; fi
                        ((cnt++))
                        if (( cnt == idx )); then
                            echo "$g|$d|$new_name|$t" >> "$tmp"
                        else
                            echo "$ln" >> "$tmp"
                        fi
                    done < "$SESSIONS_FILE"
                    mv "$tmp" "$SESSIONS_FILE"
                    release_sessions_lock
                fi
            else
                echo "  Invalid number."
            fi
        elif [[ "$cmd" =~ ^[pP]([0-9]+)$ ]]; then
            local idx=${BASH_REMATCH[1]}
            local line; line=$(get_sessions | sed -n "${idx}p")
            if [[ -n "$line" ]]; then
                local g cur_d desc t
                g=$(echo "$line" | cut -d'|' -f2)
                cur_d=$(echo "$line" | cut -d'|' -f3)
                desc=$(echo "$line" | cut -d'|' -f4)
                t=$(echo "$line" | cut -d'|' -f5)
                echo "  Current: $cur_d"
                read -rp "  New path (Enter to keep): " new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! -d "$new_path" ]]; then
                        echo "  Path does not exist: $new_path"
                        continue
                    fi
                    local old_key new_key claude_proj old_file new_dir new_file
                    old_key=$(get_proj_key "$cur_d")
                    new_key=$(get_proj_key "$new_path")
                    claude_proj="$HOME/.claude/projects"
                    old_file="$claude_proj/$old_key/$g.jsonl"
                    new_dir="$claude_proj/$new_key"
                    new_file="$new_dir/$g.jsonl"
                    if [[ -f "$old_file" ]]; then
                        mkdir -p "$new_dir"
                        cp "$old_file" "$new_file"
                        echo "  Session file copied to new project directory."
                    else
                        echo "  Warning: Session file not found at old path. Resume may not work."
                    fi
                    acquire_sessions_lock
                    local tmp; tmp=$(mktemp)
                    local cnt=0 in_arch=false
                    while IFS= read -r ln; do
                        if [[ "$ln" == "[archived]" ]]; then in_arch=true; echo "$ln" >> "$tmp"; continue; fi
                        if $in_arch || [[ -z "$ln" ]]; then [[ -n "$ln" ]] && echo "$ln" >> "$tmp"; continue; fi
                        ((cnt++))
                        if (( cnt == idx )); then
                            echo "$g|$new_path|$desc|$t" >> "$tmp"
                        else
                            echo "$ln" >> "$tmp"
                        fi
                    done < "$SESSIONS_FILE"
                    mv "$tmp" "$SESSIONS_FILE"
                    release_sessions_lock
                    sync_session_index "$new_path"
                    sync_session_index "$cur_d"
                fi
            else
                echo "  Invalid number."
            fi
        elif [[ "$cmd" =~ ^[aA]([0-9]+)$ ]]; then
            local idx=${BASH_REMATCH[1]}
            local line; line=$(get_sessions | sed -n "${idx}p")
            if [[ -n "$line" ]]; then
                local g d desc t
                g=$(echo "$line" | cut -d'|' -f2)
                d=$(echo "$line" | cut -d'|' -f3)
                desc=$(echo "$line" | cut -d'|' -f4)
                t=$(echo "$line" | cut -d'|' -f5)
                acquire_sessions_lock
                local tmp; tmp=$(mktemp)
                local cnt=0 in_arch=false has_arch=false arch_tmp; arch_tmp=$(mktemp)
                while IFS= read -r ln; do
                    if [[ "$ln" == "[archived]" ]]; then in_arch=true; continue; fi
                    if $in_arch; then
                        [[ -n "$ln" ]] && { has_arch=true; echo "$ln" >> "$arch_tmp"; }
                        continue
                    fi
                    [[ -z "$ln" ]] && continue
                    ((cnt++))
                    if (( cnt == idx )); then
                        echo "$g|$d|$desc|$t" >> "$arch_tmp"
                        has_arch=true
                    else
                        echo "$ln" >> "$tmp"
                    fi
                done < "$SESSIONS_FILE"
                {
                    cat "$tmp"
                    if $has_arch; then echo "[archived]"; cat "$arch_tmp"; fi
                } | write_sessions_atomic
                rm -f "$tmp" "$arch_tmp"
                release_sessions_lock
                printf "${C_GREEN}  Archived: %s${C_RESET}\n" "$desc"
            else
                echo "  Invalid number."
            fi
        elif [[ "$cmd" =~ ^[dD]([0-9]+)$ ]]; then
            local idx=${BASH_REMATCH[1]}
            local line; line=$(get_sessions | sed -n "${idx}p")
            if [[ -n "$line" ]]; then
                local g d desc
                g=$(echo "$line" | cut -d'|' -f2)
                d=$(echo "$line" | cut -d'|' -f3)
                desc=$(echo "$line" | cut -d'|' -f4)
                printf "${C_RED}  This permanently deletes the conversation file and all associated data.${C_RESET}\n"
                printf "${C_RED}  This cannot be undone.${C_RESET}\n"
                read -rp "  Type 'delete' to confirm: " confirm
                if [[ "${confirm,,}" == "delete" ]]; then
                    do_delete_session "$g" "$d"
                    acquire_sessions_lock
                    grep -v "^$g|" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp"
                    mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
                    release_sessions_lock
                    printf "${C_GREEN}  Deleted: %s${C_RESET}\n" "$desc"
                else
                    echo "  Cancelled."
                fi
            else
                echo "  Invalid number."
            fi
        elif [[ "$cmd" =~ ^[mM]([0-9]+),([0-9]+)$ ]]; then
            local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}
            local main_lines=()
            while IFS= read -r ln; do
                [[ "$ln" == "[archived]" ]] && break
                [[ -n "$ln" ]] && main_lines+=("$ln")
            done < "$SESSIONS_FILE"
            local n=${#main_lines[@]}
            if (( from >= 1 && from <= n && to >= 1 && to <= n )); then
                local item="${main_lines[$((from - 1))]}"
                # Remove from old position
                local new_arr=()
                local j=0
                for ln in "${main_lines[@]}"; do
                    ((j++))
                    [[ $j -eq $from ]] && continue
                    new_arr+=("$ln")
                done
                # Insert at new position
                local final=()
                local k=0
                for ln in "${new_arr[@]}"; do
                    ((k++))
                    [[ $k -eq $to ]] && final+=("$item")
                    final+=("$ln")
                done
                # Edge case: inserting at end
                if (( to > ${#new_arr[@]} )); then final+=("$item"); fi
                printf '%s\n' "${final[@]}" | save_sessions
            else
                echo "  Invalid numbers."
            fi
        else
            echo "  Unknown command."
        fi
    done
}

# --- Section 11.11: Do-ViewArchived ---
do_view_archived() {
    while true; do
        local arch_lines=()
        while IFS= read -r ln; do
            arch_lines+=("$ln")
        done < <(get_archived_sessions)
        if [[ ${#arch_lines[@]} -eq 0 ]]; then
            echo ""
            echo "  No archived sessions."
            return
        fi
        echo ""
        echo "  === Archived Sessions ==="
        echo ""
        local aline
        for aline in "${arch_lines[@]}"; do
            IFS='|' read -r idx guid dir desc tokens <<< "$aline"
            local n=$((idx + 1))
            local info size_str
            info=$(get_session_info "$guid" "$dir" "${tokens:-}")
            size_str=$(echo "$info" | cut -d'|' -f1)
            echo "  $n. $desc  [$dir]  $size_str"
        done
        echo ""
        echo "  U# = Unarchive   D# = Delete permanently   Q = Back"
        echo ""
        read -rp "  > " cmd
        [[ -z "$cmd" || "$cmd" =~ ^[qQ]$ ]] && return

        if [[ "$cmd" =~ ^[uU]([0-9]+)$ ]]; then
            local pick=${BASH_REMATCH[1]}
            local target_line=""
            for aline in "${arch_lines[@]}"; do
                IFS='|' read -r idx guid dir desc tokens <<< "$aline"
                if (( idx + 1 == pick )); then
                    target_line="$guid|$dir|$desc|$tokens"
                    break
                fi
            done
            if [[ -n "$target_line" ]]; then
                acquire_sessions_lock
                local main_tmp arch_tmp
                main_tmp=$(mktemp); arch_tmp=$(mktemp)
                echo "$target_line" > "$main_tmp"
                local in_arch=false has_arch=false
                while IFS= read -r ln; do
                    if [[ "$ln" == "[archived]" ]]; then in_arch=true; continue; fi
                    if $in_arch; then
                        [[ -n "$ln" && "$ln" != "$target_line" ]] && { has_arch=true; echo "$ln" >> "$arch_tmp"; }
                    else
                        [[ -n "$ln" ]] && echo "$ln" >> "$main_tmp"
                    fi
                done < "$SESSIONS_FILE"
                {
                    cat "$main_tmp"
                    if $has_arch; then echo "[archived]"; cat "$arch_tmp"; fi
                } | write_sessions_atomic
                rm -f "$main_tmp" "$arch_tmp"
                release_sessions_lock
                printf "${C_GREEN}  Unarchived: %s${C_RESET}\n" "$desc"
            else
                echo "  Invalid number."
            fi
        elif [[ "$cmd" =~ ^[dD]([0-9]+)$ ]]; then
            local pick=${BASH_REMATCH[1]}
            local tg="" td="" tdesc="" target_line=""
            for aline in "${arch_lines[@]}"; do
                IFS='|' read -r idx guid dir desc tokens <<< "$aline"
                if (( idx + 1 == pick )); then
                    tg=$guid; td=$dir; tdesc=$desc
                    target_line="$guid|$dir|$desc|$tokens"
                    break
                fi
            done
            if [[ -n "$tg" ]]; then
                printf "${C_RED}  This permanently deletes the conversation file and all associated data.${C_RESET}\n"
                printf "${C_RED}  This cannot be undone.${C_RESET}\n"
                read -rp "  Type 'delete' to confirm: " confirm
                if [[ "${confirm,,}" == "delete" ]]; then
                    do_delete_session "$tg" "$td"
                    acquire_sessions_lock
                    local main_tmp arch_tmp
                    main_tmp=$(mktemp); arch_tmp=$(mktemp)
                    local in_arch=false has_arch=false
                    while IFS= read -r ln; do
                        if [[ "$ln" == "[archived]" ]]; then in_arch=true; continue; fi
                        if $in_arch; then
                            [[ -n "$ln" && "$ln" != "$target_line" ]] && { has_arch=true; echo "$ln" >> "$arch_tmp"; }
                        else
                            [[ -n "$ln" ]] && echo "$ln" >> "$main_tmp"
                        fi
                    done < "$SESSIONS_FILE"
                    {
                        cat "$main_tmp"
                        if $has_arch; then echo "[archived]"; cat "$arch_tmp"; fi
                    } | write_sessions_atomic
                    rm -f "$main_tmp" "$arch_tmp"
                    release_sessions_lock
                    printf "${C_GREEN}  Deleted: %s${C_RESET}\n" "$tdesc"
                else
                    echo "  Cancelled."
                fi
            else
                echo "  Invalid number."
            fi
        else
            echo "  Unknown command."
        fi
    done
}

# --- Section 11.9: Do-Resume ---
do_resume() {
    local pick="$1"
    local lines=()
    while IFS= read -r ln; do
        [[ "$ln" == "[archived]" ]] && break
        [[ -n "$ln" ]] && lines+=("$ln")
    done < "$SESSIONS_FILE"
    if (( pick < 1 || pick > ${#lines[@]} )); then
        echo "  Invalid selection."
        return
    fi
    local sel="${lines[$((pick - 1))]}"
    local sel_guid sel_dir sel_desc sel_tokens
    sel_guid=$(echo "$sel" | cut -d'|' -f1)
    sel_dir=$(echo "$sel" | cut -d'|' -f2)
    sel_desc=$(echo "$sel" | cut -d'|' -f3)
    sel_tokens=$(echo "$sel" | cut -d'|' -f4)

    if [[ ! -d "$sel_dir" ]]; then
        echo "  Error: Project directory not found: $sel_dir"
        return
    fi
    local orig_dir; orig_dir=$(pwd)
    cd "$sel_dir" || return

    if do_orphan_scan "$sel_dir" "$sel_guid"; then
        local display_name; display_name=$(get_display_name "$sel_desc")
        invoke_claude_launch --dir "$sel_dir" -- --dangerously-skip-permissions --resume "$ORPHAN_SELECTED_GUID" -n "$display_name"
        if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
            local pg="${LAUNCH_SESSION_ID:-$ORPHAN_SELECTED_GUID}"
            do_post_exit "$pg"
        fi
        cd "$orig_dir" || true
        return
    fi

    resolve_resume_or_recover "$sel_guid" "$sel_dir" "$sel_desc" "$sel_tokens"
    if [[ "$RECOVER_ACTION" == "cancel" ]]; then cd "$orig_dir" || true; return; fi
    local display_name; display_name=$(get_display_name "$sel_desc")

    if [[ "$RECOVER_ACTION" == "fresh" ]]; then
        # Do NOT delete the old entry before launch. If the launch fails the entry would
        # be unrecoverable. Swap GUID in place AFTER successful launch.
        invoke_claude_launch --dir "$sel_dir" -- --dangerously-skip-permissions -n "$display_name"
        if [[ $LAUNCH_EXIT_CODE -eq 0 && -n "$LAUNCH_SESSION_ID" ]]; then
            swap_session_guid "$sel_guid" "$LAUNCH_SESSION_ID"
            do_post_exit "$LAUNCH_SESSION_ID"
        fi
        cd "$orig_dir" || true
        return
    fi
    if [[ "$RECOVER_ACTION" == "primed" ]]; then
        invoke_claude_launch --dir "$sel_dir" -- --dangerously-skip-permissions --resume "$RECOVER_GUID" -n "$display_name"
        if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
            local pg="${LAUNCH_SESSION_ID:-$RECOVER_GUID}"
            do_post_exit "$pg"
        fi
        cd "$orig_dir" || true
        return
    fi

    invoke_claude_launch --dir "$sel_dir" -- --dangerously-skip-permissions --resume "$sel_guid" -n "$display_name"
    if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
        local pg="${LAUNCH_SESSION_ID:-$sel_guid}"
        do_post_exit "$pg"
    else
        echo ""
        read -rp "  Session not found. Delete this entry? [Y/n] " del_entry
        if [[ "$del_entry" != "n" ]]; then
            acquire_sessions_lock
            grep -v "^$sel_guid|" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp"
            mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
            release_sessions_lock
            echo "  Entry removed."
        fi
    fi
    cd "$orig_dir" || true
}

# --- Section 11.7-11.8: New project from list mode ---
start_new_project_from_list() {
    local title="$1"
    local safe_name new_dir counter=1
    safe_name=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/-/g; s/[^a-z0-9_-]//g')
    new_dir="$(pwd)/$safe_name"
    while [[ -e "$new_dir" ]]; do
        new_dir="$(pwd)/${safe_name}(${counter})"
        ((counter++))
    done
    mkdir -p "$new_dir"
    echo ""
    echo "  Starting new session: $title"
    echo "  Project dir: $new_dir"
    local orig_dir; orig_dir=$(pwd)
    cd "$new_dir" || return
    local display_name; display_name=$(get_display_name "$title")
    invoke_claude_launch --dir "$new_dir" -- --dangerously-skip-permissions -n "$display_name"
    if [[ -n "$LAUNCH_SESSION_ID" ]]; then
        acquire_sessions_lock
        local tmp; tmp=$(mktemp)
        echo "$LAUNCH_SESSION_ID|$new_dir|$title|" > "$tmp"
        cat "$SESSIONS_FILE" >> "$tmp"
        mv "$tmp" "$SESSIONS_FILE"
        release_sessions_lock
    fi
    cd "$orig_dir" || true
}

# --- Section 11.1: List mode ---
list_mode() {
    while true; do
        local count
        count=$(get_session_count)
        if (( count == 0 )); then
            echo ""
            echo "  No saved sessions."
            echo ""
            return
        fi
        show_list
        echo ""
        read -rp "  Pick a session (Enter to quit): " pick
        [[ -z "$pick" ]] && return
        if [[ "$pick" =~ ^[eE]$ ]]; then do_edit_list; continue; fi
        if [[ "$pick" =~ ^[vV]$ ]]; then do_view_archived; continue; fi
        if [[ "$pick" =~ ^[mM]$ ]]; then
            echo ""
            echo "  Current machine name: $MACHINE_NAME"
            read -rp "  New name (Enter to keep): " new_mn
            if [[ -n "$new_mn" ]]; then
                echo "$new_mn" > "$MACHINE_NAME_FILE"
                MACHINE_NAME="$new_mn"
                printf "${C_GREEN}  Machine name set to: %s${C_RESET}\n" "$MACHINE_NAME"
            fi
            continue
        fi
        if [[ "$pick" =~ ^[0-9]+$ ]]; then
            do_resume "$pick"
            return
        fi
        # Treat as new project title
        start_new_project_from_list "$pick"
        return
    done
}

# --- Main dispatch ---
first_arg="${1:-}"

# List mode
case "$first_arg" in
    l|L|-l|-L) list_mode; exit 0 ;;
esac

# Direct resume by number
if [[ "$first_arg" =~ ^[0-9]+$ ]]; then
    count=$(get_session_count)
    if (( count == 0 )); then
        echo "  No saved sessions."
        exit 0
    fi
    show_list "$first_arg"
    do_resume "$first_arg"
    exit 0
fi

# Normal mode: parse --proj and pass-args
proj_dir=""
pass_args=()
i=1
while (( i <= $# )); do
    arg="${!i}"
    if [[ "$arg" == "--proj" ]]; then
        ((i++))
        proj_dir="${!i}"
        ((i++))
    else
        pass_args+=("$arg")
        ((i++))
    fi
done

orig_dir=$(pwd)
if [[ -n "$proj_dir" ]]; then
    if [[ ! -d "$proj_dir" ]]; then
        echo "Error: Directory not found: $proj_dir"
        exit 1
    fi
    cd "$proj_dir" || exit 1
fi

cur_dir=$(pwd)
match_line=$(grep -F "|$cur_dir|" "$SESSIONS_FILE" 2>/dev/null | head -1)
pre_named=""

if [[ -n "$match_line" && ${#pass_args[@]} -eq 0 ]]; then
    match_guid=$(echo "$match_line" | cut -d'|' -f1)
    match_desc=$(echo "$match_line" | cut -d'|' -f3)
    match_tokens=$(echo "$match_line" | cut -d'|' -f4)

    if do_orphan_scan "$cur_dir" "$match_guid"; then
        display_name=$(get_display_name "$match_desc")
        invoke_claude_launch --dir "$cur_dir" -- --dangerously-skip-permissions --resume "$ORPHAN_SELECTED_GUID" -n "$display_name"
        if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
            pg="${LAUNCH_SESSION_ID:-$ORPHAN_SELECTED_GUID}"
            do_post_exit "$pg"
        fi
        [[ -n "$proj_dir" ]] && cd "$orig_dir"
        exit 0
    fi

    echo ""
    echo "  Session found: $match_desc"
    read -rp "  Rename? (Enter to keep): " rename
    if [[ -n "$rename" ]]; then
        acquire_sessions_lock
        sed -i "s|^${match_guid}|${cur_dir}|.*|${match_guid}|${cur_dir}|${rename}|.*|" "$SESSIONS_FILE" 2>/dev/null
        # The above sed is finicky with separators; do it via node for safety
        if [[ -n "$NODE_EXE" ]]; then
            "$NODE_EXE" -e "
                const fs = require('fs');
                const lines = fs.readFileSync('$SESSIONS_FILE', 'utf8').split('\n');
                for (let i = 0; i < lines.length; i++) {
                    if (lines[i] === '[archived]') break;
                    const p = lines[i].split('|');
                    if (p[0] === '$match_guid') {
                        p[2] = '$rename';
                        lines[i] = p.join('|');
                    }
                }
                fs.writeFileSync('$SESSIONS_FILE', lines.join('\n'));
            " 2>/dev/null
        fi
        release_sessions_lock
        match_desc="$rename"
    fi
    read -rp "  Resume this session? [Y/n] " use_existing
    if [[ "$use_existing" != "n" ]]; then
        resolve_resume_or_recover "$match_guid" "$cur_dir" "$match_desc" "$match_tokens"
        if [[ "$RECOVER_ACTION" == "cancel" ]]; then [[ -n "$proj_dir" ]] && cd "$orig_dir"; exit 0; fi
        display_name=$(get_display_name "$match_desc")

        if [[ "$RECOVER_ACTION" == "fresh" ]]; then
            # Do NOT delete the old entry before launch. Swap GUID in place AFTER successful launch.
            invoke_claude_launch --dir "$cur_dir" -- --dangerously-skip-permissions -n "$display_name"
            if [[ $LAUNCH_EXIT_CODE -eq 0 && -n "$LAUNCH_SESSION_ID" ]]; then
                swap_session_guid "$match_guid" "$LAUNCH_SESSION_ID"
                do_post_exit "$LAUNCH_SESSION_ID"
            fi
            [[ -n "$proj_dir" ]] && cd "$orig_dir"
            exit 0
        fi
        if [[ "$RECOVER_ACTION" == "primed" ]]; then
            invoke_claude_launch --dir "$cur_dir" -- --dangerously-skip-permissions --resume "$RECOVER_GUID" -n "$display_name"
            if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
                pg="${LAUNCH_SESSION_ID:-$RECOVER_GUID}"
                do_post_exit "$pg"
            fi
            [[ -n "$proj_dir" ]] && cd "$orig_dir"
            exit 0
        fi

        invoke_claude_launch --dir "$cur_dir" -- --dangerously-skip-permissions --resume "$match_guid" -n "$display_name"
        if [[ $LAUNCH_EXIT_CODE -eq 0 ]]; then
            pg="${LAUNCH_SESSION_ID:-$match_guid}"
            do_post_exit "$pg"
        else
            echo ""
            read -rp "  Session not found. Delete this entry? [Y/n] " del_entry
            if [[ "$del_entry" != "n" ]]; then
                acquire_sessions_lock
                grep -v "^$match_guid|" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp"
                mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
                release_sessions_lock
                echo "  Entry removed."
            fi
        fi
        [[ -n "$proj_dir" ]] && cd "$orig_dir"
        exit 0
    fi
fi

if [[ -z "$match_line" && ${#pass_args[@]} -eq 0 ]]; then
    echo ""
    echo "  No session entry found for this directory."
    folder_default=$(basename "$(pwd)" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
    read -rp "  Create a name for this session (Enter for '$folder_default', 'skip' to skip): " pre_named
    if [[ "$pre_named" == "skip" ]]; then pre_named=""
    elif [[ -z "$pre_named" ]]; then pre_named="$folder_default"
    fi
fi

# Fresh launch
launch_desc="${pre_named:-${match_desc:-$(basename "$(pwd)")}}"
display_name=$(get_display_name "$launch_desc")
launch_args=(--dangerously-skip-permissions -n "$display_name")
[[ ${#pass_args[@]} -gt 0 ]] && launch_args+=("${pass_args[@]}")
invoke_claude_launch --dir "$(pwd)" -- "${launch_args[@]}"

if [[ $LAUNCH_EXIT_CODE -ne 0 ]]; then
    [[ -n "$proj_dir" ]] && cd "$orig_dir"
    exit $LAUNCH_EXIT_CODE
fi

if [[ -n "$pre_named" && -n "$LAUNCH_SESSION_ID" ]]; then
    acquire_sessions_lock
    tmp=$(mktemp)
    echo "$LAUNCH_SESSION_ID|$cur_dir|$pre_named|" > "$tmp"
    cat "$SESSIONS_FILE" >> "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
    release_sessions_lock
    do_post_exit "$LAUNCH_SESSION_ID"
else
    do_post_exit "$LAUNCH_SESSION_ID"
fi

[[ -n "$proj_dir" ]] && cd "$orig_dir"
exit 0
