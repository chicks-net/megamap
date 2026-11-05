#!/usr/bin/env bash
# Shared org/repo extraction and URL agreement checks.
#
# Sourced by .just/cue-verify.just (cue-verify, cue-sync-from-github) and
# .just/clean-template.just (_clean_readme, _clean_repo_toml) so GitHub URL
# parsing lives in exactly one place.
#
# Background: .repo.toml [urls] is the config source of truth, but the git
# origin remote is the ground truth for which repository you are actually
# in. Derived repos used to ship .repo.toml still pointing at
# fini-net/template-repo, so cue-sync-from-github fetched the template's
# description and topics into the derived repo, and cue-verify blessed it -
# both sides of the comparison read the same stale URL. The functions below
# let callers cross-check the two before syncing or verifying. See #420.
#
# The pure functions (normalize_remote_url, parse_web_url,
# classify_url_mismatch, repointed_repo_toml) take explicit arguments and
# are unit-tested by .just/lib/repo_urls_test.sh. The world-facing wrappers
# (origin_org_repo, repo_toml_org_repo, url_mismatch) read git/cue and are
# kept thin so the testable logic stays out of them.

# Normalize a git remote URL (SSH, ssh://, HTTPS, git://, with or without a
# .git suffix) to "org repo" on stdout. Returns 1 when no org/repo pair can
# be extracted. Only GitHub remote forms are reduced to org/repo; an
# scp-style user@host remote on another host is tolerated (the host prefix
# is simply stripped), but any other scheme-bearing URL is rejected rather
# than guessed at - recipes that need GitHub specifically will fail later
# on the GitHub API call, with a clearer message than a mangled pair.
normalize_remote_url() {
	local url="${1%.git}"

	# strip scheme and host prefixes, most specific first
	url="${url#ssh://git@github.com:}"
	url="${url#ssh://git@github.com/}"
	url="${url#git@github.com:}"
	url="${url#https://github.com/}"
	url="${url#http://github.com/}"
	url="${url#git://github.com/}"
	# any other scp-style user@host form
	url="${url#git@*[:/]}"

	# a scheme still present means a non-GitHub host we do not know how
	# to reduce to org/repo (e.g. https://gitlab.com/o/r) - reject
	# explicitly instead of guessing
	[[ "$url" == *"://"* ]] && return 1

	local org="${url%%/*}"
	local repo="${url#*/}"
	repo="${repo%%/*}"

	# no slash, or nothing usable on either side of it
	if [[ -z "$org" || -z "$repo" || "$org" == "$url" ]]; then
		return 1
	fi
	printf '%s %s\n' "$org" "$repo"
}

# Parse a web URL as stored in .repo.toml urls.web_url to "org repo" on
# stdout. Only https://github.com/org/repo is accepted; anything else
# returns 1. Unlike the sed extraction this file replaces, a
# non-matching URL never yields a misleading partial value - callers
# either get a real org/repo pair or a failure to check. See #420.
parse_web_url() {
	local url="$1"
	local re='^https://github\.com/([^/]+)/([^/]+)/?$'
	[[ "$url" =~ $re ]] || return 1
	printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Classify agreement between an "org repo" pair from .repo.toml (argument
# 1) and one from the git origin remote (argument 2). Echoes one of:
#
#   match         - same org and repo
#   org-mismatch  - same repo name, different org (typical fork clone)
#   name-mismatch - different repo name (stale template URLs, #420)
#
# The name mismatch is the dangerous one: .repo.toml describes a
# different repository, so metadata syncs would copy that repo's
# description and topics. Returns 1 when either pair is incomplete.
classify_url_mismatch() {
	local toml_org toml_repo origin_org origin_repo
	read -r toml_org toml_repo <<<"$1"
	read -r origin_org origin_repo <<<"$2"

	if [[ -z "$toml_org" || -z "$toml_repo" || -z "$origin_org" || -z "$origin_repo" ]]; then
		return 1
	fi

	if [[ "$toml_repo" != "$origin_repo" ]]; then
		echo "name-mismatch"
	elif [[ "$toml_org" != "$origin_org" ]]; then
		echo "org-mismatch"
	else
		echo "match"
	fi
}

# Echo a copy of the .repo.toml at argument 1 with its [urls] repointed at
# org/repo (arguments 2/3). The rewrite is scoped to the [urls] section:
# active or commented git_ssh/web_url lines there are replaced in place (a
# commented line is uncommented), and whichever of the two keys is absent
# is inserted at the end of the section - so git_ssh and web_url can never
# drift apart. Commented key lines *outside* [urls] (doc comments, example
# lines in other sections) are left untouched. When the file has no [urls]
# section at all, one is appended - trailing sections are valid TOML.
# Callers verify the result (clean_template treats a failed repoint as an
# error so it can never silently ship the template's URLs). See #420.
repointed_repo_toml() {
	local file="$1" org="$2" repo="$3"
	local git_ssh="git@github.com:${org}/${repo}.git"
	local web_url="https://github.com/${org}/${repo}"

	# State-aware, [urls]-scoped rewriter. Blank lines inside [urls] are
	# buffered so missing-key insertions land adjacent to the preceding
	# key rather than after the blank line separating the section from
	# the next header - the same buffering cue_sync.awk uses (see #165).
	awk -v ssh="$git_ssh" -v web="$web_url" '
		function flush_blanks() {
			if (blanks != "") {
				printf "%s", blanks
				blanks = ""
			}
		}
		function ensure_keys() {
			if (!have_ssh) {
				print "git_ssh = \"" ssh "\""
				have_ssh = 1
			}
			if (!have_web) {
				print "web_url = \"" web "\""
				have_web = 1
			}
		}
		/^\[urls\]/ {
			flush_blanks()
			in_urls = 1
			seen_urls = 1
			print
			next
		}
		/^\[/ && !/^\[urls\]/ {
			if (in_urls) {
				ensure_keys()
			}
			in_urls = 0
			flush_blanks()
			print
			next
		}
		in_urls && /^[#[:space:]]*git_ssh[[:space:]]*=/ {
			flush_blanks()
			print "git_ssh = \"" ssh "\""
			have_ssh = 1
			next
		}
		in_urls && /^[#[:space:]]*web_url[[:space:]]*=/ {
			flush_blanks()
			print "web_url = \"" web "\""
			have_web = 1
			next
		}
		in_urls && /^[[:space:]]*$/ {
			blanks = blanks "\n"
			next
		}
		{
			flush_blanks()
			print
		}
		END {
			if (in_urls) {
				ensure_keys()
			}
			flush_blanks()
			if (!seen_urls) {
				print ""
				print "[urls]"
				print "git_ssh = \"" ssh "\""
				print "web_url = \"" web "\""
			}
		}
	' "$file"
}

# Extract "org repo" from the git origin remote, in any supported URL form.
# Returns 1 when there is no origin remote or its URL is unparseable.
origin_org_repo() {
	local url
	url=$(git remote get-url origin 2>/dev/null) || return 1
	[[ -n "$url" ]] || return 1
	normalize_remote_url "$url"
}

# Extract "org repo" from .repo.toml urls.web_url (the config source of
# truth). Returns 1 when .repo.toml is missing, cue/jq fails, web_url is
# absent, or web_url is not a github.com org/repo URL.
repo_toml_org_repo() {
	local web_url
	[[ -f .repo.toml ]] || return 1
	web_url=$(cue export .repo.toml 2>/dev/null | jq -r '.urls.web_url // empty' 2>/dev/null) || return 1
	[[ -n "$web_url" ]] || return 1
	parse_web_url "$web_url"
}

# Cross-check .repo.toml urls.web_url against the git origin remote and
# echo the classification (match / org-mismatch / name-mismatch). Returns 1
# when either side cannot be determined - callers decide how loud to be
# about that (cue-sync-from-github refuses to guess, cue-verify notes it).
url_mismatch() {
	local toml origin
	toml=$(repo_toml_org_repo) || return 1
	origin=$(origin_org_repo) || return 1
	classify_url_mismatch "$toml" "$origin"
}
