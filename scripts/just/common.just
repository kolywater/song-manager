# common.just - Shared recipes for Xcode project build automation
#
# This file provides generic build system recipes for xcodeproj-based codebases.
# Import this file in your project-specific Justfile and configure the required variables.
#
# Required variables (set in importing Justfile):
#   xcode_project_or_workspace  - Project or workspace file (e.g., "MyApp.xcodeproj") [overridable]
#   scheme_<platform>           - Scheme for each platform (e.g., scheme_iphoneos) [overridable]
#   _xbs_project                - XBS project name
#   _supported_platforms        - Space-separated list of platforms
#   _default_platform           - Default platform
#   _default_device             - Default device name
#   _default_configuration      - Default configuration (Debug/Release)
#   _roots_dir                  - Directory for build artifacts
#   _test_scheme                - Test scheme name
#   _custom_help_examples       - (optional) Additional examples for help output

# Use bash with strict mode
set shell := ["bash", "-euo", "pipefail", "-c"]

# Path to shared library (sibling to this file, for use in recipes)
_lib_sh := source_directory() / "common-lib.sh"

# Derived from xcode_project_or_workspace
_project := file_stem(xcode_project_or_workspace)

# Project name for SSH helpers (uppercase, used as env var prefix)
_project_name_upper := uppercase(_project)

# Computed paths (note: backtick evaluation requires path relative to project root)
_build_subdir := `source scripts/just/common-lib.sh && get_build_subdir`
_build_root := if _build_subdir == "" { _roots_dir } else { _roots_dir + "/" + _build_subdir }
_logs_dir := _build_root + "/logs"

# Build target flag for xcodebuild (inferred from xcode_project_or_workspace extension)
_build_target_without_workspace := trim_end_match(xcode_project_or_workspace, ".xcworkspace")
_build_target_flag := if _build_target_without_workspace != xcode_project_or_workspace { "-workspace \"" + xcode_project_or_workspace + "\"" } else { "-project \"" + xcode_project_or_workspace + "\"" }

# ══════════════════════════════════════════════════════════════════════════════
# EXAMPLES
# ══════════════════════════════════════════════════════════════════════════════

# Show example invocations
[group('info')]
examples:
    #!/usr/bin/env bash
    echo "Example invocations:"
    echo ""
    echo "  just build                  # Build {{_default_platform}} {{_default_configuration}}"
    echo "  just build macosx Release   # Build macOS Release"
    echo "  just build all              # Build all platforms"
    echo "  just test                   # Test on default device"
    echo "  just test \"iPhone 16\"       # Test on specific device"
    echo "  just lint                   # Lint changed files"
    echo "  just lint all --fix         # Lint and auto-fix all files"
    echo "  just install my-device      # Deploy to device (auto-detects platform)"
    echo "  just -n build               # Dry-run (show commands)"
    # Print custom examples if defined
    custom_examples="{{_custom_help_examples}}"
    if [[ -n "$custom_examples" ]]; then
        echo "$custom_examples" | sed 's/^/  /'
    fi
    # Print launch workflow examples if _workflow_platforms is defined
    workflow_platforms="{{_workflow_platforms}}"
    if [[ -n "$workflow_platforms" ]]; then
        echo "$workflow_platforms" | grep -v '^$' | while IFS=: read -r mode binary platforms desc; do
            printf "  just launch iPhone %-9s # %s\n" "$mode" "$desc"
        done
    fi
    echo ""
    echo "Aliases: b=build, t=test, r=root, i=install"
    echo "Platforms: {{_supported_platforms}}"
    echo "Configurations: Debug, Release"

# ══════════════════════════════════════════════════════════════════════════════
# BUILD
# ══════════════════════════════════════════════════════════════════════════════

# Build for platform
[group('build')]
build platform=_default_platform configuration=_default_configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    if [[ "{{platform}}" == "all" ]]; then
        echo "Starting on all platforms: {{_supported_platforms}}"
        for p in {{_supported_platforms}}; do
            echo ""
            echo "===================================="
            echo "Building for $p..."
            echo "===================================="
            just build "$p" "{{configuration}}"
        done
        echo ""
        echo "All platforms built successfully!"
        exit 0
    fi

    # Validate parameters
    validate_platform "{{platform}}" "{{_supported_platforms}}" || exit 1
    validate_configuration "{{configuration}}" || exit 1

    # Get scheme for platform
    scheme=$(get_scheme_for_platform "{{platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && echo "Error: No scheme for platform {{platform}}" && exit 1

    dstroot="{{_build_root}}/{{platform}}-{{configuration}}"
    build_log="{{_logs_dir}}/{{platform}}-{{configuration}}.log"
    errors_log="{{_logs_dir}}/{{platform}}-{{configuration}}.errors"
    warnings_log="{{_logs_dir}}/{{platform}}-{{configuration}}.warnings"
    success_marker="{{_logs_dir}}/{{platform}}-{{configuration}}.success"
    destination=$(dest_for_platform "{{platform}}")

    mkdir -p "{{_logs_dir}}"
    rm -f "$success_marker"
    touch "$errors_log" "$warnings_log"

    echo "Building {{platform}} {{configuration}} with DSTROOT:"
    echo "  $dstroot"
    echo ""
    echo "Logging to:"
    echo "  $build_log"
    echo ""
    echo "Monitor build progress:"
    echo "  tail -f \"$build_log\""
    echo ""

    # Determine formatter and run build
    # Priority: CLAUDECODE → xcbeautify → xcpretty → raw
    # Skip formatters when CLAUDECODE is set (use quiet mode)
    set +e
    if [[ -n "${CLAUDECODE:-}" ]]; then
        echo "Running in quiet mode (errors only)"
        echo ""
        xcodebuild {{_build_target_flag}} -scheme "$scheme" \
            -configuration "{{configuration}}" \
            -destination "$destination" \
            install DSTROOT="$dstroot" 2>&1 | tee "$build_log" | grep -E ': error:' || true
        build_exit_code=${PIPESTATUS[0]}
    elif command -v xcbeautify &>/dev/null; then
        echo "Using xcbeautify for formatted output"
        echo ""
        xcodebuild {{_build_target_flag}} -scheme "$scheme" \
            -configuration "{{configuration}}" \
            -destination "$destination" \
            install DSTROOT="$dstroot" 2>&1 | tee "$build_log" | xcbeautify || true
        build_exit_code=${PIPESTATUS[0]}
    elif command -v xcpretty &>/dev/null; then
        echo "Using xcpretty for formatted output"
        echo ""
        xcodebuild {{_build_target_flag}} -scheme "$scheme" \
            -configuration "{{configuration}}" \
            -destination "$destination" \
            install DSTROOT="$dstroot" 2>&1 | tee "$build_log" | xcpretty || true
        build_exit_code=${PIPESTATUS[0]}
    else
        xcodebuild {{_build_target_flag}} -scheme "$scheme" \
            -configuration "{{configuration}}" \
            -destination "$destination" \
            install DSTROOT="$dstroot" 2>&1 | tee "$build_log" || true
        build_exit_code=$?
    fi
    set -e

    # Check for interrupt/cancellation
    if [[ $build_exit_code -eq 130 ]] || [[ $build_exit_code -eq 2 ]]; then
        echo ""
        echo "*** Build interrupted ***"
        exit $build_exit_code
    fi

    # Extract errors and warnings
    grep ': error:' "$build_log" > "$errors_log" 2>/dev/null || true
    grep ': warning:' "$build_log" > "$warnings_log" 2>/dev/null || true

    # Check for errors
    error_count=$(wc -l < "$errors_log" | tr -d ' ')
    if [[ "$error_count" -gt 0 ]]; then
        echo ""
        echo "*** Build FAILED with $error_count errors ***"
        echo ""
        echo "Check errors:"
        echo "  cat \"$errors_log\""
        echo ""
        echo "Full logs:"
        echo "  cat \"$build_log\""
        exit 1
    fi

    # Verify DSTROOT has files
    if [[ ! -d "$dstroot" ]] || [[ -z "$(find "$dstroot" -type f -print -quit 2>/dev/null)" ]]; then
        echo ""
        echo "*** Build FAILED: DSTROOT is empty or missing ***"
        echo ""
        echo "Expected files in: $dstroot"
        exit 1
    fi

    touch "$success_marker"
    echo ""
    echo "Build complete. Summary:"
    echo "  Errors:   $(wc -l < "$errors_log" | tr -d ' ') lines"
    echo "  Warnings: $(wc -l < "$warnings_log" | tr -d ' ') lines"

# ══════════════════════════════════════════════════════════════════════════════
# TEST
# ══════════════════════════════════════════════════════════════════════════════

# Run tests on device
[group('test')]
test device=_default_device only_testing="" platform=_default_platform configuration=_default_configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    validate_device "{{device}}"
    validate_configuration "{{configuration}}" || exit 1

    # Validate SDK compatibility with device (skip for macOS which runs locally)
    if [[ "{{platform}}" != "macosx" ]]; then
        validate_sdk_device_compatibility "${DEVICE_ID:-{{device}}}" "{{platform}}" || {
            echo "Aborting test due to SDK/device version mismatch."
            echo "Set SKIP_SDK_CHECK=1 to bypass this check."
            [[ -z "${SKIP_SDK_CHECK:-}" ]] && exit 1
        }
    fi

    test_log="{{_logs_dir}}/{{platform}}-{{configuration}}-${DEVICE_ID:-{{device}}}.test.log"
    test_failures="{{_logs_dir}}/{{platform}}-{{configuration}}-${DEVICE_ID:-{{device}}}.test-failures"

    mkdir -p "{{_logs_dir}}"
    touch "$test_failures"

    # Build test destination
    if [[ "{{platform}}" == "macosx" ]]; then
        test_dest="platform=macOS"
    elif [[ -n "${DEVICE_ID:-}" ]]; then
        platform_name=$(platform_filter_name "{{platform}}")
        [[ -z "$platform_name" ]] && platform_name="iOS"
        test_dest="platform=$platform_name,id=$DEVICE_ID"
    else
        echo "Error: No device specified for platform {{platform}}"
        exit 1
    fi

    echo "Running tests for {{platform}} {{configuration}} on {{device}}:"
    echo "  Test scheme: {{_test_scheme}}"
    echo ""
    echo "Logging to:"
    echo "  Full output:  $test_log"
    echo "  Failures:     $test_failures"
    echo ""
    echo "Monitor test progress:"
    echo "  tail -f \"$test_log\""
    echo ""

    # Build test command
    test_cmd="xcodebuild {{_build_target_flag}} -scheme \"{{_test_scheme}}\" -configuration \"{{configuration}}\" -destination \"$test_dest\""

    if [[ -n "{{only_testing}}" ]]; then
        test_cmd="$test_cmd -only-testing:{{only_testing}}"
    fi

    test_cmd="$test_cmd test -collect-test-diagnostics never"

    # Run tests
    set +e
    eval "$test_cmd" 2>&1 | tee "$test_log" | awk '/^✘ / {print; fflush()}' > "$test_failures"
    test_exit=$?
    set -e

    # Extract xcresult path
    xcresult=$(grep '\.xcresult$' "$test_log" 2>/dev/null | grep -v '^$' | tail -1 | sed 's/^[[:space:]]*//' || true)

    if [[ $test_exit -ne 0 ]]; then
        echo ""
        if grep -q "build commands failed" "$test_log" 2>/dev/null || grep -q "Unable to find a device" "$test_log" 2>/dev/null; then
            echo "*** Build or device error during testing ***"
            echo ""
            tail -20 "$test_log"
        else
            echo "*** Tests FAILED with exit code $test_exit ***"
            echo ""
            echo "Failed tests:"
            cat "$test_failures"
            if [[ -n "$xcresult" ]]; then
                echo ""
                echo "  open \"$xcresult\""
            fi
        fi
        exit $test_exit
    fi

    echo ""
    echo "Tests complete."
    echo ""
    grep "✔ " "$test_log" 2>/dev/null | grep -v "Executed" || true

# ══════════════════════════════════════════════════════════════════════════════
# ROOT
# ══════════════════════════════════════════════════════════════════════════════

# Build and create tarball
[group('build')]
root platform=_default_platform configuration=_default_configuration: (build platform configuration)
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    if [[ "{{platform}}" == "all" ]]; then
        echo "Starting on all platforms: {{_supported_platforms}}"
        for p in {{_supported_platforms}}; do
            echo ""
            echo "===================================="
            echo "Building root for $p..."
            echo "===================================="
            just root "$p" "{{configuration}}"
        done
        echo ""
        echo "All platform roots built successfully!"
        exit 0
    fi

    # Validate parameters
    validate_platform "{{platform}}" "{{_supported_platforms}}" || exit 1
    validate_configuration "{{configuration}}" || exit 1

    # Get scheme for platform (must match build recipe)
    scheme=$(get_scheme_for_platform "{{platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && echo "Error: No scheme for platform {{platform}}" && exit 1

    success_marker="{{_logs_dir}}/{{platform}}-{{configuration}}.success"
    dstroot="{{_build_root}}/{{platform}}-{{configuration}}"
    sdk_build=$(get_sdk_build_version "{{platform}}")

    if [[ ! -f "$success_marker" ]]; then
        echo ""
        echo "*** Cannot package root: Previous build failed ***"
        exit 1
    fi

    tarball_name="{{_project}}-${scheme}-DSTROOT-{{platform}}-{{configuration}}-${sdk_build}"
    [[ -n "{{_build_subdir}}" ]] && tarball_name="${tarball_name}-{{_build_subdir}}"
    tarball="{{_build_root}}/${tarball_name}.tar.gz"

    # Write version file into DSTROOT for tracking
    version_dir="$dstroot/usr/appleinternal/lib"
    mkdir -p "$version_dir"
    git_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "$git_commit" > "$version_dir/{{_project}}.version"
    echo "  Version marker: $git_commit (${git_branch})"

    echo "Packaging {{platform}} {{configuration}} root..."
    (cd "$dstroot" && tar cfzp "$tarball" --exclude='*.dSYM' .)

    echo "Created:"
    echo "  $tarball"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL
# ══════════════════════════════════════════════════════════════════════════════

# Deploy to device via darwinup
[group('device')]
install device platform="auto" configuration=_default_configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"
    export _PROJECT_NAME="{{_project_name_upper}}"

    # Resolve device to SSH hostname BEFORE building (fail fast on ambiguity)
    resolve_ssh_target "{{device}}" || exit 1

    # Auto-detect platform from device if not specified
    platform="{{platform}}"
    if [[ "$platform" == "auto" ]]; then
        detected=$(get_device_platform "{{device}}") || detected=""
        if [[ -n "$detected" ]]; then
            # Map device platform names to build platform names
            case "$detected" in
                iOS)      platform="iphoneos" ;;
                macOS)    platform="macosx" ;;
                visionOS) platform="visionos" ;;
                watchOS)  platform="watchos" ;;
                tvOS)     platform="tvos" ;;
                *)        platform="{{_default_platform}}" ;;
            esac
            echo "Auto-detected platform: $platform (from device)"
        else
            platform="{{_default_platform}}"
            echo "Could not detect platform, using default: $platform"
        fi
    fi

    # Validate parameters
    validate_platform "$platform" "{{_supported_platforms}}" || exit 1
    validate_configuration "{{configuration}}" || exit 1

    # Validate SDK compatibility with device before building
    # Skip for macOS which runs locally
    if [[ "$platform" != "macosx" ]]; then
        validate_sdk_device_compatibility "{{device}}" "$platform" || {
            echo "Aborting install due to SDK/device version mismatch."
            echo "Set SKIP_SDK_CHECK=1 to bypass this check."
            [[ -z "${SKIP_SDK_CHECK:-}" ]] && exit 1
        }
    fi

    # Build root
    just root "$platform" "{{configuration}}"

    # Get scheme for platform (must match root recipe)
    scheme=$(get_scheme_for_platform "$platform" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && echo "Error: No scheme for platform $platform" && exit 1

    sdk_build=$(get_sdk_build_version "$platform")
    tarball=$(ls -t "{{_build_root}}/{{_project}}-${scheme}-DSTROOT-${platform}-{{configuration}}"-*.tar.gz 2>/dev/null | head -1 || true)

    if [[ -z "$tarball" ]]; then
        echo "Error: No tarball found for $platform {{configuration}}"
        exit 1
    fi

    echo "Installing $platform {{configuration}} root to $SSH_TARGET..."
    echo "Deploying $tarball"

    run_device_scp "$tarball" "$SSH_TARGET" "/tmp/"

    echo "Uninstalling old {{_project}} roots..."
    if [[ -n "${CLAUDECODE:-}" ]]; then
        # Quiet mode for Claude Code
        run_device_ssh "$SSH_TARGET" "darwinup list" 2>/dev/null | tr -s ' ' | cut -d ' ' -f7 | { grep "{{_project}}" || true; } | while read -r root; do
            run_device_ssh "$SSH_TARGET" "darwinup uninstall $root" &>/dev/null || true
        done
    else
        run_device_ssh "$SSH_TARGET" "darwinup list" 2>/dev/null | tr -s ' ' | cut -d ' ' -f7 | { grep "{{_project}}" || true; } | while read -r root; do
            run_device_ssh "$SSH_TARGET" "darwinup uninstall $root" || true
        done
    fi

    echo "Installing new root..."
    if [[ -n "${CLAUDECODE:-}" ]]; then
        if ! run_device_ssh "$SSH_TARGET" "cd / && darwinup install /tmp/$(basename "$tarball")" &>/dev/null; then
            echo "✗ darwinup install failed"
            exit 1
        fi
    else
        run_device_ssh "$SSH_TARGET" "cd / && darwinup install /tmp/$(basename "$tarball")"
    fi

    echo "Installation complete. Verify with:"
    echo "  ssh root@$SSH_TARGET 'darwinup list'"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL-SDK
# ══════════════════════════════════════════════════════════════════════════════

# Install to SDK via darwinup
[group('host')]
install-sdk platform=_default_platform configuration=_default_configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    # Validate parameters
    validate_platform "{{platform}}" "{{_supported_platforms}}" || exit 1
    validate_configuration "{{configuration}}" || exit 1

    # Build root first
    just root "{{platform}}" "{{configuration}}"

    # Get scheme for platform (must match root recipe)
    scheme=$(get_scheme_for_platform "{{platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && echo "Error: No scheme for platform {{platform}}" && exit 1

    sdk_name=$(sdk_for_platform "{{platform}}")
    [[ -z "$sdk_name" ]] && echo "Error: No SDK for platform {{platform}}" && exit 1

    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null || true)
    [[ -z "$sdk_path" ]] && echo "Error: Could not determine SDK path for $sdk_name" && exit 1

    tarball=$(ls -t "{{_build_root}}/{{_project}}-${scheme}-DSTROOT-{{platform}}-{{configuration}}"-*.tar.gz 2>/dev/null | head -1 || true)
    [[ -z "$tarball" ]] && echo "Error: No tarball found" && exit 1

    echo "Installing {{platform}} {{configuration}} root to SDK: $sdk_name..."
    echo "Deploying $tarball to SDK: $sdk_path"

    echo "Uninstalling old {{_project}} roots from SDK..."
    sudo darwinup -s -p "$sdk_path" list 2>/dev/null | tr -s ' ' | cut -d ' ' -f7 | { grep "{{_project}}" || true; } | while read -r root; do
        sudo darwinup -s -p "$sdk_path" uninstall "$root" || true
    done

    echo "Installing new root to SDK..."
    sudo darwinup -s -p "$sdk_path" install "$tarball"

    echo "SDK installation complete. Verify with:"
    echo "  sudo darwinup -p \$(xcrun --sdk \"$sdk_name\" --show-sdk-path) list"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL-ALLOWLIST
# ══════════════════════════════════════════════════════════════════════════════

# Add SSH/SCP and just to Claude Code allowlist
[group('host')]
install-allowlist:
    #!/usr/bin/env bash
    set -euo pipefail

    allowlist_file="$HOME/.claude/apple/tool_allowlist.csv"
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    echo "Adding SSH/SCP and just patterns to Claude Code allowlist..."
    echo "  File: $allowlist_file"
    echo ""

    mkdir -p "$(dirname "$allowlist_file")"

    # Ensure file ends with newline
    if [[ -f "$allowlist_file" ]] && [[ -s "$allowlist_file" ]]; then
        [[ $(tail -c1 "$allowlist_file" | wc -l) -eq 0 ]] && echo "" >> "$allowlist_file"
    fi

    just_pattern="just "
    ssh_pattern="JUST_{{uppercase(_project)}}=1 ssh -o BatchMode=yes "
    scp_pattern="JUST_{{uppercase(_project)}}=1 scp -o BatchMode=yes "
    added=0

    # Add 'just' itself to allowlist (unsandboxed for full functionality)
    if grep -qF "$just_pattern" "$allowlist_file" 2>/dev/null; then
        echo "  ✓ just pattern already exists"
    else
        echo "$just_pattern,prefix_match,Added $timestamp - just build system" >> "$allowlist_file"
        echo "  + Added just pattern"
        added=$((added + 1))
    fi

    if grep -qF "$ssh_pattern" "$allowlist_file" 2>/dev/null; then
        echo "  ✓ SSH pattern already exists"
    else
        echo "$ssh_pattern,contains_match,Added $timestamp - just install SSH access" >> "$allowlist_file"
        echo "  + Added SSH pattern"
        added=$((added + 1))
    fi

    if grep -qF "$scp_pattern" "$allowlist_file" 2>/dev/null; then
        echo "  ✓ SCP pattern already exists"
    else
        echo "$scp_pattern,contains_match,Added $timestamp - just install SCP access" >> "$allowlist_file"
        echo "  + Added SCP pattern"
        added=$((added + 1))
    fi

    echo ""
    if [[ $added -gt 0 ]]; then
        echo "Done! Added $added pattern(s)."
        echo ""
        echo "You may need to restart Claude Code for changes to take effect."
    else
        echo "No changes needed - patterns already configured."
    fi

# ══════════════════════════════════════════════════════════════════════════════
# XBS-BUILD
# ══════════════════════════════════════════════════════════════════════════════

# Build with XBS buildit
[group('build')]
xbs-build platform=_default_platform:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    # Validate parameters
    validate_platform "{{platform}}" "{{_supported_platforms}}" || exit 1

    sdk_name=$(sdk_for_platform "{{platform}}")
    [[ -z "$sdk_name" ]] && echo "Error: No SDK for platform {{platform}}" && exit 1

    echo "Building with XBS..."
    echo "  Detecting train from SDK..."

    sdk_build=$(xcrun --sdk "$sdk_name" --show-sdk-build-version 2>/dev/null || echo "unknown")

    if [[ "{{platform}}" == "macosx" ]]; then
        xbs_train=$(xbs getTrainForBuild --quiet "$sdk_build" 2>/dev/null || true)
    else
        xbs_train=$(xbs getTrainForBuild --quiet --embedded "$sdk_build" 2>/dev/null || true)
    fi

    echo "  Update:  Current$xbs_train"
    echo "  Project: {{_xbs_project}}"

    xbs buildit \
        -update "Current$xbs_train" \
        -project "{{_xbs_project}}" \
        -target All \
        -dsymsInDstRoot \
        -noverify \
        -archive \
        .

# ══════════════════════════════════════════════════════════════════════════════
# CLEAN
# ══════════════════════════════════════════════════════════════════════════════

# Clean build artifacts
[group('build')]
clean platform=_default_platform:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    # Get scheme for platform (fallback to iphoneos scheme)
    scheme=$(get_scheme_for_platform "{{platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && scheme="{{scheme_iphoneos}}"

    echo "Cleaning build artifacts..."

    rm -rf "{{_build_root}}/{{platform}}"-*
    rm -f "{{_build_root}}/{{_project}}"-*-DSTROOT-*.tar.gz
    rm -rf "{{_logs_dir}}"

    echo "Running: xcodebuild {{_build_target_flag}} -scheme \"$scheme\" clean"
    xcodebuild {{_build_target_flag}} -scheme "$scheme" clean > /dev/null 2>&1 || true

    echo "Clean complete."

# ══════════════════════════════════════════════════════════════════════════════
# DEVICES
# ══════════════════════════════════════════════════════════════════════════════

# List available devices
[group('device')]
devices platform="":
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    echo "Available devices for testing and installation:"
    echo ""

    # Use multiple --columns flags (comma-separated doesn't work - rdar://167589553)
    # Show only useful columns: Name, Hostname, UDID, Model, Platform, OS Version
    # Excluded: Identifier (CoreDevice UUID), State, ECID, Serial Number, OS Build
    device_columns="--hide-default-columns --columns Name --columns Hostname --columns UDID --columns Model --columns Platform --columns 'OS Version'"

    # Include both "available" and "connected" states
    if [[ -z "{{platform}}" ]]; then
        eval "xcrun devicectl list devices $device_columns --filter 'State beginswith \"available\" OR State == \"connected\"'" 2>/dev/null || echo "  No available devices found"
    else
        platform_filter=$(platform_filter_name "{{platform}}")
        if [[ -z "$platform_filter" ]]; then
            echo "Error: Unknown platform '{{platform}}'. Valid: iphoneos, macosx, visionos, appletvos"
            exit 1
        fi
        eval "xcrun devicectl list devices $device_columns --filter \"Platform == '$platform_filter' AND (State beginswith 'available' OR State == 'connected')\"" 2>/dev/null || echo "  No connected {{platform}} devices found"
    fi

    echo ""

# ══════════════════════════════════════════════════════════════════════════════
# LINT
# ══════════════════════════════════════════════════════════════════════════════

# Lint changed files or all files (optionally pass extra flags)
# Pass --fix to auto-fix violations
[group('test')]
lint scope="changed" *flags="":
    #!/usr/bin/env bash
    set -euo pipefail

    linter_cmd="{{_linter}}"
    extensions="{{_lint_extensions}}"
    ext_pattern="\.(${extensions//,/|})\$"

    # Determine if we should auto-fix or just check
    # Default behavior: just check (no auto-fix)
    # Explicit --fix: auto-fix violations
    auto_fix=false

    if [[ "{{flags}}" == *"--fix"* ]]; then
        auto_fix=true
    fi

    # Build full linter command with auto-fix or check mode
    if [[ "$auto_fix" == true ]]; then
        full_linter_cmd="$linter_cmd --fix"
    else
        full_linter_cmd="$linter_cmd"
    fi

    # Add any additional flags (except --fix which we handled)
    extra_flags="{{flags}}"
    extra_flags="${extra_flags//--fix/}"
    extra_flags="${extra_flags//  / }"  # Clean up double spaces
    if [[ -n "$extra_flags" ]]; then
        full_linter_cmd="$full_linter_cmd $extra_flags"
    fi

    if [[ "{{scope}}" == "all" ]]; then
        if [[ "$auto_fix" == true ]]; then
            echo "Linting and auto-fixing all files..."
        else
            echo "Linting all files..."
        fi
        echo "Running: $full_linter_cmd"
        echo ""
        set +e
        lint_output=$($full_linter_cmd 2>&1)
        lint_exit=$?
        set -e

        echo "$lint_output"

        # Suggest --fix if violations found and not auto-fixing
        if [[ "$auto_fix" == false ]] && echo "$lint_output" | grep -q "Found [1-9][0-9]* violations"; then
            echo ""
            echo "Hint: Run 'just lint {{scope}} --fix' to automatically fix violations"
        fi
        exit $lint_exit
    fi

    # Collect changed files (staged, unstaged, untracked)
    files=""

    # Staged changes (excluding deleted files)
    staged=$(git diff --cached --name-only --diff-filter=d 2>/dev/null || true)
    [[ -n "$staged" ]] && files+="$staged"$'\n'

    # Unstaged changes (excluding deleted files)
    unstaged=$(git diff --name-only --diff-filter=d 2>/dev/null || true)
    [[ -n "$unstaged" ]] && files+="$unstaged"$'\n'

    # Untracked files
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
    [[ -n "$untracked" ]] && files+="$untracked"$'\n'

    # Filter by extension, dedupe, remove empties
    files=$(echo "$files" | grep -E "$ext_pattern" | sort -u | grep -v '^$' || true)

    if [[ -z "$files" ]]; then
        echo "No changed $extensions files to lint."
        exit 0
    fi

    count=$(echo "$files" | wc -l | tr -d ' ')
    if [[ "$auto_fix" == true ]]; then
        echo "Linting and auto-fixing $count changed file(s):"
    else
        echo "Linting $count changed file(s):"
    fi
    echo "$files" | sed 's/^/  /'
    echo ""

    # Run linter with files as arguments
    set +e
    lint_output=$(echo "$files" | xargs $full_linter_cmd 2>&1)
    lint_exit=$?
    set -e

    echo "$lint_output"

    # Suggest --fix if violations found and not auto-fixing
    if [[ "$auto_fix" == false ]] && echo "$lint_output" | grep -q "Found [1-9][0-9]* violations"; then
        echo ""
        echo "Hint: Run 'just lint {{scope}} --fix' to automatically fix violations"
    fi
    exit $lint_exit

# Debug: check sandbox status
_debug-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    echo "=== Sandbox Detection Debug ==="
    echo ""
    echo "1. Testing sandbox-exec..."
    if sandbox-exec -p '(version 1)(allow default)' /bin/echo "sandbox-exec works" 2>/dev/null; then
        echo "   Result: NOT sandboxed (sandbox-exec works)"
    else
        echo "   Result: sandbox-exec failed (blocked or sandboxed)"
    fi
    echo ""
    echo "2. Testing ssh -V..."
    ssh_output=$(ssh -V 2>&1 || true)
    echo "   Output: $ssh_output"
    if [[ "$ssh_output" == *"SANDBOX VIOLATION"* ]]; then
        echo "   Result: SSH BLOCKED"
    else
        echo "   Result: SSH available"
    fi
    echo ""
    echo "3. is_sandboxed() returns:"
    if is_sandboxed; then echo "   TRUE (sandboxed)"; else echo "   FALSE (not sandboxed)"; fi
    echo ""
    echo "4. is_ssh_blocked() returns:"
    if is_ssh_blocked; then echo "   TRUE (SSH blocked)"; else echo "   FALSE (SSH available)"; fi
    echo ""
    echo "5. CLAUDECODE=${CLAUDECODE:-<not set>}"
    echo "6. APPLE_CLAUDE_CODE_PROXY_PORT=${APPLE_CLAUDE_CODE_PROXY_PORT:-<not set>}"
