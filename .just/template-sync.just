# Template synchronization recipes - v5.2
# Enables safe updates from template-repo while preserving local customizations
#
# See RELEASE_NOTES.md for detailed history

# Generate versioned checksums from git history (template-repo only)
[group('Template Maintenance')]
checksums_generate:
    #!/usr/bin/env bash
    set -euo pipefail

    # Validate we're in template-repo
    if ! grep -q "fini-net/template-repo" .repo.toml 2>/dev/null; then
        echo "{{YELLOW}}Warning: This recipe is intended for template-repo{{NORMAL}}"
        echo "Are you sure you want to generate checksums? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Aborted"
            exit 0
        fi
    fi

    echo "{{BLUE}}Generating checksums from git history...{{NORMAL}}"

    if ! .just/lib/generate_checksums.sh > .just/CHECKSUMS.json.tmp; then
        echo "{{RED}}Error: Checksum generation failed{{NORMAL}}"
        rm -f .just/CHECKSUMS.json.tmp
        exit 1
    fi

    mv .just/CHECKSUMS.json.tmp .just/CHECKSUMS.json

    # Show summary
    file_count=$(jq '.files | length' .just/CHECKSUMS.json)
    echo "{{GREEN}}Generated .just/CHECKSUMS.json{{NORMAL}}"
    echo "Tracked files: $file_count"

# Update .just modules from template-repo (derived repos only)
[group('Template Maintenance')]
update_from_template:
    #!/usr/bin/env bash
    set -euo pipefail

    # Prevent running in template-repo itself
    if grep -q "fini-net/template-repo" .repo.toml 2>/dev/null; then
        echo "{{RED}}Error: Cannot run update_from_template in template-repo itself{{NORMAL}}"
        echo "Use 'just checksums_generate' to update the manifest"
        exit 1
    fi

    .just/lib/template_update.sh

# Verify local .just files against template versions
[group('Testing/Automation')]
checksums_verify:
    #!/usr/bin/env bash
    set -euo pipefail

    TEMPLATE_URL="https://raw.githubusercontent.com/fini-net/template-repo/main"
    MANIFEST_FILE="/tmp/checksums-verify-$$.json"

    # Platform-compatible checksum
    compute_checksum() {
        local file="$1"
        if command -v sha256sum &>/dev/null; then
            sha256sum "$file" | awk '{print $1}'
        elif command -v shasum &>/dev/null; then
            shasum -a 256 "$file" | awk '{print $1}'
        fi
    }

    # shellcheck disable=SC2329  # cleanup is invoked via trap
    cleanup() {
        rm -f "$MANIFEST_FILE"
    }
    trap cleanup EXIT

    echo "{{BLUE}}Fetching manifest...{{NORMAL}}"
    if ! curl -sSL -f "$TEMPLATE_URL/.just/CHECKSUMS.json" -o "$MANIFEST_FILE" 2>/dev/null; then
        echo "{{RED}}Error: Failed to fetch manifest{{NORMAL}}"
        exit 1
    fi

    echo
    echo "Checking local files (.just/*.just and .just/lib/*.sh):"

    all_match=true

    while IFS= read -r filepath; do
        if [[ ! -f "$filepath" ]]; then
            # Check if this is a cleaned file
            if jq -e --arg fp "$filepath" '.cleaned_files // [] | index($fp) != null' "$MANIFEST_FILE" >/dev/null 2>&1; then
                echo "  {{BLUE}}⊘{{NORMAL}} $filepath - removed by clean_template"
            else
                echo "  {{YELLOW}}⊘{{NORMAL}} $filepath - not present locally"
                all_match=false
            fi
            continue
        fi

        local_sum=$(compute_checksum "$filepath")
        versions_json=$(jq -r ".files[\"$filepath\"].versions // []" "$MANIFEST_FILE")

        # Check if matches any known version
        match_found=false
        matched_version=""
        is_latest=false

        while IFS=$'\t' read -r known_sum known_ver known_latest; do
            if [[ "$local_sum" == "$known_sum" ]]; then
                match_found=true
                # Use placeholder "-" for empty version, convert back to empty
                matched_version="${known_ver//-/}"
                [[ "$known_latest" == "true" ]] && is_latest=true
                break
            fi
        done < <(echo "$versions_json" | jq -r '.[] | "\(.checksum)\t\(if .version == "" then "-" else .version end)\t\(.is_latest)"')

        if [[ "$match_found" == false ]]; then
            echo "  {{YELLOW}}⚠{{NORMAL}} $filepath - local modifications detected"
            all_match=false
        elif [[ "$is_latest" == true ]]; then
            echo "  {{GREEN}}✓{{NORMAL}} $filepath - at latest${matched_version:+ ($matched_version)}"
        else
            echo "  {{BLUE}}⬆{{NORMAL}} $filepath - update available${matched_version:+ (current: $matched_version)}"
            all_match=false
        fi
    done < <(jq -r '.files | keys[]' "$MANIFEST_FILE")

    echo
    if [[ "$all_match" == true ]]; then
        echo "{{GREEN}}All files are at latest template versions{{NORMAL}}"
        exit 0
    else
        echo "{{YELLOW}}Some files differ from template{{NORMAL}}"
        echo "Run 'just update_from_template' to update"
        exit 1
    fi

# Show diff between local and latest template version
[group('Template Maintenance')]
checksums_diff filepath:
    #!/usr/bin/env bash
    set -euo pipefail

    TEMPLATE_URL="https://raw.githubusercontent.com/fini-net/template-repo/main"
    temp_file="/tmp/template-version-$$"

    cleanup() {
        rm -f "$temp_file"
    }
    trap cleanup EXIT

    if [[ ! -f "{{filepath}}" ]]; then
        echo "{{RED}}Error: Local file not found: {{filepath}}{{NORMAL}}"
        exit 1
    fi

    echo "{{BLUE}}Fetching latest template version...{{NORMAL}}"
    if ! curl -sSL -f "$TEMPLATE_URL/{{filepath}}" -o "$temp_file" 2>/dev/null; then
        echo "{{RED}}Error: Failed to fetch template version{{NORMAL}}"
        exit 1
    fi

    echo
    diff -u "{{filepath}}" "$temp_file" || true

# test template sync logic
[group('Testing/Automation')]
template_sync_test:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "{{BLUE}}Testing template sync logic...{{NORMAL}}"

    if .just/lib/template_sync_test.sh; then
        echo "{{GREEN}}All template sync tests passed!{{NORMAL}}"
    else
        echo "{{RED}}Some template sync tests failed{{NORMAL}}"
        exit 1
    fi
