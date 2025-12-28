{pkgs}: let
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
    " highlight CursorLine ctermbg=236 guibg=#2c2c2c
    set termguicolors
    set background=dark
    syntax on
    "set signcolumn=yes

    " Color scheme
    " colorscheme onedark
    " Options: 'hard', 'medium' (default), 'soft'
    let g:gruvbox_material_background = 'medium'

    " Options: 'material', 'mix', 'original'
    let g:gruvbox_material_palette = 'material'

    " Better line highlighting
    let g:gruvbox_material_cursor = 'auto'
    let g:gruvbox_material_better_performance = 1

    colorscheme gruvbox-material

    " --- Lightline Integration ---
    " This ensures your status bar matches the theme
    let g:lightline = {'colorscheme': 'gruvbox_material'}

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
      \    'rust': ['analyzer'],
      \    'typescript': ['tsserver', 'eslint', 'tsc'],
      \    'typescriptreact': ['tsserver', 'eslint', 'tsc'],
      \    'javascript': ['eslint'],
      \    'json': ['eslint'],
      \    'nix': ['nix'],
      \    'jsonnet': ['jsonnet'],
      \    'yaml': ['yamllint'],
      \    'slint': ['slint_lsp']
      \}
    let g:ale_fixers = {
      \     'rust': ['rustfmt'],
      \     'typescript': ['eslint', 'prettier'],
      \     'typescriptreact': ['eslint', 'prettier'],
      \     'javascript': ['prettier'],
      \     'javascriptreact': ['prettier'],
      \     'json': ['prettier'],
      \     'jsonc': ['prettier'],
      \     'css': ['prettier'],
      \     'html': ['prettier'],
      \     'yaml': ['yamlfmt'],
      \     'markdown': ['prettier'],
      \     'mdx': ['prettier'],
      \     'nix': ['alejandra'],
      \     'slint': ['trim_whitespace', 'remove_trailing_lines'],
      \     'jsonnet': ['jsonnetfmt']
      \}

    let g:ale_rust_analyzer_config = {
    \   'rust-analyzer': {
    \     'checkOnSave': {
    \       'command': 'clippy',
    \     },
    \   },
    \ }
    let g:ale_rust_cargo_use_clippy = 1
    let g:ale_virtualtext_cursor = 1
    let g:ale_set_highlights = 0
    let g:ale_lint_on_text_changed = 'always'
    let g:ale_lint_delay = 1000 " Wait 1000ms after typing stops
    let g:ale_lint_on_insert_leave = 1
    let g:ale_command_wrapper = 'nice -n 15'

    " Slint LSP Configuration
    let g:ale_lsp_servers = {
      \   'slint-lsp': {
      \       'command': 'slint-lsp',
      \       'language': 'slint',
      \       'project_root': '.',
      \   },
      \}


    " Slint syntax highlighting and file type detection
    augroup slint_syntax
        autocmd!
        autocmd BufNewFile,BufRead *.slint setfiletype slint
        autocmd FileType slint set commentstring=//%s
        " Add basic Slint syntax highlighting
        autocmd FileType slint syntax match slintKeyword /\<\(component\|property\|callback\|signal\|animate\|states\|transitions\|if\|for\|in\|import\|export\|struct\|enum\)\>/
        autocmd FileType slint syntax match slintType /\<\(int\|float\|string\|bool\|color\|brush\|image\|length\|physical_length\|duration\|angle\|relative_font_size\)\>/
        autocmd FileType slint syntax match slintComment /\/\/.*$/
        autocmd FileType slint syntax region slintBlockComment start="\/\*" end="\*\/"
        autocmd FileType slint syntax region slintString start='"' end='"'
        autocmd FileType slint highlight link slintKeyword Keyword
        autocmd FileType slint highlight link slintType Type
        autocmd FileType slint highlight link slintComment Comment
        autocmd FileType slint highlight link slintBlockComment Comment
        autocmd FileType slint highlight link slintString String
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

    " Hexokinase Configuration (alternative colorizer)
    let g:Hexokinase_highlighters = ['backgroundfull']
    let g:Hexokinase_optInPatterns = [
    \     'full_hex',
    \     'triple_hex',
    \     'rgb',
    \     'rgba',
    \     'hsl',
    \     'hsla',
    \     'colour_names'
    \ ]

    " Auto-enable Hexokinase for relevant file types
    augroup hexokinase_config
        autocmd!
        autocmd FileType css,scss,sass,html,javascript,typescript,vim,slint HexokinaseToggle
    augroup END

    " Manual toggle commands for colorizers
    nnoremap <leader>ch :HexokinaseToggle<CR>
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

    # Color highlighting plugins
    vim-hexokinase
    # Line highlighting
    lightline-vim
    onedark-vim
    gruvbox-material
  ];
in
  pkgs.vim_configurable.customize {
    name = "vim";
    vimrcConfig = {
      customRC = customRC;
      packages.myVimPackage = {
        start = plugins;
        opt = [];
      };
    };
  }
