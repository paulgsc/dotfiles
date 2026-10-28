# shellcheck shell=bash
# The curation rule: which lines of an upgrade's journal a person should read.
# Shared by report.sh (prepended to it in ./default.nix) and test-filter.sh,
# which CI runs against filter-fixture.txt, a labelled sample of the formats
# below.  A line that slipped through goes in the fixture with its fix.
#
# Two dialects:
#   - nix, nixos-rebuild, switch-to-configuration and activation scripts
#     prefix what matters: `warning:`, `evaluation warning:`, `error:`,
#     `WARNING`, `... failed ...`.
#   - home-manager's warnEcho/errorEcho print no prefix at all, only colour,
#     which the journal drops (lib/bash/home-manager.sh), so its messages are
#     matched by their text.

keep_re='(^|[[:space:]])(evaluation warning|trace: warning|warning|error)(:|[[:space:]])'
keep_re+='|^WARNING|failed|refusing'
keep_re+='|is in the way of|would be clobbered|Oops, Nix failed'
keep_re+='|Please do one of the following|does not link into a Home Manager generation'
# Shell and process failures that carry no warning/error word (#58: the
# switch's root cause and its exit line).
keep_re+='|command not found|non-zero exit status'

# Build progress that names a path or package containing a keyword, and
# systemd starting a unit's OnFailure=/OnSuccess= chain (the reporter itself).
drop_re='^(building|copying path|these [0-9]+ (paths|derivations))'
drop_re+='|: Triggering On(Failure|Success)= dependencies'

# Wider than keep_re on purpose: what it catches and curate() doesn't is
# reported as a near miss, so the filter drifting shows before it misses.
wide_re='warn|error|fail|denied|refus|cannot|unable|not found|conflict|clobber'
wide_re+='|deprecat|obsolete|abort|panic|timed out|timeout'

curate() {
  grep -E -i -e "$keep_re" | grep -v -E -e "$drop_re" | awk '!seen[$0]++' || true
}

# Lines on stdin that wide_re catches but are not in the curated set $1.
near_misses() {
  grep -E -i -e "$wide_re" | grep -v -E -e "$drop_re" |
    awk 'NR == FNR { if ($0 != "") kept[$0] = 1; next } !($0 in kept) && !seen[$0]++' \
      <(printf '%s\n' "$1") - || true
}

# Remove credentials from journal text before it is published anywhere: the
# repo is public, so an issue body is world-readable.  Two layers:
#   - the literal value of every secret this machine actually holds
#     (sops-nix's /run/secrets), which is exact for the secrets that exist;
#   - common credential shapes, for ones that don't come from there: GitHub
#     tokens, `Bearer …`, `password=`/`token: …` pairs, user:pass@ in URLs,
#     private-key blocks.
# Values shorter than 8 characters are skipped: replacing them would mangle
# unrelated text and they are not credentials worth hiding.
scrub() {
  local text f v
  text=$(cat)
  for f in "${SECRETS_DIR:-/run/secrets}"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    v=$(<"$f")
    [ "${#v}" -ge 8 ] || continue
    text=${text//"$v"/[REDACTED:${f##*/}]}
  done
  printf '%s\n' "$text" | sed -E \
    -e 's/(github_pat_|gh[pousr]_)[A-Za-z0-9_]{16,}/\1[REDACTED]/g' \
    -e 's/(Bearer|Basic|token)[[:space:]]+[A-Za-z0-9._~+/=-]{20,}/\1 [REDACTED]/Ig' \
    -e "s/((password|passwd|secret|token|api[_-]?key|access[_-]?key)[A-Za-z_-]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^[:space:]\"',;]{6,}/\\1[REDACTED]/Ig" \
    -e 's#(://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[REDACTED PRIVATE KEY]'
}
