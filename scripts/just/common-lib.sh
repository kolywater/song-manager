#!/usr/bin/env bash
#
# common-lib.sh - Helper functions for Justfile build system
#
# Source this file in Just recipes via the _lib_sh variable:
#   source "{{_lib_sh}}"
#

# ══════════════════════════════════════════════════════════════════════════════
# BUILD SUBDIRECTORY
# ══════════════════════════════════════════════════════════════════════════════

# Get build subdirectory for worktree/session isolation
# Priority:
#   1. Explicit BUILD_SUBDIR environment variable
#   2. Git worktree hash (stable per worktree directory)
#   3. Claude Code session port (fallback for non-git contexts)
#   4. Empty (no subdirectory)
get_build_subdir() {
    if [[ -n "${BUILD_SUBDIR:-}" ]]; then
        echo "$BUILD_SUBDIR"
        return
    fi

    # Try git worktree root for stable hash
    local worktree_root
    worktree_root=$(git rev-parse --show-toplevel 2>/dev/null) || true

    if [[ -n "$worktree_root" ]]; then
        # Hash the worktree path (12 hex chars)
        echo -n "$worktree_root" | shasum -a 256 | head -c 12
        return
    fi

    # Fall back to Claude Code session port
    if [[ -n "${CLAUDECODE:-}" ]] && [[ -n "${APPLE_CLAUDE_CODE_PROXY_PORT:-}" ]]; then
        echo "${APPLE_CLAUDE_CODE_PROXY_PORT}"
        return
    fi

    # Default: no subdirectory
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SANDBOX DETECTION
# ══════════════════════════════════════════════════════════════════════════════

# Check if running inside a sandbox
is_sandboxed() {
    ! sandbox-exec -p '(version 1)(allow default)' /bin/echo "test" &>/dev/null
}

# Check if SSH is available (can we actually make SSH connections?)
is_ssh_blocked() {
    # Try to run ssh --help (or version) to see if the binary is accessible
    # If we get "SANDBOX VIOLATION" in stdout/stderr, SSH is blocked
    local output
    output=$(ssh -V 2>&1 || true)

    # Check for sandbox-related errors from Claude Code proxy
    [[ "$output" == *"SANDBOX VIOLATION"* ]]
}

# Warn if running in sandbox environment where SSH is blocked
# Args: $1 = operation name (e.g., "install")
warn_if_sandboxed() {
    local operation="${1:-operation}"

    # First check if SSH is actually blocked
    if is_ssh_blocked; then
        cat >&2 <<EOF

WARNING: SSH BLOCKED - $operation will fail

SSH/SCP operations are blocked by the sandbox.

To fix, run this in Terminal (outside Claude Code):
  just install-allowlist

Or run directly in Terminal:
  just $operation ...

EOF
    elif is_sandboxed && [[ -n "${CLAUDECODE:-}" ]]; then
        # just is sandboxed but SSH works - suggest unsandboxing just
        local proxy_url="http://localhost:${APPLE_CLAUDE_CODE_PROXY_PORT:-5420}"
        cat >&2 <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  🛑 SANDBOX ERROR - YOU SHOULD HAVE STOPPED                                  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Claude: STOP. Do not proceed until this is resolved.                        ║
║                                                                              ║
║  'just' is running inside a sandbox.                                         ║
║  Mysterious errors will occur, including (but not limited to):               ║
║    - ObservationMacros.ObservableMacro build errors                          ║
║    - swift-plugin-server malformed responses                                 ║
║                                                                              ║
║  ACTION REQUIRED - Choose one:                                               ║
║                                                                              ║
║    1. Ask the user to run in Terminal (outside Claude Code):                 ║
║         just install-allowlist                                               ║
║                                                                              ║
║    2. Direct user to: $proxy_url
║         Settings > Tools > Add 'just' to allowlist                           ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
    fi
    # If neither blocked nor sandboxed, no warning needed
}

# ══════════════════════════════════════════════════════════════════════════════
# SSH/SCP HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# Common SSH options for device connections
# These options ensure non-interactive, quiet operation suitable for automation
_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Run SSH command on a device
# Args: $1 = hostname, $@ = command to run
# Requires: _PROJECT_NAME environment variable (set by Justfile)
run_device_ssh() {
    local host="$1"
    shift
    env "JUST_${_PROJECT_NAME:-TAMALE}=1" ssh $_SSH_OPTS "root@$host" "$@"
}

# Run SSH command on a device with connection timeout
# Args: $1 = hostname, $@ = command to run
# Requires: _PROJECT_NAME environment variable (set by Justfile)
run_device_ssh_with_timeout() {
    local host="$1"
    shift
    env "JUST_${_PROJECT_NAME:-TAMALE}=1" ssh $_SSH_OPTS -o ConnectTimeout=10 -o ConnectionAttempts=1 "root@$host" "$@"
}

# Copy file to device via SCP
# Args: $1 = local path, $2 = hostname, $3 = remote path
# Requires: _PROJECT_NAME environment variable (set by Justfile)
run_device_scp() {
    local local_path="$1"
    local host="$2"
    local remote_path="$3"
    env "JUST_${_PROJECT_NAME:-TAMALE}=1" scp $_SSH_OPTS "$local_path" "root@$host:$remote_path"
}

# Copy file from device via SCP
# Args: $1 = hostname, $2 = remote path, $3 = local path
# Requires: _PROJECT_NAME environment variable (set by Justfile)
run_device_scp_from() {
    local host="$1"
    local remote_path="$2"
    local local_path="$3"
    env "JUST_${_PROJECT_NAME:-TAMALE}=1" scp $_SSH_OPTS "root@$host:$remote_path" "$local_path"
}

# Resolve device name to SSH target hostname
# This is the common pattern for resolving a device before SSH operations.
# Args: $1 = device name or search pattern
# Output: Sets SSH_TARGET variable, prints status messages
# Returns: 0 = success, 1 = exit requested (ambiguous or error printed)
resolve_ssh_target() {
    local device="$1"
    local result
    local ret=0

    result=$(resolve_device_hostname "$device") || ret=$?

    case $ret in
        0)
            SSH_TARGET="$result"
            echo "Resolved device '$device' -> SSH hostname: $SSH_TARGET"
            return 0
            ;;
        1)
            SSH_TARGET="$device"
            echo "Using '$device' as SSH hostname (not found in device list)"
            return 0
            ;;
        2)
            local count
            count=$(echo "$result" | head -1)
            echo "Error: Device '$device' is ambiguous ($count matches)"
            echo "$result" | tail -n +2
            return 1
            ;;
    esac
}

# Resolve device name to SSH target (quiet version, no output)
# Args: $1 = device name or search pattern
# Output: Sets SSH_TARGET variable (no messages printed)
# Returns: 0 = success, 1 = not found (uses input as hostname), 2 = ambiguous
resolve_ssh_target_quiet() {
    local device="$1"
    local result
    local ret=0

    result=$(resolve_device_hostname "$device") || ret=$?

    case $ret in
        0)
            SSH_TARGET="$result"
            return 0
            ;;
        1)
            SSH_TARGET="$device"
            return 1
            ;;
        2)
            SSH_TARGET=""
            return 2
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# DEVICE RESOLUTION
# ══════════════════════════════════════════════════════════════════════════════

# Filter for usable devices: available (paired/unpaired) or connected
# Note: devicectl --columns with comma-separated values is broken (rdar://167589553)
DEVICE_STATE_FILTER='State beginswith "available" OR State == "connected"'

# ──────────────────────────────────────────────────────────────────────────────
# Column Parsing Infrastructure
# ──────────────────────────────────────────────────────────────────────────────
#
# devicectl output format:
#   Line 1: Header row with column names
#   Line 2: Underline row with dashes (----) defining column widths
#   Line 3+: Data rows with fixed-width columns
#
# Columns are separated by 3+ spaces. The underline row tells us exact boundaries.
# This handles device names with spaces (e.g., "Sunniva's iPhone", "Apple Watch").
#
# The parser dynamically determines column order from the header row, making it
# robust to devicectl reordering columns in future versions.
#
# Testing: Set DEVICECTL_MOCK_OUTPUT to use mock data instead of running devicectl.
# ──────────────────────────────────────────────────────────────────────────────

# AWK script for robust column parsing
# This parses the underline row (line 2) to determine column boundaries,
# then extracts columns from data rows using those boundaries.
# It also reads the header row to map column names to indices.
#
# After NR > 2, the following are available:
#   - col_val[i]: value of column i (1-indexed by position)
#   - col_by_name["Name"]: value of the "Name" column
#   - col_by_name["Model"]: value of the "Model" column, etc.
#
# The script handles:
#   - Device names with spaces and apostrophes
#   - Column reordering by devicectl (uses header row to find column indices)
#   - Variable column widths
_AWK_COLUMN_PARSER='
    # Trim trailing whitespace from a string
    function rtrim(s) {
        sub(/[[:space:]]+$/, "", s)
        return s
    }

    # Parse header row to extract column names at their positions
    NR == 1 {
        header_line = $0
        next
    }

    # Parse underline row to find column boundaries
    # Sets col_start[i] and col_end[i] for each column
    # Also extracts column names from header_line using the same boundaries
    NR == 2 {
        n = 0
        in_dash = 0
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "-") {
                if (!in_dash) {
                    n++
                    col_start[n] = i
                    in_dash = 1
                }
            } else {
                if (in_dash) {
                    col_end[n] = i - 1
                    in_dash = 0
                }
            }
        }
        # Handle last column (may extend to end of line)
        if (in_dash) {
            col_end[n] = length($0)
        }
        num_cols = n

        # Extract column names from header line using the boundaries
        for (i = 1; i <= num_cols; i++) {
            col_len = col_end[i] - col_start[i] + 1
            col_name[i] = rtrim(substr(header_line, col_start[i], col_len))
            col_index[col_name[i]] = i
        }
        next
    }

    # Process data rows
    NR > 2 {
        # Extract each column value using the boundaries from line 2
        for (i = 1; i <= num_cols; i++) {
            col_len = col_end[i] - col_start[i] + 1
            col_val[i] = rtrim(substr($0, col_start[i], col_len))
            # Also populate col_by_name for named access
            col_by_name[col_name[i]] = col_val[i]
        }
    }
'

# Get devicectl output, optionally using mock data for testing
# Args: $@ = devicectl arguments (e.g., "--columns Name --columns Model")
# Output: devicectl output or mock data
_get_devicectl_output() {
    if [[ -n "${DEVICECTL_MOCK_OUTPUT:-}" ]]; then
        echo "$DEVICECTL_MOCK_OUTPUT"
    else
        xcrun devicectl list devices "$@" 2>/dev/null || true
    fi
}

# Resolve device name to UDID
# Output: UDID on stdout
# Returns: 0 = found, 1 = not found, 2 = ambiguous
resolve_device_id() {
    local device_name="$1"
    local matches

    # Use fixed columns for predictable parsing: Name, Model, UDID
    # This allows "Air" to match "iPhone" with model "iPhone Air (D23AP)"
    # and also allows passing a UDID directly
    matches=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' --columns 'UDID' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$device_name" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = tolower(col_by_name["Name"])
                model = tolower(col_by_name["Model"])
                udid = tolower(col_by_name["UDID"])
                pattern_lower = tolower(pattern)
                # UDID exact match has highest priority, then name/model substring match
                if (udid == pattern_lower || index(name, pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print col_by_name["UDID"]
                }
            }
        ')

    if [[ -z "$matches" ]]; then
        return 1  # Not found
    fi

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')

    if [[ "$count" -eq 1 ]]; then
        echo "$matches"
        return 0
    fi

    return 2  # Ambiguous
}

# Resolve device name to SSH hostname (searches usable devices - available or connected)
# Output: device hostname on first line
# Returns: 0 = found, 1 = not found, 2 = ambiguous (count on line 1, table on rest)
resolve_device_hostname() {
    local search_pattern="$1"
    local matches

    # Use fixed columns: Name, Hostname, Model, UDID
    # devicectl outputs columns in the order we request them
    matches=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Hostname' --columns 'Model' --columns 'UDID' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = tolower(col_by_name["Name"])
                hostname = col_by_name["Hostname"]
                model = tolower(col_by_name["Model"])
                udid = tolower(col_by_name["UDID"])
                pattern_lower = tolower(pattern)
                # UDID exact match has highest priority, then name/model substring match
                if (udid == pattern_lower || index(name, pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print hostname
                }
            }
        ')

    if [[ -z "$matches" ]]; then
        return 1  # Not found
    fi

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')

    if [[ "$count" -eq 1 ]]; then
        echo "$matches"
        return 0
    fi

    # Multiple matches - return count and formatted table
    echo "$count"
    echo ""
    printf "  %-20s %-35s %s\n" "Name" "Hostname" "Model"
    printf "  %-20s %-35s %s\n" "----" "--------" "-----"

    # Re-fetch with full info for display
    _get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Hostname' --columns 'Model' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                name = col_by_name["Name"]
                hostname = col_by_name["Hostname"]
                model = col_by_name["Model"]
                name_lower = tolower(name)
                model_lower = tolower(model)
                pattern_lower = tolower(pattern)
                if (index(name_lower, pattern_lower) > 0 || index(model_lower, pattern_lower) > 0) {
                    printf "  %-20s %-35s %s\n", name, hostname, model
                }
            }
        '
    echo ""
    return 2
}

# Get device platform from devicectl (searches usable devices - available or connected)
# Args: $1 = device search pattern
# Output: platform name (iOS, macOS, visionOS, etc.)
# Returns: 0 = found, 1 = not found
get_device_platform() {
    local search_pattern="$1"
    local platform

    # Use fixed columns: Name, Model, UDID, Platform
    platform=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' --columns 'UDID' --columns 'Platform' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = tolower(col_by_name["Name"])
                model = tolower(col_by_name["Model"])
                udid = tolower(col_by_name["UDID"])
                platform = col_by_name["Platform"]
                pattern_lower = tolower(pattern)
                # UDID exact match has highest priority, then name/model substring match
                if (udid == pattern_lower || index(name, pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print platform
                    exit
                }
            }
        ')

    if [[ -z "$platform" ]]; then
        return 1
    fi

    echo "$platform"
    return 0
}

# Get device model from device name/pattern
# Output: model name (e.g., "iPhone 16 Plus (D48AP)", "VPHONE400AP")
# Returns: 0 = found, 1 = not found
get_device_model() {
    local search_pattern="$1"
    local model

    # Use fixed columns: Name, Model, UDID
    model=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' --columns 'UDID' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = tolower(col_by_name["Name"])
                model = col_by_name["Model"]
                udid = tolower(col_by_name["UDID"])
                pattern_lower = tolower(pattern)
                # UDID exact match has highest priority, then name/model substring match
                if (udid == pattern_lower || index(name, pattern_lower) > 0 || index(tolower(model), pattern_lower) > 0) {
                    print model
                    exit
                }
            }
        ')

    if [[ -z "$model" ]]; then
        return 1
    fi

    echo "$model"
    return 0
}

# Resolve device name to device name (searches all devices, not just available)
# Output: device name on first line
# Returns: 0 = found, 1 = not found, 2 = ambiguous (count on line 1, matches on rest)
resolve_device_name() {
    local search_pattern="$1"
    local matches

    # Use fixed columns: Name, Model
    # Note: This function searches ALL devices, not just available ones
    matches=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = col_by_name["Name"]
                model = tolower(col_by_name["Model"])
                pattern_lower = tolower(pattern)
                if (index(tolower(name), pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print name
                }
            }
        ')

    if [[ -z "$matches" ]]; then
        return 1  # Not found
    fi

    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')

    if [[ "$count" -eq 1 ]]; then
        echo "$matches"
        return 0
    fi

    # Multiple matches - re-fetch with full info for display
    local full_matches
    full_matches=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            # Pass through header rows
            NR <= 2 { print; next }
            NR > 2 {
                name = col_by_name["Name"]
                model = tolower(col_by_name["Model"])
                pattern_lower = tolower(pattern)
                if (index(tolower(name), pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print
                }
            }
        ')
    echo "$count"
    echo "$full_matches"
    return 2
}

# Validate and resolve device, sets DEVICE_ID
# Args: $1 = device name or ID
# Sets: DEVICE_ID (exported)
# Returns: 0 on success, exits on failure
validate_device() {
    local device="$1"

    # No device specified
    if [[ -z "$device" ]]; then
        return 0
    fi

    local resolved_id
    local ret=0
    resolved_id=$(resolve_device_id "$device") || ret=$?

    case $ret in
        0)
            export DEVICE_ID="$resolved_id"
            # Skip message if user already provided exact UDID
            if [[ "$device" == "$resolved_id" ]]; then
                :  # Silent
            else
                # Get full device info to show which field matched
                local device_info
                device_info=$(_get_devicectl_output --hide-default-columns \
                    --columns 'Name' --columns 'Model' --columns 'UDID' \
                    --filter "$DEVICE_STATE_FILTER" \
                    | awk -v udid="$resolved_id" -v pattern="$device" '
                        '"$_AWK_COLUMN_PARSER"'
                        NR > 2 && col_by_name["UDID"] == udid {
                            name = col_by_name["Name"]
                            model = col_by_name["Model"]
                            pattern_lower = tolower(pattern)

                            # Determine which field(s) matched
                            name_match = (index(tolower(name), pattern_lower) > 0)
                            model_match = (index(tolower(model), pattern_lower) > 0)

                            # Output: name|model|matched_field|matched_value
                            if (name_match && model_match) {
                                print name "|" model "|Name+Model|" name " / " model
                            } else if (name_match) {
                                print name "|" model "|Name|" name
                            } else if (model_match) {
                                print name "|" model "|Model|" model
                            } else {
                                print name "|" model "||"
                            }
                        }
                    ')

                local full_name full_model matched_field matched_value
                full_name=$(echo "$device_info" | cut -d'|' -f1)
                full_model=$(echo "$device_info" | cut -d'|' -f2)
                matched_field=$(echo "$device_info" | cut -d'|' -f3)
                matched_value=$(echo "$device_info" | cut -d'|' -f4)

                if [[ -n "$matched_field" && "$device" != "$full_name" ]]; then
                    echo "Note: '$device' matched $matched_field '$matched_value' ($DEVICE_ID)"
                    echo "      Use the full name or UDID for unambiguous targeting."
                else
                    echo "Using device: $DEVICE_ID"
                fi
            fi
            ;;
        1)
            echo ""
            echo "*** Error: Device '$device' not found ***"
            echo ""
            echo "Available devices:"
            _get_devicectl_output --hide-default-columns \
                --columns 'Name' --columns 'Hostname' --columns 'UDID' --columns 'Model' --columns 'Platform' --columns 'OS Version' \
                --filter "$DEVICE_STATE_FILTER" || echo "  (no devices found)"
            echo ""
            echo "Tip: Use UDID for exact match: just test <UDID>"
            exit 1
            ;;
        2)
            # Re-fetch matches using same logic as resolve_device_id
            local matches
            matches=$(_get_devicectl_output --hide-default-columns \
                --columns 'Name' --columns 'Model' --columns 'UDID' \
                --filter "$DEVICE_STATE_FILTER" \
                | awk -v pattern="$device" '
                    '"$_AWK_COLUMN_PARSER"'
                    # Pass through header rows
                    NR <= 2 { print; next }
                    NR > 2 {
                        name = tolower(col_by_name["Name"])
                        model = tolower(col_by_name["Model"])
                        pattern_lower = tolower(pattern)
                        if (index(name, pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                            print
                        }
                    }
                ')
            local count
            count=$(echo "$matches" | grep -v '^$' | tail -n +3 | wc -l | tr -d ' ')
            echo ""
            echo "*** Error: Device '$device' is ambiguous ($count matches) ***"
            echo ""
            echo "Matching devices:"
            echo "$matches"
            echo ""
            echo "Available devices:"
            _get_devicectl_output --hide-default-columns \
                --columns 'Name' --columns 'Hostname' --columns 'UDID' --columns 'Model' --columns 'Platform' --columns 'OS Version' \
                --filter "$DEVICE_STATE_FILTER" || echo "  (no devices found)"
            echo ""
            echo "Tip: Use UDID for exact match (hostname or unique model substring also work)"
            exit 1
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# SDK HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# NOTE: These use case statements instead of associative arrays (declare -A)
# for compatibility with bash 3.2.57 (macOS system bash).

# Get device OS version (build number) from devicectl
# Args: $1 = device search pattern
# Output: OS build version (e.g., "24A248a")
# Returns: 0 = found, 1 = not found
get_device_os_version() {
    local search_pattern="$1"
    local os_version

    # Use fixed columns: Name, Model, UDID, OS Version
    os_version=$(_get_devicectl_output --hide-default-columns \
        --columns 'Name' --columns 'Model' --columns 'UDID' --columns 'OS Version' \
        --filter "$DEVICE_STATE_FILTER" \
        | awk -v pattern="$search_pattern" '
            '"$_AWK_COLUMN_PARSER"'
            NR > 2 {
                # Use named column access for robustness to column reordering
                name = tolower(col_by_name["Name"])
                model = tolower(col_by_name["Model"])
                udid = tolower(col_by_name["UDID"])
                os_ver = col_by_name["OS Version"]
                pattern_lower = tolower(pattern)
                # UDID exact match has highest priority, then name/model substring match
                if (udid == pattern_lower || index(name, pattern_lower) > 0 || index(model, pattern_lower) > 0) {
                    print os_ver
                    exit
                }
            }
        ')

    if [[ -z "$os_version" ]]; then
        return 1
    fi

    echo "$os_version"
    return 0
}

# Compare two OS build versions (e.g., "24A246" vs "24A248a")
# Format: XXYZZZ where XX=Darwin version, Y=minor letter, ZZZ=build number
# Args: $1 = version1, $2 = version2
# Output: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
# Returns: 0 always (result is in stdout)
compare_build_versions() {
    local v1="$1"
    local v2="$2"

    # Parse version components using regex
    # Format: 2 digits (darwin), 1 letter (minor), rest is build number
    local d1 m1 b1 d2 m2 b2

    # Extract components (darwin version, minor letter, build)
    d1=$(echo "$v1" | sed 's/^\([0-9]*\).*/\1/')
    m1=$(echo "$v1" | sed 's/^[0-9]*\([A-Z]\).*/\1/')
    b1=$(echo "$v1" | sed 's/^[0-9]*[A-Z]//')

    d2=$(echo "$v2" | sed 's/^\([0-9]*\).*/\1/')
    m2=$(echo "$v2" | sed 's/^[0-9]*\([A-Z]\).*/\1/')
    b2=$(echo "$v2" | sed 's/^[0-9]*[A-Z]//')

    # Compare darwin version (major)
    if [[ "$d1" -lt "$d2" ]]; then
        echo "-1"
        return 0
    elif [[ "$d1" -gt "$d2" ]]; then
        echo "1"
        return 0
    fi

    # Compare minor letter
    if [[ "$m1" < "$m2" ]]; then
        echo "-1"
        return 0
    elif [[ "$m1" > "$m2" ]]; then
        echo "1"
        return 0
    fi

    # Compare build number (may have suffix like "248a")
    # Extract numeric part and optional suffix
    local b1_num b1_suf b2_num b2_suf
    b1_num=$(echo "$b1" | sed 's/[a-z]*$//')
    b1_suf=$(echo "$b1" | sed 's/^[0-9]*//')
    b2_num=$(echo "$b2" | sed 's/[a-z]*$//')
    b2_suf=$(echo "$b2" | sed 's/^[0-9]*//')

    # Compare numeric part
    if [[ "$b1_num" -lt "$b2_num" ]]; then
        echo "-1"
        return 0
    elif [[ "$b1_num" -gt "$b2_num" ]]; then
        echo "1"
        return 0
    fi

    # Compare suffix (empty < a < b, etc.)
    if [[ "$b1_suf" < "$b2_suf" ]]; then
        echo "-1"
        return 0
    elif [[ "$b1_suf" > "$b2_suf" ]]; then
        echo "1"
        return 0
    fi

    echo "0"
    return 0
}

# Map device platform name (from devicectl) to SDK platform name
# Args: $1 = device platform (e.g., "iOS", "macOS", "visionOS")
# Output: SDK platform name (e.g., "iphoneos", "macosx", "visionos")
device_platform_to_sdk_platform() {
    local device_platform="$1"
    case "$device_platform" in
        iOS)      echo "iphoneos" ;;
        macOS)    echo "macosx" ;;
        visionOS) echo "visionos" ;;
        tvOS)     echo "appletvos" ;;
        watchOS)  echo "watchos" ;;
        *)        echo "" ;;
    esac
}

# Validate that SDK version is compatible with device OS version
# The SDK version must be <= device OS version for binaries to run
# Args: $1 = device search pattern, $2 = platform (optional, auto-detected if not provided)
# Output: Error message if incompatible
# Returns: 0 = compatible, 1 = incompatible, 2 = could not determine
validate_sdk_device_compatibility() {
    local device="$1"
    local platform="${2:-}"

    # Get device platform if not provided
    if [[ -z "$platform" ]]; then
        local device_platform
        device_platform=$(get_device_platform "$device") || {
            echo "Warning: Could not determine device platform for '$device'"
            return 2
        }
        platform=$(device_platform_to_sdk_platform "$device_platform")
    fi

    if [[ -z "$platform" ]]; then
        echo "Warning: Could not map device to SDK platform"
        return 2
    fi

    # Get SDK build version
    local sdk_version
    sdk_version=$(get_sdk_build_version "$platform")
    if [[ "$sdk_version" == "unknown" || -z "$sdk_version" ]]; then
        echo "Warning: Could not determine SDK version for platform '$platform'"
        return 2
    fi

    # Get device OS version
    local device_version
    device_version=$(get_device_os_version "$device") || {
        echo "Warning: Could not determine OS version for device '$device'"
        return 2
    }

    # Compare versions
    local cmp_result
    cmp_result=$(compare_build_versions "$sdk_version" "$device_version")

    if [[ "$cmp_result" == "1" ]]; then
        echo ""
        echo "WARNING: SDK VERSION MISMATCH"
        echo ""
        echo "  SDK build:  $sdk_version"
        echo "  Device OS:  $device_version"
        echo ""
        echo "  The SDK is newer than the device OS. Binaries may fail to run."
        echo ""
        echo "  Options:"
        echo "    1. Update device to a newer OS version"
        echo "    2. Use an older SDK (select different Xcode)"
        echo "    3. Proceed anyway (binaries may crash or fail to load)"
        echo ""
        return 1
    fi

    return 0
}

# Get SDK name for a platform
# Usage: sdk_for_platform "iphoneos"
sdk_for_platform() {
    local platform="$1"
    case "$platform" in
        appletvos) echo "appletvos.internal" ;;
        iphoneos)  echo "iphoneos.internal" ;;
        macosx)    echo "macosx.internal" ;;
        visionos)  echo "xros.internal" ;;
        watchos)   echo "watchos.internal" ;;
        *)         echo "" ;;
    esac
}

# Get SDK build version for a platform
get_sdk_build_version() {
    local platform="$1"
    local sdk_name
    sdk_name=$(sdk_for_platform "$platform")

    if [[ -z "$sdk_name" ]]; then
        echo "unknown"
        return
    fi

    xcrun --sdk "$sdk_name" --show-sdk-build-version 2>/dev/null || echo "unknown"
}

# Get xcodebuild destination for a platform
# Usage: dest_for_platform "iphoneos"
dest_for_platform() {
    local platform="$1"
    case "$platform" in
        appletvos) echo "generic/platform=tvOS" ;;
        iphoneos)  echo "generic/platform=iOS" ;;
        macosx)    echo "generic/platform=macOS" ;;
        visionos)  echo "generic/platform=visionOS" ;;
        watchos)   echo "generic/platform=watchOS" ;;
        *)         echo "" ;;
    esac
}

# Get scheme for platform using provided mappings
# This centralizes the platform->scheme mapping logic that was duplicated in recipes.
# Args: $1 = platform
#       $2 = iphoneos scheme
#       $3 = macosx scheme
#       $4 = visionos scheme
# Output: scheme name, or empty string if platform not recognized
# Usage: scheme=$(get_scheme_for_platform "$platform" "$scheme_iphoneos" "$scheme_macosx" "$scheme_visionos")
get_scheme_for_platform() {
    local platform="$1"
    local scheme_iphoneos="$2"
    local scheme_macosx="$3"
    local scheme_visionos="$4"

    case "$platform" in
        iphoneos)  echo "$scheme_iphoneos" ;;
        macosx)    echo "$scheme_macosx" ;;
        visionos)  echo "$scheme_visionos" ;;
        *)         echo "" ;;
    esac
}

# Get devicectl filter name for a platform
# Usage: platform_filter_name "iphoneos"
platform_filter_name() {
    local platform="$1"
    case "$platform" in
        appletvos) echo "tvOS" ;;
        iphoneos)  echo "iOS" ;;
        macosx)    echo "macOS" ;;
        visionos)  echo "visionOS" ;;
        *)         echo "" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# PARAMETER VALIDATION
# ══════════════════════════════════════════════════════════════════════════════

# Validate platform is in supported list
# Args: $1 = platform, $2 = space-separated list of valid platforms
# Returns: 0 = valid, 1 = invalid (with error message)
validate_platform() {
    local platform="$1"
    local supported="$2"

    for p in $supported; do
        [[ "$p" == "$platform" ]] && return 0
    done

    echo ""
    echo "*** Error: Invalid platform '$platform' ***"
    echo ""
    echo "Valid platforms: $supported"
    echo ""
    return 1
}

# Validate configuration is Debug or Release
# Args: $1 = configuration
# Returns: 0 = valid, 1 = invalid (with error message)
validate_configuration() {
    local config="$1"

    case "$config" in
        Debug|Release) return 0 ;;
    esac

    echo ""
    echo "*** Error: Invalid configuration '$config' ***"
    echo ""
    echo "Valid configurations: Debug, Release"
    echo ""
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# AUTO-CHECK: Warn if running sandboxed in Claude Code
# ══════════════════════════════════════════════════════════════════════════════

# Run sandbox check once per just invocation when sourced
# Guards:
#   - Only in Claude Code environment (CLAUDECODE is set)
#   - Only once per just invocation (file marker prevents duplicates across subshells)
_auto_sandbox_check() {
    # Skip if not in Claude Code
    [[ -z "${CLAUDECODE:-}" ]] && return 0

    # Use file marker to prevent duplicate warnings across subshells
    # (backtick evaluation and recipe execution are separate process trees)
    local marker="/tmp/.just_sandbox_warned_${PPID:-$$}"
    if [[ -f "$marker" ]]; then
        return 0
    fi
    touch "$marker"

    # Run the actual check with generic operation name
    warn_if_sandboxed "just"
}

# Run the auto-check when this file is sourced
_auto_sandbox_check
