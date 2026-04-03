# project justfile

import? '.just/template-sync.just'
import? '.just/repo-toml.just'
import? '.just/pr-hook.just'
import? '.just/cue-verify.just'
import? '.just/copilot.just'
import? '.just/claude.just'
import? '.just/shellcheck.just'
import? '.just/compliance.just'
import? '.just/gh-process.just'

# list recipes (default works without naming it)
[group('example')]
list:
	just --list
	@echo "{{GREEN}}Your justfile is waiting for more scripts and snippets{{NORMAL}}"
