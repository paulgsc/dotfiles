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
   
    " FZF Configuration - ignore build files and generated content
    " let $FZF_DEFAULT_COMMAND = 'fd --type f --hidden --follow --exclude .git --exclude node_modules --exclude target --exclude dist --exclude build --exclude .next --exclude coverage --exclude __pycache__ --exclude .pytest_cache --exclude .venv --exclude venv --exclude .env'
    " let g:fzf_files_options = '--preview "bat --color=always --style=header,grid --line-range :300 {}"'
    
    " Alternative if you don't have fd, use find with exclusions
    let $FZF_DEFAULT_COMMAND = 'find . -type f ! -path "*/node_modules/*" ! -path "*/target/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.git/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/__pycache__/*"'

    " Rust settings
    let g:rustfmt_autosave = 1
    
    " ALE Configuration
    let g:ale_fix_on_save = 1
    let g:ale_linters = {
      \    'rust': ['analyzer', 'cargo', 'clippy'],
      \    'typescript': ['tsserver', 'eslint', 'tsc'],
      \    'typescriptreact': ['tsserver', 'eslint', 'tsc'],
      \    'javascript': ['eslint'],
      \    'json': ['eslint'],
      \    'nix': ['nix'],
      \    'jsonnet': ['jsonnet'],
      \    'slint': ['languageserver']
      \}
    let g:ale_fixers = {
      \     'rust': ['rustfmt'],
      \     'typescript': ['eslint', 'prettier'],
      \     'typescriptreact': ['eslint', 'prettier'],
      \     'json': ['prettier'],
      \     'css': ['prettier'],
      \     'yaml': ['prettier'],
      \     'nix': ['alejandra'],
      \     'jsonnet': ['jsonnetfmt']
      \}
    let g:ale_rust_cargo_use_clippy = 1
    let g:ale_virtualtext_cursor = 1
    let g:ale_set_highlights = 0

    " Slint LSP Configuration
    let g:ale_lanuageserver = {
      \   'slint-lsp': {
      \       'command': 'slint-lsp',
      \       'language': 'slint',
      \       'project_root': '.',
      \   },
      \}

    " Manual Slint syntax highlighting
     augroup slint_syntax
         autocmd!
         autocmd BufNewFile,BufRead *.slint setfiletype slint
         autocmd FileType slint set commentstring=//%s
     augroup END

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

    # Grafana
    vim-jsonnet

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

