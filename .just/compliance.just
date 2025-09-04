# our own compliance check
[group('Compliance')]
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

    if [[ $(gh repo view --json description | jq -r '.description' | wc -c) -gt 16 ]]; then
        echo "{{GREEN}}[gh] You have a repo description, more evidence that you are undescribable.{{NORMAL}}"
    else
        echo "{{RED}}[gh] You do NOT have a repo description, can you write a word or two please?{{NORMAL}}"
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
