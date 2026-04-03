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
# NOTE: This list must stay in sync with clean_template recipe in .just/clean-template.just
CLEANED_FILES=(
	".just/testing.just"
	".just/clean-template.just"
	".just/lib/pr_body_test.sh"
	".just/lib/template_sync_test.sh"
	".just/test"
	".github/workflows/pr-body-tests.yml"
	".github/workflows/checksums-verify.yml"
)

# Get list of all .just/*.just files
declare -a just_files
while IFS= read -r file; do
	just_files+=("$file")
done < <(git ls-files '.just/*.just' | sort)

# Get list of all .just/lib/*.sh files
declare -a lib_files
while IFS= read -r file; do
	lib_files+=("$file")
done < <(git ls-files '.just/lib/*.sh' | sort)

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
			if [[ " $seen_checksums " =~ " $checksum " ]]; then
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
