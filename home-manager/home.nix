# This is your home-manager configuration file
# Use this to configure your home environment (it replaces ~/.config/nixpkgs/home.nix)
{
  inputs,
  outputs,
  lib,
  config,
  pkgs,
  ...
}: {
  # You can import other home-manager modules here
  imports = [
    # If you want to use modules your own flake exports (from modules/home-manager):
    # outputs.homeManagerModules.example

    # Or modules exported from other flakes (such as nix-colors):
    # inputs.nix-colors.homeManagerModules.default
    ./shell/tmux
  ];

  home = {
    username = "paulg";
    homeDirectory = "/home/paulg";
  };

  # Add stuff for your user as you see fit:
  # programs.neovim.enable = true;
  home.packages = with pkgs; [
    # Networking Tools
    curl
    caddy

    # Shell Enahancements
    fzf
    vim-custom
    # tmux
    ripgrep

    # nix tools
    # nix-update
    # nixpkgs-review
    # nix-serve
    # nixpkgs-fmt
    # nixfmt-rfc-style
    # nix-output-monitor
    # cmtr

    # Rust tools
    bandwhich
    procs
    # sd
    # bat
    # eza
    # fd
    # gpg-tui
    # genpass
    # hyperfine

    # Node
    nodejs_latest
    nodePackages.pnpm
    nodePackages.prettier

    # Development Error Analysis Tools
    cargo-errors
    clippy-issues

    # Docker
    docker
    docker-compose
    yamllint
    yamlfmt

    # DB
    sqlite
    nodePackages.sql-formatter
  ];

  programs.bash = {
    enable = true;

    # ensure bash history keeps only unique commands
    historyControl = ["erasedups" "ignoredups"];

    # optional: make history bigger and append to file
    # historyFileSize = 10000;
    # historySize = 10000;
    # historyOptions = ["histappend" "cmdhist" "expand_history"];
  };

  # Enable home-manager and git
  programs.home-manager.enable = true;
  programs.git.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  systemd.user.services.hm-garbage-collector = {
    Unit = {
      Description = "Cleanup old Home Manager generations";
    };
    Service = {
      Type = "oneshot";
      # Expire generations older than 14 days, then collect garbage
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.home-manager}/bin/home-manager expire-generations \"-28 days\" && ${pkgs.nix}/bin/nix-collect-garbage'";
    };
  };

  systemd.user.timers.hm-garbage-collector = {
    Unit = {Description = "Weekly cleanup of Home Manager generations";};
    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
    };
    Install = {WantedBy = ["timers.target"];};
  };

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";
}
