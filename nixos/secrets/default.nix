# Secrets: one encrypted file in git, decrypted at activation into
# /run/secrets/<name> (tmpfs, root-only by default) with this machine's own
# SSH host key.  Nothing is ever copied onto a machine by hand: a new or
# reinstalled machine is a new recipient in /.sops.yaml plus
# `sops updatekeys`.  How-to: docs/secrets.md.
#
# This file is also the catalogue: every secret the system needs is declared
# here, next to the option that consumes it.  A declared secret missing from
# secrets/nixos.yaml fails the build, so one cannot be forgotten.
{
  config,
  inputs,
  lib,
  ...
}: {
  imports = [inputs.sops-nix.nixosModules.sops];

  config = lib.mkMerge [
    {
      sops = {
        defaultSopsFile = ../../secrets/nixos.yaml;
        # age only: the host's ed25519 key is the machine's identity.  (sops-nix
        # would also turn the RSA host key into a GPG key by default.)
        age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        gnupg.sshKeyPaths = [];
      };
    }

    # Cloudflare API token (Zone:DNS:Edit on the one zone) for the LAN
    # wildcard certificate.  docs/lan-tls.md.
    (lib.mkIf config.services.subdomains.tls.enable {
      sops.secrets.cloudflare-dns-token = {};
      services.subdomains.tls.cloudflareTokenFile = config.sops.secrets.cloudflare-dns-token.path;
    })
  ];
}
