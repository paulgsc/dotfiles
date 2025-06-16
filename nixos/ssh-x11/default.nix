{
  config,
  pkgs,
  ...
}: {
  # Extend the existing SSH configuration with X11 forwarding
  services.openssh.settings = {
    # X11 Forwarding configuration
    X11Forwarding = true;
    X11DisplayOffset = 10;
    X11UseLocalhost = true;
  };

  # Add X11 forwarding dependencies
  environment.systemPackages = with pkgs; [
    xorg.xauth
    xorg.xhost

    # xorg.libX11 # core X11 support
    # xorg.libXcursor # cursors
    # xorg.libXrandr # resizing
    # xorg.libXrender # drawing enhancements
    # xorg.libxcb # modern X11 protocol
    # xorg.libXi # input devices
    # xorg.libXext # extensions
    # freetype # font rendering
    # fontconfig # font lookup
    # libGL # OpenGL API
    # mesa # software renderer for OpenGL
  ];
}
