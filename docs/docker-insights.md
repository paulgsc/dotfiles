# Docker Insights Workflow

How to see what every `docker compose` stack is doing *right now*, in
relation to the machine it's running on — all from the CLI, declaratively
configured in this flake.

| Concern | Tool | Where it's configured |
|---------|------|------------------------|
| Full TUI: containers/logs/actions/live stats | `lazydocker` | `home-manager/shell/docker` |
| Pure resource top (CPU/mem/net/io per container) | `ctop` | `home-manager/shell/docker` |
| Why is this image so big (layer breakdown) | `dive <image>` | `home-manager/shell/docker` |
| One-screen overview | `docker-doctor` | `home-manager/shell/docker` |
| Reclaim disk space (previewed, confirmed) | `docker-reap` | `home-manager/shell/docker` |

---

## Why lazydocker

lazydocker (same author as lazygit) is the standard terminal UI for exactly
this problem: one screen with every container/image/volume/network, live
log tailing, and one-key actions (restart, stop, remove, exec shell) across
however many compose projects you have up. It's actively maintained and the
default recommendation for "insights on my running containers."

It's not, by itself, a *host-relative* resource view — its stats panel
shows per-container CPU/mem, but doesn't put that next to total host
capacity. That's what `ctop` and `docker-doctor` add.

## The daily driver: `docker-doctor`

One command, one screen — the docker equivalent of `disk-doctor`.

```bash
docker-doctor
```

It reports:
- **Host resources**: CPU count, `free -h`, load average
- **Containers**: running/total counts, name/image/status/ports table
- **Live resource usage per container** (`docker stats --no-stream`):
  CPU%, mem usage & %, net I/O, block I/O — read directly against the host
  section above
- **Compose projects** (`docker compose ls`)
- **Disk usage** (`docker system df`): images, containers, volumes, build
  cache
- **Prune candidates**: dangling images, stopped containers, unused
  volumes
- A **"what to do next"** footer pointing at `lazydocker` / `ctop` / `dive`
  / `docker-reap`

## Live, always-on views

```bash
lazydocker   # full TUI: browse containers/images/volumes, tail logs,
             # restart/stop/exec with one key, see live stats per project
ctop         # htop-style live view, purely resource-focused: CPU/mem/net/
             # block-io sparklines per container, sortable, good for
             # "which container is eating my machine right now"
```

## Why is an image so big?

```bash
dive <image>   # layer-by-layer breakdown of an image, flags wasted space
```

## Reclaiming disk space

`docker-reap` previews `docker system df` before doing anything, then asks
for confirmation (or pass `-y`/`--yes` to skip the prompt). It runs each
prune as a separate, labeled stage rather than one opaque
`docker system prune` call:

```bash
docker-reap                       # stopped containers, dangling images, unused networks
docker-reap --volumes             # ...and unused volumes
docker-reap --cache               # ...and the entire build cache
docker-reap --all -y              # everything, non-interactive
```

Build cache is opt-in (`--cache` / `--all`) and separated out on purpose:
it's usually the largest and slowest part to prune (potentially 100+ GB
across 1000+ entries) and prints nothing while it works. Treated as one
`docker system prune`, that silence reads as a hang and invites a `^C`
mid-prune — which leaves the cache half-cleaned rather than aborting
cleanly. `docker-reap --cache` prints a timestamped start/finish around it
so a long pause there is expected, not alarming — let it run to
completion.
