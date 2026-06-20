# Disk-Space & Cargo Workflow

How to see where disk is going, confirm that garbage collection actually
reclaims it, and prune Cargo's build artifacts across the Rust monorepos —
all from the CLI, declaratively configured in this flake.

| Concern | Tool | Where it's configured |
|---------|------|------------------------|
| One-screen overview | `disk-doctor` | `home-manager/shell/disk` |
| Prune cargo `target/` | `cargo-reap` | `home-manager/shell/disk` |
| Interactive browsing | `dust` / `ncdu` / `duf` | `home-manager/shell/disk` |
| Nix garbage collection | `nix.gc` + post-rebuild hook | `nixos/bootloader-cleanup` |
| Home-manager GC | `hm-garbage-collector` timer | `home-manager/home.nix` |

---

## Retention policy: 30 days, one number

Previously three different windows disagreed (7d / 28d / 28d). They're now a
single **30-day** policy in all three places:

- `nixos/bootloader-cleanup`: `nix.gc.options = "--delete-older-than 30d"` (weekly)
- `nixos/bootloader-cleanup`: post-rebuild `nix-collect-garbage --delete-older-than 30d`
- `home-manager/home.nix`: `hm-garbage-collector` expires generations `-30 days` (weekly)

Boot entries are independently capped at 5 (`systemd-boot.configurationLimit`).

---

## The daily driver: `disk-doctor`

One command, one screen. Run it whenever you're wondering "is disk creeping
up, and is cleanup keeping up?"

```bash
disk-doctor
```

It reports:
- **Filesystem usage** for `/`, `/boot`, `/mnt/storage`
- **Nix store size** and **how much is reclaimable right now**
  (`nix-collect-garbage --dry-run`) — if that number is large and growing,
  GC isn't keeping up
- **System + Home-Manager generation counts** (and dates)
- **Current system closure size**
- **Every `target/` dir under `~/dev`** with sizes and a running total
- **Global cargo cache** (`~/.cargo`) size
- A **"what to do next"** footer with the exact reclaim commands

Override the dev root if your workspaces live elsewhere:
```bash
DEV_ROOT=/srv/code disk-doctor
```

---

## Is GC actually working? (verifiable, not hopeful)

The weekly home-manager GC now logs `/nix/store` size **before and after**, so
you can confirm it reclaimed something instead of trusting it blindly:

```bash
journalctl --user -u hm-garbage-collector | tail
# hm-gc: /nix/store 41.3G -> 38.9G (reclaimed 2.4G)
```

For a system-wide picture of what *could* be freed today:
```bash
sudo nix-collect-garbage --dry-run        # estimate only, deletes nothing
sudo nix-collect-garbage --delete-older-than 30d   # actually reclaim
```

---

## Taming Cargo: `cargo-reap`

Cargo's `target/` dirs are the usual disk hog across several workspaces.
`cargo-reap` finds every Cargo workspace under your dev root and sweeps stale
build artifacts, reporting how much it freed.

```bash
cargo-reap                 # sweep target/ artifacts older than 30d under ~/dev
cargo-reap --days=14       # more aggressive: older than 14 days
cargo-reap --deep          # also: cargo cache --autoclean (global ~/.cargo)
cargo-reap /srv/code       # a different dev root
```

> Run it from a shell where `cargo` is on PATH (i.e. inside your rust dev
> shell). It refuses to run otherwise rather than half-working.

Output:
```
cargo target usage under /home/paulg/dev: 27.8G
sweeping artifacts older than 30d (cargo sweep -r --time 30)...
after: 9.1G  ·  reclaimed: 18.7G
```

### When to reach for `--deep`
`--deep` runs `cargo cache --autoclean`, which drops registry sources and git
checkouts that Cargo can simply re-download. Safe, but the next build re-fetches,
so use it when you're tight on space, not routinely.

---

## Interactive spelunking

When `disk-doctor` says a number is surprising and you want to drill in:

```bash
dust -d2 ~/dev      # tree of the biggest dirs, 2 levels deep
ncdu /              # interactive: navigate, press 'd' to delete
duf                 # pretty df across all mounts
```

---

## Typical session

```bash
# 1. where's it going, and is GC keeping up?
disk-doctor

# 2. if cargo targets dominate (they usually do), reap them
cargo-reap                  # or cargo-reap --deep if really tight

# 3. if nix store is the culprit and lots is reclaimable
sudo nix-collect-garbage --delete-older-than 30d

# 4. confirm the weekly automation has been doing its job
journalctl --user -u hm-garbage-collector | tail

# 5. drill into anything still surprising
dust -d2 ~/dev
```

No web dashboards, no manual `du | sort` archaeology — reproducible from the flake.
