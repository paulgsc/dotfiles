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
    ./shell/git
    ./shell/disk
    ./shell/clipboard
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

    # typst toolkit
    typst
    tinymist
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

  # Enable home-manager (git is configured in ./shell/git)
  programs.home-manager.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  systemd.user.services.hm-garbage-collector = {
    Unit = {
      Description = "Cleanup old Home Manager generations";
    };
    Service = {
      Type = "oneshot";
      # RETENTION POLICY: 30 days (matches nixos/bootloader-cleanup).
      # Logs /nix/store size before/after so `journalctl --user -u hm-garbage-collector`
      # shows whether GC actually reclaimed anything.
      ExecStart = let
        gc = pkgs.writeShellScript "hm-gc.sh" ''
          before=$(${pkgs.coreutils}/bin/du -sb /nix/store 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo 0)
          ${pkgs.home-manager}/bin/home-manager expire-generations "-30 days"
          ${pkgs.nix}/bin/nix-collect-garbage
          after=$(${pkgs.coreutils}/bin/du -sb /nix/store 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo 0)
          reclaimed=$(( ''${before:-0} - ''${after:-0} ))
          echo "hm-gc: /nix/store $(${pkgs.coreutils}/bin/numfmt --to=iec ''${before:-0}) -> $(${pkgs.coreutils}/bin/numfmt --to=iec ''${after:-0}) (reclaimed $(${pkgs.coreutils}/bin/numfmt --to=iec ''${reclaimed#-}))"
        '';
      in "${gc}";
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
