# The session on this box is GNOME on Wayland

The decision record for
[WAYLANDIA-SESSION #17](https://github.com/paulgsc/dotfiles/issues/17) story
[S1 #28](https://github.com/paulgsc/dotfiles/issues/28). The bump itself, and
the breaking-change audit behind it, live in
[docs/channel-bump-26.05.md](./channel-bump-26.05.md).

## The question, and why it stopped being a question

`nixos/configuration.nix` enabled `services.xserver`, GDM and GNOME. On a
headless box driven entirely over ssh, that raised three options:

| Option | Verdict |
| --- | --- |
| (a) GNOME on Wayland | **Chosen.** It is also the only one still implementable. |
| (b) Force X11 (`gdm.wayland = false`) | **Gone.** Not "discouraged" — removed. |
| (c) Trim the desktop off the headless box | Out of scope here; see below. |

Option (b) died upstream while this repo sat on 25.05, which is precisely the
kind of thing deferring a channel bump hides from you:

- **GNOME 49** (NixOS 25.11) "removes X11 session support. Though you can
  still run X11 apps using XWayland" — nixpkgs `rl-2511.section.md`.
- On **26.05**, `services.displayManager.gdm.wayland` is a
  `mkRemovedOptionModule`, with the message *"Disabling this option is no
  longer supported with GNOME 50"* —
  `nixos/modules/services/display-managers/gdm.nix`.

So there was no X11 fallback left to hold in reserve. The session type was
decided by upstream; what this config still chooses is everything around it.

Option (c) — deleting GNOME from a machine with no monitor — stays open but is
not this epic's business. `nixos/remote-gui` records that seat-0 GNOME is the
sanctioned home for true GUI apps, and headed browser tests already got their
own compositor (`headed-run`, cage on wlroots' headless backend) in
[WAYLANDIA-GUI #16](https://github.com/paulgsc/dotfiles/issues/16). Trimming
the desktop would be a separate change, with its own reboot and its own
rollback.

## What actually changed in `nixos/configuration.nix`

```diff
-services.xserver.enable = true;
-services.xserver.displayManager.gdm.enable = true;
-services.xserver.desktopManager.gnome.enable = true;
+services.displayManager.gdm.enable = true;
+services.desktopManager.gnome.enable = true;
```

Two different things happened in that diff.

**The renames are bookkeeping.** GDM and GNOME moved out from under
`services.xserver` upstream — they are no longer X11 things. The old paths
still resolve on 26.05 through `mkRenamedOptionModule`, so this is a warning
we are paying off early, not a build break.

**Dropping `services.xserver.enable` is the real change.** It built an Xorg
server that can now host no session, on a machine with no monitor. Two things
that look like they depend on it do not:

- **X11 apps still run.** Xwayland comes from the compositor, not from Xorg:
  nixpkgs builds mutter with `-Dxwayland_path=${lib.getExe xwayland}`
  (`pkgs/by-name/mu/mutter/package.nix`). GNOME never sets
  `programs.xwayland.enable` because it does not need to.
- **The keymap still applies.** `services.xserver.xkb.layout` is kept, and it
  still takes effect, by a route that has nothing to do with the X server:
  GDM sets `services.displayManager.enable`, whose value is the default for
  the internal `services.graphical-desktop` module, which writes
  `/etc/X11/xorg.conf.d/00-keyboard.conf` — the file `localectl` reads, and
  through it GNOME and the greeter
  (`nixos/modules/services/misc/graphical-desktop.nix`).

That second one is worth keeping in mind the next time `services.xserver.*`
looks like dead X11 config: on a Wayland-only system, part of it isn't.

## Recording the session type in situ

The epic asks for the current session type recorded from the box itself. Run
this after the reboot in
[docs/channel-bump-26.05.md](./channel-bump-26.05.md#s3--the-bump) and paste
the output here:

```console
$ loginctl list-sessions
$ loginctl show-session "$(loginctl list-sessions --no-legend | awk '/paulg/{print $1; exit}')" -p Type -p Remote
$ systemctl --user show-environment | grep -E 'WAYLAND_DISPLAY|XDG_SESSION_TYPE'
```

Expected after this change: `Type=wayland` for the seat-0 autologin session.
An ssh login is `Type=tty` with no `WAYLAND_DISPLAY` — that is correct and
unchanged; nothing in the daily workflow reads a display over ssh any more.

| Date | Where | `Type` | Notes |
| --- | --- | --- | --- |
| _pending first boot on 26.05_ | seat 0 (autologin `paulg`) | | |

## If the greeter does not come up

In order, cheapest first:

1. Roll back at the bootloader — the previous generation still has Xorg and
   the old channel. [docs/generations/rollback-drill.md](./generations/rollback-drill.md)
   is the rehearsed procedure.
2. If GDM starts but the session dies, `journalctl -b -u display-manager` and
   `journalctl -b --user -u gnome-session*` from an ssh login. ssh is
   deliberately independent of all of this.
3. Re-adding `services.xserver.enable = true;` is a one-line experiment, but
   it will not bring an X11 *session* back — GNOME 49+ has none. If the
   Wayland session is genuinely broken, the answer is a rollback and an issue,
   not an X server.
