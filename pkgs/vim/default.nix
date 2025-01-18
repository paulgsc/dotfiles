{ pkgs }:

let
  customRC = ''
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
    set hlsearch
    set smartcase
    set cursorline
    syntax on
    "set signcolumn=yes
    
    " Color scheme
    "colorscheme ondedark
    
    " Rust settings
    let g:rustfmt_autosave = 1
    
    " ALE Configuration
    let g:ale_fix_on_save = 1
    let g:ale_linters = {
      \    'rust': ['analyzer', 'cargo', 'clippy'],
      \    'typescript': ['tsserver', 'eslint', 'tsc'],
      \    'typescriptreact': ['tsserver', 'eslint', 'tsc'],
      \    'javascript': ['eslint'],
      \    'json': ['eslint']
      \}
    let g:ale_fixers = {
      \     'rust': ['rustfmt'],
      \     'typescript': ['eslint', 'prettier'],
      \     'typescriptreact': ['eslint', 'prettier'],
      \     'json': ['prettier']
      \     'css': ['prettier']
      \}
    let g:ale_rust_cargo_use_clippy = 1
    let g:ale_virtualtext_cursor = 1
    
    " Status line configuration
    set laststatus=2
    function! HasPaste()
        if &paste
            return 'PASTE MODE  '
        endif
        return 
    endfunction
    set statusline=\ %{HasPaste()}%F%m%r%h\ %w\ \ CWD:\ %r%{getcwd()}%h\ \ \ Line:\ %l\ \ Column:\ %c
    
    " SQL formatting configuration
    augroup sql_migrations
        autocmd!
        autocmd BufNewFile,BufRead *.up.sql,***.down.sql setfiletype sql
        autocmd BufWritePre *.up.sql,***.down.sql :%!sql-formatter --language sqlite
    augroup END
    
    " Key mappings
    nnoremap <C-p> :Files<CR>
    nnoremap <C-f> :Rg<CR>
    nnoremap <C-b> :Buffers<CR>
  '';

  plugins = with pkgs.vimPlugins; [
    # Your required plugins
    rust-vim
    ale
    vim-fugitive
    fzf-vim
    vim-prettier
    nerdtree
    # Additional dependencies
    # fzf
    vim-sleuth
    # onedark-vim
    
  ];

in pkgs.vim_configurable.customize {
  name = "vim";
  vimrcConfig = {
    customRC = customRC;
    packages.myVimPackage = {
      start = plugins;
      opt = [];
    };
  };
}

