# Pull-based deploys: this machine follows `main` on GitHub, so merging the
# weekly lockfile PR (.github/workflows/update-flake-lock.yml) is the whole
# upgrade — nothing to remember to run afterwards.  See docs/auto-upgrade.md.
#
# The lockfile is only ever moved by that PR, never here: `upgrade = false`
# and no `--update-input`, so the box builds exactly the flake.lock that CI
# built and you reviewed.  A local `nixos-rebuild switch --flake .` from a
# feature branch still works, but lasts only until the next run puts `main`
# back.
#
# Each run's warnings and errors are curated by ./report.sh into
# /var/lib/upgrade-report/latest.md and, with `reportToGitHub`, into an
# `upgrade-log` issue on the repo.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  repo = "paulgsc/dotfiles";
  flakeRef = "github:${repo}";
  user = "paulg";

  # File reports as GitHub issues, with `github-issues-token` from
  # secrets/nixos.yaml (fine-grained, Issues: read/write on this repo only).
  # A declared secret the file doesn't hold fails the build, so on a machine
  # without one set this false; the report still lands in latest.md.
  # docs/auto-upgrade.md.
  reportToGitHub = true;

  report = pkgs.writeShellApplication {
    name = "upgrade-report";
    runtimeInputs = with pkgs; [
      config.systemd.package
      coreutils
      curl
      gawk
      gitMinimal
      gnugrep
      gnused
      hostname
      jq
    ];
    text = builtins.readFile ./report.sh;
  };
in {
  system.autoUpgrade = {
    enable = true;
    flake = "${flakeRef}#nixos";
    # `--upgrade` refreshes root's channels; a flake honouring its lockfile
    # has none to refresh.
    upgrade = false;
    operation = "switch";
    # Daily, not weekly: when `main` hasn't moved this is a no-op switch, and
    # when it has, the merge lands within a day.  Persistent catches up a run
    # missed while the box was off.
    dates = "04:40";
    randomizedDelaySec = "20min";
    persistent = true;
    # A new kernel waits for the next reboot you choose to do.
    allowReboot = false;
    # A background rebuild shouldn't take every core.
    flags = [
      "--max-jobs"
      "2"
      "--cores"
      "0"
    ];
  };

  systemd.services = {
    # Home-manager is standalone here (homeConfigurations, not a NixOS module),
    # so `nixos-rebuild` doesn't touch it.  Chain it on the system upgrade's
    # success, building the commit that system was built from (see the
    # script below), so both halves land on the same revision.
    nixos-upgrade = {
      onSuccess = ["home-manager-upgrade.service"];
      onFailure = ["upgrade-report.service"];
    };

    home-manager-upgrade = {
      description = "Home Manager upgrade for ${user}";
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;

      serviceConfig = {
        Type = "oneshot";
        User = user;
      };

      environment = config.nix.envVars // config.networking.proxy.envVars;
      path = [
        config.nix.package
        pkgs.gitMinimal
        pkgs.coreutils
      ];

      # Pin to the system's commit rather than fetching `main` again: a merge
      # landing mid-run would otherwise put home on a newer commit than the
      # system.  Falls back to `main` when the running system doesn't record
      # one (a local, uncommitted switch).
      #
      # XDG_RUNTIME_DIR lets sd-switch reach the user's systemd to restart
      # changed user units; with nobody logged in, activation skips that step.
      script = ''
        ref='${flakeRef}'
        rev=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)
        if [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
          ref="${flakeRef}/$rev"
        fi
        echo "home-manager: building $ref"

        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        ${inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.home-manager}/bin/home-manager \
          switch --refresh --flake "$ref#${user}@nixos"
      '';

      onSuccess = ["upgrade-report.service"];
      onFailure = ["upgrade-report.service"];
      after = ["nixos-upgrade.service" "network-online.target"];
      wants = ["network-online.target"];
    };

    upgrade-report = {
      description = "Curate the nightly upgrade's warnings and errors";
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe report;
        StateDirectory = "upgrade-report";
      };
      environment = {
        REPO = repo;
        STATE_DIR = "/var/lib/upgrade-report";
        TOKEN_FILE =
          if reportToGitHub
          then config.sops.secrets.github-issues-token.path
          else "/nonexistent";
      };
      after = ["network-online.target"];
      wants = ["network-online.target"];
    };
  };

  sops.secrets = lib.mkIf reportToGitHub {github-issues-token = {};};
}
