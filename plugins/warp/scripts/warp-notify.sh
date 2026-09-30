#!/bin/bash
# Warp notification utility using OSC escape sequences.
# Usage: warp-notify.sh <title> <body>
#
# For structured Warp notifications, title should be "warp://cli-agent"
# and body should be a JSON string matching the cli-agent notification schema.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

# Only emit notifications when we've confirmed the Warp build can render them.
if ! should_use_structured; then
    exit 0
fi

TITLE="${1:-Notification}"
BODY="${2:-}"

write_notification() (
    [ -c "$1" ] || exit 1
    exec 3>"$1" || exit 1
    [ -t 3 ] || exit 1
    printf '\033]777;notify;%s;%s\007' "$TITLE" "$BODY" >&3
) 2>/dev/null

if write_notification /dev/tty; then
    exit 0
fi
write_named_terminal() {
    local terminal_path
    case "$1" in
        /dev/pts/*|/dev/tty*) terminal_path="$1" ;;
        pts/*|tty*) terminal_path="/dev/$1" ;;
        s[0-9]*) terminal_path="/dev/tty$1" ;;
        *) return 1 ;;
    esac
    write_notification "$terminal_path"
}

# Codex >= 0.155 detaches hooks with setsid and captures their stdout/stderr.
# The Codex ancestor still owns the terminal; open its device explicitly.
PID="$PPID"
for ((depth = 0; depth < 32; depth++)); do
    case "$PID" in
        ''|*[!0-9]*) break ;;
    esac
    [ "$PID" -gt 1 ] || break
    if [ -r "/proc/$PID/stat" ]; then
        PROCESS_STAT=$(<"/proc/$PID/stat")
        read -r _ PARENT_PID _ <<< "${PROCESS_STAT##*) }"
        for fd in 0 1 2; do
            TERMINAL=$(readlink "/proc/$PID/fd/$fd" 2>/dev/null) || continue
            if write_named_terminal "$TERMINAL"; then
                exit 0
            fi
        done
    else
        PROCESS_INFO=$(ps -p "$PID" -o ppid= -o tty= 2>/dev/null) || break
        read -r PARENT_PID TERMINAL <<< "$PROCESS_INFO"
        if write_named_terminal "$TERMINAL"; then
            exit 0
        fi
    fi
    PID="$PARENT_PID"
done

printf 'Warp notification skipped: no writable terminal found in the hook process ancestry.\n' >&2
exit 0
