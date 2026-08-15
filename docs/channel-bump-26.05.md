# Off the EOL channel: 25.05 → 26.05

`flake.nix` pinned `nixpkgs` and `home-manager` to `release-25.05`. That
release stopped receiving security backports when 25.11 landed, and 25.11
itself went end-of-life a month after 26.05 shipped. The box was two releases
behind on security, not on features.

The bump was deferred for a good reason — fear that GNOME/GDM/PipeWire/portal
breakage would all arrive in one `nixos-rebuild switch`. This document is the
audit that removes the fear, plus the procedure that keeps the switch
reversible.

Epic: [WAYLANDIA-SESSION #17](https://github.com/paulgsc/dotfiles/issues/17).
Runs after [WAYLANDIA-CLIP #15](https://github.com/paulgsc/dotfiles/issues/15)
and consumes [WAYLANDIA-GUI #16](https://github.com/paulgsc/dotfiles/issues/16)'s
inventory.

| Story | What it settled | Where |
| --- | --- | --- |
| [#28](https://github.com/paulgsc/dotfiles/issues/28) S1 | Target session type: GNOME on Wayland | [docs/wayland-session.md](./wayland-session.md) |
| [#29](https://github.com/paulgsc/dotfiles/issues/29) S2 | Breaking-change audit, 25.05 → 26.05 | [below](#s2--what-changes-for-us) |
| [#30](https://github.com/paulgsc/dotfiles/issues/30) S3 | The bump, CI-gated, `boot` not `switch` | [below](#s3--the-bump) · `flake.nix` |
| [#31](https://github.com/paulgsc/dotfiles/issues/31) S4 | `stateVersion` guardrail + rollback drill | `nixos/state-version-guard` · [rollback drill](./generations/rollback-drill.md) |
| [#32](https://github.com/paulgsc/dotfiles/issues/32) S5 | Post-boot validation matrix | [below](#s5--validation-matrix) |

---

## S2 — what changes for us

Two releases of notes is a lot of prose about software this box does not run.
The audit below is filtered to options this repo actually sets, and each row
was checked against the **module source at the locked revision**, not just the
release notes — release notes say what changed, module sources say whether the
old spelling still resolves.

### Breaks or warns — remediated in this change

| Change | Where it lands here | Remediation |
| --- | --- | --- |
| GNOME 49 (25.11) **removes the X11 session**; `services.displayManager.gdm.wayland` is a removed option on 26.05 ("Disabling this option is no longer supported with GNOME 50") | The session type itself | Session is GNOME/Wayland; `services.xserver.enable` dropped — it can host no session. [S1 record](./wayland-session.md) |
| `services.xserver.displayManager.gdm.*` → `services.displayManager.gdm.*` | `nixos/configuration.nix` | Renamed. Alias resolves but warns |
| `services.xserver.desktopManager.gnome.*` → `services.desktopManager.gnome.*` | `nixos/configuration.nix` | Renamed. Alias resolves but warns |
| `hardware.pulseaudio` → `services.pulseaudio` | `nixos/configuration.nix` | Renamed. GDM additionally warns that PulseAudio + GDM support is removed in 26.11 — we set it `false`, so nothing to do later |

### Package attributes that were renamed or removed

Module options are only half the surface. The `pkgs` attribute set moves too,
and a removed attribute is a hard eval failure, not a warning — nixpkgs
converts old aliases into `throw`s a release or two after the rename.

| Attribute | Now | Where it bit |
| --- | --- | --- |
| `vim_configurable` | `vim-full` (`.customize` unchanged — still `vimUtils.makeCustomizable`) | `pkgs/vim/default.nix` |
| `du-dust` | `dust` | `home-manager/shell/disk` |
| `nodePackages.pnpm` · `nodePackages.prettier` · `nodePackages.sql-formatter` | `pnpm` · `prettier` · `sql-formatter` — the whole `nodePackages` set was removed in March 2026; survivors moved to the top level | `home-manager/home.nix` |

This class is worth auditing mechanically rather than by reading, because
nothing warns first: cross-reference every identifier in the repo's `.nix`
files against the `= throw` entries in `pkgs/top-level/aliases.nix` at the
target revision. Three of the eight name collisions that turns up here were
real (`vim_configurable`, `du-dust`, `nodePackages`); the rest were ordinary
words that happen to collide — `python`, `blackbox`, `callPackage`.

### Changes behaviour, no config change needed

| Change | Effect here |
| --- | --- |
| GNOME 49 enables the `ibus` input method by default (so dead keys keep working) | Extra closure on a headless box; harmless. Trim with `i18n.inputMethod.enable = false` if it ever matters |
| GNOME 49 ships `papers`/`showtime` instead of `evince`/`totem`; `file-roller` dropped from the GNOME module; 26.05 drops Geary | Default app set on seat 0 only. No workflow here opens them |
| `services.gnome.gnome-keyring` no longer provides the SSH agent; the new `services.gnome.gcr-ssh-agent` defaults to following it | Transparent — the default preserves current behaviour. We do not set either |
| Docker defaults to 28.x (25.11) | Daemon major-version jump. Validated by the docker row in the [matrix](#s5--validation-matrix) |
| `services.avahi.wideArea` now defaults `false` (mitigation for CVE-2024-52615) | We use avahi only for `.local` mDNS on the LAN. Strictly better |
| `services.openssh.enableRecommendedAlgorithms` added, default `true` | Curated algorithm set. Our `settings` (`PasswordAuthentication`, `PermitRootLogin`, `KbdInteractiveAuthentication`, `X11Forwarding`) are unchanged spellings |
| `services.caddy` gained `httpPort`/`httpsPort`/`openFirewall` | Additive. `virtualHosts.<name>.extraConfig`, which `nixos/subdomains` renders into, is unchanged |
| `services.xserver` now throws on an unknown `videoDrivers` entry | We set none, and no longer enable `services.xserver` at all |

### Checked and unchanged

`services.pipewire.{enable,alsa.enable,alsa.support32Bit,pulse.enable}`,
`security.rtkit.enable`, `services.displayManager.autoLogin.{enable,user}`,
`services.avahi.{nssmdns4,publish.*}`, `services.printing.enable`,
`programs.firefox.enable`, `virtualisation.docker.enable`,
`boot.loader.systemd-boot.*`, `nix.gc.*` — all present with the same names and
types at the locked revision.

`xdg-desktop-portal` needs no action: the GNOME module owns
`xdg.portal.enable` and its `extraPortals`
(`xdg-desktop-portal-gnome` + `-gtk`), and this repo never overrides them.

### The changes that would have hurt — and why they don't

The scariest entries in both releases' notes are gated on `stateVersion`:
PostgreSQL 17 as the default for new installs (≥ 25.11), Nextcloud's default
major, Stalwart's data dir and unit user, taskchampion's `DynamicUser`
migration. Home-manager's whole "State Version Changes" section is the same
shape — zsh `dotDir`, `xdg.userDirs`, Firefox `configPath`, Neovim plugin
defaults.

Every one of them is inert here because `system.stateVersion` stays `23.11`
and `home.stateVersion` stays `23.05`. That is the single reason this bump is
a channel change and not a data migration, and it is why S4 turns those two
values into a guardrail rather than a convention —
`nixos/state-version-guard`, plus a matching step in
`.github/workflows/check.yml` that holds the expected values in a second file.

### Audit method

Verified against the source trees the lock now points at:

| Input | Ref | Rev |
| --- | --- | --- |
| `nixpkgs` | `nixos-26.05` | `02e08985a27c65ffd33d434eeb2e660a2e4dc84d` |
| `home-manager` | `release-26.05` | `d4fd24667c8cbef124bb70a20380cab75ec8474d` |

Release notes read: `nixos/doc/manual/release-notes/rl-2511.section.md`,
`rl-2605.section.md`, and home-manager's `docs/release-notes/rl-2511.md`,
`rl-2605.md`. Option-by-option confirmation came from the modules themselves —
`services/display-managers/gdm.nix`, `services/desktop-managers/gnome.nix`,
`services/audio/pulseaudio.nix`, `services/desktops/pipewire/pipewire.nix`,
`services/misc/graphical-desktop.nix`, `services/networking/ssh/sshd.nix`,
`services/networking/avahi-daemon.nix`, `services/web-servers/caddy/default.nix`.

## S3 — the bump

`flake.nix` moves both inputs together (home-manager's release branches track
one nixpkgs release and are only tested against it), and `flake.lock` pins the
branch heads listed above.

**Gate first, switch second.** CI (`.github/workflows/check.yml`) evaluates
the flake and builds both closures on every push — that is the gate the epic
asks for, and it runs before anything touches the machine:

```console
$ nix flake check --no-build
$ nix build --no-link .#nixosConfigurations.nixos.config.system.build.toplevel
$ nix build --no-link '.#homeConfigurations."paulg@nixos".activationPackage'
```

Then, on the box:

```console
$ nixos-rebuild boot --flake .#nixos      # stage it; do NOT switch
$ nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -3
$ sudo reboot
```

`boot` rather than `switch` is deliberate. The session change only takes
effect on a fresh login session anyway, and staging it means the running
system stays untouched until the reboot that either works or gets rolled back
in one bootloader keypress. Record the pre-bump generation number **before**
rebooting — [the drill](./generations/rollback-drill.md) explains why that
number, and a 30-day garbage-collection window, matter more than they look.

Home-manager, after the reboot:

```console
$ home-manager switch --flake .#paulg@nixos
```

### The gate, and the three steps behind it that don't work

The steps this epic gates on pass on 26.05, and they run before the lint
steps, so the result is readable:

| Step | 25.05 | 26.05 |
| --- | --- | --- |
| `stateVersion` guardrail | — | pass |
| `nix flake check` | pass | pass |
| build NixOS toplevel | pass | pass |
| build home-manager activation | pass | pass |
| `check formatting` | **fail** | **fail** |
| `deadnix` / `statix` | skipped | skipped |

The `check` job has been red on `main` for months, and the reason is not what
it looks like. The step runs bare `nix fmt`, with no path — so alejandra gets
no file argument, falls back to formatting **stdin**, and dies on the empty
stream:

```
Formatting stdin.
Failed! 1 error found at:
- <anonymous file on stdin>: unexpected end of file
```

It has therefore never checked a single file, and the `git diff --exit-code`
behind it has never had anything to diff. The failure also skips `deadnix`
and `statix`, so those have never run either.

Fixing it is not a one-liner, which is why it isn't in this PR:
`nix fmt .` makes the step do its job, and then it fails honestly on four
files that were never formatted (`nixos/hardware-configuration.nix`,
`nixos/filesystems.nix`, `nixos/ports/default.nix`, `overlays/default.nix`),
and `deadnix` and `statix` start running and fail on standing findings across
the repo — unused module arguments, `W20` repeated attribute keys in
`nixos/configuration.nix` and `hardware-configuration.nix`, `W03`/`W04`
assignments that want `inherit`. That is a repo-wide cleanup with its own
reviewable diff; burying it inside a channel bump would make both harder to
read. Every file touched by this PR is alejandra-, deadnix- and
statix-clean already.

## S5 — validation matrix

Run after the reboot. Anything red is a rollback
([drill](./generations/rollback-drill.md)) plus a follow-up issue — not a
late-night fix on the new generation.

| # | Row | How | Result |
| --- | --- | --- | --- |
| 1 | Session type | `loginctl show-session … -p Type` → `wayland` | |
| 2 | Clipboard — shell | `echo hi \| wclip`, paste in Windows | |
| 3 | Clipboard — tmux | copy-mode `y`, paste in Windows | |
| 4 | Clipboard — vim | `"+y` from `vim-custom`, paste in Windows | |
| 5 | ssh login | `ssh nixos.local` → `.bashrc` tmux auto-attach | |
| 6 | Storybook | auto-start on login; `http://nixos.local:6006` from Windows | |
| 7 | Vite preview | project dev server reachable over the LAN | |
| 8 | typst preview | `tinymist` on `http://nixos.local:3141` | |
| 9 | Caddy subdomains | `file_host.nixos.local` resolves and proxies | |
| 10 | mDNS | `nixos.local` resolves from WSL (avahi) | |
| 11 | Docker | `docker run --rm hello-world`; existing stack comes up on 28.x | |
| 12 | Headed E2E | `headed-run pnpm test:e2e` in `some-ui` under the new Wayland stack | |
| 13 | `waypipe` escape hatch | `waypipe ssh nixos.local <gui-app>` draws on WSLg | |
| 14 | Generations | prior generation still listed and bootable | |

Rows 2–4 re-test [CLIP #15](https://github.com/paulgsc/dotfiles/issues/15);
rows 6–9 and 12–13 re-test [GUI #16](https://github.com/paulgsc/dotfiles/issues/16).
Both epics' work is Wayland-native by construction — OSC52 over the ssh TTY,
HTTP over the LAN, cage on wlroots — which is exactly why this bump is
expected to be dull.

> **Status:** rows 1–14 are unrun. They need the physical box, a reboot onto
> the new generation, and a Windows-side paste target; none of that exists in
> CI. Fill the Result column in on the machine and amend this file.
