#!/usr/bin/env bash
# shellcheck disable=SC2016 # the claim checks match report.sh's source text, so $… is literal
# Recall/precision check for filter.sh against filter-fixture.txt (CI runs it).
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=nixos/auto-upgrade/filter.sh
source "$here/filter.sh"

fail=0 total=0
while IFS=$'\t' read -r want line; do
  case $want in keep | drop) ;; *) continue ;; esac
  total=$((total + 1))
  if [ -n "$(printf '%s\n' "$line" | curate)" ]; then got=keep; else got=drop; fi
  if [ "$got" != "$want" ]; then
    echo "::error file=nixos/auto-upgrade/filter-fixture.txt::want $want, got $got: $line"
    fail=1
  fi
done <"$here/filter-fixture.txt"

echo "filter: $total fixture lines checked"

# scrub(): credentials out, everything else byte for byte.  `expect IN OUT`.
secrets=$(mktemp -d)
trap 'rm -rf "$secrets"' EXIT
printf 'Zq9xLw2pVb7tRk4m' >"$secrets/github-issues-token"
printf 'short' >"$secrets/too-short"
export SECRETS_DIR=$secrets
n=0
expect() {
  n=$((n + 1))
  local got
  got=$(printf '%s\n' "$1" | scrub)
  if [ "$got" != "$2" ]; then
    echo "::error file=nixos/auto-upgrade/test-filter.sh::scrub: want '$2', got '$got'"
    fail=1
  fi
}
# redacted
expect "curl: (22) token Zq9xLw2pVb7tRk4m rejected" "curl: (22) token [REDACTED:github-issues-token] rejected"
expect "unable to download 'https://paulg:hunter2hunter2@example.com/x.tar.gz'" \
  "unable to download 'https://[REDACTED]@example.com/x.tar.gz'"
expect "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345" "Authorization: Bearer [REDACTED]"
expect "export DB_PASSWORD=hunter2hunter2" "export DB_PASSWORD=[REDACTED]"
expect 'api_key: "sk-live-0123456789abcdef"' 'api_key: "[REDACTED]"'
expect "pushed with ghp_0123456789abcdefghijABCDEFGHIJ" "pushed with ghp_[REDACTED]"
expect "github_pat_11ABCDEFG0123456789_abcdefghijklmnop" "github_pat_[REDACTED]"
expect $'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----' "[REDACTED PRIVATE KEY]"
# untouched
for keep in \
  "error: builder for '/nix/store/abcdabcdabcdabcdabcdabcdabcdabcd-foo-1.0.drv' failed with exit code 1;" \
  "'github:nixos/nixpkgs/02e0898?narHash=sha256-QvnceIGTBeDvDd9oCn%2BGvdsnkquliuwbVgpiRH68qaQ%3D'" \
  "secret cloudflare-dns-token in /nix/store/x-nixos.yaml is not valid: the key 'cloudflare-dns-token' cannot be found" \
  "warning: upgrade-canary 0123456789abcdef0123456789abcdef" \
  "the word short stays" \
  "WARNING: Boot partition is 83% full"; do
  expect "$keep" "$keep"
done
echo "scrub: $n cases checked"

# The claims at the top of report.sh (C1, C3, C4), checked against its text.
report="$here/report.sh"
claim() {
  echo "::error file=nixos/auto-upgrade/report.sh::$1"
  fail=1
}

# scrub-once (C1): $log is scrubbed before anything is cut from it, and
# nothing reads $ulog (the unscrubbed per-unit text) after that.
scrub_at=$(grep -n '^log=$(scrub <<<"$log")$' "$report" | cut -d: -f1 || true)
first_use=$(grep -n -E '^(curated|findings|misses)=' "$report" | head -n 1 | cut -d: -f1)
last_ulog=$(grep -n 'ulog' "$report" | tail -n 1 | cut -d: -f1)
if [ -z "$scrub_at" ] || [ "${first_use:-0}" -lt "$scrub_at" ] || [ "${last_ulog:-0}" -gt "$scrub_at" ]; then
  claim "C1: \$log must be scrubbed before findings are cut from it"
fi

# egress (C3): every GitHub call, as METHOD path.  A new call fails this
# until it is added here and to docs/auto-upgrade.md, "What leaves the box".
want_egress='GET /issues?labels=$label&state=open&per_page=100
PATCH /issues/$n
POST /deployments
POST /deployments/$id/statuses
POST /issues
POST /issues/$n/comments
POST /labels'
got_egress=$(grep -o -E 'api (-X [A-Z]+ )?"https://api.github.com/repos/\$REPO[^"]*"' "$report" |
  sed -E 's#api (-X ([A-Z]+) )?"https://api.github.com/repos/\$REPO([^"]*)"#\2 \3#; s#^ #GET #' | sort -u)
if [ "$got_egress" != "$want_egress" ]; then
  claim "C3: GitHub calls changed; update the egress list and the docs. Calls now: $(echo "$got_egress" | tr '\n' ';')"
fi

# token (C4): the token file is read only into curl's -H @<(...) file
# descriptor and the readable-check before it, never into an argument.
if grep -n 'TOKEN_FILE' "$report" | grep -v -E '@<\(printf .Authorization: Bearer %s|\[ ! -r "\$TOKEN_FILE" \]|no GitHub token at|^[0-9]+:#' | grep -q .; then
  claim "C4: \$TOKEN_FILE is used somewhere other than curl's -H @<(...)"
fi
echo "claims: C1 C3 C4 checked against report.sh"
exit "$fail"
