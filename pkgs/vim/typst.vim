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
      \ 'pending_restart': 0,
      \ }

function! s:PreviewAddress() abort
  return g:typst_preview_host . ':' . g:typst_preview_port
endfunction

" Tinymist logs exclusively to stderr, not stdout (verified against the
" tinymist v0.14.18 binary: stdout is empty for the whole process
" lifetime). Readiness and failure must therefore be read from err_cb, not
" out_cb.
function! s:OnPreviewErr(channel, msg) abort
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
  " callback fires asynchronously, later. A restart that started the
  " replacement immediately after calling stop -- rather than waiting for
  " this callback -- would let the old job's belated exit stomp the new
  " job's state (or lose the port race against it). So :TypstPreviewRestart
  " defers its start to here, once the old process is confirmed gone.
  if s:preview.pending_restart
    let s:preview.pending_restart = 0
    call TypstPreviewStart()
  endif
endfunction

function! s:IsTypstBuffer() abort
  return &filetype ==# 'typst' && !empty(expand('%:p'))
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

  if s:preview.status =~# '^\(starting\|listening\)$'
    if s:preview.entry ==# l:entry
      echom 'Typst preview already running for ' . l:entry . ' at http://' . s:preview.address . '/'
      return
    endif

    echoerr 'Typst preview is already running for ' . s:preview.entry
          \ . '. Run :TypstPreviewStop first to switch entrypoints.'
    return
  endif

  let s:preview.entry = l:entry
  let s:preview.address = s:PreviewAddress()
  let s:preview.status = 'starting'
  let s:preview.last_error = ''
  let s:preview.stopping = 0

  let s:preview.job = job_start(
        \ ['tinymist', 'preview', '--host', s:preview.address, '--no-open', l:entry],
        \ {
        \   'err_cb': function('s:OnPreviewErr'),
        \   'exit_cb': function('s:OnPreviewExit'),
        \ })
endfunction

function! TypstPreviewStop() abort
  let s:preview.pending_restart = 0
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
  if s:preview.job isnot v:null && job_status(s:preview.job) ==# 'run'
    call TypstPreviewStop()
    let s:preview.pending_restart = 1
  else
    call TypstPreviewStart()
  endif
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
    let l:winid = bufwinid(a:bufnr)
    if l:winid != -1
      call win_execute(l:winid, 'update')
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

imap <expr> <C-j> vsnip#expandable()  ? '<Plug>(vsnip-expand)'         : '<C-j>'
imap <expr> <C-l> vsnip#jumpable(1)   ? '<Plug>(vsnip-jump-next)'      : '<C-l>'
smap <expr> <C-j> vsnip#expandable()  ? '<Plug>(vsnip-expand)'         : '<C-j>'
smap <expr> <C-l> vsnip#jumpable(1)   ? '<Plug>(vsnip-jump-next)'      : '<C-l>'
imap <expr> <C-h> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)'      : '<C-h>'
smap <expr> <C-h> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)'      : '<C-h>'
