_: {
  # Remote GUI policy for the headless-ish box.  Formerly nixos/ssh-x11, which
  # existed to make `ssh -Y` draw remote windows on the WSL side.
  # WAYLANDIA-GUI #16/#27.  See docs/remote-gui-wayland.md.
  #
  # There is no remote-GUI channel, on purpose.  Nothing in the daily workflow
  # needs one:
  #
  #   * clipboard  -> OSC52 over the plain ssh TTY (WAYLANDIA-CLIP #15)
  #   * Storybook / Vite / tinymist / Grafana / RedisInsight / Metabase
  #                -> HTTP on the LAN via nixos.local, browsed from Windows
  #   * Prometheus -> box-only since the port pinning (#7); `ssh -L 9090:…`
  #   * true GUI apps -> the box runs its own GNOME session on seat 0
  #   * headed browser tests -> `headed-run` (a headless Wayland compositor,
  #                             home-manager/shell/headed-test, #25)
  #
  # Both refusals below are written out even where they match openssh's
  # default: this module's entire reason to exist is the decision *not* to
  # forward a display, and a silent default records no decision.  If a future
  # NixOS/openssh flips a default, this keeps the answer pinned.
  #
  # X11Forwarding: `false` is also the openssh default.
  services.openssh.settings.X11Forwarding = false;

  # AllowStreamLocalForwarding: unix-socket forwarding (`ssh -R /path:/path`).
  # This was waypipe's transport, the escape hatch #24 installed.  It was
  # removed in the security review (#7): a waypipe app on the box is a Wayland
  # client of WSLg on the Windows side, and WSLg shares the Windows clipboard,
  # so a compromised box could read whatever Windows last copied.  Refusing
  # the channel server-side means a client-side `waypipe ssh` fails instead of
  # quietly re-opening that path.  The default is "yes", so this one does
  # change sshd_config.
  services.openssh.settings.AllowStreamLocalForwarding = "no";

  # X11DisplayOffset / X11UseLocalhost are gone with it — both only tune a
  # forwarding channel that no longer exists.  So are xorg.xauth and
  # xorg.xhost: xauth exists to mint the per-session MIT-MAGIC-COOKIE that
  # forwarding hands the client, and xhost is host-based X access control.
  # Neither has a caller once X11Forwarding is off, and both are exactly the
  # kind of always-installed X surface the security review (#7) wants gone.
  # waypipe followed for the reason above.
}
