{pkgs, ...}: let
  # docker-doctor — one-screen picture of every compose stack you have up:
  # host resources, per-container CPU/mem/net vs the machine, disk usage
  # breakdown, and reclaim candidates. Same shape as disk-doctor.
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
    # Count all unused volumes (both named and anonymous) matching `docker volume prune -a` behavior
    vols=$(${pkgs.docker}/bin/docker volume ls -q | ${pkgs.coreutils}/bin/wc -l)
    echo "  dangling images: $dangling   stopped containers: $stopped   total volumes: $vols"
    echo "  (see 'docker system df' above for total reclaimable volume and image space)"

    hr "What to do next"
    echo "  Full TUI (logs/actions/live stats):   lazydocker"
    echo "  Pure resource top (like htop):        ctop"
    echo "  Why is this image so big?:            dive <image>"
    echo "  Reclaim space (previewed, confirmed): docker-reap"
  '';

  # docker-reap — preview reclaimable docker disk usage, then prune on
  # confirmation. Mirrors cargo-reap's before/after reporting.
  #
  # Staged on purpose: `docker system prune` as a single call goes silent
  # for as long as the build cache takes (which can be 100+ GB / 1000+
  # entries and several minutes), which reads as a hang and invites a ^C
  # mid-prune — leaving things half-cleaned. Each stage below is fast
  # except build cache, which is opt-in and clearly labeled so a long
  # pause there is expected, not alarming.
  docker-reap = pkgs.writeShellScriptBin "docker-reap" ''
    set -uo pipefail

    VOLUMES=0
    CACHE=0
    YES=0
    for arg in "$@"; do
      case "$arg" in
        --volumes) VOLUMES=1 ;;
        --cache) CACHE=1 ;;
        --all) VOLUMES=1; CACHE=1 ;;
        --yes|-y) YES=1 ;;
        *) echo "usage: docker-reap [--volumes] [--cache] [--all] [--yes]"; exit 2 ;;
      esac
    done

    if ! ${pkgs.docker}/bin/docker info >/dev/null 2>&1; then
      echo "docker daemon not reachable (is it running? are you in the docker group?)"
      exit 1
    fi

    step() { printf '\n\033[1;36m→ %s\033[0m\n' "$1"; }

    echo "Reclaimable space (docker system df):"
    ${pkgs.docker}/bin/docker system df
    echo
    echo "This will remove: stopped containers, unused images, unused networks."
    [ "$VOLUMES" = "1" ] && echo "  ...and ALL unused volumes, including named volumes (--volumes passed)."
    if [ "$CACHE" = "1" ]; then
      echo "  ...and the ENTIRE build cache (--cache passed) — this is usually the"
      echo "      biggest and slowest part; it can take several minutes with no"
      echo "      output in between. Let it finish; don't ^C partway through."
    else
      echo "  (build cache left untouched — pass --cache or --all to also clear it)"
    fi

    if [ "$YES" != "1" ]; then
      read -r -p "Proceed? [y/N] " reply
      case "$reply" in
        [yY]*) ;;
        *) echo "aborted"; exit 0 ;;
      esac
    fi

    step "pruning stopped containers"
    ${pkgs.docker}/bin/docker container prune -f

    step "pruning unused images"
    # -a is intentional: without it Docker only removes dangling images.
    # `docker system df` can report large amounts of reclaimable space from
    # tagged images that are no longer referenced by any container.
    ${pkgs.docker}/bin/docker image prune -a -f

    step "pruning unused networks"
    ${pkgs.docker}/bin/docker network prune -f

    if [ "$VOLUMES" = "1" ]; then
      step "pruning unused volumes"
      # -a is intentional: without -a Docker only removes anonymous volumes.
      # -a also removes unused named volumes, matching the reclaimable count in `docker system df`.
      ${pkgs.docker}/bin/docker volume prune -a -f
    fi

    if [ "$CACHE" = "1" ]; then
      step "pruning build cache (this is the slow one — hang tight)"
      ${pkgs.coreutils}/bin/date '+  started %H:%M:%S'
      ${pkgs.docker}/bin/docker builder prune -f -a
      ${pkgs.coreutils}/bin/date '+  finished %H:%M:%S'
    fi

    step "disk usage after"
    ${pkgs.docker}/bin/docker system df
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
