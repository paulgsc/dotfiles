# Clipboard is OSC52 now

Copy/paste between the remote headless NixOS box and the WSL/Windows side no
longer rides X11. `xclip`, `$DISPLAY`, and `X11Forwarding` are not needed for
clipboard to work — everything travels as an **OSC52** terminal escape
sequence over the plain `ssh` TTY, and the WSL-side terminal emulator writes
it into the Windows clipboard.

WAYLANDIA-CLIP epic: [#15](https://github.com/paulgsc/dotfiles/issues/15).

| Producer | Where it's configured | Story |
|---|---|---|
| tmux copy-mode yank | `home-manager/shell/tmux`, `.tmux.conf` | [#18](https://github.com/paulgsc/dotfiles/issues/18) |
| vim `"+y` / `"*y` | `pkgs/vim/default.nix`, `.vimrc` | [#19](https://github.com/paulgsc/dotfiles/issues/19) |
| CLI pipes (`pocket query`, etc.) | `home-manager/shell/clipboard` (`wclip`) | [#20](https://github.com/paulgsc/dotfiles/issues/20) |
| System package | `xclip` removed from `nixos/development` | [#21](https://github.com/paulgsc/dotfiles/issues/21) |

`X11Forwarding` itself is **not** removed here — that's gated on the
WAYLANDIA-GUI epic ([#16](https://github.com/paulgsc/dotfiles/issues/16)) and
is out of scope for this epic.

---

## One-time setup: enable OSC52 write on the WSL/Windows side

The remote box only *emits* the escape sequence — your local terminal
emulator has to be willing to *write* it into the Windows clipboard.

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

## Reading the Windows clipboard

`wclip --paste` (also available as `wpaste`) sends the OSC52 clipboard query
to the local terminal and writes the decoded reply to stdout. This makes the
Windows clipboard composable with normal shell tools:

```bash
wclip --paste > clipboard.txt
wclip --paste | jq .
wpaste | sha256sum
```

Clipboard **reading** is separate from OSC52 writing and is intentionally
restricted by terminal emulators because it lets a remote process inspect
the local clipboard. The command times out with a clear error when the local
terminal does not implement OSC52 queries or has clipboard reads disabled.
In particular, OSC52 write support alone does not guarantee that this works;
it must be tested with the actual Windows terminal and its clipboard policy.
Set `WPASTE_TIMEOUT` to change the two-second response timeout.

If the Windows terminal does not support OSC52 reads, the reliable fallback
has to originate on Windows/WSL, where the clipboard is locally accessible,
for example piping `powershell.exe -NoProfile -Command Get-Clipboard` into an
`ssh ... 'cat > clipboard.txt'` command. A remote process cannot otherwise
pull the client clipboard over plain SSH.

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
- [ ] **(a4) Clipboard read to file** — copy `from Windows`, run
  `wclip --paste > /tmp/wclip-paste`, and confirm the file contains
  `from Windows` (or confirm the terminal reports that reads are unsupported).
- [ ] **(b) tmux copy-mode** — enter copy-mode, select text, `y`; paste in Windows.
- [ ] **(c) vim `"+y`** — `"+yy` on a line in the managed vim; paste in Windows.
- [ ] **(d) CLI pipe** — `pocket query | wclip` (see below); paste in Windows.
- [ ] **(b) again, after reconnect** — `tmux detach`, `tmux attach`, repeat the copy-mode yank.

This is the acceptance gate for [#22](https://github.com/paulgsc/dotfiles/issues/22)
and, transitively, the hard prerequisite for dropping `X11Forwarding` in #16.
It has to be run against your real WSL ⇄ remote topology — nothing in CI can
exercise the Windows-clipboard side of this chain.

## `pocket query` still says `wl-copy`/`xclip` in `paulgsc/server`

That repo is out of scope for this PR (different repository). Repoint the
documented ergonomic there from `pocket query | wl-copy` to
`pocket query | wclip` in a follow-up change to `paulgsc/server`. Until
that lands, use `wclip` directly — `pocket` already writes the
selection to stdout, so no behavioral change to `pocket` itself is needed.
