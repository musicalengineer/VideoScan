#!/usr/bin/env bash
#
# build_test_filter.sh — emit xcodebuild -only-testing flags from
# workflow_dispatch inputs. Reads env vars set by the GH workflow:
#
#   MODE        : all | regression-only | specific-suite | custom-filter
#   SUITE       : suite name (with or without "VideoScanTests/" prefix)
#   FILTER      : free-form xcodebuild test arg, used verbatim
#   INCLUDE_UI  : 'true' to include VideoScanUITests target
#
# Each output line is one xcodebuild argument. Caller does:
#
#   args=()
#   while IFS= read -r a; do args+=("$a"); done < <(scripts/build_test_filter.sh)
#   xcodebuild test "${args[@]}" ...
#
# Locally testable:
#   MODE=regression-only ./scripts/build_test_filter.sh

set -euo pipefail

MODE="${MODE:-all}"
SUITE="${SUITE:-}"
FILTER="${FILTER:-}"
INCLUDE_UI="${INCLUDE_UI:-false}"

emit_suite() {
    local s="$1"
    if [[ "$s" == */* ]]; then
        echo "-only-testing:$s"
    else
        echo "-only-testing:VideoScanTests/$s"
    fi
}

case "$MODE" in
    all)
        # Restrict to the unit-test target unless UI tests requested.
        if [ "$INCLUDE_UI" != "true" ]; then
            echo "-only-testing:VideoScanTests"
        fi
        # No filter args = run everything in the scheme.
        ;;

    regression-only)
        # Walk every test file, track the enclosing struct, and emit
        # `-only-testing:VideoScanTests/<Suite>` for each suite that
        # contains a `// regression:` marker. Suites are deduped.
        # Matches all decoration patterns (`@Suite(...) struct X`,
        # `@MainActor` on prior line, `@Suite @MainActor struct X`,
        # plain `struct X`, etc.) by looking for "struct " on any
        # non-comment line and capturing the next identifier.
        for f in VideoScan/VideoScanTests/*.swift; do
            [ -f "$f" ] || continue
            awk '
                /struct[[:space:]]+[A-Za-z_]/ && $0 !~ /^[[:space:]]*\/\// {
                    s = $0
                    sub(/^.*struct[[:space:]]+/, "", s)
                    sub(/[^A-Za-z0-9_].*/, "", s)
                    if (s != "") current = s
                }
                /\/\/ regression:/ {
                    if (current != "") print current
                }
            ' "$f"
        done | sort -u | while IFS= read -r suite; do
            [ -n "$suite" ] && emit_suite "$suite"
        done
        ;;

    specific-suite)
        if [ -z "$SUITE" ]; then
            echo "ERROR: specific-suite mode needs SUITE input" >&2
            exit 2
        fi
        emit_suite "$SUITE"
        ;;

    custom-filter)
        if [ -z "$FILTER" ]; then
            echo "ERROR: custom-filter mode needs FILTER input" >&2
            exit 2
        fi
        # Pass through verbatim. Caller may have supplied multiple
        # space-separated flags; split on whitespace.
        printf '%s\n' $FILTER
        ;;

    *)
        echo "ERROR: unknown mode '$MODE'" >&2
        exit 2
        ;;
esac
