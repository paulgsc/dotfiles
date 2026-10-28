# Extension builds: from this box to the Windows browser

The some-ui extensions that are not on AMO (everything but suspender-ledger) exist only as
builds. This is how a build gets from this box to the Windows browser, and how the last
good one stays at hand while a new one is tried.

## The direction: Windows pulls

Builds used to reach Windows by `scp` from WSL into `/mnt/c`. Nothing here writes to Windows
any more. `ext-drop` keeps each build in `/srv/builds` on this box, and Caddy serves that
folder to the LAN as **https://builds.home.maishatu.com/**, with the same certificate as the
other `*.home` names (`docs/lan-tls.md`). The Windows browser downloads from there. WSL is
not involved, so it needs neither `/mnt/c` nor `scp`.

## The loop

```bash
cd ~/dev/some-ui            # any branch, any commit
ext-drop some-filter chromium   # build it and keep the zip; beta.zip now points at it
# ... try it in the browser for a while ...
ext-drop promote some-filter chromium   # it works: stable.zip now points at it too
```

The target is the extension's `build:<target>` script (`chromium` or `firefox`). Leave it out
and `ext-drop` runs plain `build` and names the target from the built manifest: a
`background.service_worker` is Chromium's, `background.scripts` is Firefox's. An extension
with only `build` (some-drama) is built without a target.

Each extension and target has one folder:

```
/srv/builds/some-filter/chromium/
  some-filter-chromium-20261017-032106-a2519f2.zip   every build: time, commit, -dirty
  some-filter-chromium-20261019-101500-e4f5a6b.zip
  stable.zip -> some-filter-chromium-20261017-032106-a2519f2.zip
  beta.zip   -> some-filter-chromium-20261019-101500-e4f5a6b.zip
  pointers.txt                                       which build each pointer names
```

- **Nothing is overwritten.** Each build is a new file named by time and commit, so a new
  build cannot replace the one you trust.
- **Nothing piles up.** After each build, only the newest `EXT_DROP_KEEP` builds (default 5)
  are kept, plus whatever `stable.zip` and `beta.zip` name, so the stable build is never
  pruned however old it gets.
- **Rolling back is one command.** If a new build is bad, download `stable.zip`. To make an
  older kept build stable, name it:
  `ext-drop promote some-filter chromium some-filter-chromium-20261017-032106-a2519f2.zip`.
- **A download says what it is.** Every zip carries `ext-drop.json` (extension, target,
  commit, branch, dirty, time), so a file saved as `stable.zip` still names its commit.
  `-dirty` in a name means it was built with uncommitted changes: the commit alone will not
  rebuild it.

## On Windows

Use **one browser profile for builds you are trying**, separate from the profile you use for
banking and email. An extension built on this box runs with whatever permissions it asks
for, and the threat model in `nixos/configuration.nix` assumes code here may one day be
hostile. Loading `stable` in one profile and `beta` in another also keeps the two copies of
one extension from running their content scripts twice in the same tabs.

- **Chrome / Edge:** unzip into a fixed folder (`Downloads\some-filter-beta\`), replacing
  what was there, then press reload on that extension in `chrome://extensions`. **Load
  unpacked** is needed only the first time.
- **Firefox:** `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on** accepts
  the `.zip` itself, with no unzipping. A temporary add-on is gone after a restart; only a
  signed `.xpi` (suspender-ledger's AMO route) stays installed.

## What this exposes

- **No new ports.** Caddy's 443 was already open to the LAN.
- **The builds, read-only, to the LAN, with no login.** Anyone on the network can download
  them, so anything an extension's build embeds is readable on the LAN too. To narrow it to
  one PC, add a `remote_ip` matcher to the `builds` host's `extraConfig`.
- **Nothing on this box gains a way into Windows.** The browser connects to Caddy; nothing
  connects back.

## Environment

| Variable | Default | |
| --- | --- | --- |
| `SOME_UI` | the repo you are in, else `~/dev/some-ui` | the checkout to build |
| `EXT_DROP_DIR` | `/srv/builds` | where builds go (created by `systemd.tmpfiles`) |
| `EXT_DROP_KEEP` | `5` | builds kept per extension and target |
