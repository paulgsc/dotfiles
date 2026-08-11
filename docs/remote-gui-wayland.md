# The `ssh -Y` remote-window channel is retired

`ssh -Y` used to buy two things on this box: the clipboard, and remote window
forwarding — running a GUI program on the NixOS machine and having it draw on
the WSL/Windows side. The clipboard moved to OSC52 in
[WAYLANDIA-CLIP #15](https://github.com/paulgsc/dotfiles/issues/15)
(see [docs/clipboard-osc52.md](./clipboard-osc52.md)). This document covers the
other half: **X11 forwarding is now off, and nothing in the daily workflow
needs it.**

WAYLANDIA-GUI epic: [#16](https://github.com/paulgsc/dotfiles/issues/16).
Feeds the security review, [#7](https://github.com/paulgsc/dotfiles/issues/7).

| Story | What it settled | Where |
| --- | --- | --- |
| [#23](https://github.com/paulgsc/dotfiles/issues/23) S1 | Inventory of every GUI / `$DISPLAY` consumer | [table below](#s1--what-was-actually-using-the-display) |
| [#24](https://github.com/paulgsc/dotfiles/issues/24) S2 | Remote-GUI transport: `waypipe`, on demand | `nixos/remote-gui` |
| [#25](https://github.com/paulgsc/dotfiles/issues/25) S3 | Headed browser tests: throwaway Wayland compositor | `home-manager/shell/headed-test` |
| [#26](https://github.com/paulgsc/dotfiles/issues/26) S4 | Dev servers are web-forwarded, not X-forwarded | [test matrix](#test-matrix) |
| [#27](https://github.com/paulgsc/dotfiles/issues/27) S5 | `X11Forwarding`/`xauth`/`xhost` deleted | `nixos/remote-gui` |

---

## S1 — what was actually using the display

The recon result worth internalising: **almost nothing that looked like
forwarding was forwarding.** The dev-server workflows are ordinary HTTP over
the LAN, viewed in the Windows browser. They never touched X11 and are
completely indifferent to this change.

| Consumer | Where it's configured | Really X11? | Disposition |
| --- | --- | --- | --- |
| Storybook (`some-ui`) | `.bashrc` autostarts `pnpm storybook`; port 6006 in `nixos/port-configuration` | No — HTTP, binds `0.0.0.0`, `allowedHosts: nixos.local` | Web-forwarded, unaffected |
| Vite previews | same project | No — HTTP | Web-forwarded, unaffected |
| `tinymist` typst preview | `pkgs/vim/default.nix` → `--host nixos.local:3141`; port 3141 registered | No — HTTP over mDNS | Web-forwarded, unaffected |
| Grafana / Prometheus / Redis admin / Metabase | `nixos/port-configuration` | No — HTTP | Web-forwarded, unaffected |
| Clipboard (tmux yank, vim `"+y`, CLI pipes) | `home-manager/shell/{tmux,clipboard}`, `pkgs/vim` | Not since #15 — OSC52 over the ssh TTY | Already migrated |
| OBS audio capture | `obs/`, NATS to `nixos.local:4222` | No — runs client-side on Windows/WSL | Unaffected |
| GNOME desktop, Firefox | `nixos/configuration.nix` (`services.xserver`, GDM, autologin `paulg`) | Local seat-0 session, never forwarded | Out of scope — see note below |
| **Headed Playwright E2E** | `some-ui` fixtures probe `$DISPLAY`/`$WAYLAND_DISPLAY`, else `--headless=new` | **This was the one real dependency** | Replaced — see S3 |
| `xorg.xauth`, `xorg.xhost` | `nixos/ssh-x11` (now `nixos/remote-gui`) | Existed only to serve forwarding | **Deleted** |

Exactly one workflow genuinely needed a display, and it needed a display —
not specifically a *forwarded* one. That is what made S5 possible.

> **Note on the GNOME session.** `nixos/configuration.nix` still enables
> `services.xserver`, GDM and GNOME with autologin. That is the box's own
> desktop on seat 0 and has nothing to do with ssh forwarding; retiring it is
> a separate question this epic deliberately does not touch. It is also why a
> true GUI app has somewhere to run without any transport at all: walk up to
> the machine, or use the escape hatch below.

## S2 — the remote-GUI transport: `waypipe`, when you actually need it

The honest answer for daily work is **no transport is needed**. Nothing in the
inventory above draws a remote window as part of a normal day.

For the rare genuine case, the sanctioned tool is **`waypipe`** — the Wayland
equivalent of `ssh -X`, forwarding the Wayland protocol over an ordinary ssh
stdio channel:

```bash
# from WSL (WSLg provides the Windows-side compositor)
waypipe ssh nixos.local <gui-app>
```

`waypipe` is *installed* on the remote (`nixos/remote-gui`) rather than merely
written down here, so the escape hatch works the day it is needed instead of
requiring a rebuild first. It is strictly better than what it replaces: no
listening socket, no `MIT-MAGIC-COOKIE` file on disk, and it forwards one
application rather than granting a channel to the whole session.

Why not keep `ssh -Y` for this? Because `-Y` is *trusted* forwarding — it
disables the X security extension, so any program on the remote can read your
keystrokes and screen-scrape other windows on the WSL side. Keeping a
permanently-enabled channel with that blast radius, to serve a case that
occurs approximately never, is precisely the trade the security review objects
to.

## S3 — headed browser tests without a forwarded display

`some-ui`'s Playwright fixtures fall back to `--headless=new` when both
`$DISPLAY` and `$WAYLAND_DISPLAY` are unset. Over plain ssh both are unset, so
`headless: false` was untestable — the last real argument for keeping `-Y`.

The replacement gives the test its **own** compositor on the remote instead of
borrowing one from Windows. `headed-run` (in `home-manager/shell/headed-test`)
wraps any command in [`cage`](https://github.com/cage-kiosk/cage) running on
wlroots' headless backend — software rendering into memory, no GPU, no seat,
no monitor:

```bash
headed-run pnpm test:e2e
headed-run pnpm exec playwright test --headed
```

It reuses an existing display if one is already present (at the physical
console), and otherwise creates a throwaway `XDG_RUNTIME_DIR`, runs the
compositor for exactly the lifetime of the command, and forwards the command's
exit status so a failing suite still fails the caller.

Xvfb would also have worked, and was rejected on purpose: it would have
reintroduced an X server as a *build-time dependency of the test path* in the
same change that deletes X from the ssh path. `cage` keeps the headed story
Wayland-native.

Chromium does not pick Wayland on its own — the fixtures need to launch it
with:

```ts
launchOptions: {
  args: ['--ozone-platform=wayland', '--enable-features=UseOzonePlatform'],
}
```

That snippet lives in `paulgsc/some-ui`, not this repo; until it lands there,
`headed-run` still gives the browser a valid display and Chromium will fall
back to its own headless path rather than failing.

## S4 — the dev servers were never forwarded

Storybook, Vite and `tinymist` bind `0.0.0.0` and are reached at
`http://nixos.local:<port>` from the Windows browser. They are listed in
`nixos/port-configuration` with their firewall rules, and none of them consult
`$DISPLAY`. Turning `X11Forwarding` off cannot affect them — but "cannot
affect them" is a claim, and the test matrix below is where it gets checked
against the real topology.

## S5 — what was removed

From `nixos/ssh-x11/default.nix`, now `nixos/remote-gui/default.nix`:

- `X11Forwarding = true` → **`false`**, written explicitly rather than dropped,
  so the module records a decision instead of a silent default
- `X11DisplayOffset` / `X11UseLocalhost` — both only tune a channel that no
  longer exists
- `xorg.xauth` — minted the per-session magic cookie for forwarding
- `xorg.xhost` — host-based X access control

The module was renamed because a directory called `ssh-x11` whose entire
content is "no X11" is a trap for the next reader.

---

## Rebuilding

```bash
# remote NixOS box
sudo nixos-rebuild switch --flake .#nixos
home-manager switch --flake .#"paulg@nixos"
```

`X11Forwarding` is an **sshd** setting, so it takes effect for *new* ssh
connections after the rebuild restarts sshd. Your current session keeps
whatever it negotiated at login — which is the single most common way to
"verify" this change and get a misleading answer. Reconnect first.

## Test matrix

Run over **plain `ssh`** (no `-Y`, no `-X`), after `nixos-rebuild switch` and
after reconnecting. Full step-by-step walkthrough:
[the verification runbook](https://github.com/paulgsc/dotfiles/issues/16).

- [ ] **(a) Forwarding is actually off** — `echo "$DISPLAY"` prints nothing on
      a fresh connection; `ssh -Y nixos.local echo hi` still connects but
      leaves `$DISPLAY` unset (sshd is refusing the channel, not the login).
- [ ] **(b) `xauth`/`xhost` are gone** — `command -v xauth xhost` finds nothing.
- [ ] **(c) Storybook** — reconnect, let `.bashrc` start it, browse
      `http://nixos.local:6006` from Windows.
- [ ] **(d) tinymist preview** — open a `.typ` in the managed vim, trigger the
      preview, browse `http://nixos.local:3141` from Windows.
- [ ] **(e) Clipboard still works** — re-run the
      [OSC52 matrix](./clipboard-osc52.md); it must not have regressed, since
      #15 is what made #16 possible.
- [ ] **(f) Headed tests** — `headed-run pnpm exec playwright test --headed`
      in `~/dev/some-ui` runs against a real compositor rather than silently
      falling back to headless.
- [ ] **(g) Escape hatch** — from WSL, `waypipe ssh nixos.local <gui-app>`
      draws a window on Windows.

Nothing in CI can exercise (c)–(g): they all depend on the real
WSL ⇄ remote ⇄ Windows-browser topology. CI checks that the flake still
evaluates and builds; the matrix is what checks that the machine still works.
