{pkgs, ...}: let
  # osc52-copy — pipe any command's stdout into the OSC52 escape sequence so
  # it lands in the WSL/Windows clipboard over the existing ssh TTY. No
  # xclip, no wl-copy, no local X/Wayland clipboard needed on the headless
  # remote. WAYLANDIA-CLIP #15/#20.
  #
  # Usage: pocket query | osc52-copy   (replaces `pocket query | wl-copy`)
  osc52-copy = pkgs.writeShellScriptBin "osc52-copy" ''
    set -euo pipefail

    b64=$(${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '\n')

    if [ -n "''${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]52;c;%s\007\033\\' "$b64" >/dev/tty
    else
      printf '\033]52;c;%s\007' "$b64" >/dev/tty
    fi
  '';
in {
  home.packages = [osc52-copy];
}
