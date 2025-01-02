" General Settings
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set softtabstop=4
set expandtab
set autoindent
set smartindent
set backspace=indent,eol,start

" Highlight search results
set hlsearch

" When searching try to be smart about cases
set smartcase

" Auto-format on save
let g:rustfmt_autosave = 1

" Fix files automatically on save
let g:ale_fix_on_save = 1

let g:ale_linters = {
           \    'rust': ['analyzer', 'cargo', 'clippy'],
           \    'typescript': ['tserver', 'eslint', 'tsc'],
           \    'typescriptreact': ['tserver', 'eslint', 'tsc'],
           \    'javascript': ['eslint'],
           \    'json': ['eslint']
\}
let g:ale_fixers = {
          \     'rust': ['rustfmt'],
          \     'typescript': ['eslint', 'prettier'],
          \     'typescriptreact': ['eslint', 'prettier'],
          \     'json': ['prettier']
\}
let g:ale_rust_cargo_use_clippy = 1

" Status line
""""""""""""""""""""""""

" Show errors in statusline
let g:ale_virtualtext_cursor = 1
set laststatus=2

" Format the status line
function! HasPaste()
    if &paste
        return 'PASTE MODE  '
    endif
    return ''
endfunction


" Format the status line
set statusline=\ %{HasPaste()}%F%m%r%h\ %w\ \ CWD:\ %r%{getcwd()}%h\ \ \ Line:\ %l\ \ Column:\ %c

 " Automatic SQL formatting for migration files
 augroup sql_migrations
    autocmd!
    " Match both up and down migration files
    autocmd BufNewFile,BufRead *_*.up.sql,*_*.down.sql setfiletype sql

    " Option 1: Using sql-formatter (recommended for migrations)
    autocmd BufWritePre *_*.up.sql,*_*.down.sql :%!sql-formatter --language sqlite

    " Option 2: Using pgformatter
    " autocmd BufWritePre *_*.up.sql,*_*.down.sql :%!pg_format

    " Option 3: Using sqlformat
    " autocmd BufWritePre *_*.up.sql,*_*.down.sql :%!sqlformat --reindent --keywords upper --identifiers lower -
augroup END


" Install Plugins Setup

"""""""""""""""""""""""""""""""""
"        BEGIN PLUGIN INSTALL
"""""""""""""""""""""""""""""""""

call plug#begin('~/.vim/plugged')

"Rust Lang Plugin
Plug 'rust-lang/rust.vim'

"Linting and fixing
Plug 'dense-analysis/ale'

"Fugitive Vim Github Wrapper
Plug 'tpope/vim-fugitive'

"A command-line fuzzy finder
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

"A Vim plugin for Prettier
Plug 'prettier/vim-prettier', { 'do': 'pnpm install' }

"File Tree Explorer
Plug 'preservim/nerdtree'

""""""""""""""""""""""""""""""""""""""""""""""""""""
        "       END PLUGIN INSTALL
"""""""""""""""""""""""""""""""""""""""""""""""""""""
call plug#end()


" Use ctrl-p for files
nnoremap <C-p> :Files<CR>
" Use ctrl-f for searching within files
nnoremap <C-f> :Rg<CR>
" Use ctrl-b for buffers
nnoremap <C-b> :Buffers<CR>





