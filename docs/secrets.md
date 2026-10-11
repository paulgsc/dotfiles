# Secrets

Module: `nixos/secrets` (sops-nix). Recipients: `/.sops.yaml`. Encrypted values:
`secrets/nixos.yaml`.

## The model

- **In git:** `secrets/nixos.yaml`. Its key names are readable, its values are encrypted
  (AES-GCM). The data key that unlocks them is in the same file, wrapped once for each
  recipient listed in `.sops.yaml`. Committing it is the point: the repo is the single
  source.
- **Who can decrypt:** the recipients. One is **you** (an age "admin" key), and one is
  **each machine** (its SSH host key `/etc/ssh/ssh_host_ed25519_key`, which every NixOS
  install already has).
- **Where it lands:** at activation (boot and every `nixos-rebuild switch`), sops-nix
  decrypts each declared secret into `/run/secrets/<name>`. That's a tmpfs, root-only
  (`0400`) unless a secret says otherwise, and it never touches the Nix store or the disk.
- **What's declared:** `nixos/secrets/default.nix` lists every secret the system uses,
  next to the option that consumes it. A declared secret that `secrets/nixos.yaml`
  doesn't contain **fails the build**:

  ```
  secret cloudflare-dns-token in …/nixos.yaml is not valid: the key 'cloudflare-dns-token' cannot be found
  ```

So the only thing you keep outside git is your admin key, and it's one key for every
machine.

## One-time setup

Run this on the NixOS machine, in the dotfiles checkout. First open a shell with the
three tools it uses (nothing gets installed permanently):

```sh
nix shell nixpkgs#sops nixpkgs#age nixpkgs#ssh-to-age
```

1. **Make your admin key** (once, ever, not once per machine):

   ```sh
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt     # prints "Public key: age1…"
   chmod 600 ~/.config/sops/age/keys.txt
   ```

   Save the file's contents in your password manager. It's the one secret you back up.
   sops finds it at that path automatically. On another computer you edit from, restore
   it to the same path.

2. **Get this machine's recipient** from its SSH host key:

   ```sh
   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub   # age1…
   ```

3. **Put both public keys in `.sops.yaml`**, replacing the two `age1REPLACE_…`
   placeholders. Until you do, sops refuses to encrypt anything. Public keys are safe to
   commit.

4. **Create the secrets file:**

   ```sh
   mkdir -p secrets             # sops creates the file, not the folder
   sops secrets/nixos.yaml      # opens $EDITOR on a plaintext view
   ```

   Write the values as YAML (`name: value`), save and quit. sops encrypts on save.

5. **Commit and rebuild:**

   ```sh
   git add .sops.yaml secrets/nixos.yaml && git commit -m "secrets: bootstrap"
   sudo nixos-rebuild switch --flake .#nixos
   sudo ls -l /run/secrets/                     # what was decrypted
   ```

## Day to day

Each `sops` command below runs inside `nix shell nixpkgs#sops nixpkgs#ssh-to-age`.

**Change a value:** run `sops secrets/nixos.yaml`, edit, save, commit, rebuild. To have a
service restart when its secret changes, set `restartUnits = ["<unit>.service"];` on the
secret.

**Add a secret:**

1. Add `<name>: <value>` with `sops secrets/nixos.yaml`.
2. Declare it in `nixos/secrets/default.nix` and hand its path to the option that wants
   it, under the same condition that turns the consumer on:

   ```nix
   (lib.mkIf config.services.foo.enable {
     sops.secrets.foo-api-key = {
       owner = "foo";                       # default root, mode 0400
       restartUnits = ["foo.service"];
     };
     services.foo.apiKeyFile = config.sops.secrets.foo-api-key.path;
   })
   ```

   For a service that wants an env file or a config file with the secret inside,
   `sops.templates."foo.env".content = "TOKEN=${config.sops.placeholder.foo-api-key}";`
   renders one at activation. Use `config.sops.templates."foo.env".path` there.

Prefer options that take a **file path** (`…File`, `credentialFiles`, `LoadCredential`)
over ones that take the value: a value in a Nix option is copied into the
world-readable Nix store.

**Add a machine, or reinstall one:** a reinstall makes a new host key, so it is a new
machine as far as sops is concerned.

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub   # on the new machine
# add it to .sops.yaml (a new &anchor in keys:, and in the creation rule's age list),
# then, wherever your admin key is:
sops updatekeys secrets/nixos.yaml
git commit -am "secrets: add <machine>"
```

Then rebuild on the new machine. Nothing is copied onto it.

If machines need different secrets, give each its own file
(`secrets/<machine>.yaml`) and its own `creation_rules` entry, listing only that
machine's key and yours. Then point that machine's `sops.defaultSopsFile` at it.

**Rotate:** removing a recipient from `.sops.yaml` and running `sops updatekeys` stops
*future* versions from decrypting for it, but git history still holds the old file. When a
machine or your admin key may be compromised, change the values at their source
(Cloudflare and so on) too.

**Lost the admin key:** every machine can still decrypt with its host key, so nothing
stops working. Make a new admin key, then re-encrypt the file as root on a machine
that's a recipient:

```sh
sudo env SOPS_AGE_KEY="$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)" \
  sops updatekeys secrets/nixos.yaml
```

(Put the new admin public key in `.sops.yaml` first.)

## Current secrets

| Name                   | Consumer                                                    | Declared when                     |
| ---------------------- | ----------------------------------------------------------- | --------------------------------- |
| `cloudflare-dns-token` | ACME DNS-01 for the LAN wildcard cert ([lan-tls.md](lan-tls.md)) | `services.subdomains.tls.enable` |
