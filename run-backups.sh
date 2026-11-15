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

# ---- Defaults (override with command line options) --------------------------
BASE_DIR="/docker"
BACKUP_SCRIPT="backup.sh"
LOG_SUBDIR="backup_logs"
DRY_RUN=0   # 1 = only show what would be done (same as -n)
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/run-backups/config.yaml"
# -----------------------------------------------------------------------------

CONFIG_EXPLICIT=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [-d base_dir] [-s script_name] [-l log_subdir]
                        [-c config_file] [-n] [-h]

  -d DIR     Base directory containing the subdirectories to scan
             (default: $BASE_DIR)
  -s NAME    Name of the backup script to look for in each subdirectory
             (default: $BACKUP_SCRIPT)
  -l NAME    Name of the log subdirectory created inside each subdirectory
             (default: $LOG_SUBDIR)
  -c FILE    YAML file with Gotify/ntfy notification settings
             (default: $CONFIG_FILE)
  -n         Dry run: show what would be done, but don't run any backup
             scripts, create log files, or send notifications
  -h         Show this help
USAGE
}

while getopts ":d:s:l:c:nh" opt; do
    case "$opt" in
        d) BASE_DIR="$OPTARG" ;;
        s) BACKUP_SCRIPT="$OPTARG" ;;
        l) LOG_SUBDIR="$OPTARG" ;;
        c) CONFIG_FILE="$OPTARG"; CONFIG_EXPLICIT=1 ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage >&2; exit 2 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done

BASE_DIR="${BASE_DIR%/}"

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

    # The file holds tokens/passwords, so warn if others can read it
    local perm
    perm="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$perm" && ! "$perm" =~ 00$ ]]; then
        echo "WARNING: $CONFIG_FILE is accessible by other users (mode $perm); consider: chmod 600 '$CONFIG_FILE'" >&2
    fi

    local v
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

# ---- Main -------------------------------------------------------------------

load_config
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

found=0
succeeded=0
failed=0
failed_dirs=()

for dir in "$BASE_DIR"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"

    # Skip directories without the backup script
    [[ -f "$dir/$BACKUP_SCRIPT" ]] || continue

    found=$((found + 1))
    log_dir="$dir/$LOG_SUBDIR"
    log_file="$log_dir/${BACKUP_SCRIPT%.*}-$(stamp).log"

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ -x "$dir/$BACKUP_SCRIPT" ]]; then
            how="directly"
        else
            how="via bash (not executable)"
        fi
        echo "[DRY RUN] $name: would run $dir/$BACKUP_SCRIPT $how"
        echo "[DRY RUN] $name: would log to $log_file"
        continue
    fi

    if ! mkdir -p "$log_dir"; then
        echo "[$(now)] ERROR: $name: could not create log directory '$log_dir', skipping." >&2
        failed=$((failed + 1))
        failed_dirs+=("$name")
        continue
    fi

    echo "[$(now)] $name: running $BACKUP_SCRIPT (log: $log_file)"
    echo "=== [$(now)] START $dir/$BACKUP_SCRIPT ===" >>"$log_file"

    # Run inside a subshell so the cd doesn't leak and so a failing script
    # can't affect this one. Use the script directly if it's executable,
    # otherwise fall back to bash.
    (
        cd "$dir" || exit 1
        if [[ -x "./$BACKUP_SCRIPT" ]]; then
            "./$BACKUP_SCRIPT"
        else
            bash "./$BACKUP_SCRIPT"
        fi
    ) >>"$log_file" 2>&1
    rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "=== [$(now)] END (exit code 0) ===" >>"$log_file"
        echo "[$(now)] $name: completed successfully"
        succeeded=$((succeeded + 1))
    else
        msg="[$(now)] ERROR: $name: $BACKUP_SCRIPT failed with exit code $rc"
        echo "$msg" | tee -a "$log_file" >&2
        echo "=== [$(now)] END (exit code $rc) ===" >>"$log_file"
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
