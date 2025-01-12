{ config, pkgs, lib, ... }:

let
  customTMUXConfig = ''
    set -g base-index 1
    setw -g pane-base-index 1

    # Status bar customization
    set -g status-bg blue
    set -g status-position bottom
    set -g status-left-length 50
    
    # Git branch and status
    set -g status-left "#[fg=white]branch: #(cd #{pane_current_path}; git rev-parse --abbrev-ref HEAD)#[default]"
    
    # Last modified file info
    set -g status-right "#[fg=yellow]#(cd #{pane_current_path}; ls -lt | head -n2 | tail -n1 | awk '{print $6,$7,$8,$9}')"
    
    # Window settings
    setw -g automatic-rename on
    set -g renumber-windows on
    
  '';

in {
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    historyLimit = 10000;
    extraConfig = customTMUXConfig;
  };
}

