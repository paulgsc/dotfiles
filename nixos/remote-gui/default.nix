{pkgs, ...}: {
  # Remote GUI policy for the headless-ish box.  Formerly nixos/ssh-x11, which
  # existed to make `ssh -Y` draw remote windows on the WSL side.
  # WAYLANDIA-GUI #16/#27.  See docs/remote-gui-wayland.md.
  #
  # X11 forwarding is off, deliberately and explicitly.  Nothing in the daily
  # workflow needs it any more:
  #
  #   * clipboard  -> OSC52 over the plain ssh TTY (WAYLANDIA-CLIP #15)
  #   * Storybook / Vite / tinymist / Grafana / Prometheus
  #                -> HTTP on the LAN via nixos.local, browsed from Windows
  #   * true GUI apps -> the box runs its own GNOME session on seat 0
  #   * headed browser tests -> `headed-run` (a headless Wayland compositor,
  #                             home-manager/shell/headed-test, #25)
  #
  # `false` is also the openssh default, so this line changes no bytes in
  # sshd_config as long as the default holds.  It is written out anyway: this
  # module's entire reason to exist is now the decision *not* to forward X11,
  # and a silent default records no decision.  If a future NixOS/openssh flips
  # the default, this keeps the answer pinned.
  services.openssh.settings.X11Forwarding = false;

  # X11DisplayOffset / X11UseLocalhost are gone with it — both only tune a
  # forwarding channel that no longer exists.  So are xorg.xauth and
  # xorg.xhost: xauth exists to mint the per-session MIT-MAGIC-COOKIE that
  # forwarding hands the client, and xhost is host-based X access control.
  # Neither has a caller once X11Forwarding is off, and both are exactly the
  # kind of always-installed X surface the security review (#7) wants gone.

  environment.systemPackages = with pkgs; [
    # The sanctioned escape hatch for the rare true-remote-GUI case (#24).
    # waypipe is to Wayland what `ssh -X` was to X11 — it forwards the Wayland
    # protocol over an ordinary ssh stdio channel, with no listening socket
    # and no cookie file on the remote:
    #
    #   waypipe ssh nixos.local <gui-app>
    #
    # It is installed rather than merely documented so the escape hatch works
    # the day it is needed instead of requiring a rebuild first.  WSLg supplies
    # the compositor on the Windows side, so waypipe is the only missing piece.
    waypipe
  ];
}
