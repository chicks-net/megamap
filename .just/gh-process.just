# git/gh process justfile

# check out the RELEASE_NOTES.md for the detailed history of this file
# the README.md in this directory also might be useful to you

# some useful variables
release_branch := "main"

# escape from branch, back to starting point
[group('Process')]
sync:
    git checkout "{{ release_branch }}"
    git pull
    git status --porcelain # stp

# PR create v4.4
[group('Process')]
pr: _has_commits && pr_checks
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
        echo "## Done"
        echo ""
        git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* /- /'
        echo ""
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

    if [[ ! -e ".github/workflows" ]]; then
        echo "{{BLUE}}there are no workflows in this repo so there are no PR checks to watch{{NORMAL}}"
        exit 0
    fi

    echo "{{BLUE}}sleeping for 8s because github is lazy with their API{{NORMAL}}"
    sleep 8

# merge PR and return to starting point
[group('Process')]
merge: _on_a_branch && sync
    gh pr merge -s -d
    # `&& sync` is mostly redundant, but just in case

# start a new branch
[group('Process')]
branch branchname: _main_branch
    #!/usr/bin/env bash
    NOW=$(just utcdate)
    git checkout -b "$USER/$NOW-{{ branchname }}"

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

# print UTC date in ISO format
[group('Utility')]
[no-cd]
@utcdate:
    TZ=UTC date +"%Y-%m-%d"

# make a release
[group('Process')]
release rel_version:
    gh release create {{rel_version}} --generate-notes
    sleep 1
    git pull

# watch GHAs then check for Copilot suggestions
[group('Process')]
pr_checks: _on_a_pull_request && claude_review
    #!/usr/bin/env bash

    gh pr checks --watch -i 5

    echo "🐈‍⬛😾 Copilot suggestions..."
    PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
    PR_REPO_NAME=$(echo "$PR_META" | jq -r '.headRepository.name')
    PR_REPO_OWNER=$(echo "$PR_META" | jq -r '.headRepositoryOwner.login')
    PR_NUMBER=$(echo "$PR_META" | jq '.number')
    #echo "$PR_NUMBER $PR_REPO_OWNER/$PR_REPO_NAME"
    # shellcheck disable=SC2016
    gh api graphql \
        -F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
        --jq '[ .data.repository.pullRequest.reviews.nodes.[] | select(.author.login=="copilot-pull-request-reviewer") | .comments.nodes.[] ]' \
        -f query='
        query($name: String!, $owner: String!, $pr: Int!) {
            repository(owner: $owner, name: $name) {
                pullRequest(number: $pr) {
                    reviews(last: 20) {
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
        '

    # chains to claude_review

# Claude's latest PR code review
[group('Process')]
claude_review: _on_a_pull_request
    #!/usr/bin/env bash

    # did Claude comment?
    echo -e "\n\n🟧🟠🔶🔸 Claude:"
    gh pr view --json comments --jq '[.comments[] | select(.author.login == "claude")] | last | .body'

# update the Done section of PR description with current commits
[group('Process')]
pr_update: _on_a_pull_request
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

    # get current PR body
    bodyfile=$(mktemp /tmp/justfile.XXXXXX)
    gh pr view --json body --jq '.body' > "$bodyfile"

    # create new Done section
    new_done_section=$(mktemp /tmp/justfile.XXXXXX)
    {
        echo "## Done"
        echo ""
        git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* /- /'
        echo ""
    } > "$new_done_section"

    # extract everything after Done section (preserve other sections)
    other_sections=$(mktemp /tmp/justfile.XXXXXX)
    awk '/^## Done/,/^## / {if (/^## / && !/^## Done/) {found=1}} found {print}' "$bodyfile" > "$other_sections"

    # if no other sections found after Done, preserve everything after Done
    if [ ! -s "$other_sections" ]; then
        # look for content after the Done section's commit list
        awk 'BEGIN {in_done=0; after_done=0; empty_count=0}
            /^## Done/ {in_done=1; next}
            in_done && !after_done && /^$/ {empty_count++; if (empty_count >= 2) after_done=1; next}
            in_done && !after_done && /^- / {next}
            after_done {print}' "$bodyfile" > "$other_sections"
    fi

    # combine new Done section with preserved sections
    updated_body=$(mktemp /tmp/justfile.XXXXXX)
    cat "$new_done_section" "$other_sections" > "$updated_body"

    echo ''
    cat "$updated_body"
    echo ''

    # update PR body
    gh pr edit --body-file "$updated_body"

    # cleanup
    rm "$bodyfile" "$new_done_section" "$other_sections" "$updated_body"

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
    git push
    just pr_update
    sleep 2
    just pr_checks
