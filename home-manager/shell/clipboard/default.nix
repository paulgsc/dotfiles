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

    # One plain OSC52, inside tmux or not.  Inside tmux, `set-clipboard on`
    # makes tmux take the sequence from this pane and relay it to the outer
    # terminal through its `Ms` capability (home-manager/shell/tmux).  The old
    # DCS `\ePtmux;…` envelope needed `allow-passthrough on`, which lets any
    # program printing into a pane — `cat` of a hostile log — talk to Windows
    # Terminal directly; passthrough is now off and that envelope is dropped.
    #
    # Not `tmux load-buffer -w -`: it would reach the server named by $TMUX,
    # which can be stale or point elsewhere (a nested or detached shell),
    # while /dev/tty is always the pane this command actually runs in, and the
    # same line works with no tmux at all.
    printf '\033]52;c;%s\007' "$b64" >/dev/tty
  '';
in {
  home.packages = [wclip];
}
