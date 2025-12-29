# shellcheck linting for just recipes

# run shellcheck on all bash scripts in just recipes
[group('Compliance')]
shellcheck:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode

    echo "{{MAGENTA}}Running shellcheck on bash scripts in just recipes...{{NORMAL}}"

    # find all justfiles
    JUSTFILES=(justfile .just/*.just)

    # temporary directory for extracted scripts and tracking
    CHECKS_TMPDIR=$(mktemp -d)

    # shellcheck disable=SC2064
    trap "rm -rf $CHECKS_TMPDIR" EXIT

    # use files for tracking across subshells
    ISSUES_FILE="$CHECKS_TMPDIR/issues_count"
    SCRIPTS_FILE="$CHECKS_TMPDIR/scripts_count"
    echo "0" > "$ISSUES_FILE"
    echo "0" > "$SCRIPTS_FILE"

    # process each justfile
    for JUSTFILE in "${JUSTFILES[@]}"; do
        if [[ ! -f "$JUSTFILE" ]]; then
            continue
        fi

        echo "{{BLUE}}Checking $JUSTFILE...{{NORMAL}}"

        # extract shell scripts using awk
        awk -v justfile="$JUSTFILE" -v tmpdir="$CHECKS_TMPDIR" '
        BEGIN {
            in_script = 0
            recipe_name = ""
            script_content = ""
            script_num = 0
        }

        # detect recipe name (line not starting with whitespace, containing a colon)
        # Claude is concerned this will match non-recipes, but the shebang check
        # must also trigger, which is unlikely below a variable name or other
        # mismatches.
        /^[a-zA-Z_]/ && /:/ {
            # extract recipe name (everything before the colon)
            match($0, /^[a-zA-Z_][a-zA-Z0-9_-]*/)
            recipe_name = substr($0, RSTART, RLENGTH)
        }

        # detect bash shebang
        /^[[:space:]]+(#!\/usr\/bin\/env bash|#!\/bin\/bash)/ {
            in_script = 1
            script_content = $0 "\n"
            next
        }

        # if in a script, collect indented lines
        in_script && /^[[:space:]]+/ {
            script_content = script_content $0 "\n"
            next
        }

        # if in a script, collect empty lines (preserve blank lines in scripts)
        in_script && /^[[:space:]]*$/ {
            script_content = script_content $0 "\n"
            next
        }

        # end of script (non-empty, non-indented line starts a new recipe)
        in_script && /^[^[:space:]]/ {
            if (script_content != "") {
                script_num++
                filename = tmpdir "/script_" script_num ".sh"

                # remove leading whitespace from each line to make valid bash
                gsub(/\n[[:space:]]+/, "\n", script_content)
                # remove leading whitespace from first line
                gsub(/^[[:space:]]+/, "", script_content)

                print script_content > filename
                close(filename)

                # print metadata for the shell script to process
                print justfile ":" recipe_name ":" filename
            }
            in_script = 0
            script_content = ""
        }

        END {
            # handle script at end of file
            if (in_script && script_content != "") {
                script_num++
                filename = tmpdir "/script_" script_num ".sh"

                gsub(/\n[[:space:]]+/, "\n", script_content)
                gsub(/^[[:space:]]+/, "", script_content)

                print script_content > filename
                close(filename)
                print justfile ":" recipe_name ":" filename
            }
        }
        ' "$JUSTFILE" | while IFS=: read -r jfile recipe scriptfile; do
            if [[ -f "$scriptfile" ]]; then
                # increment script counter
                SCRIPTS_CHECKED=$(cat "$SCRIPTS_FILE")
                echo $((SCRIPTS_CHECKED + 1)) > "$SCRIPTS_FILE"

                # run shellcheck
                if ! shellcheck -x -s bash "$scriptfile"; then
                    echo "{{RED}}Issues found in $jfile recipe '$recipe'{{NORMAL}}"
                    ISSUES_FOUND=$(cat "$ISSUES_FILE")
                    echo $((ISSUES_FOUND + 1)) > "$ISSUES_FILE"
                else
                    echo "{{GREEN}}✓ $jfile recipe '$recipe' passed shellcheck{{NORMAL}}"
                fi
            fi
        done
    done

    # read final counts
    SCRIPTS_CHECKED=$(cat "$SCRIPTS_FILE")
    ISSUES_FOUND=$(cat "$ISSUES_FILE")

    echo ""
    echo "{{MAGENTA}}Checked $SCRIPTS_CHECKED shell scripts{{NORMAL}}"

    if [[ $ISSUES_FOUND -eq 0 ]]; then
        echo "{{GREEN}}No shellcheck issues found!{{NORMAL}}"
        exit 0
    else
        echo "{{RED}}Found issues in $ISSUES_FOUND script(s){{NORMAL}}"
        exit 1
    fi
