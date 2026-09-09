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
  " ale#path#FindNearestDirectory() returns the match with a trailing slash
  " (".../.git/"), so a single ':h' only strips that slash and still lands
  " on the .git directory itself -- it takes two to reach the repo root.
  " Confirmed directly: fnamemodify('/x/.git/', ':h') == '/x/.git'.
  let l:git_dir = ale#path#FindNearestDirectory(a:buffer, '.git')

  if !empty(l:git_dir)
    return fnamemodify(l:git_dir, ':h:h')
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
let g:typst_preview_host = get(g:, 'typst_preview_host', 'nixos.local')
let g:typst_preview_port = get(g:, 'typst_preview_port', 3141)

let s:preview = {
      \ 'job': v:null,
      \ 'entry': '',
      \ 'address': '',
      \ 'status': 'stopped',
      \ 'last_error': '',
      \ 'stopping': 0,
      \ 'pending_start': '',
      \ }

function! s:PreviewAddress() abort
  return g:typst_preview_host . ':' . g:typst_preview_port
endfunction

" Tinymist logs exclusively to stderr, not stdout (verified against the
" tinymist v0.14.18 binary: stdout is empty for the whole process
" lifetime). Readiness and failure must therefore be read from err_cb, not
" out_cb.
function! s:OnPreviewErr(channel, msg) abort
  " A job's stderr can be buffered and delivered after we've already
  " decided it's gone -- job_stop() only requests termination, and Vim
  " may still flush queued channel output afterward, possibly after a
  " replacement job has already started. Identify the message by the
  " channel it actually came from rather than trusting "a job is
  " currently tracked": a stale message from a dead job must not
  " overwrite state that a live one (or the intentional stopped/starting
  " state) already owns.
  if s:preview.job is v:null || job_getchannel(s:preview.job) != a:channel
    return
  endif

  let s:preview.last_error = a:msg

  if a:msg =~# 'Static file server listening on'
    let s:preview.status = 'listening'
    echom 'Typst preview: listening on http://' . s:preview.address . '/'
  elseif a:msg =~# 'Address already in use' || a:msg =~# 'panicked at'
    let s:preview.status = 'failed'
    echoerr 'Typst preview failed: ' . a:msg
  endif
endfunction

function! s:OnPreviewExit(job, status) abort
  if !s:preview.stopping && s:preview.status !=# 'failed'
    let s:preview.status = 'failed'
    echoerr 'Typst preview exited unexpectedly (status ' . a:status . '). See :TypstPreviewStatus.'
  endif
  let s:preview.job = v:null
  let s:preview.stopping = 0

  " job_stop() only requests termination; the OS reaps the process and this
  " callback fires asynchronously, later. Any start requested while a stop
  " was still in flight -- via :TypstPreviewRestart, or plain :TypstPreviewStop
  " immediately followed by :TypstPreviewStart -- gets queued in
  " pending_start (by TypstPreviewStart itself, see below) instead of
  " racing the old job's belated exit. The entrypoint is captured at
  " request time, not re-resolved from "whatever buffer is current" once
  " this callback finally runs.
  if !empty(s:preview.pending_start)
    let l:target = s:preview.pending_start
    let s:preview.pending_start = ''
    call s:StartForEntry(l:target)
  endif
endfunction

function! s:IsTypstBuffer() abort
  return &filetype ==# 'typst' && !empty(expand('%:p'))
endfunction

function! s:StartForEntry(entry) abort
  let s:preview.entry = a:entry
  let s:preview.address = s:PreviewAddress()
  let s:preview.status = 'starting'
  let s:preview.last_error = ''

  let s:preview.job = job_start(
        \ ['tinymist', 'preview', '--host', s:preview.address, '--no-open', a:entry],
        \ {
        \   'err_cb': function('s:OnPreviewErr'),
        \   'exit_cb': function('s:OnPreviewExit'),
        \ })
endfunction

function! TypstPreviewStart() abort
  if !s:IsTypstBuffer()
    echoerr 'Not a Typst buffer.'
    return
  endif

  let l:entry = expand('%:p')

  if !filereadable(l:entry)
    echoerr 'Save this buffer before starting the preview (Tinymist previews a saved file, not an unsaved buffer).'
    return
  endif

  if s:preview.stopping
    " A previous job is still exiting (job_stop() only requests
    " termination, asynchronously). Queue this entry rather than racing
    " the old job's belated exit_cb for s:preview state and the port;
    " s:OnPreviewExit starts it once that job is confirmed gone.
    let s:preview.pending_start = l:entry
    return
  endif

  if s:preview.status =~# '^\(starting\|listening\)$'
    if s:preview.entry ==# l:entry
      echom 'Typst preview already running for ' . l:entry . ' at http://' . s:preview.address . '/'
      return
    endif

    echoerr 'Typst preview is already running for ' . s:preview.entry
          \ . '. Run :TypstPreviewStop first to switch entrypoints.'
    return
  endif

  call s:StartForEntry(l:entry)
endfunction

function! TypstPreviewStop() abort
  let s:preview.pending_start = ''
  if s:preview.job isnot v:null && job_status(s:preview.job) ==# 'run'
    let s:preview.stopping = 1
    call job_stop(s:preview.job, 'term')
  endif
  let s:preview.job = v:null
  let s:preview.entry = ''
  let s:preview.address = ''
  let s:preview.status = 'stopped'
endfunction

function! TypstPreviewRestart() abort
  call TypstPreviewStop()
  call TypstPreviewStart()
endfunction

function! TypstPreviewStatus() abort
  if s:preview.status ==# 'stopped'
    echom 'Typst preview: stopped'
    return
  endif

  echom 'Typst preview: ' . s:preview.status
        \ . ' | entry=' . s:preview.entry
        \ . ' | address=' . s:preview.address
        \ . (empty(s:preview.last_error) ? '' : ' | last=' . s:preview.last_error)
endfunction

function! TypstPreviewOpen() abort
  if s:preview.status !=# 'listening'
    echoerr 'Typst preview is not listening yet. Run :TypstPreviewStart, then :TypstPreviewStatus.'
    return
  endif

  echom 'http://' . s:preview.address . '/'
endfunction

command! TypstPreviewStart call TypstPreviewStart()
command! TypstPreviewStop call TypstPreviewStop()
command! TypstPreviewRestart call TypstPreviewRestart()
command! TypstPreviewStatus call TypstPreviewStatus()
command! TypstPreviewOpen call TypstPreviewOpen()

augroup typst_preview_lifecycle
  autocmd!
  autocmd FileType typst call TypstPreviewStart()
  autocmd VimLeavePre * call TypstPreviewStop()
augroup END

" --- Publication policy: manual save by default -----------------------------
" Tinymist's own watcher means the preview needs nothing from Vim beyond an
" occasional `:w`. Autosave is opt-in per buffer, never a blanket policy for
" every `.typ` file (a resumed, half-written document should not be
" silently rewritten because live-write was left on in a previous session).
let g:typst_live_write_quiet_ms = get(g:, 'typst_live_write_quiet_ms', 700)

" Bound to the buffer that scheduled it (via the Funcref partial below), not
" read from "the current buffer" -- a timer callback runs in whatever
" buffer/window is current when it fires, which is not necessarily the one
" that was being edited 700ms ago. Acting on b:/&modified/:update directly
" here would silently check or save the wrong buffer if the user switched
" away during the quiet interval.
function! s:LiveWriteTick(bufnr, timer) abort
  if !bufloaded(a:bufnr) || !getbufvar(a:bufnr, 'typst_live_write', 0)
    return
  endif

  let l:modified = getbufvar(a:bufnr, '&modified')
  let l:readonly = getbufvar(a:bufnr, '&readonly')
  let l:buftype = getbufvar(a:bufnr, '&buftype')

  if l:modified && !l:readonly && l:buftype ==# '' && !empty(bufname(a:bufnr))
    " bufwinid() only searches the current tab page; win_findbuf() searches
    " all of them, so a buffer left open in another tab during the quiet
    " interval still gets its scheduled write instead of being silently
    " skipped.
    let l:winid = get(win_findbuf(a:bufnr), 0, -1)
    if l:winid != -1
      call win_execute(l:winid, 'update')
    else
      " Loaded but displayed nowhere at all (e.g. :hide'd, or 'hidden' is
      " set and the user moved on without closing it) -- win_findbuf()
      " can't find a window to run :update in because there isn't one.
      " Borrow the current window just long enough to write it, with
      " :noautocmd so this doesn't fire FileType/Buf-Enter/Leave for
      " either buffer or trigger this same live-write machinery
      " recursively, and restore the original buffer afterward either way.
      "
      " The switch itself needs `hide`: with the default 'nohidden', a
      " plain `:buffer` refuses to abandon the *current* window's buffer
      " if that one is also modified (E37), which would silently drop
      " the write we came here to do. `:hide {cmd}` runs {cmd} with
      " 'hidden' in effect just for that command, so switching away
      " (either direction) never requires saving anything.
      let l:original = bufnr('%')
      if l:original ==# a:bufnr
        update
      else
        try
          " The modifiers must be part of the string :execute runs, not
          " prefixed on :execute itself -- `noautocmd hide execute '...'`
          " does not propagate either modifier into the command the
          " string builds and still throws E37 here; confirmed directly.
          execute 'noautocmd hide buffer' a:bufnr
          update
        finally
          execute 'noautocmd hide buffer' l:original
        endtry
      endif
    endif
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

function! TypstLiveWriteToggle() abort
  if !s:IsTypstBuffer()
    echoerr 'Not a Typst buffer.'
    return
  endif

  let b:typst_live_write = !get(b:, 'typst_live_write', 0)
  echom 'Typst live-write: ' . (b:typst_live_write ? 'on (autosaves after a quiet pause)' : 'off (manual-save)')
endfunction

command! TypstLiveWriteToggle call TypstLiveWriteToggle()

augroup typst_live_write
  autocmd!
  autocmd TextChanged,TextChangedI *.typ call s:LiveWriteSchedule()
  autocmd BufUnload,BufDelete *.typ
        \ if exists('b:typst_live_write_timer') |
        \   call timer_stop(b:typst_live_write_timer) |
        \ endif
augroup END

" --- Keyboard grammar: structural snippets only -----------------------------
" Typst's own math syntax is already ASCII (`sqrt`, `sum`, `integral`, `_`,
" `^`, named symbols via completion) -- snippets exist only for the
" repetitive *structure* around that syntax (bounds, jump points), not as a
" LaTeX-compatibility layer or a stand-in for completion.
let g:vsnip_snippet_dir = expand('<sfile>:h') . '/snippets'

" <C-j> does both expand and next-placeholder (matching docs/typst-math-
" workflow.md): try expand first, then forward-jump, else fall through to
" a literal <C-j>. Previously only expand was wired to it and forward-jump
" lived solely on the undocumented <C-l>, so <C-j> silently inserted a
" newline mid-snippet instead of advancing.
imap <expr> <C-j> vsnip#expandable()  ? '<Plug>(vsnip-expand)'    : vsnip#jumpable(1)  ? '<Plug>(vsnip-jump-next)' : '<C-j>'
smap <expr> <C-j> vsnip#expandable()  ? '<Plug>(vsnip-expand)'    : vsnip#jumpable(1)  ? '<Plug>(vsnip-jump-next)' : '<C-j>'
imap <expr> <C-h> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)' : '<C-h>'
smap <expr> <C-h> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)' : '<C-h>'
