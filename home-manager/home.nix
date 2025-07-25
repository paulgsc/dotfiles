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

  nixpkgs = {
    # You can add overlays here
    overlays = [
      # Add overlays your own flake exports (from overlays and pkgs dir):
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.unstable-packages

      # You can also add overlays exported from other flakes:
      # neovim-nightly-overlay.overlays.default

      # Or define it inline, for example:
      # (final: prev: {
      #   hi = final.hello.overrideAttrs (oldAttrs: {
      #     patches = [ ./change-hello-to-hi.patch ];
      #   });
      # })
    ];
    # Configure your nixpkgs instance
    config = {
      # Disable if you don't want unfree packages
      allowUnfree = true;
    };
  };

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

    # Docker
    docker
    docker-compose

    # DB
    sqlite
    nodePackages.sql-formatter
  ];

  # Enable home-manager and git
  programs.home-manager.enable = true;
  programs.git.enable = true;

  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  home.stateVersion = "23.05";
}
