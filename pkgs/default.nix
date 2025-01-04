{ pkgs ? import <nixpkgs> {} }: {
  vim-custom = pkgs.callPackage ./vim {};
}
