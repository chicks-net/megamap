# microsoft copilot justfile

# check out the RELEASE_NOTES.md for the detailed history of this file
# the README.md in this directory also might be useful to you

# Interactive Copilot suggestion picker
[group('Copilot')]
copilot_pick: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if gum is installed
    if ! command -v gum &>/dev/null; then
        echo "{{RED}}gum is not installed{{NORMAL}}"
        echo "{{YELLOW}}Install with: brew install gum (macOS){{NORMAL}}"
        echo "{{YELLOW}}Or see: https://github.com/charmbracelet/gum{{NORMAL}}"
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &>/dev/null; then
        echo "{{RED}}jq is not installed{{NORMAL}}"
        echo "{{YELLOW}}jq is required by gh CLI and should be installed{{NORMAL}}"
        echo "{{YELLOW}}Install with: brew install jq (macOS){{NORMAL}}"
        exit 1
    fi

    echo "🐈‍⬛😾 Fetching Copilot suggestions..."

    # Get PR metadata
    PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
    PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
    PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
    PR_NUMBER=$(echo "$PR_META" | jq '.number')

    # Fetch Copilot comments
    copilot_comments=$(mktemp /tmp/justfile.XXXXXX)

    # Note: GraphQL limits - fetches only the latest review (last: 1) and first 100 comments
    # Then filter to only Copilot reviews to ensure we only get the most recent Copilot feedback
    # This approach avoids potential GraphQL syntax issues with author filters
    # shellcheck disable=SC2016
    gh api graphql \
        -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
        --jq '[ .data.repository.pullRequest.reviews.nodes[] | select(.author.login=="copilot-pull-request-reviewer") | .comments.nodes[] ]' \
        -f query='
        query($name: String!, $owner: String!, $pr: Int!) {
            repository(owner: $owner, name: $name) {
                pullRequest(number: $pr) {
                    reviews(last: 1) {
                        nodes {
                            author {
                                resourcePath
                                login
                            }
                            comments(first: 100) {
                                nodes {
                                    body
                                    path
                                    originalLine
                                }
                            }
                        }
                    }
                }
            }
        }
        ' > "$copilot_comments"

    # Check if we have comments
    COMMENT_COUNT=$(jq 'length' "$copilot_comments")

    if [[ "$COMMENT_COUNT" -eq 0 ]]; then
        echo "{{BLUE}}No Copilot suggestions found{{NORMAL}}"
        exit 0
    fi

    echo "{{GREEN}}Found $COMMENT_COUNT Copilot suggestions{{NORMAL}}"
    echo ""

    # Format suggestions for gum display
    suggestions_display=$(mktemp /tmp/justfile.XXXXXX)
    trap 'rm -f "$copilot_comments" "$suggestions_display"' EXIT

    # Create display format: "file:line - preview"
    jq -r '.[] | "\(.path):\(.originalLine) - \(.body | split("\n")[0] | .[0:80])"' \
        "$copilot_comments" > "$suggestions_display"

    # Interactive selection with gum
    selected=$(gum choose \
        --header="Select a Copilot suggestion to view (or Ctrl+C to exit):" \
        --height=15 \
        < "$suggestions_display" || true)

    if [[ -z "$selected" ]]; then
        echo "{{BLUE}}Selection cancelled{{NORMAL}}"
        exit 0
    fi

    # Extract line number from selection to match back to original comment
    line_num=$(echo "$selected" | cut -d':' -f2 | cut -d' ' -f1)

    # Validate line number is numeric
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        echo "{{RED}}Error: Could not extract line number from selection{{NORMAL}}"
        exit 1
    fi

    # Get the full suggestion data
    suggestion_data=$(jq -r --arg line "$line_num" '.[] | select(.originalLine == ($line | tonumber))' "$copilot_comments")
    file_path=$(echo "$suggestion_data" | jq -r '.path')
    original_line=$(echo "$suggestion_data" | jq -r '.originalLine')
    suggestion_body=$(echo "$suggestion_data" | jq -r '.body')

    echo ""
    jq -r --arg line "$line_num" '.[] | select(.originalLine == ($line | tonumber)) |
        "{{GREEN}}File:{{NORMAL}} \(.path)\n{{GREEN}}Line:{{NORMAL}} \(.originalLine)\n\n\(.body)"' \
        "$copilot_comments"

    # Ask if user wants to apply the suggestion
    echo ""
    if gum confirm "Apply this suggestion?"; then
        # Extract code blocks from suggestion - improved extraction
        suggested_code=$(echo "$suggestion_body" | awk '
            BEGIN { in_block = 0; extracted = 0 }
            /^```/ {
                if (!in_block) {
                    in_block = 1
                    next  # Skip the opening ``` line
                } else {
                    extracted = 1
                    exit  # Exit after first complete block
                }
            }
            in_block { print }
        ')
        
        if [[ -n "$suggested_code" && -f "$file_path" ]]; then
            # Validate file path to prevent command injection
            if [[ ! "$file_path" =~ ^[a-zA-Z0-9/_.-][a-zA-Z0-9/_.-]*$ ]]; then
                echo "{{RED}}Error: Invalid file path characters in $file_path{{NORMAL}}"
                exit 1
            fi
            # Create backup with full path
            backup_dir=".just/copilot_backups"
            mkdir -p "$backup_dir"
            timestamp=$(date +%Y%m%d_%H%M%S)_$$
            # Store relative path from repo root for proper restoration
            relative_path=$(git ls-files --full-name "$file_path" 2>/dev/null || echo "$file_path")
            safe_path=${relative_path//\//_}
            backup_file="$backup_dir/${safe_path}_${timestamp}.bak"
            
            cp "$file_path" "$backup_file"
            echo "{{YELLOW}}Created backup: $backup_file{{NORMAL}}"
            
            # Show what will change - improved display
            echo "{{BLUE}}Will change:{{NORMAL}}"
            echo "File: $file_path"
            echo "Line: $original_line"
            
            # Get current content
            current_line=$(sed -n "${original_line}p" "$file_path")
            
            # Show diff-like output - use reliable line counting
            line_count=$(echo "$suggested_code" | wc -l | tr -d ' ')
            # Add 1 if the string doesn't end with newline
            if [[ ! "$suggested_code" =~ $'\n'$ ]]; then
                line_count=$((line_count + 1))
            fi
            
            if [[ $line_count -eq 1 ]]; then
                # Single line change
                echo "- $current_line"
                echo "+ $suggested_code"
            else
                # Multi-line change - show first line with indicator
                echo "- $current_line"
                echo "+ $(echo "$suggested_code" | head -1)"
                echo "  $line_count lines total"
            fi
            echo ""
            
            if gum confirm "Confirm this change?"; then
                # Apply the change - use temp file approach for multi-line safety
                # Use reliable line counting
                line_count=$(echo "$suggested_code" | wc -l | tr -d ' ')
                if [[ ! "$suggested_code" =~ $'\n'$ ]]; then
                    line_count=$((line_count + 1))
                fi
                
                # Check if this looks like a multi-line replacement by examining the suggestion body
                # Look for patterns that suggest replacing multiple lines
                replacement_lines=$(echo "$suggestion_body" | grep -i "replace\|change" | grep -o "lines\?[[:space:]]*[0-9]\+-[0-9]\+\|lines\?[[:space:]]*[0-9]\+" | head -1)
                
                if [[ $line_count -gt 1 ]] || [[ -n "$replacement_lines" ]]; then
                    # Multi-line: split file, insert new content, rejoin
                    # Currently we only replace one line as Copilot API doesn't provide line ranges
                    # This treats multi-line suggestions as insertions at the specified line
                    echo "{{YELLOW}}Note: Multi-line suggestion will be inserted at line $original_line{{NORMAL}}"
                    head -n $((original_line - 1)) "$file_path" > "${file_path}.tmp"
                    echo "$suggested_code" >> "${file_path}.tmp"
                    tail -n +$((original_line + 1)) "$file_path" >> "${file_path}.tmp"
                    mv "${file_path}.tmp" "$file_path"
                else
                    # Single line: use sed with proper escaping
                    # shellcheck disable=SC2016
                    escaped_code=$(echo "$suggested_code" | sed 's|[][\\\.*^$()+?{|/]|\\&|g')
                    sed -i "${original_line}s|.*|${escaped_code}|" "$file_path"
                fi
                
                # Verify the change was applied successfully
                if [[ -s "$file_path" ]]; then
                    echo "{{GREEN}}✓ Successfully applied change to $file_path:$original_line{{NORMAL}}"
                    
                    # Offer to push changes
                    if gum confirm "Push changes to PR?"; then
                        if command -v just &>/dev/null; then
                            just again
                        else
                            git add "$file_path"
                            git commit -m "Apply Copilot suggestion to $file_path:$original_line"
                            git push
                        fi
                    fi
                else
                    # Restore from backup on failure
                    cp "$backup_file" "$file_path"
                    echo "{{RED}}✗ Failed to apply change - restored from backup{{NORMAL}}"
                fi
            else
                echo "{{BLUE}}Change cancelled{{NORMAL}}"
            fi
        else
            echo "{{YELLOW}}Could not extract code or file not found - manual application required{{NORMAL}}"
        fi
    fi

    rm -f "$copilot_comments" "$suggestions_display"

# Request a new Copilot review on current PR
[group('Copilot')]
copilot_refresh: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if jq is installed
    if ! command -v jq &>/dev/null; then
        echo "{{RED}}jq is not installed{{NORMAL}}"
        echo "{{YELLOW}}jq is required by gh CLI and should be installed{{NORMAL}}"
        echo "{{YELLOW}}Install with: brew install jq (macOS){{NORMAL}}"
        exit 1
    fi

    # Get PR metadata
    PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
    PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
    PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
    PR_NUMBER=$(echo "$PR_META" | jq -r '.number')
    REPO="${PR_REPO_OWNER}/${PR_REPO_NAME}"

    # Request Copilot review
    echo "🐈‍⬛ Requesting Copilot review on PR #${PR_NUMBER}..."

    if gh api --method POST "/repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
        -f "reviewers[]=copilot-pull-request-reviewer[bot]" &>/dev/null; then
        echo "{{GREEN}}✓ Copilot review requested successfully{{NORMAL}}"
    else
        echo "{{RED}}✗ Failed to request Copilot review{{NORMAL}}"
        echo "{{YELLOW}}This may indicate:{{NORMAL}}"
        echo "  - Copilot is not enabled for this repository/organization"
        echo "  - You don't have permission to request reviewers"
        exit 1
    fi

    # Wait for review completion
    MAX_WAIT=180  # 3 minutes
    POLL_INTERVAL=5
    INITIAL_DELAY=10  # Give Copilot time to start processing

    poll_for_review() {
        echo "{{BLUE}}Waiting ${INITIAL_DELAY}s for Copilot to start processing...{{NORMAL}}"
        sleep $INITIAL_DELAY
        
        elapsed=$INITIAL_DELAY
        while (( elapsed < MAX_WAIT )); do
            # Check for Copilot review using GraphQL - check both review existence and comments
            # shellcheck disable=SC2016
            copilot_data=$(gh api graphql \
                -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
                --jq '.data.repository.pullRequest.reviews.nodes[] | select(.author.login=="copilot-pull-request-reviewer") | {state: .state, commentCount: (.comments.totalCount)}' \
                -f query='
                query($name: String!, $owner: String!, $pr: Int!) {
                    repository(owner: $owner, name: $name) {
                        pullRequest(number: $pr) {
                            reviews(last: 1) {
                                nodes {
                                    author {
                                        login
                                    }
                                    state
                                    comments {
                                        totalCount
                                    }
                                }
                            }
                        }
                    }
                }
                ' 2>/dev/null)

            if [[ -n "$copilot_data" ]]; then
                # Extract review state and comment count
                review_state=$(echo "$copilot_data" | jq -r '.state // "UNKNOWN"')
                comment_count=$(echo "$copilot_data" | jq -r '.commentCount // 0')
                
                # Consider review complete if we have a state and comments
                if [[ "$review_state" != "null" && "$review_state" != "UNKNOWN" ]] && [[ "$comment_count" -gt 0 ]]; then
                    echo "{{GREEN}}Review complete after ${elapsed}s (state: $review_state, $comment_count comments){{NORMAL}}"
                    return 0
                elif [[ "$review_state" != "null" && "$review_state" != "UNKNOWN" ]]; then
                    echo "{{YELLOW}}Review found but still processing (state: $review_state, $comment_count comments){{NORMAL}}"
                fi
            fi

            sleep $POLL_INTERVAL
            elapsed=$((elapsed + POLL_INTERVAL))

            # Only show dots if not using gum
            if [ "${USING_GUM:-0}" = "0" ]; then
                echo -n "."
            fi
        done

        echo ""
        echo "{{YELLOW}}Review not completed after ${MAX_WAIT}s - it may still be processing{{NORMAL}}"
        return 1
    }

    # Use gum spin if available, otherwise fall back to simple progress
    if command -v gum &> /dev/null; then
        USING_GUM=1 gum spin --spinner dot --title "Waiting for Copilot review..." -- bash -c "MAX_WAIT=$MAX_WAIT; POLL_INTERVAL=$POLL_INTERVAL; PR_REPO_OWNER='$PR_REPO_OWNER'; PR_REPO_NAME='$PR_REPO_NAME'; PR_NUMBER='$PR_NUMBER'; $(declare -f poll_for_review); poll_for_review"
        review_ready=$?
    else
        echo "{{BLUE}}Waiting for Copilot review...{{NORMAL}}"
        USING_GUM=0 poll_for_review
        review_ready=$?
    fi

    if [[ $review_ready -eq 0 ]]; then
        echo ""
        echo "{{GREEN}}Review complete!{{NORMAL}}"

        # Count suggestions using GraphQL
        # shellcheck disable=SC2016
        COPILOT_COUNT=$(gh api graphql \
            -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
            --jq '[ .data.repository.pullRequest.reviews.nodes[] | select(.author.login=="copilot-pull-request-reviewer") | .comments.nodes[] ] | length' \
            -f query='
            query($name: String!, $owner: String!, $pr: Int!) {
                repository(owner: $owner, name: $name) {
                    pullRequest(number: $pr) {
                        reviews(last: 1) {
                            nodes {
                                author {
                                    login
                                }
                                comments(first: 100) {
                                    nodes {
                                        body
                                        path
                                        originalLine
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ')

        if [[ $COPILOT_COUNT -gt 0 ]]; then
            echo "🐈‍⬛ Found ${COPILOT_COUNT} Copilot suggestions"
            echo ""
            echo "To browse interactively:"
            echo "  {{GREEN}}just copilot_pick{{NORMAL}}"
        else
            echo "🐈‍⬛ No suggestions - looks good!"
        fi
    else
        echo "{{YELLOW}}Review may still be processing (waited ${MAX_WAIT}s total). Options:{{NORMAL}}"
        echo "  {{GREEN}}just copilot_pick{{NORMAL}} (check if suggestions are ready)"
        echo "  {{GREEN}}just copilot_refresh{{NORMAL}} (wait longer for completion)"
    fi

# Restore from Copilot backup
[group('Copilot')]
copilot_rollback:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if gum is installed
    if ! command -v gum &>/dev/null; then
        echo "{{RED}}gum is not installed{{NORMAL}}"
        echo "{{YELLOW}}Install with: brew install gum (macOS){{NORMAL}}"
        echo "{{YELLOW}}Or see: https://github.com/charmbracelet/gum{{NORMAL}}"
        exit 1
    fi

    BACKUP_DIR=".just/copilot_backups"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "{{YELLOW}}No backup directory found{{NORMAL}}"
        exit 0
    fi

    # List available backups
    if ! ls "$BACKUP_DIR"/*.bak &>/dev/null; then
        echo "{{YELLOW}}No backups found{{NORMAL}}"
        exit 0
    fi

    echo "{{BLUE}}Available backups:{{NORMAL}}"
    backups=()
    backup_targets=()
    i=1
    
    for backup in "$BACKUP_DIR"/*.bak; do
        if [[ -f "$backup" ]]; then
            filename=$(basename "$backup")
            timestamp=${filename##*_}
            timestamp=${timestamp%.bak}
            # Convert safe path back to original file path
            safe_path=${filename%_*}
            target_file=${safe_path//_/\/}
            # Validate the reconstructed path doesn't escape repo root
            if [[ "$target_file" =~ ^\.\./|/\.\./|\.\.$ ]] || [[ "$target_file" =~ ^/ ]]; then
                echo "{{RED}}Warning: Skipping invalid backup path: $target_file{{NORMAL}}"
                continue
            fi
            # Additional validation: resolve to absolute path and verify it's under repo root
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            target_abs=$(cd "$(dirname "$target_file")" && pwd)/$(basename "$target_file") 2>/dev/null || true
            if [[ -n "$target_abs" && ! "$target_abs" =~ ^$repo_root/ ]]; then
                echo "{{RED}}Warning: Skipping backup path outside repo: $target_file{{NORMAL}}"
                continue
            fi
            backups+=("$backup")
            backup_targets+=("$target_file")
            echo "  $i) $target_file (backup: $timestamp)"
            ((i++))
        fi
    done

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "{{YELLOW}}No valid backups found{{NORMAL}}"
        exit 0
    fi

    echo ""
    echo -n "{{BLUE}}Select backup to restore (1-${#backups[@]}) or Ctrl+C to cancel:{{NORMAL}} "
    read -r selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 || "$selection" -gt ${#backups[@]} ]]; then
        echo "{{RED}}Invalid selection{{NORMAL}}"
        exit 1
    fi

    selected_backup="${backups[$((selection-1))]}"
    target_file="${backup_targets[$((selection-1))]}"

    echo "{{BLUE}}Will restore:{{NORMAL}}"
    echo "  Backup: $selected_backup"
    echo "  Target: $target_file"
    echo ""

    # Validate backup integrity
    if [[ ! -r "$selected_backup" ]]; then
        echo "{{RED}}✗ Backup file is not readable{{NORMAL}}"
        exit 1
    fi

    if [[ ! -s "$selected_backup" ]]; then
        echo "{{RED}}✗ Backup file is empty{{NORMAL}}"
        exit 1
    fi

    # Check if target file exists and has uncommitted changes
    if [[ -f "$target_file" ]] && command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
        if ! git diff --quiet "$target_file" 2>/dev/null; then
            echo "{{YELLOW}}⚠ Target file has uncommitted changes{{NORMAL}}"
            if ! gum confirm "Overwrite uncommitted changes?"; then
                echo "{{BLUE}}Restore cancelled{{NORMAL}}"
                exit 0
            fi
        fi
    fi

    if gum confirm "Restore this backup?"; then
        cp "$selected_backup" "$target_file"
        echo "{{GREEN}}✓ Restored $target_file from backup{{NORMAL}}"
        
        if gum confirm "Push restored file to PR?"; then
            if command -v just &>/dev/null; then
                just again
            else
                git add "$target_file"
                git commit -m "Restore $target_file from backup"
                git push
            fi
        fi
    else
        echo "{{BLUE}}Restore cancelled{{NORMAL}}"
    fi
