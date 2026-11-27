#!/usr/bin/env bash
# ==============================================================================
# Author: 0xMetalee | https://windflame.org/?ref=TBMW#register
# Description: Stop a Claude Code tmux session and release unused sleep assertions.
# Usage: bash stop.sh [session-name] (default: claude-work)
# License: MIT
# ==============================================================================

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"

if [[ $# -gt 1 ]]; then
    echo "Usage: bash stop.sh [session-name] (default: claude-work)" >&2
    exit 2
fi
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: bash stop.sh [session-name] (default: claude-work)"
    exit 0
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "ERROR: This script requires macOS." >&2
    exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is required. Run bash setup.sh first." >&2
    exit 1
fi

RAW_SESSION="${1:-claude-work}"
if [[ "$RAW_SESSION" == *$'\n'* || "$RAW_SESSION" == *$'\r'* ]]; then
    echo "ERROR: Session names cannot contain newlines." >&2
    exit 1
fi
# Match watchdog.sh's existing name normalization and runner location.
SESSION_NAME=$(printf '%s' "$RAW_SESSION" | tr '.:/' '---')
LOG_DIR="$HOME/.claude/logs"
RUNNER_SCRIPT="$LOG_DIR/.runner_${SESSION_NAME}.sh"
mkdir -p "$LOG_DIR"
exec 9>"$LOG_DIR/.lifecycle.lock"
/usr/bin/lockf -t 10 9 || exit 1

list_sessions() {
    local result
    if result=$(LC_ALL=C tmux list-sessions -F '#{session_name}' 2>&1); then
        printf '%s\n' "$result"
    else
        case "$result" in
            "no server running on "*|"error connecting to "*" (No such file or directory)")
                return 0 ;;
            *)
                printf 'ERROR: Cannot inspect tmux sessions: %s\n' "$result" >&2
                return 1 ;;
        esac
    fi
}

SESSIONS=$(list_sessions)
if printf '%s\n' "$SESSIONS" | grep -Fxq -- "$SESSION_NAME"; then
    # Give the foreground task a chance to handle SIGINT before closing the session.
    tmux send-keys -t "=$SESSION_NAME:" C-c
    sleep 2
    if tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "=$SESSION_NAME"
    fi
    printf 'Stopped tmux session [%s].\n' "$SESSION_NAME"
else
    printf 'Session [%s] is already stopped.\n' "$SESSION_NAME"
fi

# Verify the stop succeeded before removing the runner or releasing assertions.
SESSIONS=$(list_sessions)
if printf '%s\n' "$SESSIONS" | grep -Fxq -- "$SESSION_NAME"; then
    echo "ERROR: Session is still running. Cleanup aborted." >&2
    exit 1
fi
rm -f -- "$RUNNER_SCRIPT"
printf 'Removed runner for [%s].\n' "$SESSION_NAME"

if [[ -n "$SESSIONS" ]]; then
    printf 'Keeping caffeinate for other tmux sessions:\n%s\n' "$SESSIONS"
    exit 0
fi

# A user may also have tmux running on a different socket. Preserve shared power
# assertions in that case, even though the selected server has no sessions left.
USER_ID=$(id -u)
if pgrep -u "$USER_ID" -x tmux >/dev/null 2>&1; then
    echo "Keeping caffeinate because another tmux process is still running."
    exit 0
elif [[ $? -ne 1 ]]; then
    echo "ERROR: Cannot inspect tmux processes. Keeping caffeinate." >&2
    exit 1
fi

# Only the current user's exact watchdog-style invocation is eligible for cleanup.
if PIDS=$(pgrep -u "$USER_ID" -f '(^|/)caffeinate -disu$'); then
    while IFS= read -r pid; do
        if ! kill -TERM "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
            printf 'ERROR: Could not stop caffeinate PID %s.\n' "$pid" >&2
            exit 1
        fi
    done <<< "$PIDS"
    for _ in {1..50}; do
        if ! pgrep -u "$USER_ID" -f '(^|/)caffeinate -disu$' >/dev/null 2>&1; then
            echo "Stopped caffeinate and released its sleep assertions."
            exit 0
        fi
        sleep 0.1
    done
    echo "ERROR: caffeinate is still running. Check Activity Monitor." >&2
    exit 1
elif [[ $? -ne 1 ]]; then
    echo "ERROR: Cannot inspect caffeinate processes." >&2
    exit 1
fi
echo "No watchdog caffeinate process is running."
