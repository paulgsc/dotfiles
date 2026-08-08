{pkgs, ...}: let
  # docker-doctor — one-screen picture of every compose stack you have up:
  # host resources, per-container CPU/mem/net vs the machine, disk usage
  # breakdown, and prune candidates. Same shape as disk-doctor.
  docker-doctor = pkgs.writeShellScriptBin "docker-doctor" ''
    set -uo pipefail

    hr() { printf '\n\033[1;36m── %s ──\033[0m\n' "$1"; }

    if ! ${pkgs.docker}/bin/docker info >/dev/null 2>&1; then
      echo "docker daemon not reachable (is it running? are you in the docker group?)"
      exit 1
    fi

    hr "Host resources"
    printf "  CPUs: %s\n" "$(${pkgs.coreutils}/bin/nproc 2>/dev/null || echo '?')"
    ${pkgs.procps}/bin/free -h 2>/dev/null | sed 's/^/  /'
    ${pkgs.procps}/bin/uptime 2>/dev/null | sed 's/^/  /'

    hr "Containers"
    running=$(${pkgs.docker}/bin/docker ps -q | ${pkgs.coreutils}/bin/wc -l)
    total=$(${pkgs.docker}/bin/docker ps -aq | ${pkgs.coreutils}/bin/wc -l)
    echo "  running: $running   total: $total"
    ${pkgs.docker}/bin/docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed 's/^/  /'

    hr "Live resource usage (per container, vs host above)"
    ${pkgs.docker}/bin/docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' | sed 's/^/  /'

    hr "Compose projects"
    ${pkgs.docker}/bin/docker compose ls 2>/dev/null | sed 's/^/  /' \
      || echo "  (docker compose v2 plugin not available; use docker-compose per-project)"

    hr "Disk usage (docker system df)"
    ${pkgs.docker}/bin/docker system df | sed 's/^/  /'

    hr "Prune candidates"
    dangling=$(${pkgs.docker}/bin/docker images -f dangling=true -q | ${pkgs.coreutils}/bin/wc -l)
    stopped=$(${pkgs.docker}/bin/docker ps -aq -f status=exited | ${pkgs.coreutils}/bin/wc -l)
    vols=$(${pkgs.docker}/bin/docker volume ls -qf dangling=true | ${pkgs.coreutils}/bin/wc -l)
    echo "  dangling images: $dangling   stopped containers: $stopped   unused volumes: $vols"

    hr "What to do next"
    echo "  Full TUI (logs/actions/live stats):  lazydocker"
    echo "  Pure resource top (like htop):       ctop"
    echo "  Why is this image so big?:           dive <image>"
    echo "  Reclaim space (previewed, confirmed): docker-reap"
  '';

  # docker-reap — preview reclaimable docker disk usage, then prune on
  # confirmation. Mirrors cargo-reap's before/after reporting.
  docker-reap = pkgs.writeShellScriptBin "docker-reap" ''
    set -uo pipefail

    VOLUMES=0
    YES=0
    for arg in "$@"; do
      case "$arg" in
        --volumes) VOLUMES=1 ;;
        --yes|-y) YES=1 ;;
        *) echo "usage: docker-reap [--volumes] [--yes]"; exit 2 ;;
      esac
    done

    if ! ${pkgs.docker}/bin/docker info >/dev/null 2>&1; then
      echo "docker daemon not reachable (is it running? are you in the docker group?)"
      exit 1
    fi

    echo "Reclaimable space (docker system df):"
    ${pkgs.docker}/bin/docker system df
    echo
    echo "This will remove: stopped containers, dangling images, unused networks, build cache."
    [ "$VOLUMES" = "1" ] && echo "  ...and unused volumes (--volumes passed)."

    if [ "$YES" != "1" ]; then
      read -r -p "Proceed? [y/N] " reply
      case "$reply" in
        [yY]*) ;;
        *) echo "aborted"; exit 0 ;;
      esac
    fi

    if [ "$VOLUMES" = "1" ]; then
      ${pkgs.docker}/bin/docker system prune -f --volumes
    else
      ${pkgs.docker}/bin/docker system prune -f
    fi
  '';
in {
  home.packages = [
    # Docker itself
    pkgs.docker
    pkgs.docker-compose

    # Insight TUIs
    pkgs.lazydocker # full TUI: containers/images/volumes/logs/actions/stats
    pkgs.ctop # pure resource top for containers (CPU/mem/net/io sparklines)
    pkgs.dive # image layer analysis — why is this image so big

    # Workflow scripts
    docker-doctor
    docker-reap
  ];
}
