# microsoft copilot justfile

# check out the RELEASE_NOTES.md for the detailed history of this file
# the README.md in this directory also might be useful to you

# Convention (issues #326 / #327): these recipes run under
# `set -euo pipefail`. Any bare simple command (gum spin, gh api) whose
# non-zero exit is a handled case must use the `var=0; <cmd> || var=$?`
# (or `|| var=<fallback>`) idiom - bare calls abort the recipe before
# the fallback messaging can print. Likewise, any value flowing into
# `[[ ... -eq/-gt/-lt ... ]]` from jq or a temp file must be normalized
# first: `<cmd> 2>/dev/null || echo "0"` plus
# `[[ "$var" =~ ^[0-9]+$ ]] || var=0`.

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

    echo "🐈‍⬛😾 Fetching unresolved Copilot suggestions..."

    # Get PR metadata
    PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
    PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
    PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
    PR_NUMBER=$(echo "$PR_META" | jq '.number')

    # Fetch Copilot comments
    copilot_comments=$(mktemp /tmp/justfile.XXXXXX)
    suggestions_display=$(mktemp /tmp/justfile.XXXXXX)
    # Trap is set before the first early exit below so a failed fetch does
    # not leak the temp files.
    trap 'rm -f "$copilot_comments" "$suggestions_display"' EXIT

    # Note: Uses reviewThreads instead of reviews so we can filter by isResolved.
    # Only unresolved threads are included so the picker shows actionable suggestions.
    # Note: reviewThreads(first: 100) limits to 100 threads; pagination not implemented.
    # This is unlikely to be an issue in practice (PRs rarely exceed 100 review threads).
    # shellcheck disable=SC2016
    gh api graphql \
        -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
        --jq '[ .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .comments.nodes[] | select(.author.login=="copilot-pull-request-reviewer") ]' \
        -f query='
        query($name: String!, $owner: String!, $pr: Int!) {
            repository(owner: $owner, name: $name) {
                pullRequest(number: $pr) {
                    reviewThreads(first: 100) {
                        nodes {
                            isResolved
                            comments(first: 100) {
                                nodes {
                                    author {
                                        login
                                    }
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
        ' > "$copilot_comments" || {
        # gh api is a bare simple command under `set -e` - without the
        # `|| { ... }` fallback, a GraphQL hiccup would abort the recipe
        # before the friendly guidance below could print. See issue #326.
        echo "{{RED}}Failed to fetch Copilot suggestions from GitHub.{{NORMAL}}"
        echo "{{YELLOW}}This is usually a transient API error - try again shortly.{{NORMAL}}"
        exit 1
    }

    # Check if we have comments. jq 'length' on a truncated/partial write
    # can emit empty or non-numeric output, which would crash the `-eq`
    # below with "integer expression expected" - default to 0 and let the
    # "No unresolved suggestions" branch handle it. See issue #327.
    COMMENT_COUNT=$(jq 'length' "$copilot_comments" 2>/dev/null || echo "0")
    [[ "$COMMENT_COUNT" =~ ^[0-9]+$ ]] || COMMENT_COUNT=0

    if [[ "$COMMENT_COUNT" -eq 0 ]]; then
        echo "{{BLUE}}No unresolved Copilot suggestions found{{NORMAL}}"
        exit 0
    fi

    echo "{{GREEN}}Found $COMMENT_COUNT unresolved Copilot suggestions{{NORMAL}}"
    echo ""

    # Format suggestions for gum display
    # (created above, before the fetch, so the trap covers it)

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

    # Extract file path and line number from selection to match back to original comment
    file_path=$(echo "$selected" | cut -d':' -f1)
    line_num=$(echo "$selected" | cut -d':' -f2 | cut -d' ' -f1)

    # Validate line number is numeric
    if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
        echo "{{RED}}Error: Could not extract line number from selection{{NORMAL}}"
        exit 1
    fi

    # Get the full suggestion data - match by both path and line to avoid ambiguity
    suggestion_data=$(jq -r --arg path "$file_path" --arg line "$line_num" \
        '.[] | select(.path == $path and .originalLine == ($line | tonumber))' "$copilot_comments")

    if [[ -z "$suggestion_data" ]]; then
        echo "{{RED}}Error: Could not find matching suggestion for $file_path:$line_num{{NORMAL}}"
        exit 1
    fi

    original_line=$(echo "$suggestion_data" | jq -r '.originalLine')
    suggestion_body=$(echo "$suggestion_data" | jq -r '.body')

    echo ""
    jq -r --arg path "$file_path" --arg line "$line_num" \
        '.[] | select(.path == $path and .originalLine == ($line | tonumber)) |
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
            # URL-encode path for safe backup filenames (reversible, unlike _ replacement)
            relative_path=$(git ls-files --full-name "$file_path" 2>/dev/null || echo "$file_path")
            safe_path=$(echo "$relative_path" | sed 's|%|%25|g; s|/|%2F|g; s|_|%5F|g')
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
                    # Single line: use temp file approach for cross-platform compatibility
                    # (sed -i syntax differs between BSD and GNU)
                    # shellcheck disable=SC2016
                    escaped_code=$(echo "$suggested_code" | sed 's|[][\\\.*^$()+?{|/]|\\&|g')
                    sed "${original_line}s|.*|${escaped_code}|" "$file_path" > "${file_path}.tmp"
                    mv "${file_path}.tmp" "$file_path"
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
    # no trailing cleanup needed - the EXIT trap removes both temp files

# Request a new Copilot review on current PR
[group('Copilot')]
copilot_refresh: _on_a_pull_request
    #!/usr/bin/env bash
    # shellcheck disable=SC2016
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

    # Resolve all existing unresolved Copilot review threads
    echo "🐈‍⬛ Resolving existing Copilot suggestions..."

    # Note: reviewThreads(first: 100) limits to 100 threads; see copilot_pick for comment.

    # shellcheck disable=SC2016
    THREAD_IDS=$(gh api graphql \
        -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
        --jq '[ .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | select(any(.comments.nodes[]; .author.login == "copilot-pull-request-reviewer")) | .id ]' \
        -f query='
        query($name: String!, $owner: String!, $pr: Int!) {
            repository(owner: $owner, name: $name) {
                pullRequest(number: $pr) {
                    reviewThreads(first: 100) {
                        nodes {
                            id
                            isResolved
                            comments(first: 100) {
                                nodes {
                                    author {
                                        login
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        ') || THREAD_IDS="[]"

    # gh api is a bare simple command under `set -e` - the `|| THREAD_IDS="[]"`
    # fallback keeps a transient GraphQL failure from aborting the recipe
    # before the resolve/report messaging below (a failed fetch is treated
    # as "nothing to resolve", the same zero-thread outcome as an empty
    # response). See issue #326.
    #
    # THREAD_COUNT flows from jq into an integer comparison - guard against
    # empty/non-numeric output so `-gt` sees a valid integer instead of
    # crashing with "integer expression expected". See issue #327.
    THREAD_COUNT=$(echo "$THREAD_IDS" | jq 'length' 2>/dev/null || echo "0")
    [[ "$THREAD_COUNT" =~ ^[0-9]+$ ]] || THREAD_COUNT=0

    if [[ "$THREAD_COUNT" -gt 0 ]]; then
        RESOLVED=0
        FAILED=0
        err_file=$(mktemp /tmp/justfile.copilot_resolve_err.XXXXXX)
        for thread_id in $(echo "$THREAD_IDS" | jq -r '.[]'); do
            if gh api graphql \
                -f threadId="$thread_id" \
                -f query='mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }' \
                >>/dev/null 2>>"$err_file"; then
                ((RESOLVED++)) || true
            else
                ((FAILED++)) || true
            fi
        done
        echo "{{GREEN}}✓ Resolved $RESOLVED Copilot suggestion(s){{NORMAL}}"
        if [[ $FAILED -gt 0 ]]; then
            echo "{{YELLOW}}⚠ Failed to resolve $FAILED suggestion(s){{NORMAL}}"
            if [[ -s "$err_file" ]]; then
                echo "{{YELLOW}}  Error details:{{NORMAL}}"
                sed 's/^/  /' "$err_file"
            fi
        fi
        rm -f "$err_file"
    else
        echo "{{BLUE}}No unresolved Copilot suggestions to resolve{{NORMAL}}"
    fi

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

    # Capture HEAD sha now so the shared poll script can reject stale reviews
    # left over from an older commit (issue #299 bug 4). Completion is a
    # Copilot-authored review whose commit oid matches HEAD - this replaces
    # the v8.3 submittedAt > REQUEST_TIME filter and unifies the
    # copilot_refresh and pr_checks paths.
    PR_HEAD_SHA=$(gh pr view --json headRefOid --jq '.headRefOid')

    # Delegate to the shared poll/state-machine (see issue #299). The v8.3
    # poll loop lived only inside copilot_refresh (as a printf-generated
    # temp script); pr_checks ran a one-shot query that raced Copilot.
    # Extracting the logic into .just/lib/wait_for_copilot.sh closes that
    # gap and keeps the two paths from drifting again. MODE=fatal: exit 1
    # when Copilot is not requested, since copilot_refresh just explicitly
    # requested it and a missing request is a real failure here.
    #
    # GraphQL reviewRequests with the Bot fragment is the reliable signal
    # for an in-progress Copilot review. REST
    # /pulls/N/requested_reviewers no longer surfaces Copilot as of
    # gh 2.95.0+ (returns {"teams":[],"users":[]} while GraphQL correctly
    # returns copilot-pull-request-reviewer), so it is not a usable
    # fallback. See issue #299 bug 3.
    if command -v gum &> /dev/null; then
        # review_ready=0 then || capture: gum spin is a bare simple command,
        # so under `set -e` an exit 1 from wait_for_copilot.sh (timeout or
        # the fatal-mode "not requested" fast-fail) would abort the recipe
        # before the friendly fallback block below could run. The non-gum
        # branch is fine because it sits inside an `if` condition. See
        # Claude review of PR #300 (Potential bug 1).
        review_ready=0
        gum spin --spinner dot --show-output --title "Waiting for Copilot review..." -- \
            .just/lib/wait_for_copilot.sh \
            "$PR_REPO_OWNER" "$PR_REPO_NAME" "$PR_NUMBER" "$PR_HEAD_SHA" \
            "$MAX_WAIT" "$POLL_INTERVAL" "$INITIAL_DELAY" "1" "fatal" \
            || review_ready=$?
    else
        echo "{{BLUE}}Waiting for Copilot review...{{NORMAL}}"
        if .just/lib/wait_for_copilot.sh \
            "$PR_REPO_OWNER" "$PR_REPO_NAME" "$PR_NUMBER" "$PR_HEAD_SHA" \
            "$MAX_WAIT" "$POLL_INTERVAL" "$INITIAL_DELAY" "0" "fatal"; then
            review_ready=0
        else
            review_ready=1
        fi
    fi

    if [[ $review_ready -eq 0 ]]; then
        echo ""
        echo "{{GREEN}}Review complete!{{NORMAL}}"

        # Count unresolved suggestions using GraphQL
        # Note: reviewThreads(first: 100) limits to 100 threads; see copilot_pick for comment.
        # shellcheck disable=SC2016
        COPILOT_COUNT=$(gh api graphql \
            -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
            --jq '[ .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .comments.nodes[] | select(.author.login=="copilot-pull-request-reviewer") ] | length' \
            -f query='
            query($name: String!, $owner: String!, $pr: Int!) {
                repository(owner: $owner, name: $name) {
                    pullRequest(number: $pr) {
                        reviewThreads(first: 100) {
                            nodes {
                                isResolved
                                comments(first: 100) {
                                    nodes {
                                        author {
                                            login
                                        }
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
            ') || COPILOT_COUNT=""

        # Bare gh api under `set -e`: the `|| COPILOT_COUNT=""` fallback
        # keeps a transient GraphQL failure from aborting the recipe before
        # the Found/No-suggestions messaging below can print. See #326.
        # The value feeds a `-gt` comparison, so normalize it to 0 when
        # empty or non-numeric ("integer expression expected" guard).
        # See issue #327.
        [[ "$COPILOT_COUNT" =~ ^[0-9]+$ ]] || COPILOT_COUNT=0

        if [[ $COPILOT_COUNT -gt 0 ]]; then
            echo "🐈‍⬛ Found ${COPILOT_COUNT} unresolved Copilot suggestions"
            echo ""
            echo "To browse interactively:"
            echo "  {{GREEN}}just copilot_pick{{NORMAL}}"
        else
            echo "🐈‍⬛ No unresolved suggestions - looks good!"
        fi
    else
        echo "{{YELLOW}}Review may still be processing (waited ${MAX_WAIT}s total). Options:{{NORMAL}}"
        echo "  {{GREEN}}just copilot_pick{{NORMAL}} (check if suggestions are ready)"
        echo "  {{GREEN}}just copilot_refresh{{NORMAL}} (wait longer for completion)"
        # Clean up any stale sentinel / count file left by wait_for_copilot.sh
        # on the timeout or stale-review path. copilot_refresh never writes
        # a count file, but rm -f it defensively. This mirrors the cleanup
        # claude_review does, preventing stray /tmp files between runs.
        # See Claude review of PR #299 (round 2, issue 2).
        COPILOT_STALE_FILE="/tmp/copilot_stale_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"
        COPILOT_COUNT_FILE="/tmp/copilot_count_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"
        rm -f "$COPILOT_STALE_FILE" "$COPILOT_COUNT_FILE"
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

    # List available backups. The glob must handle dot-prefixed names:
    # most backups in this repo are of .just/* files, whose URL-encoded
    # safe paths start with a dot, and bash globs skip dotfiles by
    # default. shopt -s dotglob makes *.bak match them; the [[ -f ]]
    # guard in the loop below keeps directories out. See issue #332.
    shopt -s dotglob
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
            # Parse the timestamp from the END of the name by pattern
            # (YYYYMMDD_HHMMSS_PID), not by underscore position. A
            # first-underscore split truncates legacy backup names whose
            # safe_path itself contains underscores (the old scheme
            # encoded / as _), and the timestamp contains underscores of
            # its own, so neither first- nor last-underscore splitting
            # works. The greedy .* matches up to the LAST timestamp-like
            # suffix, which is the real one. See issue #332.
            if [[ "$filename" =~ ^(.*)_([0-9]{8}_[0-9]{6}_[0-9]+)\.bak$ ]]; then
                safe_path="${BASH_REMATCH[1]}"
                timestamp="${BASH_REMATCH[2]}"
            else
                # Unrecognized format: skip loudly rather than guess a path
                echo "{{YELLOW}}Warning: skipping unparseable backup name: $filename{{NORMAL}}"
                continue
            fi
            # URL-decode the safe path back to original file path
            # (reversible unlike the old _ for / approach)
            if echo "$safe_path" | grep -qE '%2F|%5F|%25'; then
                target_file=$(echo "$safe_path" | sed 's|%5F|_|g; s|%2F|/|g; s|%25|%|g')
            else
                # Legacy fallback: old backups used _ for / replacement
                target_file=${safe_path//_/\/}
            fi
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
