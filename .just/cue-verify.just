# File Format Self-checks

# use Cue to verify /.repo.toml validity and flag configuration
[group('Testing/Compliance')]
cue-verify:
    #!/usr/bin/env bash
    set -euo pipefail

    # Shared org/repo extraction + web_url/origin cross-checks (#420)
    source .just/lib/repo_urls.sh

    # Stage 1: Cue validates TOML structure and types
    cue vet .repo.toml docs/repo-toml.cue
    echo "{{GREEN}}Cue structure validation passed.{{NORMAL}}"

    # Extract org/repo names once at the top for all stages. urls.web_url
    # is the config source of truth; the shared helper rejects anything
    # that is not a github.com org/repo URL, which stage 3 below treats
    # as "cannot extract" (#420).
    if ORG_REPO_PAIR=$(repo_toml_org_repo); then
        read -r ORG_NAME REPO_NAME <<<"$ORG_REPO_PAIR"
    else
        ORG_NAME=""
        REPO_NAME=""
    fi

    # Stage 2: Validate flags match actual configuration
    echo "{{BLUE}}Verifying .repo.toml flags match repository configuration...{{NORMAL}}"

    # Extract flags from .repo.toml using cue export + jq
    CLAUDE_FLAG=$(cue export .repo.toml | jq -r '.flags.claude // false')
    CLAUDE_REVIEW_FLAG=$(cue export .repo.toml | jq -r '.flags."claude-review" // false')
    COPILOT_REVIEW_FLAG=$(cue export .repo.toml | jq -r '.flags."copilot-review" // false')
    STANDARD_RELEASE_FLAG=$(cue export .repo.toml | jq -r 'if .flags."standard-release" == false then "false" else "true" end')
    ASCIINEMA_RECORD_FLAG=$(cue export .repo.toml | jq -r 'if .flags."asciinema-record" == true then "true" else "false" end')

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

    # Validate asciinema-record flag (soft warn - CI runners won't have
    # asciinema installed and the recipes degrade gracefully to unrecorded
    # runs, so a missing binary is not a hard error)
    if [[ "$ASCIINEMA_RECORD_FLAG" == "true" ]]; then
        # casts are sensitive local artifacts (#375): a recording can
        # capture gh output, tokens echoed by a misbehaving tool, or
        # accidentally displayed files
        echo "{{YELLOW}}[flags.asciinema-record] cast files may capture sensitive output - review before sharing{{NORMAL}}"
        if command -v asciinema >/dev/null 2>&1; then
            echo "{{GREEN}}[flags.asciinema-record] asciinema found - pr/again recipes will record into .cache/{{NORMAL}}"
        else
            echo "{{YELLOW}}[flags.asciinema-record] asciinema not found on PATH{{NORMAL}}"
            echo "{{YELLOW}}  pr/again recipes will warn and run unrecorded{{NORMAL}}"
            echo "{{YELLOW}}  Install with: brew install asciinema{{NORMAL}}"
        fi
        # pr/again append '/.cache' to .gitignore themselves when it is
        # not ignored yet, but surface the gap here too so it is visible
        # before the first recording run. The probe path is a file under
        # the directory (.cache/x.cast), not the directory itself:
        # directory-only patterns like '.cache/' do not match a path
        # that does not exist yet, so probing '.cache' warned spuriously
        # in exactly that case, while the child path matches both
        # '/.cache' and '.cache/' rules either way (Claude review of
        # #427, item 3). check-ignore's non-zero exits are handled cases
        # (#326/#327 convention): 1 = definitively not ignored, anything
        # else (e.g. 128 outside a repo) just means the probe cannot
        # tell, so warn only on the definitive answer.
        CACHE_IGNORE_RC=0
        git check-ignore -q .cache/x.cast || CACHE_IGNORE_RC=$?
        if [[ "$CACHE_IGNORE_RC" -eq 1 ]]; then
            echo "{{YELLOW}}[flags.asciinema-record] /.cache is not gitignored - the next pr/again recording will append it to .gitignore{{NORMAL}}"
        fi
    fi

    # Stage 3: Validate GitHub metadata sync
    echo "{{BLUE}}Verifying description and topics match GitHub...{{NORMAL}}"

    # Cross-check urls.web_url against the git origin remote (#420). A
    # derived repo with stale template URLs used to compare its metadata
    # against template-repo on *both* sides of the stage 3 comparison
    # below and pass. A repo-name mismatch is the stale template-URL
    # failure and is fatal; an org-only mismatch is the normal
    # contributor-fork shape and only warns, since verification
    # legitimately runs against the repo named in web_url.
    if [[ -n "$ORG_NAME" && -n "$REPO_NAME" ]] && ORIGIN_ORG_REPO=$(origin_org_repo); then
        URL_STATUS=$(classify_url_mismatch "$ORG_NAME $REPO_NAME" "$ORIGIN_ORG_REPO")
        ORIGIN_SLASH=${ORIGIN_ORG_REPO/ /\/}
        if [[ "$URL_STATUS" == "name-mismatch" ]]; then
            echo "{{RED}}[urls] web_url points at $ORG_NAME/$REPO_NAME but the origin remote is $ORIGIN_SLASH{{NORMAL}}"
            echo "{{RED}}  Stale template URLs make the metadata check below compare the wrong repo.{{NORMAL}}"
            echo "{{RED}}  Repoint [urls] in .repo.toml at the origin remote. See #420.{{NORMAL}}"
            ERRORS=$((ERRORS + 1))
        elif [[ "$URL_STATUS" == "org-mismatch" ]]; then
            echo "{{YELLOW}}[urls] org in .repo.toml ($ORG_NAME) differs from the origin remote ($ORIGIN_SLASH){{NORMAL}}"
            echo "{{YELLOW}}  Expected in a fork clone - verifying against the repo named in web_url{{NORMAL}}"
        fi
    elif [[ -n "$ORG_NAME" && -n "$REPO_NAME" ]]; then
        echo "{{YELLOW}}[urls] origin remote unavailable - skipping web_url cross-check{{NORMAL}}"
    fi

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

    # Shared org/repo extraction + web_url/origin cross-checks (#420)
    source .just/lib/repo_urls.sh

    echo "{{BLUE}}Syncing description and topics from GitHub...{{NORMAL}}"

    REPO_TOML_EXISTS=false
    if [[ -f .repo.toml ]]; then
        REPO_TOML_EXISTS=true
    fi

    # Extract org and repo name from .repo.toml (config source of truth)
    if $REPO_TOML_EXISTS && ORG_REPO_PAIR=$(repo_toml_org_repo); then
        read -r ORG_NAME REPO_NAME <<<"$ORG_REPO_PAIR"

        # Refuse to sync the wrong repo: cross-check urls.web_url against
        # the git origin remote. A derived repo whose .repo.toml still
        # pointed at template-repo used to receive the template's
        # description and topics here, "successfully", because every
        # later step - including the trailing cue-verify - read the same
        # stale URL. See #420.
        if ORIGIN_ORG_REPO=$(origin_org_repo); then
            URL_STATUS=$(classify_url_mismatch "$ORG_REPO_PAIR" "$ORIGIN_ORG_REPO")
            if [[ "$URL_STATUS" != "match" ]]; then
                ORIGIN_SLASH=${ORIGIN_ORG_REPO/ /\/}
                echo "{{RED}}Error: refusing to sync - .repo.toml [urls] disagree with the git origin remote (#420){{NORMAL}}"
                echo "  .repo.toml web_url : $ORG_NAME/$REPO_NAME"
                echo "  origin remote      : $ORIGIN_SLASH"
                echo "  Either repoint [urls] in .repo.toml at the origin remote:"
                echo "    git_ssh = \"git@github.com:$ORIGIN_SLASH.git\""
                echo "    web_url = \"https://github.com/$ORIGIN_SLASH\""
                echo "  ...or point the origin remote at $ORG_NAME/$REPO_NAME, if that is the intent."
                exit 1
            fi
        fi
    fi

    # Fall back to git remote if .repo.toml is missing or parsing failed
    if [[ -z "${ORG_NAME:-}" || -z "${REPO_NAME:-}" ]]; then
        if ORG_REPO_PAIR=$(origin_org_repo); then
            read -r ORG_NAME REPO_NAME <<<"$ORG_REPO_PAIR"
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

        # The state-aware awk program lives in .just/lib/cue_sync.awk so this
        # recipe and its tests share one implementation. Test coverage exists
        # in template-repo only; clean_template removes the test runner from
        # derived repos. See issue #196 for why the program is no longer inlined.
        # Behavior: handles three cases for each key (description, topics):
        #   1. Active line (e.g. `topics = [...]`)        -> replace in place
        #   2. Commented line (e.g. `# topics = [...]`)   -> replace in place
        #   3. Missing line                               -> insert inside [about] block
        # Missing keys are inserted at the end of the `[about]` block, *before*
        # any trailing blank line that separates it from the next section,
        # landing adjacent to the preceding key (e.g. `license`) rather than
        # visually attaching to the next `[section]`. See issue #165 for the
        # failure modes this addresses.
        #
        # Description is passed via the environment (desc=...), not awk's -v,
        # because -v processes backslash escape sequences before the program
        # runs, which would mangle backslashes in the GitHub description. The
        # awk program applies TOML-escaping (backslash and double-quote) on
        # emit, so the output is valid TOML regardless of the description's
        # contents. See issue #198.
        desc="$GH_DESC" awk -v topics="[$TOPICS_TOML]" \
            -f .just/lib/cue_sync.awk .repo.toml > .repo.toml.tmp
        mv .repo.toml.tmp .repo.toml

        # Validate the TOML is still valid after modification.
        # NOTE: cue vet passing does NOT prove the sync wrote the right values
        # (topics is optional in the CUE schema), so the backup is preserved
        # until the trailing `just cue-verify` also passes. See issue #165.
        echo "{{BLUE}}Validating modified TOML...{{NORMAL}}"
        if ! cue vet .repo.toml docs/repo-toml.cue; then
            mv .repo.toml.backup .repo.toml
            echo "{{RED}}Sync failed - TOML validation error. Restored from backup.{{NORMAL}}"
            exit 1
        fi

        # Run full verification (this catches silent topics/description write
        # failures that cue vet cannot, by comparing against the GitHub API).
        echo ""
        echo "{{BLUE}}Running full verification...{{NORMAL}}"
        if ! just cue-verify; then
            mv .repo.toml.backup .repo.toml
            echo "{{RED}}Sync failed - verification mismatch. Restored from backup.{{NORMAL}}"
            exit 1
        fi

        rm .repo.toml.backup
        echo "{{GREEN}}Successfully synced from GitHub to .repo.toml{{NORMAL}}"
    else
        echo "{{YELLOW}}.repo.toml not found - creating from GitHub metadata{{NORMAL}}"

        GIT_SSH="git@github.com:$ORG_NAME/$REPO_NAME.git"
        WEB_URL="https://github.com/$ORG_NAME/$REPO_NAME"

        # TOML-escape the description for the new file: backslash -> \\ and
        # double-quote -> \". Without this, a description containing a
        # backslash (e.g. `C:\path`) produces invalid TOML and cue vet fails,
        # leaving the repo unable to bootstrap .repo.toml on first sync.
        # See issue #198.
        GH_DESC_TOML="${GH_DESC//\\/\\\\}"
        GH_DESC_TOML="${GH_DESC_TOML//\"/\\\"}"

        printf '%s\n' \
            "# .repo.toml" \
            "" \
            "[about]" \
            "description = \"$GH_DESC_TOML\"" \
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
            "asciinema-record = false" \
            > .repo.toml

        # Validate the new TOML
        echo "{{BLUE}}Validating new TOML...{{NORMAL}}"
        if ! cue vet .repo.toml docs/repo-toml.cue; then
            rm .repo.toml
            echo "{{RED}}Failed to create valid .repo.toml{{NORMAL}}"
            exit 1
        fi

        # Mirror existing-file branch: clean up on failure (no backup to restore).
        echo ""
        echo "{{BLUE}}Running full verification...{{NORMAL}}"
        if ! just cue-verify; then
            rm .repo.toml
            echo "{{RED}}Newly created .repo.toml failed verification - file removed.{{NORMAL}}"
            exit 1
        fi

        echo "{{GREEN}}Successfully synced from GitHub to .repo.toml{{NORMAL}}"
    fi
