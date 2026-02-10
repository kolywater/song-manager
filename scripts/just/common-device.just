# common-device.just - Device utility recipes
#
# This file contains utility recipes for working with devices.
# Import this file in your project Justfile.

# ══════════════════════════════════════════════════════════════════════════════
# DEVICE UTILITIES
# ══════════════════════════════════════════════════════════════════════════════

# Get current timestamp from device (for manual crash tracking)
[group('device')]
get-timestamp device:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"
    export _PROJECT_NAME="{{_project_name_upper}}"

    # Resolve device to SSH hostname (quiet - only output timestamp)
    resolve_ssh_target_quiet "{{device}}" || true
    if [[ -z "$SSH_TARGET" ]]; then
        echo "Error: Device '{{device}}' is ambiguous" >&2
        exit 1
    fi

    # Just output the timestamp (no extra text for easy capture)
    run_device_ssh "$SSH_TARGET" 'date +%Y-%m-%d-%H%M%S'

# Check for crashes on device
[group('device')]
check-crashes device binary="" since="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"
    export _PROJECT_NAME="{{_project_name_upper}}"

    # Resolve device to SSH hostname
    resolve_ssh_target "{{device}}" || exit 1

    echo "Checking for crashes on $SSH_TARGET..."
    if [[ -n "{{since}}" ]]; then
        echo "Filtering crashes since: {{since}}"
    fi

    # Resolve binary alias from workflow config (case-insensitive)
    binary="{{binary}}"
    if [[ -n "$binary" ]]; then
        binary_lower=$(echo "$binary" | tr '[:upper:]' '[:lower:]')
        workflow_config="{{_workflow_platforms}}"
        resolved=$(echo "$workflow_config" | grep -i "^${binary_lower}:" | cut -d: -f2 | head -1 || true)
        if [[ -n "$resolved" ]]; then
            binary="$resolved"
            echo "Resolved binary alias: {{binary}} -> $binary"
        fi
    fi
    echo ""

    # Check all configured binaries if no specific binary requested
    if [[ -z "$binary" ]]; then
        echo "Recent crashes (configured binaries):"
        echo ""
        for bin in {{_crash_binaries}}; do
            echo "=== $bin ==="

            # Get all crash files for this binary
            crash_files=$(run_device_ssh "$SSH_TARGET" "ls -1 /var/mobile/Library/Logs/CrashReporter/${bin}*.ips 2>/dev/null" || true)

            if [[ -z "$crash_files" ]]; then
                echo "  No crashes found"
            elif [[ -n "{{since}}" ]]; then
                # Filter by timestamp
                filtered=""
                while IFS= read -r crash_file; do
                    if [[ -n "$crash_file" ]]; then
                        crash_timestamp=$(basename "$crash_file" .ips | sed "s/^${bin}-//")
                        if [[ "$crash_timestamp" > "{{since}}" ]]; then
                            filtered+="$crash_file"$'\n'
                        fi
                    fi
                done <<< "$crash_files"

                if [[ -z "$filtered" ]]; then
                    echo "  No crashes since {{since}}"
                else
                    echo "$filtered" | run_device_ssh "$SSH_TARGET" "xargs ls -la" | tail -3
                fi
            else
                # No timestamp filter, show last 3
                echo "$crash_files" | tail -3 | while read -r f; do
                    run_device_ssh "$SSH_TARGET" "ls -la $f" || true
                done
            fi
            echo ""
        done
    else
        echo "Recent $binary crashes:"

        # Get all crash files for this binary
        crash_files=$(run_device_ssh "$SSH_TARGET" "ls -1 /var/mobile/Library/Logs/CrashReporter/${binary}*.ips 2>/dev/null" || true)

        if [[ -z "$crash_files" ]]; then
            echo "  No crashes found"
        elif [[ -n "{{since}}" ]]; then
            # Filter by timestamp
            filtered=""
            while IFS= read -r crash_file; do
                if [[ -n "$crash_file" ]]; then
                    crash_timestamp=$(basename "$crash_file" .ips | sed "s/^${binary}-//")
                    if [[ "$crash_timestamp" > "{{since}}" ]]; then
                        filtered+="$crash_file"$'\n'
                    fi
                fi
            done <<< "$crash_files"

            if [[ -z "$filtered" ]]; then
                echo "  No crashes since {{since}}"
            else
                echo "$filtered" | while IFS= read -r f; do
                    if [[ -n "$f" ]]; then
                        run_device_ssh "$SSH_TARGET" "ls -la $f" || true
                    fi
                done
            fi
        else
            # No timestamp filter, show last 3
            echo "$crash_files" | tail -3 | while read -r f; do
                run_device_ssh "$SSH_TARGET" "ls -la $f" || true
            done
        fi
    fi
