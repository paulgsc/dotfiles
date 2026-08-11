{pkgs, ...}: let
  # headed-run — give a command a real display server on a box that has no
  # session attached to your ssh login.  WAYLANDIA-GUI #16/#25.
  #
  # The problem: `some-ui`'s Playwright fixtures probe for $DISPLAY /
  # $WAYLAND_DISPLAY and fall back to `--headless=new` when both are unset.
  # Over plain ssh both *are* unset, so the headless path is the only one that
  # ever runs and `headless: false` is untestable — which used to be an
  # argument for keeping `ssh -Y` alive.
  #
  # The fix is not to forward a display from Windows.  It is to give the
  # command its own throwaway compositor on the remote: cage on wlroots'
  # headless backend renders into memory with no GPU, no seat, and no monitor.
  # That keeps the headed path Wayland-native — using Xvfb here would have
  # re-created the X11 dependency this epic exists to delete.
  #
  #   headed-run pnpm test:e2e
  #   headed-run --keep-going pnpm exec playwright test --headed
  #
  # Chromium needs telling to use Wayland; Playwright passes launch args
  # through, so the browser must be started with
  #   --ozone-platform=wayland --enable-features=UseOzonePlatform
  # (see docs/remote-gui-wayland.md for the fixture-side snippet).
  headed-run = pkgs.writeShellScriptBin "headed-run" ''
    set -euo pipefail

    if [ "$#" -eq 0 ]; then
      echo "usage: headed-run <command> [args...]" >&2
      echo "       runs <command> against a throwaway headless Wayland compositor" >&2
      exit 64
    fi

    # Already inside a compositor or an X session — at the physical console,
    # or nested under another headed-run.  Borrow it rather than stacking a
    # second compositor, which would give the browser a display nothing is
    # looking at.
    if [ -n "''${WAYLAND_DISPLAY:-}" ] || [ -n "''${DISPLAY:-}" ]; then
      echo "headed-run: reusing existing display (WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-} DISPLAY=''${DISPLAY:-})" >&2
      exec "$@"
    fi

    # wlroots needs an XDG_RUNTIME_DIR to put the Wayland socket in.  A plain
    # ssh login usually has one from pam_systemd, but `ssh host cmd` and
    # detached CI-ish invocations often do not.
    scratch=""
    if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
      scratch=$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/headed-run.XXXXXXXXXX")
      export XDG_RUNTIME_DIR="$scratch"
      echo "headed-run: no XDG_RUNTIME_DIR, using $scratch" >&2
    fi
    cleanup() {
      [ -n "$scratch" ] && ${pkgs.coreutils}/bin/rm -rf "$scratch"
      return 0
    }
    trap cleanup EXIT

    # headless backend: software rendering into memory, no DRM node, no seat.
    # NO_DEVICES stops libinput from hunting for keyboards/mice that a
    # headless box does not have.
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1

    # cage runs one client and exits with it, so the compositor's lifetime is
    # exactly the command's lifetime — nothing is left running after the tests.
    #
    # Deliberately not `exec`: the socket directory above has to be cleaned up
    # after cage returns, and exec would replace this shell and drop the trap.
    #
    # Backgrounded and explicitly waited on rather than run in the foreground,
    # so that termination can be relayed.  bash defers a trap until the current
    # foreground command finishes, so a SIGTERM aimed at this wrapper alone —
    # job cancellation, a supervisor killing the pid, anything that is not a
    # terminal Ctrl-C hitting the whole process group — would otherwise be
    # queued while cage, the browser and the test suite all kept running.  That
    # is precisely the command-scoped lifetime this wrapper exists to promise.
    ${pkgs.cage}/bin/cage -- "$@" &
    compositor=$!

    relay() {
      kill -"$1" "$compositor" 2>/dev/null || :
    }
    trap 'relay TERM' TERM
    trap 'relay INT' INT

    # `wait` is interruptible: a trapped signal makes it return >128 while cage
    # is still shutting down, so loop until the child is genuinely reaped and
    # its real status is in hand.
    status=0
    while :; do
      if wait "$compositor"; then status=0; else status=$?; fi
      kill -0 "$compositor" 2>/dev/null || break
    done

    trap - TERM INT
    exit "$status"
  '';
in {
  home.packages = [
    headed-run

    # Present so the escape hatch and the debugging story are usable directly:
    #   wayland-info          — what does the compositor actually advertise?
    #   waypipe               — client half of `waypipe ssh` (#24)
    pkgs.wayland-utils
    pkgs.waypipe
  ];
}
