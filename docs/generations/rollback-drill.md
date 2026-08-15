# Rollback drill

The rehearsed way back off a bad generation, and the two things that quietly
take the way back away.

[WAYLANDIA-SESSION #17](https://github.com/paulgsc/dotfiles/issues/17) story
[S4 #31](https://github.com/paulgsc/dotfiles/issues/31). Companion to
[docs/channel-bump-26.05.md](../channel-bump-26.05.md). Generation *cleanup*
lives in [README.md](./README.md) — this file is about not cleaning up the one
you need.

## Why rehearse it

A rollback path that has never been walked is a belief, not a plan. The
channel bump is the one step in the epic that feels irreversible, so the
reversal gets tested **before** the reboot that might need it — while the
current generation is known-good and there is no pressure.

## Before the bump

```console
$ nix-env --list-generations --profile /nix/var/nix/profiles/system | tail -5
$ readlink -f /run/current-system
```

Write the current generation number down somewhere that is not this machine.
After the reboot it is the number you are rolling back *to*, and a bootloader
menu of five identical `NixOS` entries is not the place to be deducing it.

### Trap 1 — `configurationLimit = 5`

`nixos/bootloader-cleanup` keeps five systemd-boot entries. That is enough for
a bump plus a rollback, and it is *not* enough if you rebuild four more times
before validating. Between `nixos-rebuild boot` and a green
[S5 matrix](../channel-bump-26.05.md#s5--validation-matrix), don't rebuild for
unrelated reasons.

### Trap 2 — the 30-day GC window

This is the one that actually bites. `nixos/bootloader-cleanup` runs

```nix
nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 30d";
};
```

`--delete-older-than 30d` deletes generations by **age**, not by count. The
moment you boot the new generation, the pre-bump one stops being current — and
if it was built more than 30 days ago (entirely normal for a machine that has
been sitting on a pinned channel), the next weekly GC is entitled to delete
the exact generation you are keeping as your escape route. `configurationLimit`
will not save it; that caps entries, it does not pin them.

So, for the migration window, do one of these:

- Validate within days, not weeks, and check
  `nix-env --list-generations --profile /nix/var/nix/profiles/system` still
  lists the pre-bump number before relaxing.
- Or temporarily set `nix.gc.automatic = false` in `nixos/bootloader-cleanup`
  until the matrix is green, and revert it in the same PR that records the
  results.

The same applies to home-manager: `hm-garbage-collector` in
`home-manager/home.nix` expires generations older than 30 days on a weekly
timer.

## The drill

Run this **before** the bump reboot, on the current known-good system.

1. `sudo reboot`, and at the systemd-boot menu pick the entry one below the
   default — the previous generation.
2. Confirm it came up: `readlink -f /run/current-system` should show the older
   generation, and `nixos-version` the older release.
3. Confirm the things you would need in an emergency actually work from it:
   `ssh nixos.local` from WSL, `systemctl is-system-running`, `docker ps`.
4. Reboot again and let the default entry win. You are back where you started,
   and the escape route is now a thing you have used.

Record the drill here:

| Date | Rolled back to | Booted clean? | Notes |
| --- | --- | --- | --- |
| _pending — run before the 26.05 reboot_ | | | |

## The three ways back

| Situation | Command |
| --- | --- |
| System boots, new generation is wrong | `sudo nixos-rebuild switch --rollback` |
| System does not boot / no login | systemd-boot menu → previous generation |
| Only the user environment is wrong | `home-manager switch --rollback` |

`home-manager switch --rollback` is new in home-manager 25.11 and arrives with
this bump; before it, rolling back a home generation meant activating an old
profile by hand and creating a new generation to do it.

## `stateVersion` is not part of any of this

Rolling back the *system* does not roll back state that a changed
`system.stateVersion` would have migrated — that is the whole reason it is
pinned. `nixos/state-version-guard` fails the eval if `23.11` drifts, and
`.github/workflows/check.yml` re-checks both it and home's `23.05` from a
second file, so the guard cannot be quietly edited alongside the value it
guards.
