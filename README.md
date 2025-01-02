# dotfiles

```markdown
# Dotfiles Repository

This repository contains my personal configuration files for various tools and environments. Currently, it includes a basic `vimrc` setup optimized for Rust development.

## Features

The `vimrc` file provides:
- **Syntax highlighting** for Rust and general programming.
- **File navigation** with netrw (default Vim file explorer).
- **Indentation rules** tailored for Rust's formatting standards.
- Basic **Rust development plugins** via `vim-plug`.

---

## Installation

### Prerequisites
- **Vim**: Ensure you have Vim 8.0+ installed.
- **`curl` or `wget`**: Needed to install `vim-plug`.

### Steps
1. Clone this repository:
   ```bash
   git clone https://github.com/your-username/dotfiles.git ~/dotfiles
   ```

2. Backup your existing `.vimrc` (if any):
   ```bash
   mv ~/.vimrc ~/.vimrc.bak
   ```

3. Link the provided `vimrc`:
   ```bash
   ln -s ~/dotfiles/vimrc ~/.vimrc
   ```

4. Install `vim-plug` (if not already installed):
   ```bash
   curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
   ```

5. Launch Vim and install plugins:
   ```bash
   vim +PlugInstall +qall
   ```

---

## Plugins

The `vimrc` uses `vim-plug` to manage plugins. The following plugins are included:
- **[rust.vim](https://github.com/rust-lang/rust.vim)**: Provides Rust-specific syntax highlighting and utilities.
- **[NERDTree](https://github.com/preservim/nerdtree)**: File system explorer.
- **[vim-airline](https://github.com/vim-airline/vim-airline)**: Status/tabline for Vim.
- **[fzf.vim](https://github.com/junegunn/fzf.vim)**: Fuzzy finder integration.

---

## Key Mappings

### Rust-Specific
- `:RustFmt` - Formats Rust code with `rustfmt` (requires installation).

### General
- `<Leader>n` - Toggle file explorer (NERDTree).
- `<Leader>f` - Fuzzy file search (requires `fzf`).



---


## License

This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.
```

This README is simple but provides clear instructions on setting up and using the repository. Adjust details (like plugin choices and mappings) to match your actual `vimrc` configuration.
