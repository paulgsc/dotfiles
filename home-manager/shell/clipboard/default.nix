{pkgs, ...}: let
  # wpaste — request the clipboard from an OSC52 terminal and write it to
  # stdout.  Clipboard reads are deliberately opt-in in many terminals, and
  # some (notably Windows Terminal) may not implement them at all.
  wpaste = pkgs.writeShellScriptBin "wpaste" ''
    exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
    import base64
    import binascii
    import os
    import select
    import sys
    import termios
    import time
    import tty

    if len(sys.argv) != 1:
        sys.exit("usage: wpaste")

    timeout = float(os.environ.get("WPASTE_TIMEOUT", "2"))
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    original = termios.tcgetattr(fd)
    query = b"\033]52;c;?\007"
    if os.environ.get("TMUX"):
        query = b"\033Ptmux;" + query.replace(b"\033", b"\033\033") + b"\033\\"

    response = bytearray()
    try:
        tty.setraw(fd)
        os.write(fd, query)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], deadline - time.monotonic())
            if not ready:
                break
            response.extend(os.read(fd, 4096))
            if b"\007" in response or b"\033\\" in response:
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, original)
        os.close(fd)

    marker = response.find(b"\033]52;")
    if marker < 0:
        sys.exit(
            "wpaste: terminal did not answer the OSC52 clipboard query; "
            "clipboard reads may be unsupported or disabled"
        )
    payload = response[marker + len(b"\033]52;"):]
    separator = payload.find(b";")
    if separator < 0:
        sys.exit("wpaste: malformed OSC52 response")
    payload = payload[separator + 1:]
    endings = [position for position in (payload.find(b"\007"), payload.find(b"\033\\")) if position >= 0]
    if not endings:
        sys.exit("wpaste: incomplete OSC52 response")
    payload = payload[:min(endings)]
    try:
        sys.stdout.buffer.write(base64.b64decode(payload, validate=True))
    except binascii.Error:
        sys.exit("wpaste: terminal returned invalid base64 clipboard data")
    PY
  '';

  # wclip — pipe any command's stdout into the OSC52 escape sequence so it
  # lands in the WSL/Windows clipboard over the existing ssh TTY. No xclip,
  # no wl-copy, no local X/Wayland clipboard needed on the headless remote.
  # WAYLANDIA-CLIP #15/#20.
  #
  # Usage: pocket query | wclip              (copy and print)
  #        pocket query | wclip >pocket.txt  (copy and save)
  #        pocket query | wclip | less       (copy and keep piping)
  #        wclip --paste >clipboard.txt      (read, when terminal permits it)
  wclip = pkgs.writeShellScriptBin "wclip" ''
    set -euo pipefail

    if [ "''${1:-}" = --paste ]; then
      if [ "$#" -ne 1 ]; then
        echo "usage: wclip [--paste]" >&2
        exit 2
      fi
      exec ${wpaste}/bin/wpaste
    elif [ "$#" -ne 0 ]; then
      echo "usage: wclip [--paste]" >&2
      exit 2
    fi

    # Keep stdout useful so wclip can sit in the middle of a pipeline, much
    # like tee.  Spooling the input also avoids storing the unencoded payload
    # in a shell variable (which cannot represent NUL bytes).
    spool=$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/wclip.XXXXXXXXXX")
    trap '${pkgs.coreutils}/bin/rm -f "$spool"' EXIT

    ${pkgs.coreutils}/bin/tee "$spool"
    b64=$(${pkgs.coreutils}/bin/base64 <"$spool" | ${pkgs.coreutils}/bin/tr -d '\n')

    if [ -n "''${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]52;c;%s\007\033\\' "$b64" >/dev/tty
    else
      printf '\033]52;c;%s\007' "$b64" >/dev/tty
    fi
  '';
in {
  home.packages = [wclip wpaste];
}
