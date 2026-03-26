#!/bin/bash
# ClaudeDSP - Claude launcher with session management (Linux/macOS)
#
# Install:
#   cp claudedsp-linux.sh /usr/local/bin/claudedsp
#   chmod +x /usr/local/bin/claudedsp
#
# Usage:
#   claudedsp                       Launch Claude normally
#   claudedsp l                     List saved sessions
#   claudedsp 3                     Resume session #3
#   claudedsp --proj /path/to/dir   Launch in a specific directory

# If running as root, re-exec as claude user
if [[ $(id -u) -eq 0 ]]; then
    exec sudo -u claude "$0" "$@"
fi

DSP_DIR="$HOME/.claudedsp"
SESSIONS_FILE="$DSP_DIR/sessions.txt"
NOTES_DIR="$DSP_DIR/notes"
CLAUDE_EXE=$(command -v claude || echo "$HOME/.local/bin/claude")
CMV_EXE=$(command -v cmv 2>/dev/null || echo "$HOME/.npm-global/bin/cmv")
EDITOR="${EDITOR:-nano}"

DEFAULT_REFRESH_PROMPT='Read your memories. This is a fresh session replacing a long previous conversation on this project. Everything you need to know is in:

1. Your memory files (MEMORY.md and all linked files)
2. Any documentation in the project directory (markdown files, QA reviews, specs)
3. The codebase itself (git log for history)
4. project_current_state.md in your memory if it exists

Read all of these before responding. Then tell me what you understand about: the current state of the project, what works, what is pending, and what your behavioral rules are. Do not start any development until I tell you to.'

mkdir -p "$DSP_DIR" "$NOTES_DIR"
touch "$SESSIONS_FILE"

SESSION_COUNT=0

# ---- Functions ----

show_list() {
    # Strip CRLF in case Claude's Write tool touched the file
    sed -i 's/\r$//' "$SESSIONS_FILE" 2>/dev/null
    local count highlight="${1:-0}"
    count=$(grep -c '.' "$SESSIONS_FILE" 2>/dev/null)
    count=${count:-0}
    if [[ $count -eq 0 ]]; then
        echo ""
        echo "  No saved sessions."
        echo ""
        return 1
    fi
    echo ""
    echo "  === Saved Sessions ==="
    echo ""
    SESSION_COUNT=0
    while IFS='|' read -r guid dir desc; do
        ((SESSION_COUNT++))
        if [[ $SESSION_COUNT -eq $highlight ]]; then
            echo -e "  \033[1;33m*** $SESSION_COUNT. $desc  [Selected] ***\033[0m"
        else
            echo "  $SESSION_COUNT. $desc"
        fi
    done < "$SESSIONS_FILE"
    echo ""
    echo "  E. Edit this list"
    return 0
}

get_entry() {
    local pick=$1 idx=0
    while IFS='|' read -r guid dir desc; do
        ((idx++))
        if [[ $idx -eq $pick ]]; then
            SEL_GUID="$guid"
            SEL_DIR="$dir"
            SEL_DESC="$desc"
            return 0
        fi
    done < "$SESSIONS_FILE"
    return 1
}

find_session_guid() {
    SESSION_GUID=""
    local proj_key
    proj_key=$(pwd | sed 's|/|-|g')
    local claude_proj_dir="$HOME/.claude/projects/$proj_key"
    [[ -d "$claude_proj_dir" ]] || return 1
    local newest
    newest=$(ls -t "$claude_proj_dir"/*.jsonl 2>/dev/null | head -1)
    [[ -n "$newest" ]] && SESSION_GUID=$(basename "$newest" .jsonl)
}

move_to_top() {
    local guid_to_move="$1"
    local tmp="$SESSIONS_FILE.tmp"
    grep "^$guid_to_move|" "$SESSIONS_FILE" > "$tmp"
    grep -v "^$guid_to_move|" "$SESSIONS_FILE" >> "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
}

update_desc() {
    local target_guid="$1" new_desc="$2" tmp="$SESSIONS_FILE.tmp"
    while IFS='|' read -r guid dir desc; do
        if [[ "$guid" == "$target_guid" ]]; then
            echo "$guid|$dir|$new_desc"
        else
            echo "$guid|$dir|$desc"
        fi
    done < "$SESSIONS_FILE" > "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
}

do_trim() {
    # Trim the current session via CMV. Returns new GUID in TRIM_NEW_GUID.
    TRIM_NEW_GUID=""
    if ! command -v "$CMV_EXE" &>/dev/null; then
        echo "  cmv not found. Skipping trim."
        return 1
    fi
    echo "  Trimming session..."
    local trim_output
    trim_output=$("$CMV_EXE" trim --latest --skip-launch 2>&1)
    local new_guid
    new_guid=$(echo "$trim_output" | grep -oP 'Session ID:\s*\K[0-9a-f-]+')
    if [[ -z "$new_guid" ]]; then
        echo "  Trim failed or no new session ID found."
        echo "$trim_output" | head -5
        return 1
    fi
    # Update GUID in sessions.txt
    local tmp="$SESSIONS_FILE.tmp"
    while IFS='|' read -r guid dir desc; do
        if [[ "$guid" == "$SESSION_GUID" ]]; then
            echo "$new_guid|$dir|$desc"
        else
            echo "$guid|$dir|$desc"
        fi
    done < "$SESSIONS_FILE" > "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
    # Rename notes file if it exists
    if [[ -f "$NOTES_DIR/$SESSION_GUID.txt" ]]; then
        mv "$NOTES_DIR/$SESSION_GUID.txt" "$NOTES_DIR/$new_guid.txt"
    fi
    # Ensure trimmed JSONL is accessible from the session's project dir
    local session_dir=""
    while IFS='|' read -r g d desc_; do
        [[ "$g" == "$new_guid" ]] && session_dir="$d" && break
    done < "$SESSIONS_FILE"
    if [[ -n "$session_dir" ]]; then
        local expected_key expected_dir expected_file
        expected_key=$(echo "$session_dir" | sed 's|/|-|g')
        expected_dir="$HOME/.claude/projects/$expected_key"
        expected_file="$expected_dir/$new_guid.jsonl"
        if [[ ! -f "$expected_file" ]]; then
            # Find where CMV actually put it
            local actual
            actual=$(find "$HOME/.claude/projects" -name "$new_guid.jsonl" 2>/dev/null | head -1)
            if [[ -n "$actual" ]]; then
                mkdir -p "$expected_dir"
                ln -s "$actual" "$expected_file"
            fi
        fi
    fi
    SESSION_GUID="$new_guid"
    TRIM_NEW_GUID="$new_guid"
    # Show trim stats (skip the Session ID line we already parsed)
    echo "$trim_output" | grep -v "Session ID:" | grep -v "^$" | head -10
    echo ""
    echo "  Session trimmed. New ID: $new_guid"
}

do_refresh() {
    # Replace current session with a fresh one.
    # Old session gets "(old)" appended and moved to bottom.

    # Get current session's description and directory from sessions.txt
    local cur_desc="" cur_dir=""
    while IFS='|' read -r guid dir desc; do
        if [[ "$guid" == "$SESSION_GUID" ]]; then
            cur_desc="$desc"
            cur_dir="$dir"
            break
        fi
    done < "$SESSIONS_FILE"
    [[ -z "$cur_dir" ]] && cur_dir=$(pwd)

    # Ask for new session name (default: same as current)
    echo ""
    read -rp "  Name for new session (Enter for '$cur_desc'): " new_name
    [[ -z "$new_name" ]] && new_name="$cur_desc"

    # Offer to edit the refresh prompt
    local prompt_file="$DSP_DIR/refresh-prompt.tmp"
    echo "$DEFAULT_REFRESH_PROMPT" > "$prompt_file"
    read -rp "  Edit the refresh prompt? (Ctrl-X when done) [y/N]: " edit_prompt
    if [[ "${edit_prompt,,}" == "y" ]]; then
        $EDITOR "$prompt_file"
    fi
    local prompt_text
    prompt_text=$(cat "$prompt_file")
    rm -f "$prompt_file"

    # Run Claude headless with the prompt, from the session's directory
    local orig_dir
    orig_dir=$(pwd)
    cd "$cur_dir" || { echo "  Error: Can't cd to $cur_dir"; return 1; }
    echo ""
    "$CLAUDE_EXE" --dangerously-skip-permissions -p "$prompt_text" > /dev/null 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %s Please wait while the new session is created..." "${spin:i++%${#spin}:1}"
        sleep 0.1
    done
    printf "\r  ✓ Done.                                              \n"
    wait "$pid"

    # Capture the new session GUID
    local old_guid="$SESSION_GUID"
    find_session_guid
    cd "$orig_dir" 2>/dev/null
    if [[ -z "$SESSION_GUID" ]]; then
        echo "  Warning: Could not find new session GUID."
        return 1
    fi

    # Rewrite sessions.txt: new session at top, old session "(old)" at bottom
    local tmp="$SESSIONS_FILE.tmp"
    local old_line=""
    {
        # New session first
        echo "$SESSION_GUID|$cur_dir|$new_name"
        # Everything else except old session
        while IFS='|' read -r guid dir desc; do
            if [[ "$guid" == "$old_guid" ]]; then
                if [[ "$desc" == *"(old)"* ]]; then
                    old_line="$guid|$dir|$desc"
                else
                    old_line="$guid|$dir|$desc (old)"
                fi
            else
                echo "$guid|$dir|$desc"
            fi
        done < "$SESSIONS_FILE"
        # Old session at bottom
        [[ -n "$old_line" ]] && echo "$old_line"
    } > "$tmp"
    mv "$tmp" "$SESSIONS_FILE"
    echo ""
    echo "  Fresh session created: $new_name"
    echo "  Old session moved to bottom of list."
}

post_exit() {
    # Let Claude Code finish its terminal cleanup before we prompt
    sleep 0.3
    echo ""
    echo ""
    echo ""
    echo "  Session ended."
    echo ""

    local known_guid="${1:-}"
    if [[ -n "$known_guid" ]]; then
        SESSION_GUID="$known_guid"
    else
        find_session_guid || return
        [[ -z "$SESSION_GUID" ]] && return
    fi

    if grep -q "^$SESSION_GUID|" "$SESSIONS_FILE"; then
        move_to_top "$SESSION_GUID"
    else
        echo ""
        read -rp "  Describe this session (Enter to skip): " session_desc
        [[ -z "$session_desc" ]] && return
        local tmp="$SESSIONS_FILE.tmp"
        echo "$SESSION_GUID|$(pwd)|$session_desc" > "$tmp"
        cat "$SESSIONS_FILE" >> "$tmp"
        mv "$tmp" "$SESSIONS_FILE"
    fi

    echo ""
    read -rp "  Add/edit notes? [y/N]: " edit_notes
    if [[ "${edit_notes,,}" == "y" ]]; then
        local note_path="$NOTES_DIR/$SESSION_GUID.txt"
        [[ -f "$note_path" ]] || touch "$note_path"
        $EDITOR "$note_path"
    fi

    # Anti-bloat: trim and refresh options
    echo ""
    read -rp "  Trim this session? [y/N]: " do_trim_answer
    if [[ "${do_trim_answer,,}" == "y" ]]; then
        do_trim
    fi

    echo ""
    read -rp "  Replace current session with a fresh one? (deeper clean) [y/N]: " do_refresh_answer
    if [[ "${do_refresh_answer,,}" == "y" ]]; then
        do_refresh
    fi
}

do_edit() {
    while true; do
        echo ""
        echo "  === Edit Sessions ==="
        echo ""
        local idx=0
        while IFS='|' read -r guid dir desc; do
            ((idx++))
            echo "  $idx. $desc  [$dir]"
        done < "$SESSIONS_FILE"
        echo ""
        echo "  R# = Rename   P# = Path   D# = Delete   M#,# = Move (from,to)   Q = Done"
        echo ""
        read -rp "  >: " cmd
        [[ -z "$cmd" ]] && return
        [[ "${cmd,,}" == "q" ]] && return

        if [[ "${cmd,,}" =~ ^r([0-9]+)$ ]]; then
            local num=${BASH_REMATCH[1]}
            get_entry "$num" || { echo "  Invalid #."; continue; }
            read -rp "  New name for '$SEL_DESC': " new_name
            if [[ -n "$new_name" ]]; then
                update_desc "$SEL_GUID" "$new_name"
            fi

        elif [[ "${cmd,,}" =~ ^p([0-9]+)$ ]]; then
            local num=${BASH_REMATCH[1]}
            get_entry "$num" || { echo "  Invalid #."; continue; }
            echo "  Current: $SEL_DIR"
            read -rp "  New path (Enter to keep): " new_path
            if [[ -n "$new_path" ]]; then
                # Copy .jsonl to new project directory
                local old_key new_key claude_proj old_file new_dir new_file
                old_key=$(echo "$SEL_DIR" | sed 's|/|-|g')
                new_key=$(echo "$new_path" | sed 's|/|-|g')
                claude_proj="$HOME/.claude/projects"
                old_file="$claude_proj/$old_key/$SEL_GUID.jsonl"
                new_dir="$claude_proj/$new_key"
                new_file="$new_dir/$SEL_GUID.jsonl"
                if [[ -f "$old_file" ]]; then
                    mkdir -p "$new_dir"
                    cp "$old_file" "$new_file"
                    echo "  Session file copied to new project directory."
                else
                    echo "  Warning: Session file not found at old path. Resume may not work."
                fi
                # Update path in sessions file
                local tmp="$SESSIONS_FILE.tmp"
                local i=0
                while IFS='|' read -r guid dir desc; do
                    ((i++))
                    if [[ $i -eq $num ]]; then
                        echo "$guid|$new_path|$desc"
                    else
                        echo "$guid|$dir|$desc"
                    fi
                done < "$SESSIONS_FILE" > "$tmp"
                mv "$tmp" "$SESSIONS_FILE"
            fi

        elif [[ "${cmd,,}" =~ ^d([0-9]+)$ ]]; then
            local num=${BASH_REMATCH[1]}
            get_entry "$num" || { echo "  Invalid #."; continue; }
            read -rp "  Delete '$SEL_DESC'? [y/N]: " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                # Archive notes if they exist
                local note_path="$NOTES_DIR/$SEL_GUID.txt"
                if [[ -f "$note_path" ]]; then
                    local deleted_dir="$NOTES_DIR/deleted"
                    mkdir -p "$deleted_dir"
                    local safe_name
                    safe_name=$(echo "$SEL_DESC" | sed 's|[/:\\*?"<>|]|_|g')
                    local dest_file="$deleted_dir/$safe_name.txt"
                    local counter=1
                    while [[ -f "$dest_file" ]]; do
                        dest_file="$deleted_dir/$safe_name ($counter).txt"
                        ((counter++))
                    done
                    mv "$note_path" "$dest_file"
                    echo "  Notes archived to deleted/$(basename "$dest_file")"
                fi
                local tmp="$SESSIONS_FILE.tmp"
                local i=0
                while IFS='|' read -r guid dir desc; do
                    ((i++))
                    [[ $i -ne $num ]] && echo "$guid|$dir|$desc"
                done < "$SESSIONS_FILE" > "$tmp"
                mv "$tmp" "$SESSIONS_FILE"
            fi

        elif [[ "${cmd,,}" =~ ^m([0-9]+),([0-9]+)$ ]]; then
            local from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}
            local -a lines=()
            while IFS= read -r line; do
                lines+=("$line")
            done < "$SESSIONS_FILE"
            local max=${#lines[@]}
            if [[ $from -lt 1 || $from -gt $max || $to -lt 1 || $to -gt $max ]]; then
                echo "  Invalid range."
                continue
            fi
            local item="${lines[$((from-1))]}"
            local -a tmp_arr=()
            for ((i=0; i<max; i++)); do
                [[ $i -ne $((from-1)) ]] && tmp_arr+=("${lines[$i]}")
            done
            local -a new_arr=()
            local inserted=0
            for ((i=0; i<${#tmp_arr[@]}; i++)); do
                if [[ $((i+1)) -eq $to && $inserted -eq 0 ]]; then
                    new_arr+=("$item")
                    inserted=1
                fi
                new_arr+=("${tmp_arr[$i]}")
            done
            [[ $inserted -eq 0 ]] && new_arr+=("$item")
            printf '%s\n' "${new_arr[@]}" > "$SESSIONS_FILE"

        else
            echo "  Unknown command."
        fi
    done
}

do_resume() {
    local pick=$1
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [[ $pick -lt 1 || $pick -gt $SESSION_COUNT ]]; then
        echo "  Invalid selection."
        return 1
    fi
    get_entry "$pick"

    # Only offer notes review if notes file exists and has content
    if [[ -f "$NOTES_DIR/$SEL_GUID.txt" ]]; then
        local note_content
        note_content=$(cat "$NOTES_DIR/$SEL_GUID.txt" 2>/dev/null)
        if [[ -n "$note_content" ]]; then
            echo ""
            read -rp "  Review notes? [Y/n]: " review
            if [[ "${review,,}" != "n" ]]; then
                echo ""
                echo "  --- Notes: $SEL_DESC ---"
                echo ""
                echo "$note_content"
                echo ""
                echo "  --- End of notes ---"
                echo ""
                read -rp "  Press Enter to continue..."
            fi
        fi
    fi

    if [[ ! -d "$SEL_DIR" ]]; then
        echo "  Error: Project directory not found: $SEL_DIR"
        return 1
    fi
    local orig_dir
    orig_dir=$(pwd)
    cd "$SEL_DIR" || return 1
    "$CLAUDE_EXE" --dangerously-skip-permissions --resume "$SEL_GUID"
    local claude_rc=$?
    if [[ $claude_rc -ne 0 ]]; then
        echo ""
        read -rp "  Session not found. Delete this entry? [Y/n]: " del_entry
        if [[ "${del_entry,,}" != "n" ]]; then
            local tmp="$SESSIONS_FILE.tmp"
            grep -v "^$SEL_GUID|" "$SESSIONS_FILE" > "$tmp"
            mv "$tmp" "$SESSIONS_FILE"
            echo "  Entry removed."
        fi
        cd "$orig_dir" || true
        return 1
    fi
    post_exit "$SEL_GUID"
    cd "$orig_dir" || true
}

# ---- Main ----

# List mode
if [[ "${1,,}" == "l" || "$1" == "-l" || "$1" == "-L" ]]; then
    while true; do
        show_list || exit 0
        echo ""
        read -rp "  Pick #, new title, or Enter to quit: " pick
        [[ -z "$pick" ]] && exit 0
        if [[ "${pick,,}" == "e" ]]; then
            do_edit
            continue
        fi
        if [[ "$pick" =~ ^[0-9]+$ ]]; then
            do_resume "$pick"
            exit 0
        fi
        # Non-numeric, non-empty, non-E: treat as new session title
        proj_dir="$HOME/$(echo "$pick" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/[^a-z0-9_-]//g')"
        if [[ -d "$proj_dir" ]]; then
            n=1
            while [[ -d "${proj_dir}(${n})" ]]; do ((n++)); done
            proj_dir="${proj_dir}(${n})"
        fi
        mkdir -p "$proj_dir"
        echo ""
        echo "  Starting new session: $pick"
        echo "  Project dir: $proj_dir"
        cd "$proj_dir" || exit 1
        "$CLAUDE_EXE" --dangerously-skip-permissions
        find_session_guid
        if [[ -n "$SESSION_GUID" ]]; then
            echo "$SESSION_GUID|$proj_dir|$pick" > "$SESSIONS_FILE.tmp"
            cat "$SESSIONS_FILE" >> "$SESSIONS_FILE.tmp"
            mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
            post_exit "$SESSION_GUID"
        fi
        exit 0
    done
fi

# Direct resume by number
if [[ "$1" =~ ^[0-9]+$ ]]; then
    show_list "$1" || { echo "  No saved sessions."; exit 0; }
    do_resume "$1"
    exit 0
fi

# Normal mode
PROJ_DIR=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proj)
            PROJ_DIR="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

ORIG_DIR=$(pwd)
if [[ -n "$PROJ_DIR" ]]; then
    if [[ ! -d "$PROJ_DIR" ]]; then
        echo "Error: Directory not found: $PROJ_DIR"
        exit 1
    fi
    cd "$PROJ_DIR" || exit 1
fi

# Check if current directory matches an existing session
CUR_DIR=$(pwd)
MATCH_GUID=""
MATCH_DESC=""
while IFS='|' read -r guid dir desc; do
    if [[ "$dir" == "$CUR_DIR" ]]; then
        MATCH_GUID="$guid"
        MATCH_DESC="$desc"
        break
    fi
done < "$SESSIONS_FILE"

PRE_NAMED=""
if [[ ${#ARGS[@]} -eq 0 ]]; then
    if [[ -n "$MATCH_GUID" ]]; then
        echo ""
        echo "  Session found: $MATCH_DESC"
        read -rp "  Rename? (Enter to keep): " rename
        if [[ -n "$rename" ]]; then
            update_desc "$MATCH_GUID" "$rename"
        fi
        read -rp "  Resume this session? [Y/n]: " use_existing
        if [[ "${use_existing,,}" != "n" ]]; then
            "$CLAUDE_EXE" --dangerously-skip-permissions --resume "$MATCH_GUID"
            if [[ $? -eq 0 ]]; then
                post_exit "$MATCH_GUID"
            else
                echo ""
                read -rp "  Session not found. Delete this entry? [Y/n]: " del_entry
                if [[ "${del_entry,,}" != "n" ]]; then
                    grep -v "^$MATCH_GUID|" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp"
                    mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
                    echo "  Entry removed."
                fi
            fi
            [[ -n "$PROJ_DIR" ]] && cd "$ORIG_DIR" 2>/dev/null
            exit 0
        fi
    else
        echo ""
        echo "  No session entry found for this directory."
        read -rp "  Create a name for this session (Enter to skip): " PRE_NAMED
    fi
fi

"$CLAUDE_EXE" --dangerously-skip-permissions "${ARGS[@]}"
CLAUDE_RC=$?

if [[ $CLAUDE_RC -ne 0 ]]; then
    [[ -n "$PROJ_DIR" ]] && cd "$ORIG_DIR" 2>/dev/null
    exit $CLAUDE_RC
fi

if [[ -n "$PRE_NAMED" ]]; then
    find_session_guid
    if [[ -n "$SESSION_GUID" ]]; then
        echo "$SESSION_GUID|$CUR_DIR|$PRE_NAMED" > "$SESSIONS_FILE.tmp"
        cat "$SESSIONS_FILE" >> "$SESSIONS_FILE.tmp"
        mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
        post_exit "$SESSION_GUID"
    fi
else
    post_exit
fi

[[ -n "$PROJ_DIR" ]] && cd "$ORIG_DIR" 2>/dev/null
