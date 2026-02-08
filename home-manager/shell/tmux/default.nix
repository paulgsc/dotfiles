{
  config,
  pkgs,
  lib,
  ...
}: let
  customTMUXConfig = ''
        # ────────────────────────────────
        # General
        # ────────────────────────────────
        set -g base-index 1
        setw -g pane-base-index 1
        # set -g mouse on
        # set -g history-limit 10000
        set -g status-interval 5
        set -g default-terminal "screen-256color"

        # ────────────────────────────────
        # Visual Theme
        # ────────────────────────────────
        set -g status on
        set -g status-bg colour18
        set -g status-fg white
        set -g status-style "bg=colour18,fg=white"
        set -g message-style "bg=colour18,fg=brightyellow"
        set -g pane-border-style "fg=colour238"
        set -g pane-active-border-style "fg=colour81"
        set -g window-status-format " #[fg=brightblack]#I:#W "
        set -g window-status-current-format "#[fg=colour81,bold]#I:#W#[fg=white]"
        # Detect nix develop shell
        if -F '#{env:IN_NIX_SHELL}' \
          'set -g status-style "bg=colour52,fg=white"; \
           set -g message-style "bg=colour52,fg=brightyellow"; \
           set -g pane-active-border-style "fg=colour196"' \
          'set -g status-style "bg=colour18,fg=white"; \
           set -g message-style "bg=colour18,fg=brightyellow"; \
           set -g pane-active-border-style "fg=colour81"'

        # ────────────────────────────────
        # Git-aware Status Left
        # ────────────────────────────────
        set -g status-left-length 80
        set -g status-left '#[fg=cyan,bold]🧑 #(cd #{pane_current_path} && git config user.name 2>/dev/null || echo "Unknown") \
    #[fg=white](#(cd #{pane_current_path} && git remote get-url origin 2>/dev/null | sed -n "s/.*github\\.com[:/]\\([^/]*\\)\\/.*$/@\\1/p" | head -n1 || echo "@local")) \
    #[fg=white]· \
    #[fg=yellow,bold]📦 #(cd #{pane_current_path} && basename $(git rev-parse --show-toplevel 2>/dev/null) || basename #{pane_current_path}) \
    #[fg=white]: \
    #[fg=green,bold]🌿 #(cd #{pane_current_path} && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-") \
    #(cd #{pane_current_path} && git diff --quiet 2>/dev/null || echo "🔴")#[default]'

        # ────────────────────────────────
        # Status Right — system + time + file info
        # ────────────────────────────────
        set -g status-right-length 120
        set -g status-right '#[fg=brightblack]💻 #(hostname -s) \
    #[fg=white]| #[fg=cyan]⏰ %Y-%m-%d %H:%M \
    #[fg=white]| #[fg=yellow]🔋 #(upower -i $(upower -e | grep BAT) 2>/dev/null | grep -E "percentage" | awk "{print \$2}" || echo "AC") \
    #[fg=white]| #[fg=magenta]🕒 #(uptime | awk -F"up " "{print \$2}" | cut -d"," -f1)#[default]'

        # ────────────────────────────────
        # Windows / Panes
        # ────────────────────────────────
        setw -g automatic-rename on
        set -g renumber-windows on
        set -g display-time 3000
        set -g visual-activity on
        setw -g aggressive-resize on

        # ────────────────────────────────
        # Key Bindings
        # ────────────────────────────────
        bind r source-file ~/.tmux.conf \; display-message "🔁 Reloaded tmux config"
        bind-key -r H resize-pane -L 5
        bind-key -r J resize-pane -D 5
        bind-key -r K resize-pane -U 5
        bind-key -r L resize-pane -R 5

        # ────────────────────────────────
        # Optional Aesthetic Touches
        # ────────────────────────────────
        set -g clock-mode-colour colour81
        set -g clock-mode-style 24
        set -g bell-action none
  '';
in {
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    historyLimit = 10000;
    extraConfig = customTMUXConfig;
  };
}
