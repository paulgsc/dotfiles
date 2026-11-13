" --- Rust scratchpad (github:paulgsc/scratch) ---
" `scratch` (tmux: prefix S) opens vim on main.rs in a throwaway tmpfs dir
" that holds a `.scratch` marker and a generated rust-project.json.  For a .rs
" file in such a dir:
"   - ALE runs rust-analyzer against that rust-project.json (no Cargo.toml)
"     and `scratch check -` on the buffer: rustc + clippy, inline as you type;
"   - <leader>r (or :make) compiles, lints and runs the file through
"     `scratch run`, errors into the quickfix list, program output below them.
" rust-analyzer, rustc and clippy come from the dev shell's PATH, never from
" the system or home packages: outside `nix develop github:paulgsc/scratch`
" none of this switches on.  Sourced from pkgs/vim/default.nix.

" rustc + clippy on the buffer's text, read from stdin.  rust-analyzer's own
" check on save cannot do this job under ALE: rust-analyzer pushes those
" results, ALE also pulls rust-analyzer's native diagnostics, and whichever
" arrives last replaces the other.  As a separate linter they sit side by side.
" Defined on first use: ALE is not on 'runtimepath' yet while vimrc runs.
function! s:DefineLinter() abort
  if exists('s:linter_defined')
    return
  endif
  let s:linter_defined = 1
  call ale#linter#Define('rust', {
  \   'name': 'scratch',
  \   'executable': 'scratch',
  \   'command': 'scratch check -',
  \   'callback': 'ale#handlers#rust#HandleRustErrors',
  \   'output_stream': 'stderr',
  \})
endfunction

function! s:InScratch() abort
  return executable('scratch') && filereadable(expand('%:p:h') . '/.scratch')
endfunction

function! s:ScratchSetup() abort
  if !s:InScratch()
    return
  endif
  call s:DefineLinter()
  " rustc's errorformat (rust.vim), then our own make: the whole file
  " through rustc + clippy, run if it compiles.
  compiler rustc
  let &l:makeprg = 'scratch run ' . shellescape(expand('%:p'))
  " ALE's cargo linter needs a Cargo.toml; these two do not.
  let b:ale_linters = ['analyzer', 'scratch']
  " Not the global rust-analyzer config: its check on save is `cargo`.
  let b:ale_rust_analyzer_config = {}
  " Lint now, not at the first edit (g:ale_lint_on_enter is off), so
  " rust-analyzer is already up by the first save.
  let l:buf = bufnr('')
  call timer_start(0, {-> bufexists(l:buf) ? ale#Queue(0, '', l:buf) : 0})
  nnoremap <buffer> <silent> <leader>r :silent make! <Bar> redraw! <Bar> botright copen<CR>
endfunction

augroup rust_scratchpad
  autocmd!
  autocmd BufNewFile,BufRead *.rs call s:ScratchSetup()
augroup END
