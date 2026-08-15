# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  outputs,
  config,
  pkgs,
  ...
}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./filesystems.nix

    # Custom opinionated modules
    ./development
    ./remote-gui
    ./state-version-guard
    ./bootloader-cleanup
    ./ports
    ./port-configuration
    ./subdomains
  ];

  nixpkgs = {
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
      # outputs.overlays.unstable-packages  # requires nixpkgs-unstable input (see flake.nix)
    ];
  };

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  virtualisation.docker.enable = true;

  # GNOME on Wayland.  WAYLANDIA-SESSION #17/#28; rationale in
  # docs/wayland-session.md.
  #
  # There is no longer an X11 alternative to weigh: GNOME 49 (NixOS 25.11)
  # deleted the X11 session upstream, and on 26.05
  # `services.displayManager.gdm.wayland` is a *removed* option — "Disabling
  # this option is no longer supported with GNOME 50".  So the session type
  # was decided for us; what this config still gets to choose is whether to
  # keep an Xorg server around, and it does not.
  #
  # `services.xserver.enable` is gone with the same change.  It built an X
  # server that can host no session on a box with no monitor.  X11 *apps* are
  # unaffected: mutter is built with `-Dxwayland_path=${xwayland}`, so
  # Xwayland ships with the compositor, not with Xorg.
  #
  # Both option paths also moved out of `services.xserver` upstream (aliases
  # still resolve on 26.05, but warn).
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Keymap.  These stay under `services.xserver` even with no X server: GDM
  # sets `services.displayManager.enable`, which turns on the internal
  # `services.graphical-desktop` module, which renders the xkb settings into
  # /etc/X11/xorg.conf.d/00-keyboard.conf — the file localectl reads and GNOME
  # follows for the Wayland session and the greeter.
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  # sound.enable = true;
  #
  # `hardware.pulseaudio` was renamed to `services.pulseaudio`; the alias
  # still resolves on 26.05 but warns.  Keeping it `false` also keeps GDM
  # quiet — GDM warns that PulseAudio support will be removed in 26.11.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.paulg = {
    isNormalUser = true;
    description = "Paul Gathondu";
    extraGroups = ["networkmanager" "wheel" "docker" "sshfs"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMJI8w7UZiLQLavfBW2SAmCPzTc817tgedFhLeakGue"
    ];
    packages = with pkgs; [
      #  thunderbird
    ];
  };

  # Auto-login: accepted risk — this machine lives behind a locked door and is
  # not encrypted at rest.  If the threat model ever changes (shared space, laptop,
  # sensitive data at rest) disable these two lines and enable screen-lock on idle.
  # Full-disk encryption (LUKS) would require a clean reinstall; track in issue #4.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "paulg";

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Install firefox.
  programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    git
    bash
    gcc
    gnumake
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = true;

  # Enable mDNS
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = true;
    publish.addresses = true;
    # publish.workstation = true;
  };

  services.subdomains = {
    enable = true;
    backend = "caddy";
    baseDomain = "nixos.local";

    hosts = {
      "file_host" = {
        enable = true;
        proxyPass = "http://file_host:3000";
      };
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  #
  # It does NOT move with the channel.  A release bump changes which nixpkgs
  # this machine builds from; stateVersion records which release its *state*
  # was laid down by, and rewriting it is a data migration wearing a one-line
  # diff.  ./state-version-guard fails the eval if this line drifts, and
  # .github/workflows/check.yml holds the same value in a second file.
  # WAYLANDIA-SESSION #17/#31.
  system.stateVersion = "23.11"; # Did you read the comment?
}
