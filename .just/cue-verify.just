# File Format Self-checks

# use Cue to verify /.repo.toml validity and flag configuration
[group('Testing/Compliance')]
cue-verify:
    #!/usr/bin/env bash
    set -euo pipefail

    # Stage 1: Cue validates TOML structure and types
    cue vet .repo.toml docs/repo-toml.cue
    echo "{{GREEN}}Cue structure validation passed.{{NORMAL}}"

    # Extract org/repo names once at the top for all stages
    ORG_NAME=$(cue export .repo.toml | jq -r '.urls.web_url // ""' | sed -E 's|https://github.com/([^/]+)/.*|\1|')
    REPO_NAME=$(cue export .repo.toml | jq -r '.urls.web_url // ""' | sed -E 's|.*/([^/]+)/?$|\1|')

    # Stage 2: Validate flags match actual configuration
    echo "{{BLUE}}Verifying .repo.toml flags match repository configuration...{{NORMAL}}"

    # Extract flags from .repo.toml using cue export + jq
    CLAUDE_FLAG=$(cue export .repo.toml | jq -r '.flags.claude // false')
    CLAUDE_REVIEW_FLAG=$(cue export .repo.toml | jq -r '.flags."claude-review" // false')
    COPILOT_REVIEW_FLAG=$(cue export .repo.toml | jq -r '.flags."copilot-review" // false')
    STANDARD_RELEASE_FLAG=$(cue export .repo.toml | jq -r 'if .flags."standard-release" == false then "false" else "true" end')

    # Error counter
    ERRORS=0

    # Validate claude flag
    if [[ "$CLAUDE_FLAG" == "true" ]]; then
        if [[ ! -e ".github/workflows/claude.yml" ]]; then
            echo "{{RED}}[flags.claude] Missing required file: .github/workflows/claude.yml{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        fi
        if [[ ! -e ".github/workflows/claude-code-review.yml" ]]; then
            echo "{{RED}}[flags.claude] Missing required file: .github/workflows/claude-code-review.yml{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Validate claude-review flag
    if [[ "$CLAUDE_REVIEW_FLAG" == "true" ]]; then
        if [[ ! -e ".github/workflows/claude-code-review.yml" ]]; then
            echo "{{RED}}[flags.claude-review] Missing required file: .github/workflows/claude-code-review.yml{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        fi
        if [[ ! -e ".just/gh-process.just" ]]; then
            echo "{{RED}}[flags.claude-review] Missing required file: .just/gh-process.just{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Validate copilot-review flag
    if [[ "$COPILOT_REVIEW_FLAG" == "true" ]]; then
        if [[ -z "$ORG_NAME" ]]; then
            echo "{{RED}}[flags.copilot-review] Cannot extract organization name from .repo.toml{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        else
            # Try to check if org has Copilot via GitHub API
            if gh api "orgs/$ORG_NAME/copilot/billing" &>/dev/null; then
                # API call succeeded - org has Copilot
                :
            else
                EXIT_CODE=$?
                if [[ $EXIT_CODE -eq 22 ]]; then
                    # HTTP 404 - org doesn't have Copilot
                    echo "{{RED}}[flags.copilot-review] Organization '$ORG_NAME' does not have GitHub Copilot enabled{{NORMAL}}"
                    ERRORS=$((ERRORS + 1))
                else
                    # Permission or network error - warn but don't fail
                    echo "{{YELLOW}}[flags.copilot-review] Warning: Cannot verify Copilot status (exit code: $EXIT_CODE){{NORMAL}}"
                    echo "{{YELLOW}}  This may be due to API permissions or network issues{{NORMAL}}"
                fi
            fi
        fi
    fi

    # Validate standard-release flag (informational only)
    if [[ "$STANDARD_RELEASE_FLAG" == "false" ]]; then
        echo "{{YELLOW}}[flags.standard-release] Standard release workflow is disabled{{NORMAL}}"
        echo "{{YELLOW}}  Ensure custom release recipes exist in justfile or .just/ modules{{NORMAL}}"
    fi

    # Stage 3: Validate GitHub metadata sync
    echo "{{BLUE}}Verifying description and topics match GitHub...{{NORMAL}}"

    # Extract description and topics from .repo.toml
    TOML_DESC=$(cue export .repo.toml | jq -r '.about.description // ""')
    TOML_TOPICS=$(cue export .repo.toml | jq -r '.about.topics // [] | sort | join(",")')

    # Check if we can extract org and repo names
    if [[ -z "$ORG_NAME" || -z "$REPO_NAME" ]]; then
        echo "{{YELLOW}}Warning: Cannot extract org/repo name from .repo.toml - skipping GitHub sync check{{NORMAL}}"
    else
        # Fetch metadata from GitHub API
        if GH_DATA=$(gh api "repos/$ORG_NAME/$REPO_NAME" 2>/dev/null); then
            GH_DESC=$(echo "$GH_DATA" | jq -r '.description // ""')
            GH_TOPICS=$(echo "$GH_DATA" | jq -r '.topics // [] | sort | join(",")')

            # Compare description
            if [[ "$TOML_DESC" != "$GH_DESC" ]]; then
                echo "{{RED}}[about.description] Mismatch with GitHub{{NORMAL}}"
                echo "  .repo.toml: $TOML_DESC"
                echo "  GitHub:     $GH_DESC"
                ERRORS=$((ERRORS + 1))
            fi

            # Compare topics
            if [[ "$TOML_TOPICS" != "$GH_TOPICS" ]]; then
                echo "{{RED}}[about.topics] Mismatch with GitHub{{NORMAL}}"
                echo "  .repo.toml: $TOML_TOPICS"
                echo "  GitHub:     $GH_TOPICS"
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo "{{YELLOW}}Warning: Cannot fetch GitHub metadata (API error){{NORMAL}}"
            echo "{{YELLOW}}  This may be due to API permissions or network issues{{NORMAL}}"
        fi
    fi

    # Report results
    if [[ $ERRORS -gt 0 ]]; then
        echo ""
        echo "{{RED}}Flag verification failed with $ERRORS error(s){{NORMAL}}"
        exit 1
    fi

    echo "{{GREEN}}Flag verification passed.{{NORMAL}}"

# sync description and topics from GitHub API into .repo.toml
[group('Template Maintenance')]
cue-sync-from-github:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "{{BLUE}}Syncing description and topics from GitHub...{{NORMAL}}"

    REPO_TOML_EXISTS=false
    if [[ -f .repo.toml ]]; then
        REPO_TOML_EXISTS=true
    fi

    # Extract org and repo name
    if $REPO_TOML_EXISTS; then
        ORG_NAME=$(cue export .repo.toml | jq -r '.urls.web_url // ""' | sed -E 's|https://github.com/([^/]+)/.*|\1|')
        REPO_NAME=$(cue export .repo.toml | jq -r '.urls.web_url // ""' | sed -E 's|.*/([^/]+)/?$|\1|')
    fi

    # Fall back to git remote if .repo.toml is missing or parsing failed
    if [[ -z "${ORG_NAME:-}" || -z "${REPO_NAME:-}" ]]; then
        REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
        if [[ -n "$REMOTE_URL" ]]; then
            # Handle SSH (git@github.com:org/repo.git) and HTTPS URLs
            REMOTE_URL="${REMOTE_URL%.git}"
            REMOTE_URL="${REMOTE_URL#git@github.com:}"
            REMOTE_URL="${REMOTE_URL#https://github.com/}"
            ORG_NAME=$(echo "$REMOTE_URL" | cut -d/ -f1)
            REPO_NAME=$(echo "$REMOTE_URL" | cut -d/ -f2)
        fi
    fi

    if [[ -z "${ORG_NAME:-}" || -z "${REPO_NAME:-}" ]]; then
        echo "{{RED}}Error: Cannot determine org/repo name from .repo.toml or git remote{{NORMAL}}"
        exit 1
    fi

    echo "{{BLUE}}Org: $ORG_NAME, Repo: $REPO_NAME{{NORMAL}}"

    # Fetch metadata from GitHub API
    if ! GH_DATA=$(gh api "repos/$ORG_NAME/$REPO_NAME" 2>/dev/null); then
        echo "{{RED}}Error: Cannot fetch GitHub metadata (API error){{NORMAL}}"
        echo "{{YELLOW}}  Check your network connection and GitHub authentication{{NORMAL}}"
        exit 1
    fi

    # Extract description and topics from GitHub
    GH_DESC=$(echo "$GH_DATA" | jq -r '.description // ""')
    GH_TOPICS=$(echo "$GH_DATA" | jq -r '.topics // []')

    # Convert topics array to TOML format
    TOPICS_TOML=$(echo "$GH_TOPICS" | jq -r 'map("\"" + . + "\"") | join(", ")')

    echo "  Description: $GH_DESC"
    echo "  Topics: [$TOPICS_TOML]"

    if $REPO_TOML_EXISTS; then
        # Create backup
        cp .repo.toml .repo.toml.backup
        echo "{{YELLOW}}Created backup: .repo.toml.backup{{NORMAL}}"

        # Update .repo.toml using awk (portable across macOS and Linux)
        GH_DESC_ESCAPED="${GH_DESC//\"/\\\"}"

        # Use state-aware awk that only matches within [about] section
        awk -v desc="$GH_DESC_ESCAPED" -v topics="[$TOPICS_TOML]" '
            /^\[about\]/ { in_about=1 }
            /^\[/ && !/^\[about\]/ { in_about=0 }
            in_about && /^description = / { print "description = \"" desc "\""; next }
            in_about && /^topics = / { print "topics = " topics; next }
            { print }
        ' .repo.toml > .repo.toml.tmp && mv .repo.toml.tmp .repo.toml

        # Validate the TOML is still valid after modification
        echo "{{BLUE}}Validating modified TOML...{{NORMAL}}"
        if cue vet .repo.toml docs/repo-toml.cue; then
            # Validation passed - safe to remove backup
            rm .repo.toml.backup
            echo "{{GREEN}}Successfully synced from GitHub to .repo.toml{{NORMAL}}"
        else
            # Validation failed - restore from backup
            mv .repo.toml.backup .repo.toml
            echo "{{RED}}Sync failed - TOML validation error. Restored from backup.{{NORMAL}}"
            exit 1
        fi
    else
        echo "{{YELLOW}}.repo.toml not found - creating from GitHub metadata{{NORMAL}}"

        GIT_SSH="git@github.com:$ORG_NAME/$REPO_NAME.git"
        WEB_URL="https://github.com/$ORG_NAME/$REPO_NAME"

        printf '%s\n' \
            "# .repo.toml" \
            "" \
            "[about]" \
            "description = \"$GH_DESC\"" \
            "topics = [$TOPICS_TOML]" \
            "" \
            "[urls]" \
            "git_ssh = \"$GIT_SSH\"" \
            "web_url = \"$WEB_URL\"" \
            "" \
            "[flags]" \
            "claude = false" \
            "claude-review = false" \
            "copilot-review = false" \
            "standard-release = true" \
            > .repo.toml

        # Validate the new TOML
        echo "{{BLUE}}Validating new TOML...{{NORMAL}}"
        if cue vet .repo.toml docs/repo-toml.cue; then
            echo "{{GREEN}}Created .repo.toml from GitHub metadata{{NORMAL}}"
        else
            rm .repo.toml
            echo "{{RED}}Failed to create valid .repo.toml{{NORMAL}}"
            exit 1
        fi
    fi

    # Run full verification to confirm sync worked
    echo ""
    echo "{{BLUE}}Running full verification...{{NORMAL}}"
    just cue-verify
