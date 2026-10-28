# Judge one nightly upgrade, record it, and say so where it'll be seen.
# (./filter.sh is prepended to this script: curate, near_misses.)
#
# Runs after nixos-upgrade (on failure) or home-manager-upgrade (either way).
# A run is *good* only when all of these hold, each checked rather than
# taken from an exit code:
#   - both units succeeded;
#   - the system is the commit `main` pointed at (its configurationRevision);
#   - the user's home-manager profile is the exact store path that commit's
#     homeConfiguration evaluates to;
#   - each unit's canary line came back through the journal read and the
#     filter, so a quiet report means quiet, not a broken capture.
#
# Outputs, in this order so the local ones survive GitHub being down:
#   $STATE_DIR/latest.md        the curated report
#   $STATE_DIR/history.jsonl    one line per run; the rolling rates come from
#                               it, not Prometheus (whose retention is ~8 days)
#   $METRICS_DIR/upgrade.prom   node_exporter textfile -> Prometheus -> Grafana
#   a GitHub Deployment         the off-box record the SLO watcher reads
#                               (.github/workflows/upgrade-slo.yml)
#   an `upgrade-log` issue      one per distinct set of findings, closed by
#                               the next good run that doesn't show them
#
# Env (set by the unit): REPO, TOKEN_FILE, STATE_DIR, METRICS_DIR, HM_USER,
# HM_HOME, HM_CONFIG.

units=(nixos-upgrade home-manager-upgrade)
current_system=${CURRENT_SYSTEM:-/run/current-system} # overridable for tests
label=upgrade-log
history="$STATE_DIR/history.jsonl"
now=$(date +%s)
date=$(date -Iseconds)
host=$(hostname)
mkdir -p "$METRICS_DIR"

# --- which units ran this time -------------------------------------------
#
# Compare the *Monotonic properties: `systemctl show` prints every property
# named *Timestamp as a formatted date and ignores --timestamp=, while these
# print as plain microseconds since boot (0 if not run this boot).  The log is
# then read per invocation ID, so no wall-clock time is involved at all.
show() { systemctl show "$1" -p "$2" --value; }
since=$(show nixos-upgrade ExecMainStartTimestampMonotonic)
if [ "${since:-0}" -eq 0 ]; then
  echo "nixos-upgrade has not run this boot; nothing to report"
  exit 0
fi
uptime_s=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
started_at=$((now - uptime_s + since / 1000000))

declare -A result
log=""
journal_cmd=""
canary_missing=()
for u in "${units[@]}"; do
  started=$(show "$u" ExecMainStartTimestampMonotonic)
  if [ "${started:-0}" -ge "$since" ]; then
    result[$u]=$(show "$u" Result)
    invocation=$(show "$u" InvocationID)
    ulog=$(journalctl --no-pager -o cat -u "$u" --invocation="$invocation")
    log+="$ulog"$'\n'
    journal_cmd+="${journal_cmd:+; }journalctl -u $u --invocation=$invocation"
    # The unit printed this first thing (./default.nix, preStart).  Matched
    # from a variable, not a pipe: `grep -q` stops reading at the first
    # match, and with pipefail the writer's SIGPIPE would read as "missing"
    # on a run that printed more than a pipe buffer of warnings.
    ucurated=$(printf '%s\n' "$ulog" | curate)
    if ! grep -qxF "warning: upgrade-canary $invocation" <<<"$ucurated"; then
      canary_missing+=("$u")
    fi
  else
    result[$u]=skipped
  fi
done

curated=$(printf '%s\n' "$log" | curate)
findings=$(printf '%s\n' "$curated" | grep -v 'upgrade-canary ' || true)
misses=$(printf '%s\n' "$log" | grep -v 'upgrade-canary ' | near_misses "$findings")
count() { if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l; else echo 0; fi; }
n_findings=$(count "$findings")
n_misses=$(count "$misses")

failed=0
for u in "${units[@]}"; do
  case ${result[$u]} in success | skipped) ;; *) failed=1 ;; esac
done
capture_ok=1
[ "${#canary_missing[@]}" -eq 0 ] || capture_ok=0

# --- did both halves really land ------------------------------------------

main_rev=$(git ls-remote "https://github.com/$REPO" refs/heads/main 2>/dev/null | cut -f1 || true)
sys_rev=$("$current_system/sw/bin/nixos-version" --configuration-revision 2>/dev/null || true)
sys_path=$(readlink -f "$current_system")

# Behind `main` is fine if `main` moved after this run fetched it.
main_moved=0
if [ -n "$main_rev" ] && [ "$sys_rev" != "$main_rev" ]; then
  main_at=$(curl -fsS "https://api.github.com/repos/$REPO/commits/$main_rev" 2>/dev/null |
    jq -r '.commit.committer.date // empty' || true)
  if [ -n "$main_at" ] && [ "$(date -d "$main_at" +%s)" -gt "$started_at" ]; then
    main_moved=1
  fi
fi
system_ok=0
if [ "${result[nixos-upgrade]}" = success ] && [[ $sys_rev =~ ^[0-9a-f]{40}$ ]] &&
  { [ "$sys_rev" = "$main_rev" ] || [ "$main_moved" = 1 ]; }; then
  system_ok=1
fi

home_path=""
for p in "$HM_HOME/.local/state/nix/profiles/home-manager" "/nix/var/nix/profiles/per-user/$HM_USER/home-manager"; do
  if [ -e "$p" ]; then
    home_path=$(readlink -f "$p")
    break
  fi
done
home_want=""
if [[ $sys_rev =~ ^[0-9a-f]{40}$ ]]; then
  home_want=$(nix eval --raw "github:$REPO/$sys_rev#homeConfigurations.\"$HM_CONFIG\".activationPackage.outPath" 2>/dev/null || true)
fi
home_ok=0
if [ "${result[home-manager-upgrade]}" = success ] && [ -n "$home_want" ] && [ "$home_path" = "$home_want" ]; then
  home_ok=1
fi

good=0
if [ "$failed" = 0 ] && [ "$system_ok" = 1 ] && [ "$home_ok" = 1 ] && [ "$capture_ok" = 1 ]; then
  good=1
fi
# The commit this run is about: what the system runs when it got there,
# otherwise what it was asked to run.
if [ "$system_ok" = 1 ]; then target=$sys_rev; else target=${main_rev:-$sys_rev}; fi

# --- the report -----------------------------------------------------------

yes_no() { if [ "$1" = 1 ]; then echo yes; else echo "**no**"; fi; }
if [ "$good" = 1 ] && [ "$n_findings" = 0 ]; then
  fingerprint=none
else
  # Store paths and numbers (percentages, sizes, counts) change run to run
  # without the finding changing; leave them out of the lines.  The verdict
  # is hashed as is: normalised, "1 0 1" and "1 1 1" would collide and an
  # open warnings issue would swallow a verification failure.
  fingerprint=$({
    printf '%s\n' "$findings" |
      sed -E 's,/nix/store/[a-z0-9]{32}-,/nix/store/…-,g; s/[0-9]+/N/g' | sort -u
    echo "units: ${result[*]}"
    echo "checks: system_ok=$system_ok home_ok=$home_ok capture_ok=$capture_ok"
  } | sha256sum | cut -c1-16)
fi

{
  echo "<!-- upgrade-log fingerprint: $fingerprint -->"
  echo "Nightly upgrade on \`$host\` at \`$date\`, deploying \`$REPO@${target:0:12}\` (\`main\`)."
  echo
  echo "| check | result |"
  echo "| --- | --- |"
  for u in "${units[@]}"; do echo "| \`$u\` | ${result[$u]} |"; done
  echo "| system is \`main\` (\`${sys_rev:0:12}\`) | $(yes_no "$system_ok") |"
  echo "| home profile is that commit's build | $(yes_no "$home_ok") |"
  echo "| capture (canary seen) | $(yes_no "$capture_ok")${canary_missing[*]:+ — missing from ${canary_missing[*]}} |"
  echo
  if [ -n "$findings" ]; then
    echo "### Warnings and errors"
    echo
    echo '```'
    printf '%s\n' "$findings"
    echo '```'
    echo
  fi
  if [ "$failed" = 1 ]; then
    echo "### Last 60 lines"
    echo
    echo '```'
    printf '%s\n' "$log" | tail -n 60
    echo '```'
    echo
  fi
  if [ -n "$misses" ]; then
    echo "### Near misses ($n_misses)"
    echo
    echo "Lines that look like trouble but the filter didn't keep. If one should"
    echo "have been kept, add it to \`nixos/auto-upgrade/filter-fixture.txt\` and fix \`filter.sh\`."
    echo
    echo '```'
    head -n 20 <<<"$misses" # not a pipe: an early-exiting head would SIGPIPE printf
    echo '```'
    echo
  fi
  echo "### For whoever picks this up"
  echo
  echo "- Reproduce without switching: \`nix build .#nixosConfigurations.nixos.config.system.build.toplevel\`"
  echo "  and \`nix build '.#homeConfigurations.\"$HM_CONFIG\".activationPackage'\` — evaluation warnings print there too."
  echo "- Full log on the machine: \`$journal_cmd\`."
  echo "- Fix it in a PR to \`main\`; the next good nightly run without these lines closes this issue."
} >"$STATE_DIR/latest.md"
echo "good=$good system_ok=$system_ok home_ok=$home_ok capture_ok=$capture_ok findings=$n_findings near_misses=$n_misses"

# --- history and rolling rates ---------------------------------------------

jq -nc --argjson ts "$now" --arg rev "$target" --arg main "$main_rev" \
  --arg sys "${result[nixos-upgrade]}" --arg home "${result[home-manager-upgrade]}" \
  --argjson system_ok "$system_ok" --argjson home_ok "$home_ok" --argjson capture_ok "$capture_ok" \
  --argjson findings "$n_findings" --argjson near_misses "$n_misses" --argjson good "$good" \
  '{ts: $ts, rev: $rev, main: $main, system: $sys, home: $home, system_ok: $system_ok,
    home_ok: $home_ok, capture_ok: $capture_ok, findings: $findings,
    near_misses: $near_misses, good: $good}' >>"$history"

# Per window: nights since the first record (or the window's start), nights
# with any run, nights with a good run.  A night with no run counts against
# the rate: it's the failure an exit code never reports.
windows=$(jq -sc --argjson now "$now" '
  def day: . / 86400 | floor;
  . as $h | ($h | map(.ts) | min | day) as $first
  | [7, 30, 90] | map(. as $w
      | ([($now | day) - $w + 1, $first] | max) as $from
      | ($h | map(select((.ts | day) >= $from))) as $in
      | { window: "\($w)d",
          nights: (($now | day) - $from + 1),
          ran: ($in | map(.ts | day) | unique | length),
          good: ($in | map(select(.good == 1) | .ts | day) | unique | length) })' "$history")

# --- metrics (node_exporter textfile collector) ---------------------------

issue_url=""
deploy_ok=0
github_ok=0
esc() { printf '%s' "$1" | cut -c1-200 | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
write_metrics() {
  local tmp="$METRICS_DIR/.upgrade.prom.$$" last_good ok i line
  last_good=$(jq -s 'map(select(.good == 1) | .ts) | max // 0' "$history")
  {
    echo "# HELP upgrade_last_run_timestamp_seconds When the last nightly upgrade was judged."
    echo "# TYPE upgrade_last_run_timestamp_seconds gauge"
    echo "upgrade_last_run_timestamp_seconds $now"
    echo "# HELP upgrade_last_good_run_timestamp_seconds When the last good run was judged (0: never)."
    echo "# TYPE upgrade_last_good_run_timestamp_seconds gauge"
    echo "upgrade_last_good_run_timestamp_seconds $last_good"
    echo "# HELP upgrade_run_good 1 if the last run was good: both units ok, both halves on main, capture ok."
    echo "# TYPE upgrade_run_good gauge"
    echo "upgrade_run_good $good"
    echo "# HELP upgrade_check 1 per check of the last run that held."
    echo "# TYPE upgrade_check gauge"
    for u in "${units[@]}"; do
      ok=0
      [ "${result[$u]}" = success ] && ok=1
      echo "upgrade_check{check=\"$u\",result=\"${result[$u]}\"} $ok"
    done
    echo "upgrade_check{check=\"system_on_main\",result=\"\"} $system_ok"
    echo "upgrade_check{check=\"home_on_system_rev\",result=\"\"} $home_ok"
    echo "upgrade_check{check=\"capture\",result=\"\"} $capture_ok"
    echo "# HELP upgrade_findings Curated warning/error lines in the last run."
    echo "# TYPE upgrade_findings gauge"
    echo "upgrade_findings $n_findings"
    echo "# HELP upgrade_near_misses Lines the wide net caught that the filter did not keep."
    echo "# TYPE upgrade_near_misses gauge"
    echo "upgrade_near_misses $n_misses"
    echo "# HELP upgrade_deployed_info The commit the system runs, and main's tip, at the last run."
    echo "# TYPE upgrade_deployed_info gauge"
    echo "upgrade_deployed_info{rev=\"${sys_rev:0:12}\",main=\"${main_rev:0:12}\"} 1"
    echo "# HELP upgrade_finding_info One series per curated line of the last run (first 30, 200 chars)."
    echo "# TYPE upgrade_finding_info gauge"
    if [ -n "$findings" ]; then
      i=0
      while IFS= read -r line; do
        i=$((i + 1))
        printf 'upgrade_finding_info{n="%02d",text="%s"} 1\n' "$i" "$(esc "$line")"
      done < <(head -n 30 <<<"$findings")
    fi
    echo "# HELP upgrade_report_info Where the last run's report lives."
    echo "# TYPE upgrade_report_info gauge"
    echo "upgrade_report_info{issue=\"$(esc "$issue_url")\"} 1"
    echo "# HELP upgrade_github_ok 1 if the last run's deployment record and issue reached GitHub."
    echo "# TYPE upgrade_github_ok gauge"
    echo "upgrade_github_ok $github_ok"
    echo "# HELP upgrade_window_nights Nights in the window, from the first recorded run."
    echo "# TYPE upgrade_window_nights gauge"
    echo "# HELP upgrade_window_nights_ran Nights in the window with any run."
    echo "# TYPE upgrade_window_nights_ran gauge"
    echo "# HELP upgrade_window_nights_good Nights in the window with a good run."
    echo "# TYPE upgrade_window_nights_good gauge"
    printf '%s' "$windows" | jq -r '.[] |
      "upgrade_window_nights{window=\"\(.window)\"} \(.nights)",
      "upgrade_window_nights_ran{window=\"\(.window)\"} \(.ran)",
      "upgrade_window_nights_good{window=\"\(.window)\"} \(.good)"'
  } >"$tmp"
  mv "$tmp" "$METRICS_DIR/upgrade.prom"
}
write_metrics

# --- GitHub: issue, deployment record -------------------------------------

if [ ! -r "$TOKEN_FILE" ]; then
  echo "no GitHub token at $TOKEN_FILE; not recording or filing (see docs/auto-upgrade.md)"
  exit 0
fi

api() {
  curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}
issues_ok=1

if open=$(api "https://api.github.com/repos/$REPO/issues?labels=$label&state=open&per_page=100"); then
  # Issues whose finding no longer reproduces: closed only by a good run — a
  # failed or unverified one may not have got far enough to print them.
  if [ "$good" = 1 ]; then
    for n in $(printf '%s' "$open" | jq -r --arg fp "$fingerprint" '.[] | select((.body // "") | contains("fingerprint: \($fp) ") | not) | .number'); do
      if api -X POST "https://api.github.com/repos/$REPO/issues/$n/comments" \
        -d "$(jq -n --arg b "No longer reproduces as reported: the good upgrade at \`$REPO@${target:0:12}\` on \`$date\` ran without this set of findings (any that remain are in a newer \`$label\` issue)." '{body: $b}')" >/dev/null &&
        api -X PATCH "https://api.github.com/repos/$REPO/issues/$n" \
          -d '{"state":"closed","state_reason":"completed"}' >/dev/null; then
        echo "closed #$n"
      else
        issues_ok=0
      fi
    done
  fi

  if [ "$fingerprint" != none ]; then
    issue_url=$(printf '%s' "$open" |
      jq -r --arg fp "$fingerprint" '[.[] | select((.body // "") | contains("fingerprint: \($fp) "))][0].html_url // empty')
    if [ -n "$issue_url" ]; then
      echo "already open: $issue_url"
    else
      if [ "$failed" = 1 ]; then
        title="Nightly upgrade failed on $host"
      elif [ "$good" = 0 ]; then
        title="Nightly upgrade not verified on $host"
      else
        title="Nightly upgrade warnings on $host ($n_findings lines)"
      fi
      # The label has to exist before an issue can carry it; 422 means it does.
      api -X POST "https://api.github.com/repos/$REPO/labels" \
        -d "$(jq -n --arg l "$label" '{name: $l, color: "d93f0b", description: "Warnings/errors from the nightly upgrade (nixos/auto-upgrade)"}')" \
        >/dev/null 2>&1 || true
      if created=$(api -X POST "https://api.github.com/repos/$REPO/issues" \
        -d "$(jq -n --arg t "$title" --rawfile b "$STATE_DIR/latest.md" --arg l "$label" '{title: $t, body: $b[:60000], labels: [$l]}')"); then
        issue_url=$(printf '%s' "$created" | jq -r .html_url)
        echo "opened $issue_url"
      else
        issues_ok=0
      fi
    fi
  fi
else
  issues_ok=0
fi

# The off-box record: one Deployment per run, its status the verdict.  The
# watcher reads these, so a night with none is itself a finding there.
if [ "$good" = 1 ]; then
  state=success
elif [ "$failed" = 1 ]; then
  state=failure
else
  state=error
fi
payload=$(jq -nc --arg sys_path "$sys_path" --arg home_path "$home_path" --arg home_want "$home_want" \
  --argjson system_ok "$system_ok" --argjson home_ok "$home_ok" --argjson capture_ok "$capture_ok" \
  --argjson findings "$n_findings" --argjson near_misses "$n_misses" --arg issue "$issue_url" \
  '{system_path: $sys_path, home_path: $home_path, home_expected: $home_want, system_ok: $system_ok,
    home_ok: $home_ok, capture_ok: $capture_ok, findings: $findings, near_misses: $near_misses,
    issue: $issue}')
if [[ $target =~ ^[0-9a-f]{40}$ ]] && deployment=$(api -X POST "https://api.github.com/repos/$REPO/deployments" \
  -d "$(jq -nc --arg ref "$target" --argjson p "$payload" --arg d "nightly upgrade on $host" \
    '{ref: $ref, environment: "nixos", auto_merge: false, required_contexts: [],
      production_environment: true, description: $d, payload: $p}')"); then
  id=$(printf '%s' "$deployment" | jq -r .id)
  desc="system $(yes_no "$system_ok"), home $(yes_no "$home_ok"), capture $(yes_no "$capture_ok"), $n_findings findings"
  if api -X POST "https://api.github.com/repos/$REPO/deployments/$id/statuses" \
    -d "$(jq -nc --arg s "$state" --arg d "${desc//\*/}" --arg u "$issue_url" \
      '{state: $s, description: $d[:140]} + (if $u != "" then {log_url: $u} else {} end)')" >/dev/null; then
    deploy_ok=1
    echo "recorded deployment $id: $state"
  fi
fi
[ "$deploy_ok" = 1 ] || echo "could not record the deployment (does the token have Deployments: write?)"

if [ "$deploy_ok" = 1 ] && [ "$issues_ok" = 1 ]; then github_ok=1; fi
write_metrics
