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

One discoverable, tab-completable entry point:

```vim
:TypstPreview {start|stop|restart|status|open|help}
```

- `start` — start once for the current buffer's entrypoint if not already
  running; a no-op if it's already running for that same file. Also runs
  automatically on `FileType typst`, but the automatic call is quiet about
  the two cases that are routine rather than errors: an unsaved new
  buffer, or a different entry already running a preview. Only an
  explicit `start` reports those with an error.
- `stop` — stop the owned preview job. Reports `stopping` immediately,
  `stopped` only once the process has actually exited — `job_stop()` only
  *requests* termination, so the port may still be held for a moment
  after this returns.
- `restart` — explicit stop+start, for recovery.
- `status` — phase, actual `job_status()`, entrypoint, bind address,
  public URL, the address Tinymist itself reported listening on, and the
  last failure. A cached `starting`/`listening` phase is reconciled
  against the live job status here, so this can never claim a
  browser-ready service for a job that's actually dead.
- `open` — echoes the public preview URL to copy into the Windows
  browser. Refuses (with an error) unless the phase is verified
  `listening`, reconciled the same way. Never tries to launch a remote
  GUI browser itself.
- `logs` — opens a Vim terminal following tinymist's persisted stderr
  live (`tail -F` on `g:typst_preview_log_file`) and echoes the exact log
  path first, so it can equally be `tail -F`'d from an adjacent tmux pane.
- `help` (also bare `:TypstPreview`, `-h`, `--help`) — the above in one
  screen, plus the current phase/entry/bind/url/log path.

`:TypstPreviewStart`/`Stop`/`Restart`/`Status`/`Open` remain as thin
compatibility aliases for the equivalent subcommand, but this document and
any new mappings should only teach the `:TypstPreview` form.

- `:TypstLiveWriteToggle` — buffer-local opt-in: after this is on, a quiet
  pause in typing triggers `:update` (writes only if modified) **while
  that buffer is still the active one**. Off by default; never a blanket
  autosave policy for every `.typ` file. See "Live-write: active-buffer
  only" below for what changed here and why.

`g:typst_preview_bind` (default `'nixos.local:3141'`) and
`g:typst_preview_url` (default `'http://nixos.local:3141/'`) are separate
variables, overridable in a personal vimrc if ever needed: one is what
Tinymist is told to listen on, the other is what the browser is told to
visit, and neither is ever inferred from the other. They must, however,
name the same host and port — see "Preview address" below for why — and
`:TypstPreview start` validates that before ever spawning `tinymist`,
refusing (loudly, on an explicit start; quietly into `last_error` on the
automatic `FileType` trigger) a configuration that names different hosts.

`nixos/port-configuration/default.nix` still restricts `3141/tcp` to the
LAN subnet at the firewall; this is unrelated to the host used above and
stays in place regardless of what `g:typst_preview_bind` is set to.

Diagnostics come from ALE talking `textDocument/didChange` to `tinymist lsp`
over stdio — independent of whether the preview is running, and independent
of whether the buffer has been saved.

## Preview address: `--data-plane-host`, not deprecated `--host`

`tinymist preview --data-plane-host <bind>` is used, with an explicit
`--control-plane-host 127.0.0.1:0` alongside it and no `--host` at all.
This replaced an earlier version of this integration that used `--host`
deliberately; verified directly against the pinned v0.14.18 binary that
the newer approach is strictly better:

### Why `bind` and `url` must name the same host

Confirmed directly against the pinned tinymist v0.14.18 source
(`crates/tinymist/src/tool/preview/http.rs`, `is_valid_origin_impl`):
every WebSocket upgrade request is checked against an *expected Origin*
computed from `--data-plane-host`'s own hostname — not from the concrete
address the OS actually bound, and not from the URL a browser visits. A
plain `GET /` performs no such check, so an earlier version of this
integration (bind `0.0.0.0:3141`, browse `http://nixos.local:3141/`) would
serve the HTML shell and report `listening` normally, then silently fail
the WebSocket upgrade the moment the page tried to connect — the frontend
stayed permanently blank with no further symptom short of a browser
network trace or tinymist's own stderr (`Connection with unexpected Origin
header. Closing connection.`). `0.0.0.0` is not on tinymist's short list of
exempt origins (`localhost`/`127.0.0.1`, VS Code webviews, Gitpod, a
configured VS Code proxy URL); nothing LAN-hostname-shaped is. Keeping
`g:typst_preview_bind`'s host equal to `g:typst_preview_url`'s host is
what actually satisfies this pin, and `s:ValidatePreviewConfig()` in
`typst.vim` enforces it before ever spawning `tinymist`. `err_cb` also
recognizes that exact rejection string directly, in case some other
override ever reintroduces it, and marks the preview `failed` rather than
leaving it looking `listening`.

- With no `--host` given, Tinymist's `static_file_host` (the frontend/
  WebSocket listener) defaults to the same address as `data_plane_host`
  rather than a separate compatibility split — confirmed directly: the
  stderr log lines `Data plane server listening on: <addr>` and
  `Static file server listening on: <addr>` report the *same* address
  when only `--data-plane-host` is passed. One socket serves everything a
  browser needs; `--host`'s deprecated compatibility path is never
  invoked.
- `--control-plane-host 127.0.0.1:0` asks the OS for an ephemeral port
  for Tinymist's internal control channel instead of leaving it on the
  hidden default (`127.0.0.1:23626`). Confirmed directly that the hidden
  default can be occupied by something unrelated to this feature, and
  when it is, Tinymist logs the data-plane listener as ready and *then*
  panics trying to bind the control channel, aborting the whole process a
  moment later — an avoidable false-`listening` window that pinning this
  to an OS-assigned port removes entirely.
- A port already in use on the *advertised* (data-plane) address still
  makes the process abort outright before ever logging a listening line
  for it (a Rust panic, `AddrInUse`), confirmed directly — not silently
  serving stale content. `typst.vim`'s `err_cb` watches stderr (tinymist
  logs there exclusively, not stdout) for `Address already in use` /
  `panicked at` and marks the preview `failed` rather than leaving a
  false `listening` status; `:TypstPreview status`'s reconciliation
  against the live job additionally catches the case where the process
  dies for any other reason before that stderr line is even parsed.

## Live tracing: `:TypstPreview logs`

`err_cb` already receives every stderr line tinymist writes, for the
lifecycle parsing above; it also appends each one, timestamped, to
`g:typst_preview_log_file` (default `$XDG_STATE_HOME/tinymist-preview.log`,
falling back to `~/.local/state/tinymist-preview.log` when
`$XDG_STATE_HOME` is unset — the parent directory is created with `0700`
permissions if missing). `:TypstPreview logs` opens a Vim terminal running
`tail -F` on that file and echoes the exact path first, so the same file
can be followed from an adjacent tmux pane instead if preferred.

There is deliberately no `--log-filter` flag or `TINYMIST_LOG` variable
wired into the `tinymist` invocation: confirmed directly against the
pinned v0.14.18 source (`crates/tinymist/src/log.rs`) that neither exists
at this pin — `InitLogOpts` is a fixed struct and per-module verbosity
(`tinymist`, `tinymist_preview`, …) is hardcoded from it, not configurable
from the CLI or environment. (Tinymist's own docs describe such a flag on
a newer, unpinned revision; it does not apply here.) There is accordingly
nothing to pass tinymist for this — the value here is purely in persisting
and following the stream Vim was already receiving, without wrapping
`tinymist` in a shell pipeline, which would break `job_stop()`'s signal
delivery and `err_cb`'s line-by-line callback.

## Live-write: active-buffer only

`:TypstLiveWriteToggle`'s debounced `:update` only ever fires while its
buffer is still the current buffer in the current window. There is no
searching other tabs and no borrowing another window to reach a buffer
that has been hidden entirely — leaving the buffer (`BufLeave`)
synchronously flushes it (if dirty) and cancels the pending timer instead
of trying to reach it again later wherever it ends up.

This replaced an earlier, stronger contract that *did* survive tab
switches and fully hidden buffers, built up over several rounds of
fixing genuinely subtle bugs in that machinery (cross-tab window lookup,
borrowing a window under `'nohidden'` without losing the user's actual
alternate-buffer navigation state, and more). That contract was never an
explicit requirement of the actual authoring workflow this feature
serves — "autosave this exercise after a quiet pause while I'm working on
it" does not obviously imply "keep finding and background-saving it after
I've moved on to something else entirely" — and it added real surface for
a guarantee nothing here actually asked for. Sunk review cost is not a
product requirement on its own; the simpler, bounded contract is
preferred.

## Snippets

`vim-vsnip` (`<C-j>` expand/next placeholder, `<C-h>` previous placeholder,
insert and select mode, mapped buffer-locally to Typst buffers only — not
a global editor default other filetypes inherit) with a small structural
grammar in `pkgs/vim/snippets/typst.json`, added to `g:vsnip_snippet_dirs`
(the additive list vsnip merges alongside its own primary
`g:vsnip_snippet_dir`, confirmed against the pinned vsnip source) rather
than overwriting `g:vsnip_snippet_dir` itself — a personal snippet
directory set there stays intact: `eqi`/`eqb` (inline/block equation shells),
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
- [x] `:TypstPreview` dispatches `start`/`stop`/`restart`/`status`/`open`/
      `logs` correctly; bare `:TypstPreview`, `help`, `-h`, `--help` all
      print the same usage; an unknown subcommand errors; tab completion
      lists all seven subcommands and filters correctly by prefix (`st` →
      `start`/`stop`/`status`). The six `TypstPreview*` compatibility
      aliases (including the added `TypstPreviewLogs`) and
      `TypstLiveWriteToggle` are all still defined after sourcing.
- [x] Regression test for this exact class of bug: with
      `g:typst_preview_bind` and `g:typst_preview_url` set to different
      hosts (reproducing the original `0.0.0.0`-bind-vs-`nixos.local`-url
      default) *before* the `FileType` autocmd fires, the automatic start
      attempt is rejected by `s:ValidatePreviewConfig()` — `phase=failed`
      with an explanatory `last_error`, no job ever spawned — without
      raising a Vim error from inside the autocmd (which could otherwise
      cut off another plugin's own `FileType typst` autocmd in the same
      dispatch); an *explicit* `:TypstPreview start` with the same
      mismatch does raise one. Setting both to the same host passes
      validation and proceeds to the normal `job_start()` path. Verified
      directly against the real `pkgs/vim/typst.vim` (autoload-stubbed
      `ale#`/`vsnip#` functions, no real `tinymist` binary) rather than a
      reimplementation.
- [x] `vim-vsnip` finds snippets from both `g:vsnip_snippet_dirs` (this
      plugin's managed set) and a separately-configured `g:vsnip_snippet_dir`
      (simulating a user's own pre-existing snippet directory) at once —
      neither displaces the other. All 13 managed snippets carry correct,
      compiler-verified Typst syntax. The `<C-j>`/`<C-h>` mappings are
      buffer-local (confirmed via `maparg(..., 0, 1).buffer ==# 1`) and
      absent entirely in a non-Typst buffer.
- [x] A persistent `tinymist preview` process recompiles on save without
      being restarted; started via `--data-plane-host` (not the deprecated
      `--host`), confirmed to report the same address for both the data
      plane and static-file listeners.
- [x] Occupying Tinymist's hidden default control-plane port (`23626`)
      does not block the advertised data-plane listener from reaching
      `listening`, because `--control-plane-host 127.0.0.1:0` no longer
      leaves that channel on the conflictable default.
- [x] A port conflict on the advertised address produces a hard,
      observable failure rather than a false "still running" status
      (`:TypstPreview status` reports `failed`).
- [x] `:TypstPreview stop` reports `stopping` immediately and only reaches
      `stopped` once the process has actually exited, never the reverse.
- [x] `:TypstPreview status`/`open` reconcile a cached `starting`/
      `listening` phase against the live `job_status()`: after killing the
      owned process out-of-band (bypassing `stop` entirely), polled
      repeatedly, status never reports `listening` at any tick where
      `job_status()` itself has already stopped returning `run` — the only
      observed lag is Vim's own job-status cache catching up to the kill,
      not anything added on top of it.
- [x] A missing/non-spawnable `tinymist` executable never leaves the
      preview stuck reporting `starting` indefinitely; it reaches `failed`
      with a recorded last-error (in this sandbox's Vim build, via the
      normal async exit path rather than a synchronous `job_start()`
      failure — the synchronous check is retained regardless, since
      `:help job_start()` documents it as possible on other platforms).
- [x] Leaving the exercise buffer for another buffer does not stop the
      preview; starting the same entrypoint twice is a no-op; opening a
      second, different `.typ` file while a preview is running elsewhere
      is silent (not an error) when triggered by `FileType`, but still
      errors on an explicit `:TypstPreview start`; `VimLeavePre` stops the
      owned preview job.
- [x] `:TypstLiveWriteToggle`'s active-buffer-only contract: a burst of
      typing produces exactly one `:update` after the configured quiet
      interval while the buffer stays current (not one per keystroke);
      leaving the buffer before the quiet interval elapses (`:hide edit`
      or `:tabnew` to another file, both while the buffer is dirty)
      flushes it synchronously and cancels the pending timer, rather than
      the previous cross-tab/hidden-buffer-reaching behavior — parking a
      dirtied buffer in another tab no longer results in a later
      background write reaching back into it, because it was already
      flushed at the moment it was left.
- [ ] **Needs the real host:** `http://nixos.local:3141` reachable from
      the actual Windows browser over the LAN, *and* the WebSocket upgrade
      itself reaching `101 Switching Protocols` with a visible document
      render — not just the HTML shell loading (firewall + mDNS + real
      network path — nothing in a sandbox can stand in for this). A real-
      host report against an earlier `0.0.0.0`-bind default found exactly
      the gap this distinction is for: the shell loaded, `status` said
      `listening`, and the page stayed blank because the WebSocket upgrade
      was failing tinymist's Origin check underneath — see "Why `bind` and
      `url` must name the same host" above. Confirm both that this no
      longer happens with `bind=url`-host `nixos.local`, and, as a
      negative check, that `:TypstPreview logs` (or `status`) visibly
      reports the old failure mode if `bind` is temporarily reset to
      `0.0.0.0:3141`.
- [ ] **Needs the real host:** `ss -ltnp | grep 3141` after
      `home-manager switch`, to confirm the address actually bound matches
      what's configured, and specifically that binding literally to the
      hostname `nixos.local` (rather than `0.0.0.0`) resolves to the LAN
      interface at bind time and not to loopback — nothing in this sandbox
      can exercise the host's actual mDNS/`nss-mdns` self-resolution.
- [x] `nix build .#vim-custom` / `nix flake check` — no `nix` binary was
      available in the sandbox this was originally built in, but the
      repository's own `nix flake check + build` GitHub Actions workflow
      has since run this exact Nix expression (the two added plugins, the
      `source ${./.}/typst.vim` line) against the pinned nixpkgs and
      passed on PR #43's head.
- [ ] **Needs the real host — reported broken:** repeated hot-reload after
      the first save. A real-machine report says the preview compiles once
      but does not visibly update on subsequent `:w` saves of the same
      entry. `tinymist preview` is a genuine long-lived filesystem watcher
      (confirmed against its `v0.14.18` source: `WatchService::run()`
      compiles once, then loops on filesystem interrupts via
      `notify::RecommendedWatcher`), so a static render is not expected
      behavior — but that same source documents its rename/remove watch
      recovery as "untested and quite probably buggy," and Vim's default
      `'backupcopy'` ("auto") can replace the saved file's inode via a
      rename-based write depending on the heuristic Vim's build picks for
      a given file/filesystem, which a `notify`-based watch can lose track
      of. `typst_preview_lifecycle` now forces `setlocal backupcopy=yes`
      for Typst buffers (copy-then-overwrite-in-place, never rename) to
      remove that ambiguity outright. This could **not** be confirmed as
      the actual cause in the sandbox available here: on this sandbox's
      filesystem, plain `'auto'` already preserved the inode across a save
      for a simple single-link file, so the failure mode this fix targets
      never reproduced here to be falsified either way. The real host's
      Vim build and filesystem may make a different heuristic choice. The
      preview invocation has since also switched from deprecated `--host`
      to `--data-plane-host`/`--control-plane-host 127.0.0.1:0` (see
      "Preview address" above) — a second candidate fix for the same
      report, on the theory that the deprecated compatibility split could
      itself be a source of transport instability, though nothing in the
      sandbox evidence specifically implicated it over the `backupcopy`
      explanation. Both changes are safe and correct independent of which
      one (if either) was the actual cause.
      **Needs, on the real host:** confirm `:setlocal backupcopy?` reads
      `yes` for a Typst buffer, then perform at least two direct `:w`
      saves with visibly different content and confirm the browser
      updates after each one (not just the first). If the browser still
      doesn't update, capture `tinymist preview`'s own stderr across both
      saves (run it directly from a terminal, outside Vim, to rule out the
      Vim lifecycle code entirely) to see whether a filesystem event and a
      recompile are actually being logged for the second save — that
      isolates a watcher-level failure from a browser/WebSocket-transport
      one.
- [ ] **Open user decision:** literal PDF output was not requested and is
      not implemented. The live web preview is being treated as satisfying
      "PDF preview" for this first slice (Tinymist's own docs recommend
      web preview over PDF preview when available, since PDF preview adds
      both compile and reader-refresh latency). If literal PDF bytes are
      actually required, that's a separate, additive command
      (`typst watch entry.typ output.pdf` plus an auto-reloading reader)
      — nothing above needs to change to add it later.
