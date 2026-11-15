#!/usr/bin/env bash
#
# run-backups.sh - run backup.sh in every subdirectory of a base directory.
#
# For each <base>/<subdir>/ that contains the backup script, the script is run
# from inside that directory and its output is written to
# <base>/<subdir>/backup_logs/ (configurable). A failure in one backup is
# logged and reported, but never stops the run.
#
# Optionally sends a summary notification via Gotify and/or ntfy when the run
# finishes (and on fatal errors). Settings live in a YAML file, by default
# ~/.config/run-backups/config.yaml - see run-backups.example.yaml.

# ---- Defaults (override with config file or command line options) -----------
BASE_DIR="/docker"
BACKUP_SCRIPT="backup.sh"
LOG_SUBDIR="backup_logs"
POST_RUN_SCRIPT=""
DRY_RUN=0   # 1 = only show what would be done (same as -n)
VERBOSE=0
CONFIG_FILE="${RUN_BACKUPS_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/run-backups/config.yaml}"
# -----------------------------------------------------------------------------

CONFIG_EXPLICIT=0
BASE_DIR_EXPLICIT=0
BACKUP_SCRIPT_EXPLICIT=0
LOG_SUBDIR_EXPLICIT=0
POST_RUN_EXPLICIT=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-d base_dir] [-s backup_command] [-l log_subdir]
                        [-p post_run_script]
                        [-c config_file] [-n] [-v] [-h]

  -d DIR     Base directory containing the subdirectories to scan
             (default: $BASE_DIR)
  -s CMD     Relative backup script path and optional arguments; searched under
             each directory (absolute paths are not allowed)
             (default: $BACKUP_SCRIPT)
  -l NAME    Name of the log subdirectory created inside each subdirectory
             (default: $LOG_SUBDIR)
  -p CMD     Post-run script and optional arguments, run after each backup
             (default: none; use -p "" to disable a YAML-configured script)
  -c FILE    YAML file with Gotify/ntfy notification settings
             (default: $CONFIG_FILE)
  -n         Dry run: show what would be done, but don't run any backup
             scripts, create log files, or send notifications
  -v         Verbose: show effective configuration and command output
  -h         Show this help
USAGE
}

while getopts ":d:s:l:p:c:nvh" opt; do
    case "$opt" in
        d) BASE_DIR="$OPTARG"; BASE_DIR_EXPLICIT=1 ;;
        s) BACKUP_SCRIPT="$OPTARG"; BACKUP_SCRIPT_EXPLICIT=1 ;;
        l) LOG_SUBDIR="$OPTARG"; LOG_SUBDIR_EXPLICIT=1 ;;
        p) POST_RUN_SCRIPT="$OPTARG"; POST_RUN_EXPLICIT=1 ;;
        c) CONFIG_FILE="$OPTARG"; CONFIG_EXPLICIT=1 ;;
        n) DRY_RUN=1 ;;
        v) VERBOSE=1 ;;
        h) usage; exit 0 ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage >&2; exit 2 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done

# Timestamp helpers
now()   { date '+%Y-%m-%d %H:%M:%S'; }
stamp() { date '+%Y%m%d-%H%M%S'; }

# ---- Notification config ----------------------------------------------------

NOTIFY_ON="always"          # always | error
GOTIFY_ON=0; GOTIFY_URL=""; GOTIFY_TOKEN=""; GOTIFY_PRIORITY=5; GOTIFY_ERROR_PRIORITY=8
NTFY_ON=0;   NTFY_URL="";   NTFY_TOPIC="";   NTFY_TOKEN=""; NTFY_USER=""; NTFY_PASSWORD=""
NTFY_PRIORITY="default"; NTFY_ERROR_PRIORITY="high"

# Minimal YAML reader for the simple "section: / indented key: value" layout
# used by the config file. Usage: yaml_get FILE SECTION KEY
yaml_get() {
    awk -v sect="$2" -v key="$3" '
        { sub(/\r$/, "") }
        /^[[:space:]]*(#|$)/ { next }
        /^[^[:space:]]/ {
            name = $0; sub(/[[:space:]]*:.*/, "", name)
            in_sect = (name == sect); next
        }
        in_sect {
            line = $0; sub(/^[[:space:]]+/, "", line)
            k = line; sub(/[[:space:]]*:.*/, "", k)
            if (k == key) {
                v = line; sub(/^[^:]*:[[:space:]]*/, "", v)
                sub(/[[:space:]]+#.*$/, "", v)
                sub(/[[:space:]]+$/, "", v)
                gsub("^[\"\047]|[\"\047]$", "", v)
                print v; exit
            }
        }
    ' "$1"
}

cfg() { yaml_get "$CONFIG_FILE" "$1" "$2"; }

is_false() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        false|no|off|0) return 0 ;;
        *) return 1 ;;
    esac
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ $CONFIG_EXPLICIT -eq 1 ]]; then
            echo "Error: config file '$CONFIG_FILE' not found." >&2
            exit 2
        fi
        return 0    # no config = notifications simply off
    fi

    local v
    if [[ $BASE_DIR_EXPLICIT -eq 0 ]]; then
        v="$(cfg run base_dir)"; [[ -n "$v" ]] && BASE_DIR="$v"
    fi
    if [[ $BACKUP_SCRIPT_EXPLICIT -eq 0 ]]; then
        v="$(cfg run backup_script)"; [[ -n "$v" ]] && BACKUP_SCRIPT="$v"
    fi
    if [[ $LOG_SUBDIR_EXPLICIT -eq 0 ]]; then
        v="$(cfg run log_subdir)"; [[ -n "$v" ]] && LOG_SUBDIR="$v"
    fi

    # The file holds tokens/passwords, so warn if others can read it
    local perm
    perm="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$perm" && ! "$perm" =~ 00$ ]]; then
        echo "WARNING: $CONFIG_FILE is accessible by other users (mode $perm); consider: chmod 600 '$CONFIG_FILE'" >&2
    fi

    v="$(cfg notify on)"
    case "$v" in
        ""|always) NOTIFY_ON="always" ;;
        error)     NOTIFY_ON="error" ;;
        *) echo "WARNING: notify.on must be 'always' or 'error' (got '$v'); using 'always'." >&2 ;;
    esac

    # Gotify
    GOTIFY_URL="$(cfg gotify url)"
    GOTIFY_TOKEN="$(cfg gotify token)"
    v="$(cfg gotify priority)";       [[ -n "$v" ]] && GOTIFY_PRIORITY="$v"
    v="$(cfg gotify error_priority)"; [[ -n "$v" ]] && GOTIFY_ERROR_PRIORITY="$v"
    if [[ -n "$GOTIFY_URL$GOTIFY_TOKEN" ]] && ! is_false "$(cfg gotify enabled)"; then
        if [[ -n "$GOTIFY_URL" && -n "$GOTIFY_TOKEN" ]]; then
            GOTIFY_ON=1
        else
            echo "WARNING: gotify needs both 'url' and 'token'; gotify notifications disabled." >&2
        fi
    fi

    # ntfy
    NTFY_URL="$(cfg ntfy url)"
    NTFY_TOPIC="$(cfg ntfy topic)"
    NTFY_TOKEN="$(cfg ntfy token)"
    NTFY_USER="$(cfg ntfy username)"
    NTFY_PASSWORD="$(cfg ntfy password)"
    v="$(cfg ntfy priority)";       [[ -n "$v" ]] && NTFY_PRIORITY="$v"
    v="$(cfg ntfy error_priority)"; [[ -n "$v" ]] && NTFY_ERROR_PRIORITY="$v"
    if [[ -n "$NTFY_URL$NTFY_TOPIC" ]] && ! is_false "$(cfg ntfy enabled)"; then
        if [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]]; then
            NTFY_ON=1
        else
            echo "WARNING: ntfy needs both 'url' and 'topic'; ntfy notifications disabled." >&2
        fi
    fi

    if [[ $POST_RUN_EXPLICIT -eq 0 ]]; then
        POST_RUN_SCRIPT="$(cfg post_run script)"
    fi

    if [[ $((GOTIFY_ON + NTFY_ON)) -gt 0 ]] && ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not found; notifications disabled." >&2
        GOTIFY_ON=0; NTFY_ON=0
    fi
}

# ---- Notification senders (never allowed to fail the script) ----------------

send_gotify() {
    local title="$1" message="$2" is_error="$3" prio="$GOTIFY_PRIORITY"
    [[ $is_error -eq 1 ]] && prio="$GOTIFY_ERROR_PRIORITY"
    if curl -fsS --max-time 15 -o /dev/null \
            -H "X-Gotify-Key: $GOTIFY_TOKEN" \
            --form-string "title=$title" \
            --form-string "message=$message" \
            --form-string "priority=$prio" \
            "${GOTIFY_URL%/}/message"; then
        echo "[$(now)] Notification sent via gotify"
    else
        echo "[$(now)] WARNING: failed to send gotify notification" >&2
    fi
}

send_ntfy() {
    local title="$1" message="$2" is_error="$3" prio="$NTFY_PRIORITY" tags="white_check_mark"
    if [[ $is_error -eq 1 ]]; then
        prio="$NTFY_ERROR_PRIORITY"; tags="rotating_light"
    fi
    local args=(-fsS --max-time 15 -o /dev/null
                -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags")
    if [[ -n "$NTFY_TOKEN" ]]; then
        args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    elif [[ -n "$NTFY_USER" ]]; then
        args+=(-u "$NTFY_USER:$NTFY_PASSWORD")
    fi
    if curl "${args[@]}" --data-binary "$message" "${NTFY_URL%/}/$NTFY_TOPIC"; then
        echo "[$(now)] Notification sent via ntfy"
    else
        echo "[$(now)] WARNING: failed to send ntfy notification" >&2
    fi
}

# notify TITLE MESSAGE IS_ERROR(0|1)
notify() {
    local title="$1" message="$2" is_error="$3"
    [[ $is_error -eq 0 && "$NOTIFY_ON" == "error" ]] && return 0
    [[ $GOTIFY_ON -eq 1 ]] && send_gotify "$title" "$message" "$is_error"
    [[ $NTFY_ON   -eq 1 ]] && send_ntfy   "$title" "$message" "$is_error"
    return 0
}

print_config_summary() {
    local gotify_auth="no" ntfy_auth="no" post_run="none"
    [[ -n "$GOTIFY_TOKEN" ]] && gotify_auth="yes"
    [[ -n "$NTFY_TOKEN$NTFY_USER$NTFY_PASSWORD" ]] && ntfy_auth="yes"
    [[ ${#POST_RUN_ARGS[@]} -gt 0 ]] && post_run="$POST_RUN_SCRIPT"

    echo "[CONFIG] Effective configuration:"
    echo "  Config file: $CONFIG_FILE"
    echo "  Base directory: $BASE_DIR"
    echo "  Backup command: $BACKUP_SCRIPT"
    echo "  Log subdirectory: $LOG_SUBDIR"
    echo "  Post-run command: $post_run"
    echo "  Dry run: $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
    echo "  Notifications: $NOTIFY_ON"
    echo "  Gotify: $([[ $GOTIFY_ON -eq 1 ]] && echo enabled || echo disabled); token configured: $gotify_auth; priorities: $GOTIFY_PRIORITY/$GOTIFY_ERROR_PRIORITY"
    echo "  ntfy: $([[ $NTFY_ON -eq 1 ]] && echo enabled || echo disabled); authentication configured: $ntfy_auth; priorities: $NTFY_PRIORITY/$NTFY_ERROR_PRIORITY"
}

run_logged() {
    local log_file="$1"
    shift

    if [[ $VERBOSE -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$log_file"
        local -a pipeline_status=("${PIPESTATUS[@]}")
        [[ ${pipeline_status[0]} -ne 0 ]] && return "${pipeline_status[0]}"
        return "${pipeline_status[1]}"
    fi

    "$@" >>"$log_file" 2>&1
}

run_backup_command() {
    local dir="$1"
    (
        cd "$dir" || exit 1
        local backup_run_path="./$BACKUP_COMMAND"
        if [[ -x "$backup_run_path" ]]; then
            "$backup_run_path" "${BACKUP_ARGS[@]:1}"
        else
            bash -- "$backup_run_path" "${BACKUP_ARGS[@]:1}"
        fi
    )
}

run_post_run_command() {
    local dir="$1"
    (
        cd "$dir" || exit 1
        local post_run_command="${POST_RUN_ARGS[0]}"
        if [[ -x "$post_run_command" ]]; then
            if [[ "$post_run_command" == */* ]]; then
                "$post_run_command" "${POST_RUN_ARGS[@]:1}"
            else
                "./$post_run_command" "${POST_RUN_ARGS[@]:1}"
            fi
        else
            bash -- "$post_run_command" "${POST_RUN_ARGS[@]:1}"
        fi
    )
}

# ---- Main -------------------------------------------------------------------

load_config
BASE_DIR="${BASE_DIR%/}"
HOST="$(hostname -s 2>/dev/null || hostname)"

if [[ ! -d "$BASE_DIR" ]]; then
    msg="Error: base directory '$BASE_DIR' does not exist."
    echo "$msg" >&2
    [[ $DRY_RUN -eq 0 ]] && notify "Backups on $HOST: could not start" "$msg" 1
    exit 1
fi

shopt -s nullglob

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] Scanning $BASE_DIR for $BACKUP_SCRIPT (no scripts will be run)"
fi

POST_RUN_ARGS=()
if [[ -n "$POST_RUN_SCRIPT" ]]; then
    read -r -a POST_RUN_ARGS <<< "$POST_RUN_SCRIPT"
fi

BACKUP_ARGS=()
if [[ -n "$BACKUP_SCRIPT" ]]; then
    read -r -a BACKUP_ARGS <<< "$BACKUP_SCRIPT"
fi
BACKUP_COMMAND="${BACKUP_ARGS[0]}"
BACKUP_FILE="${BACKUP_COMMAND##*/}"
if [[ "$BACKUP_COMMAND" == /* ]]; then
    echo "Error: backup script path must be relative to each scanned directory." >&2
    exit 2
fi
case "/$BACKUP_COMMAND/" in
    */../*)
        echo "Error: backup script path must not escape the scanned directory." >&2
        exit 2
        ;;
esac

if [[ $VERBOSE -eq 1 ]]; then
    print_config_summary
fi

found=0
succeeded=0
failed=0
failed_dirs=()

for dir in "$BASE_DIR"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"

    # Skip directories without the backup script
    backup_path="$dir/$BACKUP_COMMAND"
    [[ -f "$backup_path" ]] || continue

    found=$((found + 1))
    log_dir="$dir/$LOG_SUBDIR"
    log_file="$log_dir/${BACKUP_FILE%.*}-$(stamp).log"

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ -x "$backup_path" ]]; then
            how="directly"
        else
            how="via bash (not executable)"
        fi
        echo "[DRY RUN] $name: would run $BACKUP_SCRIPT $how"
        echo "[DRY RUN] $name: would log to $log_file"
        if [[ ${#POST_RUN_ARGS[@]} -gt 0 ]]; then
            echo "[DRY RUN] $name: would run post-run script $POST_RUN_SCRIPT within $dir"
        fi
        continue
    fi

    if ! mkdir -p "$log_dir"; then
        echo "[$(now)] ERROR: $name: could not create log directory '$log_dir', skipping." >&2
        failed=$((failed + 1))
        failed_dirs+=("$name")
        continue
    fi

    echo "[$(now)] $name: running $BACKUP_SCRIPT (log: $log_file)"
    echo "=== [$(now)] START $backup_path ===" >>"$log_file"

    run_logged "$log_file" run_backup_command "$dir"
    rc=$?

    echo "=== [$(now)] END (exit code $rc) ===" >>"$log_file"
    if [[ $rc -ne 0 ]]; then
        msg="[$(now)] ERROR: $name: $BACKUP_SCRIPT failed with exit code $rc"
        echo "$msg" | tee -a "$log_file" >&2
    fi

    post_rc=0
    if [[ ${#POST_RUN_ARGS[@]} -gt 0 ]]; then
        echo "[$(now)] $name: running post-run script $POST_RUN_SCRIPT"
        run_logged "$log_file" run_post_run_command "$dir"
        post_rc=$?
    fi

    if [[ $post_rc -ne 0 ]]; then
        msg="[$(now)] ERROR: $name: post-run script $POST_RUN_SCRIPT failed with exit code $post_rc"
        echo "$msg" >&2
    fi

    if [[ $rc -eq 0 && $post_rc -eq 0 ]]; then
        echo "[$(now)] $name: completed successfully"
        succeeded=$((succeeded + 1))
    else
        failed=$((failed + 1))
        failed_dirs+=("$name")
    fi
done

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] Done. Found $found $BACKUP_SCRIPT file(s) under $BASE_DIR; nothing was run."
    services=""
    [[ $GOTIFY_ON -eq 1 ]] && services="gotify"
    [[ $NTFY_ON   -eq 1 ]] && services="${services:+$services, }ntfy"
    if [[ -n "$services" ]]; then
        echo "[DRY RUN] Would send a completion notification via: $services (notify.on: $NOTIFY_ON)"
    fi
    exit 0
fi

echo "[$(now)] Done. Found: $found, succeeded: $succeeded, failed: $failed"
if [[ $failed -gt 0 ]]; then
    echo "Failed: ${failed_dirs[*]}"
fi

# Send the completion notification
summary="Base: $BASE_DIR"$'\n'"Found: $found, succeeded: $succeeded, failed: $failed"
if [[ $failed -gt 0 ]]; then
    summary+=$'\n'"Failed: ${failed_dirs[*]}"
    notify "Backups on $HOST: $failed failed" "$summary" 1
else
    notify "Backups on $HOST: all OK" "$summary" 0
fi

# Always exit 0 so a failed backup never makes this wrapper fail.
# Change to 'exit $(( failed > 0 ))' if you want cron/monitoring to see failures.
exit 0
