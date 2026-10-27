# Curate one nightly upgrade's journal into something you act on later.
#
# Runs after nixos-upgrade (on failure) or home-manager-upgrade (either way).
# Everything both units printed this run stays in journald; this keeps only
# the warning/error lines, writes them to $STATE_DIR/latest.md, and — when a
# token is configured — files them as one GitHub issue an agent can pick up.
#
# One issue per distinct set of findings: the issue body carries a
# fingerprint of the normalized lines, so the same warnings night after night
# don't open a new issue each time, and a clean, successful run closes the
# ones that no longer reproduce.
#
# Env (set by the unit): REPO, TOKEN_FILE, STATE_DIR.

units=(nixos-upgrade home-manager-upgrade)
label=upgrade-log

# This run started when nixos-upgrade did; home-manager-upgrade only counts
# if it ran after that (it doesn't when the system half failed).
since=$(systemctl show nixos-upgrade -p ExecMainStartTimestamp --value --timestamp=unix)
if [ -z "$since" ]; then
  echo "nixos-upgrade has not run yet; nothing to report"
  exit 0
fi

declare -A result
for u in "${units[@]}"; do
  started=$(systemctl show "$u" -p ExecMainStartTimestamp --value --timestamp=unix)
  if [ -n "$started" ] && [ "${started#@}" -ge "${since#@}" ]; then
    result[$u]=$(systemctl show "$u" -p Result --value)
  else
    result[$u]=skipped
  fi
done

log=$(journalctl --no-pager -o cat --since "$since" -u nixos-upgrade -u home-manager-upgrade)

# The signal: nix/nixos-rebuild/home-manager warnings and errors, and the
# activation scripts' own WARNING lines.  Build progress, "copying path",
# "building '...'" and the like are the noise this drops.
findings=$(printf '%s\n' "$log" |
  grep -E -i '(^|[[:space:]])(evaluation warning|trace: warning|warning|error)(:|[[:space:]])|^WARNING|failed|refusing' |
  grep -v -E '^(building|copying path|these [0-9]+ (paths|derivations))' |
  awk '!seen[$0]++' || true)

failed=false
for u in "${units[@]}"; do
  case ${result[$u]} in success | skipped) ;; *) failed=true ;; esac
done

rev=$(git ls-remote "https://github.com/$REPO" refs/heads/main 2>/dev/null | cut -c1-12 || true)
host=$(hostname)
date=$(date -Iseconds)

if [ -z "$findings" ] && [ "$failed" = false ]; then
  echo "clean upgrade at ${rev:-unknown}"
  printf 'Clean upgrade at %s on %s (%s).\n' "${rev:-unknown}" "$host" "$date" >"$STATE_DIR/latest.md"
  fingerprint=none
else
  # Store paths and numbers (percentages, sizes, counts) change run to run
  # without the finding changing; leave them out of the fingerprint.
  fingerprint=$(printf '%s\n' "$findings" "${result[*]}" |
    sed -E 's,/nix/store/[a-z0-9]{32}-,/nix/store/…-,g; s/[0-9]+/N/g' |
    sort -u | sha256sum | cut -c1-16)

  tail=""
  if [ "$failed" = true ]; then
    tail=$(printf '%s\n' "$log" | tail -n 60)
  fi

  {
    echo "<!-- upgrade-log fingerprint: $fingerprint -->"
    echo "Nightly upgrade on \`$host\` at \`$date\`, deploying \`$REPO@${rev:-unknown}\` (\`main\`)."
    echo
    echo "| unit | result |"
    echo "| --- | --- |"
    for u in "${units[@]}"; do echo "| \`$u\` | ${result[$u]} |"; done
    echo
    if [ -n "$findings" ]; then
      echo "### Warnings and errors"
      echo
      echo '```'
      printf '%s\n' "$findings"
      echo '```'
      echo
    fi
    if [ -n "$tail" ]; then
      echo "### Last 60 lines"
      echo
      echo '```'
      printf '%s\n' "$tail"
      echo '```'
      echo
    fi
    echo "### For whoever picks this up"
    echo
    echo "- Reproduce without switching: \`nix build .#nixosConfigurations.nixos.config.system.build.toplevel\`"
    echo "  and \`nix build '.#homeConfigurations.\"paulg@nixos\".activationPackage'\` — evaluation warnings print there too."
    echo "- Full log on the machine: \`journalctl -u nixos-upgrade -u home-manager-upgrade --since '$since'\`."
    echo "- Fix it in a PR to \`main\`; the next successful nightly run without these lines closes this issue."
  } >"$STATE_DIR/latest.md"
  echo "findings written to $STATE_DIR/latest.md (fingerprint $fingerprint)"
fi

if [ ! -r "$TOKEN_FILE" ]; then
  echo "no GitHub token at $TOKEN_FILE; not filing (see docs/auto-upgrade.md)"
  exit 0
fi

api() {
  curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

open=$(api "https://api.github.com/repos/$REPO/issues?labels=$label&state=open&per_page=100")

# Issues whose finding no longer reproduces: close them, but only on a
# successful run — a failed one may not have got far enough to print them.
if [ "$failed" = false ]; then
  printf '%s' "$open" |
    jq -r --arg fp "$fingerprint" '.[] | select((.body // "") | contains("fingerprint: \($fp) ") | not) | .number' |
    while read -r n; do
      api -X POST "https://api.github.com/repos/$REPO/issues/$n/comments" \
        -d "$(jq -n --arg b "No longer reproduces as reported: the upgrade at \`$REPO@${rev:-unknown}\` on \`$date\` succeeded without this set of findings (any that remain are in a newer \`$label\` issue)." '{body: $b}')" >/dev/null
      api -X PATCH "https://api.github.com/repos/$REPO/issues/$n" \
        -d '{"state":"closed","state_reason":"completed"}' >/dev/null
      echo "closed #$n"
    done
fi

[ "$fingerprint" = none ] && exit 0

existing=$(printf '%s' "$open" |
  jq -r --arg fp "$fingerprint" '[.[] | select((.body // "") | contains("fingerprint: \($fp) "))][0].number // empty')
if [ -n "$existing" ]; then
  echo "already open as #$existing"
  exit 0
fi

if [ "$failed" = true ]; then
  title="Nightly upgrade failed on $host"
else
  title="Nightly upgrade warnings on $host ($(printf '%s\n' "$findings" | wc -l) lines)"
fi
api -X POST "https://api.github.com/repos/$REPO/issues" \
  -d "$(jq -n --arg t "$title" --rawfile b "$STATE_DIR/latest.md" --arg l "$label" '{title: $t, body: $b[:60000], labels: [$l]}')" |
  jq -r '"opened #\(.number) \(.html_url)"'
