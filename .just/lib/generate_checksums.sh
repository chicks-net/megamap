#!/usr/bin/env bash
# Generate versioned checksums for .just/*.just and .just/lib/*.sh files from git history
set -euo pipefail

# shellcheck source=.just/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Check dependencies
for cmd in git jq; do
	if ! command -v "$cmd" &>/dev/null; then
		echo "Error: $cmd is required but not installed" >&2
		exit 1
	fi
done

# Files removed by clean_template (derived repos should skip these if missing)
# NOTE: This list must stay in sync with the _remove_template_files recipe in
# .just/clean-template.just. The drift guard below enforces that sync and
# fails checksums_generate on divergence (#381).
#
# Template-repo only: generate_checksums.sh runs only in fini-net/template-repo,
# so this list is intentionally not locally verifiable in derived repos - it
# names files (workflows, test scripts) that clean_template removes there, and
# their local absence is by design, not stray sync debris.
CLEANED_FILES=(
	"docs/template-repo-banner.png"
	".just/testing.just"
	".just/clean-template.just"
	".just/lib/pr_body_test.sh"
	".just/lib/template_sync_test.sh"
	".just/lib/cue_sync_test.sh"
	".just/lib/asciinema_cache_test.sh"
	".just/lib/repo_urls_test.sh"
	".just/lib/wait_for_copilot_test.sh"
	".just/lib/repo_toml_stub_test.sh"
	".just/lib/compliance_test.sh"
	".just/test"
	".github/workflows/pr-body-tests.yml"
	".github/workflows/checksums-verify.yml"
	".github/workflows/cue-sync-tests.yml"
	".github/workflows/template-sync.yml"
	".github/workflows/wait-for-copilot-tests.yml"
)

# Drift guard (#381): CLEANED_FILES must equal the set of quoted-literal
# paths the clean_template recipe removes. Editing either side without the
# other fails here at manifest generation, before a diverged CHECKSUMS.json
# can ship. Derived repos cannot run this check (clean_template removes
# clean-template.just), so it warns and skips there - see the header note
# above. All diagnostics go to stderr because stdout is the JSON manifest.
CLEAN_TEMPLATE_JUST="$(dirname "${BASH_SOURCE[0]}")/../clean-template.just"
if [[ ! -f "$CLEAN_TEMPLATE_JUST" ]]; then
	echo "Warning: $CLEAN_TEMPLATE_JUST not found - skipping CLEANED_FILES drift check (expected in derived repos)" >&2
else
	# Double-quoted literal rm paths from the recipe. The scan starts
	# from indented lines only - recipe bodies - so a column-0 comment
	# documenting the required form (the NOTE in clean-template.just)
	# cannot poison the set with example paths. Single-quoted or
	# unquoted arguments are not extracted, and a double-quoted variable
	# like "$VAR" extracts as literal text and is flagged, so removals
	# keep the literal path form the NOTE demands. Only the two named
	# in-place scratch files are excluded (justfile.tmp, .repo.toml.tmp),
	# so a real tracked path ending in .tmp still counts as drift. Both
	# scratch removals are unquoted today, so the exclusion currently
	# matches nothing - it is defense-in-depth for the day someone
	# quotes them, pinned live by the guard self-test in
	# template_sync_test.sh (review of #438)
	removed_paths=$(grep '^[[:space:]]' "$CLEAN_TEMPLATE_JUST" \
		| grep -oE 'rm -[a-z]+ "[^"]+"' \
		| grep -vE '"(justfile|\.repo\.toml)\.tmp"$' \
		| sed -E 's/^rm -[a-z]+ "//; s/"$//' \
		| sort -u) || removed_paths=""

	# A readable clean-template.just always removes template files, so an
	# empty extraction means a stale pattern or an unreadable file, not an
	# empty recipe. Failing here with a pointed message beats a row of
	# misleading listed-but-not-removed reports - and it is the only way
	# the guard could otherwise pass vacuously, both sides empty.
	if [[ -z "$removed_paths" ]]; then
		echo "Error: the drift guard extracted no rm paths from $CLEAN_TEMPLATE_JUST" >&2
		echo "  suspect a stale extraction pattern in this script (or an unreadable recipe file)" >&2
		exit 1
	fi

	listed_paths=$(printf '%s\n' "${CLEANED_FILES[@]}" | sort -u)

	only_listed=$(comm -23 <(printf '%s\n' "$listed_paths") <(printf '%s\n' "$removed_paths"))
	only_removed=$(comm -13 <(printf '%s\n' "$listed_paths") <(printf '%s\n' "$removed_paths"))

	if [[ -n "$only_listed" || -n "$only_removed" ]]; then
		echo "Error: CLEANED_FILES is out of sync with the clean_template recipe ($CLEAN_TEMPLATE_JUST)" >&2
		while IFS= read -r path; do
			if [[ -n "$path" ]]; then
				echo "  listed in CLEANED_FILES but not removed by clean_template: $path" >&2
			fi
		done <<<"$only_listed"
		while IFS= read -r path; do
			if [[ -n "$path" ]]; then
				echo "  removed by clean_template but not listed in CLEANED_FILES: $path" >&2
			fi
		done <<<"$only_removed"
		echo "Update CLEANED_FILES above and the rm lines in _remove_template_files to match each other" >&2
		exit 1
	fi
fi

# Version-drift guard (Claude review of #442, item 2): CLAUDE.md names
# the '# PR create vX.Y' header in gh-process.just as the module's
# version bump, and that header has drifted before - stuck at v10.9
# through v10.10 and v11.0, with earlier drifts recorded in
# RELEASE_NOTES at v5.4 and v6.10. Fail generation when the header
# disagrees with the newest RELEASE_NOTES.md entry (the first
# '### vX.Y' heading - entries are newest-first), so a bump cannot
# mint a manifest while the documented header is stale. Derived repos
# do not carry RELEASE_NOTES.md (it is not CHECKSUMS-tracked), so a
# missing input skips silently: that skip is by design, not drift.
# All diagnostics go to stderr because stdout is the JSON manifest.
GH_PROCESS_JUST="$(dirname "${BASH_SOURCE[0]}")/../gh-process.just"
RELEASE_NOTES_MD="$(dirname "${BASH_SOURCE[0]}")/../RELEASE_NOTES.md"
if [[ -f "$GH_PROCESS_JUST" && -f "$RELEASE_NOTES_MD" ]]; then
	pr_create_version=$(sed -n 's/^# PR create \(v[0-9][0-9.]*\)$/\1/p' "$GH_PROCESS_JUST" | head -1)
	notes_version=$(sed -n 's/^### \(v[0-9][0-9.]*\).*/\1/p' "$RELEASE_NOTES_MD" | head -1)
	if [[ -z "$pr_create_version" || -z "$notes_version" ]]; then
		echo "Warning: could not read the '# PR create vX.Y' header or the newest RELEASE_NOTES.md entry - skipping version drift check" >&2
	elif [[ "$pr_create_version" != "$notes_version" ]]; then
		echo "Error: .just/gh-process.just says '# PR create $pr_create_version' but the newest RELEASE_NOTES.md entry is $notes_version" >&2
		echo "  CLAUDE.md names the '# PR create vX.Y' header as the version bump - change only its version digits (or fix the notes entry)" >&2
		exit 1
	fi
fi

# Get list of all .just/*.just files
declare -a just_files
while IFS= read -r file; do
	just_files+=("$file")
done < <(git ls-files '.just/*.just' ':(exclude).just/test/**' | sort)

# Get list of all .just/lib/*.sh and .just/lib/*.awk files
# (.awk files are included so shared awk programs like cue_sync.awk are
# CHECKSUMS-tracked and flow through just update_from_template. See #196.)
declare -a lib_files
while IFS= read -r file; do
	lib_files+=("$file")
done < <(git ls-files '.just/lib/*.sh' '.just/lib/*.awk' | sort)

# Combine all tracked files
all_files=("${just_files[@]}" "${lib_files[@]}")

if [[ ${#all_files[@]} -eq 0 ]]; then
	echo "Error: No .just files found" >&2
	exit 1
fi

# Start JSON output
cat <<EOF
{
  "schema_version": "1.0",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "template_repo": "https://github.com/fini-net/template-repo",
  "files": {
EOF

first_file=true

for filepath in "${all_files[@]}"; do
	# Add comma before all but first entry
	if [[ "$first_file" == true ]]; then
		first_file=false
	else
		echo ","
	fi

	echo -n "    \"$filepath\": {"
	echo -n "\"versions\": ["

	# Get all commits that touched this file, newest first
	seen_checksums=""
	first_version=true
	first_commit=true

	while IFS='|' read -r commit_hash commit_date commit_subject; do
		# Checkout the file at this commit (to a temp location)
		temp_file=$(mktemp)
		if git show "$commit_hash:$filepath" >"$temp_file" 2>/dev/null; then
			checksum=$(compute_checksum "$temp_file")
			rm "$temp_file"

			# Skip if we've seen this checksum before (deduplicate)
			if [[ " $seen_checksums " == *" $checksum "* ]]; then
				continue
			fi
			seen_checksums="$seen_checksums $checksum"

			# Extract version from commit subject (e.g., "v5.1" or "[just] v5.1")
			version=""
			if [[ "$commit_subject" =~ v[0-9]+\.[0-9]+ ]]; then
				version="${BASH_REMATCH[0]}"
			fi

			# Add comma before all but first version
			if [[ "$first_version" == true ]]; then
				first_version=false
			else
				echo -n ","
			fi

			# Determine if this is the latest version (first in list)
			is_latest="$first_commit"
			first_commit=false

			# Output version entry
			cat <<EOF

        {
          "checksum": "$checksum",
          "commit": "$commit_hash",
          "date": "$commit_date",
          "version": "$version",
          "is_latest": $is_latest
        }
EOF
		else
			rm -f "$temp_file"
		fi
	done < <(git log --format="%H|%aI|%s" --follow -- "$filepath")

	echo -n "]}"
done

# Close files object and add cleaned_files array
cat <<EOF

  },
  "cleaned_files": [
$(for i in "${!CLEANED_FILES[@]}"; do
	if [[ $i -gt 0 ]]; then
		echo -n ",
"
	fi
	echo -n "    \"${CLEANED_FILES[$i]}\""
done)
  ]
}
EOF
