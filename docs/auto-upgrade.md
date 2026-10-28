# Upgrades: a weekly PR, a nightly switch, a checked verdict

Modules: `nixos/auto-upgrade`, `.github/workflows/update-flake-lock.yml`,
`.github/workflows/upgrade-slo.yml`. Dashboard: `UPGRADES` in Grafana (paulgsc/server,
`infra/grafana/dashboards/upgrades.jsonnet`).

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
   success it starts `home-manager-upgrade.service`, which runs `home-manager switch` as
   `paulg` on the commit the system was just built from. Both build `main`'s `flake.lock`
   exactly. Neither one updates inputs. Each unit times out (2h and 1h) rather than hang.
4. **After each run**: `upgrade-report.service` judges the run (below) and records the
   verdict: Grafana metrics, a GitHub Deployment, and an `upgrade-log` issue when there's
   anything to read.
5. **Daily at 17:17 UTC**: `upgrade-slo.yml` checks the records from off the box and keeps
   one `slo` issue open while the SLO fails.

A kernel update waits for a reboot you choose to do (`allowReboot = false`).

### Upgrade now

```sh
sudo systemctl start nixos-upgrade     # same path as the nightly run, report included
journalctl -fu nixos-upgrade -u home-manager-upgrade -u upgrade-report
cat /var/lib/upgrade-report/latest.md
```

You can still run `nixos-rebuild switch --flake .#nixos` or
`home-manager switch --flake .#paulg@nixos` from a branch to try something out. The next
nightly run puts `main` back, and a manual run isn't judged or recorded.

## What makes a run good

A run is **good** only if every check holds. Each one is checked, not read off an exit
code:

| Check | How |
|---|---|
| both units succeeded | `systemctl show -p Result` for this run's invocations |
| the system is on `main` | `/run/current-system`'s `configurationRevision` is `main`'s tip (or `main` moved after the run started) |
| home is on that same commit | `paulg`'s home-manager profile is the exact store path that commit's `activationPackage` evaluates to |
| the capture works | each unit prints `warning: upgrade-canary <invocation id>` first; the report must find it through the same journal read and filter as everything else |

Warnings don't make a run bad: they become an issue, and the deploy still counts.

The filter (`nixos/auto-upgrade/filter.sh`) keeps nix's prefixed lines (`warning:`,
`evaluation warning:`, `error:`, `WARNING`, failures) and home-manager's unprefixed ones
("is in the way of", "would be clobbered", …). CI checks it against
`filter-fixture.txt`, a labelled sample of real formats. Lines a wider net catches that
the filter didn't keep are reported as **near misses**; if one should have been kept, add
it to the fixture and fix the filter.

## Where to look

- **Grafana → UPGRADES**, for the current state: the last run's verdict and each check,
  time since the last good run, good nights over 7/30/90 days, and the last run's
  findings, one per row, linked to the issue. It's backed by
  `/var/lib/upgrade-report/metrics/upgrade.prom`, which node_exporter's textfile
  collector serves. Rolling rates come from `/var/lib/upgrade-report/history.jsonl`, not
  Prometheus, whose retention is about 8 days.
- **GitHub → Deployments → `nixos`**, for the run-by-run record. Each status is the
  verdict (`success` good, `failure` a unit failed, `error` not verified), and its
  payload holds the store paths.
- **`upgrade-log` issues**, for what to fix: the host, the deployed revision, the checks,
  the curated lines, the last 60 log lines if a unit failed, the near misses, and how to
  reproduce. There's one issue per distinct set of findings, fingerprinted with store
  hashes and numbers removed. A good run closes the ones it no longer shows; a failed or
  unverified run closes nothing.
- **The `slo` issue**, when the SLO fails. `upgrade-slo.yml` opens it if:
  - no run was recorded in 36h (box off, dead timer, hung run, broken reporter);
  - `main` has a commit older than 36h that no good run deployed;
  - the last run wasn't good;
  - the last good run's store paths aren't what its commit evaluates to on the runner;
  - fewer than 95% of the last 90 nights had a good run (judged once there are 14);
  - the weekly lockfile run failed.

  It rewrites the issue on each check and closes it once everything holds. If the watcher
  itself fails, GitHub emails you as for any failed scheduled run.

A night is the sample, so at one run a night the rate moves in steps of about 1%, and
95% over 90 nights allows four bad or missing nights.

### Token setup

1. Create a fine-grained GitHub token: repository `paulgsc/dotfiles` only, permissions
   **Issues: Read and write** and **Deployments: Read and write**, nothing else.
2. Add it to the secrets file as `github-issues-token` (docs/secrets.md, "Day to day"):

   ```sh
   nix shell nixpkgs#sops -c sops secrets/nixos.yaml
   ```

3. Set `reportToGitHub = true;` in `nixos/auto-upgrade/default.nix` and merge. (It is on for
   this machine.) The script creates the `upgrade-log` label the first time it files.

Changing a token's permissions keeps its value, so adding Deployments later needs no edit
to `secrets/nixos.yaml`. Without it, runs still reach Grafana and issues, but the watcher
reports `no_record`.

The toggle exists because sops-nix fails the build when a declared secret is missing from
`secrets/nixos.yaml`. With the toggle off, nothing is declared and reports stay local.

## One-time repo setting

Settings → Actions → General → Workflow permissions → tick **"Allow GitHub Actions to
create and approve pull requests"**. Without it the PR step fails with
`GitHub Actions is not permitted to create or approve pull requests`. That error is why
the old weekly job in `check.yml` never opened a PR.
