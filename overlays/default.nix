# This file defines overlays
{inputs, ...}: {
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = final: prev: {
	
	# vim-custom = prev.vim-custom.override {
	  # Add any vim overrides
	# };
  };

  # DORMANT: this overlay is defined but NOT applied anywhere until nixpkgs-unstable
  # is declared as a flake input.  To activate:
  #   1. Uncomment nixpkgs-unstable.url in flake.nix
  #   2. Run `nix flake update nixpkgs-unstable` to populate flake.lock
  #   3. Add outputs.overlays.unstable-packages back to the overlays lists in
  #      flake.nix (homeConfigurations pkgs) and nixos/configuration.nix
  # After that, pkgs.unstable.<name> becomes available everywhere.
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      system = final.system;
      config.allowUnfree = true;
    };
  };
}
