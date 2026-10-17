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
    total_images=$(${pkgs.docker}/bin/docker images -q | ${pkgs.coreutils}/bin/wc -l)
    used_images=$(${pkgs.docker}/bin/docker ps -aq | ${pkgs.findutils}/bin/xargs -r ${pkgs.docker}/bin/docker inspect --format '{{.Image}}' 2>/dev/null | ${pkgs.coreutils}/bin/sort -u | ${pkgs.coreutils}/bin/wc -l)
    unused_images=$((total_images - used_images))
    stopped=$(${pkgs.docker}/bin/docker ps -aq -f status=exited | ${pkgs.coreutils}/bin/wc -l)
    vols=$(${pkgs.docker}/bin/docker volume ls -qf dangling=true | ${pkgs.coreutils}/bin/wc -l)
    echo "  dangling images: $dangling   unused images (tagged + dangling): $unused_images"
    echo "  stopped containers: $stopped   unused volumes: $vols"
    if [ "$dangling" -lt "$unused_images" ]; then
      echo "  note: most unused images here are tagged, not dangling — plain"
      echo "        'docker image prune' won't touch them, use 'docker-reap --images'"
    fi

    hr "What to do next"
    echo "  Full TUI (logs/actions/live stats):  lazydocker"
    echo "  Pure resource top (like htop):       ctop"
    echo "  Why is this image so big?:           dive <image>"
    echo "  Reclaim space (previewed, confirmed): docker-reap"
    echo "  Reclaim ALL unused images (not just dangling): docker-reap --images"
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

    IMAGES=0
    VOLUMES=0
    CACHE=0
    YES=0
    for arg in "$@"; do
      case "$arg" in
        --images) IMAGES=1 ;;
        --volumes) VOLUMES=1 ;;
        --cache) CACHE=1 ;;
        --all) IMAGES=1; VOLUMES=1; CACHE=1 ;;
        --yes|-y) YES=1 ;;
        *) echo "usage: docker-reap [--images] [--volumes] [--cache] [--all] [--yes]"; exit 2 ;;
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
    echo "This will remove: stopped containers, dangling images, unused networks."
    if [ "$IMAGES" = "1" ]; then
      echo "  ...and ALL unused images, not just dangling ones (--images passed)."
      echo "      (this is the 'ACTIVE=0 but RECLAIMABLE is huge' fix — dangling-only"
      echo "      pruning skips tagged images nothing is currently using)"
    fi
    [ "$VOLUMES" = "1" ] && echo "  ...and unused volumes (--volumes passed)."
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

    if [ "$IMAGES" = "1" ]; then
      step "pruning all unused images (not just dangling)"
      ${pkgs.docker}/bin/docker image prune -a -f
    else
      step "pruning dangling images"
      ${pkgs.docker}/bin/docker image prune -f
    fi

    step "pruning unused networks"
    ${pkgs.docker}/bin/docker network prune -f

    if [ "$VOLUMES" = "1" ]; then
      step "pruning unused volumes"
      ${pkgs.docker}/bin/docker volume prune -f
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
