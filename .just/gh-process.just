# git/gh process justfile

# some useful variables
host := `uname -n`
release_branch := "main"

# thanks to https://stackoverflow.com/a/7293026/2002471 for the perfect git incantation
last_commit_message := `git log -1 --pretty=%B | grep '.'`

# escape from branch, back to starting point
[group('Process')]
sync:
    git checkout {{ release_branch }}
    git pull
    git stp

# PR create 3.2
[group('Process')]
pr: _has_commits
    #!/usr/bin/env bash
    set -euxo pipefail # strict mode

    git stp
    git pushup

    set +x # leave tracing off...

    bodyfile=$(mktemp /tmp/justfile.XXXXXX)

    echo "## Done:" >> $bodyfile
    echo "" >> $bodyfile
    echo "- {{ last_commit_message }}" >> $bodyfile
    echo "" >> $bodyfile
    echo "" >> $bodyfile
    echo "(Automated in \`justfile\`.)" >> $bodyfile

    echo ''
    cat "$bodyfile"
    echo ''

    gh pr create --title "{{ last_commit_message }}" --body-file "$bodyfile"
    rm "$bodyfile"

    if [[ ! -e ".github/workflows" ]]; then
        echo "{{BLUE}}there are no workflows in this repo so there are no PR checks to watch{{NORMAL}}"
        exit 0
    fi

    echo "{{BLUE}}sleeping for 10s because github is lazy with their API{{NORMAL}}"
    sleep 10
    gh pr checks --watch -i 5

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

    if [[ $(git cherry -v {{ release_branch }} "$CURRENT_BRANCH" | wc -l) -eq 0 ]]; then
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
