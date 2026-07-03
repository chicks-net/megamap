#!/usr/bin/env bash
# Test suite for cue-sync-from-github awk logic
#
# Verifies that the awk block in .just/cue-verify.just correctly handles
# missing, commented, and active keys in the [about] section of .repo.toml,
# and that inserted keys land *inside* the [about] block (before any trailing
# blank line), not after it (which would visually attach them to the next
# [section] header). See issue #165 and PR #175.
set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NORMAL='\033[0m'

readonly FIXTURES_DIR=".just/test/fixtures/cue_sync"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# Path to the shared awk program extracted from the cue-sync-from-github
# recipe. Both the recipe (in .just/cue-verify.just) and this test runner
# invoke the same file via `awk -f`, so a change to the awk is exercised by
# both paths automatically. See issue #196.
readonly AWK_PROGRAM="$REPO_ROOT/.just/lib/cue_sync.awk"

passed=0
failed=0

run_awk() {
	local input="$1" desc="$2" topics="$3"
	# Pass description via the environment (desc=...), not awk's -v, because
	# -v processes backslash escape sequences before the program runs. The
	# awk program applies TOML-escaping on emit, so callers pass the raw
	# description unmodified. See issue #198.
	desc="$desc" awk -v topics="[$topics]" -f "$AWK_PROGRAM" "$input"
}

# Assert helpers - count failures via a global flag
assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [[ "$expected" != "$actual" ]]; then
		echo "    ${RED}assertion failed:${NORMAL} $label"
		echo "      expected: $expected"
		echo "      actual:   $actual"
		return 1
	fi
	return 0
}

# Verify a given key line appears inside the [about] block, i.e. there is no
# blank line between it and the preceding non-blank [about] content, and it
# appears before the next [section] header.
# Args: output_file key_pattern
assert_key_inside_about() {
	local output="$1" key_pat="$2"
	local key_line section_line
	key_line=$(grep -nE "$key_pat" "$output" | head -1 | cut -d: -f1 || true)
	# Find the next non-[about] section header. grep -n emits "N:content";
	# filter on the content after the colon so [about] itself is excluded.
	section_line=$(grep -nE '^\[' "$output" | grep -v '^[0-9]*:\[about\]' | head -1 | cut -d: -f1 || true)
	if [[ -z "$key_line" ]]; then
		echo -e "    ${RED}assertion failed:${NORMAL} key matching /$key_pat/ not found"
		return 1
	fi
	if [[ -n "$section_line" && "$key_line" -ge "$section_line" ]]; then
		echo -e "    ${RED}assertion failed:${NORMAL} key at line $key_line is at or after next section at line $section_line"
		return 1
	fi
	# Find the nearest preceding non-blank line and confirm it is not separated
	# by a blank line (i.e. the inserted key is adjacent to the prior key).
	local prev_nonblank=0
	local i=$((key_line - 1))
	while [[ $i -gt 0 ]]; do
		local line
		line=$(sed -n "${i}p" "$output")
		if [[ -n "$(echo "$line" | tr -d '[:space:]')" ]]; then
			prev_nonblank=$i
			break
		fi
		i=$((i - 1))
	done
	if [[ $((key_line - prev_nonblank)) -ne 1 ]]; then
		echo -e "    ${RED}assertion failed:${NORMAL} blank line(s) separate key (line $key_line) from preceding content (line $prev_nonblank)"
		return 1
	fi
	return 0
}

run_test() {
	local fixture="$1" desc="$2" topics="$3" key_pat="$4" expected_val="$5" label="$6"
	local fixture_path="$REPO_ROOT/$FIXTURES_DIR/$fixture"
	local result=0

	if [[ ! -f "$fixture_path" ]]; then
		echo -e "${RED}✗${NORMAL} $label - fixture not found: $fixture"
		(( failed += 1 ))
		return
	fi

	local workspace
	workspace=$(mktemp -d -t cue_sync_test.XXXXXX)
	cp "$fixture_path" "$workspace/.repo.toml"

	local output="$workspace/out.toml"
	run_awk "$workspace/.repo.toml" "$desc" "$topics" > "$output" || result=$?

	if [[ $result -ne 0 ]]; then
		echo -e "${RED}✗${NORMAL} $label - awk exited $result"
		rm -rf "$workspace"
		(( failed += 1 ))
		return
	fi

	local actual_val
	actual_val=$(grep -oE "$key_pat" "$output" | head -1 || true)

	local ok=true
	assert_eq "value for $label" "$expected_val" "$actual_val" || ok=false
	assert_key_inside_about "$output" "$key_pat" || ok=false

	if [[ "$ok" == true ]]; then
		echo -e "${GREEN}✓${NORMAL} $label"
		(( passed += 1 ))
	else
		echo "    --- output ---"
		sed 's/^/    /' "$output"
		echo "    --- end ---"
		(( failed += 1 ))
	fi

	rm -rf "$workspace"
}

main() {
	echo -e "${BLUE}Running cue-sync-from-github tests...${NORMAL}"
	echo

	if [[ ! -d "$REPO_ROOT/$FIXTURES_DIR" ]]; then
		echo -e "${YELLOW}No test fixtures found at $FIXTURES_DIR${NORMAL}"
		echo "Tests skipped"
		return 0
	fi

	local desc="Automated GitHub workflow template: community standards, just recipes for PR lifecycle, AI reviews (Copilot/Claude),   and template sync system"
	local topics='"compliance", "github", "github-repository", "template", "template-generic-repo", "template-repository"'

	# Case 1: missing description -> inserted inside [about], before blank line
	run_test "missing_description.toml" "$desc" "$topics" \
		'description = "[^"]*"' "description = \"$desc\"" \
		"missing description inserted inside [about]"

	# Case 2: commented description -> replaced in place, inside [about]
	run_test "commented_description.toml" "$desc" "$topics" \
		'description = "[^"]*"' "description = \"$desc\"" \
		"commented description replaced inside [about]"

	# Case 3: missing topics -> inserted inside [about], before blank line
	run_test "missing_topics.toml" "$desc" "$topics" \
		'topics = \[[^]]*\]' "topics = [$topics]" \
		"missing topics inserted inside [about]"

	# Case 4: commented topics -> replaced in place, inside [about]
	# This is the headline fix for issue #165 and previously had no test.
	run_test "commented_topics.toml" "$desc" "$topics" \
		'topics = \[[^]]*\]' "topics = [$topics]" \
		"commented topics replaced inside [about]"

	# Case 5: happy path - both keys active -> replaced in place, inside [about]
	# Regression guard against any future awk change silently breaking the
	# pre-existing in-place replace behaviour. Asserts both keys in two calls
	# since run_test takes a single key assertion.
	run_test "active_keys.toml" "$desc" "$topics" \
		'description = "[^"]*"' "description = \"$desc\"" \
		"active description replaced inside [about]"
	run_test "active_keys.toml" "$desc" "$topics" \
		'topics = \[[^]]*\]' "topics = [$topics]" \
		"active topics replaced inside [about]"

	# Case 6: backslashes in description must survive the sync and produce
	# valid TOML. The description is passed raw via the environment; the awk
	# program TOML-escapes backslashes (-> \\) and double-quotes (-> \") on
	# emit. Asserting the escaped form verifies both that -v mangling is
	# avoided (would have lost backslashes entirely) and that the output is
	# valid TOML (a raw `\p` would fail cue vet). See #198.
	local bs_desc='C:\path\to\thing'
	local bs_desc_toml='C:\\path\\to\\thing'
	run_test "active_keys.toml" "$bs_desc" "$topics" \
		'description = "[^"]*"' "description = \"$bs_desc_toml\"" \
		"backslashes in description preserved and TOML-escaped (issue #198)"

	echo
	echo -e "Results: ${GREEN}$passed passed${NORMAL}, ${RED}$failed failed${NORMAL}"

	if [[ $failed -gt 0 ]]; then
		exit 1
	fi
}

main "$@"
