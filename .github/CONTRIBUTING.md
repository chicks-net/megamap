# Contributing to this project

This has started as a personal project, but I am doing it publicly on github
with the hope that it is helpful to some folks.  If you notice something that
could be better, please file an [issue](../../../issues).

## Other docs

Please review the [Contributor Covenant](CODE_OF_CONDUCT.md) to understand our
base expectations for participation.

There is a [Security Policy](SECURITY.md) for security-related issues.

## Reporting problems

Please file a [github issue](../../../issues) with a clear summary of your problem.
Output samples and exact error messages will help in debugging.

Please paste text into the bug report rather than taking a screen shot
unless a screen shot is the only way to convey your problem.

## Contributing code

- Major changes should probably be discussed in an [issue](../../../issues) first.
- Fork the repo on github.
- Make a branch in your branch on your repo.
- Add commits with good commit messages.
- Open a pull request on github.
- Check the github actions on your PR to see if there's anything to fix.

## Development requirements

- `just`
- `gh` - github CLI
- `bash`

## Development process

![dev-process animation](../docs/dev-process.gif)

The [justfile](../justfile) is used for centralizing snippets for build
and development purposes.

The full development cycle works via the command line.

1. Starting with a cloned repo, run `just branch $some-name`
1. Make some changes and make sure your last commit message conveys your
   overall purpose.
1. Run `just pr` and it will create a PR based on your last commit message.
1. Optionally, you can make other commits or update the PR description.
1. Finally, `just merge` will merge the PR with squashed commit history and
   cleaned up branches locally and remotely.  You'll end up with a repo back
   on `main` (release) branch with the latest `git pull`ed.

Run `just` anywhere in the repo to see which subcommands are available here.
You should get a more colorful version of this:

```bash
% just
just --list
Available recipes:
    [Compliance]
    compliance_check    # our own compliance check

    [Process]
    branch branchname   # start a new branch
    merge               # merge PR and return to starting point
    pr                  # PR create 3.0
    prweb               # view PR in web browser
    release rel_version # make a release
    sync                # escape from branch, back to starting point

    [Utility]
    clean_readme        # generate a clean README
    utcdate             # print UTC date in ISO format

    [example]
    list                # list recipes (default works without naming it)
Your justfile is waiting for more scripts and snippets
```
