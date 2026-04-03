#!/usr/bin/env bash
# Core update logic for template synchronization
set -euo pipefail

# shellcheck source=.just/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Color constants (matching just's colors)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NORMAL='\033[0m'

readonly TEMPLATE_URL="https://raw.githubusercontent.com/fini-net/template-repo/main"
readonly MANIFEST_URL="$TEMPLATE_URL/.just/CHECKSUMS.json"
readonly MANIFEST_FILE=$(mktemp)
readonly MAX_RETRIES=3
readonly RETRY_DELAY=2

# Counters
updated_count=0
skipped_modified_count=0
skipped_current_count=0
skipped_cleaned_count=0
downloaded_new_count=0
failed_count=0

# Check dependencies
check_dependencies() {
	local missing=()
	for cmd in curl jq; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		echo -e "${RED}Error: Missing required tools: ${missing[*]}${NORMAL}" >&2
		exit 1
	fi
}

# Fetch manifest with retries
fetch_manifest() {
	local -r max=$MAX_RETRIES
	local attempt=1

	echo "Fetching manifest from template-repo..."

	while [[ $attempt -le $max ]]; do
		if curl -sSL -f "$MANIFEST_URL" -o "$MANIFEST_FILE" 2>/dev/null; then
			# Validate JSON structure
			if ! jq -e '.schema_version' "$MANIFEST_FILE" >/dev/null 2>&1; then
				echo -e "${RED}Error: Invalid manifest format${NORMAL}" >&2
				rm -f "$MANIFEST_FILE"
				exit 1
			fi
			return 0
		fi

		if [[ $attempt -lt $max ]]; then
			echo -e "${YELLOW}Fetch failed, retrying in ${RETRY_DELAY}s...${NORMAL}" >&2
			sleep $RETRY_DELAY
			((attempt++))
		else
			echo -e "${RED}Error: Failed to fetch manifest after $max attempts${NORMAL}" >&2
			exit 1
		fi
	done
}

# Download a file with verification
download_file() {
	local filepath="$1"
	local temp_file="${filepath}.tmp"
	local backup_file="${filepath}.pre-update-backup"
	local -r max=$MAX_RETRIES
	local attempt=1

	# Backup existing file
	if [[ -f "$filepath" ]]; then
		cp "$filepath" "$backup_file"
	fi

	while [[ $attempt -le $max ]]; do
		if curl -sSL -f "$TEMPLATE_URL/$filepath" -o "$temp_file" 2>/dev/null; then
			# Verify it's not empty
			if [[ ! -s "$temp_file" ]]; then
				echo -e "      ${RED}Downloaded file is empty${NORMAL}"
				rm -f "$temp_file"
				[[ -f "$backup_file" ]] && mv "$backup_file" "$filepath"
				return 1
			fi

			# Move into place and clean up
			mv "$temp_file" "$filepath"
			rm -f "$backup_file"

			# Make executable (except common.sh which is only sourced)
			if [[ "$(basename "$filepath")" != "common.sh" ]]; then
				chmod +x "$filepath"
			fi

			return 0
		fi

		if [[ $attempt -lt $max ]]; then
			sleep $RETRY_DELAY
			((attempt++))
		else
			echo -e "      ${RED}Download failed after $max attempts${NORMAL}"
			rm -f "$temp_file"
			[[ -f "$backup_file" ]] && mv "$backup_file" "$filepath"
			return 1
		fi
	done
}

# Process a single file
process_file() {
	local filepath="$1"

	# Check if this is a cleaned file (should be skipped if missing)
	local is_cleaned=false
	if jq -e --arg fp "$filepath" '.cleaned_files // [] | index($fp) != null' "$MANIFEST_FILE" >/dev/null 2>&1; then
		is_cleaned=true
	fi

	# Get versions array from manifest
	local versions_json
	versions_json=$(jq -r ".files[\"$filepath\"].versions // []" "$MANIFEST_FILE")

	if [[ "$versions_json" == "[]" ]]; then
		echo -e "  ${YELLOW}⚠${NORMAL} $filepath - not in manifest, skipping"
		return
	fi

	# Get latest version info
	local latest_checksum latest_version
	latest_checksum=$(echo "$versions_json" | jq -r '.[0].checksum')
	latest_version=$(echo "$versions_json" | jq -r '.[0].version')

	# Check if file exists locally
	if [[ ! -f "$filepath" ]]; then
		# If it's a cleaned file, skip it (intentionally removed)
		if [[ "$is_cleaned" == true ]]; then
			echo -e "  ${GREEN}⊘${NORMAL} $filepath - removed by clean_template, skipping"
			((skipped_cleaned_count++)) || true
			return
		fi
		echo -e "  ${BLUE}↓${NORMAL} $filepath - new file, downloading"
		if download_file "$filepath"; then
			echo -e "      ${GREEN}Downloaded successfully${NORMAL}"
			((downloaded_new_count++)) || true
		else
			((failed_count++)) || true
		fi
		return
	fi

	# Compute local checksum
	local local_checksum
	local_checksum=$(compute_checksum "$filepath")

	# Check if already at latest
	if [[ "$local_checksum" == "$latest_checksum" ]]; then
		echo -e "  ${GREEN}✓${NORMAL} $filepath - already at latest${NORMAL}"
		((skipped_current_count++)) || true
		return
	fi

	# Check if local checksum matches any known version
	local match_found=false
	local matched_version=""

	while read -r known_sum known_ver; do
		if [[ "$local_checksum" == "$known_sum" ]]; then
			match_found=true
			matched_version="$known_ver"
			break
		fi
	done < <(echo "$versions_json" | jq -r '.[] | "\(.checksum) \(.version)"')

	if [[ "$match_found" == false ]]; then
		echo -e "  ${YELLOW}⚠${NORMAL} $filepath - has local modifications, skipping"
		((skipped_modified_count++)) || true
		return
	fi

	# Update needed
	local version_info=""
	if [[ -n "$matched_version" && -n "$latest_version" ]]; then
		version_info=" ${matched_version} → ${latest_version}"
	fi

	echo -e "  ${BLUE}⬆${NORMAL} $filepath - updating${version_info}"
	if download_file "$filepath"; then
		echo -e "      ${GREEN}Updated successfully${NORMAL}"
		((updated_count++)) || true
	else
		((failed_count++)) || true
	fi
}

# Cleanup
cleanup() {
	rm -f "$MANIFEST_FILE"
	# Clean up any orphaned backup files older than 7 days
	find .just -name '*.pre-update-backup' -mtime +7 -delete 2>/dev/null || true
}

trap cleanup EXIT

# Main execution
main() {
	echo -e "${BLUE}Checking for template updates...${NORMAL}"
	echo

	check_dependencies
	fetch_manifest

	echo
	echo "Processing .just/*.just and .just/lib/*.sh files:"

	# Get list of files from manifest
	while IFS= read -r filepath; do
		process_file "$filepath"
	done < <(jq -r '.files | keys[]' "$MANIFEST_FILE")

	# Print summary
	echo
	echo "Summary:"
	[[ $updated_count -gt 0 ]] && echo -e "  ${GREEN}Updated: $updated_count file(s)${NORMAL}"
	[[ $downloaded_new_count -gt 0 ]] && echo -e "  ${BLUE}Downloaded (new): $downloaded_new_count file(s)${NORMAL}"
	[[ $skipped_modified_count -gt 0 ]] && echo -e "  ${YELLOW}Skipped (modified): $skipped_modified_count file(s)${NORMAL}"
	[[ $skipped_cleaned_count -gt 0 ]] && echo -e "  ${BLUE}Skipped (cleaned): $skipped_cleaned_count file(s)${NORMAL}"
	[[ $skipped_current_count -gt 0 ]] && echo "  Already current: $skipped_current_count file(s)"
	[[ $failed_count -gt 0 ]] && echo -e "  ${RED}Failed: $failed_count file(s)${NORMAL}"

	echo
	if [[ $failed_count -gt 0 ]]; then
		echo -e "${RED}Template sync completed with errors${NORMAL}"
		exit 1
	else
		echo -e "${GREEN}Template sync complete${NORMAL}"
	fi
}

main "$@"
