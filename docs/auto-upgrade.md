# Upgrades: a weekly PR, a nightly switch, an issue when it's noisy

Modules: `nixos/auto-upgrade`, `.github/workflows/update-flake-lock.yml`.

## The loop

1. **Monday 06:00 UTC**: `update-flake-lock.yml` runs `nix flake update`. It builds the
   system and home closures before and after the update, and opens (or refreshes) one PR,
   `chore(flake): weekly lockfile update`. The PR body is the changeset:
   - each input that moved, with a GitHub compare link
   - `nvd diff` of the system closure and of the home closure: which packages change
     version, which get added, which get removed

   It then dispatches `check.yml` on the PR branch so the usual checks show on the PR.
   Pushes made with `GITHUB_TOKEN` can't trigger `push`/`pull_request` runs themselves.
2. **You review and merge.** That's the only manual step.
3. **Nightly at 04:40 local** (± 20 min, caught up after downtime): `nixos-upgrade.service`
   runs `nixos-rebuild switch --refresh --flake github:paulgsc/dotfiles#nixos`. On
   success it starts `home-manager-upgrade.service`, which runs
   `home-manager switch --refresh --flake github:paulgsc/dotfiles#paulg@nixos` as `paulg`.
   Both build `main`'s `flake.lock` exactly. Neither one updates inputs.
4. **After each run**: `upgrade-report.service` reads both units' journal for that run and
   keeps only the warning and error lines (`warning:`, `evaluation warning:`, `error:`,
   activation `WARNING`, failures). It writes them to `/var/lib/upgrade-report/latest.md`.
   With the token set up (below), it also files them as an `upgrade-log` issue.

A kernel update waits for a reboot you choose to do (`allowReboot = false`).

### Upgrade now

```sh
sudo systemctl start nixos-upgrade     # same path as the nightly run, report included
journalctl -fu nixos-upgrade -u home-manager-upgrade
cat /var/lib/upgrade-report/latest.md
```

You can still run `nixos-rebuild switch --flake .#nixos` or
`home-manager switch --flake .#paulg@nixos` from a branch to try something out. The next
nightly run puts `main` back, and a manual run's output isn't reported.

## Issues an agent can pick up

Each issue holds: the host, the deployed `main` revision, each unit's result, the curated
lines, the last 60 log lines if a unit failed, and how to reproduce with `nix build`. It
is labelled `upgrade-log`.

- **No duplicates.** The body carries a fingerprint of the normalized lines (store hashes
  and numbers removed), so the same warnings every night stay one issue.
- **Self-closing.** After a successful run, any open `upgrade-log` issue whose
  fingerprint doesn't match that run gets closed with a comment. The issue was either
  fixed or replaced by a newer issue holding what's left. A failed run closes nothing.

### Token setup

1. Create a fine-grained GitHub token: repository `paulgsc/dotfiles` only, permission
   **Issues: Read and write**, nothing else.
2. Add it to the secrets file as `github-issues-token` (docs/secrets.md, "Day to day"):

   ```sh
   nix shell nixpkgs#sops -c sops secrets/nixos.yaml
   ```

3. Set `reportToGitHub = true;` in `nixos/auto-upgrade/default.nix` and merge. (It is on for
   this machine.) The script creates the `upgrade-log` label the first time it files.

The toggle exists because sops-nix fails the build when a declared secret is missing from
`secrets/nixos.yaml`. With the toggle off, nothing is declared and reports stay local.

## One-time repo setting

Settings → Actions → General → Workflow permissions → tick **"Allow GitHub Actions to
create and approve pull requests"**. Without it the PR step fails with
`GitHub Actions is not permitted to create or approve pull requests`. That error is why
the old weekly job in `check.yml` never opened a PR.
