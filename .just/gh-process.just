# git/gh process justfile

# some useful variables
release_branch := "main"

# escape from branch, back to starting point
[group('Process')]
sync:
    git checkout "{{ release_branch }}"
    git pull
    git stp

# PR create 3.7
[group('Process')]
pr: _has_commits && pr_checks
    #!/usr/bin/env bash
    set -euxo pipefail # strict mode
    set +x # leave tracing off...

    # handle optional pre-pr hook (for things like hugo)
    if [[ -e ".just/pr-hook.just" ]]; then
        # _pr-hook is hidden because we think it is internal
        just _pr-hook
    fi

    git stp
    git pushup

    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    #COMMIT_COUNT=$(git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | wc -l)

    # first commit message becomes PR title
    FIRST_COMMIT_MESSAGE=$(git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* //' | head -1)

    bodyfile=$(mktemp /tmp/justfile.XXXXXX)
    echo "## Done" >> $bodyfile
    echo "" >> $bodyfile
    git cherry -v "{{ release_branch }}" "$CURRENT_BRANCH" | sed -e 's/^[+] [0-9a-f]* /- /' >> $bodyfile
    echo "" >> $bodyfile
    echo "" >> $bodyfile
    echo "## Meta" >> $bodyfile
    echo "" >> $bodyfile
    echo "(Automated in \`.just/gh-process.just\`.)" >> $bodyfile

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
    NOW=`just utcdate`
    git co -b "$USER/$NOW-{{ branchname }}"

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

# print UTC date in ISO format
[group('Utility')]
[no-cd]
@utcdate:
    TZ=UTC date +"%Y-%m-%d"

# make a release
[group('Process')]
release rel_version:
    gh release create {{rel_version}} --generate-notes

# watch GHAs then check for Copilot suggestions
[group('Process')]
pr_checks:
    #!/usr/bin/env bash

    gh pr checks --watch -i 5

    echo "🐈‍⬛😾 Copilot suggestions..."
    PR_META=$(gh pr view --json number,headRepository,headRepositoryOwner)
    PR_REPO_NAME=$(echo $PR_META | jq -r '.headRepository.name')
    PR_REPO_OWNER=$(echo $PR_META | jq -r '.headRepositoryOwner.login')
    PR_NUMBER=$(echo $PR_META | jq '.number')
    #echo "$PR_NUMBER $PR_REPO_OWNER/$PR_REPO_NAME"
    gh api graphql \
        -F owner=$PR_REPO_OWNER -F name=$PR_REPO_NAME -F pr=$PR_NUMBER \
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

    # did Claude comment?
    echo -e "\n\n🟧🟠🔶🔸 Claude:"
    gh pr view --json comments --jq '[.comments[] | select(.author.login == "claude")] | last | .body'
