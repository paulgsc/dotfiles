{config, ...}: let
  # The release this machine's *state* was first laid down by — not the
  # release it builds from.  WAYLANDIA-SESSION #17/#31.
  #
  # Every channel bump is an invitation to "tidy up" this value, because it
  # looks like a version that has fallen behind.  It hasn't.  Options all over
  # nixpkgs branch on it to decide stateful defaults — which PostgreSQL major
  # a fresh cluster gets, where a service keeps its data dir, whether a unit
  # runs under DynamicUser.  Moving it re-points those at the new release's
  # answers for state that already exists in the old one's shape.
  #
  # The 26.05 release notes are full of exactly these: stalwart's data dir and
  # unit user, taskchampion's DynamicUser migration, nextcloud's default major.
  # None of them fire here while this stays at 23.11 — which is the entire
  # point of the bump being boring.
  #
  # If a migration is ever genuinely wanted, it is its own change, with its own
  # per-service migration steps, on a day when nothing else is moving.
  firstInstallRelease = "23.11";
in {
  assertions = [
    {
      assertion = config.system.stateVersion == firstInstallRelease;
      message = ''
        system.stateVersion is "${config.system.stateVersion}", but this machine
        is pinned to "${firstInstallRelease}" (nixos/state-version-guard).

        A channel bump must not move stateVersion.  If you are bumping nixpkgs,
        revert this line in nixos/configuration.nix.  If you really are
        migrating state, change firstInstallRelease here too — deliberately,
        in its own commit, and read what each affected service does at the new
        value first.
      '';
    }
  ];
}
