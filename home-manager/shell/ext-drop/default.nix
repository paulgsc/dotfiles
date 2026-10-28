{pkgs, ...}: let
  # ext-drop: build a some-ui extension and keep the zip in /srv/builds,
  # which Caddy serves to the LAN as https://builds.<baseDomain>/
  # (nixos/configuration.nix).  The Windows browser pulls it from there, so
  # nothing on this box writes to Windows.  docs/ext-drop.md.
  #
  # writeShellApplication rather than writeShellScriptBin: it runs shellcheck
  # at build time and sets errexit/nounset/pipefail itself.  pnpm and node
  # are not pinned here; they come from the PATH (home.nix), as for any other
  # pnpm command in the checkout.
  ext-drop = pkgs.writeShellApplication {
    name = "ext-drop";
    runtimeInputs = with pkgs; [coreutils findutils git jq util-linux zip];
    text = builtins.readFile ./ext-drop.sh;
  };
in {
  home.packages = [ext-drop];
}
