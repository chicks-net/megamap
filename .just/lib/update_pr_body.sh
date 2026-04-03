#!/usr/bin/env bash
# update_pr_body.sh - Reliably update PR body Done section
#
# Usage: update_pr_body.sh <original_body_file> <new_commits_file>
# Outputs updated PR body to stdout
#
# Uses HTML comment markers for reliable section boundaries:
#   <!-- PR_BODY_DONE_START --> and <!-- PR_BODY_DONE_END -->
#
# Falls back to section header detection for backwards compatibility with old PRs

set -euo pipefail

# Arguments
BODY_FILE="${1:-}"
COMMITS_FILE="${2:-}"

if [[ -z "$BODY_FILE" || -z "$COMMITS_FILE" ]]; then
    echo "Usage: $0 <original_body_file> <new_commits_file>" >&2
    exit 1
fi

if [[ ! -f "$BODY_FILE" ]]; then
    echo "Error: Body file not found: $BODY_FILE" >&2
    exit 1
fi

if [[ ! -f "$COMMITS_FILE" ]]; then
    echo "Error: Commits file not found: $COMMITS_FILE" >&2
    exit 1
fi

# State machine states
BEFORE_DONE="before"
IN_DONE="in"
AFTER_DONE="after"

# Current state
state="$BEFORE_DONE"

# Code block tracking
in_code_block=false

# Accumulate content in these sections
header_content=()
footer_content=()

# Check if body uses new marker format
has_markers=false
if grep -q "<!-- PR_BODY_DONE_START -->" "$BODY_FILE" 2>/dev/null; then
    has_markers=true
fi

# Parse the original body
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"  # normalize CRLF: strip trailing carriage return
    # Track code blocks (triple backticks)
    if [[ "$line" =~ ^\`\`\` ]]; then
        if [[ "$in_code_block" == true ]]; then
            in_code_block=false
        else
            in_code_block=true
        fi
    fi

    # Parse markers/headers only outside code blocks
    if [[ "$in_code_block" == false ]]; then
        # Check for HTML markers (new format)
        if [[ "$line" == "<!-- PR_BODY_DONE_START -->" ]]; then
            state="$IN_DONE"
            continue
        elif [[ "$line" == "<!-- PR_BODY_DONE_END -->" ]]; then
            state="$AFTER_DONE"
            continue
        fi

        # Check for section headers (old format backwards compatibility)
        if [[ ! "$has_markers" == true && "$line" =~ ^##[[:space:]]+Done[[:space:]]*$ ]]; then
            state="$IN_DONE"
            continue
        elif [[ ! "$has_markers" == true && "$state" == "$IN_DONE" && "$line" =~ ^##[[:space:]]+ ]]; then
            # Any other section header after Done
            state="$AFTER_DONE"
        fi
    fi

    # Accumulate content based on state
    case "$state" in
        "$BEFORE_DONE")
            header_content+=("$line")
            ;;
        "$IN_DONE")
            # Skip old Done section content - will be replaced
            ;;
        "$AFTER_DONE")
            footer_content+=("$line")
            ;;
    esac
done < "$BODY_FILE"

# If no Done section was found, split header at first section header
if [[ "$state" == "$BEFORE_DONE" && ${#header_content[@]} -gt 0 ]]; then
    # Find first section header
    first_section_idx=-1
    for i in "${!header_content[@]}"; do
        if [[ "${header_content[$i]}" =~ ^##[[:space:]]+ ]]; then
            first_section_idx=$i
            break
        fi
    done

    # If found, move everything from first section onwards to footer
    if [[ $first_section_idx -ge 0 ]]; then
        footer_content=("${header_content[@]:$first_section_idx}")
        header_content=("${header_content[@]:0:$first_section_idx}")
    fi
fi

# Output the updated PR body
# 1. Header content (everything before Done)
if [[ ${#header_content[@]} -gt 0 ]]; then
    for line in "${header_content[@]}"; do
        echo "$line"
    done
fi

# 2. Done section with markers
echo "<!-- PR_BODY_DONE_START -->"
echo "## Done"
echo ""
cat "$COMMITS_FILE"
echo ""
echo "<!-- PR_BODY_DONE_END -->"

# 3. Footer content (everything after Done)
if [[ ${#footer_content[@]} -gt 0 ]]; then
    # Add blank line before footer if first line isn't already blank
    if [[ -n "${footer_content[0]}" ]]; then
        echo ""
    fi
    for line in "${footer_content[@]}"; do
        echo "$line"
    done
fi
