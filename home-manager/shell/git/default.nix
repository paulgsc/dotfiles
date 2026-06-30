{pkgs, ...}: {
  # ──────────────────────────────────────────────────────────────
  # tig — paginated, navigable commit-history TUI
  # ──────────────────────────────────────────────────────────────
  home.packages = [pkgs.tig];

  xdg.configFile."tig/config".text = ''
    # ── General ──────────────────────────────────────────────────
    set line-graphics = utf-8
    set tab-size = 4
    set ignore-case = smart-case
    set mouse = no
    set vertical-split = auto
    set blame-options = -C -C -C   # follow code moved across/within files

    # ── Main view: dense, reviewable log ────────────────────────
    set main-view = id date:relative author:abbreviated commit-title:graph=v1,refs=yes
    set main-view-date = relative
    set main-view-author = abbreviated

    # ── Vi-style navigation on top of tig defaults ──────────────
    bind generic g  move-first-line
    bind generic G  move-last-line
    bind main    G  move-last-line

    # ── Review ergonomics ───────────────────────────────────────
    # F: open the highlighted commit as a full, paginated patch
    bind generic F  !sh -c "git show --stat -p %(commit) | less -R"
    # U: fetch + prune so a long-lived review view stays current
    bind generic U  ?git fetch --all --prune

    # ── Status/stage view: faster staging ───────────────────────
    bind status  u  status-update
    bind stage   u  stage-update-line
  '';

  # ──────────────────────────────────────────────────────────────
  # git — declarative identity, delta pager, review aliases
  # ──────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    userName = "Paul Gathondu";
    userEmail = "streakfor@gmail.com";

    # delta: syntax-highlighted diffs for diff / show / log -p and fugitive.
    delta = {
      enable = true;
      options = {
        navigate = true; # n / N jump between files in a diff
        line-numbers = true;
        side-by-side = false; # flip to true for two-column diffs
        syntax-theme = "gruvbox-dark"; # matches the vim gruvbox-material theme
      };
    };

    extraConfig = {
      init.defaultBranch = "main";
      pull.ff = "only"; # never create implicit merge commits on pull
      push.autoSetupRemote = true; # first push of a new branch just works
      fetch.prune = true; # drop deleted remote branches on fetch
      rerere.enabled = true; # remember conflict resolutions
      merge.conflictStyle = "zdiff3"; # show the common ancestor in conflicts
      log.date = "iso";
      diff.algorithm = "histogram"; # smarter, more readable hunks
      diff.colorMoved = "default"; # distinguish moved code from add/delete
      branch.sort = "-committerdate"; # most-recent branches first
      column.ui = "auto";
    };

    aliases = {
      # base: resolve this repo's default branch (origin/HEAD, else main).
      # Every "replay" alias calls this so they work from any feature branch.
      base = "!git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main";

      # ── Replay / review primitives ────────────────────────────
      lg = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) %C(dim white)%an%C(reset) %C(green)(%ar)%C(reset)%C(auto)%d%C(reset)%n          %s'";
      # commits THIS branch added on top of its base
      replay = "!git lg $(git base)..HEAD";
      # same, with full patches per commit, oldest-first — the paginated review
      replayp = "!git log -p --reverse $(git base)..HEAD";
      # files changed on this branch vs base, with churn stats
      changed = "!git diff --stat $(git base)...HEAD";

      # ── Authorship / blame ────────────────────────────────────
      who = "shortlog -sne --no-merges"; # who wrote how much
      last = "log -1 HEAD --stat";
      praise = "blame -w -C -C -C"; # blame ignoring whitespace, following moves

      # ── Gone-branch cleanup ───────────────────────────────────
      # list local branches whose upstream was deleted (preview before sweep)
      gone = "!git fetch --prune && git branch -vv | awk '/: gone]/{print $1}'";
      # delete local branches whose upstream is gone (safe; fails if unmerged)
      sweep = "!git fetch --prune && git branch -vv | awk '/: gone]/{print $1}' | xargs -r git branch -d";
      # force-delete gone-upstream branches regardless of merge status
      sweep-f = "!git fetch --prune && git branch -vv | awk '/: gone]/{print $1}' | xargs -r git branch -D";

      # ── Everyday quality-of-life ──────────────────────────────
      s = "status -sb";
      d = "diff";
      dc = "diff --cached";
      co = "checkout";
      undo = "reset --soft HEAD~1"; # undo last commit, keep changes staged
      amend = "commit --amend --no-edit";
      graph = "log --graph --oneline --decorate --all";
    };
  };
}
