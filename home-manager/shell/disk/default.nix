{pkgs, ...}: let
  # disk-doctor — one-screen disk picture: nix store, reclaimable garbage,
  # generations, boot usage, and cargo target/cache sizes.
  disk-doctor = pkgs.writeShellScriptBin "disk-doctor" ''
    set -uo pipefail

    DEV_ROOT="''${DEV_ROOT:-$HOME/dev}"

    hr() { printf '\n\033[1;36m── %s ──\033[0m\n' "$1"; }

    hr "Filesystem usage"
    ${pkgs.coreutils}/bin/df -h / /boot /mnt/storage 2>/dev/null

    hr "Nix store size"
    ${pkgs.coreutils}/bin/du -sh /nix/store 2>/dev/null || echo "  (could not stat /nix/store)"

    hr "Reclaimable right now (nix-collect-garbage --dry-run, user profile)"
    ${pkgs.nix}/bin/nix-collect-garbage --dry-run 2>&1 | ${pkgs.coreutils}/bin/tail -n 2 || true
    echo "  → system-wide estimate needs: sudo nix-collect-garbage --dry-run"

    hr "System generations"
    sudo ${pkgs.nix}/bin/nix-env --list-generations --profile /nix/var/nix/profiles/system 2>/dev/null | ${pkgs.coreutils}/bin/tail -n 6 \
      || echo "  (run with sudo to list system generations)"
    syscount=$(sudo ${pkgs.nix}/bin/nix-env --list-generations --profile /nix/var/nix/profiles/system 2>/dev/null | ${pkgs.coreutils}/bin/wc -l || echo "?")
    echo "  total system generations: $syscount   (boot entries capped at 5)"

    hr "Home Manager generations"
    home-manager generations 2>/dev/null | ${pkgs.coreutils}/bin/head -n 6 || echo "  (home-manager not found)"

    hr "Current system closure size"
    ${pkgs.nix}/bin/nix path-info -S /run/current-system 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '{printf "  %.2f GiB\n", $2/1024/1024/1024}' || true

    hr "Cargo target/ dirs under $DEV_ROOT"
    if [ -d "$DEV_ROOT" ]; then
      total=0
      while IFS= read -r d; do
        sz=$(${pkgs.coreutils}/bin/du -sb "$d" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
        [ -z "$sz" ] && continue
        total=$(( total + sz ))
        printf "  %10s  %s\n" "$(${pkgs.coreutils}/bin/numfmt --to=iec "$sz")" "$d"
      done < <(${pkgs.findutils}/bin/find "$DEV_ROOT" -type d -name target -prune 2>/dev/null)
      printf "  %10s  ── TOTAL cargo targets\n" "$(${pkgs.coreutils}/bin/numfmt --to=iec "$total")"
    else
      echo "  $DEV_ROOT not found (override with: DEV_ROOT=/path disk-doctor)"
    fi

    hr "Global cargo cache (~/.cargo)"
    ${pkgs.coreutils}/bin/du -sh "$HOME/.cargo" 2>/dev/null || echo "  none"

    hr "What to do next"
    echo "  Reclaim nix (system):  sudo nix-collect-garbage --delete-older-than 30d"
    echo "  Reclaim cargo targets: cargo-reap            (sweeps target/ under $DEV_ROOT)"
    echo "  Reclaim cargo + cache: cargo-reap --deep     (also: cargo cache --autoclean)"
    echo "  Browse interactively:  ncdu /  |  dust -d2 $DEV_ROOT  |  duf"
    echo "  Did weekly GC work?:   journalctl --user -u hm-garbage-collector | tail"
  '';

  # cargo-reap — sweep stale build artifacts from every Cargo workspace under
  # a dev root, reporting reclaimed space. Optional --deep also prunes the
  # global ~/.cargo registry/git caches (re-fetchable).
  cargo-reap = pkgs.writeShellScriptBin "cargo-reap" ''
    set -uo pipefail

    DEEP=0
    DEV_ROOT="''${DEV_ROOT:-$HOME/dev}"
    DAYS="''${DAYS:-30}"

    for arg in "$@"; do
      case "$arg" in
        --deep) DEEP=1 ;;
        --days=*) DAYS="''${arg#--days=}" ;;
        /*|~*) DEV_ROOT="$arg" ;;
        *) echo "usage: cargo-reap [--deep] [--days=N] [DEV_ROOT]"; exit 2 ;;
      esac
    done

    if [ ! -d "$DEV_ROOT" ]; then
      echo "dev root not found: $DEV_ROOT (override with arg or DEV_ROOT=...)"
      exit 1
    fi
    if ! command -v cargo >/dev/null 2>&1; then
      echo "cargo not on PATH — enter your rust dev shell first, then re-run."
      exit 1
    fi

    targets_size() {
      ${pkgs.findutils}/bin/find "$DEV_ROOT" -type d -name target -prune 2>/dev/null \
        -exec ${pkgs.coreutils}/bin/du -sb {} + 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '{s+=$1} END {print s+0}'
    }

    before=$(targets_size)
    echo "cargo target usage under $DEV_ROOT: $(${pkgs.coreutils}/bin/numfmt --to=iec "$before")"
    echo "sweeping artifacts older than ''${DAYS}d (cargo sweep -r --time $DAYS)..."
    cargo sweep -r --time "$DAYS" "$DEV_ROOT" || true

    if [ "$DEEP" = "1" ]; then
      echo "deep clean: cargo cache --autoclean (global registry/git caches)"
      cargo cache --autoclean || true
    fi

    after=$(targets_size)
    reclaimed=$(( before - after ))
    echo "after: $(${pkgs.coreutils}/bin/numfmt --to=iec "$after")  ·  reclaimed: $(${pkgs.coreutils}/bin/numfmt --to=iec "''${reclaimed#-}")"
  '';
in {
  home.packages = [
    # Interactive disk inspectors
    pkgs.dust # tree view of what's big (was `du-dust` before 25.11)
    pkgs.ncdu # `ncdu` — interactive ncurses disk usage
    pkgs.duf # `duf` — friendly df

    # Cargo pruning
    pkgs.cargo-sweep # remove stale target/ artifacts
    pkgs.cargo-cache # manage / autoclean ~/.cargo

    # Workflow scripts
    disk-doctor
    cargo-reap
  ];
}
