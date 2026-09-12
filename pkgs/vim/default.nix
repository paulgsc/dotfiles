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
    let $FZF_DEFAULT_COMMAND = 'git ls-files --exclude-standard --others --cached --modified'

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
      \    'typst': ['tinymist'],
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
      \     'typst': ['trim_whitespace', 'remove_trailing_lines'],
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
    let g:ale_lint_on_text_changed = 'normal'
    let g:ale_lint_delay = 1000 " Wait 1000ms after typing stops
    let g:ale_lint_on_insert_leave = 1
    let g:ale_lint_on_enter = 0                 " don't lint on buffer open
    let g:ale_command_wrapper = 'nice -n 15'

    " --- Typst authoring: ALE+Tinymist LSP, persistent preview, snippets ---
    " See pkgs/vim/typst.vim and docs/typst-math-workflow.md. Sourced as its
    " own file (not inlined here) so its script-local state gets its own
    " script ID, and so the runtime logic stays reviewable/testable outside
    " this generated vimrc string.
    source ${./.}/typst.vim

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

    " --- Git review ergonomics (vim-fugitive) ---
    " <leader>gs : interactive git status (stage/unstage/commit from here)
    nnoremap <leader>gs :Git<CR>
    " <leader>gb : blame the current file (who/why per line)
    nnoremap <leader>gb :Git blame<CR>
    " <leader>gl : commit log of the current file, navigable
    nnoremap <leader>gl :0Gclog<CR>
    " <leader>gL : full repo commit log into the quickfix list
    nnoremap <leader>gL :Gclog<CR>
    " <leader>gd : diff the working tree against HEAD in a split
    nnoremap <leader>gd :Gvdiffsplit<CR>
    " <leader>gr : "replay" this branch vs its base (delta-paginated) in a terminal
    nnoremap <leader>gr :tab terminal git replayp<CR>
    " <leader>gt : open tig on the current file's history without leaving vim
    nnoremap <leader>gt :tab terminal tig %<CR>

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

    " --- OSC52 clipboard yank (WAYLANDIA-CLIP #15/#19) ---
    " "+y / "*y ride the OSC52 escape sequence over the controlling
    " terminal instead of xclip + $DISPLAY. Wrapped for tmux passthrough
    " (see home-manager/shell/tmux's `allow-passthrough on`).
    function! s:OSC52Yank(text) abort
      let b64 = system('base64 | tr -d "\n"', a:text)
      let seq = "\x1b]52;c;" . b64 . "\x07"
      if !empty($TMUX)
        let seq = "\x1bPtmux;\x1b" . seq . "\x1b\\"
      endif
      call writefile([seq], '/dev/tty', 'b')
    endfunction

    " Is there a real clipboard provider behind "+ / "*?  On this box there is
    " not: vim-full is compiled +clipboard, but that clipboard is X11-backed
    " and WAYLANDIA-GUI #16 removed $DISPLAY for good.  vim's adjust_clip_reg()
    " then silently rewrites "+ and "* to the *unnamed* register before the
    " yank happens, so TextYankPost reports an empty regname and a guard that
    " tests for the + register never fires — `"+yy` looked like it worked and
    " copied nothing at all.
    " (A vim built -clipboard is no better: `"+` is E354 and never yanks.)
    " So when no provider exists, treat an ordinary yank as the clipboard yank.
    "
    " That does mean every `yy` reaches the Windows clipboard.  On a box whose
    " only clipboard *is* the terminal, that is the useful default rather than
    " a surprise — but set g:osc52_yank_unnamed = 0 before this loads to opt
    " out and require an explicit "+y (which will then copy nothing).
    let s:osc52_provider =
          \ has('clipboard') && (!empty($DISPLAY) || !empty($WAYLAND_DISPLAY))
    let g:osc52_yank_unnamed = get(g:, 'osc52_yank_unnamed', !s:osc52_provider)

    function! s:OSC52Wanted(event) abort
      if a:event.operator !=# 'y'
        return 0
      endif
      if a:event.regname ==# '+' || a:event.regname ==# '*'
        return 1
      endif
      return g:osc52_yank_unnamed && a:event.regname ==# '''
    endfunction

    augroup osc52_yank
      autocmd!
      autocmd TextYankPost * if s:OSC52Wanted(v:event)
            \ | call s:OSC52Yank(getreg(v:event.regname))
            \ | endif
    augroup END
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

    # Typst: filetype detection, syntax and indent (kaarmu/typst.vim). This
    # is distinct from this repo's own pkgs/vim/typst.vim, sourced above,
    # which owns the ALE/preview/snippet logic instead.
    typst-vim
    vim-vsnip
  ];
in
  # `vim_configurable` became `vim-full` in nixpkgs; the old attribute is a
  # throw as of 25.11.  `.customize` is unchanged — vim-full is still built
  # through `vimUtils.makeCustomizable`.  WAYLANDIA-SESSION #17/#29.
  pkgs.vim-full.customize {
    name = "vim";
    vimrcConfig = {
      inherit customRC;
      packages.myVimPackage = {
        start = plugins;
        opt = [];
      };
    };
  }
