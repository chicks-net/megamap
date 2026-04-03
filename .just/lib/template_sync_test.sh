#!/usr/bin/env bash
# Test suite for template synchronization system
set -euo pipefail

# shellcheck source=.just/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NORMAL='\033[0m'

readonly FIXTURES_DIR=".just/test/fixtures/template_sync"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

passed=0
failed=0

# Run a single test
run_test() {
    local test_name="$1"
    local test_dir="$FIXTURES_DIR/$test_name"

    if [[ ! -d "$test_dir" ]]; then
        echo -e "${RED}✗${NORMAL} $test_name - directory not found"
        (( failed += 1 ))
        return
    fi

    # Create temp workspace
    local workspace
    workspace=$(mktemp -d)

    # Copy input files to workspace (including hidden files)
    if [[ -d "$test_dir/input" ]]; then
        shopt -s dotglob
        cp -r "$test_dir/input/"* "$workspace/" 2>/dev/null || true
        shopt -u dotglob
    fi

    # Mock curl to return fixture manifest
    local mock_curl="$workspace/curl"
    cat > "$mock_curl" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock curl for testing
if [[ "$*" == *"CHECKSUMS.json"* ]]; then
    # Return the test manifest
    manifest_path="${BASH_SOURCE[0]%/*}/manifest.json"
    if [[ -f "$manifest_path" ]]; then
        cat "$manifest_path"
        exit 0
    fi
    exit 1
elif [[ "$*" == *"-o"* ]]; then
    # Extract output file and source file from args
    output_file=""
    source_path=""
    for arg in "$@"; do
        if [[ -n "$output_file" ]]; then
            output_file="$arg"
            break
        fi
        if [[ "$arg" == "-o" ]]; then
            output_file="next"
        fi
    done
    # Get the source file from URL (last arg without -)
    for arg in "$@"; do
        if [[ "$arg" != -* && "$arg" != "$output_file" ]]; then
            source_path="$arg"
        fi
    done
    # Extract just the filename
    filename="${source_path##*/}"
    template_file="${BASH_SOURCE[0]%/*}/template_versions/$filename"
    if [[ -f "$template_file" ]]; then
        cat "$template_file" > "$output_file"
        exit 0
    fi
    exit 1
fi
exit 1
MOCK_EOF
    chmod +x "$mock_curl"

    # Copy manifest to workspace
    if [[ -f "$test_dir/manifest.json" ]]; then
        cp "$test_dir/manifest.json" "$workspace/"
    fi

    # Copy template versions if they exist
    if [[ -d "$test_dir/template_versions" ]]; then
        mkdir -p "$workspace/template_versions"
        cp -r "$test_dir/template_versions/"* "$workspace/template_versions/" 2>/dev/null || true
    fi

    # Run update logic with mocked curl
    cd "$workspace"
    export PATH="$workspace:$PATH"

    # Copy common.sh to workspace so sourcing works
    cp "$SCRIPT_DIR/common.sh" "$workspace/"

    # Create a modified version of template_update.sh that uses our workspace
    local test_script="$workspace/test_update.sh"
    # Escape pipe characters in workspace path to prevent sed command breaking
    local escaped_workspace="${workspace//|/\\|}"
    sed 's|readonly MANIFEST_FILE=\$(mktemp)|readonly MANIFEST_FILE="'"$escaped_workspace"'/manifest.json"|g' \
        "$SCRIPT_DIR/template_update.sh" > "$test_script"
    chmod +x "$test_script"

    # Capture output
    local output
    output=$("$test_script" 2>&1 || true)

    # Check expected output if provided
    local output_ok=true
    if [[ -f "$test_dir/expected_output.txt" ]]; then
        # Normalize output (remove color codes, timestamps, temp paths)
        local normalized_output
        normalized_output=$(echo "$output" | sed -E 's/\x1b\[[0-9;]*m//g' | \
            grep -v "^$" | \
            sed 's|/tmp/[^[:space:]]*||g')

        local expected
        expected=$(cat "$test_dir/expected_output.txt" | grep -v "^$")

        if ! echo "$normalized_output" | grep -qF "$expected"; then
            output_ok=false
        fi
    fi

    # Check expected state if provided
    local state_ok=true
    if [[ -d "$test_dir/expected_state" ]]; then
        while IFS= read -r expected_file; do
            local rel_path="${expected_file#$test_dir/expected_state/}"
            if [[ ! -f "$workspace/$rel_path" ]]; then
                state_ok=false
                break
            fi

            local expected_sum actual_sum
            expected_sum=$(compute_checksum "$expected_file")
            actual_sum=$(compute_checksum "$workspace/$rel_path")

            if [[ "$expected_sum" != "$actual_sum" ]]; then
                state_ok=false
                break
            fi
        done < <(find "$test_dir/expected_state" -type f)
    fi

    # Cleanup
    cd - >/dev/null
    rm -rf "$workspace"

    # Report result
    if [[ "$output_ok" == true && "$state_ok" == true ]]; then
        echo -e "${GREEN}✓${NORMAL} $test_name"
        (( passed += 1 ))
    else
        echo -e "${RED}✗${NORMAL} $test_name"
        [[ "$output_ok" == false ]] && echo "    Output mismatch"
        [[ "$state_ok" == false ]] && echo "    State mismatch"
        (( failed += 1 ))
    fi
}

# Main execution
main() {
    echo -e "${BLUE}Running template sync tests...${NORMAL}"
    echo

    # Check if fixtures directory exists
    if [[ ! -d "$FIXTURES_DIR" ]]; then
        echo -e "${YELLOW}No test fixtures found at $FIXTURES_DIR${NORMAL}"
        echo "Tests skipped"
        return 0
    fi

    # Run each test
    for test_dir in "$FIXTURES_DIR"/*; do
        if [[ -d "$test_dir" ]]; then
            test_name=$(basename "$test_dir")
            run_test "$test_name"
        fi
    done

    # Summary
    echo
    echo "Results: ${GREEN}$passed passed${NORMAL}, ${RED}$failed failed${NORMAL}"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
