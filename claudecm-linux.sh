#!/usr/bin/env bash
# claudecm-linux.sh - Claude Context Manager for Linux / macOS
#
# Conforms to claudecm-project-spec.md. Port of claudecm-powershell.ps1.
# Source this file from ~/.bashrc or ~/.zshrc to get the `claudecm` function.
#
# Dependencies: claude (required), jq or node (for JSON), flock (util-linux),
# cmv (optional; snapshot/trim/refresh degrade gracefully if missing).
#
# NOTE: This script has not been tested on a real Linux system. It is a
# faithful port of the PowerShell implementation, built from the spec.
# Exercise caution and verify behavior before relying on it.

# If running as root, re-exec as claude user
if [[ $(id -u) -eq 0 ]]; then
    exec sudo -u claude "$0" "$@"
fi

# ==================================================================
# Color helpers
# ==================================================================
__CM_C_RESET=$'\033[0m'
__CM_C_RED=$'\033[31m'
__CM_C_GREEN=$'\033[32m'
__CM_C_YELLOW=$'\033[33m'
__CM_C_CYAN=$'\033[36m'
__CM_C_DARKGRAY=$'\033[90m'

__cm_say()     { printf '  %s\n' "$*"; }
__cm_say_c()   { local c="$1"; shift; printf '  %b%s%b\n' "$c" "$*" "$__CM_C_RESET"; }
__cm_blank()   { printf '\n'; }

# ==================================================================
# Paths and executable lookup
# ==================================================================
__cm_cm_dir="$HOME/.claudecm"
__cm_sessions_file="$__cm_cm_dir/sessions.txt"
__cm_lock_file="$__cm_sessions_file.lock"
__cm_tmp_file="$__cm_sessions_file.tmp"
__cm_machine_name_file="$__cm_cm_dir/machine-name.txt"
__cm_backup_dir="$__cm_cm_dir/backup"
__cm_quarantine_root="$HOME/claude-conversation-backup"

__cm_find_exe() {
    # Returns first existing/on-PATH executable from the candidate list.
    local c
    for c in "$@"; do
        if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
        if [[ -x "$c" ]]; then printf '%s\n' "$c"; return 0; fi
    done
    return 1
}

__cm_resolve_claude()  { __cm_find_exe claude "$HOME/.local/bin/claude"; }
__cm_resolve_cmv()     { __cm_find_exe cmv "$HOME/.npm-global/bin/cmv"; }
__cm_resolve_node()    { __cm_find_exe node; }
__cm_resolve_jq()      { __cm_find_exe jq; }

# ==================================================================
# JSON parse helper (jq preferred, node fallback)
# ==================================================================
__cm_json_get() {
    # Usage: __cm_json_get <json-string> <field>
    # Returns field value on stdout, empty on failure. Supports top-level only.
    local json="$1" field="$2" jq
    if jq=$(__cm_resolve_jq); then
        printf '%s' "$json" | "$jq" -r ".${field} // empty" 2>/dev/null
    else
        local node
        if node=$(__cm_resolve_node); then
            printf '%s' "$json" | "$node" -e "
let s=''; process.stdin.on('data',d=>s+=d);
process.stdin.on('end',()=>{try{const o=JSON.parse(s);const v=o['$field'];if(v!==undefined&&v!==null)process.stdout.write(String(v));}catch(e){}});
" 2>/dev/null
        fi
    fi
}

# ==================================================================
# Bootstrap: cleanupPeriodDays protection
# ==================================================================
__cm_ensure_cleanup_period_days() {
    local settings="$HOME/.claude/settings.json"
    [[ -f "$settings" ]] || return 0
    local node; node=$(__cm_resolve_node) || return 0
    local current
    current=$("$node" -e "try{const s=JSON.parse(require('fs').readFileSync('$settings','utf8'));process.stdout.write(String(s.cleanupPeriodDays||''))}catch(e){}" 2>/dev/null)
    if [[ -z "$current" ]] || (( current < 1000 )); then
        local ts; ts=$(date +%Y%m%d-%H%M%S)
        mkdir -p "$__cm_backup_dir" 2>/dev/null
        cp -f "$settings" "$__cm_backup_dir/settings.json.$ts" 2>/dev/null
        "$node" -e "
try{const fs=require('fs');const s=JSON.parse(fs.readFileSync('$settings','utf8'));s.cleanupPeriodDays=100000;fs.writeFileSync('$settings',JSON.stringify(s,null,2));}catch(e){}
" 2>/dev/null
        __cm_say_c "$__CM_C_CYAN" "Protected session transcripts from Claude Code's 30-day auto-delete."
    fi
}

# ==================================================================
# Lock, atomic write, sessions.txt I/O
# ==================================================================
__cm_acquire_lock() {
    # Opens fd 9 on the lock file with exclusive lock. Retries up to 10s.
    # On timeout, warns and proceeds unlocked (fd 9 left closed).
    exec 9>>"$__cm_lock_file" 2>/dev/null || return 1
    local i
    for (( i=0; i<50; i++ )); do
        if flock -n 9; then return 0; fi
        sleep 0.2
    done
    __cm_say_c "$__CM_C_YELLOW" "[warning] Could not acquire sessions.txt lock after 10s; proceeding without lock."
    exec 9>&- 2>/dev/null
    return 1
}

__cm_release_lock() { exec 9>&- 2>/dev/null || true; }

__cm_write_atomic() {
    # Stdin → sessions.txt.tmp → mv onto sessions.txt.
    cat > "$__cm_tmp_file" && mv -f "$__cm_tmp_file" "$__cm_sessions_file"
}

__cm_get_sessions() {
    # Prints main-section lines (before [archived]) to stdout.
    [[ -f "$__cm_sessions_file" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line// }" ]] && continue
        [[ "$(printf '%s' "$line" | tr -d '[:space:]')" == "[archived]" ]] && break
        printf '%s\n' "$line"
    done < "$__cm_sessions_file"
}

__cm_get_archived() {
    [[ -f "$__cm_sessions_file" ]] || return 0
    local line in_arch=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line// }" ]] && continue
        if [[ "$(printf '%s' "$line" | tr -d '[:space:]')" == "[archived]" ]]; then in_arch=1; continue; fi
        (( in_arch )) && printf '%s\n' "$line"
    done < "$__cm_sessions_file"
}

__cm_parse_line() {
    # Sets globals: __cm_g, __cm_d, __cm_desc, __cm_t. Ignores trailing fields past 4.
    local line="$1"
    IFS='|' read -r __cm_g __cm_d __cm_desc __cm_t <<< "$line"
    __cm_t="${__cm_t:-}"
}

__cm_save_sessions() {
    # Args: list of pipe-joined lines (one per arg).
    local have_lock=0
    __cm_acquire_lock && have_lock=1
    {
        local s
        for s in "$@"; do printf '%s\n' "$s"; done
        local archived=()
        mapfile -t archived < <(__cm_get_archived)
        if (( ${#archived[@]} > 0 )); then
            printf '[archived]\n'
            for s in "${archived[@]}"; do printf '%s\n' "$s"; done
        fi
    } | __cm_write_atomic
    (( have_lock )) && __cm_release_lock
}

__cm_save_archived() {
    # Args: pipe-joined archived lines.
    local have_lock=0
    __cm_acquire_lock && have_lock=1
    {
        local main=()
        mapfile -t main < <(__cm_get_sessions)
        local s
        for s in "${main[@]}"; do printf '%s\n' "$s"; done
        if (( $# > 0 )); then
            printf '[archived]\n'
            for s in "$@"; do printf '%s\n' "$s"; done
        fi
    } | __cm_write_atomic
    (( have_lock )) && __cm_release_lock
}

# Auto-backup sessions.txt, keep 20 most recent.
__cm_auto_backup_sessions() {
    [[ -s "$__cm_sessions_file" ]] || return 0
    mkdir -p "$__cm_backup_dir" 2>/dev/null
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -f "$__cm_sessions_file" "$__cm_backup_dir/sessions.txt.$ts" 2>/dev/null
    # Prune beyond 20
    ls -1t "$__cm_backup_dir"/sessions.txt.* 2>/dev/null | tail -n +21 | while IFS= read -r f; do
        rm -f -- "$f" 2>/dev/null
    done
}

# ==================================================================
# Get-ProjectKey, format helpers, Get-SessionInfo
# ==================================================================
__cm_get_proj_key() {
    # Replace every non-alphanumeric char with dash. Canonical encoding.
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

__cm_format_tokens() {
    # Input: integer or empty. Output: "-- " / "1.2M tok" / "155K tok" / "<n> tok".
    local t="$1"
    [[ -z "$t" ]] && { printf '%s' "--"; return; }
    if (( t >= 1000000 )); then
        awk -v v="$t" 'BEGIN{printf "%.1fM tok", v/1000000}'
    elif (( t >= 1000 )); then
        awk -v v="$t" 'BEGIN{printf "%dK tok", int(v/1000 + 0.5)}'
    else
        printf '%s tok' "$t"
    fi
}

__cm_format_size() {
    local b="$1"
    if (( b >= 1048576 )); then
        awk -v v="$b" 'BEGIN{printf "%.1f MB", v/1048576}'
    elif (( b >= 1024 )); then
        awk -v v="$b" 'BEGIN{printf "%d KB", int(v/1024 + 0.5)}'
    else
        printf '%d B' "$b"
    fi
}

__cm_format_date_short() {
    # Input: epoch seconds. If year < current year, "Mon D, YYYY" else "Mon D".
    local epoch="$1"
    local now_year; now_year=$(date +%Y)
    local file_year; file_year=$(date -d "@$epoch" +%Y 2>/dev/null || date -r "$epoch" +%Y 2>/dev/null)
    if [[ -n "$file_year" && "$file_year" -lt "$now_year" ]]; then
        date -d "@$epoch" "+%b %-d, %Y" 2>/dev/null || date -r "$epoch" "+%b %-d, %Y" 2>/dev/null
    else
        date -d "@$epoch" "+%b %-d" 2>/dev/null || date -r "$epoch" "+%b %-d" 2>/dev/null
    fi
}

__cm_file_mtime_epoch() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
__cm_file_ctime_epoch() { stat -c %W "$1" 2>/dev/null || stat -f %B "$1" 2>/dev/null; }
__cm_file_size()        { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }

# Sets globals: __cm_info_size, __cm_info_date, __cm_info_tokens, __cm_info_status
__cm_get_session_info() {
    local guid="$1" dir="$2" tokens="$3"
    local proj_key proj_dir jsonl
    proj_key=$(__cm_get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    jsonl="$proj_dir/$guid.jsonl"
    __cm_info_tokens=$(__cm_format_tokens "$tokens")
    if [[ -f "$jsonl" ]]; then
        __cm_info_size=$(__cm_format_size "$(__cm_file_size "$jsonl")")
        __cm_info_date=$(__cm_format_date_short "$(__cm_file_mtime_epoch "$jsonl")")
        __cm_info_status=ok
        return
    fi
    # Missing; walk fallback chain for date.
    local fb=""
    if [[ -d "$proj_dir/$guid" ]]; then
        fb=$(__cm_file_mtime_epoch "$proj_dir/$guid")
    elif [[ -d "$proj_dir/memory" ]]; then
        fb=$(__cm_file_mtime_epoch "$proj_dir/memory")
    elif [[ -f "$proj_dir/sessions-index.json" ]]; then
        local node; node=$(__cm_resolve_node) && fb=$("$node" -e "
try{const fs=require('fs');const d=JSON.parse(fs.readFileSync('$proj_dir/sessions-index.json','utf8'));
const e=(d.entries||[]).find(x=>x.sessionId==='$guid');
if(e&&e.created)process.stdout.write(String(Math.floor(new Date(e.created).getTime()/1000)));}catch(e){}
" 2>/dev/null)
    fi
    if [[ -n "$fb" ]]; then
        __cm_info_date=$(__cm_format_date_short "$fb")"*"
    else
        __cm_info_date="--"
    fi
    __cm_info_size="(missing)"
    __cm_info_status=missing
}

# ==================================================================
# Sync-SessionIndex (best-effort, always silent on failure)
# ==================================================================
__cm_sync_session_index() {
    local project_dir="$1"
    local node; node=$(__cm_resolve_node) || return 0
    local proj_key proj_dir
    proj_key=$(__cm_get_proj_key "$project_dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    [[ -d "$proj_dir" ]] || return 0
    # Build a text listing of "guid|desc|dir" for sessions-registered entries.
    local reg_file; reg_file=$(mktemp) || return 0
    {
        __cm_get_sessions
        __cm_get_archived
    } > "$reg_file"
    "$node" - "$proj_dir" "$project_dir" "$reg_file" <<'NODEJS' 2>/dev/null
const fs = require('fs'), path = require('path');
const [,, projDir, originalPathArg, regFile] = process.argv;
try {
  const files = fs.readdirSync(projDir).filter(n => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$/.test(n));
  if (files.length === 0) return;
  const indexPath = path.join(projDir, 'sessions-index.json');
  let existing = [], originalPath = originalPathArg;
  if (fs.existsSync(indexPath)) {
    try { const j = JSON.parse(fs.readFileSync(indexPath,'utf8')); existing = j.entries || []; if (j.originalPath) originalPath = j.originalPath; } catch(e) { existing = []; }
  }
  const onDisk = {};
  for (const n of files) {
    const full = path.join(projDir, n);
    const st = fs.statSync(full);
    onDisk[n.replace(/\.jsonl$/, '')] = { full, mtime: st.mtimeMs, ctime: st.ctimeMs };
  }
  const kept = [];
  for (const e of existing) {
    if (e && e.sessionId && onDisk[e.sessionId]) {
      const d = onDisk[e.sessionId];
      e.fileMtime = Math.floor(d.mtime);
      e.modified = new Date(d.mtime).toISOString();
      kept.push(e);
    }
  }
  const keptSet = new Set(kept.map(x => x.sessionId));
  // Build registered-desc map from reg_file
  const reg = {};
  try {
    for (const line of fs.readFileSync(regFile,'utf8').split('\n')) {
      if (!line || line.trim() === '[archived]') continue;
      const parts = line.split('|');
      if (parts[0]) reg[parts[0]] = { desc: parts[2] || '', dir: parts[1] || '' };
    }
  } catch(e) {}
  const added = [];
  for (const guid of Object.keys(onDisk)) {
    if (keptSet.has(guid)) continue;
    const d = onDisk[guid];
    const r = reg[guid] || {};
    added.push({
      sessionId: guid,
      fullPath: d.full,
      fileMtime: Math.floor(d.mtime),
      firstPrompt: r.desc || '',
      messageCount: 0,
      created: new Date(d.ctime || d.mtime).toISOString(),
      modified: new Date(d.mtime).toISOString(),
      gitBranch: '',
      projectPath: r.dir || originalPath,
      isSidechain: false
    });
  }
  const out = { version: 1, entries: kept.concat(added), originalPath };
  fs.writeFileSync(indexPath, JSON.stringify(out, null, 2));
} catch(e) {}
NODEJS
    rm -f "$reg_file" 2>/dev/null
    return 0
}

# ==================================================================
# Do-DeleteSession (destructive)
# ==================================================================
__cm_do_delete_session() {
    local guid="$1" dir="$2"
    local proj_key proj_dir
    proj_key=$(__cm_get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    [[ -f "$proj_dir/$guid.jsonl" ]] && rm -f "$proj_dir/$guid.jsonl"
    [[ -d "$proj_dir/$guid" ]] && rm -rf "$proj_dir/$guid"
    __cm_sync_session_index "$dir"
}

# ==================================================================
# Do-OrphanScan
# ==================================================================
# Sets __cm_scan_result_action (empty, or "select") and __cm_scan_result_guid.
__cm_do_orphan_scan() {
    local scan_dir="$1" registered_guid="$2"
    __cm_scan_result_action=""; __cm_scan_result_guid=""
    local proj_key proj_dir
    proj_key=$(__cm_get_proj_key "$scan_dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    [[ -d "$proj_dir" ]] || return 0
    # Collect *.jsonl sorted by mtime descending.
    local files=() f
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(
        ls -1t "$proj_dir"/*.jsonl 2>/dev/null
    )
    (( ${#files[@]} <= 1 )) && return 0
    # Combined registered set: main + archived.
    local sessions=() line
    while IFS= read -r line; do sessions+=("$line"); done < <(__cm_get_sessions)
    while IFS= read -r line; do sessions+=("$line"); done < <(__cm_get_archived)
    # Detect problems.
    local has_problem=0
    for f in "${files[@]}"; do
        local g; g=$(basename "$f" .jsonl)
        local match_dir=""
        for s in "${sessions[@]}"; do
            local sg sd
            IFS='|' read -r sg sd _ _ <<< "$s"
            if [[ "$sg" == "$g" ]]; then match_dir="$sd"; break; fi
        done
        if [[ -z "$match_dir" ]]; then has_problem=1; break; fi
        if [[ "$match_dir" != "$scan_dir" ]]; then has_problem=1; break; fi
    done
    (( has_problem )) || return 0
    __cm_blank
    __cm_say_c "$__CM_C_YELLOW" "Multiple conversation files found (${#files[@]}):"
    __cm_blank
    __cm_say "#   Last Modified          Size     Session Name"
    __cm_say "--- --------------------  --------  ---------------------------"
    local i=0
    for f in "${files[@]}"; do
        i=$((i+1))
        local g; g=$(basename "$f" .jsonl)
        local sz; sz=$(__cm_format_size "$(__cm_file_size "$f")")
        local dt; dt=$(date -d "@$(__cm_file_mtime_epoch "$f")" "+%Y-%m-%d %H:%M" 2>/dev/null \
                      || date -r "$(__cm_file_mtime_epoch "$f")" "+%Y-%m-%d %H:%M" 2>/dev/null)
        local name="(orphan)" marker="" sd=""
        for s in "${sessions[@]}"; do
            local sg sd2 sdesc
            IFS='|' read -r sg sd2 sdesc _ <<< "$s"
            if [[ "$sg" == "$g" ]]; then name="$sdesc"; sd="$sd2"; break; fi
        done
        [[ -n "$sd" && "$sd" != "$scan_dir" ]] && name="$name (wrong directory)"
        [[ "$g" == "$registered_guid" ]] && marker=" *"
        printf '  %-3d %s  %8s  %s%s\n' "$i" "$dt" "$sz" "$name" "$marker"
    done
    __cm_blank
    __cm_say "* = registered session for this directory"
    __cm_blank
    __cm_say "Actions: [number] to select, [q number] to quarantine to backup, [Enter] to continue with registered session"
    local cmd; printf '  >: '; read -r cmd
    if [[ "$cmd" =~ ^[0-9]+$ ]]; then
        local idx=$((cmd - 1))
        if (( idx >= 0 && idx < ${#files[@]} )); then
            __cm_scan_result_action="select"
            __cm_scan_result_guid=$(basename "${files[idx]}" .jsonl)
        else __cm_say "Invalid number."
        fi
    elif [[ "$cmd" =~ ^[qQ][[:space:]]*([0-9]+)$ ]]; then
        local idx=$((${BASH_REMATCH[1]} - 1))
        if (( idx >= 0 && idx < ${#files[@]} )); then
            local f="${files[idx]}" g
            g=$(basename "$f" .jsonl)
            if [[ "$g" == "$registered_guid" ]]; then
                __cm_say_c "$__CM_C_RED" "Cannot quarantine the registered session."
            else
                local leaf dest
                leaf=$(basename "$scan_dir")
                dest="$__cm_quarantine_root/$leaf"
                mkdir -p "$dest" 2>/dev/null
                mv -f "$f" "$dest/$(basename "$f")" 2>/dev/null
                [[ -d "$proj_dir/$g" ]] && mv -f "$proj_dir/$g" "$dest/$g" 2>/dev/null
                __cm_sync_session_index "$scan_dir"
                __cm_say_c "$__CM_C_GREEN" "Quarantined to backup: $leaf/$g"
            fi
        else __cm_say "Invalid number."
        fi
    fi
}

# ==================================================================
# Show-List
# ==================================================================
__cm_show_list() {
    local highlight="${1:-0}"
    __cm_blank
    __cm_say "=== Saved Sessions ==="
    __cm_blank
    local sessions=() s
    mapfile -t sessions < <(__cm_get_sessions)
    local count=${#sessions[@]}
    (( count == 0 )) && return
    local max_desc=10 num_width=${#count} i=0
    for s in "${sessions[@]}"; do
        local _g _d _desc _t
        IFS='|' read -r _g _d _desc _t <<< "$s"
        (( ${#_desc} > max_desc )) && max_desc=${#_desc}
    done
    for s in "${sessions[@]}"; do
        i=$((i+1))
        local g d desc t
        IFS='|' read -r g d desc t <<< "$s"
        __cm_get_session_info "$g" "$d" "$t"
        local num="$i."
        local num_pad; num_pad=$(printf '%-*s' $((num_width + 2)) "$num")
        local desc_pad; desc_pad=$(printf '%-*s' $((max_desc + 2)) "$desc")
        local size_pad; size_pad=$(printf '%9s' "$__cm_info_size")
        local tok_pad;  tok_pad=$(printf '%10s' "$__cm_info_tokens")
        local line="  $num_pad $desc_pad $size_pad  $tok_pad   $__cm_info_date"$'\t'"$d"
        if [[ "$highlight" == "$i" ]]; then
            printf '  %b*** %s %s %s  %s   %s\t%s  [Selected] ***%b\n' \
                "$__CM_C_YELLOW" "$num_pad" "$desc_pad" "$size_pad" "$tok_pad" "$__cm_info_date" "$d" "$__CM_C_RESET"
        else
            printf '%s\n' "$line"
        fi
    done
    __cm_blank
    local arch_count; arch_count=$(__cm_get_archived | wc -l | tr -d ' ')
    __cm_say "E. Edit this list"
    (( arch_count > 0 )) && __cm_say "V. View archived ($arch_count)"
    __cm_say "M. Machine name ($__cm_machine_name)"
}

# ==================================================================
# Do-ViewArchived
# ==================================================================
__cm_do_view_archived() {
    while true; do
        local archived=()
        mapfile -t archived < <(__cm_get_archived)
        if (( ${#archived[@]} == 0 )); then
            __cm_blank; __cm_say "No archived sessions."; return
        fi
        __cm_blank
        __cm_say "=== Archived Sessions ==="
        __cm_blank
        local i=0 s
        for s in "${archived[@]}"; do
            i=$((i+1))
            local g d desc t
            IFS='|' read -r g d desc t <<< "$s"
            __cm_get_session_info "$g" "$d" "$t"
            __cm_say "$i. $desc  [$d]  $__cm_info_size"
        done
        __cm_blank
        __cm_say "U# = Unarchive   D# = Delete permanently   Q = Back"
        __cm_blank
        local cmd; printf '  >: '; read -r cmd
        if [[ -z "$cmd" || "$cmd" == "q" || "$cmd" == "Q" ]]; then return; fi
        if [[ "$cmd" =~ ^[uU]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < ${#archived[@]} )); then
                local entry="${archived[idx]}"
                local new_arch=()
                local j
                for (( j=0; j<${#archived[@]}; j++ )); do (( j != idx )) && new_arch+=("${archived[j]}"); done
                __cm_save_archived "${new_arch[@]}"
                local main=()
                mapfile -t main < <(__cm_get_sessions)
                __cm_save_sessions "$entry" "${main[@]}"
                local _g _d desc _t; IFS='|' read -r _g _d desc _t <<< "$entry"
                __cm_say_c "$__CM_C_GREEN" "Unarchived: $desc"
            else __cm_say "Invalid number."
            fi
        elif [[ "$cmd" =~ ^[dD]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < ${#archived[@]} )); then
                __cm_say_c "$__CM_C_RED" "This permanently deletes the conversation file and all associated data."
                __cm_say_c "$__CM_C_RED" "This cannot be undone."
                local confirm; printf "  Type 'delete' to confirm: "; read -r confirm
                if [[ "${confirm,,}" == "delete" ]]; then
                    local entry="${archived[idx]}"
                    local g d desc t; IFS='|' read -r g d desc t <<< "$entry"
                    __cm_do_delete_session "$g" "$d"
                    local new_arch=()
                    local j
                    for (( j=0; j<${#archived[@]}; j++ )); do (( j != idx )) && new_arch+=("${archived[j]}"); done
                    __cm_save_archived "${new_arch[@]}"
                    __cm_say_c "$__CM_C_GREEN" "Deleted: $desc"
                else __cm_say "Cancelled."
                fi
            else __cm_say "Invalid number."
            fi
        else __cm_say "Unknown command."
        fi
    done
}

# ==================================================================
# Do-EditList
# ==================================================================
__cm_do_edit_list() {
    while true; do
        local sessions=()
        mapfile -t sessions < <(__cm_get_sessions)
        __cm_blank
        __cm_say "=== Edit Sessions ==="
        __cm_blank
        local i=0 s
        for s in "${sessions[@]}"; do
            i=$((i+1))
            local g d desc t; IFS='|' read -r g d desc t <<< "$s"
            __cm_say "$i. $desc  [$d]"
        done
        __cm_blank
        __cm_say "R# = Rename   P# = Path   A# = Archive   D# = Delete   M#,# = Move   Q = Done"
        __cm_blank
        local cmd; printf '  >: '; read -r cmd
        [[ -z "$cmd" || "$cmd" == "q" || "$cmd" == "Q" ]] && return
        local count=${#sessions[@]}
        if [[ "$cmd" =~ ^[rR]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < count )); then
                local g d desc t; IFS='|' read -r g d desc t <<< "${sessions[idx]}"
                local new_name; printf "  New name for '$desc': "; read -r new_name
                if [[ -n "$new_name" ]]; then
                    sessions[idx]="$g|$d|$new_name|$t"
                    __cm_save_sessions "${sessions[@]}"
                fi
            else __cm_say "Invalid number."
            fi
        elif [[ "$cmd" =~ ^[pP]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < count )); then
                local g d desc t; IFS='|' read -r g d desc t <<< "${sessions[idx]}"
                __cm_say "Current: $d"
                local new_path; printf '  New path (Enter to keep): '; read -r new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! -d "$new_path" ]]; then __cm_say "Path does not exist: $new_path"; continue; fi
                    local old_key new_key old_proj new_proj
                    old_key=$(__cm_get_proj_key "$d")
                    new_key=$(__cm_get_proj_key "$new_path")
                    old_proj="$HOME/.claude/projects/$old_key"
                    new_proj="$HOME/.claude/projects/$new_key"
                    if [[ -f "$old_proj/$g.jsonl" ]]; then
                        mkdir -p "$new_proj" 2>/dev/null
                        cp -f "$old_proj/$g.jsonl" "$new_proj/$g.jsonl"
                        __cm_say "Session file copied to new project directory."
                    else
                        __cm_say "Warning: Session file not found at old path. Resume may not work."
                    fi
                    sessions[idx]="$g|$new_path|$desc|$t"
                    __cm_save_sessions "${sessions[@]}"
                    __cm_sync_session_index "$new_path"
                    __cm_sync_session_index "$d"
                fi
            else __cm_say "Invalid number."
            fi
        elif [[ "$cmd" =~ ^[aA]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < count )); then
                local entry="${sessions[idx]}"
                local g d desc t; IFS='|' read -r g d desc t <<< "$entry"
                local new_s=() j
                for (( j=0; j<count; j++ )); do (( j != idx )) && new_s+=("${sessions[j]}"); done
                __cm_save_sessions "${new_s[@]}"
                local archived=()
                mapfile -t archived < <(__cm_get_archived)
                archived+=("$entry")
                __cm_save_archived "${archived[@]}"
                __cm_say_c "$__CM_C_GREEN" "Archived: $desc"
            else __cm_say "Invalid number."
            fi
        elif [[ "$cmd" =~ ^[dD]([0-9]+)$ ]]; then
            local idx=$((${BASH_REMATCH[1]} - 1))
            if (( idx >= 0 && idx < count )); then
                __cm_say_c "$__CM_C_RED" "This permanently deletes the conversation file and all associated data."
                __cm_say_c "$__CM_C_RED" "This cannot be undone."
                local confirm; printf "  Type 'delete' to confirm: "; read -r confirm
                if [[ "${confirm,,}" == "delete" ]]; then
                    local entry="${sessions[idx]}"
                    local g d desc t; IFS='|' read -r g d desc t <<< "$entry"
                    __cm_do_delete_session "$g" "$d"
                    local new_s=() j
                    for (( j=0; j<count; j++ )); do (( j != idx )) && new_s+=("${sessions[j]}"); done
                    __cm_save_sessions "${new_s[@]}"
                    __cm_say_c "$__CM_C_GREEN" "Deleted: $desc"
                else __cm_say "Cancelled."
                fi
            else __cm_say "Invalid number."
            fi
        elif [[ "$cmd" =~ ^[mM]([0-9]+),([0-9]+)$ ]]; then
            local from=$((${BASH_REMATCH[1]} - 1)) to=$((${BASH_REMATCH[2]} - 1))
            if (( from >= 0 && from < count && to >= 0 && to < count )); then
                local item="${sessions[from]}"
                local new_s=() j
                for (( j=0; j<count; j++ )); do (( j != from )) && new_s+=("${sessions[j]}"); done
                local result=() k=0
                for (( j=0; j<=${#new_s[@]}; j++ )); do
                    if (( j == to )); then result+=("$item"); fi
                    if (( j < ${#new_s[@]} )); then result+=("${new_s[j]}"); fi
                done
                __cm_save_sessions "${result[@]}"
            else __cm_say "Invalid numbers."
            fi
        else __cm_say "Unknown command."
        fi
    done
}

# ==================================================================
# Build-RecoveryMetaPrompt — verbatim template from spec 11.7.1
# ==================================================================
__cm_build_recovery_meta_prompt() {
    local guid="$1" dir="$2" desc="$3" tokens="$4" last_date="$5"
    local proj_key proj_dir memory_dir subagents_dir
    proj_key=$(__cm_get_proj_key "$dir")
    proj_dir="$HOME/.claude/projects/$proj_key"
    memory_dir="$proj_dir/memory"
    subagents_dir="$proj_dir/$guid/subagents"
    local memory_list="  (none)"
    if [[ -d "$memory_dir" ]]; then
        local lines=() f
        while IFS= read -r f; do
            local sz_kb mod
            sz_kb=$(( ($(__cm_file_size "$f") + 512) / 1024 ))
            mod=$(date -d "@$(__cm_file_mtime_epoch "$f")" "+%Y-%m-%d" 2>/dev/null \
                 || date -r "$(__cm_file_mtime_epoch "$f")" "+%Y-%m-%d" 2>/dev/null)
            lines+=("  * $(basename "$f") ($sz_kb KB, modified $mod)")
        done < <(ls -1 "$memory_dir"/*.md 2>/dev/null)
        if (( ${#lines[@]} > 0 )); then
            memory_list=$(printf '%s\n' "${lines[@]}")
        fi
    fi
    local subagent_count=0 subagent_latest="unknown"
    if [[ -d "$subagents_dir" ]]; then
        local agents=() a
        while IFS= read -r a; do agents+=("$a"); done < <(ls -1t "$subagents_dir"/*.jsonl 2>/dev/null)
        subagent_count=${#agents[@]}
        if (( subagent_count > 0 )); then
            subagent_latest=$(date -d "@$(__cm_file_mtime_epoch "${agents[0]}")" "+%Y-%m-%d" 2>/dev/null \
                             || date -r "$(__cm_file_mtime_epoch "${agents[0]}")" "+%Y-%m-%d" 2>/dev/null)
        fi
    fi
    local tok_str="unknown token count"
    [[ -n "$tokens" ]] && tok_str="$tokens tokens"
    local date_str="${last_date:-unknown}"
    cat <<EOF
Context: a Claude Code session was deleted. You need to produce orientation text for a future Claude Code session that will read this text as its first input. Produce the text. That text goes directly into the next session. It is NOT a summary, NOT a description, NOT a report about what you did. It is the directives themselves.

Read these artifacts:
* Memory files in ${memory_dir}
* Subagent transcripts in ${subagents_dir} (2-3 most recent; total on disk: ${subagent_count}, latest dated ${subagent_latest})
* The project code at ${dir}

Session metadata (for reference when you write):
* Session name: ${desc}
* Project path: ${dir}
* Last activity: ${date_str}
* Conversation size when lost: ${tok_str}

Now replace every <PLACEHOLDER> below and OUTPUT the completed template. Start your output with "This is a recovery session." and end with "ask before assuming." Output nothing else. No preamble, no confirmation, no summary of what you did.

This is a recovery session. The previous conversation transcript for "${desc}" was deleted. The project lives at ${dir}. Memory, subagent state, and source code all survived.

Read these files in this order:

<NUMBERED LIST. Format: "1. <filename>: <one-line description of what this file contains, based on what you read in it>". Use actual file paths from the memory directory.>

Then skim these subagent transcripts for context on in-flight work:

<BULLETED LIST using "*" not "-". Format: "* <filename>: <what this subagent was doing>". Use 2-3 of the most recently modified subagent transcripts. If there are zero subagent transcripts, replace this whole list with the single line: "No surviving subagent transcripts.">

Open questions or in-flight work visible from the artifacts:

<BULLETED LIST using "*" not "-". One line per item. If nothing specific is identifiable, replace this whole list with: "None identified from the artifacts.">

Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming.
EOF
}

# ==================================================================
# Resolve-ResumeOrRecover (recovery primer flow)
# ==================================================================
# Sets __cm_recover_action ("normal"|"fresh"|"primed"|"cancel") and __cm_recover_guid.
__cm_resolve_resume_or_recover() {
    local guid="$1" dir="$2" desc="$3" tokens="$4"
    __cm_recover_action=""; __cm_recover_guid=""
    local proj_key jsonl
    proj_key=$(__cm_get_proj_key "$dir")
    jsonl="$HOME/.claude/projects/$proj_key/$guid.jsonl"
    if [[ -f "$jsonl" ]]; then
        __cm_recover_action="normal"; __cm_recover_guid="$guid"; return
    fi
    __cm_blank
    __cm_say_c "$__CM_C_YELLOW" "The conversation transcript for '$desc' has been lost."
    __cm_say "Probably due to Claude Code's 30-day auto-cleanup."
    __cm_say "Memory files and subagent state are intact."
    __cm_blank
    __cm_say "You have three options:"
    __cm_say "  1. Start a fresh Claude session in that directory"
    __cm_say "  2. Create a recovery-prompt.md file in the project directory, that you can prompt Claude to read and execute, with optional edits."
    __cm_say "  3. Cancel"
    __cm_blank
    local choice; printf '  > '; read -r choice
    case "$choice" in
        1) __cm_recover_action="fresh"; return ;;
        3|"") __cm_recover_action="cancel"; return ;;
        2)
            if [[ ! -d "$dir" ]]; then
                __cm_say_c "$__CM_C_RED" "Project directory not found: $dir"
                __cm_recover_action="cancel"; return
            fi
            # Rotate existing recovery-prompt.md files.
            local primary="$dir/recovery-prompt.md"
            if [[ -f "$primary" ]]; then
                local max_n=1 f n
                shopt -s nullglob
                for f in "$dir"/recovery-prompt.md.old*; do
                    local bn; bn=$(basename "$f")
                    if [[ "$bn" =~ recovery-prompt\.md\.old([0-9]+)$ ]]; then
                        n="${BASH_REMATCH[1]}"
                        (( n >= max_n )) && max_n=$((n + 1))
                    fi
                done
                # Rotate in descending order to avoid collisions.
                local to_rotate=() pair
                for f in "$dir"/recovery-prompt.md.old*; do
                    local bn num=1
                    bn=$(basename "$f")
                    if [[ "$bn" =~ recovery-prompt\.md\.old([0-9]+)$ ]]; then num="${BASH_REMATCH[1]}"; fi
                    to_rotate+=("$num|$f")
                done
                shopt -u nullglob
                # Sort descending by num.
                IFS=$'\n' to_rotate=($(printf '%s\n' "${to_rotate[@]}" | sort -t'|' -k1,1nr))
                for pair in "${to_rotate[@]}"; do
                    local num path; IFS='|' read -r num path <<< "$pair"
                    mv -f "$path" "$dir/recovery-prompt.md.old$((num + 1))" 2>/dev/null
                done
                mv -f "$primary" "$dir/recovery-prompt.md.old" 2>/dev/null
            fi
            __cm_blank
            __cm_say_c "$__CM_C_CYAN" "Generating recovery prompt (this may take a minute)..."
            __cm_get_session_info "$guid" "$dir" "$tokens"
            local meta_prompt; meta_prompt=$(__cm_build_recovery_meta_prompt "$guid" "$dir" "$desc" "$tokens" "$__cm_info_date")
            local orig_dir; orig_dir=$(pwd)
            cd "$dir" || { __cm_recover_action="cancel"; return; }
            local tmp_file; tmp_file=$(mktemp)
            printf '%s' "$meta_prompt" > "$tmp_file"
            local claude_exe; claude_exe=$(__cm_resolve_claude)
            local primer_json=""
            if [[ -n "$claude_exe" ]]; then
                primer_json=$("$claude_exe" -p --output-format json --dangerously-skip-permissions < "$tmp_file" 2>/dev/null)
            fi
            rm -f "$tmp_file"
            local recovery_prompt primer_sid
            recovery_prompt=$(__cm_json_get "$primer_json" "result")
            primer_sid=$(__cm_json_get "$primer_json" "session_id")
            # Cleanup throwaway -p session.
            if [[ -n "$primer_sid" ]]; then
                local pk; pk=$(__cm_get_proj_key "$(pwd)")
                rm -f "$HOME/.claude/projects/$pk/$primer_sid.jsonl" 2>/dev/null
                rm -rf "$HOME/.claude/projects/$pk/$primer_sid" 2>/dev/null
                __cm_sync_session_index "$(pwd)"
            fi
            if [[ -z "$recovery_prompt" ]]; then
                __cm_say_c "$__CM_C_RED" "Recovery prompt generation failed."
                cd "$orig_dir"
                __cm_recover_action="cancel"; return
            fi
            printf '%s' "$recovery_prompt" > "$primary"
            __cm_blank
            __cm_say_c "$__CM_C_GREEN" "Recovery prompt saved to:"
            __cm_say "  $primary"
            __cm_blank
            __cm_say "Edit it if you want, or just tell Claude to use it as the first message of the conversation."
            __cm_say_c "$__CM_C_CYAN" "Opening a fresh Claude session in that directory now..."
            __cm_blank
            cd "$orig_dir"
            __cm_recover_action="fresh"; return
            ;;
        *) __cm_recover_action="cancel"; return ;;
    esac
}

# ==================================================================
# Do-Trim (cmv-driven trim, fail-loud cross-project)
# ==================================================================
# Sets __cm_trim_new_guid on success.
__cm_do_trim() {
    __cm_trim_new_guid=""
    local current_guid="$1"
    local cmv_exe; cmv_exe=$(__cm_resolve_cmv) || { __cm_say "cmv not found. Skipping trim."; return; }
    # Pre-trim cleanup: stale .cmv-trim-tmp older than 5 minutes.
    local sessions=() s
    mapfile -t sessions < <(__cm_get_sessions)
    local entry=""
    for s in "${sessions[@]}"; do
        local g d desc t; IFS='|' read -r g d desc t <<< "$s"
        if [[ "$g" == "$current_guid" ]]; then entry="$s"; break; fi
    done
    if [[ -n "$entry" ]]; then
        local g d _desc _t; IFS='|' read -r g d _desc _t <<< "$entry"
        local pk pd; pk=$(__cm_get_proj_key "$d"); pd="$HOME/.claude/projects/$pk"
        if [[ -d "$pd" ]]; then
            local cutoff; cutoff=$(( $(date +%s) - 300 ))
            local f
            for f in "$pd"/*.cmv-trim-tmp; do
                [[ -f "$f" ]] || continue
                local m; m=$(__cm_file_mtime_epoch "$f")
                if (( m < cutoff )); then
                    __cm_say_c "$__CM_C_DARKGRAY" "Cleaned stale CMV temp file: $(basename "$f")"
                    rm -f "$f" 2>/dev/null
                fi
            done
        fi
    fi
    __cm_say "Trimming session..."
    local trim_started; trim_started=$(date +%s)
    local trim_output; trim_output=$("$cmv_exe" trim -s "$current_guid" --skip-launch 2>&1)
    local new_guid
    new_guid=$(printf '%s' "$trim_output" | grep -oE 'Session ID:\s*[0-9a-f-]+' | head -1 | sed -E 's/.*Session ID:\s*//')
    if [[ -z "$new_guid" ]]; then
        __cm_say "Trim failed or no new session ID found."
        printf '%s\n' "$trim_output" | head -5 | sed 's/^/  /'
        return
    fi
    # Update sessions.txt: replace current_guid with new_guid.
    local updated=() line
    for line in "${sessions[@]}"; do
        local g d desc t; IFS='|' read -r g d desc t <<< "$line"
        if [[ "$g" == "$current_guid" ]]; then updated+=("$new_guid|$d|$desc|$t")
        else updated+=("$line"); fi
    done
    __cm_save_sessions "${updated[@]}"
    # Verify trimmed JSONL is in the expected project dir. Fail loud if not.
    local looked_up="" lu
    mapfile -t sessions < <(__cm_get_sessions)
    for lu in "${sessions[@]}"; do
        local g _d _desc _t; IFS='|' read -r g _d _desc _t <<< "$lu"
        [[ "$g" == "$new_guid" ]] && { looked_up="$lu"; break; }
    done
    if [[ -n "$looked_up" ]]; then
        local g d _desc _t; IFS='|' read -r g d _desc _t <<< "$looked_up"
        local pk pd expected; pk=$(__cm_get_proj_key "$d"); pd="$HOME/.claude/projects/$pk"
        expected="$pd/$new_guid.jsonl"
        if [[ ! -f "$expected" ]]; then
            local actual; actual=$(ls -1 "$HOME"/.claude/projects/*/"$new_guid.jsonl" 2>/dev/null | head -1)
            if [[ -n "$actual" ]]; then
                __cm_blank
                __cm_say_c "$__CM_C_RED" "CMV WROTE THE TRIMMED SESSION TO THE WRONG PROJECT"
                __cm_say_c "$__CM_C_RED" "Expected: $expected"
                __cm_say_c "$__CM_C_RED" "Actual:   $actual"
                __cm_say "Investigate before resuming. ClaudeCM will NOT silently copy the file."
            else
                __cm_blank
                __cm_say_c "$__CM_C_RED" "Trim claimed to create $new_guid but the file is not on disk."
            fi
        fi
    fi
    # Print remaining output (first 10 non-Session-ID lines).
    printf '%s\n' "$trim_output" | grep -v 'Session ID:' | sed '/^$/d' | head -10 | sed 's/^/  /'
    # Post-trim cleanup of *.cmv-trim-tmp files modified during this run.
    if [[ -n "$looked_up" ]]; then
        local g d _desc _t; IFS='|' read -r g d _desc _t <<< "$looked_up"
        local pk pd; pk=$(__cm_get_proj_key "$d"); pd="$HOME/.claude/projects/$pk"
        if [[ -d "$pd" ]]; then
            local f
            for f in "$pd"/*.cmv-trim-tmp; do
                [[ -f "$f" ]] || continue
                local m; m=$(__cm_file_mtime_epoch "$f")
                if (( m >= trim_started )); then
                    __cm_say_c "$__CM_C_DARKGRAY" "CMV left a temp file behind: $(basename "$f"); removing."
                    rm -f "$f" 2>/dev/null
                fi
            done
        fi
        __cm_sync_session_index "$d"
    fi
    local leaf; leaf=$(basename "$d")
    local backup_sub="$HOME/.claudecm/backup/$leaf"
    mkdir -p "$backup_sub" 2>/dev/null
    local pre_trim_file="$pd/$current_guid.jsonl"
    if [[ -f "$pre_trim_file" ]]; then
        mv -f "$pre_trim_file" "$backup_sub/$current_guid.jsonl" 2>/dev/null
        if [[ -d "$pd/$current_guid" ]]; then
            mv -f "$pd/$current_guid" "$backup_sub/$current_guid" 2>/dev/null
        fi
    fi
    __cm_blank
    __cm_say "Session trimmed. New ID: $new_guid"
    __cm_trim_new_guid="$new_guid"
}

# ==================================================================
# Do-Refresh — structured compaction; prompt piped via stdin
# ==================================================================
__cm_do_refresh() {
    local current_guid="$1"
    local sessions=() s
    mapfile -t sessions < <(__cm_get_sessions)
    local cur_desc="Unnamed" cur_dir
    cur_dir=$(pwd)
    for s in "${sessions[@]}"; do
        local g d desc t; IFS='|' read -r g d desc t <<< "$s"
        if [[ "$g" == "$current_guid" ]]; then cur_desc="$desc"; cur_dir="$d"; break; fi
    done
    __cm_blank
    local new_name; printf "  Name for new session (Enter for '$cur_desc'): "; read -r new_name
    [[ -z "$new_name" ]] && new_name="$cur_desc"
    # Skeleton extraction setup.
    local proj_key proj_dir_claude old_jsonl
    proj_key=$(__cm_get_proj_key "$cur_dir")
    proj_dir_claude="$HOME/.claude/projects/$proj_key"
    old_jsonl="$proj_dir_claude/$current_guid.jsonl"
    local refresh_root="$__cm_cm_dir/refresh-temp"
    mkdir -p "$refresh_root" 2>/dev/null
    # Clean up subdirs older than 24h (best-effort).
    find "$refresh_root" -maxdepth 1 -mindepth 1 -type d -mtime +0 -exec rm -rf {} + 2>/dev/null
    local op_id; op_id="$(date +%Y%m%d-%H%M%S)-$current_guid"
    local refresh_temp_dir="$refresh_root/$op_id"
    mkdir -p "$refresh_temp_dir" 2>/dev/null
    local skeleton_content="" transcript_path=""
    # Locate extract-skeleton.mjs.
    local extract_script=""
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    local candidates=()
    [[ -n "$script_dir" ]] && candidates+=("$script_dir/extract-skeleton.mjs")
    [[ -n "$CLAUDECM_HOME" ]] && candidates+=("$CLAUDECM_HOME/extract-skeleton.mjs")
    candidates+=("$HOME/.claudecm/extract-skeleton.mjs" "$HOME/.local/share/claudecm/extract-skeleton.mjs")
    local c
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -f "$c" ]] && { extract_script="$c"; break; }
    done
    local node; node=$(__cm_resolve_node || true)
    if [[ -f "$old_jsonl" && -n "$extract_script" && -n "$node" ]]; then
        __cm_blank
        __cm_say "Extracting session skeleton..."
        "$node" "$extract_script" "$old_jsonl" "$cur_desc" "$refresh_temp_dir" >/dev/null 2>&1
        local skel_file="$refresh_temp_dir/$current_guid-skeleton.md"
        local tx_file="$refresh_temp_dir/$current_guid-transcript.md"
        if [[ -f "$skel_file" ]]; then
            skeleton_content=$(<"$skel_file")
            __cm_say_c "$__CM_C_GREEN" "Skeleton extracted."
        fi
        if [[ -f "$tx_file" ]]; then
            transcript_path="$tx_file"
            local tx_kb; tx_kb=$(( ($(__cm_file_size "$tx_file") + 512) / 1024 ))
            __cm_say_c "$__CM_C_GREEN" "Filtered transcript: $tx_kb KB"
        fi
    else
        [[ ! -f "$old_jsonl" ]]         && __cm_say_c "$__CM_C_YELLOW" "Old session JSONL not found, skipping skeleton extraction."
        [[ -z "$extract_script" ]]       && __cm_say_c "$__CM_C_YELLOW" "extract-skeleton.mjs not found, skipping skeleton extraction."
        [[ -z "$node" ]]                 && __cm_say_c "$__CM_C_YELLOW" "Node.js not found, skipping skeleton extraction."
    fi
    # Build refresh prompt.
    local prompt_file="$__cm_cm_dir/refresh-prompt.tmp"
    {
        cat <<'HEAD'
Read your memories. This is a fresh session replacing a long previous conversation
on this project. Everything you need to know is in:

1) Your memory files (MEMORY.md and all linked files)
2) Any documentation in the project directory
3) The codebase itself (git log for history)
4) project_current_state.md in your memory if it exists
HEAD
        if [[ -n "$skeleton_content" || -n "$transcript_path" ]]; then
            printf '5) The structured extraction below, produced by mechanical analysis of the\n   conversation log\n'
            if [[ -n "$transcript_path" ]]; then
                printf '6) A filtered transcript of the previous session (conversation text and tool call\n   summaries, no tool output) at:\n   %s\n   Read this file and identify any key decisions, user corrections, or reasoning\n   that the skeleton below does not capture.\n' "$transcript_path"
            fi
        fi
        cat <<'TAIL'

IMPORTANT:
- The files listed below reflect the state at the end of the previous session.
  Re-read any file before modifying it, as it may have changed since then.
- The errors listed may or may not still be relevant. Verify before acting on them.
- Do not start any development until the user tells you to.
- Tell the user what you understand about the current state of the project,
  what works, what is pending, and what your behavioral rules are.
TAIL
        if [[ -n "$skeleton_content" ]]; then
            printf '\n\n--- ADD YOUR NOTES HERE (context, decisions, corrections, anything the skeleton missed) ---\n\n\n\n--- SKELETON START (review and edit as needed) ---\n\n%s\n\n--- SKELETON END ---\n' "$skeleton_content"
        fi
    } > "$prompt_file"
    local edit_ans; printf '  Would you like to view/edit the compaction prompt and skeleton before proceeding? (Save and close when done) [y/N]: '; read -r edit_ans
    if [[ "$edit_ans" == "y" || "$edit_ans" == "Y" ]]; then
        "${EDITOR:-nano}" "$prompt_file"
    fi
    local refresh_orig; refresh_orig=$(pwd)
    cd "$cur_dir" || true
    __cm_blank
    __cm_say "Creating fresh session, please wait..."
    local claude_exe; claude_exe=$(__cm_resolve_claude)
    # Spec-critical: pipe via stdin. Never pass the prompt as a -p argument.
    # Windows' 32K CreateProcess limit is the known failure mode; Linux usually has
    # higher limits but the stdin pattern is the authoritative approach per spec 11.14 step 11.
    local refresh_json=""
    if [[ -n "$claude_exe" ]]; then
        refresh_json=$("$claude_exe" --dangerously-skip-permissions -p --output-format json < "$prompt_file" 2>&1)
    fi
    rm -f "$prompt_file" 2>/dev/null
    __cm_say "Done."
    cd "$refresh_orig" || true
    # Authoritative: extract session_id from JSON. Never fall back to filesystem scan.
    local fresh_guid; fresh_guid=$(__cm_json_get "$refresh_json" "session_id")
    if [[ -z "$fresh_guid" ]]; then
        __cm_say_c "$__CM_C_YELLOW" "Warning: Refresh did not create a new session. The old session is unchanged."
        return
    fi
    # Rewrite sessions: fresh at top, old with incremented (old N) suffix at bottom.
    mapfile -t sessions < <(__cm_get_sessions)
    local old_entry="" others=()
    local base_desc="" old_dir=""
    for s in "${sessions[@]}"; do
        local g d desc t; IFS='|' read -r g d desc t <<< "$s"
        if [[ "$g" == "$current_guid" ]]; then
            base_desc=$(printf '%s' "$desc" | sed -E 's/[[:space:]]*\(old([[:space:]]+[0-9]+)?\)[[:space:]]*$//')
            old_dir="$d"
            # Collect (old N) numbers in use for same base+dir.
            local used=() other
            for other in "${sessions[@]}"; do
                local og od odesc ot; IFS='|' read -r og od odesc ot <<< "$other"
                [[ "$og" == "$current_guid" ]] && continue
                [[ "$od" != "$d" ]] && continue
                local od_base="" od_n=""
                if [[ "$odesc" =~ ^(.*)[[:space:]]+\(old[[:space:]]+([0-9]+)\)[[:space:]]*$ ]]; then
                    od_base=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/[[:space:]]+$//')
                    od_n="${BASH_REMATCH[2]}"
                elif [[ "$odesc" =~ ^(.*)[[:space:]]*\(old\)[[:space:]]*$ ]]; then
                    od_base=$(printf '%s' "${BASH_REMATCH[1]}" | sed -E 's/[[:space:]]+$//')
                    od_n="1"
                fi
                if [[ -n "$od_n" && "$od_base" == "$base_desc" ]]; then used+=("$od_n"); fi
            done
            local old_desc
            if (( ${#used[@]} == 0 )); then old_desc="$base_desc (old)"
            else
                local n=1 u
                while :; do
                    local hit=0
                    for u in "${used[@]}"; do (( u == n )) && { hit=1; break; }; done
                    (( hit )) || break
                    n=$((n + 1))
                done
                if (( n == 1 )); then old_desc="$base_desc (old)"; else old_desc="$base_desc (old $n)"; fi
            fi
            old_entry="$g|$d|$old_desc|$t"
        else
            others+=("$s")
        fi
    done
    # Token count via cmv.
    local fresh_tokens=""
    local cmv_exe; cmv_exe=$(__cm_resolve_cmv || true)
    if [[ -n "$cmv_exe" ]]; then
        local bo; bo=$("$cmv_exe" benchmark -s "$fresh_guid" --json 2>&1)
        fresh_tokens=$(printf '%s' "$bo" | grep -oE '"preTrimTokens"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
    fi
    __cm_sync_session_index "$cur_dir"
    local new_list=("$fresh_guid|$cur_dir|$new_name|$fresh_tokens" "${others[@]}")
    [[ -n "$old_entry" ]] && new_list+=("$old_entry")
    __cm_save_sessions "${new_list[@]}"
    __cm_blank
    __cm_say "Fresh session created: $new_name"
    __cm_say "Old session moved to bottom of list."
    [[ -d "$refresh_temp_dir" ]] && rm -rf "$refresh_temp_dir" 2>/dev/null
}

# ==================================================================
# Do-PostExit
# ==================================================================
__cm_do_post_exit() {
    local known_guid="${1:-}"
    __cm_blank
    __cm_say "Session ended."
    __cm_blank
    local guid=""
    if [[ -n "$known_guid" ]]; then
        guid="$known_guid"
    else
        # Project-scoped fallback to newest non-agent-* JSONL in current project key dir.
        local pk pd; pk=$(__cm_get_proj_key "$(pwd)"); pd="$HOME/.claude/projects/$pk"
        [[ -d "$pd" ]] || return 0
        local newest=""
        while IFS= read -r f; do
            local bn; bn=$(basename "$f")
            [[ "$bn" =~ ^agent- ]] && continue
            newest="$f"; break
        done < <(ls -1t "$pd"/*.jsonl 2>/dev/null)
        [[ -z "$newest" ]] && return 0
        guid=$(basename "$newest" .jsonl)
    fi
    # Auto-snapshot via cmv (always -s <guid>, never --latest).
    local cmv_exe; cmv_exe=$(__cm_resolve_cmv || true)
    if [[ -n "$cmv_exe" ]]; then
        local snap_label="auto-exit-$(date +%Y%m%d-%H%M%S)"
        printf '  - Saving snapshot...\r'
        local spin_pid=""
        ( local i=0 spin="-\\|/"
          while :; do
              printf '  %s Saving snapshot...\r' "${spin:$((i%4)):1}"
              sleep 0.1; i=$((i+1))
          done ) &
        spin_pid=$!
        "$cmv_exe" snapshot "$snap_label" -s "$guid" >/dev/null 2>&1
        kill "$spin_pid" 2>/dev/null; wait "$spin_pid" 2>/dev/null
        printf '\r  Done.                        \n'
    fi
    # Locate entry; update tokens or register new.
    local sessions=() s
    mapfile -t sessions < <(__cm_get_sessions)
    local found_idx=-1 i=0
    for s in "${sessions[@]}"; do
        local g _d _desc _t; IFS='|' read -r g _d _desc _t <<< "$s"
        [[ "$g" == "$guid" ]] && { found_idx=$i; break; }
        i=$((i+1))
    done
    if (( found_idx >= 0 )); then
        local g d desc t; IFS='|' read -r g d desc t <<< "${sessions[found_idx]}"
        if [[ -n "$cmv_exe" ]]; then
            local bo; bo=$("$cmv_exe" benchmark -s "$guid" --json 2>&1)
            local new_tokens; new_tokens=$(printf '%s' "$bo" | grep -oE '"preTrimTokens"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
            [[ -n "$new_tokens" ]] && t="$new_tokens"
        fi
        local top="$g|$d|$desc|$t"
        local rest=() j
        for (( j=0; j<${#sessions[@]}; j++ )); do (( j != found_idx )) && rest+=("${sessions[j]}"); done
        __cm_save_sessions "$top" "${rest[@]}"
    else
        __cm_blank
        local folder; folder=$(basename "$(pwd)")
        folder="${folder//-/ }"
        # Title case (POSIX sh-friendly-ish)
        folder=$(printf '%s' "$folder" | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
        local desc
        printf "  Describe this session (Enter for '$folder', 'skip' to skip): "; read -r desc
        [[ "$desc" == "skip" ]] && return
        [[ -z "$desc" ]] && desc="$folder"
        local new_entry="$guid|$(pwd)|$desc|"
        __cm_save_sessions "$new_entry" "${sessions[@]}"
    fi
    # Sync session index.
    mapfile -t sessions < <(__cm_get_sessions)
    for s in "${sessions[@]}"; do
        local g d _desc _t; IFS='|' read -r g d _desc _t <<< "$s"
        [[ "$g" == "$guid" ]] && { __cm_sync_session_index "$d"; break; }
    done
    # Show size + token summary.
    local cur_s=""
    for s in "${sessions[@]}"; do
        local g _d _desc _t; IFS='|' read -r g _d _desc _t <<< "$s"
        [[ "$g" == "$guid" ]] && { cur_s="$s"; break; }
    done
    if [[ -n "$cur_s" ]]; then
        local g d _desc t; IFS='|' read -r g d _desc t <<< "$cur_s"
        __cm_get_session_info "$g" "$d" "$t"
        __cm_blank
        __cm_say "Current session: $__cm_info_size ($__cm_info_tokens)"
    fi
    echo ""
    local do_trim; printf '  Trim this session? [y/N]: '; read -r do_trim
    if [[ "$do_trim" == "y" || "$do_trim" == "Y" ]]; then
        __cm_do_trim "$guid"
        [[ -n "$__cm_trim_new_guid" ]] && guid="$__cm_trim_new_guid"
    fi
    echo ""
    local do_refresh; printf '  Create a new compacted session, built from a structured rebuild of this one? [y/N]: '; read -r do_refresh
    if [[ "$do_refresh" == "y" || "$do_refresh" == "Y" ]]; then
        __cm_do_refresh "$guid"
    fi
}

# ==================================================================
# invoke_claude_launch — bash belt-and-suspenders (spec 11.6 bash branch)
# ==================================================================
# Usage: __cm_invoke_claude_launch <session_dir> -- <claude args...>
# Sets: __cm_launch_sid, __cm_launch_exit.
#
# Layer 2 (snapshot diff) is the primary mechanism implemented here.
# Layer 3 (newest in project key after launch) is implicit by the way
# we take "newest that wasn't there before".
# Layer 1 (PID manifest poll) is deferred: bash can't cleanly capture a
# foreground PID without subshell tricks that interfere with TTY handoff.
# The spec explicitly allows Layer 1 silent fallback.
__cm_invoke_claude_launch() {
    __cm_launch_sid=""; __cm_launch_exit=1
    local session_dir="$1"; shift
    [[ "$1" == "--" ]] && shift
    local claude_exe; claude_exe=$(__cm_resolve_claude) || {
        __cm_say_c "$__CM_C_RED" "claude executable not found."
        return 1
    }
    local pk pd; pk=$(__cm_get_proj_key "$session_dir"); pd="$HOME/.claude/projects/$pk"
    # Snapshot before.
    local before=""
    if [[ -d "$pd" ]]; then
        before=$(ls -1 "$pd"/*.jsonl 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//' | sort)
    fi
    "$claude_exe" "$@"
    __cm_launch_exit=$?
    # Snapshot after.
    if [[ -d "$pd" ]]; then
        local after diff sid
        after=$(ls -1 "$pd"/*.jsonl 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//' | sort)
        diff=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null)
        # If there's a new UUID, that's our session id.
        sid=$(printf '%s\n' "$diff" | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' | head -1)
        if [[ -n "$sid" ]]; then
            __cm_launch_sid="$sid"
        else
            # Layer 3: newest in project key (may equal an existing file if no new one was made).
            local newest; newest=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
            [[ -n "$newest" ]] && __cm_launch_sid=$(basename "$newest" .jsonl)
        fi
    fi
    return 0
}

# ==================================================================
# Invoke-ResumeWithForkDetection (spec 11.6.1)
# ==================================================================
# Sets: __cm_resume_exit, __cm_resume_effective_guid.
__cm_invoke_resume_with_fork_detection() {
    local original_guid="$1" project_dir="$2" display_name="$3"
    __cm_resume_exit=1; __cm_resume_effective_guid="$original_guid"
    local pk pd; pk=$(__cm_get_proj_key "$project_dir"); pd="$HOME/.claude/projects/$pk"
    local before_newest=""
    if [[ -d "$pd" ]]; then
        local bn; bn=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
        [[ -n "$bn" ]] && before_newest=$(basename "$bn" .jsonl)
    fi
    local claude_exe; claude_exe=$(__cm_resolve_claude) || return 1
    "$claude_exe" --dangerously-skip-permissions --resume "$original_guid"
    __cm_resume_exit=$?
    if (( __cm_resume_exit == 0 )) && [[ -d "$pd" ]]; then
        local newest; newest=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
        if [[ -n "$newest" ]]; then
            local newest_bn; newest_bn=$(basename "$newest" .jsonl)
            if [[ "$newest_bn" != "$original_guid" ]] && [[ -z "$before_newest" || "$newest_bn" != "$before_newest" ]]; then
                # Fork detected. Swap guid in sessions.txt, quarantine predecessor.
                local sessions=() s new=() swapped=0
                mapfile -t sessions < <(__cm_get_sessions)
                for s in "${sessions[@]}"; do
                    local g d desc t; IFS='|' read -r g d desc t <<< "$s"
                    if [[ "$g" == "$original_guid" ]]; then
                        new+=("$newest_bn|$d|$desc|")
                        swapped=1
                    else
                        new+=("$s")
                    fi
                done
                (( swapped )) && __cm_save_sessions "${new[@]}"
                __cm_resume_effective_guid="$newest_bn"
                local pred="$pd/$original_guid.jsonl"
                if [[ -f "$pred" ]]; then
                    local leaf dest; leaf=$(basename "$project_dir"); dest="$__cm_backup_dir/$leaf"
                    mkdir -p "$dest" 2>/dev/null
                    mv -f "$pred" "$dest/$original_guid.jsonl" 2>/dev/null
                    [[ -d "$pd/$original_guid" ]] && mv -f "$pd/$original_guid" "$dest/$original_guid" 2>/dev/null
                    __cm_sync_session_index "$project_dir"
                fi
            fi
        fi
    fi
    return 0
}

# ==================================================================
# Do-Resume
# ==================================================================
__cm_do_resume() {
    local pick="$1"
    local sessions=()
    mapfile -t sessions < <(__cm_get_sessions)
    if (( pick < 1 || pick > ${#sessions[@]} )); then
        __cm_say "Invalid selection."; return
    fi
    local sel="${sessions[$((pick - 1))]}"
    local sel_g sel_d sel_desc sel_t
    IFS='|' read -r sel_g sel_d sel_desc sel_t <<< "$sel"
    if [[ ! -d "$sel_d" ]]; then
        __cm_say "Error: Project directory not found: $sel_d"; return
    fi
    local orig; orig=$(pwd)
    cd "$sel_d" || return
    __cm_do_orphan_scan "$sel_d" "$sel_g"
    if [[ "$__cm_scan_result_action" == "select" ]]; then
        local display_name="$__cm_machine_name - $sel_desc"
        __cm_invoke_resume_with_fork_detection "$__cm_scan_result_guid" "$sel_d" "$display_name"
        (( __cm_resume_exit == 0 )) && __cm_do_post_exit "$__cm_resume_effective_guid"
        cd "$orig"; return
    fi
    __cm_resolve_resume_or_recover "$sel_g" "$sel_d" "$sel_desc" "$sel_t"
    if [[ "$__cm_recover_action" == "cancel" ]]; then cd "$orig"; return; fi
    local display_name="$__cm_machine_name - $sel_desc"
    if [[ "$__cm_recover_action" == "fresh" ]]; then
        local pk pd; pk=$(__cm_get_proj_key "$sel_d"); pd="$HOME/.claude/projects/$pk"
        local before_newest=""
        if [[ -d "$pd" ]]; then
            local bn; bn=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
            [[ -n "$bn" ]] && before_newest=$(basename "$bn" .jsonl)
        fi
        local claude_exe; claude_exe=$(__cm_resolve_claude)
        "$claude_exe" --dangerously-skip-permissions
        if (( $? == 0 )); then
            local newest; newest=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
            if [[ -n "$newest" ]]; then
                local nb; nb=$(basename "$newest" .jsonl)
                if [[ -z "$before_newest" || "$nb" != "$before_newest" ]]; then
                    # Swap GUID in place in sessions.txt, preserve desc and dir, reset tokens.
                    local ses=() s new=()
                    mapfile -t ses < <(__cm_get_sessions)
                    for s in "${ses[@]}"; do
                        local g d desc t; IFS='|' read -r g d desc t <<< "$s"
                        if [[ "$g" == "$sel_g" ]]; then new+=("$nb|$d|$desc|")
                        else new+=("$s"); fi
                    done
                    __cm_save_sessions "${new[@]}"
                    __cm_do_post_exit "$nb"
                fi
            fi
        fi
        cd "$orig"; return
    fi
    if [[ "$__cm_recover_action" == "primed" ]]; then
        __cm_invoke_resume_with_fork_detection "$__cm_recover_guid" "$sel_d" "$display_name"
        (( __cm_resume_exit == 0 )) && __cm_do_post_exit "$__cm_resume_effective_guid"
        cd "$orig"; return
    fi
    # Normal resume branch.
    __cm_invoke_resume_with_fork_detection "$sel_g" "$sel_d" "$display_name"
    if (( __cm_resume_exit == 0 )); then
        __cm_do_post_exit "$__cm_resume_effective_guid"
    else
        local pk; pk=$(__cm_get_proj_key "$sel_d")
        local jp="$HOME/.claude/projects/$pk/$sel_g.jsonl"
        if [[ -f "$jp" ]]; then
            __cm_blank
            __cm_say_c "$__CM_C_YELLOW" "Claude refused to resume this session (file is on disk but Claude won't load it)."
            __cm_say "Common causes: interrupted tool call, stale deferred-tool marker."
            __cm_say "The session entry has NOT been deleted. You can try again later or investigate the JSONL."
        else
            __cm_blank
            local ans; printf '  Session JSONL is missing. Delete this entry? [Y/n]: '; read -r ans
            if [[ "$ans" != "n" && "$ans" != "N" ]]; then
                local ses=() s new=()
                mapfile -t ses < <(__cm_get_sessions)
                for s in "${ses[@]}"; do
                    local g _d _desc _t; IFS='|' read -r g _d _desc _t <<< "$s"
                    [[ "$g" != "$sel_g" ]] && new+=("$s")
                done
                __cm_save_sessions "${new[@]}"
                __cm_say "Entry removed."
            fi
        fi
    fi
    cd "$orig"
}

# ==================================================================
# Main entry: claudecm
# ==================================================================
claudecm() {
    # Bootstrap
    export CLAUDE_CODE_REMOTE_SEND_KEEPALIVES=1
    mkdir -p "$__cm_cm_dir" "$__cm_backup_dir" 2>/dev/null
    [[ -f "$__cm_sessions_file" ]] || : > "$__cm_sessions_file"
    __cm_ensure_cleanup_period_days
    __cm_auto_backup_sessions
    # Machine name.
    if [[ ! -f "$__cm_machine_name_file" ]]; then
        __cm_blank
        local mn; printf '  Machine name for remote display (e.g. desktop, laptop): '; read -r mn
        if [[ -z "$mn" ]]; then
            mn=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [[ -z "$mn" ]] && mn="unknown"
        fi
        printf '%s\n' "$mn" > "$__cm_machine_name_file"
        __cm_say "Saved: $mn"
    fi
    __cm_machine_name=$(head -1 "$__cm_machine_name_file" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$__cm_machine_name" ]]; then
        __cm_machine_name=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    local first="${1:-}"
    # List mode
    if [[ "$first" == "l" || "$first" == "L" || "$first" == "-l" || "$first" == "-L" ]]; then
        while true; do
            local sessions=()
            mapfile -t sessions < <(__cm_get_sessions)
            if (( ${#sessions[@]} == 0 )); then
                __cm_blank; __cm_say "No saved sessions."; __cm_blank; return
            fi
            __cm_show_list 0
            __cm_blank
            local pick; printf '  Pick a session (Enter to quit): '; read -r pick
            [[ -z "$pick" ]] && return
            if [[ "$pick" == "e" || "$pick" == "E" ]]; then __cm_do_edit_list; continue; fi
            if [[ "$pick" == "v" || "$pick" == "V" ]]; then __cm_do_view_archived; continue; fi
            if [[ "$pick" == "m" || "$pick" == "M" ]]; then
                __cm_blank
                __cm_say "Current machine name: $__cm_machine_name"
                local nm; printf '  New name (Enter to keep): '; read -r nm
                if [[ -n "$nm" ]]; then
                    printf '%s\n' "$nm" > "$__cm_machine_name_file"
                    __cm_machine_name="$nm"
                    __cm_say_c "$__CM_C_GREEN" "Machine name set to: $__cm_machine_name"
                fi
                continue
            fi
            if [[ "$pick" =~ ^[0-9]+$ ]]; then
                __cm_do_resume "$pick"; return
            fi
            # Non-numeric: new project title.
            local safe_name
            safe_name=$(printf '%s' "$pick" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/-/g; s/[^a-z0-9_-]//g')
            local new_proj="$HOME/$safe_name" counter=1
            while [[ -e "$new_proj" ]]; do
                new_proj="$HOME/${safe_name}($counter)"; counter=$((counter + 1))
            done
            mkdir -p "$new_proj"
            __cm_blank
            __cm_say "Starting new session: $pick"
            __cm_say "Project dir: $new_proj"
            local orig; orig=$(pwd)
            cd "$new_proj"
            local display_name="$__cm_machine_name - $pick"
            __cm_invoke_claude_launch "$new_proj" -- --dangerously-skip-permissions
            if [[ -n "$__cm_launch_sid" ]]; then
                local sessions=()
                mapfile -t sessions < <(__cm_get_sessions)
                __cm_save_sessions "$__cm_launch_sid|$new_proj|$pick|" "${sessions[@]}"
                __cm_do_post_exit "$__cm_launch_sid"
            fi
            cd "$orig"
            return
        done
        return
    fi
    # Direct resume by number
    if [[ "$first" =~ ^[0-9]+$ ]]; then
        local sessions=()
        mapfile -t sessions < <(__cm_get_sessions)
        if (( ${#sessions[@]} == 0 )); then __cm_say "No saved sessions."; return; fi
        __cm_show_list "$first"
        __cm_do_resume "$first"
        return
    fi
    # Normal mode: parse --proj and passArgs.
    local proj_dir="" pass_args=()
    while (( $# > 0 )); do
        if [[ "$1" == "--proj" ]]; then
            proj_dir="${2:-}"; shift 2
        else
            pass_args+=("$1"); shift
        fi
    done
    local orig; orig=$(pwd)
    if [[ -n "$proj_dir" ]]; then
        if [[ ! -d "$proj_dir" ]]; then __cm_say "Error: Directory not found: $proj_dir"; return; fi
        cd "$proj_dir"
    fi
    local cur_dir; cur_dir=$(pwd)
    local sessions=() s match=""
    mapfile -t sessions < <(__cm_get_sessions)
    for s in "${sessions[@]}"; do
        local g d _desc _t; IFS='|' read -r g d _desc _t <<< "$s"
        [[ "$d" == "$cur_dir" ]] && { match="$s"; break; }
    done
    local pre_named=""
    if (( ${#pass_args[@]} == 0 )); then
        if [[ -n "$match" ]]; then
            local mg md mdesc mt; IFS='|' read -r mg md mdesc mt <<< "$match"
            __cm_do_orphan_scan "$cur_dir" "$mg"
            if [[ "$__cm_scan_result_action" == "select" ]]; then
                if [[ ! -d "$md" ]]; then __cm_say "Error: Project directory not found: $md"; return; fi
                cd "$md"
                local dn="$__cm_machine_name - $mdesc"
                __cm_invoke_resume_with_fork_detection "$__cm_scan_result_guid" "$md" "$dn"
                (( __cm_resume_exit == 0 )) && __cm_do_post_exit "$__cm_resume_effective_guid"
                [[ -n "$proj_dir" ]] && cd "$orig"
                return
            fi
            __cm_blank
            __cm_say "Session found: $mdesc"
            local rename_ans; printf '  Rename? (Enter to keep): '; read -r rename_ans
            if [[ -n "$rename_ans" ]]; then
                local new=() ss
                for ss in "${sessions[@]}"; do
                    local g d desc t; IFS='|' read -r g d desc t <<< "$ss"
                    if [[ "$g" == "$mg" ]]; then new+=("$g|$d|$rename_ans|$t"); mdesc="$rename_ans"
                    else new+=("$ss"); fi
                done
                __cm_save_sessions "${new[@]}"
            fi
            local use_ans; printf '  Resume this session? [Y/n]: '; read -r use_ans
            if [[ "$use_ans" != "n" && "$use_ans" != "N" ]]; then
                if [[ ! -d "$md" ]]; then __cm_say "Error: Project directory not found: $md"; return; fi
                cd "$md"
                __cm_resolve_resume_or_recover "$mg" "$md" "$mdesc" "$mt"
                if [[ "$__cm_recover_action" == "cancel" ]]; then [[ -n "$proj_dir" ]] && cd "$orig"; return; fi
                local dn="$__cm_machine_name - $mdesc"
                if [[ "$__cm_recover_action" == "fresh" ]]; then
                    local pk pd; pk=$(__cm_get_proj_key "$md"); pd="$HOME/.claude/projects/$pk"
                    local before_newest=""
                    if [[ -d "$pd" ]]; then
                        local bn; bn=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
                        [[ -n "$bn" ]] && before_newest=$(basename "$bn" .jsonl)
                    fi
                    local claude_exe; claude_exe=$(__cm_resolve_claude)
                    "$claude_exe" --dangerously-skip-permissions -n "$dn"
                    if (( $? == 0 )); then
                        local newest; newest=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
                        if [[ -n "$newest" ]]; then
                            local nb; nb=$(basename "$newest" .jsonl)
                            if [[ -z "$before_newest" || "$nb" != "$before_newest" ]]; then
                                local ses=() ns new=()
                                mapfile -t ses < <(__cm_get_sessions)
                                for ns in "${ses[@]}"; do
                                    local g d desc t; IFS='|' read -r g d desc t <<< "$ns"
                                    if [[ "$g" == "$mg" ]]; then new+=("$nb|$d|$desc|")
                                    else new+=("$ns"); fi
                                done
                                __cm_save_sessions "${new[@]}"
                                __cm_do_post_exit "$nb"
                            fi
                        fi
                    fi
                    [[ -n "$proj_dir" ]] && cd "$orig"
                    return
                fi
                if [[ "$__cm_recover_action" == "primed" ]]; then
                    __cm_invoke_resume_with_fork_detection "$__cm_recover_guid" "$md" "$dn"
                    (( __cm_resume_exit == 0 )) && __cm_do_post_exit "$__cm_resume_effective_guid"
                    [[ -n "$proj_dir" ]] && cd "$orig"
                    return
                fi
                __cm_invoke_resume_with_fork_detection "$mg" "$md" "$dn"
                if (( __cm_resume_exit == 0 )); then
                    __cm_do_post_exit "$__cm_resume_effective_guid"
                else
                    local pk; pk=$(__cm_get_proj_key "$md")
                    local jp="$HOME/.claude/projects/$pk/$mg.jsonl"
                    if [[ -f "$jp" ]]; then
                        __cm_blank
                        __cm_say_c "$__CM_C_YELLOW" "Claude refused to resume this session (file is on disk but Claude won't load it)."
                        __cm_say "Common causes: interrupted tool call, stale deferred-tool marker."
                        __cm_say "The session entry has NOT been deleted."
                    else
                        __cm_blank
                        local del; printf '  Session JSONL is missing. Delete this entry? [Y/n]: '; read -r del
                        if [[ "$del" != "n" && "$del" != "N" ]]; then
                            local ses=() ns new=()
                            mapfile -t ses < <(__cm_get_sessions)
                            for ns in "${ses[@]}"; do
                                local g _d _desc _t; IFS='|' read -r g _d _desc _t <<< "$ns"
                                [[ "$g" != "$mg" ]] && new+=("$ns")
                            done
                            __cm_save_sessions "${new[@]}"
                            __cm_say "Entry removed."
                        fi
                    fi
                fi
                [[ -n "$proj_dir" ]] && cd "$orig"
                return
            fi
        else
            __cm_blank
            __cm_say "No session entry found for this directory."
            local fd; fd=$(basename "$(pwd)")
            fd="${fd//-/ }"
            fd=$(printf '%s' "$fd" | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
            printf "  Create a name for this session (Enter for '$fd', 'skip' to skip): "; read -r pre_named
            if [[ "$pre_named" == "skip" ]]; then pre_named=""
            elif [[ -z "$pre_named" ]]; then pre_named="$fd"; fi
        fi
    fi
    # Fresh launch path.
    local launch_desc
    if [[ -n "$pre_named" ]]; then launch_desc="$pre_named"
    elif [[ -n "$match" ]]; then local _g _d _dd _t; IFS='|' read -r _g _d _dd _t <<< "$match"; launch_desc="$_dd"
    else launch_desc=$(basename "$(pwd)"); fi
    local display_name="$__cm_machine_name - $launch_desc"
    __cm_invoke_claude_launch "$cur_dir" -- --dangerously-skip-permissions "${pass_args[@]}"
    if (( __cm_launch_exit != 0 )); then
        [[ -n "$proj_dir" ]] && cd "$orig"
        return
    fi
    if [[ -n "$pre_named" ]]; then
        if [[ -n "$__cm_launch_sid" ]]; then
            local ses=()
            mapfile -t ses < <(__cm_get_sessions)
            __cm_save_sessions "$__cm_launch_sid|$cur_dir|$pre_named|" "${ses[@]}"
            __cm_do_post_exit "$__cm_launch_sid"
        else
            __cm_do_post_exit
        fi
    else
        if [[ -n "$__cm_launch_sid" ]]; then __cm_do_post_exit "$__cm_launch_sid"
        else __cm_do_post_exit; fi
    fi
    [[ -n "$proj_dir" ]] && cd "$orig"
}

# When executed directly (not sourced), run the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    claudecm "$@"
fi

