#!/usr/bin/env bash
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
exit "$fail"
