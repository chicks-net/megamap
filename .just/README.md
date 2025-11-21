# .just directory

Just recipe files live in this directory.

## Source of Truth

The master copy of these project files lives in the
[FINI template-repo](https://github.com/fini-net/template-repo)
and you should be able to copy them into your
project for updates.

You should read our
[release notes](https://github.com/fini-net/template-repo/blob/main/.just/RELEASE_NOTES.md)
to learn more about the history of how we have evolved the github PR process.

We use the
[repos-summary script](https://github.com/chicks-net/chicks-home/blob/main/bin/repos-summary)
to see which of our repos need updates of the just files.

## Included Just Files

### gh-process.just - Git/GitHub Workflow Automation

Core PR lifecycle management with these features:

- **Branch creation** - `just branch <name>` creates dated branches in `$USER/YYYY-MM-DD-<name>` format
- **PR creation** - `just pr` creates PRs using first commit message as title, all commits in body
- **PR checks monitoring** - Watches GitHub Actions checks with 5-second polling
- **AI integration** - Displays GitHub Copilot and Claude Code review comments after checks complete
- **PR merge** - `just merge` squash merges, deletes remote branch, returns to main, and pulls latest
- **Branch escape** - `just sync` returns to main branch and pulls latest changes
- **Web viewing** - `just prweb` opens current PR in browser
- **Releases** - `just release <version>` creates GitHub releases with auto-generated notes
- **Sanity checks** - Hidden recipes (`_on_a_branch`, `_has_commits`, `_main_branch`) prevent mistakes
- **Pre-PR hooks** - Optional integration with `pr-hook.just` for project-specific automation

### compliance.just - Repository Health Checks

Custom compliance validation for GitHub community standards:

- **README.md** validation
- **LICENSE** file check
- **Code of Conduct** verification (`.github/CODE_OF_CONDUCT.md`)
- **Contributing Guide** check (`.github/CONTRIBUTING.md`)
- **Security Policy** validation (`.github/SECURITY.md`)
- **Pull Request Template** check (`.github/pull_request_template.md`)
- **Issue Templates** directory validation (`.github/ISSUE_TEMPLATE/`)
- **Repository description** check via GitHub API
- **CODEOWNERS** file validation
- **`.gitignore`** file check
- **`.gitattributes`** file verification
- **`justfile`** presence check
- **`.editorconfig`** validation

All checks include colorized output with helpful (and sometimes sarcastic) messages.

### shellcheck.just - Bash Script Linting

Automated shellcheck validation for bash scripts in just recipes:

- **Automatic detection** - Scans all justfiles in repo (`justfile` and `.just/*.just`)
- **Script extraction** - Uses awk to extract bash scripts (looks for `#!/usr/bin/env bash` or `#!/bin/bash`)
- **Temporary file handling** - Creates temp files for each script and cleans up on exit
- **Shellcheck execution** - Runs shellcheck with `-x -s bash` flags for thorough validation
- **Detailed reporting** - Shows which file and recipe each issue is in, with colorized output
- **Statistics** - Reports total scripts checked and issues found
- **Exit codes** - Returns 1 if issues found, 0 if all scripts pass

### pr-hook.just - Pre-PR Hook Template

Optional pre-PR automation hook:

- **Called automatically** - Invoked by `just pr` if this file exists
- **Placeholder implementation** - Currently just prints a message
- **Customizable** - Replace with project-specific tasks (e.g., Hugo rebuilds, asset compilation)
- **Hidden recipe** - Uses `_pr-hook` naming to indicate internal use only
