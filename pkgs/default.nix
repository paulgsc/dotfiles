# Custom packages
# Build them using 'nix build .H<pkg_name>
pkgs: {
  # Editor
  vim-custom = pkgs.callPackage ./vim {};

  # Development utilities
  cargo-errors = pkgs.callPackage ./cargo-errors {};
  clippy-issues = pkgs.callPackage ./clippy-issues {};
}
