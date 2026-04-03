# Claude Code management recipes

claude_settings_file := ".claude/settings.local.json"

# Sort Claude Code permissions in canonical order
[group('Claude Code')]
claude_permissions_sort:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode without tracing

    BACKUP_FILE=".claude/settings.local.json.backup"

    echo "{{BLUE}}Sorting Claude Code permissions...{{NORMAL}}"

    # Check if file exists
    if [[ ! -f "{{ claude_settings_file }}" ]]; then
        echo "{{RED}}Error: {{ claude_settings_file }} not found{{NORMAL}}"
        exit 1
    fi

    # Validate input JSON
    if ! jq empty "{{ claude_settings_file }}" 2>/dev/null; then
        echo "{{RED}}Error: {{ claude_settings_file }} is not valid JSON{{NORMAL}}"
        exit 1
    fi

    # Create backup
    cp "{{ claude_settings_file }}" "$BACKUP_FILE"
    echo "{{YELLOW}}Created backup: $BACKUP_FILE{{NORMAL}}"

    # Sort permissions with grouping strategy
    # Group 1: Bash (most commonly modified)
    # Group 2: WebFetch (domain restrictions)
    # Group 3: WebSearch (standalone)
    # Group 4: Other (future-proof)
    if jq '
      .permissions.allow |= (
        map(
          if startswith("Bash(") then {type: "1-Bash", perm: .}
          elif startswith("WebFetch(") then {type: "2-WebFetch", perm: .}
          elif startswith("WebSearch") then {type: "3-WebSearch", perm: .}
          else {type: "9-Other", perm: .}
          end
        ) |
        sort_by([.type, .perm]) |
        map(.perm)
      ) |
      .permissions.deny |= sort |
      .permissions.ask |= sort
    ' "$BACKUP_FILE" > "{{ claude_settings_file }}"; then

        # Validate output JSON
        if ! jq empty "{{ claude_settings_file }}" 2>/dev/null; then
            echo "{{RED}}Error: Sorting produced invalid JSON, restoring from backup{{NORMAL}}"
            cp "$BACKUP_FILE" "{{ claude_settings_file }}"
            exit 1
        fi

        # Remove backup on success
        rm "$BACKUP_FILE"

        # Show permission counts
        ALLOW_COUNT=$(jq '.permissions.allow | length' "{{ claude_settings_file }}")
        DENY_COUNT=$(jq '.permissions.deny | length' "{{ claude_settings_file }}")
        ASK_COUNT=$(jq '.permissions.ask | length' "{{ claude_settings_file }}")

        echo "{{GREEN}}Permissions sorted successfully!{{NORMAL}}"
        echo "{{BLUE}}Allow: $ALLOW_COUNT | Deny: $DENY_COUNT | Ask: $ASK_COUNT{{NORMAL}}"
    else
        echo "{{RED}}Error: jq sorting failed, restoring from backup{{NORMAL}}"
        cp "$BACKUP_FILE" "{{ claude_settings_file }}"
        exit 1
    fi

# Check Claude Code permissions structure
[group('Claude Code')]
claude_permissions_check:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode without tracing

    echo "{{BLUE}}Checking Claude Code permissions structure...{{NORMAL}}"

    # Check if file exists
    if [[ ! -f "{{ claude_settings_file }}" ]]; then
        echo "{{RED}}Error: {{ claude_settings_file }} not found{{NORMAL}}"
        exit 1
    fi

    # Validate JSON
    if ! jq empty "{{ claude_settings_file }}" 2>/dev/null; then
        echo "{{RED}}Error: {{ claude_settings_file }} is not valid JSON{{NORMAL}}"
        exit 1
    fi

    # Check for required structure
    if ! jq -e '.permissions' "{{ claude_settings_file }}" >/dev/null 2>&1; then
        echo "{{RED}}Error: Missing .permissions object{{NORMAL}}"
        exit 1
    fi

    if ! jq -e '.permissions.allow' "{{ claude_settings_file }}" >/dev/null 2>&1; then
        echo "{{YELLOW}}Warning: Missing .permissions.allow array{{NORMAL}}"
    fi

    if ! jq -e '.permissions.deny' "{{ claude_settings_file }}" >/dev/null 2>&1; then
        echo "{{YELLOW}}Warning: Missing .permissions.deny array{{NORMAL}}"
    fi

    if ! jq -e '.permissions.ask' "{{ claude_settings_file }}" >/dev/null 2>&1; then
        echo "{{YELLOW}}Warning: Missing .permissions.ask array{{NORMAL}}"
    fi

    # Show permission counts
    ALLOW_COUNT=$(jq '.permissions.allow | length' "{{ claude_settings_file }}" 2>/dev/null || echo "0")
    DENY_COUNT=$(jq '.permissions.deny | length' "{{ claude_settings_file }}" 2>/dev/null || echo "0")
    ASK_COUNT=$(jq '.permissions.ask | length' "{{ claude_settings_file }}" 2>/dev/null || echo "0")

    echo "{{GREEN}}Permissions structure is valid{{NORMAL}}"
    echo "{{BLUE}}Allow: $ALLOW_COUNT | Deny: $DENY_COUNT | Ask: $ASK_COUNT{{NORMAL}}"

    # Show grouping breakdown for allow list
    if [[ $ALLOW_COUNT -gt 0 ]]; then
        echo ""
        echo "{{BLUE}}Permission types in allow list:{{NORMAL}}"
        BASH_COUNT=$(jq '[.permissions.allow[] | select(startswith("Bash("))] | length' "{{ claude_settings_file }}")
        WEBFETCH_COUNT=$(jq '[.permissions.allow[] | select(startswith("WebFetch("))] | length' "{{ claude_settings_file }}")
        WEBSEARCH_COUNT=$(jq '[.permissions.allow[] | select(startswith("WebSearch"))] | length' "{{ claude_settings_file }}")
        OTHER_COUNT=$((ALLOW_COUNT - BASH_COUNT - WEBFETCH_COUNT - WEBSEARCH_COUNT))

        echo "  Bash: $BASH_COUNT"
        echo "  WebFetch: $WEBFETCH_COUNT"
        echo "  WebSearch: $WEBSEARCH_COUNT"
        if [[ $OTHER_COUNT -gt 0 ]]; then
            echo "  Other: $OTHER_COUNT"
        fi
    fi
