#!/usr/bin/env bash
# wait_for_copilot.sh - Shared Copilot review poll/state-machine.
#
# Used by both pr_checks (.just/gh-process.just) and copilot_refresh
# (.just/copilot.just) so the same in-progress / zero-comment / stale
# detection logic runs on every code path (see issue #299, follow-up to
# #288).
#
# The v8.3 fix only wired this state machine into copilot_refresh; the
# main PR flow (just pr / just again -> pr_checks) ran a one-shot
# reviewThreads query immediately after the CI watcher exited and raced
# Copilot, producing false "looks good!" negatives when CI settled before
# Copilot finished. Extracting the poll loop into this shared script
# closes that gap and keeps the two paths from drifting again.
#
# Completion criterion: a Copilot-authored review whose commit oid
# matches the PR's HEAD sha. This works for both auto-requested reviews
# (pr_checks: Copilot fires at PR creation) and refresh-requested
# reviews (copilot_refresh: explicit reviewer request after a push), and
# also fixes the stale-review-after-push bug (#299 bug 4): a review
# against an older commit is not treated as complete.
#
# Usage:
#   wait_for_copilot.sh \
#       PR_REPO_OWNER PR_REPO_NAME PR_NUMBER HEAD_SHA \
#       MAX_WAIT POLL_INTERVAL INITIAL_DELAY USING_GUM MODE
#
# Arguments:
#   PR_REPO_OWNER   GitHub org/user owning the repo
#   PR_REPO_NAME    GitHub repo name
#   PR_NUMBER       PR number
#   HEAD_SHA        Full oid of the PR's current HEAD commit
#   MAX_WAIT        Max seconds to poll before giving up
#   POLL_INTERVAL   Seconds between polls
#   INITIAL_DELAY   Seconds to sleep before first poll (let Copilot start)
#   USING_GUM       "1" if wrapped by gum spin (suppress dots), "0" otherwise
#   MODE            "fatal"     - exit 1 when Copilot is not requested
#                   "nonfatal"  - exit 0 with a note when not requested
#
# Exit codes:
#   0  Copilot review for HEAD is complete, or not requested / timed out
#      (nonfatal)
#   1  Timed out, or Copilot not requested (fatal mode)
#
# Output (stdout): progress dots / status lines. The caller is
# responsible for the post-completion unresolved-thread count query.

set -euo pipefail

PR_REPO_OWNER="${1:?missing PR_REPO_OWNER}"
PR_REPO_NAME="${2:?missing PR_REPO_NAME}"
PR_NUMBER="${3:?missing PR_NUMBER}"
HEAD_SHA="${4:?missing HEAD_SHA}"
MAX_WAIT="${5:-180}"
POLL_INTERVAL="${6:-5}"
INITIAL_DELAY="${7:-10}"
USING_GUM="${8:-0}"
MODE="${9:-fatal}"

COPILOT_LOGIN="copilot-pull-request-reviewer"

# Sentinel file written when the poll exits having seen a stale Copilot
# review (against an older commit) but no HEAD-matching review. Callers
# that summarize the Copilot state after the wait (pr_checks ->
# claude_review) read this to annotate "looks good!" with "(review may be
# stale)" so users skimming the bottom of `just pr` don't mistake a stale
# review for a current one. Removed on the clean exit-0 path so a prior
# run's stale signal does not leak into a later successful run. See Claude
# review of PR #300 (Potential bug 2).
STALE_SENTINEL="/tmp/copilot_stale_${PR_REPO_OWNER}_${PR_REPO_NAME}_${PR_NUMBER}"
rm -f "$STALE_SENTINEL"

echo "Waiting ${INITIAL_DELAY}s for Copilot to start processing..."
sleep "$INITIAL_DELAY"

elapsed=$INITIAL_DELAY
saw_in_progress=0
saw_stale_review=0
not_found_count=0

while (( elapsed < MAX_WAIT )); do
	# Single GraphQL call: reviewRequests (with Bot fragment, since
	# gh pr view --json reviewRequests silently drops Bot reviewers - see
	# issue #288) + reviews(last: 10) including commit oid so we can match
	# against HEAD. reviews(last: 10) avoids missing Copilot when another
	# review lands after; | last grabs the most recent Copilot one.
	#
	# Note: GraphQL reviewRequests with the Bot fragment is the reliable
	# signal for an in-progress Copilot review. REST
	# /pulls/N/requested_reviewers no longer surfaces Copilot as of
	# gh 2.95.0+ (returns {"teams":[],"users":[]} while GraphQL correctly
	# returns copilot-pull-request-reviewer), so it is not a usable
	# fallback. See issue #299 bug 3.
	# shellcheck disable=SC2016
	response=$(gh api graphql \
		-F owner="$PR_REPO_OWNER" -F name="$PR_REPO_NAME" -F pr="$PR_NUMBER" \
		--jq '.data.repository.pullRequest' \
		-f query='
		query($name: String!, $owner: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					reviewRequests(first: 10) {
						nodes {
							requestedReviewer {
								__typename
								... on Bot { login }
								... on User { login }
								... on Team { name }
							}
						}
					}
					reviews(last: 10) {
						nodes {
							author { login }
							state
							comments { totalCount }
							submittedAt
							commit { oid }
						}
					}
				}
			}
		}
		' 2>/dev/null) || true

	if [[ -z "$response" || "$response" == "null" ]]; then
		sleep "$POLL_INTERVAL"
		elapsed=$((elapsed + POLL_INTERVAL))
		if [ "$USING_GUM" = "0" ]; then echo -n "."; fi
		continue
	fi

	# Pick the latest Copilot-authored review whose commit oid matches HEAD.
	# reviews(last: 10) returns newest at the end; | last grabs the most
	# recent Copilot one. Matching on commit oid (instead of submittedAt >
	# requestTime) unifies the pr_checks and copilot_refresh paths and
	# rejects stale reviews left over from an older commit (#299 bug 4).
	copilot_review=$(echo "$response" | jq -r --arg login "$COPILOT_LOGIN" --arg head "$HEAD_SHA" '
		[.reviews.nodes[] | select(.author.login == $login and .commit.oid == $head)] | last |
		{state: .state, commentCount: (.comments.totalCount // 0)}' 2>/dev/null) || true

	if [[ -n "$copilot_review" && "$copilot_review" != "null" ]]; then
		review_state=$(echo "$copilot_review" | jq -r '.state // "UNKNOWN"' || echo "UNKNOWN")
		comment_count=$(echo "$copilot_review" | jq -r '.commentCount // 0' || echo 0)
		if [[ "${review_state:-UNKNOWN}" != "null" && "${review_state:-UNKNOWN}" != "UNKNOWN" ]]; then
			if [[ "${comment_count:-0}" -gt 0 ]]; then
				echo "Review complete after ${elapsed}s (state: $review_state, $comment_count comments)"
			else
				echo "Review complete after ${elapsed}s (state: $review_state, no suggestions)"
			fi
			rm -f "$STALE_SENTINEL"
			exit 0
		fi
	fi

	# No HEAD-matching Copilot review yet. Track whether a stale Copilot
	# review (against an older commit) exists so we can warn at timeout
	# or on the fast-fail path.
	stale_review=$(echo "$response" | jq -r --arg login "$COPILOT_LOGIN" --arg head "$HEAD_SHA" '
		[.reviews.nodes[] | select(.author.login == $login and .commit.oid != $head)] | length' 2>/dev/null) || true
	if [[ "${stale_review:-0}" -gt 0 ]]; then
		saw_stale_review=1
	fi

	# Is Copilot in reviewRequests (in progress)?
	copilot_requested=$(echo "$response" | jq -r --arg login "$COPILOT_LOGIN" '
		[.reviewRequests.nodes[].requestedReviewer | select(.login == $login)] | length' 2>/dev/null) || true

	if [[ "${copilot_requested:-0}" -gt 0 ]]; then
		saw_in_progress=1
		not_found_count=0
		if [ "$USING_GUM" = "0" ]; then echo -n "."; fi
	else
		# Not requested and no HEAD review - either never started or was dropped.
		# Require two consecutive "not found" polls before acting so a single
		# GraphQL read that lags the prior REST POST that requested the review
		# (cross-service eventual consistency on GitHub's side) does not produce
		# a false failure on the very first poll.
		if [[ "$saw_in_progress" -eq 0 ]]; then
			not_found_count=$((not_found_count + 1))
			if [[ "$not_found_count" -ge 2 ]]; then
				echo ""
				if [[ "$saw_stale_review" -eq 1 ]]; then
					echo "Copilot's latest review is for an older commit (HEAD is ${HEAD_SHA:0:7})."
					echo "The review is stale - it may not apply to the current code."
					echo "Consider: just copilot_refresh (to request a fresh review)"
					touch "$STALE_SENTINEL"
				else
					echo "Copilot was not found in reviewRequests and has no review on PR #${PR_NUMBER}."
					echo "This may mean Copilot was never requested, finished and was unassigned,"
					echo "or the Bot reviewer is not surfaced via GraphQL reviewRequests."
				fi
				if [[ "$MODE" == "fatal" ]]; then
					exit 1
				else
					echo "Continuing (non-fatal mode)."
					exit 0
				fi
			fi
			if [ "$USING_GUM" = "0" ]; then echo -n "."; fi
		else
			# We saw it in progress earlier; it disappeared without a HEAD review landing yet.
			if [ "$USING_GUM" = "0" ]; then echo -n "."; fi
		fi
	fi

	sleep "$POLL_INTERVAL"
	elapsed=$((elapsed + POLL_INTERVAL))
done

echo ""
if [[ "$saw_stale_review" -eq 1 ]]; then
	echo "Copilot's latest review is for an older commit (HEAD is ${HEAD_SHA:0:7})."
	echo "The review is stale - it may not apply to the current code."
	echo "Consider: just copilot_refresh (to request a fresh review)"
	touch "$STALE_SENTINEL"
else
	echo "Review not completed after ${MAX_WAIT}s - it may still be processing"
fi
if [[ "$MODE" == "fatal" ]]; then
	exit 1
else
	exit 0
fi
