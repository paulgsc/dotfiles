
{ config, lib, pkgs, ... }: 
{
    foo
    programs.tmux = {
        enable = true;
        baseIndex = 1;
        historyLimit = 1000;
        extraConfig = ''
            # Git branch and status
            set -g status-left "#[fg=green]#(cd #{pane_current_path}; git rev-parse --abbrev-ref HEAD)#[fg=red]#(cd #{pane_current_path}; git status --porcelain | head -n1 | wc -l | xargs -I {} test {} -gt 0 && echo '*')"

            # Last modified file info
            set -g status-right "#[fg=yellow]#(cd #{pane_current_path}; ls -lt | head -n2 | tail -n1 | awk '{print $6,$7,$8,$9}') "
            
            # Window settings
            setw -g automatic-rename on
            set -g renumber-windows on
            set -g set-titles on
        '';
    };
}


