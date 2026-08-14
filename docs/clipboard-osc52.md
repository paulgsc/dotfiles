# Clipboard is OSC52 now

Copy/paste between the remote headless NixOS box and the WSL/Windows side no
longer rides X11. `xclip`, `$DISPLAY`, and `X11Forwarding` are not needed for
clipboard to work — everything travels as an **OSC52** terminal escape
sequence over the plain `ssh` TTY, and the WSL-side terminal emulator writes
it into the Windows clipboard.

WAYLANDIA-CLIP epic: [#15](https://github.com/paulgsc/dotfiles/issues/15).

| Producer                         | Where it's configured                    | Story                                                |
| -------------------------------- | ---------------------------------------- | ---------------------------------------------------- |
| tmux copy-mode yank              | `home-manager/shell/tmux`, `.tmux.conf`  | [#18](https://github.com/paulgsc/dotfiles/issues/18) |
| vim yank (`yy`, `yw`, …)         | `pkgs/vim/default.nix`, `.vimrc`         | [#19](https://github.com/paulgsc/dotfiles/issues/19) |
| CLI pipes (`pocket query`, etc.) | `home-manager/shell/clipboard` (`wclip`) | [#20](https://github.com/paulgsc/dotfiles/issues/20) |
| System package                   | `xclip` removed from `nixos/development` | [#21](https://github.com/paulgsc/dotfiles/issues/21) |

`X11Forwarding` itself is **not** removed here — that was gated on the
WAYLANDIA-GUI epic ([#16](https://github.com/paulgsc/dotfiles/issues/16)),
which has since landed: forwarding is off and `xauth`/`xhost` are gone. See
[docs/remote-gui-wayland.md](./remote-gui-wayland.md).

---

## One-time setup: enable OSC52 write on the WSL/Windows side

The remote box only _emits_ the escape sequence — your local terminal
emulator has to be willing to _write_ it into the Windows clipboard.

- **Windows Terminal**: recent stable builds honor OSC52 write by default.
  If paste isn't landing, check Settings → your profile → and confirm there
  isn't a policy disabling clipboard access; there is no per-profile toggle
  to flip on in current versions, just nothing blocking it.
- **WezTerm**: OSC52 write is enabled by default (`enable_osc52` alias is
  effectively on). If you've overridden clipboard behavior in
  `wezterm.lua`, verify you haven't disabled it.

Whichever terminal you use, re-verify with the test matrix below after any
terminal update — this is exactly the kind of setting that regresses
silently.

## Rebuilding after this change

```bash
# remote NixOS box
sudo nixos-rebuild switch --flake .#nixos
home-manager switch --flake .#"paulg@nixos"
```

If you use the plain (non-Nix) `.tmux.conf` / `.vimrc` directly (e.g. bootstrapped
onto a box before Nix is set up), just re-source them:

```bash
tmux source-file ~/.tmux.conf
# vim picks up .vimrc on next launch
```

## Test matrix (run this after rebuilding, and again after any terminal update)

With `xclip` uninstalled and `$DISPLAY` unset, over **plain `ssh`** (no `-Y`):

- [ ] **(a) Bare shell** — `printf 'hello' | wclip`, then paste in Windows.
- [ ] **(a2) Output passthrough** — `printf 'hello' | wclip > /tmp/wclip-test`,
      confirm `/tmp/wclip-test` contains `hello`, then paste `hello` in Windows.
- [ ] **(a3) Pipeline passthrough** — `printf 'hello' | wclip | tr a-z A-Z`,
      confirm the command prints `HELLO`, then paste the original `hello` in Windows.
- [ ] **(b) tmux copy-mode** — enter copy-mode, select text, `y`; paste in Windows.
- [ ] **(c) vim yank** — `yy` on a line in the managed vim; paste in Windows.
      (**Not** `"+yy` — see "Why `"+yy` is not the ergonomic" below.)
- [ ] **(d) CLI pipe** — `pocket query | wclip` (see below); paste in Windows.
- [ ] **(b) again, after reconnect** — `tmux detach`, `tmux attach`, repeat the copy-mode yank.

This is the acceptance gate for [#22](https://github.com/paulgsc/dotfiles/issues/22)
and was the hard prerequisite for dropping `X11Forwarding` in #16 — so re-run it
after that change too, to confirm the clipboard did not quietly depend on the
channel that got deleted.
It has to be run against your real WSL ⇄ remote topology — nothing in CI can
exercise the Windows-clipboard side of this chain.

## `pocket query` still says `wl-copy`/`xclip` in `paulgsc/server`

That repo is out of scope for this PR (different repository). Repoint the
documented ergonomic there from `pocket query | wl-copy` to
`pocket query | wclip` in a follow-up change to `paulgsc/server`. Until
that lands, use `wclip` directly — `pocket` already writes the
selection to stdout, so no behavioral change to `pocket` itself is needed.

## Why `"+yy` is not the ergonomic

Manual verification of [#16](https://github.com/paulgsc/dotfiles/issues/16)
turned up two bugs in the original migration. Both had the same symptom —
nothing arrives in Windows — and neither was caused by that epic; retiring
`ssh -Y` is just what finally forced the two producers to be exercised without
a display.

**vim: `"+` has no provider, so the yank never reached the handler.**
`vim-full` is compiled `+clipboard`, but that clipboard is X11-backed. With no
`$DISPLAY` — the normal state over plain `ssh`, and the permanent state after
#16 — vim's `adjust_clip_reg()` silently rewrites `"+` and `"*` to the
*unnamed* register **before** the yank happens. `TextYankPost` then reports an
empty `regname`, so the old guard (`regname ==# '+'`) never matched and the
OSC52 handler was never called. `"+yy` looked like it worked and copied
nothing. A vim built `-clipboard` fares no better: `"+` is `E354` and never
yanks at all.

Since `"+` cannot be made to work on a display-less box, the handler now fires
on an ordinary yank whenever no clipboard provider exists. **Every `yy` reaches
the Windows clipboard.** On a machine whose only clipboard *is* the terminal
that is the useful default, but it is a real behaviour change — set
`g:osc52_yank_unnamed = 0` before the config loads to opt out and go back to
requiring an explicit `"+y` (which will then copy nothing).

**tmux: the `Ms` capability was malformed, so tmux emitted nothing.**
tmux calls `Ms` with **two** string parameters — `%p1` is the selection
(`c`, `s0`, …) and `%p2` is the base64 payload. The override read:

```tmux
set -as terminal-overrides ',*:Ms=\E]52;c;%p1%s\007'   # broken
```

which pins the selection but then interpolates the *selection* as the payload
and never emits `%p2`. Handed two arguments for a one-argument capability,
tmux wrote **no OSC52 at all** — verified by capturing a client's pty. Both
parameters have to be consumed, in order; `Ms=\E]52;c;%p2%s\007` is equally
silent. The working form is the standard one:

```tmux
set -as terminal-overrides ',*:Ms=\E]52;%p1%s;%p2%s\007'
```

This is also why `wclip` kept working while both of these failed: `wclip`
writes the DCS-wrapped sequence straight to `/dev/tty`, so it rides
`allow-passthrough` and never touches `Ms` at all.
