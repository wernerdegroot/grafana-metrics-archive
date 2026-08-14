#!/bin/sh

# Exit on errors and variables that have not been initialized.
set -eu


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TSDB_PATH="/data/tsdb"
STATE_DIR="/data/state"
BACKUP_PATH="/data/backups"

CHECKPOINT_FILE="${STATE_DIR}/checkpoint"

REMOTE_READ_PATH="/prometheus/api/v1/read"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

mkdir -p "$TSDB_PATH" "$STATE_DIR" "$BACKUP_PATH"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

timestamp() {
    # GNU date is available inside our Linux container.
    date -u --date="@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

write_checkpoint() {
    # Write to a temporary file first, then atomically rename it.
    printf '%s\n' "$1" > "${CHECKPOINT_FILE}.tmp"
    mv "${CHECKPOINT_FILE}.tmp" "$CHECKPOINT_FILE"
}


# ---------------------------------------------------------------------------
# Initialize the checkpoint on the first run
# ---------------------------------------------------------------------------

if [ ! -f "$CHECKPOINT_FILE" ]; then
    now="$(date +%s)"
    start=$((now - INITIAL_LOOKBACK_SECONDS))

    echo "No checkpoint found."
    echo "Starting at $(timestamp "$start")"

    write_checkpoint "$start"
fi


# ---------------------------------------------------------------------------
# Back up the current archive before changing anything
# ---------------------------------------------------------------------------

backup_time="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
backup_dir="${BACKUP_PATH}/${backup_time}"

echo
echo "Creating backup:"
echo "  $backup_dir"

mkdir -p "${backup_dir}/tsdb" "${backup_dir}/state"

cp -a "${TSDB_PATH}/." "${backup_dir}/tsdb/"
cp -a "${STATE_DIR}/." "${backup_dir}/state/"

echo "Backup completed."


# ---------------------------------------------------------------------------
# Determine the fixed target for this run
# ---------------------------------------------------------------------------

from="$(cat "$CHECKPOINT_FILE")"

# Capture "now" once.
#
# The target for this entire run is now minus 10 minutes.
# It does not move while the script is running.
now="$(date +%s)"
target=$((now - LAG_SECONDS))

echo
echo "Current checkpoint: $(timestamp "$from")"
echo "Target:             $(timestamp "$target")"

if [ "$from" -ge "$target" ]; then
    echo
    echo "Archive is already caught up."
    exit 0
fi


# ---------------------------------------------------------------------------
# Export everything from the checkpoint up to the target
# ---------------------------------------------------------------------------

while [ "$from" -lt "$target" ]; do

    # Export at most WINDOW_SECONDS at a time.
    to=$((from + WINDOW_SECONDS))

    if [ "$to" -gt "$target" ]; then
        to="$target"
    fi

    from_text="$(timestamp "$from")"
    to_text="$(timestamp "$to")"

    echo
    echo "Exporting:"
    echo "  $from_text"
    echo "  -> $to_text"

    # Capture mimirtool's output while preserving its exit status.
    #
    # Using this if-form also means we don't need to temporarily disable
    # `set -e`.
    if output="$(
        mimirtool remote-read export \
            --selector "$SELECTOR" \
            --remote-read-path "$REMOTE_READ_PATH" \
            --from "$from_text" \
            --to "$to_text" \
            --tsdb-path "$TSDB_PATH" \
            2>&1
    )"; then
        exit_code=0
    else
        exit_code=$?
    fi

    # Show mimirtool's output so the run can be inspected manually.
    printf '%s\n' "$output"

    # Never advance the checkpoint after a failed export.
    if [ "$exit_code" -ne 0 ]; then
        echo >&2
        echo >&2 "Export failed."
        echo >&2 "Checkpoint remains at $from_text."
        exit 1
    fi

    # We've seen mimirtool 3.1.4 print this error prefix while returning
    # success, so check the output as an additional safeguard.
    if printf '%s\n' "$output" | grep -Fq 'mimirtool: error:'; then
        echo >&2
        echo >&2 "mimirtool reported an error."
        echo >&2 "Checkpoint remains at $from_text."
        exit 1
    fi

    # Only advance the checkpoint after a successful export.
    write_checkpoint "$to"
    from="$to"

    echo "Checkpoint advanced to $to_text."
done


# ---------------------------------------------------------------------------
# Finished successfully
# ---------------------------------------------------------------------------

echo
echo "Archive caught up successfully."
echo "Latest archived point: $(timestamp "$target")"

