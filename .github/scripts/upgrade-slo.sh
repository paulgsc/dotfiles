#!/usr/bin/env bash
# The nightly upgrade's SLO, judged from off the box (upgrade-slo.yml runs it).
#
# The box records each run as a GitHub Deployment to environment `nixos`
# (nixos/auto-upgrade/report.sh).  This reads those records and fails the SLO
# for what the box can't report about itself:
#
#   no_record      no run recorded in 36h: box off, timer dead, run hung,
#                  or the reporter broken
#   not_deployed   main has a commit older than 36h that no good run deployed
#   last_run_bad   the latest run was not good (the box's own issue has why)
#   unverified     the latest good run's store paths aren't what its commit
#                  evaluates to here: the box's claim, checked independently
#   rate           fewer than 95% of nights in the last 90 had a good run
#   lockfile_pr    the latest weekly lockfile workflow run failed
#
# Writes a summary to $GITHUB_STEP_SUMMARY and keeps one `slo` issue open
# while anything fails; closes it when everything holds.
set -euo pipefail

: "${REPO:?}"
label=slo
hours=36
target_rate=0.95
now=$(date +%s)
violations=()
add() { violations+=("$1"); }

# Every page, newest first: nightly runs plus manual ones can pass 100 in
# the 90-day window, and a truncated list would read as a shorter history.
# --paginate runs the --jq per page; `jq -s add` joins the pages' arrays.
# shellcheck disable=SC2016 # $owner/$name/$endCursor are GraphQL variables
deployments=$(gh api graphql --paginate -f owner="${REPO%/*}" -f name="${REPO#*/}" -f query='
  query($owner: String!, $name: String!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      deployments(environments: ["nixos"], first: 100, after: $endCursor,
                  orderBy: {field: CREATED_AT, direction: DESC}) {
        nodes { createdAt commitOid payload latestStatus { state } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }' --jq '.data.repository.deployments.nodes
    | map({ts: (.createdAt | fromdateiso8601), rev: .commitOid,
           state: (.latestStatus.state // "NONE"), payload: ((.payload // "{}") | fromjson? // {})})' |
  jq -s 'add // []')

main=$(gh api "repos/$REPO/commits/main" --jq '{sha: .sha, ts: (.commit.committer.date | fromdateiso8601)}')
main_sha=$(jq -r .sha <<<"$main")
main_ts=$(jq -r .ts <<<"$main")

latest=$(jq -c '.[0] // empty' <<<"$deployments")
if [ -z "$latest" ]; then
  add "no_record: no run has ever been recorded (is the box's token allowed Deployments: write?)"
else
  age=$(((now - $(jq -r .ts <<<"$latest")) / 3600))
  [ "$age" -lt "$hours" ] || add "no_record: the last recorded run was ${age}h ago"

  state=$(jq -r .state <<<"$latest")
  if [ "$state" != SUCCESS ]; then
    add "last_run_bad: the last run (\`$(jq -r '.rev[:12]' <<<"$latest")\`) ended \`$state\`: $(jq -r '.payload | "system_ok=\(.system_ok) home_ok=\(.home_ok) capture_ok=\(.capture_ok) \(.issue // "")"' <<<"$latest")"
  fi
fi

deployed=$(jq --arg sha "$main_sha" 'any(.[]; .rev == $sha and .state == "SUCCESS")' <<<"$deployments")
if [ "$deployed" != true ] && [ $(((now - main_ts) / 3600)) -ge "$hours" ]; then
  add "not_deployed: \`main\` (\`${main_sha:0:12}\`) is $(((now - main_ts) / 3600))h old and no good run has deployed it"
fi

# The box says which store paths it ended on; evaluate what that commit
# should produce and compare.  Evaluation only — nothing is built.
good=$(jq -c 'map(select(.state == "SUCCESS"))[0] // empty' <<<"$deployments")
verified="n/a"
if [ -n "$good" ]; then
  rev=$(jq -r .rev <<<"$good")
  want_sys=$(nix eval --raw "github:$REPO/$rev#nixosConfigurations.nixos.config.system.build.toplevel.outPath")
  want_home=$(nix eval --raw "github:$REPO/$rev#homeConfigurations.\"paulg@nixos\".activationPackage.outPath")
  got_sys=$(jq -r '.payload.system_path // ""' <<<"$good")
  got_home=$(jq -r '.payload.home_path // ""' <<<"$good")
  verified="yes (\`${rev:0:12}\`)"
  if [ "$got_sys" != "$want_sys" ]; then
    add "unverified: at \`${rev:0:12}\` the box reported system \`$got_sys\`, the commit evaluates to \`$want_sys\`"
    verified=no
  fi
  if [ "$got_home" != "$want_home" ]; then
    add "unverified: at \`${rev:0:12}\` the box reported home \`$got_home\`, the commit evaluates to \`$want_home\`"
    verified=no
  fi
fi

# Nights, not runs: a night with no record counts against the rate.  The
# window ends today only once today has a record, so a run that simply hasn't
# happened yet isn't counted as missed.
read -r nights good_nights < <(jq -r --argjson now "$now" '
  def day: . / 86400 | floor;
  (if any(.[]; (.ts | day) == ($now | day)) then ($now | day) else ($now | day) - 1 end) as $end
  | (map(.ts) | min // $now | day) as $first
  | ([$end - 89, $first] | max) as $from
  | [([$end - $from + 1, 0] | max),
     (map(select(.state == "SUCCESS" and (.ts | day) >= $from and (.ts | day) <= $end) | .ts | day) | unique | length)]
  | @tsv' <<<"$deployments")
rate=$(awk -v g="$good_nights" -v n="$nights" 'BEGIN { printf "%.3f", n ? g / n : 0 }')
if [ "$nights" -ge 14 ] && awk -v r="$rate" -v t="$target_rate" 'BEGIN { exit !(r < t) }'; then
  add "rate: $good_nights of the last $nights nights had a good run ($rate, target $target_rate)"
fi

lockfile=$(gh api "repos/$REPO/actions/workflows/update-flake-lock.yml/runs?per_page=1" \
  --jq '.workflow_runs[0] | select(. != null) | "\(.conclusion // .status) \(.html_url)"' || true)
case $lockfile in
  failure* | timed_out* | startup_failure*) add "lockfile_pr: the last weekly lockfile run failed: ${lockfile#* }" ;;
esac

{
  echo "## Nightly upgrade SLO"
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| last run | $(jq -r 'if . then "\(.ts | todate) — \(.state) at `\(.rev[:12])`" else "none recorded" end' <<<"${latest:-null}") |"
  echo "| \`main\` | \`${main_sha:0:12}\` ($(((now - main_ts) / 3600))h old), deployed: $deployed |"
  echo "| last good run verified | $verified |"
  echo "| good nights, 90d | $good_nights / $nights ($rate; target $target_rate, judged from 14 nights) |"
  echo "| weekly lockfile run | ${lockfile:-none yet} |"
  echo
  if [ "${#violations[@]}" -eq 0 ]; then
    echo "Everything holds."
  else
    echo "### Failing"
    echo
    printf -- '- %s\n' "${violations[@]}"
  fi
} >"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

open=$(gh api "repos/$REPO/issues?labels=$label&state=open&per_page=1" --jq '.[0].number // empty')
if [ "${#violations[@]}" -eq 0 ]; then
  if [ -n "$open" ]; then
    gh api -X POST "repos/$REPO/issues/$open/comments" -f body="Holding again as of $(date -u -Iseconds): every check in .github/scripts/upgrade-slo.sh passes." >/dev/null
    gh api -X PATCH "repos/$REPO/issues/$open" -f state=closed -f state_reason=completed >/dev/null
    echo "closed #$open"
  fi
  exit 0
fi

body=$(
  echo "The nightly upgrade's SLO is failing, judged from off the box by \`.github/workflows/upgrade-slo.yml\` (last checked $(date -u -Iseconds))."
  echo
  printf -- '- %s\n' "${violations[@]}"
  echo
  echo "What each check means, and how the box records runs: \`.github/scripts/upgrade-slo.sh\`, \`docs/auto-upgrade.md\`."
  echo "This issue is rewritten on every check and closed once everything holds."
)
if [ -n "$open" ]; then
  gh api -X PATCH "repos/$REPO/issues/$open" -f body="$body" >/dev/null
  echo "updated #$open"
else
  gh api -X POST "repos/$REPO/labels" -f name="$label" -f color=b60205 \
    -f description="The nightly upgrade's SLO is failing (upgrade-slo.yml)" >/dev/null 2>&1 || true
  gh api -X POST "repos/$REPO/issues" -f title="Nightly upgrade SLO failing" -f body="$body" -f "labels[]=$label" --jq '"opened #\(.number)"'
fi
