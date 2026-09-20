{pkgs, ...}: let
  # wclip — pipe any command's stdout into the OSC52 escape sequence so it
  # lands in the WSL/Windows clipboard over the existing ssh TTY. No xclip,
  # no wl-copy, no local X/Wayland clipboard needed on the headless remote.
  # WAYLANDIA-CLIP #15/#20.
  #
  # Usage: pocket query | wclip              (copy silently)
  #        pocket query | wclip >pocket.txt  (copy and save)
  #        pocket query | wclip | less       (copy and keep piping)
  wclip = pkgs.writeShellScriptBin "wclip" ''
    set -euo pipefail

    # Spooling the input avoids storing the unencoded payload in a shell
    # variable (which cannot represent NUL bytes).
    spool=$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/wclip.XXXXXXXXXX")
    trap '${pkgs.coreutils}/bin/rm -f "$spool"' EXIT INT TERM

    if [ -t 1 ]; then
      # stdout is the terminal itself: there's no downstream reader, so
      # passing the payload through would just dump it straight back onto
      # the screen right after the command that produced it already
      # printed it (#42). Spool it quietly instead.
      ${pkgs.coreutils}/bin/cat >"$spool"
    else
      # Something is actually consuming stdout — a file redirect or a
      # further pipe — so keep it useful and let wclip sit in the middle
      # of a pipeline, much like tee.
      #
      # -p (--output-error=warn-nopipe) keeps tee alive when the downstream
      # reader exits early — `cmd | wclip | head -1`, quitting `less`, etc.
      # Without it tee dies on SIGPIPE mid-stream and, under `set -e`, the
      # copy never happens: the spool is truncated and the OSC52 write below
      # is never reached.  Copying is the job; passthrough is the courtesy.
      ${pkgs.coreutils}/bin/tee -p "$spool"
    fi
    b64=$(${pkgs.coreutils}/bin/base64 <"$spool" | ${pkgs.coreutils}/bin/tr -d '\n')

    if [ -n "''${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]52;c;%s\007\033\\' "$b64" >/dev/tty
    else
      printf '\033]52;c;%s\007' "$b64" >/dev/tty
    fi
  '';
in {
  home.packages = [wclip];
}
