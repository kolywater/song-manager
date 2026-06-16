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

# Rebuild and relaunch the Mac app (build → kill running instance → open)
[group('build')]
reload: build
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{_build_root}}/macosx-Debug/Applications/Song Manager.app"
    pkill -x "Song Manager" 2>/dev/null || true
    open "$app"
    echo "Launched $app"

# Launch the Mac app against a throwaway copy of the example project (no
# Dropbox). Finder / Ableton / new-version all act on the copy, so the
# committed example fixture is never mutated.
[group('test')]
example: build
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    scratch="{{_build_root}}/example-scratch"
    rm -rf "$scratch"
    mkdir -p "$scratch"
    cp -R "example project" "$scratch/"
    app="{{_build_root}}/macosx-Debug/Applications/Song Manager.app"
    pkill -x "Song Manager" 2>/dev/null || true
    SM_EXAMPLE_PATH="$scratch/example project" \
        nohup "$app/Contents/MacOS/Song Manager" >/tmp/adenel-songs-example.log 2>&1 &
    echo "Launched example mode against:"
    echo "  $scratch/example project"
    echo "Logs: /tmp/adenel-songs-example.log"

# Run the standalone version-logic unit tests (no XCTest target needed)
[group('test')]
unit-tests:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    bin="$(mktemp -t versiontests)"
    swiftc Shared/VersionService.swift \
           "Song Manager macOS/FileActions.swift" \
           Tests/main.swift -o "$bin"
    "$bin"

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
    export_path="$HOME/Library/CloudStorage/Dropbox/music/aidenel songs/$app_name"

    if [[ ! -d "$app_path" ]]; then
        echo "Error: $app_name not found at $app_path"
        exit 1
    fi

    echo ""
    echo "Copying $app_name to $(dirname "$export_path")..."
    mkdir -p "$(dirname "$export_path")"
    rm -rf "$export_path"
    cp -R "$app_path" "$export_path"

    echo "Exported:"
    echo "  $export_path"

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

    app_path="$HOME/Library/CloudStorage/Dropbox/music/aidenel songs/$app_name"

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

# Cut a release: bump version, build Release, zip the .app, tag, and
# publish to GitHub so the in-app updater can find it.
#   just release 1.1
[group('build')]
release version:
    #!/usr/bin/env bash
    set -euo pipefail

    version="{{version}}"
    # Digits-and-dots only (no leading "v"); the tag gets the v prefix.
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "Usage: just release 1.1   (digits and dots only, no leading 'v')"
        exit 1
    fi
    tag="v$version"

    if git rev-parse "$tag" >/dev/null 2>&1; then
        echo "Error: tag $tag already exists."
        exit 1
    fi

    # Require no uncommitted *tracked* changes so the version-bump commit
    # is self-contained. Untracked files (scratch dirs, notes) are fine.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "Error: working tree has uncommitted changes — commit or stash first."
        exit 1
    fi

    pbxproj="{{xcode_project_or_workspace}}/project.pbxproj"
    echo "Bumping MARKETING_VERSION → $version"
    # Bumps every target's MARKETING_VERSION (macOS + iOS stay in lockstep).
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $version;/g" "$pbxproj"
    git add "$pbxproj"
    git commit -m "Release $tag"

    # Build the macOS Release into build/macosx-Release/Applications/.
    just build macosx Release

    scheme="{{scheme_macosx}}"
    app_path="{{_build_root}}/macosx-Release/Applications/$scheme.app"
    if [[ ! -d "$app_path" ]]; then
        echo "Error: built app not found at $app_path"
        exit 1
    fi

    dist="{{_build_root}}/dist"
    mkdir -p "$dist"
    zip_path="$dist/SongManager-$version.zip"
    rm -f "$zip_path"
    echo "Zipping → $zip_path"
    # --keepParent so the archive contains "<scheme>.app", which the
    # updater's ditto extraction expects.
    ditto -c -k --keepParent "$app_path" "$zip_path"

    # Tag + push so the GitHub release attaches to the bump commit.
    git tag "$tag"
    git push origin HEAD
    git push origin "$tag"

    echo "Creating GitHub release $tag"
    gh release create "$tag" "$zip_path" \
        --title "$tag" \
        --generate-notes

    echo ""
    echo "Released $tag"
    echo "  asset: $zip_path"
