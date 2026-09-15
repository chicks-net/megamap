# our own repo compliance check
[group('Testing/Compliance')]
compliance_check:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode without tracing

    echo "{{BLUE}}Chicks' repo compliance check...{{NORMAL}}"

    if [[ -e README.md ]]; then
        echo "{{GREEN}}You have a README.md, thank you.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have a README.md, hmmmm, why is this repo here?{{NORMAL}}"
    fi

    if [[ -e LICENSE ]]; then
        echo "{{GREEN}}[gh] You have a license, good for you.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a license, are you feeling ok?{{NORMAL}}"
    fi

    if [[ -e .github/CODE_OF_CONDUCT.md ]]; then
        echo "{{GREEN}}[gh] You have a Code of Conduct, respect.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a Code of Conduct.  So anything goes around here?{{NORMAL}}"
    fi

    if [[ -e .github/CONTRIBUTING.md ]]; then
        echo "{{GREEN}}[gh] You have a Contributing Guide, how giving.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a Contributing Guide.  Hopefully they'll figure it out on their own.{{NORMAL}}"
    fi

    if [[ -e .github/SECURITY.md ]]; then
        echo "{{GREEN}}[gh] You have a Security Guide, very comforting.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a Security Guide.  Don't call the cops.{{NORMAL}}"
    fi

    if [[ -e .github/pull_request_template.md ]]; then
        echo "{{GREEN}}[gh] You have a pull request template, not too pushy.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a pull request template.  Prepare for anything.{{NORMAL}}"
    fi

    if [[ -d .github/ISSUE_TEMPLATE ]]; then
        echo "{{GREEN}}[gh] You have Issue Templates, life is good.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have Issue Templates.  I must take issue with that.{{NORMAL}}"
    fi

    # Assignment in an `if` so a gh failure (missing gh, expired auth, API
    # error) skips just this check instead of aborting the recipe under
    # `set -euo pipefail` or reporting a false verdict off an empty
    # substitution (matches the REPO_META pattern below).
    if desc_json=$(gh repo view --json description 2>/dev/null); then
        desc_len=$(echo "$desc_json" | jq -r '.description' | wc -c)
        if [[ "$desc_len" -gt 16 ]]; then
            echo "{{GREEN}}[gh] You have a repo description, more evidence that you are undescribable.{{NORMAL}}"
        else
            echo "{{RED}}[gh] You do NOT have a repo description, can you write a word or two please?{{NORMAL}}"
        fi
    else
        echo "{{YELLOW}}[gh] Repo description check skipped: gh repo view failed (auth/network?){{NORMAL}}"
    fi

    # Social preview image (Settings > General > Social preview).
    # The REST `repos/{owner}/{repo}` endpoint does not expose this; GraphQL
    # `usesCustomOpenGraphImage` is true only when an admin has uploaded one.
    # Single `gh repo view` for owner+name (matches the single-fetch pattern
    # used by the rulesets and releases_json fetches below); the assignment
    # sits in an `if` so a gh failure skips just this check rather than
    # aborting the recipe under `set -euo pipefail` (cf. the rulesets/
    # releases_json `|| echo` fallbacks).
    if REPO_META=$(gh repo view --json owner,name 2>/dev/null); then
        REPO_OWNER=$(echo "$REPO_META" | jq -r '.owner.login')
        REPO_NAME=$(echo "$REPO_META" | jq -r '.name')
        # shellcheck disable=SC2016  # $owner/$name are GraphQL vars, not bash
        if GQL=$(gh api graphql -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){usesCustomOpenGraphImage}}' -F owner="$REPO_OWNER" -F name="$REPO_NAME" --jq '.data.repository.usesCustomOpenGraphImage' 2>/dev/null); then
            if [[ "$GQL" == "true" ]]; then
                echo "{{GREEN}}[gh] You have a custom social preview image, looking sharp out there.{{NORMAL}}"
            else
                echo "{{RED}}[gh] You do NOT have a custom social preview image.  Settings > General > Social preview, upload one.{{NORMAL}}"
            fi
        else
            echo "{{RED}}[gh] Could not reach GitHub to check social preview.  Is gh authed and online?{{NORMAL}}"
        fi
    else
        echo "{{RED}}[gh] Could not reach GitHub to check social preview.  Is gh authed and online?{{NORMAL}}"
    fi

    # github also checks for something about the repo admins

    if [[ -e .github/CODEOWNERS ]]; then
        echo "{{GREEN}}You have a CODEOWNERS file, in DEED.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have a CODEOWNERS file.  Does anyone want to make a claim?{{NORMAL}}"
    fi

    if [[ -e .gitignore ]]; then
        echo "{{GREEN}}You have a .gitignore file, so there will be less debris in your future.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have a .gitignore file.  I expect you to keep ignoring my advice!{{NORMAL}}"
    fi

    if [[ -e .gitattributes ]]; then
        echo "{{GREEN}}You have a .gitattributes file, keeping metadata and line endings clean too.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have a .gitattributes file.  Did you hear what happens when binaries and text files get together?{{NORMAL}}"
    fi

    if [[ -e justfile ]]; then
        echo "{{GREEN}}You have a {{BLUE}}justfile{{GREEN}}, spreading justice and automation a little further.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have a justfile.  Feeling the FOMO yet?{{NORMAL}}"
        echo "{{RED}}And this should not be possible.  Tell me how you got here.{{NORMAL}}"
    fi

    if [[ -e .editorconfig ]]; then
        echo "{{GREEN}}You have an {{BLUE}}.editorconfig{{GREEN}}, keeping tabs and spaces segregated.{{NORMAL}}"
    else
        echo "{{RED}}You do NOT have an .editorconfig.  Will your world explode when the tabs and spaces get together?{{NORMAL}}"
    fi

    # Check for branch protection on main branch (repo-level or org-level rulesets)
    # Single fetch shared with the [gh,openssf] Code-Review check below.
    rulesets=$(gh api 'repos/{owner}/{repo}/rulesets' 2>/dev/null || echo '[]')
    active_ruleset_ids=$(echo "$rulesets" | jq -r '.[] | select(.enforcement == "active" and .target == "branch") | .id')
    if echo "$active_ruleset_ids" | grep -q .; then
        echo "{{GREEN}}[gh] You have branch protection enabled, keeping the main branch safe from accidents.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have branch protection enabled.  Living dangerously, are we?{{NORMAL}}"
    fi

    # --- OpenSSF Scorecard-aligned checks (https://github.com/ossf/scorecard) ---
    # Shell heuristics, not a faithful Scorecard reimplementation, and purely
    # informational like everything above.  Only File-Existence-style heuristics;
    # requires `file` for the Binary-Artifacts check.

    if command -v file >/dev/null 2>&1; then
        binaries=$(git ls-files -z | xargs -0 file -- 2>/dev/null | grep -E 'ELF|Mach-O|PE32|MS Windows|JPEG|PNG|GIF|Web/P|PDF' | cut -d: -f1 || true)
        large_blobs=$(git ls-files -z | xargs -0 wc -c 2>/dev/null | awk '$1 > 1000000 && $2 != "total" {found++} END {print found+0}')
        if [[ -z "$binaries" && "${large_blobs:-0}" -eq 0 ]]; then
            echo "{{GREEN}}[openssf] No binary artifacts in git, your repo is surgically clean.{{NORMAL}}"
        else
            echo "{{RED}}[openssf] Binary artifacts committed: $(echo "$binaries" | tr '\n' ' ') plus $large_blobs blob(s) over 1MB.  Git is not a dumpster.{{NORMAL}}"
        fi
    else
        echo "{{BLUE}}[openssf] 'file' command not found, skipping the Binary-Artifacts check.  No judgment.{{NORMAL}}"
    fi

    # CI-Tests: workflows that actually run tests
    # bare-word tokens get \b boundaries so 'jest' can't match 'majestic' etc.;
    # also \b before 'just' so 'adjust testing' can't match mid-word
    test_cmds='npm test|npm run test|pytest|go test|cargo test|make test|bazel test|mvn test|gradle test|deno test|\b(tox|jest|rspec|vitest)\b|\bjust [a-z0-9_-]*test'
    if [[ -d .github/workflows ]] && grep -lrE "$test_cmds" .github/workflows >/dev/null 2>&1; then
        echo "{{GREEN}}[openssf] CI runs tests on every push, machines grinding so humans can look away.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] No workflow found that runs tests.  Testing is for people who plan to be around later.{{NORMAL}}"
    fi

    # Code-Review: ruleset on the default branch requiring pull request reviews
    # (overlaps the [gh] community-standards branch protection check above,
    # reusing the same rulesets fetch instead of re-hitting the API)
    code_review_ok=false
    for id in $active_ruleset_ids; do
        if gh api "repos/{owner}/{repo}/rulesets/$id" --jq '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count > 0 or .parameters.dismiss_stale_reviews_on_push or .parameters.require_code_owner_review' 2>/dev/null | grep -q true; then
            code_review_ok=true
            break
        fi
    done
    if [[ "$code_review_ok" == "true" ]]; then
        echo "{{GREEN}}[gh,openssf] Branch rulesets require pull request reviews, code never travels alone.{{NORMAL}}"
    else
        echo "{{RED}}[gh,openssf] No ruleset found requiring pull request reviews.  Somewhere, code walks the streets unsupervised.{{NORMAL}}"
    fi

    # Dangerous-Workflow: pull_request_target with secrets, or sudo in workflows
    prt_wfs=""
    sudo_wfs=""
    dangerous=""
    if [[ -d .github/workflows ]]; then
        prt_wfs=$(grep -rl 'pull_request_target' .github/workflows 2>/dev/null || true)
        if [[ -n "$prt_wfs" ]]; then
            # \b (left boundary only, GNU/BSD extension) rather than -w:
            # -w demands a non-word char AFTER the match, but real usage
            # is secrets.NAME, so -w never matches
            dangerous=$(echo "$prt_wfs" | xargs grep -lE '\bsecrets\.' 2>/dev/null || true)
        fi
        # -w so 'sudo' can't match inside 'pseudorandom' or 'sudoers'
        sudo_wfs=$(grep -rlw 'sudo' .github/workflows 2>/dev/null || true)
    fi
    if [[ -z "$dangerous" && -z "$sudo_wfs" ]]; then
        echo "{{GREEN}}[openssf] No dangerous workflow patterns, your automations mind their manners.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] Dangerous workflow pattern(s) found: pull_request_target with secrets: ${dangerous:-none}; sudo: ${sudo_wfs:-none}.  Handle with gloves.{{NORMAL}}"
    fi

    # Dependency-Update-Tool: dependabot or renovate config
    if [[ -e .github/dependabot.yml || -e .github/renovate.json || -e .github/renovate.json5 || -e renovate.json || -e renovate.json5 ]]; then
        echo "{{GREEN}}[openssf] Automated dependency updates configured, your dependencies get fresh air and exercise.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] No dependabot.yml or renovate config.  Your dependencies are on their own.{{NORMAL}}"
    fi

    # Maintained: some commit activity in the last 90 days
    last_commit=$(git log -1 --format=%ct 2>/dev/null || echo 0)
    if [[ "$last_commit" -gt $(( $(date +%s) - 90 * 86400 )) ]]; then
        echo "{{GREEN}}[openssf] Repo has recent activity, somebody actually lives here.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] No commits in over 90 days, the cobwebs are collecting interest{{NORMAL}}"
    fi

    # Pinned-Dependencies: workflow 'uses:' lines pinned to a full SHA (or container digest)
    unpinned=""
    if [[ -d .github/workflows ]]; then
        # repo-local actions (uses: ./path) need no pin - exclude them;
        # [[:space:]] instead of \s for BSD/GNU grep portability;
        # dash optional in the pattern since 'uses:' appears as a YAML
        # list item ('- uses:') in some styles and bare in others
        unpinned=$(grep -rhE '^[[:space:]]*(-[[:space:]]+)?uses:' .github/workflows 2>/dev/null | grep -v 'uses:[[:space:]]*\.\/' | grep -vE '@([0-9a-fA-F]{40}|sha256:[0-9a-f]{64})' || true)
    fi
    if [[ -z "$unpinned" ]]; then
        echo "{{GREEN}}[openssf] All workflow actions are SHA-pinned, no tag-surfing for supply-chain pirates.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] Unpinned actions found: $(echo "$unpinned" | tr -d ' ' | tr '\n' ';' ).  Pin them to a full SHA or the mermaid songs will come for you.{{NORMAL}}"
    fi

    # Packaging: workflows that publish or release artifacts
    if [[ -d .github/workflows ]] && grep -lrEi 'npm publish|gh release|docker push|twine upload|cargo publish|gem push|nuget push|mvn deploy' .github/workflows >/dev/null 2>&1; then
        echo "{{GREEN}}[openssf] Workflow publishes to a registry/release channel, your code gets out in the world (licensed, of course).{{NORMAL}}"
    else
        echo "{{RED}}[openssf] No publishing workflow detected.  Alpha geeks everywhere are disappointed.{{NORMAL}}"
    fi

    # SAST: static analysis workflow presence
    if [[ -d .github/workflows ]] && grep -lrEi 'codeql|sonarcloud|sonarqube|semgrep' .github/workflows >/dev/null 2>&1; then
        echo "{{GREEN}}[openssf] SAST workflow found, the machines are reading your code so the hackers don't have to.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] No SAST workflow (CodeQL, SonarCloud, Semgrep, etc.) found.  Vulnerabilities left to their own devices.{{NORMAL}}"
    fi

    # Signed-Releases: release assets with cryptographic signatures
    # One API call yields both the release count and the asset names.
    releases_json=$(gh api 'repos/{owner}/{repo}/releases?per_page=10' 2>/dev/null || echo '[]')
    release_count=$(echo "$releases_json" | jq 'length')
    signed_assets=$(echo "$releases_json" | jq -r '.[].assets[].name' 2>/dev/null | grep -Ei '\.(sig|asc|pem|intoto\.jsonl)$' || true)
    if [[ -n "$signed_assets" ]]; then
        echo "{{GREEN}}[openssf] Latest releases include signed assets, tamper-proofing for the paranoid and prudent.{{NORMAL}}"
    elif [[ "${release_count:-0}" -eq 0 ]]; then
        echo "{{BLUE}}[openssf] No releases found, skipping the signed-release check.  Nothing to sign yet.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] Releases exist but none of the latest ones have signed assets (.sig, .asc, .pem, .intoto.jsonl).  Unsigned releases, eh?  Bold.{{NORMAL}}"
    fi

    # Token-Permissions: workflows declaring a top-level permissions block
    # Anchored to '^permissions:' because '^[[:space:]]*permissions:' also
    # matched job-level indented blocks, silently reporting GREEN for
    # workflows with no top-level block at all.
    missing_perms=""
    if [[ -d .github/workflows ]]; then
        missing_perms=$(grep -rLE '^permissions:' .github/workflows 2>/dev/null || true)
    fi
    if [[ -z "$missing_perms" ]]; then
        echo "{{GREEN}}[openssf] All workflows declare a top-level permissions block, least privilege is the best privilege.{{NORMAL}}"
    else
        echo "{{RED}}[openssf] Workflow(s) missing top-level 'permissions:' block: $(echo "$missing_perms" | tr '\n' ' ').  Grant them a trust fall, why don't you.{{NORMAL}}"
    fi

# validate that git-tracked files conform to .editorconfig
# (editorconfig-checker exits non-zero on the first offending file set)
# Best-effort gate: missing tool or missing .editorconfig warns and exits 0
# so the check never blocks a push in repos that opted out.  CI
# (.github/workflows/editorconfig.yml) remains the hard enforcement.
# See: https://github.com/fini-net/template-repo/issues/329
[group('Testing/Compliance')]
editorconfig_check:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    if [[ ! -e .editorconfig ]]; then
        echo "{{YELLOW}}No .editorconfig found - skipping editorconfig check.{{NORMAL}}"
        exit 0
    fi

    if ! command -v editorconfig-checker >/dev/null 2>&1; then
        echo "{{YELLOW}}editorconfig-checker is not installed - skipping editorconfig check.{{NORMAL}}"
        echo "{{YELLOW}}Install with: brew install editorconfig-checker (or see https://editorconfig-checker.github.io){{NORMAL}}"
        exit 0
    fi

    if editorconfig-checker; then
        echo "{{GREEN}}All files conform to .editorconfig - your indentation is beyond reproach.{{NORMAL}}"
    else
        echo ""
        echo "{{RED}}editorconfig check failed.{{NORMAL}}"
        echo "{{RED}}Common culprit: RELEASE_NOTES.md numbered-list continuation lines with 3-space indent (aligning under '1. ').{{NORMAL}}"
        echo "{{RED}}Continuation indents must be a multiple of 2 (2 or 4 spaces).  See CLAUDE.md 'Versioning .just/* changes'.{{NORMAL}}"
        exit 1
    fi
