#!/usr/bin/env bash
# pr_body_test.sh - Test runner for PR body update logic
#
# Iterates through test fixtures in .just/test/fixtures/pr_bodies/
# Each fixture directory contains: input.md, commits.txt, expected.md
#
# Exit code: 0 if all tests pass, 1 if any fail

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NORMAL='\033[0m'

# Find script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SCRIPT="$SCRIPT_DIR/update_pr_body.sh"
TEST_DIR="$SCRIPT_DIR/../test/fixtures/pr_bodies"

# Counters
PASSED=0
FAILED=0

# Verify library script exists
if [[ ! -f "$LIB_SCRIPT" ]]; then
    echo -e "${RED}Error: Library script not found: $LIB_SCRIPT${NORMAL}" >&2
    exit 1
fi

# Verify test directory exists
if [[ ! -d "$TEST_DIR" ]]; then
    echo -e "${RED}Error: Test directory not found: $TEST_DIR${NORMAL}" >&2
    exit 1
fi

# Count test cases
test_count=$(find "$TEST_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
if [[ $test_count -eq 0 ]]; then
    echo -e "${RED}Error: No test cases found in $TEST_DIR${NORMAL}" >&2
    exit 1
fi

echo -e "${BLUE}Running $test_count PR body update tests...${NORMAL}"
echo ""

# Run tests
for test_case in "$TEST_DIR"/*/; do
    test_name=$(basename "$test_case")
    echo -e "${BLUE}  Testing: $test_name${NORMAL}"

    # Check required files exist
    if [[ ! -f "$test_case/input.md" ]]; then
        echo -e "${RED}✗ $test_name - missing input.md${NORMAL}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ ! -f "$test_case/commits.txt" ]]; then
        echo -e "${RED}✗ $test_name - missing commits.txt${NORMAL}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ ! -f "$test_case/expected.md" ]]; then
        echo -e "${RED}✗ $test_name - missing expected.md${NORMAL}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Run test
    actual=$(mktemp)
    if ! "$LIB_SCRIPT" "$test_case/input.md" "$test_case/commits.txt" > "$actual" 2>&1; then
        echo -e "${RED}✗ $test_name - script failed${NORMAL}"
        FAILED=$((FAILED + 1))
        rm "$actual" || true
        continue
    fi

    # Compare output
    if diff -u "$test_case/expected.md" "$actual" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ $test_name${NORMAL}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ $test_name${NORMAL}"
        echo "  Diff (expected vs actual):"
        diff -u "$test_case/expected.md" "$actual" | head -20 | sed 's/^/  /'
        echo ""
        FAILED=$((FAILED + 1))
    fi

    rm "$actual" || true
done

# Summary
echo ""
echo "================================"
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed! ($PASSED/$test_count)${NORMAL}"
    exit 0
else
    echo -e "${RED}Some tests failed: $FAILED failed, $PASSED passed ($test_count total)${NORMAL}"
    exit 1
fi
