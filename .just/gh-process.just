# git/gh process justfile

# check out the RELEASE_NOTES.md for the detailed history of this file
# the README.md in this directory also might be useful to you

# Convention (issues #326 / #327): recipes in this file that run under
# `set -euo pipefail` must guard bare simple commands (gum spin, gh api)
# whose non-zero exit is a handled case with `var=0; <cmd> || var=$?`
# (or `|| var=<fallback>`) - bare calls abort the recipe before fallback
# messaging can print. Any value flowing into
# `[[ ... -eq/-gt/-lt ... ]]` from jq or a temp file
# must be normalized first: `<cmd> 2>/dev/null || echo "0"` plus
# `[[ "$var" =~ ^[0-9]+$ ]] || var=0`.

# some useful variables
release_branch := "main"

# escape from branch, back to starting point
[group('Process')]
sync:
    git checkout "{{ release_branch }}"
    git pull
    git status --porcelain # stp

# PR create v9.9
[group('Process')]
pr: _has_commits
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # Feature flag: record the whole pr flow (inner recipe + pr_checks)
    # with asciinema into .cache/ - see .repo.toml flags.asciinema-record
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        FLAG_ASCIINEMA_RECORD="false"
    fi

    if [[ "${FLAG_ASCIINEMA_RECORD:-false}" != "true" ]]; then
        just _pr_inner
        just pr_checks
        exit 0
    fi

    # Flag is on: record if the binary exists, else warn and run unrecorded
    if ! command -v asciinema >/dev/null 2>&1; then
        echo "{{YELLOW}}Warning: flags.asciinema-record is true but asciinema is not on PATH - running unrecorded{{NORMAL}}"
        just _pr_inner
        just pr_checks
        exit 0
    fi

    mkdir -p .cache
    TMP_CAST=".cache/pr-$$.cast.tmp"
    echo "{{BLUE}}Recording pr flow to $TMP_CAST (asciinema)...{{NORMAL}}"
    # asciinema 3.x exits 0 regardless of the recorded command's status
    # unless --return is passed; 2.x propagates by default and has no
    # --return flag, so detect support rather than hardcode either way
    if asciinema rec --help 2>/dev/null | grep -q -- '--return'; then
        RC=0
        asciinema rec --return "$TMP_CAST" -c "just _pr_inner && just pr_checks" || RC=$?
    else
        RC=0
        asciinema rec "$TMP_CAST" -c "just _pr_inner && just pr_checks" || RC=$?
    fi

    # rename to include the PR number once known; fall back to pid-only
    # if pr create failed or was interrupted, so we still keep the cast
    if [[ ! -f "$TMP_CAST" ]]; then
        echo "{{YELLOW}}asciinema did not produce a recording (rec requires a TTY) - no cast saved{{NORMAL}}"
        exit "$RC"
    fi
    PRNUM=$(gh pr view --json number -q .number 2>/dev/null || echo "0")
    [[ "$PRNUM" =~ ^[0-9]+$ ]] || PRNUM=0
    if [[ "$PRNUM" -gt 0 ]]; then
        mv "$TMP_CAST" ".cache/pr-${PRNUM}-$$.cast"
        echo "{{BLUE}}Recording saved: .cache/pr-${PRNUM}-$$.cast{{NORMAL}}"
    else
        mv "$TMP_CAST" ".cache/pr-$$.cast"
        echo "{{YELLOW}}No PR number found - recording saved: .cache/pr-$$.cast{{NORMAL}}"
    fi
    exit "$RC"

# inner body of pr - the pre-recording recipe body, now callable by
# the pr wrapper above; pr_checks runs separately (chained by pr)
[group('Process')]
_pr_inner: _has_commits
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # handle optional pre-pr hook (for things like hugo)
    if [[ -e ".just/pr-hook.just" ]]; then
        # _pr-hook is hidden because we think it is internal
        just _pr-hook
    fi

    git status --porcelain # stp
    git push -u origin HEAD # pushup

    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    #COMMIT_COUNT=$(git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | wc -l)

    # first commit message becomes PR title
    FIRST_COMMIT_MESSAGE=$(git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* //' | head -1)

    bodyfile=$(mktemp /tmp/justfile.XXXXXX)
    {
        echo "<!-- PR_BODY_DONE_START -->"
        echo "## Done"
        echo ""
        git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* /- /'
        echo ""
        echo "<!-- PR_BODY_DONE_END -->"
        echo ""
        echo "## Meta"
        echo ""
        echo "(Automated in \`.just/gh-process.just\`.)"
    } >> "$bodyfile"

    echo ''
    cat "$bodyfile"
    echo ''

    gh pr create --title "$FIRST_COMMIT_MESSAGE" --body-file "$bodyfile"
    rm "$bodyfile"

# merge PR and return to starting point
[group('Process')]
merge: _on_a_branch && sync
    gh pr merge -s -d
    # `&& sync` is mostly redundant, but just in case

# [positional-arguments] keeps this recipe self-contained in derived
# repos, whose root justfile lacks `set positional-arguments` (#367)
# start a new branch
[group('Process')]
[positional-arguments]
branch branchname: _main_branch
    #!/usr/bin/env bash
    NOW=$(just utcdate)
    git checkout -b "$USER/$NOW-$1"

# view PR in web browser
[group('Process')]
prweb: _on_a_branch
    gh pr view --web

# error if not on a git branch
[group('sanity check')]
[no-cd]
_on_a_branch:
    #!/bin/bash

    # thanks to https://stackoverflow.com/a/12142066/2002471

    if [[ $(git rev-parse --abbrev-ref HEAD) == "{{ release_branch }}" ]]; then
        echo "{{RED}}You are on branch '{{ release_branch }}' (the release branch) so you are not ready to start a PR.{{NORMAL}}"
        exit 100
    fi

# error if not on the release branch
[group('sanity check')]
[no-cd]
_has_commits: _on_a_branch
    #!/bin/bash

    # thanks to https://stackoverflow.com/a/24668421/2002471

    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    #echo $CURRENT_BRANCH

    if [[ $(git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | wc -l) -eq 0 ]]; then
        echo "You are on a branch that {{RED}}does not have any commits{{NORMAL}}."
        exit 101
    fi

# error if not on the release branch
[group('sanity check')]
[no-cd]
_main_branch:
    #!/bin/bash

    # thanks to https://stackoverflow.com/a/12142066/2002471

    if [[ ! $(git rev-parse --abbrev-ref HEAD) == "{{ release_branch }}" ]]; then
        echo "You are on a {{BLUE}}branch that is not the release branch{{NORMAL}} so you are not ready to start a new branch."
        exit 102
    fi

# error if not on a branch with a pull request
[group('sanity check')]
[no-cd]
_on_a_pull_request: _on_a_branch
    #!/bin/bash
    set -euo pipefail # strict mode

    if \! gh pr view &>/dev/null; then
        echo "No PR found for current branch"
        exit 103
    fi

# wait for GitHub checks to start (with polling)
[group('sanity check')]
[no-cd]
_wait_for_checks: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail

    MAX_WAIT=30
    POLL_INTERVAL=2

    # Polling function that can be wrapped by gum or run standalone
    poll_for_checks() {
        elapsed=0
        while (( elapsed < MAX_WAIT )); do
            # Check if any checks exist
            checks=$(gh pr checks --json state,name 2>/dev/null || echo "[]")

            if [ "$checks" != "[]" ] && [ -n "$checks" ]; then
                echo "{{GREEN}}Checks detected after ${elapsed}s{{NORMAL}}"
                return 0
            fi

            sleep $POLL_INTERVAL
            elapsed=$((elapsed + POLL_INTERVAL))

            # Only show dots if not using gum
            if [ "${USING_GUM:-0}" = "0" ]; then
                echo -n "."
            fi
        done

        echo ""
        echo "{{YELLOW}}No checks found after ${MAX_WAIT}s - continuing anyway{{NORMAL}}"
        return 0
    }

    # Use gum spin if available, otherwise fall back to simple progress.
    # gum spin is a bare simple command under `set -e` - the `spin_ok=0; ...`
    # `|| spin_ok=$?` idiom keeps a gum crash (tty loss, SIGPIPE) from
    # aborting the recipe before the fallback run of poll_for_checks below.
    # See issue #326.
    if command -v gum &> /dev/null; then
        spin_ok=0
        USING_GUM=1 gum spin --spinner dot --title "Waiting for GitHub checks to start..." -- bash -c "MAX_WAIT=$MAX_WAIT; POLL_INTERVAL=$POLL_INTERVAL; $(declare -f poll_for_checks); poll_for_checks" \
            || spin_ok=$?
        if [[ $spin_ok -ne 0 ]]; then
            echo "{{YELLOW}}gum spin failed - falling back to plain polling{{NORMAL}}"
            USING_GUM=0 poll_for_checks
        fi
    else
        echo "{{BLUE}}Waiting for GitHub checks to start...{{NORMAL}}"
        USING_GUM=0 poll_for_checks
    fi

# print UTC date in ISO format
[group('Utility')]
[no-cd]
@utcdate:
    TZ=UTC date +"%Y-%m-%d"

# [positional-arguments] keeps this recipe self-contained in derived
# repos, whose root justfile lacks `set positional-arguments` (#367)
# make a release
[group('Process')]
[positional-arguments]
release rel_version:
    #!/usr/bin/env bash
    set -euo pipefail
    rel_version="$1"

    # Check if standard release workflow is enabled
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        # Default to true if file doesn't exist (backward compatibility)
        FLAG_STANDARD_RELEASE="true"
    fi

    if [[ "$FLAG_STANDARD_RELEASE" != "true" ]]; then
        echo "{{BLUE}}Standard release workflow is disabled (see .repo.toml flags.standard-release){{NORMAL}}"
        echo "{{YELLOW}}For this project's release workflow, check the justfile or .just/ modules{{NORMAL}}"
        exit 0
    fi

    # Validate version format - must be v, digits, with up to two
    # .digits groups, nothing else (start-anchored-only regexes let
    # quote-injection through, #359)
    if [[ ! "$rel_version" =~ ^v[0-9]+(\.[0-9]+){0,2}$ ]]; then
        echo "{{RED}}Error: Release version must be v followed by digits and up to two .digits groups (e.g., v1, v1.0, v1.0.0){{NORMAL}}"
        exit 1
    fi

    # Standard release workflow
    gh release create "$rel_version" --generate-notes
    sleep 1
    git pull

# watch GHAs then check for Copilot suggestions
[group('Process')]
pr_checks: _on_a_pull_request && claude_review
    #!/usr/bin/env bash

    # Skip workflow watcher when repo has no GitHub Actions workflows
    if [[ -d ".github/workflows" ]]; then
        # Use gh observer if installed, otherwise fall back to gh pr checks --watch.
        # gh observer gates exit on Copilot review completion itself
        # (gh-observer #409), so the separate wait_for_copilot.sh call below is
        # only needed on the fallback path. Track which watcher ran so the
        # Copilot wait block can skip itself when gh observer already waited.
        used_gh_observer=false
        if gh observer --help >/dev/null 2>&1; then
            used_gh_observer=true
            echo ""
            gh observer
        else
            just _wait_for_checks
            gh pr checks --watch -i 5
        fi
        echo "" # blank line for visual space
    else
        echo "{{BLUE}}no workflows in this repo - skipping workflow watcher{{NORMAL}}"
        used_gh_observer=false
    fi

    # Load repo metadata for conditional display
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        echo "{{YELLOW}}Warning: .just/repo-toml.sh not found - run 'just repo_toml_generate'{{NORMAL}}"
        FLAG_COPILOT_REVIEW="false"
        # shellcheck disable=SC2034  # Set both flags for defensive programming
        FLAG_CLAUDE_REVIEW="false"
    fi

    # Only display Copilot review if flag is enabled
    if [[ "$FLAG_COPILOT_REVIEW" == "true" ]]; then
        PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner,headRefOid)
        PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
        PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
        PR_NUMBER=$(echo "$PR_META" | jq '.number')
        PR_HEAD_SHA=$(echo "$PR_META" | jq -r '.headRefOid')
        #echo "$PR_NUMBER $PR_REPO_OWNER/$PR_REPO_NAME"

        # Define temp file for passing count to claude_review (based on repo and PR)
        COPILOT_COUNT_FILE="/tmp/copilot_count_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"

        # Wait for Copilot to finish before querying threads, so the one-shot
        # count below runs against settled state instead of racing Copilot
        # (issue #299: the v8.3 state machine was only wired into
        # copilot_refresh; pr_checks ran the thread query immediately after
        # the CI watcher exited and printed false "looks good!" negatives
        # when CI settled before Copilot finished). The shared
        # wait_for_copilot.sh polls reviewRequests + reviews(last: 10) and
        # completes when a Copilot review for the HEAD commit lands.
        # MODE=nonfatal: if Copilot was never requested (no auto-review on
        # this repo), exit 0 and fall through to the thread query instead of
        # failing the whole PR flow.
        #
        # Skip the wait on the gh observer path: gh observer already gates its
        # exit on Copilot review completion (gh-observer #409), so by the time
        # we get here the review state is already settled and a second wait is
        # dead time (issue #320). The fallback path (gh pr checks --watch)
        # only watches CI check runs and still needs the explicit wait.
        if [[ "$used_gh_observer" == "true" ]]; then
            echo "{{BLUE}}Copilot wait already handled by gh observer{{NORMAL}}"
        elif [[ -x ".just/lib/wait_for_copilot.sh" ]]; then
            MAX_WAIT=180
            POLL_INTERVAL=5
            INITIAL_DELAY=10
            if command -v gum &> /dev/null; then
                gum spin --spinner dot --show-output --title "Waiting for Copilot review..." -- \
                    .just/lib/wait_for_copilot.sh \
                    "$PR_REPO_OWNER" "$PR_REPO_NAME" "$PR_NUMBER" "$PR_HEAD_SHA" \
                    "$MAX_WAIT" "$POLL_INTERVAL" "$INITIAL_DELAY" "1" "nonfatal" \
                    || true
            else
                echo "{{BLUE}}Waiting for Copilot review...{{NORMAL}}"
                .just/lib/wait_for_copilot.sh \
                    "$PR_REPO_OWNER" "$PR_REPO_NAME" "$PR_NUMBER" "$PR_HEAD_SHA" \
                    "$MAX_WAIT" "$POLL_INTERVAL" "$INITIAL_DELAY" "0" "nonfatal" \
                    || true
            fi
        else
            echo "{{YELLOW}}Warning: .just/lib/wait_for_copilot.sh not found - skipping Copilot wait{{NORMAL}}"
        fi

        # Capture GraphQL output
        # Note: reviewThreads(first: 100) limits to 100 threads; see copilot_pick for comment.
        # shellcheck disable=SC2016
        COPILOT_JSON=$(gh api graphql \
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
            ')

        # Count and store suggestions for display after claude_review.
        # The value flows into an integer comparison and a temp file read
        # back by claude_review, so normalize empty/non-numeric jq output
        # to 0 to avoid "integer expression expected" crashes downstream.
        # See issue #327.
        COPILOT_COUNT=$(echo "$COPILOT_JSON" | jq 'length' 2>/dev/null || echo "0")
        [[ "$COPILOT_COUNT" =~ ^[0-9]+$ ]] || COPILOT_COUNT=0
        echo "$COPILOT_COUNT" > "$COPILOT_COUNT_FILE"

        # Don't echo the "looks good!" / "Unresolved Copilot suggestions: N"
        # summary line here - claude_review reads this same count file and
        # is the single place that summary prints. Printing it in both
        # recipes duplicated the line on every pr_checks->claude_review run
        # (pr_checks always chains into claude_review). Only the detailed
        # JSON dump belongs here, as immediate feedback right after the
        # GraphQL query.
        if [[ "$COPILOT_COUNT" -gt 0 ]]; then
            echo "$COPILOT_JSON" | jq '.'
        fi
    else
        echo "{{BLUE}}Skipping Copilot review (disabled in .repo.toml){{NORMAL}}"
    fi

    # chains to claude_review

# Claude's latest PR code review
[group('Process')]
claude_review: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail

    # Load repo metadata for conditional display
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        echo "{{YELLOW}}Warning: .just/repo-toml.sh not found - run 'just repo_toml_generate'{{NORMAL}}"
        # shellcheck disable=SC2034  # Set both flags for defensive programming
        FLAG_COPILOT_REVIEW="false"
        FLAG_CLAUDE_REVIEW="false"
    fi

    # Display Copilot count summary if available (moved above *both*
    # early exits - the FLAG_CLAUDE_REVIEW disabled gate and the "No
    # Claude comment found" gate - so the end-of-run summary always
    # prints and the temp file is always cleaned up when copilot-review
    # is enabled, regardless of the claude-review flag. Previously the
    # claude-review=false early exit skipped this block, leaking the
    # count file and skipping the summary - the same class of bug as
    # issue #299 bug 2, via a different early-exit path. See Claude
    # review of PR #299 (round 2, issue 1).
    if [[ "${FLAG_COPILOT_REVIEW:-false}" == "true" ]]; then
        PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
        PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
        PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
        PR_NUMBER=$(echo "$PR_META" | jq '.number')
        COPILOT_COUNT_FILE="/tmp/copilot_count_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"
        # Sentinel written by wait_for_copilot.sh when it exited having seen
        # a stale Copilot review (older commit) but no HEAD-matching one.
        # Annotates the "looks good!" summary so a stale review is not
        # mistaken for a current one. See Claude review of PR #300
        # (Potential bug 2).
        COPILOT_STALE_FILE="/tmp/copilot_stale_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"
        if [[ -f "$COPILOT_COUNT_FILE" ]]; then
            # COPILOT_COUNT is a raw temp-file read feeding an integer
            # comparison - a partial write or empty file would crash `-eq`
            # with "integer expression expected", so validate before use.
            # See issue #327.
            COPILOT_COUNT=$(cat "$COPILOT_COUNT_FILE" 2>/dev/null || echo "0")
            [[ "$COPILOT_COUNT" =~ ^[0-9]+$ ]] || COPILOT_COUNT=0
            echo ""
            if [[ "$COPILOT_COUNT" -eq 0 ]]; then
                if [[ -f "$COPILOT_STALE_FILE" ]]; then
                    echo "🐈‍⬛ No unresolved Copilot suggestions - looks good! {{YELLOW}}(review may be stale - run just copilot_refresh){{NORMAL}}"
                else
                    echo "🐈‍⬛ No unresolved Copilot suggestions - looks good!"
                fi
            else
                echo "🐈‍⬛ Unresolved Copilot suggestions: $COPILOT_COUNT"
            fi
            rm -f "$COPILOT_COUNT_FILE" "$COPILOT_STALE_FILE"
        fi
    fi

    # Only display Claude review if flag is enabled
    if [[ "$FLAG_CLAUDE_REVIEW" != "true" ]]; then
        echo "{{BLUE}}Skipping Claude review (disabled in .repo.toml){{NORMAL}}"
        exit 0
    fi

    # Get latest commit info
    LATEST_COMMIT_SHA=$(gh pr view --json commits --jq '.commits[-1].oid')
    LATEST_COMMIT_DATE=$(gh pr view --json commits --jq '.commits[-1].committedDate')

    # Get Claude's latest comment
    CLAUDE_COMMENT_JSON=$(gh pr view --json comments --jq '[.comments[] | select(.author.login == "claude")] | last')

    # Check if comment exists
    if [[ -z "$CLAUDE_COMMENT_JSON" || "$CLAUDE_COMMENT_JSON" == "null" ]]; then
        echo -e "\n\n{{BLUE}}ℹ️  No Claude Code review found yet{{NORMAL}}"
        echo "   Latest commit: ${LATEST_COMMIT_SHA:0:7} ($(date -d "$LATEST_COMMIT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LATEST_COMMIT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$LATEST_COMMIT_DATE"))"
        echo "   The review workflow may still be running"
        echo "   Try: {{GREEN}}just claude_review{{NORMAL}} (to check again)"
        echo "   Or: {{GREEN}}just prweb{{NORMAL}} (to see review status in browser)"
        exit 0
    fi

    COMMENT_DATE=$(echo "$CLAUDE_COMMENT_JSON" | jq -r '.createdAt')
    COMMENT_BODY=$(echo "$CLAUDE_COMMENT_JSON" | jq -r '.body')

    # Convert dates to epoch for comparison (cross-platform)
    if COMMIT_EPOCH=$(date -d "$LATEST_COMMIT_DATE" +%s 2>/dev/null); then
        # GNU date (Linux)
        COMMENT_EPOCH=$(date -d "$COMMENT_DATE" +%s 2>/dev/null)
    elif COMMIT_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LATEST_COMMIT_DATE" +%s 2>/dev/null); then
        # BSD date (macOS)
        COMMENT_EPOCH=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$COMMENT_DATE" +%s 2>/dev/null)
    else
        echo "{{YELLOW}}Warning: Could not parse dates for staleness check{{NORMAL}}"
        COMMIT_EPOCH=0
        COMMENT_EPOCH=0
    fi

    # Check staleness
    if [[ $COMMENT_EPOCH -lt $COMMIT_EPOCH ]]; then
        # Comment is older than latest commit = STALE
        TIME_DIFF=$((COMMIT_EPOCH - COMMENT_EPOCH))
        MINUTES_OLD=$((TIME_DIFF / 60))

        echo -e "\n\n{{YELLOW}}⚠️  Claude Code Review exists but is STALE{{NORMAL}}"
        echo "   Review created: $(date -d "$COMMENT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$COMMENT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$COMMENT_DATE")"
        echo "   Latest commit:  $(date -d "$LATEST_COMMIT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LATEST_COMMIT_DATE" +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$LATEST_COMMIT_DATE")"
        echo "   Age difference: ~$MINUTES_OLD minutes old"
        echo "   Consider waiting for new review or checking workflow status"
        echo ""
        echo "🟧🟠🔶🔸 Claude's feedback (may not apply to latest code):"
    else
        # Comment is same age or newer than latest commit = CURRENT
        echo -e "\n\n🟧🟠🔶🔸 Claude Code Review (current):"
    fi

    echo "$COMMENT_BODY"

    # Always exit 0 - this is informational, not an error
    exit 0

# update the Done section of PR description with current commits
[group('Process')]
pr_update: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

    # Get current PR body
    bodyfile=$(mktemp /tmp/justfile.XXXXXX)
    gh pr view --json body --jq '.body' > "$bodyfile"

    # Create new commit list
    new_commits=$(mktemp /tmp/justfile.XXXXXX)
    git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | \
        sed -e 's/^[+] [0-9a-f]* /- /' > "$new_commits"

    # Use library script for robust update
    updated_body=$(mktemp /tmp/justfile.XXXXXX)
    .just/lib/update_pr_body.sh "$bodyfile" "$new_commits" > "$updated_body"

    echo ''
    cat "$updated_body"
    echo ''

    # Update PR body
    gh pr edit --body-file "$updated_body"

    # Cleanup
    rm "$bodyfile" "$new_commits" "$updated_body"

# add or append to Verify section from stdin
[group('Process')]
pr_verify: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # read stdin into a temp file
    stdin_content=$(mktemp /tmp/justfile.XXXXXX)
    cat > "$stdin_content"

    # get current PR body
    bodyfile=$(mktemp /tmp/justfile.XXXXXX)
    gh pr view --json body --jq '.body' > "$bodyfile"

    # get current datetime
    DATETIME=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # check if Verify section exists
    if grep -q '^## Verify' "$bodyfile"; then
        # append to existing Verify section
        updated_body=$(mktemp /tmp/justfile.XXXXXX)
        awk -v datetime="$DATETIME" '
            /^## Verify/ {
                in_verify=1
                print
                next
            }
            /^## / && in_verify {
                # found next section, insert content before it
                print ""
                print "### " datetime
                print ""
                print "```"
                system("cat '"$stdin_content"'")
                print "```"
                print ""
                in_verify=0
            }
            { print }
            END {
                # if still in verify section at end, append content
                if (in_verify) {
                    print ""
                    print "### " datetime
                    print ""
                    print "```"
                    system("cat '"$stdin_content"'")
                    print "```"
                }
            }
        ' "$bodyfile" > "$updated_body"
    else
        # create new Verify section before Meta section
        updated_body=$(mktemp /tmp/justfile.XXXXXX)
        awk -v datetime="$DATETIME" '
            /^## Meta/ {
                # insert Verify section before Meta
                print "## Verify"
                print ""
                print "### " datetime
                print ""
                print "```"
                system("cat '"$stdin_content"'")
                print "```"
                print ""
            }
            { print }
        ' "$bodyfile" > "$updated_body"
    fi

    echo ''
    cat "$updated_body"
    echo ''

    # update PR body
    gh pr edit --body-file "$updated_body"

    # cleanup
    rm "$stdin_content" "$bodyfile" "$updated_body"

# check how long ago the last release was
[group('Process')]
release_age:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # Check if standard release workflow is enabled
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        # Default to true if file doesn't exist (backward compatibility)
        FLAG_STANDARD_RELEASE="true"
    fi

    if [[ "$FLAG_STANDARD_RELEASE" != "true" ]]; then
        echo "{{BLUE}}Standard release workflow is disabled (see .repo.toml flags.standard-release){{NORMAL}}"
        echo "{{YELLOW}}For this project's release workflow, check the justfile or .just/ modules{{NORMAL}}"
        exit 0
    fi

    echo "{{BLUE}}Checking last release age...{{NORMAL}}"
    echo ""

    # Get the latest release tag using JSON for robustness
    release_tag=$(gh release list --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)

    if [[ -z "$release_tag" ]]; then
        echo "{{YELLOW}}No releases found{{NORMAL}}"
        exit 0
    fi

    # Get release date using JSON
    release_date=$(gh release view "$release_tag" --json publishedAt -q .publishedAt 2>/dev/null | cut -d'T' -f1)

    if [[ -z "$release_date" ]]; then
        echo "{{RED}}Could not determine release date{{NORMAL}}"
        exit 1
    fi

    # Convert release date to epoch seconds (cross-platform)
    # Try GNU date first (Linux), then BSD date (macOS)
    if release_epoch=$(date -d "$release_date" +%s 2>/dev/null); then
        # GNU date (Linux)
        current_epoch=$(date +%s)
    elif release_epoch=$(date -j -f "%Y-%m-%d" "$release_date" +%s 2>/dev/null); then
        # BSD date (macOS)
        current_epoch=$(date +%s)
    else
        echo "{{RED}}Could not parse release date: $release_date{{NORMAL}}"
        exit 1
    fi

    days_old=$(( (current_epoch - release_epoch) / 86400 ))

    # Count commits since last release on main/master branch
    if git rev-parse --verify main >/dev/null 2>&1; then
        main_branch="main"
    elif git rev-parse --verify master >/dev/null 2>&1; then
        main_branch="master"
    else
        echo "{{RED}}Could not find main or master branch{{NORMAL}}"
        exit 1
    fi

    commits_since=$(git rev-list --count "${release_tag}..${main_branch}" 2>/dev/null || echo "0")

    # Display results with color coding
    echo "Latest release: {{CYAN}}$release_tag{{NORMAL}}"
    echo "Published: {{CYAN}}$release_date{{NORMAL}}"

    if [[ $days_old -gt 60 ]]; then
        echo "Age: {{YELLOW}}$days_old days old{{NORMAL}}"
        echo "Commits since release: {{YELLOW}}$commits_since{{NORMAL}}"
        echo ""
        echo "{{YELLOW}}⚠ Release is more than 60 days old - consider creating a new release{{NORMAL}}"
    else
        echo "Age: {{GREEN}}$days_old days old{{NORMAL}}"
        echo "Commits since release: {{GREEN}}$commits_since{{NORMAL}}"
    fi

# push changes, update PR description, and watch GHAs
[group('Process')]
again:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # Feature flag: record the whole again flow with asciinema into
    # .cache/ - see .repo.toml flags.asciinema-record
    if [[ -e ".just/repo-toml.sh" ]]; then
        source .just/repo-toml.sh
    else
        FLAG_ASCIINEMA_RECORD="false"
    fi

    if [[ "${FLAG_ASCIINEMA_RECORD:-false}" != "true" ]]; then
        just _again_inner
        exit 0
    fi

    # Flag is on: record if the binary exists, else warn and run unrecorded
    if ! command -v asciinema >/dev/null 2>&1; then
        echo "{{YELLOW}}Warning: flags.asciinema-record is true but asciinema is not on PATH - running unrecorded{{NORMAL}}"
        just _again_inner
        exit 0
    fi

    # the PR number is already known here (unlike pr, where create may
    # fail), so name the cast up front
    PRNUM=$(gh pr view --json number -q .number 2>/dev/null || echo "0")
    [[ "$PRNUM" =~ ^[0-9]+$ ]] || PRNUM=0
    if [[ "$PRNUM" -eq 0 ]]; then
        echo "{{YELLOW}}Warning: could not determine PR number - recording as .cache/again-$$.cast{{NORMAL}}"
        CAST=".cache/again-$$.cast"
    else
        CAST=".cache/again-${PRNUM}-$$.cast"
    fi

    mkdir -p .cache
    echo "{{BLUE}}Recording again flow to $CAST (asciinema)...{{NORMAL}}"
    # asciinema 3.x exits 0 regardless of the recorded command's status
    # unless --return is passed; 2.x propagates by default and has no
    # --return flag, so detect support rather than hardcode either way
    if asciinema rec --help 2>/dev/null | grep -q -- '--return'; then
        RC=0
        asciinema rec --return "$CAST" -c "just _again_inner" || RC=$?
    else
        RC=0
        asciinema rec "$CAST" -c "just _again_inner" || RC=$?
    fi
    if [[ ! -f "$CAST" ]]; then
        echo "{{YELLOW}}asciinema did not produce a recording (rec requires a TTY) - no cast saved{{NORMAL}}"
        exit "$RC"
    fi
    if [[ "$RC" -eq 0 ]]; then
        echo "{{BLUE}}Recording saved: $CAST{{NORMAL}}"
    else
        echo "{{YELLOW}}Recording finished with exit code $RC - saved: $CAST{{NORMAL}}"
    fi
    exit "$RC"

# inner body of again - the pre-recording recipe body, callable by
# the again wrapper above
[group('Process')]
_again_inner:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    # The #329 regression path: the RELEASE_NOTES indent fix landed
    # broken on a pr PR, was fixed, then re-broke on a follow-up push
    # through 'again'. Run the same pre-PR hook before this push.
    if [[ -e ".just/pr-hook.just" ]]; then
        just _pr-hook
    fi

    git push
    just pr_update
    just pr_checks
