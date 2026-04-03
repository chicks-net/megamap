# .just/pr-hook.just

# called from pr recipe in .just/gh-process.just

# run this before creating a PR - no PR if this errors out
_pr-hook:
    just shellcheck
    just claude_permissions_sort
    @echo "{{BLUE}}Feel free to add more to the _pr-hook...{{NORMAL}}"
