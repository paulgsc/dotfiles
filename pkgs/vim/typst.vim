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
"   - The preview follows an active-ordinary-file lease: the current saved
"     Typst buffer is the desired target, and a reconciler asynchronously
"     makes the running job match it. See s:ConvergePreview() below.

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
        \ 'desired_entry': '',
        \ 'desired_auto': 0,
        \ 'bind': '',
        \ 'public_url': '',
        \ 'phase': 'stopped',
        \ 'observed_listener': '',
        \ 'last_error': '',
        \ 'stderr_log': [],
        \ 'stopping': 0,
        \ }
endif

" All code below reads/writes s:preview as before -- this is a live alias
" to the same shared dictionary, rebound on every source (cheap: no copy),
" not a fresh local state container.
let s:preview = g:_typst_preview_state

" g:_typst_preview_state survives a plain `:source $MYVIMRC` (see above),
" so a dict created by an older version of this file -- before
" 'desired_entry'/'desired_auto' existed -- is not recreated by the guard
" above and would otherwise be missing these keys entirely, throwing E716
" the first time any function below reads them. Captured before either key
" is added: this is also the signal for the inherited-job check below,
" which needs to know whether this dict predates them, not whether it
" still does after this block runs.
let s:migrating_preview_state = !has_key(s:preview, 'desired_entry')

if !has_key(s:preview, 'desired_entry')
  let s:preview.desired_entry = ''
endif
if !has_key(s:preview, 'desired_auto')
  let s:preview.desired_auto = 0
endif

" A dict shaped like this was created by a version of this script whose
" s:OnPreviewExit predates desired_entry-based reconciliation. If a job is
" currently running, its exit_cb Funcref is still bound to that OLD
" function -- Vim never rebinds an already-running job's callbacks just
" because the script that started it was re-sourced -- and that old code
" has no way to call the current s:ConvergePreview. Left alone, the first
" switch requested under the new code would stop this job (job_stop()
" itself works regardless of version), but the *old* exit_cb would then
" just clear it without ever reconciling the new desired target, leaving
" the preview stuck until some unrelated event happened to trigger
" reconciliation. Stopping it once, right here where the incompatibility
" is actually detected (inlined, not via s:RequestStop(), which is not
" yet defined at this point in the script), means the very next
" navigation or save starts fresh entirely under the new code path.
if s:migrating_preview_state && s:preview.job isnot v:null && !s:preview.stopping
  let s:preview.stopping = 1
  let s:preview.phase = 'stopping'
  call job_stop(s:preview.job, 'term')
endif
unlet s:migrating_preview_state

" Shared by the tinymist stderr parser below and the reconciler's own
" switch/stop decisions, so every asynchronous trace -- not just tinymist's
" own output -- carries both the desired target and the job's actual entry,
" letting a stale-target trace be told apart from a stale-job one.
function! s:LogPreviewEvent(msg) abort
  " Best-effort only: this is an `abort` function called from other
  " `abort` functions (s:ConvergePreview among them) *before* they issue
  " the actual job_stop()/job_start() -- an unwritable log path or a full
  " state filesystem must never propagate out of here and cut off the
  " caller's own remaining lines, or a stop/start request could silently
  " never be issued at all. See :TypstPreview status for the alternative
  " signal when logging itself is failing.
  try
    call s:EnsureLogDir()
    call writefile([strftime('%Y-%m-%d %H:%M:%S')
          \ . ' gen=' . s:preview.generation
          \ . ' phase=' . s:preview.phase
          \ . ' desired=' . (empty(s:preview.desired_entry) ? '(none)' : s:preview.desired_entry)
          \ . ' entry=' . (empty(s:preview.entry) ? '(none)' : s:preview.entry)
          \ . ' ' . a:msg], g:typst_preview_log_file, 'a')
  catch
  endtry
endfunction

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

  call s:LogPreviewEvent(a:msg)

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

  " Captured before being cleared below: it is what tells an intentional
  " shutdown (TypstPreviewStop/Restart, or the reconciler switching targets)
  " apart from tinymist dying on its own, and only the former should ever
  " reconverge below.
  let l:was_stopping = s:preview.stopping

  if l:was_stopping
    " Only a confirmed exit may ever advertise 'stopped' -- job_stop()
    " itself only requests asynchronous termination, so the request sets
    " 'stopping', not 'stopped', and waits for this callback.
    let s:preview.phase = 'stopped'
    let s:preview.entry = ''
  elseif s:preview.phase !=# 'failed'
    let s:preview.phase = 'failed'
    let s:preview.last_error = 'exited unexpectedly (status ' . a:status . ')'
    echoerr 'Typst preview exited unexpectedly (status ' . a:status . '). See :TypstPreview status.'
  endif

  let s:preview.job = v:null
  let s:preview.stopping = 0

  if l:was_stopping
    " job_stop() only requests termination; the OS reaps the process and
    " this callback fires asynchronously, later. This is the serialization
    " boundary the reconciler relies on: reconverge now against whatever
    " desired_entry navigation has moved to *during* this shutdown --
    " possibly a different file than the one that triggered the stop, or
    " empty if the user has since navigated away from every Typst buffer --
    " rather than replaying a value captured back when the stop began.
    "
    " desired_auto (not a hardcoded 1) carries forward whether that latest
    " desired_entry came from an explicit command or automatic navigation:
    " an explicit :TypstPreview start/restart whose actual start is
    " deferred to this exact continuation (it raced a still-in-flight stop)
    " must still be able to echoerr a validation failure, exactly as if the
    " stop had not still been in flight.
    call s:ConvergePreview(s:preview.desired_auto)
  endif
  " An exit that was NOT requested (tinymist crashed on its own) must not
  " reconverge: desired_entry may still equal the crashed entry, and
  " starting it again immediately would be an uncontrolled crash loop. The
  " 'failed' phase set above stands until an explicit :TypstPreview start
  " or a later qualifying BufEnter/FileType/BufWritePost observation
  " retries it through the normal reconciliation path.
endfunction

function! s:IsTypstBufnr(bufnr) abort
  return getbufvar(a:bufnr, '&filetype') ==# 'typst' && !empty(bufname(a:bufnr))
endfunction

" a:auto: 1 when the call originated from an automatic observation
" (BufEnter/FileType/BufWritePost, or a reconciliation continuation of one
" from s:OnPreviewExit), 0 for a direct :TypstPreview start/restart. A
" config validation failure is real state either way (phase/last_error,
" visible via :TypstPreview status regardless), but only an explicit
" invocation should ever echoerr it -- doing so unconditionally would run
" this inside a BufEnter/FileType autocmd's own dispatch, and an uncaught
" error from an `abort` function there can cut off any *other* plugin's
" autocmd still queued for the same event on this buffer.
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

" Requests asynchronous termination of the owned job, if any, exactly once.
" Both the reconciler and :TypstPreview restart route through this so
" 'stopping' can never be set twice for the same job -- job_stop() itself
" is harmless to call again, but doing so would also re-arm the "stopping"
" phase message/log noise for no reason.
function! s:RequestStop() abort
  if s:preview.job isnot v:null && !s:preview.stopping
    " Route through 'stopping' and let s:OnPreviewExit be the sole place
    " that ever sets 'stopped', regardless of what job_status() currently
    " reads -- job_status() reporting non-'run' does NOT mean exit_cb has
    " already fired for it (that callback is asynchronous and can still be
    " pending); jumping straight to 'stopped' here would leave that pending
    " callback's generation and s:preview.stopping both untouched, so when
    " it later ran, it would read stopping=0 and treat an intentional stop
    " as an unexpected exit, overwriting the correct 'stopped' with 'failed'.
    let s:preview.stopping = 1
    let s:preview.phase = 'stopping'
    call job_stop(s:preview.job, 'term')
  endif
endfunction

" The single boundary every path -- automatic navigation, explicit
" start/stop, and s:OnPreviewExit's post-shutdown reconciliation -- uses to
" make the running job match current intent. desired_entry is the one
" durable fact this reads; nothing here re-derives intent from ambient '%'
" or from a queued command captured earlier.
"
" Do not sleep, poll, or start a timer to guess when a stopped job's port
" is free: s:OnPreviewExit is the sole serialization boundary, and this
" function returns immediately whenever a shutdown is already in flight,
" trusting that exit callback to call back in here once it lands.
function! s:ConvergePreview(auto) abort
  if s:preview.stopping
    return
  endif

  if empty(s:preview.desired_entry)
    if s:preview.job isnot v:null
      call s:LogPreviewEvent('stopping (no desired target)')
      call s:RequestStop()
    elseif s:preview.phase !=# 'stopped'
      let s:preview.phase = 'stopped'
      let s:preview.entry = ''
    endif
    return
  endif

  if s:preview.job isnot v:null
    if s:preview.entry ==# s:preview.desired_entry
      " Already converged: same target, live job, stable PID. Covers every
      " duplicate/re-entry route (explicit start, window/tab re-entry,
      " repeated saves, a redundant FileType firing) without touching the
      " job at all.
      return
    endif
    call s:LogPreviewEvent('switching: stopping ' . s:preview.entry . ' -> ' . s:preview.desired_entry)
    call s:RequestStop()
    return
  endif

  if filereadable(s:preview.desired_entry)
    call s:StartForEntry(s:preview.desired_entry, a:auto)
  elseif s:preview.phase !=# 'stopped'
    " A new, not-yet-saved Typst buffer is the desired target: remain
    " stopped until its first write makes it readable, rather than trying
    " and failing to start tinymist against a nonexistent path.
    let s:preview.phase = 'stopped'
  endif
endfunction

function! s:SetDesiredEntry(target, auto) abort
  let s:preview.desired_entry = a:target
  " Remembered alongside the target itself so a later asynchronous
  " continuation (s:OnPreviewExit, once an in-flight stop confirms) knows
  " whether *this* desired_entry came from an explicit command or
  " automatic navigation, even if the actual start happens well after this
  " call returns.
  let s:preview.desired_auto = a:auto
  call s:ConvergePreview(a:auto)
endfunction

" The tri-state classifier (D-3): a named ordinary buffer with filetype
" typst becomes the desired target; any other named ordinary buffer clears
" it; an unnamed buffer or one with a non-empty 'buftype' (terminal,
" quickfix, help, and the nofile buffers NERDTree/Fugitive/FZF use) is
" neither -- it is a navigation/inspection surface, not a replacement file,
" so the current target is left untouched. This is also what keeps
" :TypstPreview logs' own terminal buffer from stopping the very preview
" its stream belongs to.
"
" a:is_navigation: 1 for BufEnter/FileType (a real arrival at this buffer,
" which is what ":stop ... until ... a later leave/re-enter navigation
" event" means -- see TypstPreviewStop), 0 for BufWritePost (a mere save
" of the buffer you never left). Without this distinction, saving again in
" a buffer you explicitly stopped would resurrect the preview merely
" because BufWritePost re-derives the same desired target BufEnter would
" have -- the write itself is not navigation, so it must not undo an
" explicit stop the way leaving and coming back does.
function! s:ObserveBuffer(bufnr, auto, is_navigation) abort
  if a:bufnr != bufnr('%')
    " Guards the FileType observer in particular: filetype can be set on a
    " buffer that is not the current one (a background read, another
    " plugin loading a .typ file to inspect it), and that must never steal
    " the lease from whatever buffer the user is actually looking at.
    return
  endif

  if getbufvar(a:bufnr, '&buftype') !=# '' || empty(bufname(a:bufnr))
    return
  endif

  if getbufvar(a:bufnr, '&filetype') !=# 'typst'
    call s:SetDesiredEntry('', a:auto)
    return
  endif

  if a:is_navigation
    call setbufvar(a:bufnr, 'typst_preview_explicit_stop', 0)
  elseif getbufvar(a:bufnr, 'typst_preview_explicit_stop', 0)
    return
  endif

  call s:SetDesiredEntry(fnamemodify(bufname(a:bufnr), ':p'), a:auto)
endfunction

function! TypstPreviewStart(...) abort
  let l:auto = get(a:, 1, 0)
  let l:bufnr = bufnr('%')

  if !s:IsTypstBufnr(l:bufnr)
    if !l:auto
      echoerr 'Not a Typst buffer.'
    endif
    return
  endif

  let l:entry = fnamemodify(bufname(l:bufnr), ':p')

  if !filereadable(l:entry)
    if l:auto
      return
    endif
    echoerr 'Save this buffer before starting the preview (Tinymist previews a saved file, not an unsaved buffer).'
    return
  endif

  if !l:auto && s:preview.job isnot v:null && s:preview.entry ==# l:entry
        \ && s:preview.phase =~# '^\(starting\|listening\)$'
    echom 'Typst preview already running for ' . l:entry . ' at ' . s:preview.public_url
  endif

  " An explicit start always supersedes any earlier explicit stop recorded
  " for this buffer -- otherwise a save right after this start would still
  " see the stale marker and refuse to reconcile (see s:ObserveBuffer).
  call setbufvar(l:bufnr, 'typst_preview_explicit_stop', 0)
  call s:SetDesiredEntry(l:entry, l:auto)
endfunction

function! TypstPreviewStop() abort
  " Marks whichever buffer actually owns the entry being stopped -- not
  " necessarily bufnr('%'): :stop is not restricted to being invoked from
  " the previewed buffer itself. This is what makes "stays stopped until
  " :start or a later leave/re-enter" (see s:ObserveBuffer) survive a
  " plain :w in that buffer instead of being undone by the very next save.
  let l:target = !empty(s:preview.desired_entry) ? s:preview.desired_entry : s:preview.entry
  if !empty(l:target)
    let l:target_bufnr = bufnr(l:target)
    if l:target_bufnr >= 0
      call setbufvar(l:target_bufnr, 'typst_preview_explicit_stop', 1)
    endif
  endif
  call s:SetDesiredEntry('', 0)
endfunction

function! TypstPreviewRestart() abort
  let l:bufnr = bufnr('%')

  if !s:IsTypstBufnr(l:bufnr)
    echoerr 'Not a Typst buffer.'
    return
  endif

  let l:entry = fnamemodify(bufname(l:bufnr), ':p')

  if !filereadable(l:entry)
    echoerr 'Save this buffer before restarting the preview (Tinymist previews a saved file, not an unsaved buffer).'
    return
  endif

  " Set directly rather than through s:SetDesiredEntry: that would converge
  " straight into s:ConvergePreview's "already owns desired" no-op when
  " restarting the file already running, but restart means an explicit
  " stop+start even for that case. desired_auto is still recorded (0, this
  " is always explicit) so that if the actual start ends up deferred to
  " s:OnPreviewExit's continuation -- restarting while the same or a
  " different entry is still mid-shutdown -- a validation failure there
  " still reports the way an explicit command promises.
  let s:preview.desired_entry = l:entry
  let s:preview.desired_auto = 0
  call setbufvar(l:bufnr, 'typst_preview_explicit_stop', 0)

  if s:preview.job isnot v:null
    call s:RequestStop()
  else
    call s:ConvergePreview(0)
  endif
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
  if s:preview.phase ==# 'stopped' && empty(s:preview.desired_entry)
    echom 'Typst preview: stopped'
    return
  endif

  " desired and entry legitimately differ while switching, stopping,
  " waiting for a new buffer's first save, or after a failure -- both are
  " shown rather than collapsed into one field.
  let l:job_status = s:preview.job is v:null ? 'no-job' : job_status(s:preview.job)
  echom 'Typst preview: ' . s:ReconciledPhase()
        \ . ' | job=' . l:job_status
        \ . ' | desired=' . (empty(s:preview.desired_entry) ? '(none)' : s:preview.desired_entry)
        \ . ' | entry=' . (empty(s:preview.entry) ? '(none)' : s:preview.entry)
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
        \ . '  stop     stop the owned preview job; stays stopped in this buffer until :start' . "\n"
        \ . '           or the next qualifying navigation' . "\n"
        \ . '  restart  stop then start (recovery)' . "\n"
        \ . '  status   phase, job state, desired vs. actual entrypoint, bind/public URL, last error' . "\n"
        \ . '  open     echo the public preview URL (never opens a local browser)' . "\n"
        \ . '  logs     open a terminal following tinymist''s persisted stderr live' . "\n"
        \ . '  help     this message (also -h / --help / bare :TypstPreview)' . "\n"
        \ . '' . "\n"
        \ . 'Automatic: entering a saved ordinary Typst file makes it the preview target;' . "\n"
        \ . '  entering another ordinary file stops the preview; entering a transient surface' . "\n"
        \ . '  (this logs terminal, help, a file picker, Fugitive, quickfix, ...) preserves' . "\n"
        \ . '  the current target; a new unsaved Typst buffer starts after its first save.' . "\n"
        \ . '' . "\n"
        \ . 'Current: phase=' . s:ReconciledPhase()
        \ . ' desired=' . (empty(s:preview.desired_entry) ? '(none)' : s:preview.desired_entry)
        \ . ' entry=' . (empty(s:preview.entry) ? '(none)' : s:preview.entry) . "\n"
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
  " explicitly, rather than letting s:ObserveBuffer re-derive "the" buffer
  " from ambient '%' state. BufEnter is the primary ownership boundary --
  " it observes the destination buffer directly, unlike a BufLeave-based
  " design, which can only guess where navigation is headed. FileType is
  " kept alongside it purely as an initial-load/detection-ordering
  " fallback (s:ObserveBuffer's own bufnr('%') check keeps a background
  " buffer's FileType event from stealing the lease); BufWritePost is what
  " activates a brand-new Typst buffer once its first save makes it
  " readable, and is a no-op for every save after that. BufEnter/FileType
  " pass is_navigation=1 (a real arrival, which may resume a buffer an
  " explicit :stop left stopped); BufWritePost passes 0 (a mere save must
  " not undo that same explicit stop).
  autocmd BufEnter * call s:ObserveBuffer(str2nr(expand('<abuf>')), 1, 1)
  autocmd FileType typst call s:ObserveBuffer(str2nr(expand('<abuf>')), 1, 1)
  autocmd BufWritePost *.typ call s:ObserveBuffer(str2nr(expand('<abuf>')), 1, 0)
  " Deliberately no BufLeave handler here: a departure autocmd cannot see
  " the destination buffer, only that the current one is being left, so it
  " cannot tell a real replacement file apart from a transient surface
  " (:TypstPreview logs, a picker, help) without also duplicating the
  " classification BufEnter already does on arrival.
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
