# Rust scratchpad

`prefix S` in tmux opens a window named `scratch`. Vim edits a fresh `main.rs`
on the left, and the right pane recompiles, lints and runs it on every save.
Quit vim or close the window, and everything is deleted. Nothing is ever
written outside tmpfs.

The tool lives in [paulgsc/scratch](https://github.com/paulgsc/scratch). The
binding runs:

```sh
nix develop github:paulgsc/scratch#scratchpad -c scratch
```

rustc, clippy, rustfmt and rust-analyzer exist only inside that dev shell.
None of them is in `environment.systemPackages` or `home.packages`, and none
should be. The first run fetches the toolchain. Later runs reuse it until a
garbage collection removes it.

## In vim (pkgs/vim/scratch.vim)

These settings apply only to a `.rs` file in a scratch dir, meaning a directory
with the `.scratch` marker, opened while the `scratch` command is on PATH:

- **Inline diagnostics.** ALE runs two linters. rust-analyzer reads the
  generated `rust-project.json` and gives types, hover and completion with no
  `Cargo.toml`. A `scratch` linter runs `scratch check -`, which is rustc +
  clippy on the buffer, as you type.
- **`<leader>r`** (or `:make`) runs `scratch run` on the file. Errors go to the
  quickfix list, and the program's output appears below them.
- `:e other.rs` starts another scratch file. It becomes a rust-analyzer crate
  on its first save, and the watch pane runs whichever file was saved last.

Two choices here are deliberate:

- **rust-analyzer's own check on save is not used.** Under ALE, rust-analyzer
  pushes the check results, ALE then pulls rust-analyzer's native
  diagnostics, and the later answer replaces the earlier one. Moved values
  and clippy warnings vanished the moment they appeared. A separate ALE
  linter keeps them.
- **`scratch check` never uses `-o /dev/null`.** rustc writes its output to a
  file and renames it over the output path. Run as root, that replaces
  `/dev/null` with a regular file.

## From the shell

Inside the dev shell, `scratch run foo.rs` compiles, lints and runs any file
with a `main`. `scratch watch foo.rs` does the same on every save. See the
scratch repo's README for the rest.
