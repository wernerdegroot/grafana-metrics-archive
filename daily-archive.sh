#!/bin/sh

# Schedule and run the archiver in a visible window on macOS.
#
# Running this script with no arguments installs a launchd LaunchAgent that
# fires every day at 09:55. If the laptop is asleep or powered off
# at that time, launchd runs the missed job as soon as it wakes.
#
# When the schedule fires, a new Terminal window pops up, counts down 5
# seconds (ignoring input), runs `docker compose up` with visible output, and
# stays open until you close it yourself.
#
# Usage:
#   ./daily-archive.sh            Schedule it (does nothing if already scheduled)
#   ./daily-archive.sh install    Same as no arguments
#   ./daily-archive.sh status     Show whether it is scheduled
#   ./daily-archive.sh run        Open the window now (for testing)
#   ./daily-archive.sh uninstall  Remove the schedule

set -eu


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Resolve our own absolute location so launchd can always find us, even if the
# job is triggered from a different working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"

LABEL="nl.wernerdegroot.grafana-metrics-archive.daily"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG="${HOME}/Library/Logs/grafana-metrics-archive.log"

# Seconds to wait in the visible window before running.
COUNTDOWN=5


# ---------------------------------------------------------------------------
# Scheduling helpers
# ---------------------------------------------------------------------------

is_loaded() {
    launchctl list "$LABEL" >/dev/null 2>&1
}

write_plist() {
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>${SCRIPT_PATH}</string>
        <string>--launch</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>55</integer>
    </dict>

    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF
}

ensure_scheduled() {
    if is_loaded; then
        echo "Already scheduled (label: ${LABEL})."
        echo "Runs daily at 09:55."
        return 0
    fi

    echo "Not scheduled yet. Installing the LaunchAgent..."
    write_plist
    launchctl load -w "$PLIST"

    echo
    echo "Scheduled successfully."
    echo "  Label: ${LABEL}"
    echo "  Plist: ${PLIST}"
    echo "  Runs daily at 09:55 (catches up on wake if missed)."
    echo
    echo "Test it now with: ${SCRIPT_PATH} run"
}

uninstall() {
    if is_loaded; then
        launchctl unload -w "$PLIST" || true
    fi
    if [ -f "$PLIST" ]; then
        rm -f "$PLIST"
        echo "Removed schedule (${LABEL})."
    else
        echo "Nothing to remove; ${LABEL} was not installed."
    fi
}

status() {
    if is_loaded; then
        echo "Scheduled: yes (${LABEL})"
        echo "Plist:     ${PLIST}"
        echo "Log:       ${LOG}"
    else
        echo "Scheduled: no"
        echo "Run '${SCRIPT_PATH}' to schedule it."
    fi
}


# ---------------------------------------------------------------------------
# Opening the visible window (triggered by launchd, or by 'run')
# ---------------------------------------------------------------------------

open_window() {
    # Open a new Terminal window and run ourselves in --windowed mode inside it.
    # Terminal loads the user's normal shell profile, so `docker` and friends
    # are on PATH there even though launchd's own environment is minimal.
    #
    # After the windowed command finishes, Terminal leaves the shell at a
    # prompt, so the window stays open until the user closes it.
    /usr/bin/osascript <<OSA_EOF
tell application "Terminal"
    activate
    do script "clear && cd \"${SCRIPT_DIR}\" && /bin/sh \"${SCRIPT_PATH}\" --windowed"
end tell
OSA_EOF
}


# ---------------------------------------------------------------------------
# The actual work, run inside the visible window
# ---------------------------------------------------------------------------

run_windowed() {
    cd "$SCRIPT_DIR"

    echo "==================================================================="
    echo " Grafana metrics archive"
    echo " $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==================================================================="
    echo

    # Visible wait that does not accept any user input.
    i="$COUNTDOWN"
    while [ "$i" -gt 0 ]; do
        printf '\rStarting in %d second(s)... ' "$i"
        sleep 1
        i=$((i - 1))
    done
    printf '\rStarting now.                 \n\n'

    # Run the archiver with fully visible output.
    docker compose up

    echo
    echo "==================================================================="
    echo " Finished. You can close this window."
    echo "==================================================================="
}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

case "${1:-install}" in
    install|"")
        ensure_scheduled
        ;;
    status)
        status
        ;;
    run|--launch)
        open_window
        ;;
    --windowed)
        run_windowed
        ;;
    uninstall)
        uninstall
        ;;
    *)
        echo "Usage: $0 [install|status|run|uninstall]" >&2
        exit 1
        ;;
esac
