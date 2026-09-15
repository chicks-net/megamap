#!/usr/bin/env bash
# Test suite for template synchronization system
#
# Two fixture modes share this runner:
#
#   - update-script mode (legacy, fixtures 01-04): drives a patched copy of
#     template_update.sh with a mocked curl, as before
#   - recipe mode (fixtures 05+): drives the actual `just checksums_verify`
#     / `checksums_diff` recipes in a temp workspace holding a copy of the
#     real .just/template-sync.just, so the validate_filepath gates that
#     live in the recipe bodies are exercised too (#354 - flagged as a
#     coverage gap in the Claude review of #352, since template_update.sh
#     tests never touch the recipe-level gates)
#
# Fixture layout is shared: input/, manifest.json, template_versions/,
# expected_output.txt, expected_state/. Recipe fixtures add:
#
#   recipe         - required: recipe to run, first word is the recipe name
#                     and remaining words are its arguments (e.g.
#                     "checksums_verify" or "checksums_diff ../evil.txt")
#   expected_exit  - optional: expected exit code (default 0 for recipe
#                     mode; update-script mode ignores failures as before)
#   modules        - optional: space-separated .just module basenames to
#                     copy into the workspace and import (default:
#                     "template-sync"; e.g. "gh-process" or "claude
#                     template-sync"). Each module's import line lands in
#                     the scaffolded justfile.
#   bare_justfile  - optional: any content; when present the scaffolded
#                     workspace justfile omits `set positional-arguments
#                     := true`, exactly mirroring a derived repo whose
#                     root justfile never ships (#368). Pins the
#                     invariant: tracked modules must be self-contained -
#                     no recipe may depend on root-justfile configuration
#                     that doesn't ship (#367).
#   shims/         - optional: executable scripts copied into the
#                     workspace and prepended to PATH, shadowing both the
#                     harness's mock curl and real tools (the same PATH
#                     shim precedent wait_for_copilot_test.sh uses for
#                     gh/sleep). Fixture shims win over the harness mock
#                     because the whole workspace dir sits first on PATH.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

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

	# Absolutize before we cd into the workspace, so fixture checks
	# below still resolve after the working directory changes
	test_dir="$(cd "$test_dir" && pwd)"

	# Recipe mode (#354): drive the real just recipes. Falls back to a
	# yellow skip (counted as a failure so the gap stays visible) when
	# just is not installed.
	if [[ -f "$test_dir/recipe" ]]; then
		run_recipe_test "$test_name" "$test_dir"
		return
	fi

	run_update_test "$test_name" "$test_dir"
}

# Write the shared mock curl into a target directory. Contract:
#   - any call with -o writes to the given output file
#   - a URL ending in .just/CHECKSUMS.json serves the fixture manifest
#   - any other URL serves template_versions/<basename> if present
# Both the recipe-mode and update-script-mode mocks must honor this
# exact contract, so it lives in one place (Claude review of #360,
# finding 2 - it was two copy-pasted heredocs that could drift).
write_mock_curl() {
	local target_dir="$1"
	local mock_curl="$target_dir/curl"
	cat > "$mock_curl" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock curl for testing
if [[ "$*" == *"-o"* ]]; then
	# Extract output file: the argument after -o
	output_file=""
	next=0
	for arg in "$@"; do
		if [[ "$next" == 1 ]]; then
			output_file="$arg"
			break
		fi
		if [[ "$arg" == "-o" ]]; then
			next=1
		fi
	done
	# The URL is the last non-flag argument
	source_path=""
	for arg in "$@"; do
		if [[ "$arg" != -* && "$arg" != "$output_file" ]]; then
			source_path="$arg"
		fi
	done
	if [[ "$source_path" == *".just/CHECKSUMS.json" ]]; then
		manifest_path="${BASH_SOURCE[0]%/*}/manifest.json"
		if [[ -f "$manifest_path" ]]; then
			# The update-script mode points MANIFEST_FILE straight at
			# this fixture-copied manifest (sed patch), so source and
			# destination can be the same file - cat-ing a file onto
			# itself would truncate it. No-op in that case.
			if [[ ! "$manifest_path" -ef "$output_file" ]]; then
				cat "$manifest_path" > "$output_file"
			fi
			exit 0
		fi
		exit 1
	fi
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
}

# Recipe mode: run the real `just <recipe> <args...>` inside a temp
# workspace that mirrors a derived repo (minimal justfile importing a
# copy of the real template-sync.just + common.sh), with mocked curl
# serving the fixture manifest/template versions.
run_recipe_test() {
	local test_name="$1"
	local test_dir="$2"

	if ! command -v just &>/dev/null; then
		echo -e "${YELLOW}!${NORMAL} $test_name - just not installed, recipe gate untested"
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

	# Scaffold a minimal derived-repo justfile importing the real modules.
	# Fixture `modules` picks which (default: template-sync); fixture
	# `bare_justfile` drops the `set positional-arguments` line so the
	# workspace mirrors a derived repo's justfile exactly (#367/#368)
	local module_list="template-sync"
	if [[ -f "$test_dir/modules" ]]; then
		if [[ ! -s "$test_dir/modules" ]]; then
			echo -e "${RED}✗${NORMAL} $test_name - modules file is empty"
			rm -rf "$workspace"
			(( failed += 1 ))
			return
		fi
		module_list=$(cat "$test_dir/modules")
	fi
	mkdir -p "$workspace/.just/lib"
	local module
	for module in $module_list; do
		if [[ ! -f "$SCRIPT_DIR/../$module.just" ]]; then
			echo -e "${RED}✗${NORMAL} $test_name - unknown module: $module"
			rm -rf "$workspace"
			(( failed += 1 ))
			return
		fi
		cp "$SCRIPT_DIR/../$module.just" "$workspace/.just/"
	done
	cp "$SCRIPT_DIR/common.sh" "$workspace/.just/lib/"
	{
		if [[ ! -f "$test_dir/bare_justfile" ]]; then
			echo "set positional-arguments := true"
		fi
		for module in $module_list; do
			echo "import '.just/$module.just'"
		done
	} > "$workspace/justfile"

	# Mock curl serving fixture data (shared contract - see write_mock_curl)
	write_mock_curl "$workspace"

	# Fixture shims: copied in executable and prepended to PATH below,
	# ahead of the harness mock curl (whole-workspace dir first on PATH)
	if [[ -d "$test_dir/shims" ]]; then
		local shim
		for shim in "$test_dir"/shims/*; do
			[[ -f "$shim" ]] || continue
			cp "$shim" "$workspace/"
			chmod +x "$workspace/$(basename "$shim")"
		done
	fi

	# Copy manifest + template versions (curl mock resolves these)
	[[ -f "$test_dir/manifest.json" ]] && cp "$test_dir/manifest.json" "$workspace/"
	if [[ -d "$test_dir/template_versions" ]]; then
		mkdir -p "$workspace/template_versions"
		cp -r "$test_dir/template_versions/"* "$workspace/template_versions/" 2>/dev/null || true
	fi

	# Parse the recipe line: first word = recipe name, rest = arguments.
	# Guard against an empty recipe file under set -u.
	local recipe_name recipe_line=()
	if [[ ! -s "$test_dir/recipe" ]]; then
		echo -e "${RED}✗${NORMAL} $test_name - recipe file is empty"
		rm -rf "$workspace"
		(( failed += 1 ))
		return
	fi
	read -r -a recipe_line <<< "$(cat "$test_dir/recipe")"
	recipe_name="${recipe_line[0]}"
	local recipe_args=("${recipe_line[@]:1}")

	# Run the recipe with the workspace first on PATH (fixture shims
	# shadow both the harness mock curl and real tools). The if/else
	# branch keeps empty-argument recipes working under set -u on bash
	# 3.2 (macOS), where "empty_array[@]" is an unbound-variable error.
	cd "$workspace"
	local output actual_exit=0
	if [[ ${#recipe_args[@]} -gt 0 ]]; then
		output=$(PATH="$workspace:$PATH" just "$recipe_name" "${recipe_args[@]}" 2>&1) \
			|| actual_exit=$?
	else
		output=$(PATH="$workspace:$PATH" just "$recipe_name" 2>&1) \
			|| actual_exit=$?
	fi

	# Expected exit code (default 0)
	local expected_exit=0
	if [[ -f "$test_dir/expected_exit" ]]; then
		expected_exit=$(cat "$test_dir/expected_exit")
	fi

	# Check expected output if provided (same normalization + in-order
	# matching as update-script mode)
	local output_ok=true
	if [[ -f "$test_dir/expected_output.txt" ]]; then
		local normalized_output
		normalized_output=$(echo "$output" | LC_ALL=C awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' | \
			grep -v "^$" | \
			sed 's|/tmp/[^[:space:]]*||g')

		local expected_lines=()
		local line
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -n "$line" ]] && expected_lines+=("$line")
		done < "$test_dir/expected_output.txt"

		if [[ ${#expected_lines[@]} -eq 0 ]]; then
			echo -e "${YELLOW}!${NORMAL} $test_name - expected_output.txt is empty, output not checked"
		fi
		local search_start=1
		for line in "${expected_lines[@]}"; do
			local line_num
			# -e: expected lines may start with dashes (e.g. diff output).
			# grep exits 1 when the line is missing - a handled case here,
			# not a crash - but under `set -euo pipefail` the substitution
			# would abort the whole suite before the mismatch could be
			# reported (a latent harness bug surfaced by the bare-justfile
			# fixtures, #368, whose whole point is failing recipes). The
			# `|| true` guard keeps the loop alive; the -z check below
			# reports the mismatch.
			line_num=$(echo "$normalized_output" | grep -nF -e "$line" | awk -F: -v s="$search_start" '$1 >= s {print $1; exit}') \
				|| true
			if [[ -z "$line_num" ]]; then
				output_ok=false
				break
			fi
			search_start=$((line_num + 1))
		done
	fi

	# Check expected state if provided
	local state_ok=true
	if [[ -d "$test_dir/expected_state" ]]; then
		while IFS= read -r expected_file; do
			local rel_path="${expected_file#"$test_dir"/expected_state/}"
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
	local exit_ok=true
	[[ "$actual_exit" == "$expected_exit" ]] || exit_ok=false

	if [[ "$exit_ok" == true && "$output_ok" == true && "$state_ok" == true ]]; then
		echo -e "${GREEN}✓${NORMAL} $test_name"
		(( passed += 1 ))
	else
		echo -e "${RED}✗${NORMAL} $test_name"
		[[ "$exit_ok" == false ]] && echo "    Exit mismatch: expected $expected_exit, got $actual_exit"
		[[ "$output_ok" == false ]] && echo "    Output mismatch"
		[[ "$state_ok" == false ]] && echo "    State mismatch"
		(( failed += 1 ))
	fi
}

# Update-script mode (legacy): drive a patched copy of template_update.sh
run_update_test() {
	local test_name="$1"
	local test_dir="$2"

	# Create temp workspace
	local workspace
	workspace=$(mktemp -d)

	# Copy input files to workspace (including hidden files)
	if [[ -d "$test_dir/input" ]]; then
		shopt -s dotglob
		cp -r "$test_dir/input/"* "$workspace/" 2>/dev/null || true
		shopt -u dotglob
	fi

	# Mock curl to return fixture data (shared contract - see write_mock_curl)
	write_mock_curl "$workspace"

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
		# shellcheck disable=SC2016  # awk script is intentionally single-quoted
		normalized_output=$(echo "$output" | LC_ALL=C awk '{ gsub(/\033\[[0-9;]*m/, ""); print }' | \
			grep -v "^$" | \
			sed 's|/tmp/[^[:space:]]*||g')

		# Every non-empty expected line must appear in order in the output
		local expected_lines=()
		local line
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -n "$line" ]] && expected_lines+=("$line")
		done < "$test_dir/expected_output.txt"

		if [[ ${#expected_lines[@]} -eq 0 ]]; then
			echo -e "${YELLOW}!${NORMAL} $test_name - expected_output.txt is empty, output not checked"
		fi
		local search_start=1
		for line in "${expected_lines[@]}"; do
			local line_num
			# -e: expected lines may start with dashes (e.g. diff output).
			# grep exits 1 when the line is missing - a handled case here,
			# not a crash - but under `set -euo pipefail` the substitution
			# would abort the whole suite before the mismatch could be
			# reported (a latent harness bug surfaced by the bare-justfile
			# fixtures, #368, whose whole point is failing recipes). The
			# `|| true` guard keeps the loop alive; the -z check below
			# reports the mismatch.
			line_num=$(echo "$normalized_output" | grep -nF -e "$line" | awk -F: -v s="$search_start" '$1 >= s {print $1; exit}') \
				|| true
			if [[ -z "$line_num" ]]; then
				output_ok=false
				break
			fi
			search_start=$((line_num + 1))
		done
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
