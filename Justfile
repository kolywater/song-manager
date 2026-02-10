# Justfile
#
# Usage:
#   just build                    Build for iphoneos Debug
#   just build macosx Release     Build for macOS Release
#   just build all                Build all platforms
#   just test                     Run tests on default device
#   just test "iPhone 16"         Run tests on specific device
#   just install my-device        Deploy to device
#   just devices                  List available devices
#   just -n build                 Dry-run (show commands)
#
# For new projects, copy this file and modify the configuration below.
# The shared recipes are in scripts/just/common.just

# ══════════════════════════════════════════════════════════════════════════════
# PROJECT CONFIGURATION - Edit this section for your project
# Set any unused variables to empty strings
# ══════════════════════════════════════════════════════════════════════════════

# Project identity (overridable)
xcode_project_or_workspace := "Song Manager.xcodeproj"
_xbs_project := ""

# Platform → Scheme mappings (overridable)
scheme_iphoneos := ""
scheme_macosx := "Song Manager"
scheme_visionos := ""

# Supported platforms (space-separated)
_supported_platforms := "macosx"

# Defaults
_default_platform := "macosx"
_default_device := ""
_default_configuration := "Debug"
_roots_dir := justfile_directory() / "build"

# Test configuration
_test_scheme := "Song Manager"

# Lint configuration (can be a command or a script path)
_linter := "swiftlint lint"
_lint_extensions := "swift"

# Debug log path
debug_log := "/tmp/adenel-songs.log"

# Crash monitoring: binaries to check for crashes on device
_crash_binaries := ""

# Custom help examples (appended to 'just help' output)
# Note: launch examples are generated dynamically from _workflow_platforms
_workflow_platforms := ""
_custom_help_examples := '''
just test iPhone TamaleTests/CameraIntegrationTests
                            # Run camera integration tests
just check-crashes iPhone   # Check for recent crashes
'''

# ══════════════════════════════════════════════════════════════════════════════
# END PROJECT CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

# Default: show available recipes
[private]
default:
    @just --list

# Import shared recipes
import 'scripts/just/common.just'
import 'scripts/just/common-device.just'

# ══════════════════════════════════════════════════════════════════════════════
# ALIASES - Short forms for common commands (hidden from --list)
# ══════════════════════════════════════════════════════════════════════════════

[private]
alias b := build

[private]
alias t := test

[private]
alias r := root

[private]
alias i := install

# ══════════════════════════════════════════════════════════════════════════════
# PROJECT-SPECIFIC RECIPES
# ══════════════════════════════════════════════════════════════════════════════

# Build and copy app to project root
[group('build')]
export platform=_default_platform configuration=_default_configuration: (build platform configuration)
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    # Get scheme for platform (matches build recipe)
    scheme=$(get_scheme_for_platform "{{platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    [[ -z "$scheme" ]] && echo "Error: No scheme for platform {{platform}}" && exit 1

    dstroot="{{_build_root}}/{{platform}}-{{configuration}}"
    app_name="$scheme.app"
    app_path="$dstroot/Applications/$app_name"
    export_path="./build/$app_name"

    if [[ ! -d "$app_path" ]]; then
        echo "Error: $app_name not found at $app_path"
        exit 1
    fi

    echo ""
    echo "Copying $app_name to project root..."
    rm -rf "$export_path"
    cp -R "$app_path" "$export_path"

    echo "Exported:"
    echo "  $PWD/$app_name"

# Run app and stream logs in tmux
[group('build')]
run:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{_lib_sh}}"

    scheme=$(get_scheme_for_platform "{{_default_platform}}" "{{scheme_iphoneos}}" "{{scheme_macosx}}" "{{scheme_visionos}}")
    app_name="$scheme.app"
    log_file="{{debug_log}}"
    session_name="{{_project}}-logs"

    app_path="./build/$app_name"

    if [[ ! -d "$app_path" ]]; then
        echo "Error: $app_name not found"
        echo "Run 'just export' first"
        exit 1
    fi

    # Create session if doesn't exist
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "Starting log watcher in tmux: $session_name"
        tmux new-session -d -s "$session_name" "tail -F '$log_file' 2>/dev/null || sleep infinity"
    else
        echo "Reusing existing tmux session: $session_name"
    fi

    echo "Checking for running instances..."
    pkill -x "$scheme" 2>/dev/null || true
    sleep 0.5

    echo "Launching $app_name..."
    open "$app_path"

    echo ""
    echo "View logs: tmux attach -t $session_name"
    echo "Stop: tmux kill-session -t $session_name"
