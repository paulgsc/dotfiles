" Typst authoring: semantic editing (ALE + Tinymist LSP), a persistent
" preview session, and an explicit save/publication policy.
"
" Architecture (see docs/typst-math-workflow.md for the full rationale):
"   - ALE talks textDocument/didChange to `tinymist lsp` over stdio, so
"     diagnostics/completion reflect the in-memory buffer, not disk.
"   - `tinymist preview` is a separate, persistent process. It watches the
"     file on disk and recompiles on every save on its own; it must never
"     be restarted on a text-change event, only started once per entrypoint.
"   - The two are lifecycle-independent: killing/restarting one must not
"     touch the other.
"   - Bind address (what Tinymist is told to listen on) and public URL
"     (what the browser is told to visit) are modeled as separate facts,
"     never inferred from each other -- see :TypstPreview status.

" --- ALE: register Tinymist as a real stdio LSP for Typst -----------------
" Upstream ALE (pinned via vimPlugins.ale) ships a `typstyle` *fixer* for
" Typst but no linter/LSP definition: installing the `tinymist` executable
" does not by itself register it with ALE. This Define call is the missing
" piece; naming it 'tinymist' here is what makes g:ale_linters.typst =
" ['tinymist'] (set in default.nix) refer to something real.
" A plain script-local function, not an autoload-style dotted name: it is
" handed to ale#linter#Define() directly as a Funcref below, so ALE never
" looks it up by name and it does not need to live under autoload/ (Vim's
" E746 rejects a dotted function name defined outside its matching
" autoload/ path).
function! s:GetProjectRoot(buffer) abort
  " In a linked git worktree, '.git' at the worktree root is a plain FILE
  " (containing a "gitdir: ..." pointer into the main repo's
  " .git/worktrees/<name>), not a directory -- confirmed directly with a
  " real `git worktree add`. ale#path#FindNearestDirectory() only matches
  " directories, so it finds nothing there and this used to fall through
  " to the buffer's own immediate directory as project root, breaking
  " root-dependent behavior for anything not sitting right at the
  " worktree's top level. ale#path#FindNearestFileOrDirectory() matches
  " either shape, but the two return different formats (confirmed against
  " the pinned ALE source): a matched directory gets a trailing slash
  " appended, so ':h:h' is needed to reach the repository root (one ':h'
  " only strips that trailing slash: fnamemodify('/x/.git/', ':h') ==
  " '/x/.git'); a matched file has no trailing slash, so a single ':h'
  " already reaches the worktree root.
  let l:git_path = ale#path#FindNearestFileOrDirectory(a:buffer, '.git')

  if !empty(l:git_path)
    return isdirectory(l:git_path) ? fnamemodify(l:git_path, ':h:h') : fnamemodify(l:git_path, ':h')
  endif

  return fnamemodify(bufname(a:buffer), ':p:h')
endfunction

call ale#linter#Define('typst', {
\   'name': 'tinymist',
\   'lsp': 'stdio',
\   'executable': 'tinymist',
\   'command': '%e lsp',
\   'project_root': function('s:GetProjectRoot'),
\})

" --- Preview: one persistent process per entrypoint ------------------------
" `tinymist preview` is itself a filesystem watcher (it recompiles and
" pushes to the browser on every save with no help from Vim); restarting it
" on every keystroke, as a naive HMR translation would, only churns the
" process and creates PID/port races without publishing anything Tinymist's
" own watcher wasn't already going to see. So: start once, leave it running,
" let `:w` do the rest.
"
" `bind` (what Tinymist listens on) and `url` (what the browser is told to
" visit) are deliberately separate variables, never one hostname reused for
" both roles by inference -- but confirmed directly against the pinned
" tinymist v0.14.18 source (crates/tinymist/src/tool/preview/http.rs,
" is_valid_origin_impl): the WebSocket Origin it expects is derived from
" *bind*'s hostname, not from the concrete OS-bound address or the URL, and
" a browser visiting a different hostname than that sends an Origin header
" tinymist rejects (it is not on the exception list: localhost/127.0.0.1,
" vscode-webview, Gitpod, configured vscode-proxy -- nothing LAN-hostname-
" shaped). The HTML shell still loads either way (plain GET / performs no
" Origin check), so the preview looks "listening" while staying permanently
" blank. A wildcard bind (0.0.0.0) used to be chosen here because
" nixos/port-configuration/default.nix restricts 3141/tcp to the trusted
" LAN subnet at the firewall -- that restriction is still in place, but
" 0.0.0.0 as *bind*'s value is exactly what breaks the Origin check against
" the nixos.local URL below, so bind must name the same host the browser
" visits instead. s:ValidatePreviewConfig() enforces this pin-specific
" host:port equality before ever spawning tinymist.
let g:typst_preview_bind = get(g:, 'typst_preview_bind', 'nixos.local:3141')
let g:typst_preview_url = get(g:, 'typst_preview_url', 'http://nixos.local:3141/')

" --- Live tracing: persist tinymist's stderr, don't wrap the process -------
" tinymist v0.14.18 has no --log-filter flag or TINYMIST_LOG variable --
" confirmed directly against crates/tinymist/src/log.rs: InitLogOpts is a
" fixed {is_transient_cmd, is_test_no_verbose, output} struct and module
" verbosity (including tinymist_preview, which is what actually matters
" here) is hardcoded from those, not configurable from the CLI. There is
" therefore nothing to pass tinymist for this; what's missing is a place to
" *see* the stream after the fact. s:OnPreviewErr already receives every
" stderr line for lifecycle parsing; it also appends each one, timestamped,
" to this file, so `:TypstPreview logs` can `tail -F` it live without
" wrapping tinymist in a shell pipeline (which would break job_stop()'s
" signal delivery and err_cb's line-by-line callback).
let g:typst_preview_log_file = get(g:, 'typst_preview_log_file',
      \ (exists('$XDG_STATE_HOME') && !empty($XDG_STATE_HOME)
      \   ? $XDG_STATE_HOME : expand('$HOME/.local/state'))
      \ . '/tinymist-preview.log')

function! s:EnsureLogDir() abort
  let l:dir = fnamemodify(g:typst_preview_log_file, ':h')
  if !isdirectory(l:dir)
    call mkdir(l:dir, 'p', 0700)
  endif
endfunction

" host(bind) must equal host(url) (and, unless bind's port is the
" OS-assigned 0, port(bind) must equal port(url)) for the reason explained
" above g:typst_preview_bind. Returns an explanation string on mismatch, or
" '' when compatible -- deliberately just this one equality, not a general
" semver/compatibility policy.
function! s:ValidatePreviewConfig(bind, url) abort
  let l:bind_parts = matchlist(a:bind, '^\(.*\):\(\d\+\)$')
  if empty(l:bind_parts)
    return 'g:typst_preview_bind must be "host:port" (got ' . string(a:bind) . ')'
  endif

  let l:url_parts = matchlist(a:url, '^\w\+://\([^/:]\+\)\%(:\(\d\+\)\)\?')
  if empty(l:url_parts)
    return 'g:typst_preview_url must be a URL like "http://host:port/" (got ' . string(a:url) . ')'
  endif

  let [l:bind_host, l:bind_port] = [l:bind_parts[1], l:bind_parts[2]]
  let [l:url_host, l:url_port] = [l:url_parts[1], empty(l:url_parts[2]) ? '80' : l:url_parts[2]]

  if l:bind_host !=# l:url_host
    return 'g:typst_preview_bind host (' . l:bind_host . ') must match g:typst_preview_url host ('
          \ . l:url_host . ') -- tinymist v0.14.18 computes the WebSocket Origin it expects from the '
          \ . 'bind hostname and rejects the upgrade when the browser''s Origin (from the URL you visit) differs'
  endif

  if l:bind_port !=# '0' && l:bind_port !=# l:url_port
    return 'g:typst_preview_bind port (' . l:bind_port . ') must match g:typst_preview_url port ('
          \ . l:url_port . ') for the same reason'
  endif

  return ''
endfunction

" Backed by a GLOBAL, not a plain script-local: this file is sourced via
" `source ${./.}/typst.vim` from pkgs/vim/default.nix, and `${./.}` is a
" Nix store path that changes every time this package rebuilds (editing
" typst.vim itself, or anything else in pkgs/vim/, changes the derivation
" and therefore the path). A script-local variable is keyed to the exact
" file PATH Vim sourced, not to "this logical config" -- so after any
" rebuild, `:source $MYVIMRC` loads typst.vim from a genuinely new path,
" gets a brand new script ID with its own empty script-local namespace,
" and a plain `if !exists('s:preview')` guard there would still be false:
" it would reinitialize fresh state and orphan whatever the previous
" script instance's preview job still was, the same failure this guard
" exists to prevent for a plain re-source, just via a different trigger.
" A global survives regardless of which script instance touches it.
" Vim dictionaries are reference types, so aliasing s:preview to it here
" costs nothing: every `s:preview.foo = ...` elsewhere in this file (under
" whichever script instance is currently active) mutates the one shared
" object, and a still-pending callback bound to an *older* script
" instance's function (Vim never unloads a previous instance's function
" definitions just because a new one was sourced) keeps mutating that same
" shared object too -- including the generation counter, so cross-
" instance staleness rejection keeps working exactly as it does within a
" single instance.
if !exists('g:_typst_preview_state')
  let g:_typst_preview_state = {
        \ 'job': v:null,
        \ 'generation': 0,
        \ 'entry': '',
        \ 'bind': '',
        \ 'public_url': '',
        \ 'phase': 'stopped',
        \ 'observed_listener': '',
        \ 'last_error': '',
        \ 'stderr_log': [],
        \ 'stopping': 0,
        \ 'pending_start': '',
        \ }
endif

" All code below reads/writes s:preview as before -- this is a live alias
" to the same shared dictionary, rebound on every source (cheap: no copy),
" not a fresh local state container.
let s:preview = g:_typst_preview_state

" Tinymist logs exclusively to stderr, not stdout (verified against the
" tinymist v0.14.18 binary: stdout is empty for the whole process
" lifetime). Readiness and failure must therefore be read from err_cb, not
" out_cb.
"
" a:generation is bound at job-start time via the Funcref partial below, not
" read from ambient state -- this is the one piece of evidence a callback
" needs to know whether it still belongs to the job s:preview currently
" owns. A job's stderr/exit can be delivered after we've already decided
" it's gone (job_stop() only requests termination, and Vim may still flush
" queued channel output or fire exit_cb afterward, possibly after a
" replacement job has already started for a different entry): a stale
" callback from a superseded generation must never mutate state a live one
" already owns.
function! s:OnPreviewErr(generation, channel, msg) abort
  " The generation check alone only rejects a callback superseded by a
  " *newer job having started* -- it does nothing once a stop has been
  " requested for the still-current generation, since TypstPreviewStop()
  " deliberately does not bump the generation (the real exit_cb for the
  " job being stopped still needs to match it). So also reject once we've
  " begun tearing this job down (a queued readiness/failure line must not
  " flip 'stopping' back to 'listening'/'failed' out from under the
  " pending exit) or once it's already confirmed gone (s:preview.job is
  " cleared only by that exit callback; stderr can still be delivered
  " after it runs).
  if a:generation != s:preview.generation || s:preview.stopping || s:preview.job is v:null
    return
  endif

  " A bounded ring, not a single overwritten scalar: an informational log
  " line must not erase a genuine prior failure, and last_error itself is
  " only ever set below from an actual failure line, not every line seen.
  call add(s:preview.stderr_log, a:msg)
  if len(s:preview.stderr_log) > 20
    call remove(s:preview.stderr_log, 0)
  endif

  call s:EnsureLogDir()
  call writefile([strftime('%Y-%m-%d %H:%M:%S')
        \ . ' gen=' . a:generation
        \ . ' phase=' . s:preview.phase
        \ . ' entry=' . s:preview.entry
        \ . ' ' . a:msg], g:typst_preview_log_file, 'a')

  if a:msg =~# 'Static file server listening on'
    " Retain the address Tinymist itself reports, not just the bind we
    " asked for -- if the two ever disagree, :TypstPreview status should
    " be able to show that instead of asserting they must match.
    let s:preview.observed_listener = matchstr(a:msg, 'Static file server listening on:\s*\zs\S\+')
    let s:preview.phase = 'listening'
    echom 'Typst preview: listening at ' . s:preview.public_url
  elseif a:msg =~# 'Address already in use' || a:msg =~# 'panicked at'
    let s:preview.phase = 'failed'
    let s:preview.last_error = a:msg
    echoerr 'Typst preview failed: ' . a:msg
  elseif a:msg =~# 'unexpected Origin header'
    " The HTTP shell can already be up (this arrives after "listening")
    " when this fires -- the rejected WebSocket upgrade is a distinct,
    " later failure at a distinct edge, so it must overwrite phase/
    " last_error here rather than being folded silently into the stderr
    " ring below where only :TypstPreview logs would ever surface it.
    let s:preview.phase = 'failed'
    let s:preview.last_error = a:msg
    echoerr 'Typst preview: WebSocket Origin rejected (' . a:msg . '). '
          \ . 'See g:typst_preview_bind/g:typst_preview_url.'
  endif
endfunction

function! s:OnPreviewExit(generation, job, status) abort
  if a:generation != s:preview.generation
    return
  endif

  if s:preview.stopping
    " Only a confirmed exit may ever advertise 'stopped' -- job_stop()
    " itself only requests asynchronous termination, so TypstPreviewStop()
    " sets 'stopping', not 'stopped', and waits for this callback.
    let s:preview.phase = 'stopped'
    let s:preview.entry = ''
  elseif s:preview.phase !=# 'failed'
    let s:preview.phase = 'failed'
    let s:preview.last_error = 'exited unexpectedly (status ' . a:status . ')'
    echoerr 'Typst preview exited unexpectedly (status ' . a:status . '). See :TypstPreview status.'
  endif

  let s:preview.job = v:null
  let s:preview.stopping = 0

  " job_stop() only requests termination; the OS reaps the process and this
  " callback fires asynchronously, later. Any start requested while a stop
  " was still in flight -- via :TypstPreview restart, or plain stop
  " immediately followed by start -- gets queued in pending_start (by
  " s:MaybeStartForBuffer itself, see below) instead of racing the old
  " job's belated exit. The entrypoint is captured at request time, not
  " re-resolved from "whatever buffer is current" once this callback
  " finally runs.
  if !empty(s:preview.pending_start)
    let l:target = s:preview.pending_start
    let s:preview.pending_start = ''
    " Always the deferred continuation of an explicit request (:TypstPreview
    " restart, or start racing a still-in-flight stop) -- see where
    " pending_start is set in s:MaybeStartForBuffer, both branches guarded
    " by `if a:auto | return | endif` above. Never queued for an automatic
    " FileType trigger, so a validation failure here should be as visible
    " as it would have been had the stop not still been in flight.
    call s:StartForEntry(l:target, 0)
  endif
endfunction

function! s:IsTypstBufnr(bufnr) abort
  return getbufvar(a:bufnr, '&filetype') ==# 'typst' && !empty(bufname(a:bufnr))
endfunction

" a:auto mirrors s:MaybeStartForBuffer's own parameter (see there): 1 when
" this call originated from the FileType autocmd or a pending_start
" continuation of one, 0 for a direct :TypstPreview start/restart. A config
" validation failure is real state either way (phase/last_error, visible
" via :TypstPreview status regardless), but only an explicit invocation
" should ever echoerr it -- doing so unconditionally would run this inside
" a FileType autocmd's own dispatch, and an uncaught error from an `abort`
" function there can cut off any *other* plugin's FileType autocmd still
" queued for the same event on this buffer.
function! s:StartForEntry(entry, auto) abort
  let s:preview.generation += 1
  let l:generation = s:preview.generation

  let s:preview.entry = a:entry
  let s:preview.bind = g:typst_preview_bind
  let s:preview.public_url = g:typst_preview_url
  let s:preview.last_error = ''
  let s:preview.observed_listener = ''
  let s:preview.stderr_log = []

  " Reject a bind/url host:port mismatch before ever spawning tinymist --
  " see s:ValidatePreviewConfig() above g:typst_preview_bind for why this
  " specific pin needs it. Without this, the failure only ever surfaces as
  " a permanently blank browser page well after "listening" already showed.
  let l:config_error = s:ValidatePreviewConfig(s:preview.bind, s:preview.public_url)
  if !empty(l:config_error)
    let s:preview.phase = 'failed'
    let s:preview.last_error = l:config_error
    let s:preview.job = v:null
    if !a:auto
      echoerr 'Typst preview: ' . l:config_error
    endif
    return
  endif

  let s:preview.phase = 'starting'

  " `--data-plane-host` is v0.14.18's intended path (hidden from `--help`
  " at this pin, but present and functional -- confirmed directly against
  " the pinned binary) and, with no `--host` given, the same listener
  " serves the frontend, WebSocket, and data plane together: one socket,
  " not the deprecated `--host` compatibility split. `--control-plane-host
  " 127.0.0.1:0` asks the OS for an ephemeral port for Tinymist's internal
  " control channel so it can never collide with anything -- confirmed
  " directly that a fixed default (23626) can otherwise be occupied by an
  " unrelated process and abort the whole preview process with a panic
  " *after* the data-plane listener already reported itself ready, which
  " would otherwise show as a false 'listening' phase for a job that is
  " actually seconds from dying.
  let s:preview.job = job_start(
        \ ['tinymist', 'preview',
        \   '--data-plane-host', s:preview.bind,
        \   '--control-plane-host', '127.0.0.1:0',
        \   '--no-open', a:entry],
        \ {
        \   'err_cb': function('s:OnPreviewErr', [l:generation]),
        \   'exit_cb': function('s:OnPreviewExit', [l:generation]),
        \ })

  " job_start() can, on some platforms/circumstances, return a Job whose
  " own immediate status is already 'fail' without ever invoking exit_cb
  " for that failure; see :help job_start() and :help job_status(). This
  " guard costs nothing and catches that case synchronously instead of
  " leaving 'starting' cached indefinitely for a job that never actually
  " ran. (Confirmed directly that a missing/non-executable target on this
  " platform instead goes through the normal fork-then-async-exit path --
  " job_status() reads 'run' immediately after job_start() and only
  " becomes 'dead' after an event-loop tick, reaching s:OnPreviewExit's
  " generic branch below instead of this one. Both paths converge on the
  " same outcome -- 'failed', never stuck at 'starting' -- so this guard
  " is retained for the platforms where the synchronous case is real,
  " without being load-bearing for this one.)
  if job_status(s:preview.job) ==# 'fail'
    let s:preview.phase = 'failed'
    let s:preview.last_error = 'tinymist failed to start (missing executable or invalid arguments?)'
    let s:preview.job = v:null
  endif
endfunction

" The single boundary both the automatic (FileType) and explicit
" (:TypstPreview start) paths converge on. a:bufnr is captured by the
" caller -- from <abuf> at the autocmd boundary, or bufnr('%') for an
" explicit call -- rather than read again from ambient '%' state deeper in
" here, so the entrypoint a start acts on is never ambiguous about which
" buffer it came from.
"
" a:auto: 1 when called from the FileType autocmd rather than a direct
" :TypstPreview start. The autocmd fires for every saved-or-not .typ
" buffer a user merely opens -- a brand-new unsaved exercise, or a second
" file opened just to read it while a different entry's preview is already
" running. Neither is a user request to start (or switch) a preview, so
" those two cases must stay quiet there; only an explicit invocation should
" ever echoerr about them.
function! s:MaybeStartForBuffer(bufnr, auto) abort
  if !s:IsTypstBufnr(a:bufnr)
    if !a:auto
      echoerr 'Not a Typst buffer.'
    endif
    return
  endif

  let l:entry = fnamemodify(bufname(a:bufnr), ':p')

  if !filereadable(l:entry)
    if a:auto
      return
    endif
    echoerr 'Save this buffer before starting the preview (Tinymist previews a saved file, not an unsaved buffer).'
    return
  endif

  if s:preview.stopping
    " Merely opening another saved .typ file while a stop is in flight is
    " not a request to start or switch previews either -- same principle
    " as the "already running" branch below, just for the shutdown window
    " instead of the running window. Only an explicit start/restart should
    " ever queue a pending_start here; the auto path must stay quiet and
    " let the stop actually finish stopping.
    if a:auto
      return
    endif
    " A previous job is still exiting (job_stop() only requests
    " termination, asynchronously). Queue this entry rather than racing
    " the old job's belated exit_cb for s:preview state and the port;
    " s:OnPreviewExit starts it once that job is confirmed gone.
    let s:preview.pending_start = l:entry
    return
  endif

  if s:preview.phase =~# '^\(starting\|listening\)$'
    if s:preview.entry ==# l:entry
      echom 'Typst preview already running for ' . l:entry . ' at ' . s:preview.public_url
      return
    endif

    if a:auto
      return
    endif

    echoerr 'Typst preview is already running for ' . s:preview.entry
          \ . '. Run :TypstPreview stop first to switch entrypoints.'
    return
  endif

  call s:StartForEntry(l:entry, a:auto)
endfunction

function! TypstPreviewStart(...) abort
  call s:MaybeStartForBuffer(bufnr('%'), get(a:, 1, 0))
endfunction

function! TypstPreviewStop() abort
  let s:preview.pending_start = ''
  if s:preview.job isnot v:null
    " Route through 'stopping' and let s:OnPreviewExit be the sole place
    " that ever sets 'stopped', regardless of what job_status() currently
    " reads -- job_status() reporting non-'run' does NOT mean exit_cb has
    " already fired for it (that callback is asynchronous and can still be
    " pending); jumping straight to 'stopped' here previously left that
    " pending callback's generation and s:preview.stopping both untouched,
    " so when it later ran, it read stopping=0 and treated an intentional
    " stop as an unexpected exit, overwriting the correct 'stopped' with
    " 'failed'. job_stop() on an already-dead job is a harmless no-op.
    let s:preview.stopping = 1
    let s:preview.phase = 'stopping'
    call job_stop(s:preview.job, 'term')
  else
    " No job object at all -- already fully stopped/failed previously, or
    " job_start() itself failed synchronously -- so there is no pending
    " callback left to wait on.
    let s:preview.entry = ''
    let s:preview.phase = 'stopped'
  endif
endfunction

function! TypstPreviewRestart() abort
  call TypstPreviewStop()
  call TypstPreviewStart()
endfunction

" A cached phase is not liveness evidence by itself: job_status() polls the
" OS directly and can observe a dead process before the asynchronous
" exit_cb for it has run. Status must never assert a browser-ready service
" for a job that is actually gone, even for the brief window before its
" own exit callback catches up.
function! s:ReconciledPhase() abort
  let l:job_status = s:preview.job is v:null ? 'no-job' : job_status(s:preview.job)
  if s:preview.phase =~# '^\(starting\|listening\)$' && l:job_status !=# 'run'
    return 'failed (job ' . l:job_status . ', stale phase)'
  endif
  return s:preview.phase
endfunction

function! TypstPreviewStatus() abort
  if s:preview.phase ==# 'stopped'
    echom 'Typst preview: stopped'
    return
  endif

  let l:job_status = s:preview.job is v:null ? 'no-job' : job_status(s:preview.job)
  echom 'Typst preview: ' . s:ReconciledPhase()
        \ . ' | job=' . l:job_status
        \ . ' | entry=' . s:preview.entry
        \ . ' | bind=' . s:preview.bind
        \ . ' | url=' . s:preview.public_url
        \ . ' | observed=' . (empty(s:preview.observed_listener) ? '(none)' : s:preview.observed_listener)
        \ . (empty(s:preview.last_error) ? '' : ' | last=' . s:preview.last_error)
endfunction

function! TypstPreviewOpen() abort
  if s:ReconciledPhase() !=# 'listening'
    echoerr 'Typst preview is not verified listening (phase=' . s:ReconciledPhase() . '). Run :TypstPreview start, then :TypstPreview status.'
    return
  endif

  echom s:preview.public_url
endfunction

" Opens a Vim terminal following the persistent log file live, rather than
" printing a static snapshot -- also echoes the exact path first so the
" path is visible even if the terminal window is later closed, and so it
" can be `tail -F`'d from an adjacent tmux pane instead if preferred.
function! TypstPreviewLogs() abort
  call s:EnsureLogDir()
  if !filereadable(g:typst_preview_log_file)
    call writefile([], g:typst_preview_log_file)
  endif
  echom 'Typst preview log: ' . g:typst_preview_log_file
  execute 'terminal tail -F -- ' . shellescape(g:typst_preview_log_file)
endfunction

" --- :TypstPreview {start|stop|restart|status|open|logs|help} --------------
" One discoverable, tab-completable entry point instead of several unrelated
" Ex command names. The underlying TypstPreview{Start,Stop,...} commands
" remain as thin compatibility aliases -- not a second implementation --
" but documentation teaches only this grammar.
function! s:TypstPreviewHelp() abort
  echo ':TypstPreview {start|stop|restart|status|open|logs|help}' . "\n"
        \ . '  start    start the preview for the current entrypoint (no-op if already running for it)' . "\n"
        \ . '  stop     stop the owned preview job' . "\n"
        \ . '  restart  stop then start (recovery)' . "\n"
        \ . '  status   phase, job state, entrypoint, bind/public URL, last error' . "\n"
        \ . '  open     echo the public preview URL (never opens a local browser)' . "\n"
        \ . '  logs     open a terminal following tinymist''s persisted stderr live' . "\n"
        \ . '  help     this message (also -h / --help / bare :TypstPreview)' . "\n"
        \ . '' . "\n"
        \ . 'Current: phase=' . s:ReconciledPhase() . ' entry=' . (empty(s:preview.entry) ? '(none)' : s:preview.entry) . "\n"
        \ . '  bind=' . g:typst_preview_bind . ' url=' . g:typst_preview_url . "\n"
        \ . '  log=' . g:typst_preview_log_file . "\n"
        \ . "\n"
        \ . ':TypstLiveWriteToggle toggles buffer-local autosave-after-quiet-pause (off by default).'
endfunction

function! TypstPreviewDispatch(args) abort
  let l:sub = trim(a:args)

  if empty(l:sub) || l:sub ==# 'help' || l:sub ==# '-h' || l:sub ==# '--help'
    call s:TypstPreviewHelp()
  elseif l:sub ==# 'start'
    call TypstPreviewStart()
  elseif l:sub ==# 'stop'
    call TypstPreviewStop()
  elseif l:sub ==# 'restart'
    call TypstPreviewRestart()
  elseif l:sub ==# 'status'
    call TypstPreviewStatus()
  elseif l:sub ==# 'open'
    call TypstPreviewOpen()
  elseif l:sub ==# 'logs'
    call TypstPreviewLogs()
  else
    echoerr 'Unknown :TypstPreview subcommand: ' . l:sub . '. Try :TypstPreview help.'
  endif
endfunction

function! TypstPreviewComplete(arglead, cmdline, cursorpos) abort
  let l:subs = ['start', 'stop', 'restart', 'status', 'open', 'logs', 'help']
  return filter(copy(l:subs), 'stridx(v:val, a:arglead) == 0')
endfunction

command! -nargs=? -complete=customlist,TypstPreviewComplete TypstPreview
      \ call TypstPreviewDispatch(<q-args>)

" Compatibility aliases: thin wrappers, not independent implementations.
command! TypstPreviewStart call TypstPreviewStart()
command! TypstPreviewStop call TypstPreviewStop()
command! TypstPreviewRestart call TypstPreviewRestart()
command! TypstPreviewStatus call TypstPreviewStatus()
command! TypstPreviewOpen call TypstPreviewOpen()
command! TypstPreviewLogs call TypstPreviewLogs()

augroup typst_preview_lifecycle
  autocmd!
  " `tinymist preview` watches the entry file with `notify::RecommendedWatcher`
  " (inotify on Linux), which tracks a specific inode/watch descriptor, not a
  " path. Vim's default 'backupcopy' is "auto", which on a normal writable
  " file goes through the rename-based safe-write strategy: write a new
  " file, then rename it over the original -- this replaces the inode at
  " that path on every :w. Tinymist's own watcher source documents its
  " rename/remove recovery as "untested and quite probably buggy"; forcing
  " 'backupcopy=yes' makes Vim copy-then-overwrite-in-place instead, so the
  " saved file keeps the same inode across every write and the watch never
  " needs to be re-established. Buffer-local and Typst-only: this is a
  " workaround for an external watcher's inode tracking, not a general
  " editor preference.
  autocmd FileType typst setlocal backupcopy=yes
  " <abuf> is captured at the autocmd boundary and threaded through
  " explicitly, rather than letting s:MaybeStartForBuffer re-derive "the"
  " buffer from ambient '%' state -- FileType fires synchronously for the
  " buffer whose filetype just changed, so this is not currently a source
  " of divergence, but it is the one boundary both this hook and an
  " explicit :TypstPreview start now go through identically.
  autocmd FileType typst call s:MaybeStartForBuffer(str2nr(expand('<abuf>')), 1)
  autocmd VimLeavePre * call TypstPreviewStop()
augroup END

" --- Publication policy: manual save by default -----------------------------
" Tinymist's own watcher means the preview needs nothing from Vim beyond an
" occasional `:w`. Autosave is opt-in per buffer, never a blanket policy for
" every `.typ` file (a resumed, half-written document should not be
" silently rewritten because live-write was left on in a previous session).
let g:typst_live_write_quiet_ms = get(g:, 'typst_live_write_quiet_ms', 700)

" Active-buffer-only contract: a scheduled write only ever fires while its
" buffer is still the current buffer in the current window. There is no
" cross-tab search and no hidden-buffer window-borrowing here -- the
" BufLeave hook below synchronously flushes and cancels the timer the
" moment the buffer stops being the active one, instead of trying to
" reach it again later wherever it ends up. "Debounced write while
" actively authoring this buffer" does not have to mean "keep finding and
" background-saving it after the user's attention has moved elsewhere";
" the stronger contract this replaced needed real window-borrowing/keepalt
" machinery to reach a buffer with no window at all, which is a lot of
" surface for a guarantee this feature never actually promised.
function! s:LiveWriteTick(bufnr, timer) abort
  if bufnr('%') !=# a:bufnr || !get(b:, 'typst_live_write', 0)
    return
  endif

  if &modified && !&readonly && &buftype ==# '' && !empty(bufname('%'))
    update
  endif
endfunction

function! s:LiveWriteSchedule() abort
  if !get(b:, 'typst_live_write', 0)
    return
  endif

  if exists('b:typst_live_write_timer')
    call timer_stop(b:typst_live_write_timer)
  endif

  let b:typst_live_write_timer = timer_start(
        \ g:typst_live_write_quiet_ms,
        \ function('s:LiveWriteTick', [bufnr('%')]))
endfunction

" Fires while the leaving buffer is still current (:help BufLeave): safe to
" act on ambient '%'/&-option state directly here, unlike BufUnload/
" BufDelete below, whose docs explicitly warn '%' may already differ from
" the buffer being unloaded.
function! s:LiveWriteFlushAndCancel() abort
  if exists('b:typst_live_write_timer')
    call timer_stop(b:typst_live_write_timer)
    unlet b:typst_live_write_timer
  endif

  if get(b:, 'typst_live_write', 0) && &modified && !&readonly && &buftype ==# '' && !empty(bufname('%'))
    update
  endif
endfunction

" BufUnload/BufDelete: cancel only, addressed by buffer number rather than
" ambient '%' (which the buffer being unloaded may not be), and without
" attempting a flush -- a buffer on its way out that was never properly
" left first (bypassing BufLeave) is already an unusual path; the timer
" itself must still not leak, but inventing a safe write there is not the
" job of an unload hook.
function! s:LiveWriteCancelForBuffer(bufnr) abort
  let l:timer = getbufvar(a:bufnr, 'typst_live_write_timer', 0)
  if l:timer isnot 0
    call timer_stop(l:timer)
  endif
endfunction

function! TypstLiveWriteToggle() abort
  if !s:IsTypstBufnr(bufnr('%'))
    echoerr 'Not a Typst buffer.'
    return
  endif

  let b:typst_live_write = !get(b:, 'typst_live_write', 0)
  echom 'Typst live-write: ' . (b:typst_live_write ? 'on (autosaves after a quiet pause, active buffer only)' : 'off (manual-save)')
endfunction

command! TypstLiveWriteToggle call TypstLiveWriteToggle()

augroup typst_live_write
  autocmd!
  autocmd TextChanged,TextChangedI *.typ call s:LiveWriteSchedule()
  " `nested`: without it, the :update inside s:LiveWriteFlushAndCancel()
  " runs nested inside this BufLeave autocmd's own execution, and Vim
  " does not fire autocommands triggered from within another autocommand
  " by default -- so BufWritePre/BufWritePost (ALE's g:ale_fix_on_save
  " path among them) would silently never run for this write, even though
  " the file itself still gets written. `nested` restores that: this
  " flush then behaves like the timer-driven :update (a timer callback is
  " not itself inside an autocmd, so it was never affected) and like a
  " normal :w.
  autocmd BufLeave *.typ nested call s:LiveWriteFlushAndCancel()
  autocmd BufUnload,BufDelete *.typ call s:LiveWriteCancelForBuffer(str2nr(expand('<abuf>')))
augroup END

" --- Keyboard grammar: structural snippets only -----------------------------
" Typst's own math syntax is already ASCII (`sqrt`, `sum`, `integral`, `_`,
" `^`, named symbols via completion) -- snippets exist only for the
" repetitive *structure* around that syntax (bounds, jump points), not as a
" LaTeX-compatibility layer or a stand-in for completion.
"
" `g:vsnip_snippet_dir` (singular) is vsnip's own primary, user-editable
" snippet directory (default `~/.vsnip`); overwriting it here would
" displace whatever the user already has there. `g:vsnip_snippet_dirs`
" (plural, a list) is the additive slot vsnip merges alongside it --
" confirmed directly against the pinned vsnip source
" (autoload/vsnip/source/{user_snippet,snipmate}.vim both read `+= [g:vsnip_snippet_dir]`
" then `+= g:vsnip_snippet_dirs`), so appending here can only add sources,
" never remove the user's own.
let g:vsnip_snippet_dirs = get(g:, 'vsnip_snippet_dirs', []) + [expand('<sfile>:h') . '/snippets']

augroup typst_vsnip_mappings
  autocmd!
  " Buffer-local to Typst: these are structural-snippet bindings for this
  " filetype's grammar specifically, not a global editor default that
  " every other filetype should inherit just because this file loaded.
  "
  " <C-j> does both expand and next-placeholder (matching docs/typst-math-
  " workflow.md): try expand first, then forward-jump, else fall through to
  " a literal <C-j>.
  autocmd FileType typst imap <buffer><expr> <C-j> vsnip#expandable() ? '<Plug>(vsnip-expand)' : vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : '<C-j>'
  autocmd FileType typst smap <buffer><expr> <C-j> vsnip#expandable() ? '<Plug>(vsnip-expand)' : vsnip#jumpable(1) ? '<Plug>(vsnip-jump-next)' : '<C-j>'
  autocmd FileType typst imap <buffer><expr> <C-h> vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : '<C-h>'
  autocmd FileType typst smap <buffer><expr> <C-h> vsnip#jumpable(-1) ? '<Plug>(vsnip-jump-prev)' : '<C-h>'
augroup END
