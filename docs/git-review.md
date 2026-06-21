# Git History Review Workflow

A CLI/Vim-native way to *replay* a branch — review and reason about what
changed, by whom, and why — without the GitHub web UI and without bloat.

Three layers, each declarative in this flake:

| Layer | Tool | Where it's configured |
|-------|------|------------------------|
| Browse history (TUI) | **tig** | `home-manager/shell/git` → `xdg.configFile."tig/config"` |
| Read diffs / aliases | **git + delta** | `home-manager/shell/git` → `programs.git` |
| In-editor review | **vim-fugitive** | `pkgs/vim` (`<leader>g…` maps) |

---

## The core idea: "replay a branch vs its base"

When reviewing a feature branch, the question is almost never "show me all
history" — it's *"what did **this branch** add on top of where it started?"*

The base branch (usually `main`) is detected automatically by the aliases, so
these work from any feature branch:

```bash
git replay      # graph oneline of commits this branch added (base..HEAD)
git replayp     # same, but full patch per commit, oldest-first, paginated via delta
git changed     # files changed on this branch vs base, with churn stats
```

`git replayp` is the workhorse: it walks the branch commit-by-commit in order,
so you read the change as a *story* rather than one squashed blob. `delta`
renders each hunk with syntax highlighting and line numbers; press `n` / `N`
to jump file-to-file.

---

## tig — the 4 commands that cover 90%

```bash
tig                  # main view: navigable, paginated commit graph of the repo
tig main..feature    # REPLAY: only the commits feature added on top of main
tig blame <file>     # per-line authorship + the commit that introduced each line
tig status           # stage / unstage / commit interactively (like a TUI `git add -p`)
```

### Navigating tig
- `j` / `k` — down / up;  `g` / `G` — top / bottom (vi-style, configured here)
- `Enter` — open the highlighted commit in a split (full diff)
- `Tab` — toggle focus between the log and the diff pane
- `/` — search;  `n` / `N` — next / previous match
- inside a commit diff: `[` / `]` — previous / next file

### Custom keys added in `tig/config`
- `F` — open the highlighted commit as `git show --stat -p … | less -R`
- `U` — `git fetch --all --prune` and refresh, so a long review stays current
- `u` — stage / unstage the line under the cursor (in status/stage views)
- `g` / `G` — jump to top / bottom (vi-style)

> **Replay a teammate's branch you just fetched:**
> ```bash
> git fetch origin
> tig main..origin/their-branch
> ```

---

## git aliases (defined in `home-manager/shell/git`)

| Alias | Does |
|-------|------|
| `git lg` | graph oneline log of the whole history (delta-free, fast) |
| `git replay` | `lg` of `base..HEAD` — this branch's commits |
| `git replayp` | full-patch, oldest-first review of `base..HEAD` |
| `git changed` | `diff --stat base...HEAD` — files + churn on this branch |
| `git who` | `shortlog -sne` — who wrote how much (no merges) |
| `git last` | the last commit + its stat |
| `git praise <file>` | blame with whitespace + copy detection (`-w -C -C -C`) |
| `git s` | short branch-aware status |
| `git graph` | oneline graph of **all** refs |
| `git undo` | soft-reset the last commit (keeps changes staged) |
| `git amend` | amend HEAD without re-editing the message |

`delta` is the pager for `git diff`, `git show`, and `git log -p`, so every
diff you read — through aliases or raw git — is syntax-highlighted.

---

## In Vim (vim-fugitive)

Already installed; these `<leader>g…` maps are added in `pkgs/vim`:

| Map | Does |
|-----|------|
| `<leader>gs` | `:Git` — interactive status; stage/unstage/commit inline |
| `<leader>gb` | `:Git blame` — per-line authorship for the current file |
| `<leader>gl` | `:0Gclog` — commit log of the **current file**, navigable |
| `<leader>gL` | `:Gclog` — repo log into the quickfix list |
| `<leader>gd` | `:Gvdiffsplit` — working tree vs HEAD, side by side |
| `<leader>gr` | run `git replayp` in a terminal tab (branch replay) |
| `<leader>gt` | open `tig %` on the current file's history in a terminal tab |

Inside `:Git blame`, press `Enter` on a line to open that commit; inside
fugitive's status, `=` toggles an inline diff and `cc` starts a commit.

---

## Typical review session

```bash
# 1. land on the branch and grab the latest base
git fetch origin

# 2. get the shape of it: what files, how much churn, by whom
git changed
git who

# 3. read the change as a story, commit by commit
git replayp          # or: tig main..HEAD  for an interactive walk

# 4. drill into a suspicious file's line-level history
tig blame path/to/file.rs     # or in vim: <leader>gb
```

No browser, no `pip install`, all reproducible from the flake.
