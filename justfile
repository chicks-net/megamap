# project justfile

import? '.just/compliance.just'
import? '.just/gh-process.just'

# list recipes (default works without naming it)
[group('example')]
list:
	just --list
	@echo "{{GREEN}}Your justfile is waiting for more scripts and snippets{{NORMAL}}"

# generate a clean README
[group('Utility')]
[no-cd]
clean_readme:
    #!/usr/bin/env bash
    set -euo pipefail # strict mode without tracing

    GIT_ORIGIN=$(git config --get remote.origin.url | sed -e 's/^.*://' -e 's/[.]git$//')
    #echo "$GIT_ORIGIN"

    GITHUB_ORG=$(echo "$GIT_ORIGIN" | sed -e 's/[/].*$//')
    echo "org={{BLUE}}$GITHUB_ORG{{NORMAL}}"

    GITHUB_REPO=$(echo "$GIT_ORIGIN" | sed -e 's/^.*[/]//')
    echo "repo={{BLUE}}$GITHUB_REPO{{NORMAL}}"

    cat > README.md << END_OF_HEREDOC
    # ${GITHUB_REPO}

    ![GitHub Issues](https://img.shields.io/github/issues/${GITHUB_ORG}/${GITHUB_REPO})
    ![GitHub Pull Requests](https://img.shields.io/github/issues-pr/${GITHUB_ORG}/${GITHUB_REPO})
    ![GitHub License](https://img.shields.io/github/license/${GITHUB_ORG}/${GITHUB_REPO})
    ![GitHub watchers](https://img.shields.io/github/watchers/${GITHUB_ORG}/${GITHUB_REPO})

    A good starting place for something. (TODO)

    ## Contibuting

    - [Code of Conduct](.github/CODE_OF_CONDUCT.md)
    - [Contributing Guide](.github/CONTRIBUTING.md) includes a step-by-step guide to our
      [development processs](.github/CONTRIBUTING.md#development-process).

    ## Support & Security

    - [Getting Support](.github/SUPPORT.md)
    - [Security Policy](.github/SECURITY.md)
    END_OF_HEREDOC
