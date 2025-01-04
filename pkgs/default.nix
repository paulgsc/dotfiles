# Custom packages
# Build them using 'nix build .H<pkg_name>
pkgs: {
    vim-custom = pkgs.callPackage ./vim {};
}
