# Typst math authoring in managed Vim

Editing a `.typ` exercise in the managed Vim now gets you three independent
services, not one hand-rolled "HMR" loop:

| Mechanism | Owner | Behavior |
| --- | --- | --- |
| Typst grammar | `vimPlugins.typst-vim` | filetype detection, syntax, indent |
| Semantic editing | ALE + an explicit `tinymist lsp` stdio definition (`pkgs/vim/typst.vim`) | diagnostics/completion from the in-memory buffer |
| Live rendered preview | one persistent `tinymist preview` process per entrypoint | watches the saved file and pushes to the browser on its own |
| Publication | manual `:w` by default; opt-in debounced `:update` per buffer | explicit, not silent autosave |

Files: `pkgs/vim/typst.vim` (ALE definition, preview lifecycle, live-write
toggle, snippet mappings), `pkgs/vim/snippets/typst.json` (structural
snippets), both sourced/loaded by `pkgs/vim/default.nix`.

## Why the old integration didn't work

The previous config set `g:ale_linters.typst = ['tinymist']` without ever
calling `ale#linter#Define('typst', ...)`. Upstream ALE (pinned at
`dense-analysis/ale@2a3af30f`) ships a Typst *fixer* (`typstyle`) but no
linter/LSP definition at all, so that name never resolved to anything —
confirmed by cloning that exact revision and checking
`supported-tools.md`. Installing the `tinymist` executable doesn't change
that; ALE only knows about linters it has an explicit definition for.

Separately, the old preview autocmd killed and relaunched
`tinymist preview` on every `TextChanged`/`TextChangedI`, invoked against
the file *on disk*. Two things make that actively counterproductive:

- `tinymist preview` is itself a filesystem watcher. Verified directly
  against the pinned binary (`tinymist` v0.14.18, matching
  `nixpkgs` `02e08985a2...`): a single long-running `tinymist preview`
  process picks up and recompiles a plain `:w`-saved change with no
  restart at all. Killing and relaunching it on every keystroke churns the
  process for no benefit and reintroduces PID/port races.
- The old restart still only ever read the last saved snapshot — it never
  transmitted the in-memory buffer — so it could not have shown unsaved
  edits regardless of how eagerly it restarted.

## Commands

- `:TypstPreviewStart` — start once for the current buffer's entrypoint if
  not already running; a no-op if it's already running for that same file.
  Also runs automatically on `FileType typst` for a saved buffer.
- `:TypstPreviewStop` — stop the owned preview job.
- `:TypstPreviewRestart` — explicit stop+start, for recovery.
- `:TypstPreviewStatus` — entrypoint, job state, address, last error line.
- `:TypstPreviewOpen` — echoes the preview URL (`http://nixos.local:3141/`
  by default) to copy into the Windows browser. Never tries to launch a
  remote GUI browser itself.
- `:TypstLiveWriteToggle` — buffer-local opt-in: after this is on, a quiet
  pause in typing triggers `:update` (writes only if modified). Off by
  default; never a blanket autosave policy for every `.typ` file.

`g:typst_preview_host` (default `'nixos.local'`) and `g:typst_preview_port`
(default `3141`, matching the firewall rule in
`nixos/port-configuration/default.nix`) are overridable in a personal vimrc
if ever needed.

Diagnostics come from ALE talking `textDocument/didChange` to `tinymist lsp`
over stdio — independent of whether the preview is running, and independent
of whether the buffer has been saved.

## Preview address: why `--host`, not `--data-plane-host`

`tinymist preview --host <addr>` is still used, deliberately, even though
`--host` is marked `(Deprecated)` in `tinymist preview --help`. Verified
directly against the pinned v0.14.18 binary:

- `tinymist preview` actually opens three listeners: `data_plane_host` and
  `control_plane_host` (both default to `127.0.0.1:<random>` if unset), and
  `static_file_host`, which is what `--host` actually sets (the CLI's own
  help text describing `--host` as an alias for `data_plane_host` does not
  match the binary's behavior — a real discrepancy between docs and this
  build).
- Despite that split, driving a real headless-Chromium session at the
  `--host` address alone renders correctly end-to-end: the page's WebSocket
  connects back to that same address (`ws://<host>/`, same-origin), live
  SVG content renders, and there are zero failed requests or console
  errors. `--data-plane-host`/`--control-plane-host` only matter if you
  want those split onto separate addresses, which this single-port,
  firewall-scoped deployment does not need.
- A port already in use makes the process abort outright (a Rust panic,
  `AddrInUse`), not silently keep serving stale content — `typst.vim`'s
  `err_cb` watches stderr (tinymist logs there exclusively, not stdout) for
  `Address already in use` / `panicked at` and marks the preview `failed`
  rather than leaving a false `listening` status.

## Snippets

`vim-vsnip` (`<C-j>` expand/next placeholder, `<C-h>` previous placeholder,
insert and select mode) with a small structural grammar in
`pkgs/vim/snippets/typst.json`: `eqi`/`eqb` (inline/block equation shells),
`frac`, `sqrt`, `root`, `sum`, `prod`, `int`, `lim`, `align` (aligned
derivation), `cases`, `mat`, `vec`. Every one of these was compiled and,
where layout mattered (the aligned derivation, cases), rendered to PNG
against the pinned Typst 0.14.2 compiler to confirm both syntax and visual
correctness before being committed.

Deliberately not snippet-ified: named symbols and functions (`alpha`, `pi`,
`RR`, arrows, relations) — those are ASCII already and are what Tinymist's
own completion is for (confirmed working: completing `sq` inside math
returns `sqrt`/`square` via a real `textDocument/completion` request
against the pinned binary). Conceal is not enabled; it would hide the
source grammar this loop exists to make comfortable.

## Rebuild

```bash
home-manager switch --flake .#"paulg@nixos"
```

No NixOS-level change is needed — the port rule already exists.

## Verification matrix

Checked in an isolated sandbox against the exact pinned versions
(`tinymist` v0.14.18, `ale@2a3af30f`, `typst-vim@1d5436c`,
`vim-vsnip@9bcfabe`, real headless Chromium, and a real PTY-driven
interactive Vim session for the timing-sensitive checks) but **not**
against the real NixOS host, its firewall, or an actual Windows browser —
those need a run on the real machine:

- [x] Typst filetype/syntax/indent load from `typst-vim` alone.
- [x] `ale#linter#Get('typst')` includes `tinymist` after sourcing
      `typst.vim`.
- [x] ALE produces real diagnostics (`unclosed delimiter`, `expected
      comma`) against an in-memory, never-saved buffer via the real ALE
      engine, not just a raw LSP probe.
- [x] `textDocument/completion` inside math returns `sqrt`/`square`.
- [x] All six `TypstPreview*`/`TypstLiveWriteToggle` commands are defined
      after sourcing.
- [x] `vim-vsnip` expands all 13 snippets with the expected content.
- [x] A persistent `tinymist preview` process recompiles on save without
      being restarted.
- [x] `--host <addr>` alone is sufficient for a real browser to load and
      live-render content (headless Chromium, WebSocket observed, SVG
      content present, zero console/network errors).
- [x] A port conflict produces a hard, observable failure rather than a
      false "still running" status (`:TypstPreviewStatus` reports
      `failed`).
- [x] Leaving the exercise buffer for another buffer does not stop the
      preview; starting the same entrypoint twice is a no-op; `VimLeavePre`
      stops the owned preview job.
- [x] `:TypstLiveWriteToggle`, under a real interactive Vim session with
      realistic per-keystroke timing: a burst of typing produces exactly
      one `:update` after the configured quiet interval (not one per
      keystroke), the buffer becomes unmodified, and the file on disk
      matches what was typed.
- [ ] **Needs the real host:** `http://nixos.local:3141` reachable from
      the actual Windows browser over the LAN (firewall + mDNS + real
      network path — nothing in a sandbox can stand in for this).
- [ ] **Needs the real host:** `ss -ltnp | grep 3141` after
      `home-manager switch`, to confirm the address actually bound matches
      what's configured.
- [ ] **Needs the real host:** `nix build .#vim-custom` / `nix flake
      check` — no `nix` binary was available in the sandbox this was
      built in, so the Nix expression itself (adding two plugins, adding
      one `source ${./.}/typst.vim` line) was reviewed but never actually
      built.
- [ ] **Open user decision:** literal PDF output was not requested and is
      not implemented. The live web preview is being treated as satisfying
      "PDF preview" for this first slice (Tinymist's own docs recommend
      web preview over PDF preview when available, since PDF preview adds
      both compile and reader-refresh latency). If literal PDF bytes are
      actually required, that's a separate, additive command
      (`typst watch entry.typ output.pdf` plus an auto-reloading reader)
      — nothing above needs to change to add it later.
